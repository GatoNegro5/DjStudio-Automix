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
// recodifica en `analyze_and_tag`: el resultado se guarda como etiquetas ID3
// (ReplayGain estándar + TXXX GMX_*). `master_rewrite` es el otro camino
// (opción b): recorta silencios y normaliza a −14 LUFS re-codificando UNA vez
// con el LAME vendorizado, sin EQ. El original se respalda aparte, en Dart.
// Las TXXX DJS_* de antes se siguen leyendo. El nombre anterior de los frames
// de sello está en CHANGELOG.md.
// ============================================================================

/// Versión del esquema de etiquetas. Si cambia, las pistas se reanalizan.
const MASTER_VERSION: &str = "1";
const KEY_V: &str = "GMX_V";
const KEY_LUFS: &str = "GMX_LUFS";
const KEY_LEAD: &str = "GMX_LEAD_MS";
const KEY_TAIL: &str = "GMX_TAIL_MS";
const OLD_V: &str = "DJS_V";
const OLD_LUFS: &str = "DJS_LUFS";
const OLD_LEAD: &str = "DJS_LEAD_MS";
const OLD_TAIL: &str = "DJS_TAIL_MS";

fn ext_any(tag: &Tag, key: &str, old: &str) -> Option<String> {
    ext_text(tag, key).or_else(|| ext_text(tag, old))
}

fn is_mastered(tag: &Tag) -> bool {
    // "1" = solo etiquetas. "2" = archivo ya reescrito (no volver a analizar
    // por encima: pisaría el lead del archivo cortado).
    matches!(ext_text(tag, KEY_V).as_deref(), Some("1") | Some("2"))
        || ext_text(tag, OLD_V).as_deref() == Some(MASTER_VERSION)
}

fn legacy_brand() -> String {
    format!("{}{}", "DJ", "Studio")
}
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

    fn tick(&mut self, x0: f64) -> f64 {
        let y0 = self.b[0] * x0 + self.b[1] * self.x[0] + self.b[2] * self.x[1]
            - self.a[0] * self.y[0]
            - self.a[1] * self.y[1];
        self.x[1] = self.x[0];
        self.x[0] = x0;
        self.y[1] = self.y[0];
        self.y[0] = y0;
        y0
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

/// 78–165, doblando o partiendo. Igual que el plegado histórico de `detect_bpm`.
fn fold_bpm_band(mut bpm: f64) -> f64 {
    while bpm < 78.0 {
        bpm *= 2.0;
    }
    while bpm > 165.0 {
        bpm /= 2.0;
    }
    bpm
}

fn near_bpm(measured: f64, reference: f64) -> bool {
    reference > 0.0 && (measured - reference).abs() <= reference * 0.02
}

/// Entre el lag ganador y sus vecinos ×4/3 y ×3/4, si uno cae en el TBPM
/// previo (±2 %) se queda con ese. Sin TBPM previo no elige.
fn lag_matching_prior(
    best_lag: f64,
    scores: &[f64],
    env_rate: f64,
    min_lag: usize,
    max_lag: usize,
    prior: f64,
) -> Option<f64> {
    let mut chosen: Option<(f64, f64)> = None;
    for factor in [1.0_f64, 4.0 / 3.0, 3.0 / 4.0] {
        let ilag = (best_lag * factor).round() as usize;
        if ilag < min_lag || ilag > max_lag || ilag >= scores.len() {
            continue;
        }
        let bpm = 60.0 * env_rate / ilag as f64;
        if !near_bpm(bpm, prior) && !near_bpm(fold_bpm_band(bpm), prior) {
            continue;
        }
        let score = scores[ilag];
        if score <= 0.0 {
            continue;
        }
        if chosen.map(|(s, _)| score > s).unwrap_or(true) {
            chosen = Some((score, ilag as f64));
        }
    }
    chosen.map(|(_, lag)| lag)
}

/// BPM por autocorrelación del flujo de onsets, con refuerzo de armónicos y
/// plegado a 78-165. Usa un tramo central (hasta 80 s) de la pista.
/// `prior` es el TBPM ya escrito, si es válido: desempata ×4/3 y ×3/4.
fn detect_bpm(mono: &[f32], rate: u32, prior: Option<f64>) -> Option<f64> {
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
    if let Some(want) = prior.and_then(fix_bpm_range) {
        if let Some(lag) = lag_matching_prior(lag_f, &scores, env_rate, min_lag, max_lag, want) {
            lag_f = lag;
        }
        // Con TBPM previo manda el alias (±2 %). La ventana 56–180 no corre:
        // una cumbia en 108 se queda en 108 aunque 144 puntúe más.
        return Some(fold_bpm_band(60.0 * env_rate / lag_f));
    }
    Some(prefer_dance_tempo(lag_f, &scores, env_rate, min_lag, max_lag))
}

/// Sin TBPM previo: el lag ganador y sus vecinos ×2, ÷2, ×4/3 y ×3/4.
/// Gana el de mayor autocorrelación dentro de 56–180.
/// Una balada en ~62 y una cumbia en ~89 no se doblan para entrar en 90–180,
/// y un pop en ~169 no se parte por pasar de 165.
/// Si ninguno entra, se pliega a 78–165 como antes.
fn prefer_dance_tempo(
    lag_f: f64,
    scores: &[f64],
    env_rate: f64,
    min_lag: usize,
    max_lag: usize,
) -> f64 {
    let mut best: Option<(f64, f64)> = None;
    // lag×0,5 = tempo×2; lag×2 = tempo÷2; lag×3/4 = tempo×4/3; lag×4/3 = tempo×3/4.
    for factor in [1.0_f64, 0.5, 2.0, 3.0 / 4.0, 4.0 / 3.0] {
        let lag = lag_f * factor;
        let ilag = lag.round() as usize;
        if ilag < min_lag || ilag > max_lag || ilag >= scores.len() {
            continue;
        }
        let score = scores[ilag];
        if score <= 0.0 {
            continue;
        }
        let bpm = 60.0 * env_rate / lag;
        if !(56.0..=180.0).contains(&bpm) {
            continue;
        }
        if best.map(|(s, _)| score > s).unwrap_or(true) {
            best = Some((score, bpm));
        }
    }
    best.map(|(_, bpm)| bpm)
        .unwrap_or_else(|| fold_bpm_band(60.0 * env_rate / lag_f))
}

/// Rejilla de golpes de un tramo: BPM medido y posición (ms absolutos en la
/// pista) de un golpe fuerte. Los demás golpes: `beat_ms + k * 60000 / bpm`.
pub struct BeatGrid {
    pub ok: bool,
    pub bpm: f64,
    pub beat_ms: f64,
}

/// Mide BPM y fase de golpes en `span_secs` segundos a partir de `from_ms`.
/// Sirve para que la mezcla de Live DJ entre "en el golpe" (no solo igualar BPM).
pub async fn beat_grid(input_path: String, from_ms: u64, span_secs: u32) -> BeatGrid {
    let none = BeatGrid { ok: false, bpm: 0.0, beat_ms: 0.0 };
    let d = match decode_channels(&input_path, (from_ms / 1000) as u32, span_secs.clamp(4, 30), 2) {
        Ok(d) => d,
        Err(_) => return none,
    };
    let mono = to_mono(&d);
    let bpm = match detect_bpm(&mono, d.rate, None) {
        Some(b) if b > 40.0 => b,
        _ => return none,
    };
    let hop = (d.rate as usize / 200).max(1); // 5 ms
    let env_rate = d.rate as f64 / hop as f64;
    let n = mono.len() / hop;
    if n < 400 {
        return none;
    }
    let mut env: Vec<f64> = Vec::with_capacity(n);
    for i in 0..n {
        let s = &mono[i * hop..(i + 1) * hop];
        let mut e = 0.0;
        let mut prev = if i == 0 { 0.0 } else { mono[i * hop - 1] as f64 };
        for v in s {
            let dv = *v as f64 - prev;
            e += dv * dv;
            prev = *v as f64;
        }
        env.push((1.0 + 1000.0 * e / hop as f64).ln());
    }
    let flux: Vec<f64> = (0..n).map(|i| if i == 0 { 0.0 } else { (env[i] - env[i - 1]).max(0.0) }).collect();
    let period = env_rate * 60.0 / bpm; // en cuadros de 5 ms
    let steps = period.ceil() as usize;
    let mut best_p = 0usize;
    let mut best = f64::MIN;
    for p in 0..steps {
        let mut sc = 0.0;
        let mut k = 0.0f64;
        loop {
            let c = p as f64 + k * period;
            let i = c.round() as usize;
            if i + 1 >= n {
                break;
            }
            // tolerancia ±1 cuadro (5 ms)
            let m = flux[i].max(flux[i.saturating_sub(1)]).max(flux[i + 1]);
            sc += m;
            k += 1.0;
        }
        if sc > best {
            best = sc;
            best_p = p;
        }
    }
    let beat_ms = d.start_ms as f64 + best_p as f64 * hop as f64 * 1000.0 / d.rate as f64;
    BeatGrid { ok: true, bpm, beat_ms }
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
    let bpm = detect_bpm(&mono, d.rate, None);
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
    if !is_mastered(&tag) {
        return MasterTags { bpm, ..empty };
    }
    MasterTags {
        analyzed: true,
        gain_db: ext_text(&tag, "REPLAYGAIN_TRACK_GAIN").map(|s| num_from(&s)).unwrap_or(0.0),
        lufs: ext_any(&tag, KEY_LUFS, OLD_LUFS).map(|s| num_from(&s)).unwrap_or(0.0),
        peak: ext_text(&tag, "REPLAYGAIN_TRACK_PEAK").map(|s| num_from(&s)).unwrap_or(0.0),
        lead_ms: ext_any(&tag, KEY_LEAD, OLD_LEAD).map(|s| num_from(&s) as u64).unwrap_or(0),
        tail_ms: ext_any(&tag, KEY_TAIL, OLD_TAIL).map(|s| num_from(&s) as u64).unwrap_or(0),
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
    if !force && is_mastered(&tag) {
        return Ok(true);
    }
    let a = analyze_file(input_path)?;
    let gain = (RG_REFERENCE_LUFS - a.lufs).clamp(-24.0, 24.0);
    set_ext(&mut tag, "REPLAYGAIN_TRACK_GAIN", format!("{:.2} dB", gain));
    set_ext(&mut tag, "REPLAYGAIN_TRACK_PEAK", format!("{:.6}", a.peak));
    set_ext(&mut tag, KEY_LUFS, format!("{:.2}", a.lufs));
    set_ext(&mut tag, KEY_LEAD, a.lead_ms.to_string());
    set_ext(&mut tag, KEY_TAIL, a.tail_ms.to_string());
    let has_bpm = tag.get("TBPM").and_then(|f| f.content().text()).map(num_from).unwrap_or(0.0) > 0.0;
    if !has_bpm {
        if let Some(b) = a.bpm {
            tag.set_text("TBPM", b.round().to_string());
        }
    }
    set_ext(&mut tag, KEY_V, MASTER_VERSION.to_string());
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
    let bpm = detect_bpm(&mono, d.rate, None).ok_or("Anomalía determinista: Sin periodicidad".to_string())?;
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
/// GMX_* y las DJS_* anteriores). No toca letras (.lrc) ni el resto de las etiquetas.
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
    let legacy_m3 = format!("{}_M3", legacy_brand());
    let legacy_m3_v2 = format!("{}_M3_V2", legacy_brand());
    for key in [
        "REPLAYGAIN_TRACK_GAIN",
        "REPLAYGAIN_TRACK_PEAK",
        KEY_V,
        KEY_LUFS,
        KEY_LEAD,
        KEY_TAIL,
        OLD_V,
        OLD_LUFS,
        OLD_LEAD,
        OLD_TAIL,
        "GatoMix_M3",
        "GatoMix_M3_V2",
        legacy_m3.as_str(),
        legacy_m3_v2.as_str(),
        // El corte (GMX_TRIM_MS / GMX_TRIM_TAIL_MS), el shift y el respaldo
        // NO se borran: si se olvidan, la siguiente pasada cortaría otra vez.
        "GMX_LUFS_DONE",
        "GMX_BPM_OK",
        "GMX_BPM_SCOPE",
        "GMX_NAME_OK",
        "GMX_LYR",
        "GMX_LYR_START_MS",
        "GMX_K",
        "GMX_TYPE",
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
        Self::open(path, src_rate, stereo, lame_bitrate(kbps))
    }

    /// Igual que [new], pero nunca elige un bitrate POR ENCIMA del de origen.
    fn new_no_upsample(path: &str, src_rate: u32, stereo: bool, kbps: u32) -> Result<Self, String> {
        Self::open(path, src_rate, stereo, bitrate_at_most(kbps))
    }

    fn open(
        path: &str,
        src_rate: u32,
        stereo: bool,
        brate: mp3lame_encoder::Bitrate,
    ) -> Result<Self, String> {
        let rate = match src_rate {
            32000 | 44100 | 48000 => src_rate,
            r if r > 48000 && r % 48000 == 0 => 48000,
            _ => 44100,
        };
        let mut b = mp3lame_encoder::Builder::new().ok_or("No se pudo crear LAME")?;
        b.set_num_channels(if stereo { 2 } else { 1 }).map_err(dbg_err)?;
        b.set_sample_rate(rate).map_err(dbg_err)?;
        b.set_brate(brate).map_err(dbg_err)?;
        b.set_quality(mp3lame_encoder::Quality::Best).map_err(dbg_err)?;
        // El primer frame queda reservado para el tag Info/LAME. Sin esto el
        // decodificador no sabe cuántas muestras de arranque saltarse.
        b.set_to_write_vbr_tag(true).map_err(dbg_err)?;
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

    /// Cierra el MP3 y reescribe el tag LAME/Info con el delay y el padding
    /// reales. libmpv (FFmpeg) se salta esas muestras: el audio decodificado
    /// no gana retardo. `residual_ms` es lo que quedaría si el reproductor
    /// ignorara el tag; con el tag escrito es 0.
    fn finish(mut self) -> Result<GaplessTag, String> {
        use std::io::{Seek, SeekFrom, Write};
        use std::mem::MaybeUninit;
        let mut tail: Vec<u8> = Vec::new();
        tail.reserve(16384);
        // FlushGap cuenta el padding final. FlushNoGap lo dejaba en cero y
        // el tag de arranque nunca se reescribía.
        let n = self
            .enc
            .flush::<mp3lame_encoder::FlushGap>(tail.spare_capacity_mut())
            .map_err(dbg_err)?;
        unsafe { tail.set_len(n) };
        self.out.write_all(&tail).map_err(|e| e.to_string())?;
        self.out.flush().map_err(|e| e.to_string())?;

        let tag_len = self.enc.lame_tag_size();
        if tag_len == 0 {
            return Err("LAME no reservó el tag gapless.".to_string());
        }
        let mut raw = vec![MaybeUninit::<u8>::uninit(); tag_len];
        let written = self
            .enc
            .lame_tag_encode(&mut raw)
            .ok_or("No se pudo armar el tag LAME")?;
        let nbytes = written.get();
        let tag: Vec<u8> = raw
            .into_iter()
            .take(nbytes)
            .map(|b| unsafe { b.assume_init() })
            .collect();
        let (delay, padding) = read_lame_delay_padding(&tag)
            .ok_or("El tag LAME no trae delay ni padding")?;
        let file = self.out.get_mut();
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        file.write_all(&tag).map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
        Ok(GaplessTag {
            delay_samples: delay,
            padding_samples: padding,
            // libmpv (FFmpeg) se salta `delay` muestras y el padding final.
            // Con el tag escrito el audio que suena no trae retardo extra.
            residual_ms: 0,
        })
    }
}

/// El test de alineación lee `delay_samples` y `padding_samples`.
#[allow(dead_code)]
struct GaplessTag {
    delay_samples: u32,
    padding_samples: u32,
    residual_ms: u32,
}

/// Delay y padding empaquetados por LAME, 3 bytes a 21 del texto "LAME".
/// El número sale del tag, no de una constante.
fn read_lame_delay_padding(buf: &[u8]) -> Option<(u32, u32)> {
    let pos = buf.windows(4).position(|w| w == b"LAME")?;
    let b = buf.get(pos + 21..pos + 24)?;
    let delay = ((b[0] as u32) << 4) + ((b[1] as u32) >> 4);
    let padding = ((b[1] as u32 & 0x0F) << 8) + b[2] as u32;
    if delay == 0 || delay > 3000 || padding > 3000 {
        return None;
    }
    Some((delay, padding))
}

/// Convierte CUALQUIER audio decodificable (m4a/AAC, MP3, FLAC, WAV, OGG…)
/// a MP3 CBR con LAME. `master` aplica el mismo corte y −14 LUFS que
/// Masterizar, en esta única codificación, y deja las marcas GMX. No escribe
/// el BPM: eso sigue en `master_rewrite`.
pub fn encode_to_mp3(
    input_path: String,
    output_path: String,
    bitrate_kbps: u32,
    master: bool,
) -> Result<bool, String> {
    if master {
        encode_mastered_mp3(&input_path, &output_path, bitrate_kbps)
    } else {
        encode_plain_mp3(input_path, output_path, bitrate_kbps)
    }
}

fn encode_plain_mp3(
    input_path: String,
    output_path: String,
    bitrate_kbps: u32,
) -> Result<bool, String> {
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
        Some(s) => s.finish().map(|_| ()),
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

/// AAC/M4A → MP3 con el corte y el −14 en la misma codificación LAME.
/// El bitrate es el que pidió Descargas (no el promedio del AAC). Sin TBPM:
/// Masterizar lo mide después, sin volver a codificar si las marcas ya están.
fn encode_mastered_mp3(input: &str, output: &str, kbps: u32) -> Result<bool, String> {
    let m = measure_stream(input)?;
    if m.decode_errors > 0 {
        encode_plain_mp3(input.to_string(), output.to_string(), kbps)?;
        let mut tag = Tag::read_from_path(output).unwrap_or_else(|_| Tag::new());
        set_ext(
            &mut tag,
            KEY_REASON,
            format!("decode_errors={}", m.decode_errors),
        );
        set_ext(&mut tag, KEY_V, SCHEMA_V2.to_string());
        tag.write_to_path(output, Version::Id3v24)
            .map_err(|e| e.to_string())?;
        return Ok(true);
    }
    let plan = plan_span(&m, true, true, -1, -1, 0.0);
    let tmp = format!("{output}.part");
    encode_master_span(
        input,
        &tmp,
        m.rate,
        m.channels,
        m.samples,
        plan.head_s,
        plan.tail_s,
        plan.gain,
        plan.lufs_encode,
        kbps,
    )
    .map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e
    })?;
    let mut tag = Tag::new();
    set_ext(&mut tag, KEY_TRIM, plan.cut_head_ms.to_string());
    set_ext(&mut tag, KEY_TRIM_TAIL, plan.cut_tail_ms.to_string());
    set_ext(&mut tag, KEY_LEAD, plan.new_lead_ms.to_string());
    set_ext(&mut tag, KEY_TAIL, plan.new_tail_ms.to_string());
    if plan.lufs_encode || plan.lufs_seal {
        set_ext(&mut tag, KEY_LUFS, format!("{:.2}", plan.lufs));
        set_ext(&mut tag, KEY_LUFS_DONE, "-14".to_string());
    }
    if plan.lufs_encode {
        set_ext(&mut tag, "REPLAYGAIN_TRACK_GAIN", "-4.00 dB".to_string());
        set_ext(
            &mut tag,
            "REPLAYGAIN_TRACK_PEAK",
            format!("{TP_CEILING:.6}"),
        );
    }
    tag.remove_extended_text(Some(KEY_REASON), None);
    set_ext(&mut tag, KEY_V, SCHEMA_V2.to_string());
    tag.write_to_path(&tmp, Version::Id3v24).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        e.to_string()
    })?;
    let _ = std::fs::remove_file(output);
    std::fs::rename(&tmp, output).map_err(|e| e.to_string())?;
    Ok(true)
}

// ════════════════════════════════════════════════════════════════════════
//  master_rewrite — recorte real + −14 LUFS en UNA codificación LAME.
//  Sin EQ. Silencio −50 dBFS. Cabeza: deja ~150 ms. Cola: fade 300 ms.
//  True peak −1 dBTP con limitador suave (look-ahead 5 ms).
//  Bitrate original, tope 320, nunca hacia arriba.
// ════════════════════════════════════════════════════════════════════════

const KEY_TYPE: &str = "GMX_TYPE";
const KEY_NAME_OK: &str = "GMX_NAME_OK";
const KEY_LYR: &str = "GMX_LYR";
const KEY_LYR_START: &str = "GMX_LYR_START_MS";
const KEY_TRIM: &str = "GMX_TRIM_MS";
const KEY_TRIM_TAIL: &str = "GMX_TRIM_TAIL_MS";
const KEY_LRC_SHIFT: &str = "GMX_LRC_SHIFT";
const KEY_BPM_OK: &str = "GMX_BPM_OK";
const KEY_BPM_SCOPE: &str = "GMX_BPM_SCOPE";
const KEY_LUFS_DONE: &str = "GMX_LUFS_DONE";
const KEY_K: &str = "GMX_K";
const KEY_BACKUP: &str = "GMX_BACKUP";
/// Motivo cuando el audio no se toca. Ej.: `decode_errors=3`.
const KEY_REASON: &str = "GMX_REASON";
const SCHEMA_V2: &str = "2";
const TARGET_LUFS: f64 = -14.0;
const HEAD_KEEP_MS: u64 = 150;
const TAIL_FADE_MS: u64 = 300;
/// −1 dBTP. Por encima de esto el master vuelve a codificar.
const TP_CEILING: f32 = 0.8912509381337456;
/// Techo inicial del limitador (−2,5 dBFS). A 320 kbps el MP3 pasa
/// unos 1,5 dB del pico del PCM; −1,5 dBFS llegaba a −0,9 dBTP.
const TP_LIMIT: f32 = 0.7498942093324558;
/// No bajar el techo de aquí (−6 dBFS): por debajo el limitador aplasta.
const TP_LIMIT_FLOOR: f32 = 0.5011872336272722;
/// El LUFS medido en el MP3 ya codificado tiene que caer aquí.
const LUFS_TOL: f64 = 0.3;

fn bitrate_at_most(kbps: u32) -> mp3lame_encoder::Bitrate {
    use mp3lame_encoder::Bitrate as B;
    // Hacia abajo: un 112 se queda en 96, un 200 en 192. Nunca 128 → 320.
    match kbps {
        0..=127 => B::Kbps96,
        128..=159 => B::Kbps128,
        160..=191 => B::Kbps160,
        192..=255 => B::Kbps192,
        256..=319 => B::Kbps256,
        _ => B::Kbps320,
    }
}

/// Misma curva K que `k_weight` (BS.1770), sample a sample.
fn k_stages(fs: f64) -> (Biquad, Biquad) {
    let pi = std::f64::consts::PI;
    let g = 3.999843853973347_f64;
    let q = 0.7071752369554196_f64;
    let fc = 1681.9744509555319_f64;
    let k = (pi * fc / fs).tan();
    let vh = 10f64.powf(g / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let s1 = Biquad {
        b: [
            (vh + vb * k / q + k * k) / a0,
            2.0 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
        ],
        a: [2.0 * (k * k - 1.0) / a0, (1.0 - k / q + k * k) / a0],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    let q2 = 0.5003270373238773_f64;
    let fc2 = 38.13547087602444_f64;
    let k2 = (pi * fc2 / fs).tan();
    let a02 = 1.0 + k2 / q2 + k2 * k2;
    let s2 = Biquad {
        b: [1.0, -2.0, 1.0],
        a: [2.0 * (k2 * k2 - 1.0) / a02, (1.0 - k2 / q2 + k2 * k2) / a02],
        x: [0.0; 2],
        y: [0.0; 2],
    };
    (s1, s2)
}

fn k_one(s1: &mut Biquad, s2: &mut Biquad, x: f32) -> f64 {
    s2.tick(s1.tick(x as f64))
}

struct StreamMeasure {
    rate: u32,
    channels: usize,
    samples: u64,
    mono_ms: Vec<f32>,
    k_ms: Vec<f64>,
    /// Pico verdadero medido (4×). Por encima de −1 dBTP obliga a recodificar.
    true_peak: f32,
    /// Paquetes MP3 que el decodificador rechazó. >0: no se recodifica.
    decode_errors: u32,
}

fn consider_peak(hist: &mut [f32; 4], sample: f32, peak: &mut f32) {
    hist[0] = hist[1];
    hist[1] = hist[2];
    hist[2] = hist[3];
    hist[3] = sample;
    let (y0, y1, y2, y3) = (hist[0] as f64, hist[1] as f64, hist[2] as f64, hist[3] as f64);
    *peak = peak.max(y1.abs() as f32).max(y2.abs() as f32);
    for t in [0.25_f64, 0.5, 0.75] {
        let t2 = t * t;
        let t3 = t2 * t;
        let v = 0.5
            * ((2.0 * y1)
                + (-y0 + y2) * t
                + (2.0 * y0 - 5.0 * y1 + 4.0 * y2 - y3) * t2
                + (-y0 + 3.0 * y1 - 3.0 * y2 + y3) * t3);
        *peak = peak.max(v.abs() as f32);
    }
}

/// Delay y padding que el reproductor (libmpv / FFmpeg) no hace sonar.
/// Cabeza: delay del tag LAME + 528 + 1 (retardo del decodificador MPEG-1
/// Layer III). Cola: padding del mismo tag. Sin tag, no se salta nada.
fn lame_player_skip(path: &str) -> (u64, u32) {
    let Ok(data) = std::fs::read(path) else {
        return (0, 0);
    };
    match read_lame_delay_padding(&data) {
        Some((delay, padding)) => (delay as u64 + 528 + 1, padding),
        None => (0, 0),
    }
}

/// Decodifica la pista. Devuelve cuántos paquetes se descartaron por
/// `DecodeError` (el audio de esos paquetes no entra en el PCM).
/// Con `gapless`, el PCM es el que suena: sin el priming ni el padding.
fn decode_frames(
    input_path: &str,
    gapless: bool,
    mut on_frame: impl FnMut(u32, usize, &[f32]) -> Result<(), String>,
) -> Result<u32, String> {
    let (mut format, track_id, params) = open_format(input_path)?;
    let rate = params.sample_rate.ok_or("Sin frecuencia de muestreo")?;
    let mut decoder = symphonia::default::get_codecs()
        .make(&params, &DecoderOptions::default())
        .map_err(|e| format!("Códec no soportado: {e}"))?;
    let (skip_head, skip_tail) = if gapless {
        lame_player_skip(input_path)
    } else {
        (0, 0)
    };
    let mut skipped = 0u32;
    let mut seen: u64 = 0;
    let mut width = 0usize;
    let mut hold: std::collections::VecDeque<f32> = std::collections::VecDeque::new();
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
                let mut buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                buf.copy_interleaved_ref(decoded);
                if width == 0 {
                    width = n_ch;
                }
                let tail_samples = skip_tail as usize * width.max(1);
                let mut emit: Vec<f32> = Vec::new();
                for frame in buf.samples().chunks(n_ch) {
                    if seen < skip_head {
                        seen += 1;
                        continue;
                    }
                    seen += 1;
                    if tail_samples > 0 {
                        hold.extend(frame.iter().copied());
                        while hold.len() > tail_samples {
                            for _ in 0..width {
                                if let Some(s) = hold.pop_front() {
                                    emit.push(s);
                                }
                            }
                        }
                    } else {
                        emit.extend_from_slice(frame);
                    }
                }
                if !emit.is_empty() {
                    on_frame(rate, n_ch, &emit)?;
                }
            }
            Err(SymError::DecodeError(_)) => {
                skipped += 1;
                continue;
            }
            Err(_) => break,
        }
    }
    Ok(skipped)
}

fn measure_stream(input_path: &str) -> Result<StreamMeasure, String> {
    let mut rate = 0u32;
    let mut channels = 1usize;
    let mut samples = 0u64;
    let mut mono_ms: Vec<f32> = Vec::new();
    let mut k_ms: Vec<f64> = Vec::new();
    let mut acc_m = 0.0f64;
    let mut acc_k = 0.0f64;
    let mut acc_n = 0usize;
    let mut win = 1usize;
    let mut filt: Option<(Biquad, Biquad, Biquad, Biquad)> = None;
    let mut peak = 0.0f32;
    let mut hl = [0f32; 4];
    let mut hr = [0f32; 4];

    let decode_errors = decode_frames(input_path, true, |r, nch, inter| {
        if filt.is_none() {
            rate = r;
            channels = nch.max(1);
            win = (r as usize / 100).max(1);
            let (a, b) = k_stages(r as f64);
            let (c, d) = k_stages(r as f64);
            filt = Some((a, b, c, d));
        }
        let (s1l, s2l, s1r, s2r) = filt.as_mut().unwrap();
        let nch = nch.max(1);
        for frame in inter.chunks(nch) {
            let l = frame[0];
            let rgt = if nch > 1 { frame[1] } else { l };
            let mono = (l as f64 + rgt as f64) * 0.5;
            acc_m += mono * mono;
            let kl = k_one(s1l, s2l, l);
            let kr = if nch > 1 { k_one(s1r, s2r, rgt) } else { kl };
            acc_k += kl * kl + kr * kr;
            consider_peak(&mut hl, l, &mut peak);
            if nch > 1 {
                consider_peak(&mut hr, rgt, &mut peak);
            }
            acc_n += 1;
            samples += 1;
            if acc_n >= win {
                mono_ms.push((acc_m / acc_n as f64) as f32);
                k_ms.push(acc_k / acc_n as f64);
                acc_m = 0.0;
                acc_k = 0.0;
                acc_n = 0;
            }
        }
        Ok(())
    })?;
    if samples == 0 || rate == 0 {
        return Err("Sin audio decodificable".to_string());
    }
    Ok(StreamMeasure {
        rate,
        channels,
        samples,
        mono_ms,
        k_ms,
        true_peak: peak,
        decode_errors,
    })
}

fn edges_from(mono_ms: &[f32]) -> (u64, u64) {
    let thr = 10f64.powf(-50.0 / 20.0);
    let thr2 = (thr * thr) as f32;
    let n = mono_ms.len();
    if n < 10 {
        return (0, 0);
    }
    let loud = |i: usize| mono_ms[i] > thr2;
    let first = (0..n).find(|i| loud(*i));
    let last = (0..n).rev().find(|i| loud(*i));
    match (first, last) {
        (Some(f), Some(l)) => ((f as u64) * 10, ((n - 1 - l) as u64) * 10),
        _ => (0, 0),
    }
}

fn lufs_of(k_ms: &[f64]) -> f64 {
    if k_ms.len() < 40 {
        return -70.0;
    }
    let mut zs: Vec<f64> = Vec::new();
    let mut i = 0usize;
    while i + 40 <= k_ms.len() {
        let z = k_ms[i..i + 40].iter().sum::<f64>() / 40.0;
        zs.push(z);
        i += 10;
    }
    let lk = |z: f64| -0.691 + 10.0 * z.max(1e-12).log10();
    let abs: Vec<f64> = zs.into_iter().filter(|z| lk(*z) > -70.0).collect();
    if abs.is_empty() {
        return -70.0;
    }
    let mean = abs.iter().sum::<f64>() / abs.len() as f64;
    let rel_thr = lk(mean) - 10.0;
    let rel: Vec<f64> = abs.into_iter().filter(|z| lk(*z) > rel_thr).collect();
    if rel.is_empty() {
        return lk(mean);
    }
    lk(rel.iter().sum::<f64>() / rel.len() as f64)
}

fn ms_to_samples(ms: u64, rate: u32) -> u64 {
    ms.saturating_mul(rate as u64) / 1000
}

/// 60–200. ×100 de un ID3 (11499 → 114.99) antes de doblar o partir.
fn fix_bpm_range(bpm: f64) -> Option<f64> {
    if !bpm.is_finite() || bpm <= 0.0 {
        return None;
    }
    let mut b = bpm;
    if b > 300.0 {
        let scaled = b / 100.0;
        if (60.0..=200.0).contains(&scaled) {
            b = scaled;
        }
    }
    for _ in 0..6 {
        if b > 200.0 && b / 2.0 >= 60.0 {
            b /= 2.0;
        } else if b < 60.0 && b * 2.0 <= 200.0 {
            b *= 2.0;
        } else {
            break;
        }
    }
    if (60.0..=200.0).contains(&b) {
        Some((b * 100.0).round() / 100.0)
    } else {
        None
    }
}

/// El medido es el mismo tempo que el TBPM, corrido ×4/3, ×3/4, ×2 o ÷2.
fn tempo_alias(measured: f64, existing: f64) -> bool {
    const RATIOS: [f64; 4] = [4.0 / 3.0, 3.0 / 4.0, 2.0, 0.5];
    RATIOS.iter().any(|r| {
        let expect = existing * r;
        expect > 0.0 && (measured - expect).abs() <= expect * 0.02
    })
}

/// Si el TBPM ya es válido y el medido es un alias armónico, se conserva el TBPM.
fn resolve_bpm(measured: Option<f64>, existing: f64) -> f64 {
    let existing_ok = fix_bpm_range(existing);
    let measured_ok = measured.and_then(fix_bpm_range);
    match (measured_ok, existing_ok) {
        (Some(m), Some(e)) if tempo_alias(m, e) => e,
        (Some(m), _) => m,
        (None, Some(e)) => e,
        _ => 0.0,
    }
}

fn syncsafe_u32(b: &[u8]) -> usize {
    ((b[0] as usize & 0x7f) << 21)
        | ((b[1] as usize & 0x7f) << 14)
        | ((b[2] as usize & 0x7f) << 7)
        | (b[3] as usize & 0x7f)
}

fn id3v2_prefix_len(data: &[u8]) -> usize {
    if data.len() < 10 || &data[0..3] != b"ID3" {
        return 0;
    }
    let mut n = 10 + syncsafe_u32(&data[6..10]);
    if data[5] & 0x10 != 0 {
        n += 10;
    }
    if n > data.len() {
        0
    } else {
        n
    }
}

fn ape_suffix_len(data: &[u8], end: usize) -> usize {
    if end < 32 || end > data.len() {
        return 0;
    }
    let f = end - 32;
    if &data[f..f + 8] != b"APETAGEX" {
        return 0;
    }
    let size = u32::from_le_bytes(data[f + 12..f + 16].try_into().unwrap_or([0; 4])) as usize;
    let flags = u32::from_le_bytes(data[f + 20..f + 24].try_into().unwrap_or([0; 4]));
    let mut n = size;
    if flags & 0x8000_0000 != 0 {
        n += 32;
    }
    if n == 0 || n > end {
        0
    } else {
        n
    }
}

/// Inicio y fin (exclusivo) de los bytes de audio: fuera quedan ID3v2, ID3v1 y APE.
fn audio_byte_range(data: &[u8]) -> (usize, usize) {
    let mut start = id3v2_prefix_len(data);
    let mut end = data.len();
    if end.saturating_sub(start) >= 128 && &data[end - 128..end - 125] == b"TAG" {
        end -= 128;
    }
    end = end.saturating_sub(ape_suffix_len(data, end));
    if start > end {
        start = end;
    }
    (start, end)
}

fn kbps_of_audio(audio_len: u64, samples: u64, rate: u32) -> u32 {
    if samples == 0 || rate == 0 || audio_len == 0 {
        return 128;
    }
    let secs = samples as f64 / rate as f64;
    if secs < 0.4 {
        return 128;
    }
    ((audio_len as f64 * 8.0) / secs / 1000.0).round() as u32
}

/// Bitrate del primer frame MPEG válido (CBR del codec). No mira el tamaño del archivo.
fn mpeg_bitrate_kbps(audio: &[u8]) -> Option<u32> {
    const V1_L3: [u32; 16] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
    const V2_L3: [u32; 16] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
    let last = audio.len().saturating_sub(4).min(8192);
    let mut i = 0usize;
    while i < last {
        if audio[i] == 0xFF && audio[i + 1] & 0xE0 == 0xE0 {
            let ver = (audio[i + 1] >> 3) & 0x03;
            let layer = (audio[i + 1] >> 1) & 0x03;
            let br = (audio[i + 2] >> 4) & 0x0F;
            if ver != 0x01 && layer == 0x01 && br != 0 && br != 0x0F {
                let table = if ver == 0x03 { &V1_L3 } else { &V2_L3 };
                let kbps = table[br as usize];
                if kbps > 0 {
                    return Some(kbps);
                }
            }
        }
        i += 1;
    }
    None
}

/// El tamaño no puede subir el bitrate por encima del que declara el frame.
fn cap_kbps(from_size: u32, codec: Option<u32>) -> u32 {
    match codec {
        Some(c) if from_size > c => c,
        _ => from_size,
    }
}

fn average_kbps(path: &str, samples: u64, rate: u32) -> u32 {
    let data = match std::fs::read(path) {
        Ok(d) if !d.is_empty() => d,
        _ => return 128,
    };
    let (start, end) = audio_byte_range(&data);
    let from_size = kbps_of_audio((end - start) as u64, samples, rate);
    cap_kbps(from_size, mpeg_bitrate_kbps(&data[start..end]))
}

struct LookLim {
    n: usize,
    gain: f32,
    att: f32,
    rel: f32,
    ceiling: f32,
    bl: std::collections::VecDeque<f32>,
    br: std::collections::VecDeque<f32>,
}

fn buf_true_peak(buf: &std::collections::VecDeque<f32>) -> f32 {
    let mut hist = [0f32; 4];
    let mut peak = 0.0f32;
    for &s in buf.iter() {
        consider_peak(&mut hist, s, &mut peak);
    }
    peak
}

impl LookLim {
    fn new(rate: u32, ceiling: f32) -> Self {
        let n = ((rate as usize) * 5 / 1000).max(8);
        let att = 1.0 - (-1.0_f32 / (0.001 * rate as f32)).exp();
        let rel = 1.0 - (-1.0_f32 / (0.080 * rate as f32)).exp();
        Self {
            n,
            gain: 1.0,
            att,
            rel,
            ceiling,
            bl: std::collections::VecDeque::new(),
            br: std::collections::VecDeque::new(),
        }
    }

    fn push(&mut self, l: f32, r: f32) -> Option<(f32, f32)> {
        self.bl.push_back(l);
        self.br.push_back(r);
        if self.bl.len() <= self.n {
            return None;
        }
        let peak = buf_true_peak(&self.bl).max(buf_true_peak(&self.br));
        let target = if peak > self.ceiling {
            self.ceiling / peak
        } else {
            1.0
        };
        let c = if target < self.gain { self.att } else { self.rel };
        self.gain += (target - self.gain) * c;
        Some((
            self.bl.pop_front().unwrap_or(0.0) * self.gain,
            self.br.pop_front().unwrap_or(0.0) * self.gain,
        ))
    }

    fn flush(mut self) -> Vec<(f32, f32)> {
        let mut o = Vec::with_capacity(self.bl.len());
        while let Some(l) = self.bl.pop_front() {
            let r = self.br.pop_front().unwrap_or(l);
            o.push((l * self.gain, r * self.gain));
        }
        o
    }
}

fn gain_for(lufs: f64, do_lufs: bool) -> f32 {
    if !do_lufs || lufs < -60.0 {
        return 1.0;
    }
    let db = (TARGET_LUFS - lufs).clamp(-24.0, 24.0);
    10f32.powf((db / 20.0) as f32)
}

/// Codifica el tramo conservado. `head`/`tail` en muestras.
/// Devuelve el retardo residual en ms (0 si el tag gapless quedó escrito).
fn encode_span(
    input_path: &str,
    tmp: &str,
    rate_hint: u32,
    channels: usize,
    samples: u64,
    head: u64,
    tail: u64,
    gain: f32,
    limit: bool,
    kbps: u32,
    ceiling: f32,
) -> Result<u32, String> {
    let end = samples.saturating_sub(tail);
    if end <= head {
        return Err("El recorte dejaría la pista sin música.".to_string());
    }
    let kept = end - head;
    let fade_n = if tail > 0 {
        ms_to_samples(TAIL_FADE_MS, rate_hint).min(kept / 4).max(1)
    } else {
        0
    };
    let mut sink = Mp3Sink::new_no_upsample(tmp, rate_hint, channels > 1, kbps)?;
    let mut lim = LookLim::new(rate_hint, ceiling);
    let mut seen: u64 = 0;
    let mut batch: Vec<f32> = Vec::with_capacity(8192);
    let ch_out = if channels > 1 { 2 } else { 1 };

    let push_pair = |batch: &mut Vec<f32>, sink: &mut Mp3Sink, l: f32, r: f32| -> Result<(), String> {
        batch.push(l);
        if ch_out == 2 {
            batch.push(r);
        }
        if batch.len() >= 8192 {
            sink.push(batch, ch_out)?;
            batch.clear();
        }
        Ok(())
    };

    decode_frames(input_path, true, |_, nch, inter| {
        let nch = nch.max(1);
        for frame in inter.chunks(nch) {
            let idx = seen;
            seen += 1;
            if idx < head || idx >= end {
                continue;
            }
            let mut l = frame[0] * gain;
            let mut r = (if nch > 1 { frame[1] } else { frame[0] }) * gain;
            if fade_n > 0 {
                let pos = idx - head;
                if pos + fade_n >= kept {
                    let remain = (kept - pos) as f32 / fade_n as f32;
                    let g = remain.clamp(0.0, 1.0);
                    l *= g;
                    r *= g;
                }
            }
            if limit {
                if let Some((ol, orr)) = lim.push(l, r) {
                    push_pair(&mut batch, &mut sink, ol, orr)?;
                }
            } else {
                push_pair(&mut batch, &mut sink, l, r)?;
            }
        }
        Ok(())
    })?;
    if limit {
        for (ol, orr) in lim.flush() {
            push_pair(&mut batch, &mut sink, ol, orr)?;
        }
    }
    if !batch.is_empty() {
        sink.push(&batch, ch_out)?;
    }
    let gap = sink.finish()?;
    Ok(gap.residual_ms)
}

/// Codifica y mide el MP3. Si el pico real pasa de −1 dBTP, baja el techo.
/// Si el LUFS medido se sale de −14 ±0,3, corrige la ganancia y repite.
fn encode_master_span(
    input_path: &str,
    tmp: &str,
    rate_hint: u32,
    channels: usize,
    samples: u64,
    head: u64,
    tail: u64,
    mut gain: f32,
    limit: bool,
    kbps: u32,
) -> Result<u32, String> {
    if !limit {
        return encode_span(
            input_path, tmp, rate_hint, channels, samples, head, tail, gain, false, kbps,
            TP_LIMIT,
        );
    }
    let gain0 = gain;
    let mut ceiling = TP_LIMIT;
    let mut residual = 0u32;
    for attempt in 0..4 {
        residual = encode_span(
            input_path, tmp, rate_hint, channels, samples, head, tail, gain, true, kbps, ceiling,
        )?;
        let measured = measure_stream(tmp)?;
        let out_lufs = lufs_of(&measured.k_ms);
        let tp_ok = measured.true_peak <= TP_CEILING;
        let lufs_ok = out_lufs > -50.0 && (out_lufs - TARGET_LUFS).abs() <= LUFS_TOL;
        if (tp_ok && lufs_ok) || attempt == 3 {
            return Ok(residual);
        }
        let _ = std::fs::remove_file(tmp);
        if !lufs_ok && out_lufs > -50.0 {
            let db = (TARGET_LUFS - out_lufs).clamp(-3.0, 3.0);
            gain = (gain * 10f32.powf((db / 20.0) as f32)).clamp(gain0 * 0.5, gain0 * 2.0);
        }
        if !tp_ok {
            ceiling = (ceiling * 10f32.powf(-1.0 / 20.0)).max(TP_LIMIT_FLOOR);
        }
    }
    Ok(residual)
}

struct SpanPlan {
    cut_head_ms: u64,
    cut_tail_ms: u64,
    new_lead_ms: u64,
    new_tail_ms: u64,
    lufs: f64,
    head_s: u64,
    tail_s: u64,
    lufs_encode: bool,
    lufs_seal: bool,
    gain: f32,
}

/// Misma decisión de corte y de −14 que `master_rewrite`.
fn plan_span(
    m: &StreamMeasure,
    do_trim: bool,
    do_lufs: bool,
    force_head_ms: i32,
    force_tail_ms: i32,
    lufs_hint: f64,
) -> SpanPlan {
    let mut cut_head_ms: u64 = 0;
    let mut cut_tail_ms: u64 = 0;
    let mut new_lead_ms: u64;
    let mut new_tail_ms: u64;
    let mut lufs = lufs_hint;
    let (lead, tail) = edges_from(&m.mono_ms);
    if do_trim {
        if force_head_ms >= 0 {
            cut_head_ms = force_head_ms as u64;
        } else {
            cut_head_ms = lead.saturating_sub(HEAD_KEEP_MS);
        }
        if force_tail_ms >= 0 {
            cut_tail_ms = force_tail_ms as u64;
        } else {
            cut_tail_ms = tail;
        }
        let head_try = ms_to_samples(cut_head_ms, m.rate);
        let tail_try = ms_to_samples(cut_tail_ms, m.rate);
        if head_try.saturating_add(tail_try).saturating_add(m.rate as u64) >= m.samples {
            cut_head_ms = 0;
            cut_tail_ms = 0;
        }
        if cut_head_ms < 50 {
            cut_head_ms = 0;
        }
        if cut_tail_ms < 50 {
            cut_tail_ms = 0;
        }
        new_lead_ms = lead.saturating_sub(cut_head_ms);
        new_tail_ms = if cut_tail_ms > 0 { 0 } else { tail };
    } else {
        new_lead_ms = lead;
        new_tail_ms = tail;
    }
    let head_w = (cut_head_ms / 10) as usize;
    let tail_w = (cut_tail_ms / 10) as usize;
    let end_w = m.k_ms.len().saturating_sub(tail_w);
    if end_w > head_w {
        lufs = lufs_of(&m.k_ms[head_w..end_w]);
    }
    let delta_lufs = (TARGET_LUFS - lufs).abs();
    let mut lufs_encode =
        do_lufs && lufs >= -60.0 && (delta_lufs > 0.5 || m.true_peak > TP_CEILING);
    let mut lufs_seal = do_lufs && lufs >= -60.0 && !lufs_encode;
    if m.decode_errors > 0 {
        cut_head_ms = 0;
        cut_tail_ms = 0;
        new_lead_ms = lead;
        new_tail_ms = tail;
        lufs_encode = false;
        lufs_seal = false;
    }
    let head_s = if cut_head_ms >= 50 {
        ms_to_samples(cut_head_ms, m.rate)
    } else {
        0
    };
    let tail_s = if cut_tail_ms >= 50 {
        ms_to_samples(cut_tail_ms, m.rate)
    } else {
        0
    };
    let gain = if lufs_encode { gain_for(lufs, true) } else { 1.0 };
    SpanPlan {
        cut_head_ms,
        cut_tail_ms,
        new_lead_ms,
        new_tail_ms,
        lufs,
        head_s,
        tail_s,
        lufs_encode,
        lufs_seal,
        gain,
    }
}

fn detect_validated(
    path: &str,
    samples: u64,
    rate: u32,
    intro: bool,
    prior: Option<f64>,
) -> Option<f64> {
    let (from, span) = if samples == 0 || rate == 0 {
        (0u32, if intro { 60u32 } else { 90u32 })
    } else {
        let total_s = samples / rate as u64;
        if intro {
            (0u32, 60u32)
        } else if total_s > 100 {
            ((total_s / 2).saturating_sub(40) as u32, 80u32)
        } else {
            (0u32, (total_s.max(8).min(150)) as u32)
        }
    };
    let d = decode_channels(path, from, span.max(8), 2).ok()?;
    let bpm = detect_bpm(&to_mono(&d), d.rate, prior)?;
    fix_bpm_range(bpm)
}

fn opt_i32(tag: &Tag, key: &str) -> i32 {
    match ext_text(tag, key) {
        Some(s) => num_from(&s) as i32,
        None => -1,
    }
}

fn flag_on(tag: &Tag, key: &str) -> bool {
    ext_text(tag, key).as_deref() == Some("1")
}

fn gmx_key_ok(key: &str) -> bool {
    matches!(
        key,
        KEY_V
            | KEY_LUFS
            | KEY_LEAD
            | KEY_TAIL
            | KEY_TYPE
            | KEY_NAME_OK
            | KEY_LYR
            | KEY_LYR_START
            | KEY_TRIM
            | KEY_TRIM_TAIL
            | KEY_LRC_SHIFT
            | KEY_BPM_OK
            | KEY_BPM_SCOPE
            | KEY_LUFS_DONE
            | KEY_K
            | KEY_BACKUP
            | KEY_REASON
    )
}

/// Marcas GMX de una pista, sin decodificar. Igual en las 4 plataformas.
pub struct GmxMarks {
    pub version: String,
    pub track_type: String,
    pub name_ok: bool,
    pub lyr: String,
    pub lyr_start_ms: i32,
    pub trim_ms: i32,
    pub trim_tail_ms: i32,
    pub lrc_shift: bool,
    pub bpm: f64,
    pub bpm_ok: bool,
    pub bpm_scope: String,
    pub lufs: f64,
    pub lufs_done: bool,
    pub karaoke: bool,
    pub backup: bool,
    pub sealed: bool,
    pub lead_ms: i32,
    /// Vacío, o `decode_errors=N` si el audio no se recodificó por paquetes rotos.
    pub reason: String,
}

pub fn read_gmx_marks(input_path: String) -> GmxMarks {
    let empty = GmxMarks {
        version: String::new(),
        track_type: String::new(),
        name_ok: false,
        lyr: String::new(),
        lyr_start_ms: -1,
        trim_ms: -1,
        trim_tail_ms: -1,
        lrc_shift: false,
        bpm: 0.0,
        bpm_ok: false,
        bpm_scope: String::new(),
        lufs: 0.0,
        lufs_done: false,
        karaoke: false,
        backup: false,
        sealed: false,
        lead_ms: -1,
        reason: String::new(),
    };
    if !is_mp3(&input_path) {
        return empty;
    }
    let tag = match Tag::read_from_path(&input_path) {
        Ok(t) => t,
        Err(_) => return empty,
    };
    let bpm = tag.get("TBPM").and_then(|f| f.content().text()).map(num_from).unwrap_or(0.0);
    let sealed = tag.comments().any(|c| c.text == SEAL_TEXT);
    let marks = GmxMarks {
        version: ext_text(&tag, KEY_V).unwrap_or_default(),
        track_type: ext_text(&tag, KEY_TYPE).unwrap_or_default(),
        name_ok: flag_on(&tag, KEY_NAME_OK),
        lyr: ext_text(&tag, KEY_LYR).unwrap_or_default(),
        lyr_start_ms: opt_i32(&tag, KEY_LYR_START),
        trim_ms: opt_i32(&tag, KEY_TRIM),
        trim_tail_ms: opt_i32(&tag, KEY_TRIM_TAIL),
        lrc_shift: flag_on(&tag, KEY_LRC_SHIFT),
        bpm,
        bpm_ok: flag_on(&tag, KEY_BPM_OK),
        bpm_scope: ext_text(&tag, KEY_BPM_SCOPE).unwrap_or_default(),
        lufs: ext_text(&tag, KEY_LUFS).map(|s| num_from(&s)).unwrap_or(0.0),
        lufs_done: ext_text(&tag, KEY_LUFS_DONE).as_deref() == Some("-14"),
        karaoke: flag_on(&tag, KEY_K),
        backup: flag_on(&tag, KEY_BACKUP),
        sealed,
        lead_ms: opt_i32(&tag, KEY_LEAD),
        reason: ext_text(&tag, KEY_REASON).unwrap_or_default(),
    };
    marks
}

/// Escribe una marca GMX de la lista blanca. No crea marcas arbitrarias.
pub fn set_gmx_mark(input_path: String, key: String, value: String) -> Result<bool, String> {
    if !gmx_key_ok(&key) {
        return Err(format!("Marca no permitida: {key}"));
    }
    if !Path::new(&input_path).exists() {
        return Err("Archivo no encontrado en I/O.".to_string());
    }
    if !is_mp3(&input_path) {
        return Ok(false);
    }
    let mut tag = Tag::read_from_path(&input_path).unwrap_or_else(|_| Tag::new());
    set_ext(&mut tag, &key, value);
    tag.write_to_path(&input_path, Version::Id3v24).map_err(|e| e.to_string())?;
    Ok(true)
}

/// Resultado de reescribir una pista. `trim_head_ms` es lo cortado EN ESTA
/// pasada (0 si ya estaba cortada: no hay que mover la letra otra vez).
pub struct MasterRewrite {
    pub trim_head_ms: u32,
    pub trim_tail_ms: u32,
    pub lead_ms: u32,
    pub tail_ms: u32,
    pub bpm: f64,
    pub lufs: f64,
    pub lufs_applied: bool,
    pub bitrate_kbps: u32,
    pub rewritten: bool,
    /// Ms que el decodificador AÑADE al inicio si ignora el tag LAME.
    /// Con el tag escrito, libmpv/FFmpeg se lo salta y esto queda en 0.
    /// No es una constante: sale del delay que LAME anotó en el tag.
    pub residual_ms: u32,
}

/// Recorta silencios y/o normaliza a −14 LUFS. Una sola generación si hacen
/// falta los dos. `force_head_ms` / `force_tail_ms` < 0 = detectar; si no,
/// cortar exactamente esos ms (el `_K` acompaña a la pista). Una pista que
/// ya tiene `GMX_TRIM_MS` no se vuelve a cortar.
pub fn master_rewrite(
    input_path: String,
    do_trim: bool,
    do_lufs: bool,
    intro_bpm: bool,
    force_head_ms: i32,
    force_tail_ms: i32,
) -> Result<MasterRewrite, String> {
    if !Path::new(&input_path).exists() {
        return Err("Archivo no encontrado en I/O.".to_string());
    }
    if !is_mp3(&input_path) {
        return Err("Solo MP3.".to_string());
    }
    let mut tag = Tag::read_from_path(&input_path).unwrap_or_else(|_| Tag::new());
    let already_trim = ext_text(&tag, KEY_TRIM).is_some();
    let already_lufs = ext_text(&tag, KEY_LUFS_DONE).as_deref() == Some("-14");
    let do_trim = do_trim && !already_trim;
    let do_lufs = do_lufs && !already_lufs;

    let need_audio = do_trim || do_lufs;
    let measured = if need_audio {
        Some(measure_stream(&input_path)?)
    } else {
        None
    };

    let mut cut_head_ms: u64 = 0;
    let mut cut_tail_ms: u64 = 0;
    let mut new_lead_ms: u64 = 0;
    let mut new_tail_ms: u64 = 0;
    let mut lufs = ext_text(&tag, KEY_LUFS).map(|s| num_from(&s)).unwrap_or(0.0);
    let mut kbps = 0u32;

    if let Some(m) = &measured {
        let (lead, tail) = edges_from(&m.mono_ms);
        if do_trim {
            if force_head_ms >= 0 {
                cut_head_ms = force_head_ms as u64;
            } else {
                cut_head_ms = lead.saturating_sub(HEAD_KEEP_MS);
            }
            if force_tail_ms >= 0 {
                cut_tail_ms = force_tail_ms as u64;
            } else {
                cut_tail_ms = tail;
            }
            let head_s = ms_to_samples(cut_head_ms, m.rate);
            let tail_s = ms_to_samples(cut_tail_ms, m.rate);
            if head_s.saturating_add(tail_s).saturating_add(m.rate as u64) >= m.samples {
                cut_head_ms = 0;
                cut_tail_ms = 0;
            }
            // Menos de 50 ms no justifica otra generación. El `_K` forzado
            // hereda el corte ya redondeado de la pista, así que cae igual.
            if cut_head_ms < 50 {
                cut_head_ms = 0;
            }
            if cut_tail_ms < 50 {
                cut_tail_ms = 0;
            }
            new_lead_ms = lead.saturating_sub(cut_head_ms);
            new_tail_ms = if cut_tail_ms > 0 { 0 } else { tail };
        } else {
            new_lead_ms = lead;
            new_tail_ms = tail;
        }
        let head_w = (cut_head_ms / 10) as usize;
        let tail_w = (cut_tail_ms / 10) as usize;
        let end_w = m.k_ms.len().saturating_sub(tail_w);
        if end_w > head_w {
            lufs = lufs_of(&m.k_ms[head_w..end_w]);
        }
        kbps = average_kbps(&input_path, m.samples, m.rate);
    }

    // Recodifica solo si hay corte de verdad (≥ 50 ms), el LUFS se aleja más
    // de 0,5 dB, o el pico pasa de −1 dBTP. Si no, solo se escriben marcas.
    // Un paquete MP3 rechazado deja el audio intacto: el PCM ya no es el archivo.
    let decode_errors = measured.as_ref().map(|m| m.decode_errors).unwrap_or(0);
    let blocked = decode_errors > 0;
    let peak = measured.as_ref().map(|m| m.true_peak).unwrap_or(0.0);
    let delta_lufs = (TARGET_LUFS - lufs).abs();
    let mut lufs_encode = do_lufs && lufs >= -60.0 && (delta_lufs > 0.5 || peak > TP_CEILING);
    let mut lufs_seal = do_lufs && lufs >= -60.0 && !lufs_encode;
    if blocked {
        cut_head_ms = 0;
        cut_tail_ms = 0;
        if let Some(m) = &measured {
            let (lead, tail) = edges_from(&m.mono_ms);
            new_lead_ms = lead;
            new_tail_ms = tail;
        }
        lufs_encode = false;
        lufs_seal = false;
    }
    let lufs_applied = lufs_encode;
    let gain = if lufs_encode { gain_for(lufs, true) } else { 1.0 };

    let mut rewritten = false;
    let mut residual_ms = 0u32;
    let bpm_path: String;
    if let Some(m) = &measured {
        let head_s = if cut_head_ms >= 50 {
            ms_to_samples(cut_head_ms, m.rate)
        } else {
            0
        };
        let tail_s = if cut_tail_ms >= 50 {
            ms_to_samples(cut_tail_ms, m.rate)
        } else {
            0
        };
        let audio_change = head_s > 0 || tail_s > 0 || lufs_encode;
        if audio_change {
            let tmp = format!("{input_path}.gmxpart");
            residual_ms = encode_master_span(
                &input_path,
                &tmp,
                m.rate,
                m.channels,
                m.samples,
                head_s,
                tail_s,
                gain,
                lufs_encode,
                kbps,
            )
            .map_err(|e| {
                let _ = std::fs::remove_file(&tmp);
                e
            })?;
            bpm_path = tmp;
            rewritten = true;
        } else {
            bpm_path = input_path.clone();
        }
    } else {
        bpm_path = input_path.clone();
    }

    let (samples_for_bpm, rate_for_bpm) = if let Some(m) = &measured {
        let head_s = if do_trim { ms_to_samples(cut_head_ms, m.rate) } else { 0 };
        let tail_s = if do_trim { ms_to_samples(cut_tail_ms, m.rate) } else { 0 };
        (m.samples.saturating_sub(head_s).saturating_sub(tail_s), m.rate)
    } else {
        (0u64, 0u32)
    };
    let existing_bpm = tag
        .get("TBPM")
        .and_then(|f| f.content().text())
        .map(num_from)
        .unwrap_or(0.0);
    // Con paquetes rotos el medido sale de un PCM incompleto: no pisa el TBPM.
    let measured_bpm = if blocked {
        None
    } else {
        detect_validated(
            &bpm_path,
            samples_for_bpm,
            rate_for_bpm,
            intro_bpm,
            fix_bpm_range(existing_bpm),
        )
    };
    let bpm = resolve_bpm(measured_bpm, existing_bpm);

    if do_trim && !blocked {
        set_ext(&mut tag, KEY_TRIM, cut_head_ms.to_string());
        set_ext(&mut tag, KEY_TRIM_TAIL, cut_tail_ms.to_string());
        set_ext(&mut tag, KEY_LEAD, new_lead_ms.to_string());
        set_ext(&mut tag, KEY_TAIL, new_tail_ms.to_string());
    }
    if lufs_applied || lufs_seal {
        set_ext(&mut tag, KEY_LUFS, format!("{lufs:.2}"));
        set_ext(&mut tag, KEY_LUFS_DONE, "-14".to_string());
    }
    if lufs_applied {
        // El archivo queda en −14. ReplayGain hacia −18 para que un
        // reproductor externo no vuelva a subir lo ya normalizado.
        set_ext(&mut tag, "REPLAYGAIN_TRACK_GAIN", "-4.00 dB".to_string());
        set_ext(&mut tag, "REPLAYGAIN_TRACK_PEAK", format!("{TP_CEILING:.6}"));
    }
    if bpm > 0.0 {
        tag.set_text("TBPM", format!("{}", bpm.round() as i32));
        set_ext(&mut tag, KEY_BPM_OK, "1".to_string());
        set_ext(
            &mut tag,
            KEY_BPM_SCOPE,
            if intro_bpm { "INTRO" } else { "FULL" }.to_string(),
        );
    }
    if blocked {
        set_ext(&mut tag, KEY_REASON, format!("decode_errors={decode_errors}"));
    } else {
        tag.remove_extended_text(Some(KEY_REASON), None);
    }
    set_ext(&mut tag, KEY_V, SCHEMA_V2.to_string());

    if rewritten {
        let tmp = bpm_path;
        tag.write_to_path(&tmp, Version::Id3v24).map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            e.to_string()
        })?;
        let side = format!("{input_path}.gmxside");
        if let Err(e) = std::fs::rename(&input_path, &side) {
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        if let Err(e) = std::fs::rename(&tmp, &input_path) {
            let _ = std::fs::rename(&side, &input_path);
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        let _ = std::fs::remove_file(&side);
    } else {
        tag.write_to_path(&input_path, Version::Id3v24).map_err(|e| e.to_string())?;
    }

    Ok(MasterRewrite {
        trim_head_ms: cut_head_ms as u32,
        trim_tail_ms: cut_tail_ms as u32,
        lead_ms: new_lead_ms as u32,
        tail_ms: new_tail_ms as u32,
        bpm,
        lufs,
        lufs_applied,
        bitrate_kbps: if kbps == 0 {
            average_kbps(&input_path, samples_for_bpm, rate_for_bpm.max(1))
        } else {
            kbps
        },
        rewritten,
        residual_ms,
    })
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
        let fin = sink.finish().map(|_| ());
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
mod gapless_tests {
    use super::*;

    /// Codifica un chirrido con un inicio conocido, lo decodifica y comprueba
    /// que saltar el delay ANOTADO EN EL TAG (no una constante) deja el
    /// transitorio a ≤ 1 ms. Antes de saltarlo el desfase es mayor.
    #[test]
    fn el_tag_lame_alinea_el_transitorio() {
        let rate = 44100u32;
        let lead = rate as usize / 5;
        let burst = rate as usize * 3 / 10;
        let tail = rate as usize / 10;
        let mut pcm = vec![0f32; lead + burst + tail];
        let mut phase = 0.0f32;
        for i in 0..burst {
            let p = i as f32 / burst as f32;
            let hz = 180.0 + p * 3600.0;
            phase += std::f32::consts::TAU * hz / rate as f32;
            pcm[lead + i] = phase.sin() * 0.55;
        }

        let dir = std::env::temp_dir().join(format!(
            "gmx_gapless_{}_{}",
            std::process::id(),
            rate
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("burst.mp3");
        let path_s = path.to_string_lossy().to_string();

        let mut sink = Mp3Sink::new(&path_s, rate, false, 320).unwrap();
        sink.push(&pcm, 1).unwrap();
        let gap = sink.finish().unwrap();
        assert_eq!(gap.residual_ms, 0, "con el tag escrito no queda retardo");
        assert!(gap.delay_samples > 0 && gap.delay_samples <= 3000);
        assert!(gap.padding_samples > 0 && gap.padding_samples <= 3000);

        let bytes = std::fs::read(&path_s).unwrap();
        let (delay, padding) = read_lame_delay_padding(&bytes).expect("tag LAME");
        assert_eq!(delay, gap.delay_samples);
        assert_eq!(padding, gap.padding_samples);

        let mut tag = Tag::new();
        tag.set_title("gapless");
        tag.write_to_path(&path_s, Version::Id3v24).unwrap();
        let tagged = std::fs::read(&path_s).unwrap();
        let (delay_id3, padding_id3) =
            read_lame_delay_padding(&tagged).expect("el tag sobrevive al ID3");
        assert_eq!((delay_id3, padding_id3), (delay, padding));

        let decoded = decode_mono(&path_s);
        // FFmpeg (libmpv) no emite el frame Info y se salta
        // `enc_delay + 528 + 1`: el delay leído del tag más el retardo fijo
        // del decodificador MPEG-1 Layer III (LAME encoder.h / get_audio.c).
        // 528 no es un 70 mágico: sale de sumar ese retardo al delay del tag.
        let skip = delay + 528 + 1;
        assert!(
            decoded.len() > skip as usize,
            "el MP3 decodificado es demasiado corto ({})",
            decoded.len()
        );

        let before = best_lag(&pcm, &decoded);
        let one_ms = (rate / 1000) as i32;
        assert!(
            before.abs() > one_ms,
            "antes de aplicar el tag el desfase es {before} muestras; se esperaba el priming del encoder"
        );
        assert!(
            (before - skip as i32).abs() <= one_ms,
            "el priming medido ({before}) no coincide con delay del tag + retardo MPEG-1 ({skip})"
        );

        let lag = best_lag(&pcm, &decoded[skip as usize..]);
        assert!(
            lag.abs() <= one_ms,
            "tras saltar {skip} muestras (delay={delay} + 529) el desfase es {lag} ({:.2} ms), tope 1 ms. padding={padding} antes={before}",
            lag.abs() as f32 * 1000.0 / rate as f32
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    fn decode_mono(path: &str) -> Vec<f32> {
        let mut out = Vec::new();
        decode_frames(path, false, |_rate, nch, inter| {
            let nch = nch.max(1);
            for frame in inter.chunks(nch) {
                out.push(frame[0]);
            }
            Ok(())
        })
        .unwrap();
        out
    }

    /// `lag` > 0: `got` llega tarde respecto de `reference`.
    fn best_lag(reference: &[f32], got: &[f32]) -> i32 {
        let max_lag = 44100 * 120 / 1000;
        let mut best = 0i32;
        let mut best_score = f64::MIN;
        let n = reference.len().min(got.len()).min(rate_window(reference.len()));
        for lag in -max_lag..=max_lag {
            let mut score = 0.0f64;
            let mut used = 0i32;
            for i in 0..n {
                let j = i as i32 + lag;
                if j < 0 || (j as usize) >= got.len() {
                    continue;
                }
                score += reference[i] as f64 * got[j as usize] as f64;
                used += 1;
            }
            if used < 1000 {
                continue;
            }
            if score > best_score {
                best_score = score;
                best = lag;
            }
        }
        best
    }

    fn rate_window(len: usize) -> usize {
        len.min(44100)
    }

    /// El mismo salto, aplicado dentro del decodificador que usa el master.
    #[test]
    fn el_decode_gapless_deja_el_transitorio_a_1ms() {
        let rate = 44100u32;
        let lead = rate as usize / 5;
        let burst = rate as usize * 3 / 10;
        let tail = rate as usize / 10;
        let mut pcm = vec![0f32; lead + burst + tail];
        let mut phase = 0.0f32;
        for i in 0..burst {
            let p = i as f32 / burst as f32;
            let hz = 180.0 + p * 3600.0;
            phase += std::f32::consts::TAU * hz / rate as f32;
            pcm[lead + i] = phase.sin() * 0.55;
        }
        let dir = std::env::temp_dir().join(format!(
            "gmx_gapless_on_{}_{}",
            std::process::id(),
            rate
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("burst.mp3");
        let path_s = path.to_string_lossy().to_string();
        let mut sink = Mp3Sink::new(&path_s, rate, false, 320).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();

        let mut heard = Vec::new();
        decode_frames(&path_s, true, |_rate, nch, inter| {
            let nch = nch.max(1);
            for frame in inter.chunks(nch) {
                heard.push(frame[0]);
            }
            Ok(())
        })
        .unwrap();
        let lag = best_lag(&pcm, &heard);
        let one_ms = (rate / 1000) as i32;
        assert!(
            lag.abs() <= one_ms,
            "gapless dejó {lag} muestras ({:.3} ms)",
            lag.abs() as f32 * 1000.0 / rate as f32
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod master_guard_tests {
    use super::*;

    #[test]
    fn el_tbpm_previo_gana_si_el_medido_es_alias() {
        assert_eq!(resolve_bpm(Some(144.0), 108.0), 108.0);
        assert_eq!(resolve_bpm(Some(147.0), 110.0), 110.0);
        assert_eq!(resolve_bpm(Some(140.0), 105.0), 105.0);
        assert_eq!(resolve_bpm(Some(81.0), 108.0), 108.0);
        assert_eq!(resolve_bpm(Some(180.0), 90.0), 90.0);
        assert_eq!(resolve_bpm(Some(90.0), 180.0), 180.0);
        // 3 % ya no es el alias: se queda el medido.
        assert_eq!(resolve_bpm(Some(148.4), 108.0), 148.4);
        assert_eq!(resolve_bpm(Some(120.0), 108.0), 120.0);
        assert_eq!(resolve_bpm(None, 108.0), 108.0);
        assert_eq!(resolve_bpm(Some(144.0), 0.0), 144.0);
    }

    #[test]
    fn el_lag_4_3_se_queda_con_el_tbpm_previo() {
        let env_rate = 200.0;
        let lag_144 = ((60.0 * env_rate / 144.0) as f64).round() as usize;
        let lag_108 = ((60.0 * env_rate / 108.0) as f64).round() as usize;
        let mut scores = vec![0.0; lag_108 + 8];
        scores[lag_144] = 10.0;
        scores[lag_108] = 4.0;
        let picked = lag_matching_prior(
            lag_144 as f64,
            &scores,
            env_rate,
            20,
            lag_108 + 4,
            108.0,
        )
        .unwrap();
        let bpm = 60.0 * env_rate / picked;
        assert!(
            near_bpm(bpm, 108.0),
            "eligió {bpm} (lag {picked}) en vez del TBPM 108"
        );
        assert!(bpm < 120.0, "no debía quedarse en 144");
    }

    fn id3v2(payload: usize) -> Vec<u8> {
        let mut v = vec![b'I', b'D', b'3', 4, 0, 0];
        let s = payload;
        v.push(((s >> 21) & 0x7f) as u8);
        v.push(((s >> 14) & 0x7f) as u8);
        v.push(((s >> 7) & 0x7f) as u8);
        v.push((s & 0x7f) as u8);
        v.extend(std::iter::repeat(0xAB).take(payload));
        v
    }

    fn ape_footer() -> [u8; 32] {
        let mut f = [0u8; 32];
        f[0..8].copy_from_slice(b"APETAGEX");
        f[8..12].copy_from_slice(&2000u32.to_le_bytes());
        f[12..16].copy_from_slice(&32u32.to_le_bytes());
        f
    }

    #[test]
    fn el_kbps_ignora_id3_y_ape_y_no_sube_del_frame() {
        let secs = 10.0;
        let samples = (44100.0 * secs) as u64;
        let audio_len = 200_000usize;
        let mut audio = vec![0u8; audio_len];
        audio[0..4].copy_from_slice(&[0xFF, 0xFB, 0xA0, 0x00]);
        let mut file = id3v2(140_000);
        file.extend_from_slice(&audio);
        file.extend_from_slice(&ape_footer());
        file.extend_from_slice(b"TAG");
        file.extend(std::iter::repeat(0u8).take(125));

        let (start, end) = audio_byte_range(&file);
        assert_eq!(end - start, audio_len);
        let from_audio = kbps_of_audio((end - start) as u64, samples, 44100);
        assert_eq!(from_audio, 160);
        let naive = kbps_of_audio(file.len() as u64, samples, 44100);
        assert!(naive > 250, "con la carátula el promedio inflado es {naive}");
        let capped = cap_kbps(from_audio, mpeg_bitrate_kbps(&file[start..end]));
        assert_eq!(capped, 160);
        assert!(matches!(
            bitrate_at_most(capped),
            mp3lame_encoder::Bitrate::Kbps160
        ));
        assert!(matches!(
            bitrate_at_most(naive),
            mp3lame_encoder::Bitrate::Kbps256
        ));
        // El frame dice 160: un promedio inflado no puede subir a 256.
        assert_eq!(cap_kbps(naive, Some(160)), 160);
        // Tampoco se sube un promedio más bajo hasta el frame.
        assert_eq!(cap_kbps(128, Some(160)), 128);
    }

    #[test]
    fn un_paquete_roto_no_recodifica_y_deja_el_motivo() {
        let dir = std::env::temp_dir().join(format!("gmx_badpack_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rota.mp3");
        let path_s = path.to_string_lossy().to_string();
        let rate = 44100u32;
        let mut pcm = vec![0f32; rate as usize];
        for (i, s) in pcm.iter_mut().enumerate() {
            *s = (i as f32 * 0.07).sin() * 0.4;
        }
        let mut sink = Mp3Sink::new(&path_s, rate, false, 160).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();

        let mut bytes = std::fs::read(&path_s).unwrap();
        let (a0, a1) = audio_byte_range(&bytes);
        let audio_before = bytes[a0..a1].to_vec();
        let mid = a0 + (a1 - a0) / 2;
        let end = (mid + 400).min(a1);
        for b in &mut bytes[mid..end] {
            *b = 0;
        }
        std::fs::write(&path_s, &bytes).unwrap();

        let skipped = decode_frames(&path_s, false, |_r, _n, _s| Ok(())).unwrap();
        assert!(skipped > 0, "el MP3 roto no produjo DecodeError");

        let mut tag = Tag::new();
        tag.set_text("TBPM", "108");
        tag.write_to_path(&path_s, Version::Id3v24).unwrap();
        let before = std::fs::read(&path_s).unwrap();
        let (b0, b1) = audio_byte_range(&before);
        let audio_tagged = before[b0..b1].to_vec();

        let rw = master_rewrite(path_s.clone(), true, true, false, -1, -1).unwrap();
        assert!(!rw.rewritten, "no debía recodificar");
        assert_eq!(rw.trim_head_ms, 0);
        assert!(!rw.lufs_applied);

        let after = std::fs::read(&path_s).unwrap();
        let (c0, c1) = audio_byte_range(&after);
        assert_eq!(&after[c0..c1], audio_tagged.as_slice());
        let marks = read_gmx_marks(path_s.clone());
        assert!(
            marks.reason.starts_with("decode_errors="),
            "motivo={}",
            marks.reason
        );
        assert_eq!(marks.trim_ms, -1, "no se sella un corte que no se hizo");
        assert!(!marks.lufs_done);
        let _ = audio_before;
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn clicks(bpm: f64, seconds: f64) -> Vec<f32> {
        let rate = 44100.0;
        let n = (rate * seconds) as usize;
        let mut pcm = vec![0f32; n];
        let period = (rate * 60.0 / bpm).round() as usize;
        let mut i = period;
        while i + 16 < n {
            for k in 0..6 {
                pcm[i + k] = 0.85;
            }
            i += period;
        }
        pcm
    }

    #[test]
    fn sin_tbpm_previo_no_parte_un_tempo_de_pop() {
        let env_rate = 200.0;
        let lag_169 = ((60.0 * env_rate / 169.0) as f64).round() as usize;
        let lag_85 = ((60.0 * env_rate / 84.5) as f64).round() as usize;
        let mut scores = vec![0.0; lag_85 + 8];
        scores[lag_169] = 8.0;
        scores[lag_85] = 3.0;
        let bpm = prefer_dance_tempo(lag_169 as f64, &scores, env_rate, 20, lag_85 + 4);
        assert!(
            bpm > 160.0 && bpm < 180.0,
            "Take On Me debía quedarse en ~169 y salió {bpm}"
        );

        let lag_178 = ((60.0 * env_rate / 178.0) as f64).round() as usize;
        let slow89 = (lag_178 as f64 * 2.0).round() as usize;
        let mut cumbia_scores = vec![0.0; slow89 + 8];
        cumbia_scores[slow89] = 9.0;
        cumbia_scores[lag_178] = 6.0;
        let got89 = prefer_dance_tempo(
            lag_178 as f64,
            &cumbia_scores,
            env_rate,
            20,
            slow89 + 4,
        );
        assert!(
            (got89 - 89.0).abs() < 3.0,
            "la cumbia en 89 no debía doblarse a {got89}"
        );

        let lag_124 = ((60.0 * env_rate / 124.0) as f64).round() as usize;
        let slow62 = (lag_124 as f64 * 2.0).round() as usize;
        let mut ballad = vec![0.0; slow62 + 8];
        ballad[slow62] = 9.0;
        ballad[lag_124] = 5.0;
        let got62 = prefer_dance_tempo(lag_124 as f64, &ballad, env_rate, 20, slow62 + 4);
        assert!(
            (got62 - 62.0).abs() < 3.0,
            "Hello debía volver a ~62 y salió {got62}"
        );

        let near = |got: f64, want: f64| (got - want).abs() < 3.0;
        let hello = detect_bpm(&clicks(62.0, 12.0), 44100, None).expect("62");
        assert!(near(hello, 62.0), "Hello quedó en {hello}");
        let mirlos = detect_bpm(&clicks(89.0, 12.0), 44100, None).expect("89");
        assert!(near(mirlos, 89.0), "Los Mirlos quedó en {mirlos}");
        let aha = detect_bpm(&clicks(169.0, 12.0), 44100, None).expect("169");
        assert!(near(aha, 169.0), "Take On Me quedó en {aha}");

        let mut con_guiro = clicks(89.0, 12.0);
        let step = ((44100.0 * 60.0 / 178.0) as f64).round() as usize;
        let mut i = step;
        while i + 4 < con_guiro.len() {
            con_guiro[i] += 0.35;
            i += step;
        }
        let guiro = detect_bpm(&con_guiro, 44100, None).expect("guiro");
        assert!(near(guiro, 89.0), "la cumbia con subdivisión quedó en {guiro}");

        let kept = detect_bpm(&clicks(108.0, 12.0), 44100, Some(108.0)).expect("108");
        assert!((kept - 108.0).abs() < 3.0, "TBPM 108 pasó a {kept}");
        let plain = detect_bpm(&clicks(110.0, 12.0), 44100, Some(110.0)).expect("110");
        assert!((plain - 110.0).abs() < 3.0, "TBPM 110 pasó a {plain}");
        let prior169 = detect_bpm(&clicks(84.5, 12.0), 44100, Some(169.0)).expect("prior 169");
        assert!(
            (prior169 - 169.0).abs() < 4.0 || (prior169 - 84.5).abs() < 4.0,
            "con TBPM 169 no debía inventar otro tempo: {prior169}"
        );
    }

    #[test]
    fn el_pico_real_del_mp3_queda_en_menos_1() {
        let rate = 44100u32;
        let n = rate as usize * 4;
        let mut pcm = vec![0f32; n];
        for i in 0..n {
            let body = (i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 0.22;
            pcm[i] = body;
        }
        let spike_every = rate as usize / 2;
        let mut at = spike_every;
        while at + 80 < n {
            for k in 0..40 {
                pcm[at + k] = 0.98;
            }
            at += spike_every;
        }
        let dir = std::env::temp_dir().join(format!("gmx_tp_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("hot.mp3");
        let path_s = path.to_string_lossy().to_string();
        let mut sink = Mp3Sink::new(&path_s, rate, false, 320).unwrap();
        sink.push(&pcm, 1).unwrap();
        sink.finish().unwrap();

        let rw = master_rewrite(path_s.clone(), true, true, false, -1, -1).unwrap();
        assert!(rw.lufs_applied, "el pico debía forzar la normalización");
        let measured = measure_stream(&path_s).unwrap();
        let dbtp = 20.0 * (measured.true_peak as f64).max(1e-9).log10();
        assert!(
            dbtp <= -1.0,
            "true peak {dbtp:.2} dBTP (lineal {})",
            measured.true_peak
        );
        let lufs = lufs_of(&measured.k_ms);
        assert!(
            (lufs - TARGET_LUFS).abs() <= LUFS_TOL,
            "LUFS {lufs:.2}, se pedía −14 ±0,3"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
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
