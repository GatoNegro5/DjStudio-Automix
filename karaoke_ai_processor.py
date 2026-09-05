import os
import sys
import subprocess
import shutil
import time
import ctypes

# ==========================================
# MITIGACIÓN TÉRMICA Y LÍMITES DE HARDWARE
# ==========================================
# 1. Limitar hilos de PyTorch/Demucs para no incendiar la CPU (Core Capping)
os.environ["OMP_NUM_THREADS"] = "4"
os.environ["MKL_NUM_THREADS"] = "4"

# 2. Forzar baja prioridad en el planificador de Windows (OS Niceness)
# Esto permite que Windows estrangule este proceso automáticamente si detecta sobrecalentamiento.
try:
    # 0x00004000 = BELOW_NORMAL_PRIORITY_CLASS
    ctypes.windll.kernel32.SetPriorityClass(
        ctypes.windll.kernel32.GetCurrentProcess(), 0x00004000
    )
except Exception:
    pass

# ==========================================
# CONFIGURACION DEL PIPELINE
# ==========================================
DEFAULT_TARGET_DIR = r"C:\Users\ASUS\Music\ReGenial"
TEMP_DIR = r"C:\Users\ASUS\Music\ReGenial_TempAI"
SUFFIX = "_K"
COOLING_TIME_SECONDS = 120  # 2 Minutos de enfriamiento entre pistas

# Forzar UTF-8 en Windows Console para evitar UnicodeEncodeError
if sys.stdout.encoding != "utf-8":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass


def process_single_file(file_path):
    if not os.path.exists(file_path):
        print(f"[ERROR] El archivo {file_path} no existe.")
        return False

    if not file_path.lower().endswith(".mp3"):
        print("[ERROR] El archivo no es un MP3.")
        return False

    base_name = os.path.splitext(os.path.basename(file_path))[0]
    root_dir = os.path.dirname(file_path)
    karaoke_mp3_name = f"{base_name}{SUFFIX}.mp3"
    karaoke_mp3_path = os.path.join(root_dir, karaoke_mp3_name)

    # BLINDAJE DE EVASIÓN FÍSICA: Si existe el _K, se omite de inmediato
    if os.path.exists(karaoke_mp3_path):
        print(f"[SKIP] La pista instrumental ya existe para {base_name}")
        return False

    print(f"\n[Procesando IA Demucs SINGLE] {base_name}")
    os.makedirs(TEMP_DIR, exist_ok=True)

    try:
        demucs_cmd = ["demucs", "--two-stems=vocals", "-o", TEMP_DIR, file_path]

        subprocess.run(demucs_cmd, check=True)

        ai_output_folder = os.path.join(TEMP_DIR, "htdemucs", base_name)
        no_vocals_wav = os.path.join(ai_output_folder, "no_vocals.wav")

        if not os.path.exists(no_vocals_wav):
            print(f"[ERROR I/O] Demucs no genero el archivo esperado para {base_name}")
            return False

        print(f"[Comprimiendo a MP3 320kbps] {karaoke_mp3_name}")
        ffmpeg_cmd = [
            "ffmpeg",
            "-y",
            "-i",
            no_vocals_wav,
            "-b:a",
            "320k",
            karaoke_mp3_path,
        ]

        subprocess.run(
            ffmpeg_cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )

        if os.path.exists(ai_output_folder):
            shutil.rmtree(ai_output_folder)

        print(f"[Exito] Pista Instrumental generada: {karaoke_mp3_name}\n")
        return True  # Retorna True solo si hizo trabajo pesado de IA

    except subprocess.CalledProcessError as e:
        print(
            f"[ERROR CRITICO] procesando {base_name}. Codigo de salida: {e.returncode}"
        )
        return False
    except Exception as ex:
        print(f"[ERROR INESPERADO] en {base_name}: {ex}")
        return False


def process_catalog(directory):
    if not os.path.exists(directory):
        print(f"[ERROR] El directorio {directory} no existe.")
        return

    print(f"[INFO] Escaneando directorio: {directory}")
    os.makedirs(TEMP_DIR, exist_ok=True)

    files_to_process = []
    for root, _, files in os.walk(directory):
        for file in files:
            # BLINDAJE DE EVASIÓN DE ESCANEO
            if file.lower().endswith(".mp3") and not file.endswith(f"{SUFFIX}.mp3"):
                files_to_process.append(os.path.join(root, file))

    total = len(files_to_process)
    for i, original_mp3_path in enumerate(files_to_process):
        did_heavy_lifting = process_single_file(original_mp3_path)

        # 3. DUTY CYCLE: Descanso térmico solo si la IA corrió y no es la última pista
        if did_heavy_lifting and i < total - 1:
            print(
                f"[TERMAL] Duty Cycle Activado. Dejando enfriar la CPU por {COOLING_TIME_SECONDS}s..."
            )
            for sec in range(COOLING_TIME_SECONDS, 0, -1):
                # Imprimir silenciosamente a stderr para no romper el parser de Flutter
                sys.stderr.write(f"\r🧊 Enfriando Procesador... {sec}s restantes")
                sys.stderr.flush()
                time.sleep(1)
            sys.stderr.write("\n")
            sys.stderr.flush()

    if os.path.exists(TEMP_DIR):
        shutil.rmtree(TEMP_DIR)

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
            "Iniciando Motor de Aislamiento de Voces Batch Global (Demucs - Meta AI)..."
        )
        process_catalog(DEFAULT_TARGET_DIR)
