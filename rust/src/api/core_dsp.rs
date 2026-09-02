use std::fs;
use std::process::Command;
use std::path::Path;
use std::env;
use std::sync::atomic::{AtomicU32, Ordering};
use std::fs::File;

use id3::{Tag, TagLike, Version};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::probe::Hint;
use symphonia::default::get_probe;
use symphonia::core::formats::FormatOptions;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::audio::SampleBuffer;

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;

static ACTIVE_PID: AtomicU32 = AtomicU32::new(0);

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[flutter_rust_bridge::frb(sync)]
pub fn abort_active_process() {
    let pid = ACTIVE_PID.swap(0, Ordering::SeqCst);
    if pid != 0 {
        #[cfg(target_os = "windows")]
        let _ = std::process::Command::new("taskkill")
            .args(&["/F", "/T", "/PID", &pid.to_string()])
            .creation_flags(CREATE_NO_WINDOW)
            .status();

        #[cfg(not(target_os = "windows"))]
        let _ = std::process::Command::new("kill")
            .args(&["-9", &pid.to_string()])
            .status();
            
        println!("🔴 [RUST FFI] Proceso de audio abortado forzosamente (PID: {}).", pid);
    }
}

fn execute_ffmpeg_with_kill_switch(cmd: &mut Command) -> Result<std::process::Output, std::io::Error> {
    let child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            println!("🔴 [RUST FFI FATAL] No se pudo lanzar FFmpeg. Ruta intentada: {:?}", cmd.get_program());
            return Err(e);
        }
    };
    ACTIVE_PID.store(child.id(), Ordering::SeqCst);
    let output = child.wait_with_output()?;        
    ACTIVE_PID.store(0, Ordering::SeqCst);         
    Ok(output)
}

fn spawn_headless_ffmpeg() -> Command {
    let mut cmd = Command::new(get_ffmpeg_path());
    #[cfg(target_os = "windows")]
    cmd.creation_flags(CREATE_NO_WINDOW);
    // 🛠️ FIX ARQUITECTURA: 0 indica uso del 100% de los núcleos lógicos disponibles.
    cmd.args(["-nostdin", "-threads", "0"]); 
    cmd
}

fn extract_json_value(log: &str, key: &str) -> Option<String> {
    let search_key = format!("\"{}\" : \"", key);
    if let Some(start) = log.find(search_key.as_str()) {
        let val_start = start + search_key.len();
        if let Some(end_offset) = log[val_start..].find('\"') {
            return Some(log[val_start..val_start + end_offset].to_string());
        }
    }
    None
}

fn atomic_replace(temp_path: &Path, original_path: &Path) -> Result<(), String> {
    let mut attempts = 0;
    let max_attempts = 5;
    let mut delay_ms = 50;

    loop {
        match fs::rename(temp_path, original_path) {
            Ok(_) => return Ok(()),
            Err(e) => {
                attempts += 1;
                if attempts >= max_attempts {
                    return Err(format!("Fallo en I/O Atómico tras {} intentos: {}", max_attempts, e));
                }
                std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                delay_ms *= 2;
            }
        }
    }
}

pub async fn get_audio_duration_ms(input_path: String) -> Result<u64, String> {
    let file = Box::new(File::open(&input_path).map_err(|e| e.to_string())?);
    let mss = MediaSourceStream::new(file, Default::default());
    let mut hint = Hint::new();
    hint.with_extension("mp3");

    let probed = get_probe().format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default());

    if let Ok(mut format) = probed {
        if let Some(track) = format.format.default_track() {
            if let Some(tb) = track.codec_params.time_base {
                if let Some(frames) = track.codec_params.n_frames {
                    let time = tb.calc_time(frames);
                    return Ok((time.seconds * 1000) + (time.frac as u64 * 1000));
                }
            }
        }
    }

    let file_meta = std::fs::metadata(&input_path).map_err(|e| e.to_string())?;
    let size_bytes = file_meta.len();
    Ok(((size_bytes * 8) / 320) as u64)
}

pub async fn process_auto_trim(input_path: String) -> Result<bool, String> {
    if check_watermark(input_path.clone()).await.unwrap_or(false) {
        return Ok(true);
    }

    let input = Path::new(&input_path);
    if !input.exists() { return Err("Archivo no encontrado en I/O.".to_string()); }

    let temp_path = input.with_file_name("temp_dsp_trim.mp3");
    let filter = "silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse";
    
    let output = execute_ffmpeg_with_kill_switch(spawn_headless_ffmpeg()
        .args(["-y", "-i", input.to_str().unwrap(), "-af", filter, "-c:a", "libmp3lame", "-q:a", "2", temp_path.to_str().unwrap()]))
        .map_err(|e| format!("OS Invocation Error: {}", e))?;

    if output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

pub async fn normalize_lufs(input_path: String) -> Result<bool, String> {
    if check_watermark(input_path.clone()).await.unwrap_or(false) {
        return Ok(true);
    }

    let input = Path::new(&input_path);
    if !input.exists() { return Err("Archivo no encontrado en I/O.".to_string()); }

    let null_sink = if cfg!(target_os = "windows") { "NUL" } else { "/dev/null" };

    let pass1_output = execute_ffmpeg_with_kill_switch(spawn_headless_ffmpeg()
        .args(["-i", input.to_str().unwrap(), "-af", "loudnorm=I=-14:LRA=11:TP=-1.5:print_format=json", "-f", "null", null_sink]))
        .map_err(|e| format!("Paso 1 Error: {}", e))?;

    let log = String::from_utf8_lossy(&pass1_output.stderr);
    let i = extract_json_value(&log, "input_i").ok_or("input_i missing".to_string())?;
    let lra = extract_json_value(&log, "input_lra").ok_or("input_lra missing".to_string())?;
    let tp = extract_json_value(&log, "input_tp").ok_or("input_tp missing".to_string())?;
    let thresh = extract_json_value(&log, "input_thresh").ok_or("input_thresh missing".to_string())?;

    let temp_path = input.with_file_name("temp_dsp_norm.mp3");
    let pass2_filter = format!("loudnorm=I=-14:LRA=11:TP=-1.5:measured_I={}:measured_LRA={}:measured_TP={}:measured_thresh={}:linear=true", i, lra, tp, thresh);

    let pass2_output = execute_ffmpeg_with_kill_switch(spawn_headless_ffmpeg()
        .args(["-y", "-i", input.to_str().unwrap(), "-af", &pass2_filter, "-c:a", "libmp3lame", "-q:a", "2", temp_path.to_str().unwrap()]))
        .map_err(|e| format!("Paso 2 Error: {}", e))?;

    if pass2_output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&pass2_output.stderr).to_string())
    }
}

// 🛠️ INYECTADO: Firma con is_megamix para enrutamiento táctico de rendimiento
pub async fn process_full_pipeline(input_path: String, is_megamix: bool) -> Result<bool, String> {
    if check_watermark(input_path.clone()).await.unwrap_or(false) {
        return Ok(true);
    }

    let input = Path::new(&input_path);
    if !input.exists() { return Err("Archivo no encontrado en I/O.".to_string()); }
    let temp_path = input.with_file_name("temp_dsp_full.mp3");

    // 🛠️ BYPASS ALGORÍTMICO: Si es un Megamix, abortamos el corte de silencios (areverse)
    // para evitar que la RAM explote al intentar invertir 1 hora de audio.
    let filter = if is_megamix {
        "loudnorm=I=-14:LRA=11:TP=-1.5"
    } else {
        "loudnorm=I=-14:LRA=11:TP=-1.5,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse"
    };

    let output = execute_ffmpeg_with_kill_switch(spawn_headless_ffmpeg()
        .args(["-y", "-i", input.to_str().unwrap(), "-af", filter, "-c:a", "libmp3lame", "-b:a", "320k", temp_path.to_str().unwrap()]))
        .map_err(|e| format!("OS Error: {}", e))?;

    if output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

pub async fn read_audio_genre(input_path: String) -> String {
    let path = Path::new(&input_path);
    let path_str = path.to_string_lossy().to_lowercase();

    if path_str.contains("salsa") { return "salsa".to_string(); }
    if path_str.contains("merengues") || path_str.contains("merengue") { return "merengue".to_string(); }
    if path_str.contains("cumbias") || path_str.contains("cumbia") { return "cumbia".to_string(); }
    if path_str.contains("nacional") { return "nacional".to_string(); }
    if path_str.contains("vallenatos") || path_str.contains("vallenato") { return "vallenato".to_string(); }
    if path_str.contains("guaracha") { return "guaracha".to_string(); }
    if path_str.contains("80s") { return "80s".to_string(); }
    if path_str.contains("rock") { return "rock".to_string(); }
    if path_str.contains("baladas") || path_str.contains("balada") { return "balada".to_string(); }
    if path_str.contains("española") || path_str.contains("espanola") { return "española".to_string(); }
    if path_str.contains("bachatas") || path_str.contains("bachata") { return "bachata".to_string(); }
    if path_str.contains("actualidad") { return "actualidad".to_string(); }
    if path_str.contains("fiesta") { return "fiesta".to_string(); }

    if let Ok(tag) = id3::Tag::read_from_path(path) {
        if let Some(genre) = tag.genre() {
            let genre_lower = genre.to_lowercase();
            if genre_lower.contains("salsa") { return "salsa".to_string(); }
            if genre_lower.contains("merengue") { return "merengue".to_string(); }
            if genre_lower.contains("cumbia") { return "cumbia".to_string(); }
            if genre_lower.contains("rock") { return "rock".to_string(); }
            if genre_lower.contains("electro") || genre_lower.contains("house") || genre_lower.contains("pop") { 
                return "actualidad".to_string(); 
            }
            return genre_lower;
        }
    }
    "desconocido".to_string()
}

pub async fn inject_watermark(input_path: String) -> Result<bool, String> {
    let path = std::path::Path::new(&input_path);
    if !path.exists() {
        return Err("File not found".to_string());
    }

    let mut tag = id3::Tag::read_from_path(path).unwrap_or_else(|_| id3::Tag::new());
    
    tag.add_comment(id3::frame::Comment {
        lang: "spa".to_string(),
        description: "".to_string(),
        text: "ReGenial Master".to_string(),
    });
    
    match tag.write_to_path(path, id3::Version::Id3v24) {
        Ok(_) => Ok(true),
        Err(e) => Err(format!("Failed to write ID3 tag: {}", e)),
    }
}

pub async fn check_watermark(input_path: String) -> Result<bool, String> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err("File not found".to_string());
    }

    if let Ok(tag) = id3::Tag::read_from_path(path) {
        if let Some(comment) = tag.comments().next() {
            if comment.text == "ReGenial Master" {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

pub async fn clear_watermark(input_path: String) -> Result<bool, String> {
    let input = Path::new(&input_path);
    let temp_path = input.with_file_name("temp_clear_meta.mp3");

    let output = execute_ffmpeg_with_kill_switch(spawn_headless_ffmpeg()
        .args(["-y", "-i", input.to_str().unwrap(), "-map", "0", "-c", "copy", "-metadata", "DjStudio_M3=", "-metadata", "DjStudio_M3_V2=", temp_path.to_str().unwrap()]))
        .map_err(|e| format!("OS Error: {}", e))?;

    if output.status.success() {
        atomic_replace(&temp_path, input)?;
        Ok(true)
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

fn get_ffmpeg_path() -> String {
    if let Ok(mut exe_path) = std::env::current_exe() {
        exe_path.pop();
        exe_path.push(if cfg!(target_os = "windows") { "ffmpeg.exe" } else { "ffmpeg" });
        
        // 🛠️ FIX ARQUITECTURA: Restauramos la validación física.
        // Si el binario no está en la carpeta efímera, usamos el comando global del PATH.
        if exe_path.exists() {
            return exe_path.to_string_lossy().into_owned();
        }
    }
    
    if cfg!(target_os = "macos") {
        if Path::new("/opt/homebrew/bin/ffmpeg").exists() { return "/opt/homebrew/bin/ffmpeg".to_string(); }
        if Path::new("/usr/local/bin/ffmpeg").exists() { return "/usr/local/bin/ffmpeg".to_string(); }
    }
    
    "ffmpeg".to_string()
}

pub async fn auto_detect_and_inject_bpm(input_path: String) -> Result<f64, String> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err("VETO I/O: Archivo no encontrado.".into());
    }

    let detected_bpm = match extract_bpm_dsp(&input_path) {
        Ok(bpm) => bpm,
        Err(e) => return Err(format!("Fallo DSP: {}", e)),
    };

    let mut tag = Tag::read_from_path(&input_path).unwrap_or_else(|_| Tag::new());
    tag.set_text("TBPM", detected_bpm.round().to_string());
    
    if let Err(e) = tag.write_to_path(&input_path, Version::Id3v24) {
        return Err(format!("Fallo I/O al sellar ID3: {}", e));
    }

    Ok(detected_bpm.round())
}

fn extract_bpm_dsp(input_path: &str) -> Result<f64, String> {
    let file = Box::new(File::open(input_path).map_err(|e| e.to_string())?);
    let mss = MediaSourceStream::new(file, Default::default());
    
    let mut hint = Hint::new();
    hint.with_extension("mp3");

    let format_opts: FormatOptions = Default::default();
    let metadata_opts: MetadataOptions = Default::default();
    let decoder_opts: DecoderOptions = Default::default();

    let probed = get_probe().format(&hint, mss, &format_opts, &metadata_opts)
        .map_err(|e| e.to_string())?;
    
    let mut format = probed.format;
    
    let (track_id, codec_params) = {
        let track = format.default_track().ok_or("Sin pistas de audio válidas")?;
        (track.id, track.codec_params.clone())
    };
    
    let mut decoder = symphonia::default::get_codecs()
        .make(&codec_params, &decoder_opts)
        .map_err(|e| e.to_string())?;

    let sample_rate = codec_params.sample_rate.unwrap_or(44100) as f64;
    let mut energy_envelope = Vec::new();
    
    let window_size = (sample_rate * 0.01) as usize; 
    let mut current_window = 0.0;
    let mut samples_in_window = 0;

    let max_frames = 600; 
    let mut frame_count = 0;

    loop {
        if frame_count >= max_frames { break; }
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(_) => break,
        };

        if packet.track_id() != track_id { continue; }

        match decoder.decode(&packet) {
            Ok(decoded) => {
                let mut sample_buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, *decoded.spec());
                sample_buf.copy_interleaved_ref(decoded);
                
                for sample in sample_buf.samples() {
                    current_window += sample * sample; 
                    samples_in_window += 1;
                    
                    if samples_in_window >= window_size {
                        energy_envelope.push(current_window);
                        current_window = 0.0;
                        samples_in_window = 0;
                    }
                }
            }
            Err(_) => break,
        }
        frame_count += 1;
    }

    if energy_envelope.is_empty() {
        return Err("Buffer PCM espectral vacío".into());
    }

    let mut max_corr = 0.0;
    let mut best_lag = 0;
    
    let min_bpm = 70.0;
    let max_bpm = 160.0;
    
    let env_sample_rate = sample_rate / window_size as f64;
    let min_lag = (env_sample_rate * 60.0 / max_bpm) as usize;
    let max_lag = (env_sample_rate * 60.0 / min_bpm) as usize;

    for lag in min_lag..=max_lag {
        let mut corr = 0.0;
        if energy_envelope.len() <= lag {
            continue;
        }
        for i in 0..(energy_envelope.len() - lag) {
            corr += energy_envelope[i] * energy_envelope[i + lag];
        }
        if corr > max_corr {
            max_corr = corr;
            best_lag = lag;
        }
    }

    if best_lag == 0 {
        return Err("Anomalía determinista: Sin periodicidad".into());
    }

    let bpm = (60.0 * env_sample_rate) / best_lag as f64;
    Ok(bpm)
}