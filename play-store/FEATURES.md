# Easy Spectrum — Características completas

Documento de referencia para redactar fichas de tienda (Google Play, web, etc.). Describe lo que el emulador **realmente hace** hoy. Lo marcado «no incluido» o «pendiente» no debe prometerse en la ficha.

- **Qué es:** emulador de ZX Spectrum para Android y Windows, con estética Spectrum (negro + arcoíris) y una interfaz accesible (botones grandes, texto grande).
- **Desarrollador:** EasySoft SPA — soporte@easysoft.cl — https://www.easysoft.cl
- **Política de privacidad:** https://www.easysoft.cl/easy-spectrum/privacy.html
- **Idiomas de la app:** español, inglés, portugués, italiano, ruso (inglés como reserva).
- **Ediciones Android:**
  - **Easy Spectrum** (`cl.easysoft.easyspectrum`): gratuita, con anuncios (banner en la pantalla de inicio e interstitial al salir de un juego).
  - **Easy Spectrum Pro** (`cl.easysoft.easyspectrum.pro`): de pago, **sin anuncios**; mismas funciones. Cada edición guarda sus propios datos (biblioteca y ajustes no se comparten).
- **Windows:** programa de escritorio (instalador o zip), sin anuncios.

---

## Características comunes (Android y Windows)

### Máquinas emuladas
- ZX Spectrum 16K, 48K, 128K, +2, +2A y +3.
- ZX Spectrum Next: solo para ejecutar programas `.nex` (sin NextZXOS; ver sección propia).
- Núcleo basado en Clock Signal (CLK, Thomas Harte, licencia MIT). Funciona a 50 fps, con sonido a 48 kHz.
- ROMs incluidas en la app (Amstrad permite distribuirlas con emuladores); no hace falta buscarlas.

### Formatos de archivo
- Cintas: `.tap`, `.tzx`, `.csw`.
- Instantáneas (snapshots): `.z80`, `.sna` (incluidos 48K y 128K), `.szx`.
- Discos: `.dsk` (+3).
- Next: `.nex`.
- Archivos `.zip` que contengan cualquiera de los anteriores.
- No hay guardado de estado propio (save states): no incluido.

### Carga de cintas
- **Autocarga:** al abrir una cinta, la app teclea sola el comando de carga correcto según el modelo.
- **Carga rápida (turbo):** mientras la cinta gira, el emulador acelera hasta ×50 sin dibujar ni sonar; sirve también con cargadores propios (Speedlock, Ocean, etc.), no solo con el cargador estándar. Una cinta que tardaba unos 3,5 minutos carga en unos 40 segundos. Indicador ⏩ en pantalla. Se puede desactivar.
- Una pulsación del usuario suspende el turbo (útil en cintas de varias cargas).

### Gestor de cintas
- Lista de bloques de la cinta, con la posición actual.
- Controles de grabadora: grabar ●, reproducir ▶, pausa ⏸, detener ■, bloque anterior ⏮, bloque siguiente ⏭, expulsar ⏏.
- Crear una cinta nueva a partir de archivos.
- **Grabar SAVE:** el SAVE hecho desde BASIC del 48K se captura a una cinta nueva.
- Android: panel inferior con un casete dibujado; Windows: panel lateral.

### Pantalla
- Modos de vídeo: **Nítido** (por defecto), **Suave**, **Bordes redondeados**, **Monitor** y **TV CRT** (los dos últimos con shader: curvatura, líneas de escaneo, máscara RGB, resplandor y viñeta).
- **Gigascreen** (opcional): mezcla fotogramas consecutivos para mostrar más colores, como en hardware real.
- **ULAplus**: paleta de 64 colores (siempre activo).
- Borde de pantalla visible; opciones de borde en Ajustes.

### Sonido
- Beeper y AY-3-8912 (128K/+2/+3), estéreo.
- Interruptor de sonido en la interfaz.

### Joystick y ratón
- Joystick: Kempston, Sinclair 1 (6-7-8-9-0), Sinclair 2 (1-2-3-4-5), Cursor, o **teclas propias**.
- **Ratón Kempston** (el que usan algunos programas con puntero).

### Biblioteca «Mis juegos»
- Importar archivos (también `.zip`); lista con miniatura de cada juego.
- **Miniaturas:** se sacan de la pantalla de carga del archivo; si no la tiene (cinta cifrada, `.dsk`…), se guarda una captura del propio emulador al salir del juego.
- **Fichas por internet (opcional, activado por defecto):** busca título, año, editor, género y pantalla de carga en la base ZXDB (zxinfo.dk) enviando solo el hash (MD5) del archivo; sin cuenta ni claves. Se puede desactivar en Ajustes. Si no hay red, todo funciona igual.
- Configuración de control guardada **por juego**.
- Abrir un juego directamente desde BASIC (sin cinta).

### Depuración (para desarrolladores)
- Protocolo de depuración propio (PDP) por TCP: puntos de ruptura, paso a paso, memoria, POKE, reset; también para programas Next. Pensado para desarrollo de juegos PRISMA. No es una función de cara al usuario final.

---

## Solo Android

### Interfaz de consola portátil
- Pantalla del juego dentro de una consola dibujada: LED POWER, vidrio con la imagen, **panel LCD** con letrero que se desplaza (juego, año, editor, género, control activo) y **dos mitades táctiles ENTER | ESPACIO**.
- Fila de 4 botones de colores: configurar control (rojo), ajustes (amarillo), teclado/mando (verde), volver a la lista (azul). Quedan en el mismo sitio con mando y con teclado.
- Orientación vertical y horizontal.

### Mando táctil
- Cruceta de 8 direcciones (se puede deslizar el dedo) y botón de fuego.
- Botonera configurable de **1 a 4 botones** (rojo = fuego; amarillo, verde y azul = cualquier tecla).
- Botones **Select / Start** opcionales (0, 1 o 2), cada uno con su tecla.
- Botón de **salto** configurable (envía «arriba»).
- Vibración háptica suave en la cruceta y firme en los botones.
- Touchpad con un botón para el ratón Kempston.

### Teclado en pantalla
- Teclado de ZX Spectrum fiel al original, multitáctil; CAPS SHIFT y SYMBOL SHIFT se fijan con un toque y se sueltan tras la siguiente tecla.

### Abrir archivos desde otras apps
- Aparece en «Abrir con» / «Compartir» de gestores de archivos, WhatsApp, Telegram, descargas, etc. Si el archivo perdió su extensión, la app la deduce del contenido.

### Ajustes
- Control por defecto, modo de vídeo, Gigascreen, carga rápida, información en línea, opciones de borde, y «Privacidad y anuncios» (solo Free, solo donde la ley exige consentimiento).
- **Anuncios (solo Free):** AdMob con consentimiento UMP en la UE/Reino Unido/Suiza. La Pro no incluye anuncios ni permisos publicitarios.

### Permisos Android
- Free: internet, estado de red, vibración, ID de publicidad (AdMob).
- Pro: internet, estado de red, vibración. **Ningún acceso a fotos, vídeos, audio ni almacenamiento general**; los archivos se eligen con el selector del sistema.

---

## Solo Windows

- Ventana con la salida del Spectrum y **barra de menús nativa** de Windows con colores Spectrum: Archivo (abrir, recargar, recientes, BASIC), Máquina (modelo, reset, pausa, velocidad, carga rápida, cinta), Pantalla (modo, tamaño ×1–×4, pantalla completa, Gigascreen), Joystick, Ayuda. Barra de herramientas.
- Arrastrar y soltar archivos sobre la ventana.
- **Teclado del PC mapeado por posición** (Shift = CAPS, Ctrl = SYMBOL, signos por carácter); flechas + Alt/Tab como joystick o cursores.
- Atajos: F2 recargar, F3 abrir, F5 reset, F6 cinta, F8 pausa, F11 / Alt+Enter pantalla completa.
- **Ratón Kempston** capturando el puntero (F9 lo suelta).
- **Instancia única:** abrir otro archivo lo envía a la ventana ya abierta.
- **Instalador** (Inno Setup, sin permisos de administrador; opción para todos los usuarios; idiomas es/en/pt/it/ru). Aparece siempre en «Abrir con» para `.tap .tzx .z80 .sna .szx .dsk .csw` y `.zip`, y puede quedar como programa predeterminado (salvo `.zip`).
- **Línea de comandos:** `EasySpectrum.exe juego.tap --model 48k|128k|+2|+2a|+3|16k`.
- Sin anuncios y sin biblioteca: los archivos se abren donde están.

---

## ZX Spectrum Next (solo programas `.nex`)

Máquina propia (no usa CLK), sin NextZXOS:
- CPU Z80N (todas las extensiones; supera el test `zexdoc`), 2 MB de memoria con MMU de 8 páginas, 28 MHz.
- Vídeo: ULA (estándar, Timex, LoRes, ULANext), Layer 2 (256×192, 320×256, 640×256), tilemap (40/80 columnas), **128 sprites** (4 bpp, escala, rotación), Copper, mezcla de capas.
- Sonido: 3× AY + DAC + beeper. DMA zxnDMA.
- **esxDOS parcial:** los programas pueden leer/escribir archivos de una carpeta (los `.zip` con assets se extraen junto al juego).
- Teclado, joystick Kempston y reset funcionan igual que en las otras máquinas.
- **No incluido todavía:** teclas extendidas de la Next, ratón Kempston en la Next, CTC/UART/divMMC, modo 60 Hz, ejecutar NextZXOS o imágenes de SD.

---

## Qué NO hace (no prometer en la ficha)
- No incluye juegos comerciales; el usuario aporta sus propios archivos.
- No guarda/restaura estados (save states).
- No emula ZX81, otros ordenadores ni consolas.
- No tiene multijugador en línea ni cuentas de usuario.
- iOS: preparado en el código, **sin probar ni publicado**.
- Archivos `.sna` de Amstrad CPC no son compatibles (se informa del error).

## Notas para la ficha
- Palabras clave naturales: ZX Spectrum, emulador, retro, cintas .tap .tzx, snapshots .z80 .sna, 48K, 128K, +3, Next, joystick Kempston, juegos clásicos.
- Evitar logos y marcas de Sinclair/Amstrad y capturas de juegos comerciales (ver `play-store/README.md`).
- Las dos apps se describen con el mismo texto; la Pro destaca «sin anuncios».
