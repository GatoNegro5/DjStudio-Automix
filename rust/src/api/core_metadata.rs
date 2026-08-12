use std::fs;
use std::process::Command;
use std::path::Path;
use std::env;
use regex::Regex;

fn get_ffmpeg_path() -> String {
    if let Ok(mut exe_path) = env::current_exe() {
        exe_path.pop();
        exe_path.push(if cfg!(target_os = "windows") { "ffmpeg.exe" } else { "ffmpeg" });
        if exe_path.exists() {
            return exe_path.to_string_lossy().into_owned();
        }
    }
    "ffmpeg".to_string()
}

pub async fn process_metadata(input_path: String) -> Result<Vec<String>, String> {
    let input = Path::new(&input_path);
    if !input.exists() {
        return Err("Archivo no encontrado en I/O nativo.".to_string());
    }

    let filename = input.file_name().unwrap().to_string_lossy().into_owned();
    let (new_filename, artist, title) = parse_and_clean(&filename);

    let parent = input.parent().ok_or("Ruta huérfana".to_string())?;
    let new_file_path = parent.join(&new_filename);
    let temp_path = parent.join("temp_meta.mp3");

    let output = Command::new(get_ffmpeg_path())
        .args([
            "-nostdin", // 🛠️ FIX: Aislamiento de I/O
            "-y", "-i", input.to_str().unwrap(),
            "-c", "copy",
            "-metadata", &format!("title={}", title),
            "-metadata", &format!("artist={}", artist),
            "-metadata", "album=ReGenial Master",
            temp_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("FFmpeg OS Invocation Error: {}", e))?;

    if output.status.success() {
        if input != new_file_path.as_path() {
            let _ = fs::remove_file(input);
            
            let mut attempts = 0;
            let mut delay_ms = 50;
            loop {
                match fs::rename(&temp_path, &new_file_path) {
                    Ok(_) => break,
                    Err(e) => {
                        attempts += 1;
                        if attempts >= 5 {
                            return Err(format!("Rename error tras 5 intentos: {}", e));
                        }
                        std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                        delay_ms *= 2;
                    }
                }
            }
        } else {
            let _ = fs::remove_file(input);
            
            let mut attempts = 0;
            let mut delay_ms = 50;
            loop {
                match fs::rename(&temp_path, input) {
                    Ok(_) => break,
                    Err(e) => {
                        attempts += 1;
                        if attempts >= 5 {
                            return Err(format!("Rename error tras 5 intentos: {}", e));
                        }
                        std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                        delay_ms *= 2;
                    }
                }
            }
        }
        Ok(vec![new_filename, artist, title])
    } else {
        if temp_path.exists() { let _ = fs::remove_file(temp_path); }
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

fn parse_and_clean(filename: &str) -> (String, String, String) {
    let mut name = filename.to_string();
    let mut ext = String::new();
    
    if let Some(idx) = name.rfind('.') {
        ext = name[idx..].to_string();
        name = name[..idx].to_string();
    }

    if name.ends_with("_R") || name.ends_with(" R") {
        name = name[..name.len() - 2].to_string();
    }

    let garbage_regex = Regex::new(r"(?i)\s*[\(\[\{][^\)\]\}]*(official|music video|video|audio|lyric|lyrics|letra|letras|hq|hd|4k|remastered|remaster|visualizer|en vivo|en directo|live)[^\)\]\}]*(?:[\)\]\}]|$)\s*").unwrap();
    let spaces_regex = Regex::new(r"\s{2,}").unwrap();
    let dash_regex = Regex::new(r"\s*-\s*-+\s*").unwrap();
    let invalid_chars_regex = Regex::new(r#"[<>:"/\\|?*]"#).unwrap();

    let mut clean_name = garbage_regex.replace_all(&name, " ").to_string();
    clean_name = dash_regex.replace_all(&clean_name, " - ").to_string();
    clean_name = clean_name.replace("_", " ");
    clean_name = spaces_regex.replace_all(&clean_name, " ").trim().to_string();

    let parts: Vec<&str> = clean_name.split(" - ").collect();
    let mut artist = "Unknown".to_string();
    let mut title = clean_name.clone();

    if parts.len() >= 2 {
        artist = parts[0].trim().to_string();
        title = parts[1..].join(" - ").trim().to_string();
    }

    artist = to_title_case(&artist);
    title = to_title_case(&title);
    
    let trailing_regex = Regex::new(r"[\.\-_]+$").unwrap();
    title = trailing_regex.replace(&title, "").to_string();

    let final_filename = if artist != "Unknown" {
        format!("{} - {}{}", artist, title, ext)
    } else {
        format!("{}{}", title, ext)
    };

    let safe_filename = invalid_chars_regex.replace_all(&final_filename, "").to_string();
    (safe_filename, artist, title)
}

fn to_title_case(text: &str) -> String {
    if text.is_empty() { return String::new(); }
    text.split_whitespace()
        .map(|word| {
            let mut c = word.chars();
            match c.next() {
                None => String::new(),
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str().to_lowercase().as_str(),
            }
        })
        .collect::<Vec<String>>()
        .join(" ")
}