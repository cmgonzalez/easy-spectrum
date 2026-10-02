# play-store — publicación en Google Play

Material para publicar **Easy Spectrum** (Free, `cl.easysoft.easyspectrum`) y **Easy Spectrum Pro** (`cl.easysoft.easyspectrum.pro`).

| Archivo | Qué es |
|---|---|
| `web/easy-spectrum/privacy.html` | Política de privacidad (es + en). Publicar en `https://www.easysoft.cl/easy-spectrum/privacy.html` |
| `listing/en-US.md` | Textos de la ficha en inglés (idioma predeterminado) |
| `listing/es-419.md` | Textos de la ficha en español |
| `play-console.md` | Respuestas para Play Console: público, clasificación, anuncios, seguridad de los datos |

## Hecho
- [x] Quitados del manifiesto `READ_EXTERNAL_STORAGE` y `READ_MEDIA_IMAGES/VIDEO/AUDIO` (no se usaban; Play exige justificar acceso a fotos/videos) y el paquete `permission_handler` de `pubspec.yaml`.

## IDs de AdMob (cuenta pub-4383534162647782)
- App ID (Free): `ca-app-pub-4383534162647782~8837981292` — app «Easy Spectrum: ZX Spectrum Emulator», creada sin tienda; vincular a Google Play cuando esté publicada.
- Banner (inicio, «Easy Spectrum - Banner Inicio»): `ca-app-pub-4383534162647782/2568261422`
- Interstitial (al salir del juego, «Easy Spectrum - Interstitial Salida»): `ca-app-pub-4383534162647782/5449400629`

## Pendiente en el código (Claude Code)
1. **IDs reales de AdMob** (solo Free) — reemplazar los de prueba en:
   - `android/app/src/main/AndroidManifest.xml` → meta-data `com.google.android.gms.ads.APPLICATION_ID` (`ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY`)
   - `lib/core/ads/ad_manager.dart` → banner e interstitial de Android (`ca-app-pub-…/…`)
   - Mantener los de prueba en debug (`kDebugMode`) para no generar clics inválidos.
2. **Consentimiento UMP** (EEE/Reino Unido/Suiza): AdMob exige un CMP certificado. Con `google_mobile_ads` usar `ConsentInformation.instance.requestConsentInfoUpdate` + `ConsentForm.loadAndShowConsentFormIfRequired` antes de `MobileAds.instance.initialize()`, y una opción «Privacidad / anuncios» en Ajustes que llame a `showPrivacyOptionsForm` cuando `getPrivacyOptionsRequirementStatus()` sea `required`. Solo en la Free (`Edition.isPro` → no-op). Crear también el mensaje GDPR en AdMob › Privacidad y mensajes.
3. **Enlace a la política de privacidad** en Acerca de (las dos ediciones).
4. **app-ads.txt** en `https://www.easysoft.cl/app-ads.txt` con la línea que entrega AdMob (`google.com, pub-4383534162647782, DIRECT, f08c47fec0942fa0`; si ya existe para las otras apps, no hace falta cambiarlo).
5. Compilar: `bash build-app.sh aab` y verificar permisos de cada edición:
   `aapt dump permissions` sobre los APK (la Pro no debe tener `AD_ID` ni `ACCESS_ADSERVICES_*`; ninguna debe tener `READ_MEDIA_*` ni `READ_EXTERNAL_STORAGE`, ojo con permisos que agregue `file_picker`).
6. Commit + push.

## Pendiente en Play Console
- Crear las dos apps (cuenta EasySoft SPA recomendada: la cuenta personal nueva exige 12 testers × 14 días por app).
- Pro: perfil de pagos / cuenta de comerciante activa y precio.
- Ficha: ícono 512 (`icon-app_play_512[_pro].png` en la raíz), gráfico de funciones 1024×500, 4-8 capturas de teléfono (sin juegos comerciales ni logos de Sinclair/Amstrad; usar BASIC, Civtopia o demos propias).
- Subir AAB a prueba interna → prueba cerrada → producción.
