# DjStudio - Arquitectura, Flujo de Procesos y Despliegue (Flutter)

## 1. División del Sistema (Diseño por Capas)
El sistema aplica una arquitectura de separación de responsabilidades (Clean Architecture):
*   **Capa de Presentación (UI):** Renderizado reactivo a 60FPS. Enrutamiento SPA (Single Page Application) mediante `IndexedStack` lógico. El `Live Deck` (reproductor) vive fuera del enrutador para persistencia absoluta del audio.
*   **Capa de Estado (Riverpod 2.0):** Inyección de dependencias mediante `Notifier` y `Provider`. Prohíbe la mutación directa del estado desde la UI. 
*   **Capa de Orquestación (Workers):** Hilos asíncronos (Isolates simulados) que procesan I/O intensivo (lectura de disco, peticiones HTTP, invocación de binarios) sin bloquear el hilo principal (UI Stuttering).

## 2. Flujo de Procesos Estrictos
1.  **Directorio Global (Lazy Loading):** Lectura diferida del sistema de archivos. Bloquea las rutas de ejecución si no hay un objetivo claro.
2.  **Pipeline DSP/NLP (Batch):**
    *   *Paso 1 (Regex):* Sanitización atómica del File System (Amputación de metadatos basura y renombrado estricto).
    *   *Paso 2 (NLP):* Scraping asíncrono con control de latencia (anti-HTTP 429) hacia `lrclib.net` para generar mapas `.lrc`.
    *   *Paso 3 y 4 (DSP/EBU):* Invocación de CLI nativo para procesamiento de tensores de audio (Trim de silencios a -45dB y nivelación LUFS).
3.  **Live Deck (Reproducción Semántica):** Pre-carga el archivo `.lrc`. Calcula la delta de silencios. Inyecta un *Punch-In* asimétrico a la Pista B (volumen exponencial descendente vs. volumen agresivo entrante), adelantando el *Cue-In* 2.5 segundos antes de la primera voz. Failsafe activo: fundido genérico de 4s si el mapa `.lrc` no existe.

## 3. Estrategia de Despliegue y Compilación (Cross-Platform)

### Entorno Windows / Linux (Desktop)
*   **Binarios Autogestionados:** El sistema auto-descarga `yt-dlp.exe` a la carpeta `%TEMP%` del OS si no lo detecta en la primera ejecución del módulo de YouTube.
*   **Dependencia Estricta (Bloqueante):** El motor DSP (Módulo 3 y 4) exige obligatoriamente que **FFmpeg esté instalado y configurado en el PATH global del sistema operativo**. Si no existe, el *Worker* de masterización abortará el proceso.

### Entorno Android (Mobile)
*   **Restricción Arquitectónica (Veto):** La ejecución nativa de binarios x86_64 (`yt-dlp.exe` / `ffmpeg.exe`) a través de `Process.run` está bloqueada por el Kernel de Android.
*   **Fallback I/O (Motor YT):** La extracción de YouTube degrada automáticamente al motor nativo en Dart (`youtube_explode_dart`), generando archivos en caché.
*   **Gestión de Permisos:** Para compilar el APK y permitir que la app escriba en `/storage/emulated/0/Music`, es obligatorio inyectar los permisos de almacenamiento en el `AndroidManifest.xml`:
    *   `<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>`
    *   `<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>`
    *   `<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>` (Requerido para Android 11+ / API 30+).

## 4. Estado Actual de la Compilación
*   **Backend:** Workers I/O asíncronos programados. Motor NLP (Scraping y semántica) funcional y enrutamiento Riverpod adaptado a 2.0 sin deprecaciones.
*   **Fase Actual:** Preparación para test de estrés en disco real y ajuste fino de los eventos de la barra de progreso (Telemetría UI).

---
**INPUT DEL USUARIO PARA ESTA SESIÓN:**
[Escribe aquí tu requerimiento, parche, o bug a revisar]