# CHANGELOG

![GatoMix](assets/branding/gatomix_logo.png)

## 1.0.0

El producto pasa a llamarse GatoMix. La app de TV pasa a llamarse GatoMix Karaoke.

Esto reemplaza el nombre anterior DjStudio (paquete `djstudio_player`, carpeta `djstudio_tv`, ejecutable `djstudio_player.exe`, APK `djstudio-tv.apk`, rol de red `djstudio-karaoke`, laboratorio `DjStudio_LAB`, caché `%LOCALAPPDATA%\DJStudio`, crate `rust_lib_djstudio_player`, tema `DjStudioTheme`).

La app sigue leyendo las etiquetas ID3 viejas `DJS_*` y, si hace falta borrarlas, también los frames `DjStudio_M3` y `DjStudio_M3_V2`. Las nuevas se escriben `GMX_*`. La carpeta de caché y el laboratorio se renombran solos si todavía existe la carpeta anterior. La regla de firewall anterior (`DjStudio REST Server` y `DjStudio TV Sync`) se quita si sigue presente.

El `applicationId` es `com.gatonegro5.gatomix` (TV: `com.gatonegro5.gatomix.tv`). Hay que desinstalar la app anterior una vez. La contraseña de la firma nueva no está en el repositorio: va en los secretos de GitHub y, en local, en `android/key.properties`.
