import os
import sys
import time
import shutil
import ctypes
import subprocess

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["TORCH_NUM_THREADS"] = "1"
os.environ["TORCH_NUM_INTEROP_THREADS"] = "1"

try:
    ctypes.windll.kernel32.SetPriorityClass(
        ctypes.windll.kernel32.GetCurrentProcess(), 0x00000040
    )
except Exception:
    pass

DEFAULT_TARGET_DIR = r"C:\Users\ASUS\Music\ReGenial"
TEMP_DIR = r"C:\Users\ASUS\Music\ReGenial_TempAI"
STOP_FLAG = os.path.join(TEMP_DIR, ".karaoke_ai_stop")
SUFFIX = "_K"
COOLDOWN_SEC = 25


if sys.stdout.encoding != "utf-8":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def _resolve_device():
    try:
        import torch

        if torch.cuda.is_available():
            print("[INFO] Demucs en CUDA.")
            return "cuda"
    except Exception:
        pass
    print("[INFO] Demucs en CPU (1 hilo, 1 pista, cooldown automatico).")
    return "cpu"


def _karaoke_path(file_path):
    base_name = os.path.splitext(os.path.basename(file_path))[0]
    root_dir = os.path.dirname(file_path)
    return os.path.join(root_dir, f"{base_name}{SUFFIX}.mp3"), base_name


def _duration_sec(path):
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                path,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        return float((result.stdout or "").strip())
    except Exception:
        return 0.0


def _usable_instrumental(path, source_path=None):
    if not os.path.exists(path) or os.path.getsize(path) < 256 * 1024:
        return False
    if source_path and os.path.exists(source_path):
        src_size = os.path.getsize(source_path)
        if src_size > 0 and os.path.getsize(path) < src_size * 0.45:
            return False
        src_dur = _duration_sec(source_path)
        out_dur = _duration_sec(path)
        if src_dur > 8 and out_dur > 0 and out_dur < src_dur * 0.85:
            return False
    return True


def _run_demucs(file_path, device):
    cmd = [
        "demucs",
        "--two-stems=vocals",
        "-n",
        "htdemucs",
        "-o",
        TEMP_DIR,
        "--device",
        device,
        "--jobs",
        "1",
        "--shifts",
        "0",
        "--overlap",
        "0.15",
    ]
    if device == "cpu":
        cmd.extend(["--segment", "5"])
    cmd.append(file_path)
    subprocess.run(cmd, check=True)


def _compress_wav(wav_path, dest_mp3):
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-threads",
            "1",
            "-i",
            wav_path,
            "-b:a",
            "320k",
            dest_mp3,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _cooldown():
    print(f"[COOLDOWN] {COOLDOWN_SEC}s para no saturar el procesador.")
    sys.stdout.flush()
    for _ in range(COOLDOWN_SEC):
        if _stop_requested():
            return
        time.sleep(1)


def _finalize_file(file_path):
    karaoke_mp3_path, base_name = _karaoke_path(file_path)
    ai_output_folder = os.path.join(TEMP_DIR, "htdemucs", base_name)
    no_vocals_wav = os.path.join(ai_output_folder, "no_vocals.wav")

    if not os.path.exists(no_vocals_wav):
        print(f"[ERROR I/O] Demucs no genero el archivo esperado para {base_name}")
        return False

    print(f"[Comprimiendo a MP3 320kbps] {os.path.basename(karaoke_mp3_path)}")
    try:
        _compress_wav(no_vocals_wav, karaoke_mp3_path)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR CRITICO] ffmpeg {base_name}. Codigo: {e.returncode}")
        return False

    if os.path.exists(ai_output_folder):
        shutil.rmtree(ai_output_folder, ignore_errors=True)

    if not _usable_instrumental(karaoke_mp3_path, file_path):
        print(f"[ERROR I/O] _K.mp3 truncado o invalido para {base_name}, se descarta.")
        try:
            os.remove(karaoke_mp3_path)
        except OSError:
            pass
        return False

    print(f"[Exito] Pista Instrumental generada: {os.path.basename(karaoke_mp3_path)}\n")
    return True


def process_single_file(file_path, device=None, rest=True):
    if not os.path.exists(file_path):
        print(f"[ERROR] El archivo {file_path} no existe.")
        return False

    if not file_path.lower().endswith(".mp3"):
        print("[ERROR] El archivo no es un MP3.")
        return False

    karaoke_mp3_path, base_name = _karaoke_path(file_path)
    if _usable_instrumental(karaoke_mp3_path, file_path):
        print(f"[SKIP] La pista instrumental ya existe para {base_name}")
        return False

    print(f"\n[Procesando IA Demucs SINGLE] {base_name}")
    sys.stdout.flush()
    os.makedirs(TEMP_DIR, exist_ok=True)
    device = device or _resolve_device()

    try:
        _run_demucs(file_path, device)
        ok = _finalize_file(file_path)
        if rest:
            _cooldown()
        return ok
    except subprocess.CalledProcessError as e:
        print(f"[ERROR CRITICO] procesando {base_name}. Codigo de salida: {e.returncode}")
        return False
    except Exception as ex:
        print(f"[ERROR INESPERADO] en {base_name}: {ex}")
        return False


def _stop_requested():
    return os.path.exists(STOP_FLAG)


def _clear_stop_flag():
    try:
        os.remove(STOP_FLAG)
    except OSError:
        pass


def process_catalog(directory):
    if not os.path.exists(directory):
        print(f"[ERROR] El directorio {directory} no existe.")
        return

    print(f"[INFO] Escaneando directorio: {directory}")
    os.makedirs(TEMP_DIR, exist_ok=True)
    _clear_stop_flag()
    device = _resolve_device()

    files_to_process = []
    for root, _, files in os.walk(directory):
        for file in files:
            if not file.lower().endswith(".mp3") or file.endswith(f"{SUFFIX}.mp3"):
                continue
            full = os.path.join(root, file)
            karaoke_mp3_path, _ = _karaoke_path(full)
            if _usable_instrumental(karaoke_mp3_path, full):
                continue
            files_to_process.append(full)

    total = len(files_to_process)
    print(f"[INFO] {total} pista(s) pendientes. Una por una, con cooldown.")

    cancelled = False
    for index, path in enumerate(files_to_process, start=1):
        if _stop_requested():
            cancelled = True
            print("[CANCEL] Cola detenida. La pista en curso ya termino.")
            break
        print(f"[INFO] {index}/{total}")
        process_single_file(path, device=device, rest=index < total)

    _clear_stop_flag()
    if os.path.exists(TEMP_DIR):
        shutil.rmtree(TEMP_DIR, ignore_errors=True)

    if cancelled:
        print("[JOB CANCELADO] No se encolan mas pistas.")
    else:
        print("[JOB FINALIZADO] Toda la cola ha sido procesada.")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        target_path = sys.argv[1]
        if os.path.isdir(target_path):
            print(f"Iniciando Motor Batch para la carpeta especifica: {target_path}")
            process_catalog(target_path)
        elif os.path.isfile(target_path):
            print(f"Iniciando Motor de IA para archivo unico: {target_path}")
            process_single_file(target_path)
        else:
            print(f"[ERROR] Ruta no valida: {target_path}")
    else:
        print(
            "Iniciando Motor de Aislamiento de Voces (Demucs, 1 pista, prioridad idle)..."
        )
        process_catalog(DEFAULT_TARGET_DIR)
