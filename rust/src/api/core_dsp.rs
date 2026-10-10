use std::fs::File;
use std::path::Path;

use id3::frame::ExtendedText;
use id3::{Tag, TagLike, Version};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::{FormatOptions, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::core::units::Time;
use symphonia::default::get_probe;

// ============================================================================
// REGLA (CONTEXTO §2.7 y §7): CERO FFmpeg y CERO reproductor extra.
// Todo el análisis (volumen, silencios, BPM, duración) se hace en proceso con
// Rust/symphonia, igual en Windows, macOS, Android e iPhone. El MP3 NO se
// recodifica: el resultado se guarda como etiquetas ID3 (ReplayGain estándar +
// TXXX DJS_*), así el audio original queda intacto (sin pérdida de generación).
// ============================================================================

/// Versión del esquema de etiquetas. Si cambia, las pistas se reanalizan.
const MASTER_VERSION: &str = "1";
const SEAL_TEXT: &str = "ReGenial Master";
const RG_REFERENCE_LUFS: f64 = -18.0;
/// Tope de análisis (s). Los megamix largos se miden solo en este tramo.
const MAX_ANALYZE_SECS: u32 = 900;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Resultado leído de las etiquetas de una pista (sin decodificar).
pub struct MasterTags {
    pub analyzed: bool,
    /// Ganancia ReplayGain (dB) para llegar a -18 LUFS.
    pub gain_db: f64,
    pub lufs: f64,
    pub peak: f64,
    /// Silencio inicial / final (ms).
    pub lead_ms: u64,
    pub tail_ms: u64,
    pub bpm: f64,
}

// ---------------------------------------------------------------- decodificar

struct Decoded {
    rate: u32,
    ch: Vec<Vec<f32>>,
    /// Inicio REAL del tramo (ms): un seek puede caer antes de lo pedido.
    start_ms: u64,
}

fn open_format(
    input_path: &str,
) -> Result<
    (
        Box<dyn symphonia::core::formats::FormatReader>,
        u32,
        symphonia::core::codecs::CodecParameters,
    ),
    String,
> {
    let file = File::open(input_path).map_err(|e| e.to_string())?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(input_path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| e.to_string())?;
    let format = probed.format;
    let (track_id, params) = {
        let t = format.default_track().ok_or("Sin pista de audio")?;
        (t.id, t.codec_params.clone())
    };
    Ok((format, track_id, params))
}

/// Decodifica hasta `max_secs` segundos desde `start_secs`, hasta `max_ch`
/// canales (sin mezclar).
fn decode_channels(
    input_path: &str,
    start_secs: u32,
    max_secs: u32,
    max_ch: usize,
) -> Result<Decoded, String> {
    let (mut format, track_id, params) = open_format(input_path)?;
    let rate = params.sample_rate.ok_or("Sin frecuencia de muestreo")?;
    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(|e| e.to_string())?;

    let mut start_ms: u64 = 0;
    if start_secs > 0 {
        let sought = format.seek(
            SeekMode::Coarse,
            SeekTo::Time { time: Time::new(start_secs as u64, 0.0), track_id: Some(track_id) },
        );
        if let Ok(s) = sought {
            decoder.reset();
            if let Some(tb) = params.time_base {
                let t = tb.calc_time(s.actual_ts);
                start_ms = t.seconds * 1000 + (t.frac * 1000.0) as u64;
            } else {
                start_ms = start_secs as u64 * 1000;
            }
        }
    }

    let want = (rate as usize) * (max_secs as usize);
    let mut chans: Vec<Vec<f32>> = Vec::new();
    let mut frames = 0usize;
    while frames < want {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(_) => break,
        };
        if packet.track_id() != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(decoded) => {
                let spec = *decoded.spec();
                let n_ch = spec.channels.count().max(1);
                let keep = n_ch.min(max_ch.max(1));
                if chans.is_empty() {
                    chans = vec![Vec::with_capacity(want.min(1 << 24)); keep];
                }
                let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                buf.copy_interleaved_ref(decoded);
                for frame in buf.samples().chunks(n_ch) {
                    for c in 0..keep.min(chans.len()) {
                        chans[c].push(frame[c]);
                    }
                    frames += 1;
                }
            }
            Err(SymError::DecodeError(_)) => continue,
            Err(_) => break,
        }
    }
    if chans.is_empty() || chans[0].is_empty() {
        return Err("Sin audio decodificable".to_string());
    }
    Ok(Decoded { rate, ch: chans, start_ms })
}

fn to_mono(d: &Decoded) -> Vec<f32> {
    let n = d.ch[0].len();
    let k = d.ch.len() as f32;
    (0..n).map(|i| d.ch.iter().map(|c| c[i]).sum::<f32>() / k).collect()
}

/// Decodifica un tramo a PCM mono s16le a `target_rate` Hz (EQ adaptativa).
pub async fn decode_mono_pcm(
    input_path: String,
    start_secs: u32,
    length_secs: u32,
    target_rate: u32,
) -> Result<Vec<u8>, String> {
    let d = decode_channels(&input_path, start_secs, length_secs, 2)?;
    let mono = to_mono(&d);
    let ratio = d.rate as f64 / target_rate as f64;
    let out_len = (mono.len() as f64 / ratio) as usize;
    let mut out: Vec<u8> = Vec::with_capacity(out_len * 2);
    for i in 0..out_len {
        let pos = i as f64 * ratio;
        let idx = pos as usize;
        let frac = (pos - idx as f64) as f32;
        let a = mono[idx];
        let b = if idx + 1 < mono.len() { mono[idx + 1] } else { a };
        let v = (a + (b - a) * frac).clamp(-1.0, 1.0);
        out.extend_from_slice(&((v * 32767.0) as i16).to_le_bytes());
    }
    Ok(out)
}

// ------------------------------------------------------------------ duración

/// Duración EXACTA en ms. Un MP3 sin cabecera Xing (o con carátula grande)
/// hace que libmpv la ESTIME por tamaño/bitrate y se pase. Si el contenedor
/// trae el total de cuadros se usa; si no, se suman las duraciones de los
/// paquetes (sin decodificar). Devuelve 0 si no se puede determinar.
pub async fn exact_duration_ms(input_path: String) -> Result<u64, String> {
    let (mut format, track_id, params) = open_format(&input_path)?;
    let tb = match params.time_base {
        Some(tb) => tb,
        None => return Ok(0),
    };
    // MP3: la cabecera Xing/Info suele mentir (archivos recortados, unidos o
    // re-etiquetados) y libmpv la cree. En MP3 se cuentan los frames reales.
    let is_mp3 = params.codec == symphonia::core::codecs::CODEC_TYPE_MP3;
    if !is_mp3 {
        if let Some(n) = params.n_frames {
            let t = tb.calc_time(n);
            return Ok(t.seconds * 1000 + (t.frac * 1000.0) as u64);
        }
    }
    let mut total: u64 = 0;
    while let Ok(p) = format.next_packet() {
        if p.track_id() == track_id {
            total += p.dur;
        }
    }
    let t = tb.calc_time(total);
    Ok(t.seconds * 1000 + (t.frac * 1000.0) as u64)
}

/// Duración en ms para quien ya la usaba (mismo nombre). Ahora es exacta.
pub async fn get_audio_duration_ms(input_path: String) -> Result<u64, String> {
    match exact_duration_ms(input_path.clone()).await {
        Ok(ms) if ms > 0 => Ok(ms),
        _ => {
            let size = std::fs::metadata(&input_path).map_err(|e| e.to_string())?.len();
            Ok((size * 8) / 320)
        }
    }
}

// ------------------------------------------------------------------- análisis

struct Biquad {
    b: [f64; 3],
    a: [f64; 2],
    x: [f64; 2],
    y: [f64; 2],
}

impl Biquad {
    fn run(&mut self, input: &[f32]) -> Vec<f64> {
        let mut out = Vec::with_capacity(input.len());
        for &s in input {
            let x0 = s as f64;
            let y0 = self.b[0] * x0 + self.b[1] * self.x[0] + self.b[2] * self.x[1]
                - self.a[0] * self.y[0]
                - self.a[1] * self.y[1];
            self.x[1] = self.x[0];
            self.x[0] = x0;
            self.y[1] = self.y[0];
            self.y[0] = y0;
            out.push(y0);
        }
        out
    }
}

/// Filtro K (ITU-R BS.1770): shelf de agudos + pasa-altos, para cualquier fs.
fn k_weight(input: &[f32], fs: f64) -> Vec<f64> {
    let pi = std::f64::consts::PI;
    // Etapa 1: high shelf
    let g = 3.999843853973347_f64;
    let q = 0.7071752369554196_f64;
    let fc = 1681.9744509555319_f64;
    let k = (pi * fc / fs).tan();
    let vh = 10f64.powf(g / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let mut s1 = Biquad {
        b: [
            (vh + vb * k / q + k * k) / a0,
            2.0 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
        ],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    // Etapa 2: pasa-altos
    let q2 = 0.5003270373238773_f64;
    let fc2 = 38.13547087602444_f64;
    let k2 = (pi * fc2 / fs).tan();
    let a02 = 1.0 + k2 / q2 + k2 * k2;
    let mut s2 = Biquad {
        b: [1.0, -2.0, 1.0],
        a: [2.0 * (k2 * k2 - 1.0) / a02, (1.0 - k2 / q2 + k2 * k2) / a02],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    let stage1 = s1.run(input);
    // La 2ª etapa se corre sobre f64 para no perder precisión.
    let mut out = Vec::with_capacity(stage1.len());
    for &v in &stage1 {
        let y0 = s2.b[0] * v + s2.b[1] * s2.x[0] + s2.b[2] * s2.x[1]
            - s2.a[0] * s2.y[0]
            - s2.a[1] * s2.y[1];
        s2.x[1] = s2.x[0];
        s2.x[0] = v;
        s2.y[1] = s2.y[0];
        s2.y[0] = y0;
        out.push(y0);
    }
    out
}

/// Sonoridad integrada (LUFS) con compuertas absoluta y relativa (BS.1770-4).
fn integrated_lufs(d: &Decoded) -> f64 {
    let fs = d.rate as f64;
    let weighted: Vec<Vec<f64>> = d.ch.iter().map(|c| k_weight(c, fs)).collect();
    let block = (fs * 0.400) as usize;
    let step = (fs * 0.100) as usize;
    let n = weighted[0].len();
    if n < block || step == 0 {
        return -70.0;
    }
    let mut zs: Vec<f64> = Vec::new();
    let mut start = 0usize;
    while start + block <= n {
        let mut z = 0.0;
        for ch in &weighted {
            let ms: f64 = ch[start..start + block].iter().map(|v| v * v).sum::<f64>() / block as f64;
            z += ms;
        }
        zs.push(z);
        start += step;
    }
    let lk = |z: f64| -0.691 + 10.0 * z.max(1e-12).log10();
    let abs_gated: Vec<f64> = zs.iter().copied().filter(|z| lk(*z) > -70.0).collect();
    if abs_gated.is_empty() {
        return -70.0;
    }
    let mean_abs = abs_gated.iter().sum::<f64>() / abs_gated.len() as f64;
    let rel_thr = lk(mean_abs) - 10.0;
    let rel_gated: Vec<f64> = abs_gated.into_iter().filter(|z| lk(*z) > rel_thr).collect();
    if rel_gated.is_empty() {
        return lk(mean_abs);
    }
    lk(rel_gated.iter().sum::<f64>() / rel_gated.len() as f64)
}

/// Silencio inicial y final (ms) con ventanas de 10 ms y umbral de -50 dBFS.
fn edge_silence_ms(mono: &[f32], rate: u32) -> (u64, u64) {
    let win = (rate as usize / 100).max(1);
    let thr = 10f64.powf(-50.0 / 20.0);
    let n_win = mono.len() / win;
    if n_win < 10 {
        return (0, 0);
    }
    let loud = |i: usize| -> bool {
        let s = &mono[i * win..(i + 1) * win];
        let rms = (s.iter().map(|v| (*v as f64) * (*v as f64)).sum::<f64>() / win as f64).sqrt();
        rms > thr
    };
    let first = (0..n_win).find(|i| loud(*i));
    let last = (0..n_win).rev().find(|i| loud(*i));
    match (first, last) {
        (Some(f), Some(l)) => {
            let lead = (f as u64) * 10;
            let tail = ((n_win - 1 - l) as u64) * 10;
            (lead, tail)
        }
        _ => (0, 0),
    }
}

/// BPM por autocorrelación del flujo de onsets, con refuerzo de armónicos y
/// plegado a 78-165. Usa un tramo central (hasta 80 s) de la pista.
fn detect_bpm(mono: &[f32], rate: u32) -> Option<f64> {
    let total_s = mono.len() as f64 / rate as f64;
    let (from, len) = if total_s > 100.0 { (20.0, 80.0) } else { (0.0, total_s) };
    let s0 = (from * rate as f64) as usize;
    let s1 = ((from + len) * rate as f64) as usize;
    let seg = &mono[s0.min(mono.len())..s1.min(mono.len())];
    let hop = (rate as usize / 200).max(1); // 5 ms
    let env_rate = rate as f64 / hop as f64;
    let n = seg.len() / hop;
    if n < 400 {
        return None;
    }
    // Energía de la señal diferenciada (resalta golpes).
    let mut env: Vec<f64> = Vec::with_capacity(n);
    for i in 0..n {
        let s = &seg[i * hop..(i + 1) * hop];
        let mut e = 0.0;
        let mut prev = if i == 0 { 0.0 } else { seg[i * hop - 1] as f64 };
        for v in s {
            let d = *v as f64 - prev;
            e += d * d;
            prev = *v as f64;
        }
        env.push((1.0 + 1000.0 * e / hop as f64).ln());
    }
    // Flujo positivo y centrado.
    let mut flux: Vec<f64> = (0..n).map(|i| if i == 0 { 0.0 } else { (env[i] - env[i - 1]).max(0.0) }).collect();
    let mean = flux.iter().sum::<f64>() / n as f64;
    for v in flux.iter_mut() {
        *v -= mean;
    }
    let min_lag = (env_rate * 60.0 / 200.0) as usize;
    let max_lag = (env_rate * 60.0 / 55.0) as usize;
    if max_lag * 4 + 2 >= n {
        return None;
    }
    let ac = |lag: usize| -> f64 {
        let mut c = 0.0;
        for i in 0..(n - lag) {
            c += flux[i] * flux[i + lag];
        }
        c / (n - lag) as f64
    };
    let mut best_lag = 0usize;
    let mut best = f64::MIN;
    let mut scores: Vec<f64> = vec![0.0; max_lag + 2];
    for lag in min_lag..=max_lag {
        let sc = ac(lag) + 0.5 * ac(lag * 2) + 0.25 * ac((lag * 4).min(n - 2));
        scores[lag] = sc;
        if sc > best {
            best = sc;
            best_lag = lag;
        }
    }
    if best_lag == 0 || best <= 0.0 {
        return None;
    }
    // Interpolación parabólica del pico.
    let mut lag_f = best_lag as f64;
    if best_lag > min_lag && best_lag < max_lag {
        let (a, b, c) = (scores[best_lag - 1], scores[best_lag], scores[best_lag + 1]);
        let denom = a - 2.0 * b + c;
        if denom.abs() > 1e-12 {
            lag_f += 0.5 * (a - c) / denom;
        }
    }
    let mut bpm = 60.0 * env_rate / lag_f;
    while bpm < 78.0 {
        bpm *= 2.0;
    }
    while bpm > 165.0 {
        bpm /= 2.0;
    }
    Some(bpm)
}

struct Analysis {
    lufs: f64,
    peak: f64,
    lead_ms: u64,
    tail_ms: u64,
    bpm: Option<f64>,
}

fn analyze_file(input_path: &str) -> Result<Analysis, String> {
    let d = decode_channels(input_path, 0, MAX_ANALYZE_SECS, 2)?;
    let mut peak = 0.0f64;
    for c in &d.ch {
        for v in c {
            let a = (*v as f64).abs();
            if a > peak {
                peak = a;
            }
        }
    }
    let lufs = integrated_lufs(&d);
    let mono = to_mono(&d);
    let (lead_ms, tail_ms) = edge_silence_ms(&mono, d.rate);
    let bpm = detect_bpm(&mono, d.rate);
    Ok(Analysis { lufs, peak, lead_ms, tail_ms, bpm })
}

// ------------------------------------------------------------------ etiquetas

fn ext_text(tag: &Tag, key: &str) -> Option<String> {
    tag.extended_texts().find(|e| e.description.eq_ignore_ascii_case(key)).map(|e| e.value.clone())
}

fn set_ext(tag: &mut Tag, key: &str, value: String) {
    tag.remove_extended_text(Some(key), None);
    tag.add_frame(ExtendedText { description: key.to_string(), value });
}

fn num_from(s: &str) -> f64 {
    let t: String = s.chars().filter(|c| c.is_ascii_digit() || *c == '.' || *c == '-').collect();
    t.parse::<f64>().unwrap_or(0.0)
}

fn is_mp3(path: &str) -> bool {
    path.to_lowercase().ends_with(".mp3")
}

/// Lee lo que dejó el masterizado (sin decodificar). Sirve a Live DJ y Automix.
pub async fn read_master_tags(input_path: String) -> MasterTags {
    let empty = MasterTags { analyzed: false, gain_db: 0.0, lufs: 0.0, peak: 0.0, lead_ms: 0, tail_ms: 0, bpm: 0.0 };
    if !is_mp3(&input_path) {
        return empty;
    }
    let tag = match Tag::read_from_path(&input_path) {
        Ok(t) => t,
        Err(_) => return empty,
    };
    let bpm = tag.get("TBPM").and_then(|f| f.content().text()).map(num_from).unwrap_or(0.0);
    if ext_text(&tag, "DJS_V").as_deref() != Some(MASTER_VERSION) {
        return MasterTags { bpm, ..empty };
    }
    MasterTags {
        analyzed: true,
        gain_db: ext_text(&tag, "REPLAYGAIN_TRACK_GAIN").map(|s| num_from(&s)).unwrap_or(0.0),
        lufs: ext_text(&tag, "DJS_LUFS").map(|s| num_from(&s)).unwrap_or(0.0),
        peak: ext_text(&tag, "REPLAYGAIN_TRACK_PEAK").map(|s| num_from(&s)).unwrap_or(0.0),
        lead_ms: ext_text(&tag, "DJS_LEAD_MS").map(|s| num_from(&s) as u64).unwrap_or(0),
        tail_ms: ext_text(&tag, "DJS_TAIL_MS").map(|s| num_from(&s) as u64).unwrap_or(0),
        bpm,
    }
}

/// Analiza y guarda las etiquetas. `Ok(true)` = la pista queda analizada (o ya
/// lo estaba). `Ok(false)` = formato no soportado para etiquetas (no se sella).
fn analyze_and_tag(input_path: &str, force: bool) -> Result<bool, String> {
    if !Path::new(input_path).exists() {
        return Err("Archivo no encontrado en I/O.".to_string());
    }
    if !is_mp3(input_path) {
        return Ok(false);
    }
    let mut tag = Tag::read_from_path(input_path).unwrap_or_else(|_| Tag::new());
    if !force && ext_text(&tag, "DJS_V").as_deref() == Some(MASTER_VERSION) {
        return Ok(true);
    }
    let a = analyze_file(input_path)?;
    let gain = (RG_REFERENCE_LUFS - a.lufs).clamp(-24.0, 24.0);
    set_ext(&mut tag, "REPLAYGAIN_TRACK_GAIN", format!("{:.2} dB", gain));
    set_ext(&mut tag, "REPLAYGAIN_TRACK_PEAK", format!("{:.6}", a.peak));
    set_ext(&mut tag, "DJS_LUFS", format!("{:.2}", a.lufs));
    set_ext(&mut tag, "DJS_LEAD_MS", a.lead_ms.to_string());
    set_ext(&mut tag, "DJS_TAIL_MS", a.tail_ms.to_string());
    let has_bpm = tag.get("TBPM").and_then(|f| f.content().text()).map(num_from).unwrap_or(0.0) > 0.0;
    if !has_bpm {
        if let Some(b) = a.bpm {
            tag.set_text("TBPM", b.round().to_string());
        }
    }
    set_ext(&mut tag, "DJS_V", MASTER_VERSION.to_string());
    tag.write_to_path(input_path, Version::Id3v24).map_err(|e| format!("Fallo I/O al guardar etiquetas: {}", e))?;
    Ok(true)
}

/// Masterizado de una pista: volumen + silencios + BPM, sin recodificar.
/// (Mismo nombre y firma que antes; ya no usa FFmpeg.)
pub async fn process_full_pipeline(input_path: String, is_megamix: bool) -> Result<bool, String> {
    if is_megamix {
        return Ok(true);
    }
    analyze_and_tag(&input_path, false)
}

/// Solo volumen (ReplayGain). Misma salida que `process_full_pipeline`.
pub async fn normalize_lufs(input_path: String) -> Result<bool, String> {
    analyze_and_tag(&input_path, false)
}

/// Solo silencios de inicio/fin (se guardan como cue, no se corta el archivo).
pub async fn process_auto_trim(input_path: String) -> Result<bool, String> {
    analyze_and_tag(&input_path, false)
}

pub async fn auto_detect_and_inject_bpm(input_path: String) -> Result<f64, String> {
    if !Path::new(&input_path).exists() {
        return Err("VETO I/O: Archivo no encontrado.".into());
    }
    let d = decode_channels(&input_path, 0, 150, 2).map_err(|e| format!("Fallo DSP: {}", e))?;
    let mono = to_mono(&d);
    let bpm = detect_bpm(&mono, d.rate).ok_or("Anomalía determinista: Sin periodicidad".to_string())?;
    let rounded = bpm.round();
    if is_mp3(&input_path) {
        let mut tag = Tag::read_from_path(&input_path).unwrap_or_else(|_| Tag::new());
        tag.set_text("TBPM", rounded.to_string());
        tag.write_to_path(&input_path, Version::Id3v24)
            .map_err(|e| format!("Fallo I/O al sellar ID3: {}", e))?;
    }
    Ok(rounded)
}

// --------------------------------------------------------------------- género

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

// --------------------------------------------------------------------- sello

pub async fn inject_watermark(input_path: String) -> Result<bool, String> {
    let path = std::path::Path::new(&input_path);
    if !path.exists() {
        return Err("File not found".to_string());
    }

    let mut tag = id3::Tag::read_from_path(path).unwrap_or_else(|_| id3::Tag::new());
    tag.remove_comment(None, Some(SEAL_TEXT));
    tag.add_frame(id3::frame::Comment {
        lang: "spa".to_string(),
        description: "".to_string(),
        text: SEAL_TEXT.to_string(),
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
        if tag.comments().any(|c| c.text == SEAL_TEXT) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Reset de SONIDO: quita el sello y las etiquetas de masterizado (ReplayGain,
/// DJS_*). No toca letras (.lrc) ni el resto de las etiquetas del archivo.
pub async fn clear_watermark(input_path: String) -> Result<bool, String> {
    let path = Path::new(&input_path);
    if !path.exists() {
        return Err("File not found".to_string());
    }
    if !is_mp3(&input_path) {
        return Ok(true);
    }
    let mut tag = match Tag::read_from_path(path) {
        Ok(t) => t,
        Err(_) => return Ok(true),
    };
    tag.remove_comment(None, Some(SEAL_TEXT));
    for key in [
        "REPLAYGAIN_TRACK_GAIN",
        "REPLAYGAIN_TRACK_PEAK",
        "DJS_V",
        "DJS_LUFS",
        "DJS_LEAD_MS",
        "DJS_TAIL_MS",
        "DjStudio_M3",
        "DjStudio_M3_V2",
    ] {
        tag.remove_extended_text(Some(key), None);
    }
    tag.write_to_path(path, Version::Id3v24).map_err(|e| format!("Fallo I/O: {}", e))?;
    Ok(true)
}

// ════════════════════════════════════════════════════════════════════════
//  CODIFICADOR MP3 (LAME) + SONDA DE OUTRO + GRABADOR MASTER-OUT
//  Todo en proceso: cero binarios externos en las 4 plataformas.
// ════════════════════════════════════════════════════════════════════════

fn lame_bitrate(kbps: u32) -> mp3lame_encoder::Bitrate {
    use mp3lame_encoder::Bitrate as B;
    match kbps {
        0..=96 => B::Kbps96,
        97..=128 => B::Kbps128,
        129..=160 => B::Kbps160,
        161..=192 => B::Kbps192,
        193..=256 => B::Kbps256,
        _ => B::Kbps320,
    }
}

/// Resampleo lineal con estado (continuo entre bloques).
struct Resampler {
    ratio: f64,
    pos: f64,
    last: (f32, f32),
    has_last: bool,
}

impl Resampler {
    fn new(from: u32, to: u32) -> Self {
        Resampler { ratio: from as f64 / to as f64, pos: 0.0, last: (0.0, 0.0), has_last: false }
    }

    fn process(&mut self, input: &[(f32, f32)], out: &mut Vec<(f32, f32)>) {
        if input.is_empty() {
            return;
        }
        let mut seq: Vec<(f32, f32)> = Vec::with_capacity(input.len() + 1);
        if self.has_last {
            seq.push(self.last);
        }
        seq.extend_from_slice(input);
        while self.pos + 1.0 < seq.len() as f64 {
            let i = self.pos as usize;
            let f = (self.pos - i as f64) as f32;
            let a = seq[i];
            let b = seq[i + 1];
            out.push((a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f));
            self.pos += self.ratio;
        }
        self.pos -= (seq.len() - 1) as f64;
        self.last = seq[seq.len() - 1];
        self.has_last = true;
    }
}

/// Destino MP3: recibe PCM float entrelazado y escribe un MP3 CBR.
struct Mp3Sink {
    enc: mp3lame_encoder::Encoder,
    out: std::io::BufWriter<File>,
    stereo: bool,
    rs: Option<Resampler>,
}

fn dbg_err<E: std::fmt::Debug>(e: E) -> String {
    format!("{:?}", e)
}

impl Mp3Sink {
    fn new(path: &str, src_rate: u32, stereo: bool, kbps: u32) -> Result<Self, String> {
        let rate = match src_rate {
            32000 | 44100 | 48000 => src_rate,
            r if r > 48000 && r % 48000 == 0 => 48000,
            _ => 44100,
        };
        let mut b = mp3lame_encoder::Builder::new().ok_or("No se pudo crear LAME")?;
        b.set_num_channels(if stereo { 2 } else { 1 }).map_err(dbg_err)?;
        b.set_sample_rate(rate).map_err(dbg_err)?;
        b.set_brate(lame_bitrate(kbps)).map_err(dbg_err)?;
        b.set_quality(mp3lame_encoder::Quality::Best).map_err(dbg_err)?;
        let enc = b.build().map_err(dbg_err)?;
        if let Some(dir) = Path::new(path).parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let f = File::create(path).map_err(|e| e.to_string())?;
        Ok(Mp3Sink {
            enc,
            out: std::io::BufWriter::with_capacity(1 << 18, f),
            stereo,
            rs: if rate != src_rate { Some(Resampler::new(src_rate, rate)) } else { None },
        })
    }

    /// `inter` = muestras entrelazadas con `src_ch` canales (se usan L y R).
    fn push(&mut self, inter: &[f32], src_ch: usize) -> Result<(), String> {
        use std::io::Write;
        let src_ch = src_ch.max(1);
        let mut frames: Vec<(f32, f32)> = Vec::with_capacity(inter.len() / src_ch);
        for fr in inter.chunks_exact(src_ch) {
            let l = fr[0];
            let r = if src_ch > 1 { fr[1] } else { l };
            frames.push((l, r));
        }
        let frames = match self.rs.as_mut() {
            Some(rs) => {
                let mut o = Vec::with_capacity(frames.len() + 8);
                rs.process(&frames, &mut o);
                o
            }
            None => frames,
        };
        if frames.is_empty() {
            return Ok(());
        }
        let q = |x: f32| (x.clamp(-1.0, 1.0) * 32767.0).round() as i16;
        let mut out: Vec<u8> = Vec::new();
        out.reserve(mp3lame_encoder::max_required_buffer_size(frames.len()));
        let n = if self.stereo {
            let mut pcm: Vec<i16> = Vec::with_capacity(frames.len() * 2);
            for (l, r) in &frames {
                pcm.push(q(*l));
                pcm.push(q(*r));
            }
            self.enc
                .encode(mp3lame_encoder::InterleavedPcm(&pcm), out.spare_capacity_mut())
                .map_err(dbg_err)?
        } else {
            let pcm: Vec<i16> = frames.iter().map(|(l, r)| q((*l + *r) * 0.5)).collect();
            self.enc
                .encode(mp3lame_encoder::MonoPcm(&pcm), out.spare_capacity_mut())
                .map_err(dbg_err)?
        };
        unsafe { out.set_len(n) };
        self.out.write_all(&out).map_err(|e| e.to_string())
    }

    fn finish(mut self) -> Result<(), String> {
        use std::io::Write;
        let mut out: Vec<u8> = Vec::new();
        out.reserve(8192);
        let n = self
            .enc
            .flush::<mp3lame_encoder::FlushNoGap>(out.spare_capacity_mut())
            .map_err(dbg_err)?;
        unsafe { out.set_len(n) };
        self.out.write_all(&out).map_err(|e| e.to_string())?;
        self.out.flush().map_err(|e| e.to_string())
    }
}

/// Convierte CUALQUIER audio decodificable (m4a/AAC, MP3, FLAC, WAV, OGG…)
/// a MP3 CBR con LAME (calidad máxima). Decodifica en streaming (RAM plana).
/// Reemplaza al antiguo `ffmpeg -vn -b:a 320k`.
pub fn encode_to_mp3(input_path: String, output_path: String, bitrate_kbps: u32) -> Result<bool, String> {
    let (mut format, track_id, params) = open_format(&input_path)?;
    let rate = params.sample_rate.ok_or("Sin frecuencia de muestreo")?;
    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(|e| format!("Códec no soportado: {e}"))?;

    let tmp = format!("{output_path}.part");
    let mut sink: Option<Mp3Sink> = None;
    let mut wrote = false;
    let res: Result<(), String> = (|| {
        loop {
            let packet = match format.next_packet() {
                Ok(p) => p,
                Err(_) => break,
            };
            if packet.track_id() != track_id {
                continue;
            }
            match decoder.decode(&packet) {
                Ok(decoded) => {
                    let spec = *decoded.spec();
                    let n_ch = spec.channels.count().max(1);
                    if sink.is_none() {
                        sink = Some(Mp3Sink::new(&tmp, rate, n_ch > 1, bitrate_kbps)?);
                    }
                    let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                    buf.copy_interleaved_ref(decoded);
                    sink.as_mut().unwrap().push(buf.samples(), n_ch)?;
                    wrote = true;
                }
                Err(SymError::DecodeError(_)) => continue,
                Err(_) => break,
            }
        }
        Ok(())
    })();
    let fin = match sink {
        Some(s) => s.finish(),
        None => Err("Sin audio decodificable".to_string()),
    };
    if let Err(e) = res.and(fin) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    if !wrote {
        let _ = std::fs::remove_file(&tmp);
        return Err("Sin audio decodificable".to_string());
    }
    let _ = std::fs::remove_file(&output_path);
    std::fs::rename(&tmp, &output_path).map_err(|e| e.to_string())?;
    Ok(true)
}

/// Dónde muere la energía del outro: inicio (ms absolutos) de la última racha
/// de ≥ 0.4 s por debajo de -32 dBFS en los últimos ~12 s. 0 = no hay.
/// Reemplaza al antiguo `ffmpeg silencedetect`.
pub fn outro_energy_end_ms(input_path: String, duration_ms: u64) -> u64 {
    if duration_ms < 20_000 {
        return 0;
    }
    let seek = (duration_ms.saturating_sub(12_000) / 1000) as u32;
    let d = match decode_channels(&input_path, seek, 14, 1) {
        Ok(d) => d,
        Err(_) => return 0,
    };
    let x = &d.ch[0];
    let win = (d.rate as usize / 100).max(1); // 10 ms
    let need = 40; // 0.4 s
    let thr_db = -32.0f32;
    let mut run = 0usize;
    let mut last_start: Option<usize> = None;
    let mut idx = 0usize;
    let mut run_start = 0usize;
    for w in x.chunks(win) {
        let e = w.iter().map(|v| v * v).sum::<f32>() / w.len() as f32;
        let db = 10.0 * e.max(1e-12).log10();
        if db < thr_db {
            if run == 0 {
                run_start = idx;
            }
            run += 1;
            if run >= need {
                last_start = Some(run_start);
            }
        } else {
            run = 0;
        }
        idx += 1;
    }
    match last_start {
        Some(w) => d.start_ms + (w as u64) * 10,
        None => 0,
    }
}

// ───────────────────────── Grabador Master-Out ─────────────────────────

struct RecHandle {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    join: std::thread::JoinHandle<Result<(), String>>,
}

static REC: std::sync::Mutex<Option<RecHandle>> = std::sync::Mutex::new(None);

pub fn is_master_recording() -> bool {
    REC.lock().map(|g| g.is_some()).unwrap_or(false)
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn rec_stream<T>(
    dev: &cpal::Device,
    cfg: &cpal::StreamConfig,
    tx: std::sync::mpsc::Sender<Vec<f32>>,
) -> Result<cpal::Stream, String>
where
    T: cpal::SizedSample,
    f32: cpal::FromSample<T>,
{
    use cpal::traits::DeviceTrait;
    dev.build_input_stream(
        cfg,
        move |data: &[T], _| {
            let v: Vec<f32> = data.iter().map(|s| (*s).to_sample::<f32>()).collect();
            let _ = tx.send(v);
        },
        |e| eprintln!("[rec] {e}"),
        None,
    )
    .map_err(|e| e.to_string())
}

/// Graba la salida master a MP3 320 kbps. Windows: loopback WASAPI del
/// dispositivo de salida. macOS: entrada de audio predeterminada.
/// Android/iOS: no disponible (el sistema lo veta).
#[cfg(any(target_os = "windows", target_os = "macos"))]
pub fn start_master_recording(output_path: String, bitrate_kbps: u32) -> Result<(), String> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc};

    let mut guard = REC.lock().map_err(|_| "estado corrupto".to_string())?;
    if guard.is_some() {
        return Err("Ya se está grabando".to_string());
    }
    let stop = Arc::new(AtomicBool::new(false));
    let stop2 = stop.clone();
    let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();

    let join = std::thread::spawn(move || -> Result<(), String> {
        let setup = || -> Result<(cpal::Stream, mpsc::Receiver<Vec<f32>>, Mp3Sink, usize), String> {
            let host = cpal::default_host();
            #[cfg(target_os = "windows")]
            let (dev, conf) = {
                let d = host.default_output_device().ok_or("Sin dispositivo de salida")?;
                let c = d.default_output_config().map_err(|e| e.to_string())?;
                (d, c)
            };
            #[cfg(target_os = "macos")]
            let (dev, conf) = {
                let d = host.default_input_device().ok_or("Sin dispositivo de entrada")?;
                let c = d.default_input_config().map_err(|e| e.to_string())?;
                (d, c)
            };
            let ch = conf.channels() as usize;
            let rate = conf.sample_rate().0;
            let (tx, rx) = mpsc::channel::<Vec<f32>>();
            let cfg: cpal::StreamConfig = conf.clone().into();
            let stream = match conf.sample_format() {
                cpal::SampleFormat::F32 => rec_stream::<f32>(&dev, &cfg, tx)?,
                cpal::SampleFormat::I16 => rec_stream::<i16>(&dev, &cfg, tx)?,
                cpal::SampleFormat::U16 => rec_stream::<u16>(&dev, &cfg, tx)?,
                cpal::SampleFormat::I32 => rec_stream::<i32>(&dev, &cfg, tx)?,
                f => return Err(format!("Formato de muestra no soportado: {f:?}")),
            };
            let sink = Mp3Sink::new(&output_path, rate, ch > 1, bitrate_kbps)?;
            stream.play().map_err(|e| e.to_string())?;
            Ok((stream, rx, sink, ch))
        };
        let (stream, rx, mut sink, ch) = match setup() {
            Ok(v) => {
                let _ = ready_tx.send(Ok(()));
                v
            }
            Err(e) => {
                let _ = ready_tx.send(Err(e.clone()));
                return Err(e);
            }
        };
        let mut result: Result<(), String> = Ok(());
        while !stop2.load(Ordering::Relaxed) {
            if let Ok(buf) = rx.recv_timeout(std::time::Duration::from_millis(100)) {
                if let Err(e) = sink.push(&buf, ch) {
                    result = Err(e);
                    break;
                }
            }
        }
        drop(stream);
        while let Ok(buf) = rx.try_recv() {
            if result.is_ok() {
                if let Err(e) = sink.push(&buf, ch) {
                    result = Err(e);
                }
            }
        }
        let fin = sink.finish();
        result.and(fin)
    });

    match ready_rx.recv_timeout(std::time::Duration::from_secs(8)) {
        Ok(Ok(())) => {
            *guard = Some(RecHandle { stop, join });
            Ok(())
        }
        Ok(Err(e)) => {
            let _ = join.join();
            Err(e)
        }
        Err(_) => {
            stop.store(true, Ordering::Relaxed);
            Err("El grabador no arrancó a tiempo".to_string())
        }
    }
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
pub fn start_master_recording(_output_path: String, _bitrate_kbps: u32) -> Result<(), String> {
    Err("La grabación Master-Out no está disponible en este sistema".to_string())
}

/// Detiene la grabación y cierra el MP3 (flush de LAME).
pub fn stop_master_recording() -> Result<(), String> {
    let h = {
        let mut g = REC.lock().map_err(|_| "estado corrupto".to_string())?;
        g.take()
    };
    match h {
        None => Ok(()),
        Some(h) => {
            h.stop.store(true, std::sync::atomic::Ordering::Relaxed);
            h.join.join().map_err(|_| "El grabador falló".to_string())?
        }
    }
}

// ════════════════════════════════════════════════════════════════════════
//  KARAOKE IA (MDX-Net / UVR, ONNX) — 100 % Rust, sin Python ni FFmpeg
//  Modelo: UVR-MDX-NET-Inst_HQ_3.onnx (entrada [1,4,3072,256], salida = pista
//  instrumental). Inferencia con tract (Rust puro, corre en las 4 plataformas).
// ════════════════════════════════════════════════════════════════════════

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

static KAR_PROGRESS: AtomicU32 = AtomicU32::new(0);
static KAR_CANCEL: AtomicBool = AtomicBool::new(false);

const K_FFT: usize = 7680;
const K_HOP: usize = 1024;
const K_DIM_F: usize = 3072;
const K_DIM_T: usize = 256;
const K_COMPENSATE: f32 = 1.022;
const K_RATE: u32 = 44100;

/// Progreso 0.0‥1.0 de la pista que se está separando.
pub fn karaoke_progress() -> f64 {
    KAR_PROGRESS.load(Ordering::Relaxed) as f64 / 1000.0
}

/// Pide detener la separación en curso (corta en el siguiente bloque).
pub fn karaoke_cancel() {
    KAR_CANCEL.store(true, Ordering::Relaxed);
}

struct KStft {
    fwd: std::sync::Arc<dyn rustfft::Fft<f32>>,
    inv: std::sync::Arc<dyn rustfft::Fft<f32>>,
    win: Vec<f32>,
}

impl KStft {
    fn new() -> Self {
        let mut p = rustfft::FftPlanner::<f32>::new();
        let win = (0..K_FFT)
            .map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / K_FFT as f32).cos())
            .collect();
        KStft { fwd: p.plan_fft_forward(K_FFT), inv: p.plan_fft_inverse(K_FFT), win }
    }

    /// x: K_HOP*(K_DIM_T-1) muestras → escribe re/im en `re`/`im` [K_DIM_F][K_DIM_T].
    fn forward(&self, x: &[f32], re: &mut [f32], im: &mut [f32]) {
        let half = K_FFT / 2;
        let l = x.len();
        let mut p = vec![0f32; l + K_FFT];
        for i in 0..half {
            p[i] = x[half - i];
            p[half + l + i] = x[l - 2 - i];
        }
        p[half..half + l].copy_from_slice(x);
        let mut buf = vec![rustfft::num_complex::Complex32::new(0.0, 0.0); K_FFT];
        for t in 0..K_DIM_T {
            for n in 0..K_FFT {
                buf[n] = rustfft::num_complex::Complex32::new(p[t * K_HOP + n] * self.win[n], 0.0);
            }
            self.fwd.process(&mut buf);
            for k in 0..K_DIM_F {
                re[k * K_DIM_T + t] = buf[k].re;
                im[k * K_DIM_T + t] = buf[k].im;
            }
        }
    }

    /// Inversa: re/im [K_DIM_F][K_DIM_T] → `out_len` muestras.
    fn inverse(&self, re: &[f32], im: &[f32], out_len: usize) -> Vec<f32> {
        let half = K_FFT / 2;
        let total = K_HOP * (K_DIM_T - 1) + K_FFT;
        let mut ola = vec![0f32; total];
        let mut wsum = vec![0f32; total];
        let mut buf = vec![rustfft::num_complex::Complex32::new(0.0, 0.0); K_FFT];
        for t in 0..K_DIM_T {
            for b in buf.iter_mut() {
                *b = rustfft::num_complex::Complex32::new(0.0, 0.0);
            }
            for k in 0..K_DIM_F {
                let c = rustfft::num_complex::Complex32::new(re[k * K_DIM_T + t], im[k * K_DIM_T + t]);
                buf[k] = c;
                if k > 0 {
                    buf[K_FFT - k] = c.conj();
                }
            }
            self.inv.process(&mut buf);
            let off = t * K_HOP;
            for n in 0..K_FFT {
                let w = self.win[n];
                ola[off + n] += buf[n].re / K_FFT as f32 * w;
                wsum[off + n] += w * w;
            }
        }
        (0..out_len)
            .map(|i| {
                let w = wsum[half + i];
                if w > 1e-11 { ola[half + i] / w } else { 0.0 }
            })
            .collect()
    }
}

type KInfer = Box<dyn FnMut(&[f32]) -> Result<Vec<f32>, String>>;

/// Escritorio (Windows/macOS): ONNX Runtime oficial (MIT), SIMD + varios
/// hilos; muy superior a un intérprete en Rust puro para convoluciones.
#[cfg(any(target_os = "windows", target_os = "macos"))]
fn karaoke_backend(model_path: &str) -> Result<KInfer, String> {
    use ort::session::{builder::GraphOptimizationLevel, Session};
    use ort::value::Tensor;
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = (cores * 3 / 4).clamp(2, 16);
    let mut session = Session::builder()
        .map_err(|e| e.to_string())?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| e.to_string())?
        .with_intra_threads(threads)
        .map_err(|e| e.to_string())?
        .commit_from_file(model_path)
        .map_err(|e| format!("Modelo inválido: {e}"))?;
    Ok(Box::new(move |data: &[f32]| {
        let t = Tensor::from_array(([1usize, 4, K_DIM_F, K_DIM_T], data.to_vec()))
            .map_err(|e| e.to_string())?;
        let outs = session.run(ort::inputs![t]).map_err(|e| e.to_string())?;
        let (_, o) = outs[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
        Ok(o.to_vec())
    }))
}

/// Resto de plataformas (Android/iOS): tract, Rust puro (sin binarios nativos
/// que compilar). Más lento; el celular sigue vetado en la UI.
#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn karaoke_backend(model_path: &str) -> Result<KInfer, String> {
    use tract_onnx::prelude::*;
    let model = tract_onnx::onnx()
        .model_for_path(model_path)
        .map_err(|e| format!("Modelo inválido: {e}"))?
        .with_input_fact(0, f32::fact([1, 4, K_DIM_F, K_DIM_T]).into())
        .map_err(|e| e.to_string())?
        .into_optimized()
        .map_err(|e| e.to_string())?
        .into_runnable()
        .map_err(|e| e.to_string())?;
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2);
    let pool = tract_onnx::tract_core::internal::multithread::Executor::multithread((cores / 2).clamp(1, 8));
    Ok(Box::new(move |data: &[f32]| {
        let input = Tensor::from_shape(&[1, 4, K_DIM_F, K_DIM_T], data).map_err(|e| e.to_string())?;
        let out = tract_onnx::tract_core::internal::multithread::multithread_tract_scope(
            pool.clone(),
            || model.run(tvec!(input.into())),
        )
        .map_err(|e| e.to_string())?;
        Ok(out[0].as_slice::<f32>().map_err(|e| e.to_string())?.to_vec())
    }))
}

/// Separa la voz y escribe la pista instrumental como MP3 320 kbps.
/// `model_path` = UVR-MDX-NET-Inst_HQ_3.onnx. Sin Python ni FFmpeg.
pub fn karaoke_separate(input_path: String, model_path: String, output_path: String) -> Result<bool, String> {
    KAR_CANCEL.store(false, Ordering::Relaxed);
    KAR_PROGRESS.store(0, Ordering::Relaxed);

    let dec = decode_channels(&input_path, 0, 1800, 2)?;
    let mut chans: Vec<Vec<f32>> = if dec.ch.len() == 1 { vec![dec.ch[0].clone(), dec.ch[0].clone()] } else { dec.ch };
    if dec.rate != K_RATE {
        for c in chans.iter_mut() {
            let fr: Vec<(f32, f32)> = c.iter().map(|v| (*v, *v)).collect();
            let mut rs = Resampler::new(dec.rate, K_RATE);
            let mut o = Vec::with_capacity(fr.len() * K_RATE as usize / dec.rate as usize + 8);
            rs.process(&fr, &mut o);
            *c = o.into_iter().map(|p| p.0).collect();
        }
    }
    let n = chans[0].len();
    if n < K_RATE as usize {
        return Err("Pista demasiado corta".to_string());
    }

    let mut infer = karaoke_backend(&model_path)?;

    let trim = K_FFT / 2;
    let chunk = K_HOP * (K_DIM_T - 1);
    let gen = chunk - 2 * trim;
    let n_chunks = (n + gen - 1) / gen;
    let total_len = trim * 2 + n_chunks * gen;
    let mut padded: Vec<Vec<f32>> = Vec::with_capacity(2);
    for c in chans.iter().take(2) {
        let mut p = vec![0f32; total_len];
        p[trim..trim + n].copy_from_slice(c);
        padded.push(p);
    }
    drop(chans);

    let stft = KStft::new();
    let plane = K_DIM_F * K_DIM_T;
    let mut result: Vec<Vec<f32>> = vec![Vec::with_capacity(n_chunks * gen); 2];
    let mut data = vec![0f32; 4 * plane];

    for ci in 0..n_chunks {
        if KAR_CANCEL.load(Ordering::Relaxed) {
            return Err("Cancelado".to_string());
        }
        let start = ci * gen;
        for ch in 0..2 {
            let seg = &padded[ch][start..start + chunk];
            let (a, b) = data[(ch * 2) * plane..(ch * 2 + 2) * plane].split_at_mut(plane);
            stft.forward(seg, a, b);
        }
        let o = infer(&data)?;
        for ch in 0..2 {
            let re = &o[(ch * 2) * plane..(ch * 2 + 1) * plane];
            let im = &o[(ch * 2 + 1) * plane..(ch * 2 + 2) * plane];
            let w = stft.inverse(re, im, chunk);
            result[ch].extend(w[trim..trim + gen].iter().map(|v| v * K_COMPENSATE));
        }
        KAR_PROGRESS.store((((ci + 1) * 1000) / n_chunks) as u32, Ordering::Relaxed);
    }

    let tmp = format!("{output_path}.part");
    let mut sink = Mp3Sink::new(&tmp, K_RATE, true, 320)?;
    let mut inter: Vec<f32> = Vec::with_capacity(1 << 20);
    let mut i = 0usize;
    while i < n {
        let end = (i + (1 << 19)).min(n);
        inter.clear();
        for j in i..end {
            inter.push(result[0][j]);
            inter.push(result[1][j]);
        }
        sink.push(&inter, 2)?;
        i = end;
    }
    sink.finish()?;
    let _ = std::fs::remove_file(&output_path);
    std::fs::rename(&tmp, &output_path).map_err(|e| e.to_string())?;
    KAR_PROGRESS.store(1000, Ordering::Relaxed);
    Ok(true)
}

#[cfg(test)]
mod karaoke_tests {
    #[test]
    #[ignore]
    fn separa_pista_real() {
        let inp = std::env::var("KAR_IN").unwrap();
        let model = std::env::var("KAR_MODEL").unwrap();
        let out = std::env::var("KAR_OUT").unwrap();
        let t = std::time::Instant::now();
        std::thread::spawn(|| loop {
            std::thread::sleep(std::time::Duration::from_secs(10));
            println!("PROGRESO {:.1}%", super::karaoke_progress() * 100.0);
        });
        super::karaoke_separate(inp, model, out).unwrap();
        println!("TIEMPO {:?}", t.elapsed());
    }
}
