import subprocess
import os

# 🛠️ TRACKER: Ruta actualizada a tu carpeta de Normalizados
test_file = r"C:\Users\ASUS\Music\ReGenial\Descargas\Normalizados\Víctor Manuelle - Dile A Ella.mp3"
out_dir = r"C:\Users\ASUS\Music\ReGenial_TempAI"

os.makedirs(out_dir, exist_ok=True)

print("🔍 [TRACKER] Iniciando prueba aislada de Demucs...")
print(f"📂 Archivo: {test_file}")

# Comando de separación a 2 stems (Voz / Instrumental)
demucs_cmd = ["demucs", "--two-stems=vocals", "-o", out_dir, test_file]

try:
    # 🛠️ FIX: Sin capture_output para ver el progreso real (stdout/stderr directos a la consola)
    subprocess.run(demucs_cmd, check=True)

    print("\n✅ [ÉXITO] Procesamiento finalizado.")
    print(f"Revisa la carpeta: {out_dir}\\htdemucs\\Víctor Manuelle - Dile A Ella\\")
    print("Ahí encontrarás el archivo 'no_vocals.wav'. Escúchalo y valida la calidad.")

except subprocess.CalledProcessError as e:
    print(
        f"\n🔴 [FATAL DEMUCS ERROR] El proceso C++ colapsó con código: {e.returncode}"
    )
except Exception as e:
    print(f"\n🔴 [ERROR DESCONOCIDO]: {e}")
