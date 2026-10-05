# CONTEXTO — DJ Studio

Fuente única. No hay `REGLAS.md` ni otros `.mdc` de ley. No pedir a Gabriel que repita esto.

**Obligatorio en todo chat (también el primero).** Cursor inyecta este archivo + `.cursor/rules/contexto.mdc` (`alwaysApply`) en cada turno. Gabriel **no** tiene que escribir “cero diff”, “no borres” ni pegar este bloque. Si el mensaje no lo dice, el default sigue siendo **Se elimina: NADA**. Silencio ≠ permiso. “Arregla”, “revisa”, “urgente”, “desfasada” **no derogan**. Culpa de un borrado colateral = del agente, no de Gabriel por no repetirlo.

## 00. Todo cambio = todos los dispositivos (ley)

**Todo cambio que Gabriel pida aplica a TODOS los dispositivos:** Windows, Android, macOS **e iPhone** (entrada independiente `lib/djiphone/main.dart` + `PlatformMixStrategy` por plataforma). No se entrega un arreglo/feature "solo Windows" ni "solo celular". Si el código vive en una capa compartida (`lib/providers`, `lib/ui/workspaces`), basta un diff; si hay una estrategia/ruta por plataforma (`lib/core/hal/platform_strategy.dart`, `djiphone/`, rutas de sesión, permisos), se revisa y se alinea en el mismo turno. Si algo no puede ser igual en una plataforma (p. ej. voz/ruido en celular), se dice explícito en el cierre; nunca se deja en silencio.

Verificación mínima al cerrar: nombrar las 4 plataformas y confirmar que el diff las cubre (o cuál queda excluida y por qué). Despliegue = commit + tag `v*` + push (el CI de GitHub arma los ejecutables).

## 0. UI = LOG + OK

Sustituir un hijo (p. ej. rueda LRC por 2 `Text`) = borrar. Compactar, “2 líneas”, “overflow” o “solo celular” no autorizan borrar.

Turno 1: **cero** `StrReplace` / `Write` / `Delete`. Solo el log. Esperar **OK** / “autorizado” / “aplica”.

OK = aplicar el LOG y desplegar en el mismo turno (`clasp push --force` + deploy). Cerrar con @N y que el deploy ya quedó. No pedir otro OK. No esperar un “despliega” aparte.

```
LOG CAMBIO
Pedido: …
Se conserva: lista literal (rueda LRC, Sync I/O, teatro, LAB, SET IN/OUT, cola, PLAY, …)
Se mueve/compacta: …
Se elimina: NADA  |  lo que Gabriel nombró (“quita X”)
Riesgo: 1920px / Mac 13" / móvil
```

Sin ese log + confirmación en un mensaje posterior, no hay diff.

**Cero borrado colateral (UI y motor).** “Se elimina: NADA” vale para **cualquier** diff: widgets, `automixProvider`, `liveDjProvider`, `mix_formula.dart`, DAWN, persistencia, JSON. Arreglar X no autoriza quitar, fusionar, comentar ni “limpiar” ni **una** línea de las que ya funcionaban. “No topar X” no autoriza borrar Y al lado. Alcance = solo el bloque que Gabriel nombró. Si un parche anterior quitó líneas no nombradas: **reponer primero**, luego el arreglo. Turno 1+OK sigue siendo solo UI.

Diff de motor (mismo inventario, sin esperar OK salvo que sea UI):

```
Se conserva: DNA 65/80/75, cue-in 10 s (>30 s, DNA/Phrase), fade 18 s,
             Phrase 8, Stealth 5–10 % / ~60 %, TIPO DE MEZCLA 1→2→3,
             Zero-Start, SET IN/OUT (solo Automix), rueda LRC, persistencia
Se elimina: NADA
```

## 1. Qué es, rol, stack

Reproductor/mezclador DJ (Windows / Android / macOS).

ROL del agente: Staff Software & DSP Engineer Senior. Tono técnico, directo y frío. Cero explicaciones.

**Stack:** Flutter (UI) · Riverpod (State) · media_kit + libmpv (audio C++) · Rust + tokio (FFI/DSP) · Python/yt-dlp (extractor).

Rutas `IndexedStack` (`lib/main.dart`), orden fijo interno:
0 Automix · 1 Masterizar · 2 YT Descarga · 3 Laboratorio · 4 LAN Sync · 5 Live DJ · 6 Karaoke.

Menú ☰ (visual, mismas rutas): Automix · Live DJ · Descargas YT · Laboratorio · Masterizar · LAN Sync · Karaoke.

## 2. Ley marcial

1. **Modificación atómica:** solo el bloque modificado, funciones o clases completas. Prohibido `// ... resto del código`. Lo no tocado se clona byte a byte.
2. **Zero-touch:** prohibido tocar, refactorizar u “optimizar” `automixProvider`, `liveDjProvider` o estilo sin autorización. Cada toque a esos providers, justificado.
3. **Veto técnico:** si el pedido choca con timeouts, I/O locks o bloqueo de hilo, veto. No asfixiar hardware; Tracker, no parches ciegos. Si el gesto/pedido no está 100 % claro, o el agente quiere sustituirlo por una “opción mejor”: **PARA**. Cero `StrReplace` / `Write` / `Delete` de UI/motor. Preguntar a Gabriel. Prohibido inventar el flujo (p. ej. quitar la pausa, segundo clic en 2 en vez del icono de empate, no mostrar la lista de filas). El diseño lo nombra Gabriel; el agente no lo reescribe.
4. **Código:** nivel profesional de plataformas equivalentes. Nada genérico de tutorial.
5. **UI:** estructura de consola DJ, no layout básico.
6. **Cero línea colateral:** el diff solo toca el defecto nombrado. Prohibido borrar ramas `if`, cues, mixes, SET I/O, sesión, widgets o imports “no usados” de paso. Si se perdió, reponer en el mismo turno.

## 3. Automix — flujo fijo (Windows = celular)

Tres recuadros abajo + mixer arriba. Siempre.

1. **Explorador** (`LibraryTreePanel`) — carpeta.
2. **Pistas** (`FolderContentPanel`) — Cargar Todo o una pista (+).
3. **Cola** (`AutomixPanel`) — ordenar (A-Z / BPM); PLAY. La canción suena **arriba** en `MixerPanel`.

`MixerPanel` = letra + Sync I/O (GLOBAL / 2-MED) + SET IN / SET OUT + candado + seq/random + play + slider.

Prohibido overlay, crate o pestañas que sustituyan los 3 recuadros. Seq/random solo en MixerPanel.

Bucle infinito. Zero-Start (evasión de silencios). LRC (LRCLib). Lectura de letra a los 10 s salvo la primera pista.

## 4. Módulos

- **Automix** — `automix_workspace.dart` / `automix_provider.dart`. Leer letra y marcar SET IN/OUT. Sin eso no tiene objeto.
- **Live DJ** — `livedj_workspace.dart` / `liveDjProvider`. Fiestas. Cartridge FIFO destructiva. ADN DJ: Remix/EDM ~65 %, Tropical/Salsa/Merengue ~80 %, resto ~75 %. Nadie lee letra ni marca SET I/O. El empate debe ser exacto. Layout vigente (2026-10-04): **Explorador** = columna izquierda a toda la altura, pegada al header (flex 5); a su derecha (flex 19) el player arriba y debajo **carpeta (4) | Cartridge (5)**. Cada fila del Cartridge muestra el **BPM a la izquierda** de la canción (`livedj_bpm_badge.dart`; orden: `_dj_metadata.json` en la carpeta o padres → etiqueta ID3 `TBPM` → nombre del archivo → "–"). Independiente de Automix: `liveDjDirectoryProvider` (explorador), `liveDjEqualizerProvider` (EQ), controles del SO por motor activo; nada compartido (el BPM del Cartridge no usa `bpmCacheProvider`). Tres motores (TIPO DE MEZCLA cicla 1→2→3; no borrar ninguno): (1) **DNA** 65/80/75 + cue-in Zero-Start 10 s si pista > 30 s + fade 18 s + BPM ±12 %; (2) **Phrase 8** mismo ADN, snap 8 compases, `phraseFadeMs`; (3) **Stealth** entra 5–10 %, cruza ~60 %, cola BPM, `lyricMs` vacío (no lee `.lrc`).
- **Karaoke** — `karaoke_workspace.dart` + `djstudio_tv/`. Laptop = mando (QR, cola, pausa/skip/borrar, INICIAR/FINALIZAR). TV = audio + letra. Laptop **no** abre `media_kit`. Monitor de letra en laptop = reloj visual, sin sonido.
  - `INICIAR KARAOKE` → `EDGE_EXECUTE` (`_K.mp3` + `.lrc` HTTP :55056).
  - `STAGE_STATE` replica cola/QR/votos/pausa. `TV_PAUSE` / `TV_SKIP` / `TV_REMOVE` suben del mando.
  - Fin: scoreboard 8 s y avance; skip corta scoreboard. `FINALIZAR` → `SESSION_END`.
  - Lupa TV: `tv_adb_deployment_service.dart` (ADB + mDNS `_adb-tls-*`, no radar REST :55055). `adb install -r`, launch LEANBACK. Depuración inalámbrica + emparejamiento.
- **Auto-Master / Masterizar** — `dsp_workspace.dart`. Menú: **Masterizar**. BPM, letra, ruido, voz (Python). Celular: voz/ruido = “Usa la compu”. No borrar las tarjetas.
- **Lab** — `lab_workspace.dart`. Cuarentena `quarantine_registry.json`. Un frame: carpetas flex 2 | pistas 3 | arsenal 5. Default origen = carpeta actual. No dos pantallas.
- **YT** — `yt_workspace.dart`. Menú **Descargas YT** (ruta 2) en Windows **y** celular (☰). No ocultar con `if (isMobile)`. Buscador + extracción en scroll; no recortar la barra de estado. Windows: yt-dlp → FFmpeg MP3 320 (`yt-dlp.exe` en `%TEMP%` si falta). Android: no `Process.run` de binarios x86; extracción con `YoutubeExplode`. DSP exige FFmpeg en PATH (computadora).
- **LAN** — `lan_sync_workspace.dart`. REST `:55055` (`/api/whoami`, radar por lotes de 50 IPs). Flat-Tree en memoria. Radar LAN ≠ lupa TV (ADB).

## 5. Cromo, huecos, zero-touch

| | Windows | Android / iOS |
|---|---|---|
| Nav | sidebar **160 px** `_DjStudioNavColumn` | `_MobileModeBar` **36 px** (`☰ Título ▾`) + overlay 228 px. **No** rail a pantalla completa |
| Stage | resto del Row | `SafeArea` → mode bar → IndexedStack. Padding derecho **48 px** si `viewPadding.right == 0` (gutter Xiaomi) |
| Audio | n/a | Llamada = pausa y reanuda sola (§6c). Minimizar = sigue + `persistSession`. Cerrar = persist + `parkIdleDecks` + stop. Reabrir = misma canción y posición. Android: servicio en primer plano (`audio_service`) con latido por segundo; sin él el SO mata el proceso tras ~10 canciones |

**Paleta (ley):** C Traktor / Native Instruments. Gabriel la cerró 2026-09-21. No volver a Pioneer A ni Serato B. Tokens en `DjStudioTheme` (`lib/providers/theme_provider.dart`). Prohibido hardcodear fondos `#161616` / `#222222`.

| Token | Hex | Uso |
|---|---|---|
| `bgDark` | `#0E1014` | Fondo cabina |
| `bgPanel` | `#1A1E26` | Paneles elevados |
| `deckA` | `#2E9BFF` | Deck A azul Traktor |
| `deckB` / `cyanAccent` | `#F05A22` | Naranja Native Instruments |
| `syncActive` | `#00E676` | Sync / menú idle |
| menú seleccionado | `#43B3AE` | Cardenillo |

**Huecos:** Automix mixer **5** / terna **5** (árbol 2 · pistas 4 · cola 5). Live DJ (todas las plataformas): Explorador 5 | columna derecha 19; en la derecha celular player **4** / fila **6**, Windows player 5 / fila 5, y la fila = carpeta 4 · cartridge 5. (Antes: árbol 2 · carpeta 4 · cartridge 5 bajo el player.) Lab: 2 · 3 · 5.

Overflow amarillo = fallo de cálculo. Hijos no-flex (IconButton 48, Slider) no pueden sumar más que el slot: `tightFor` + `shrinkWrap` + FittedBox. **Cero** `BOTTOM OVERFLOWED`. Nunca quitar hijos para que “quepa”.

Altura útil ≈ pantalla − SafeArea − 36 (mode bar) − gutters; el resto en flex.

**Zero-touch** (salvo “quita X” / “borra Y”):

- `LyricsSyncPanel` / letra de `MixerPanel`: título, teatro, LAB, Sync I/O, Sync GLOBAL, Sync 2-MED, **rueda LRC** (`ListWheelScrollView`).
- SET IN / SET OUT / candado / cues / deck painter / slider.
- Explorador, pistas, cola, PLAY, ON AIR, STUDIO 1, SMART ROUTING, cartridge, Cargar Carpeta, QR.
- Sidebar 160 px. Rutas IndexedStack. Menú ☰: Automix · Live DJ · Descargas YT · Laboratorio · Masterizar · LAN Sync · Karaoke (los 7, Windows y celular).
- `automixProvider` / `liveDjProvider`. Sesión minimizar/cerrar/reanudar.
- Live DJ TIPO DE MEZCLA × 3: DNA 65/80/75, cue-in 10 s (>30 s), fade 18 s, Phrase 8, Stealth 5–10 %/~60 %. No sustituir un motor por “return 0”.

Sustituir = borrar: rueda LRC por `Text`/`Column`; sacar la rueda del `Expanded` de `LyricsSyncPanel`; `if (isMobile) no pintar`.

Cómo sí: envolver, reordenar, bajar padding. Mismos hijos. Additive-only.

Pendiente visual (sin tocar estructura): 3 recuadros + letra en landscape Xiaomi sin barra amarilla.

## 6. Riverpod — aislamiento de hilos

Prohibido mezclar listas/UI con el hilo acústico.

| Ámbito | Hilo acústico | Hilo visual |
|---|---|---|
| Automix | `automixProvider` (Audio/FFI/DAWN) | `automixQueueProvider` |
| Live DJ | `liveDjProvider` (Audio/ADN) | cola / cartridge |

Globales: `playedTracksProvider` (session JSON) · `bpmCacheProvider` (Rust `dspWorkerProvider`) · `wasapiRecordProvider` (Master Out dshow/avfoundation → FFmpeg).

UI no muta estado a pelo: `Notifier` / `Provider`.

## 6b. Colas — estabilidad y fin de cola (2026-10-04)

**Cola estable (Live DJ y Automix):** una canción en cola no se mueve ni desaparece por sí sola.
- Añadir (`+`, Cargar Carpeta, cargar playlist) **solo anexa al final**. Con shuffle activo se mezcla únicamente el lote nuevo; lo ya cargado conserva su orden. Añadir **no** cambia el modo secuencial/shuffle: eso lo decide solo el botón.
- El banco de shuffle (10 órdenes) se aplica **solo** al pulsar el botón de shuffle (y en Automix con la lista vacía). Al reabrir la app **no** se re-mezcla: el orden guardado es la verdad.
- Tocar una fila del Cartridge (play/fila) suena **esa** pista; el resto **no** se reordena (antes se movía al índice 0 y en Stealth sonaba otra).
- Cruce: la pista entrante se quita de la cola **por ruta**, nunca por índice (la cola puede cambiar durante la carga). El deck standby recuerda qué pista precargó (`_standbyArmedPath`); si la cola cambió, se recarga.
- Al restaurar sesión sin pista actual, la primera de la cola pasa a "actual" **y sale de la cola** (no suena dos veces).
- Automix: `syncDynamicPlaylist` ya no re-mezcla todo ni fuerza random al añadir pistas.

**Fin de cola (cola vacía):** se detiene el audio y se **borra la pista residual** (Live DJ: `currentTrackPath`, posición, duración, cue/mix-out; Automix: pista, playlist, índice, letra, solo con `autoMixArmed` y sin siguiente pista; con candado manual se conserva para SET IN/OUT). Se guarda el estado limpio. La siguiente carpeta cargada arranca desde su primera canción, sin reproducir la última de la cola anterior. `copyWith(clearCurrentTrackPath: true)` existe en ambos estados.

## 6c. Foco de audio e interrupciones (2026-10-04)

`lib/services/audio_interruption.dart` (`AudioInterruptionGuard`, paquete `audio_session`), montado en `_MobileAudioLifecycle` (`main.dart`) y `_DjIphoneLifecycle` (`djiphone/main.dart`). Android + iPhone; Windows/macOS no aplica (sin llamadas).
- Al sonar Automix o Live DJ pide el foco (`setActive(true)`); si el SO lo niega, no suena encima.
- Llamada/alarma (interrupción temporal) → pausa ambos decks (también a mitad de cruce) con `pauseForInterruption()`; al terminar reanuda sola con `resumeAfterInterruption()`, solo si la pausa la causó el sistema.
- Otra app toma el audio (pérdida permanente) o se desconectan auriculares/Bluetooth → pausa y **no** reanuda.
- Navegación hablando (duck): la atenúa el SO; no se toca el volumen del motor de mezcla.
- Pausa del usuario → suelta el foco. Cola, posición y sesión no se tocan.

## 6d. Voz — ELIMINADA (2026-10-05)

Gabriel quitó toda la voz: mando de voz (micrófono, "Oye DJ", comandos) y la pregunta "¿Qué pongo?" al abrir. No hay `speech_to_text`, `flutter_tts` ni `volume_controller`; no hay permisos de micrófono/voz en `Info.plist` (iOS/macOS). No reintroducir sin pedido explícito. `AudioInterruptionGuard` (6c) queda sin ventana de voz.

## 7. DSP

**DAWN:** crossfade logarítmico de alta energía. Cruce > 90 % de ganancia real. Prohibido `sin()`/`cos()` en la **ganancia** del crossfade (−3 dB en el medio). Sí trigonometría para otros parámetros (p. ej. `setRate()` al tempo).

```dart
final rateIn = (progress * 1.8).clamp(0.0, 1.0);
final rateOut = ((1.0 - progress) * 1.8).clamp(0.0, 1.0);
final smoothRateIn = pow(rateIn, 1.2).toDouble();
final smoothRateOut = pow(rateOut, 1.2).toDouble();
```

**Duraciones:** Automix auto 7–10 s (`kDawnLeadMs` 5 s antes del SET OUT; cola silencedetect 2–5 s; SET OUT no es corte seco). Manual Automix y Live DJ: 8–18 s, dictada por la **entrante** (compases 4/4 / BPM; sin BPM, 6 % de duración). Live DJ auto: 18 s `activeSync` / 4 s si set > 10 min. Toda mezcla manual = DAWN. Prohibido cortar audio.

**Zero-Lag:** `state.duration` síncrono. Prohibido `timeout()` que bloquee el hilo.

**Hifi:** `af` nativo en libmpv. Prohibido bucles Dart de DSP. No reconstruir `af` por frame. Bass swap: una escritura por deck en el cruce.

## 8. Tokens

1. No releer archivos ya leídos en la sesión.
2. Fuente única: este `CONTEXTO.md` (Apps Drive: `c:\AppScripts\CONTEXTO.md`). Una lectura, no re-derivar.
3. `Grep`/`Read` con offset/limit.
4. Respuestas concisas; un diff, no pegar el archivo.
5. No listar árboles de nuevo.
6. Terminal: salida a archivo; no volcar el wrapper PowerShell.
7. Glob/Grep en paralelo.
8. Apps Drive → `c:\AppScripts`, no este repo.
9. `.cursorignore` ya excluye tooling, `build/`, `.dart_tool/`, `venv/`, `__pycache__/`. No indexar esos paths.

## 9. Permisos Android (APK)

`READ_EXTERNAL_STORAGE` · `WRITE_EXTERNAL_STORAGE` · `MANAGE_EXTERNAL_STORAGE` (API 30+). Escritura en `/storage/emulated/0/Music`. Sin micrófono: `RECORD_AUDIO` y los `<queries>` de voz (reconocedor/TTS) se quitaron el 2026-10-05.

## 10. CI GitHub (Windows · Android · macOS)

**Regla de Gabriel (2026-10-05): NO hacer `git push` (ni subir tags) a GitHub hasta que él lo diga directamente.** Esto anula el "OK = desplegar" de la sección 0: tras un OK se aplican los cambios y se puede hacer commit local, pero el push solo cuando Gabriel escriba la orden. Un tag pusheado dispara el CI.

Workflow: `.github/workflows/release.yml`. Tag `v*` dispara build en las 3:

| Target | Runner | Salida |
|---|---|---|
| Android | ubuntu | `app-release.apk` |
| Windows | windows | `DjStudio-Installer.exe` (`windows_setup.iss` / Inno Setup) |
| macOS | macos | `DjStudio-MacOS.zip` |

Controles externos (notificación / bloqueo): `DjAudioHandler` tiene un dueño (`claim` al sonar; `syncOs` solo escribe el dueño o quien suena). Título/duración se refrescan siempre con la pista real. `pause` real desde la notificación (se ignora ≤2 s tras minimizar: `noteAppBackgrounded`); `play` no pausa si ya suena. Automix siguiente/anterior dan la vuelta; Live DJ anterior reinicia la canción.

Versión actual desplegada: `v2.0.14` (v2.0.14: controles externos con dueño + permisos de voz quitados de Android; v2.0.13: se elimina toda la voz; v2.0.12: voz (eliminada); v2.0.11: foco de audio / llamadas; v2.0.7: servicio en primer plano Android + TIPO DE MEZCLA persistente; v2.0.8: independencia Live DJ/Automix, fidelidad; v2.0.9: fin de cola, layout Live DJ, BPM Cartridge; v2.0.10: BPM por ruta/ID3, cola estable). Nunca commitear `GeneratedPluginRegistrant.swift`, `generated_plugin_registrant.cc`, `generated_plugins.cmake`.

Rust targets por OS, `flutter_rust_bridge_codegen generate`, NDK r25c en APK, CocoaPods en Mac. Artefactos → GitHub Releases. Toda config de empaquetado debe cubrir esas 3; no dejar una plataforma fuera.
