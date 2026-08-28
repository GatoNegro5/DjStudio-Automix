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

// 🛠️ INYECCIÓN: Librerías exclusivas de Windows para control de subprocesos
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;

// 🛠️ REGISTRO GLOBAL DE PID PARA ABORTO ATÓMICO (KILL SWITCH)
static ACTIVE_PID: AtomicU32 = AtomicU32::new(0);

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

// 🛠️ KILL SWITCH EXPUESTO A DART (Debe ser síncrono para interrumpir al instante)
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

// 🛠️ MOTOR DE EJECUCIÓN SEGURO (Registra el PID antes de bloquear el hilo)
fn execute_ffmpeg_with_kill_switch(cmd: &mut Command) -> Result<std::process::Output, std::io::Error> {
    let child = cmd.spawn()?;
    ACTIVE_PID.store(child.id(), Ordering::SeqCst); // Registra el proceso en memoria RAM
    let output = child.wait_with_output()?;         // Bloquea hasta terminar o ser liquidado
    ACTIVE_PID.store(0, Ordering::SeqCst);          // Libera el registro
    Ok(output)
}

// 🛠️ CONSTRUCTOR MAESTRO: Aislamiento estricto de UI y Límite de CPU
fn spawn_headless_ffmpeg() -> Command {
    let mut cmd = Command::new(get_ffmpeg_path());
    #[cfg(target_os = "windows")]
    cmd.creation_flags(CREATE_NO_WINDOW);
    
    // 🛠️ FIX CPU STARVATION: 
    // -nostdin: Evita deadlocks de consola.
    // -threads 2: Obliga a FFmpeg a usar máximo 2 núcleos. Libera el resto para Windows y WhatsApp.
    cmd.args(["-nostdin", "-threads", "2"]); 
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

pub async fn process_auto_trim(input_path: String) -> Result<bool, String> {
    // 🛠️ VETO DE EJECUCIÓN (Idempotencia Nativa)
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

pub async fn inject_watermark(input_path: String) -> Result<bool, String> {
    // 🛠️ VETO DE EJECUCIÓN
    if check_watermark(input_path.clone()).await.unwrap_or(false) {
        return Ok(true);
    }

    let input = Path::new(&input_path);
    let temp_path = input.with_file_name("temp_watermark.mp3");

    let output = execute_ffmpeg_with_kill_switch(spawn_headless_ffmpeg()
        .args(["-y", "-i", input.to_str().unwrap(), "-map", "0", "-c", "copy", "-metadata", "DjStudio_M3_V2=Verified", temp_path.to_str().unwrap()]))
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
    // 🛠️ VETO DE EJECUCIÓN
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

pub async fn process_full_pipeline(input_path: String) -> Result<bool, String> {
    // 🛠️ VETO DE EJECUCIÓN MAESTRO: Si la firma física existe, aborta el re-renderizado pesado instantáneamente.
    if check_watermark(input_path.clone()).await.unwrap_or(false) {
        return Ok(true);
    }

    let input = Path::new(&input_path);
    if !input.exists() { return Err("Archivo no encontrado en I/O.".to_string()); }
    let temp_path = input.with_file_name("temp_dsp_full.mp3");

    let filter = "loudnorm=I=-14:LRA=11:TP=-1.5,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-30dB,areverse";

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

pub async fn check_watermark(input_path: String) -> Result<bool, String> {
    let input = std::path::Path::new(&input_path);
    if !input.exists() { 
        return Ok(false); 
    }

    // 1. Ejecutamos FFmpeg pidiendo explícitamente volcar los metadatos a la salida (stdout)
    let output = execute_ffmpeg_with_kill_switch(spawn_headless_ffmpeg()
        .args(["-i", input.to_str().unwrap(), "-f", "ffmetadata", "-"]))
        .map_err(|e| format!("Error de I/O nativo: {}", e));

    if let Ok(cmd_output) = output {
        // 2. FFmpeg es caótico: escribe el banner en stderr y ffmetadata en stdout. 
        // Leemos ambos buffers y los combinamos en minúsculas.
        let stdout_str = String::from_utf8_lossy(&cmd_output.stdout).to_lowercase();
        let stderr_str = String::from_utf8_lossy(&cmd_output.stderr).to_lowercase();
        
        let combined_log = format!("{}\n{}", stdout_str, stderr_str);
        
        // 3. Evaluación agnóstica a saltos de línea o símbolos
        if combined_log.contains("djstudio_m3_v2") && combined_log.contains("verified") {
            return Ok(true);
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

use std::process::Command;
use std::path::Path;

fn get_ffprobe_path() -> String {
    if let Ok(mut exe_path) = std::env::current_exe() {
        exe_path.pop();
        exe_path.push(if cfg!(target_os = "windows") { "ffprobe.exe" } else { "ffprobe" });
        if exe_path.exists() {
            return exe_path.to_string_lossy().into_owned();
        }
    }
    if cfg!(target_os = "macos") {
        if Path::new("/opt/homebrew/bin/ffprobe").exists() { return "/opt/homebrew/bin/ffprobe".to_string(); }
        if Path::new("/usr/local/bin/ffprobe").exists() { return "/usr/local/bin/ffprobe".to_string(); }
    }
    "ffprobe".to_string()
}

fn get_ffmpeg_path() -> String {
    if let Ok(mut exe_path) = std::env::current_exe() {
        exe_path.pop();
        exe_path.push(if cfg!(target_os = "windows") { "ffmpeg.exe" } else { "ffmpeg" });
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

// 🛠️ ANALIZADOR NEURONAL LIGERO (FFMPEG AST)
fn analyze_transients(file_path: &Path) -> String {
    // Escaneamos 5 segundos desde la mitad de la canción para evitar las intros sin ritmo.
    let output = Command::new(get_ffmpeg_path())
        .args([
            "-ss", "00:01:30", 
            "-t", "5",
            "-i", file_path.to_str().unwrap(),
            "-af", "astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.Peak_level",
            "-f", "null", "-"
        ])
        .output();

    if let Ok(out) = output {
        let log = String::from_utf8_lossy(&out.stderr);
        let mut peak_count = 0;
        let mut rms_level = 0.0;
        let mut readings = 0;

        // Parseo de los picos crudos.
        for line in log.lines() {
            if line.contains("lavfi.astats.Overall.Peak_level") {
                if let Some(val_str) = line.split('=').last() {
                    if let Ok(val) = val_str.trim().parse::<f32>() {
                        // Un pico por encima de -5dB suele ser una campana o un redoblante seco (Tropical/Rock).
                        if val > -5.0 { peak_count += 1; }
                        rms_level += val;
                        readings += 1;
                    }
                }
            }
        }

        if readings > 0 {
            let avg_peak = rms_level / readings as f32;
            
            // LÓGICA DE DENSIDAD:
            // - Si hay muchísimos picos súper agresivos y rápidos, es percusión acústica viva.
            if peak_count > 15 { return "salsa".to_string(); } 
            
            // - Si los picos son constantes y aplastados (cerca a 0dB), es un bajo/synth masterizado (Urbano).
            if avg_peak > -3.0 { return "actualidad".to_string(); }
            
            // - Si los picos tienen dinámica variable, suele ser acústico o Rock.
            return "rock".to_string();
        }
    }
    "desconocido".to_string()
}


pub async fn read_audio_genre(input_path: String) -> String {
    let path = Path::new(&input_path);
    let path_str = path.to_string_lossy().to_lowercase();

    // 1. CERO-COST HEURÍSTICA LÉXICA (Para bibliotecas organizadas en disco)
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

    // 2. LECTURA DE ID3v2 
    let output = Command::new(get_ffprobe_path())
        .args([
            "-v", "error",
            "-show_entries", "format_tags=genre",
            "-of", "default=noprint_wrappers=1:nokey=1",
            path.to_str().unwrap()
        ])
        .output();

    if let Ok(out) = output {
        let tag = String::from_utf8_lossy(&out.stdout).trim().to_lowercase();
        if !tag.is_empty() && tag != "unknown" {
            if tag.contains("salsa") { return "salsa".to_string(); }
            if tag.contains("merengue") { return "merengue".to_string(); }
            if tag.contains("cumbia") { return "cumbia".to_string(); }
            if tag.contains("rock") { return "rock".to_string(); }
            if tag.contains("electro") || tag.contains("house") || tag.contains("pop") { return "actualidad".to_string(); }
            return tag;
        }
    }

    // 3. ANÁLISIS ESPECTRAL BLINDADO (Si todo lo demás falla)
    // Si la ruta no dice nada ("Descargas/pista_rara.mp3") y el ID3 está vacío,
    // usamos FFmpeg nativo en C++ para leer la energía y predecir el comportamiento.
    analyze_transients(path)
}

pub async fn auto_detect_and_inject_bpm(input_path: String) -> Result<f64, String> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err("VETO I/O: Archivo no encontrado.".into());
    }

    // 1. Decodificación PCM y Autocorrelación en Memoria (Zero-I/O)
    let detected_bpm = match extract_bpm_dsp(&input_path) {
        Ok(bpm) => bpm,
        Err(e) => return Err(format!("Fallo DSP: {}", e)),
    };

    // 2. Auto-Healing: Inyección del Tag físico para estabilizar la pista permanentemente
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
    
    // Clonamos track_id y codec_params para soltar el préstamo inmutable de `format`
    let (track_id, codec_params) = {
        let track = format.default_track().ok_or("Sin pistas de audio válidas")?;
        (track.id, track.codec_params.clone())
    };
    
    let mut decoder = symphonia::default::get_codecs()
        .make(&codec_params, &decoder_opts)
        .map_err(|e| e.to_string())?;

    let sample_rate = codec_params.sample_rate.unwrap_or(44100) as f64;
    let mut energy_envelope = Vec::new();
    
    // Low-Pass aproximado: Ventana RMS de ~10ms aislando la energía de los bombos (Kicks)
    let window_size = (sample_rate * 0.01) as usize; 
    let mut current_window = 0.0;
    let mut samples_in_window = 0;

    // Límite de carga: ~15 segundos de espectro bastan para inducir el tempo
    let max_frames = 600; 
    let mut frame_count = 0;

    loop {
        if frame_count >= max_frames { break; }
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(_) => break, // EOF o corrupción tolerada
        };

        if packet.track_id() != track_id { continue; }

        match decoder.decode(&packet) {
            Ok(decoded) => {
                let mut sample_buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, *decoded.spec());
                sample_buf.copy_interleaved_ref(decoded);
                
                for sample in sample_buf.samples() {
                    current_window += sample * sample; // Root Mean Square (Energía)
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

    // Autocorrelación de la Envolvente de Energía (Búsqueda de picos periódicos)
    let mut max_corr = 0.0;
    let mut best_lag = 0;
    
    let min_bpm = 70.0;
    let max_bpm = 160.0;
    
    let env_sample_rate = sample_rate / window_size as f64;
    let min_lag = (env_sample_rate * 60.0 / max_bpm) as usize;
    let max_lag = (env_sample_rate * 60.0 / min_bpm) as usize;

    // Fix bounds check para iterador de lag
    for lag in min_lag..=max_lag {
        let mut corr = 0.0;
        // Prevenimos underflow en arreglos pequeños
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