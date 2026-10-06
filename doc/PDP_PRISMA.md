# Depurar juegos PRISMA con Easy Spectrum (PDP) — guía para la IA de PRISMA

Easy Spectrum (Windows) trae un depurador por TCP, **PDP**, que sustituye a ZRCP de ZEsarUX. Lee
registros y memoria, pone breakpoints/watchpoints, mide T-states por función, inyecta teclas y saca
capturas, todo con los símbolos de `build/game.map`. Referencia completa: `C:\dev\easy-spectrum\doc\PDP.md`.

> Regla de PRISMA: no lances el emulador sin OK del usuario. Pídele que abra Easy Spectrum con el
> comando de abajo (o pídele permiso para hacerlo tú) y luego conéctate.

## 1. Arrancar (lo hace el usuario o tú con su permiso)

```powershell
$env:EASYSPECTRUM_PDP_PORT = 7878
& "$env:LOCALAPPDATA\Programs\Easy Spectrum\EasySpectrum.exe" C:\prisma\out\JUEGO.tap --model 128k
```
(`--model 48k|128k|+2|+2a|+3|16k`; con la app ya abierta, recargar el `.tap` es F4). Usa la ruta real
de instalación si es otra. Preferir `.z80`/`.sna` a `.tap`: arrancan directo en el juego. Sin
`EASYSPECTRUM_PDP_PORT` no hay depurador.

Alternativa sin ventana (mismo núcleo, tiempo real):
`python C:\dev\easy-spectrum\tools\pdp_host.py C:\prisma\out\JUEGO.z80 --model 128k --port 7878`.

## 2. Conectar

Cliente de línea de comandos (una orden por llamada, salida JSON):
```bash
python C:/dev/easy-spectrum/tools/pdp.py regs
python C:/dev/easy-spectrum/tools/pdp.py --port 7878 mem 0x8000 16
```
Como librería (mejor para sesiones largas: una conexión, varios comandos):
```python
import sys; sys.path.insert(0, r"C:\dev\easy-spectrum\tools")
from pdp import Pdp
c = Pdp(7878)
c.cmd("load_map", path=r"C:\prisma\build\game.map")   # símbolos: hacerlo SIEMPRE primero
print(c.cmd("pause", wait=True))                       # {'state':'stopped','pc':'0x8012','pc_sym':'_main+0x12'...}
```
`c.cmd(nombre, **params)` devuelve el JSON de la respuesta (`ok`, o `error`).
Las direcciones aceptan `0x8000`, `$8000`, decimal o **símbolos** (`_main`, `game_key`, `_main+3`).
Las respuestas traen las direcciones como `"0x1F00"` y, si hay símbolo, `pc_sym`/`addr_sym`.

**Modelo de ejecución:** la máquina corre libre hasta que la detienes. `pause`, `resume`, `step`, `next`
devuelven enseguida; con `wait=True` la respuesta espera a la parada y trae `reason` (`pause`,
`breakpoint`, `step`, `until`, `watch`, `crash`, `frames`) y `pc`. Sin `wait`, la parada llega como evento
(se acumula en `c.events`).

## 3. Recetas

**Ver dónde está y qué pasa**
```python
c.cmd("pause", wait=True); c.cmd("regs"); c.cmd("history", n=30)   # últimas 30 instrucciones, con símbolo
c.cmd("screenshot", path=r"C:\tmp\pantalla.png", paper=True)       # y luego mirar la imagen
```

**Breakpoint (con condición) y avanzar**
```python
c.cmd("break", addr="_player_update", cond="a==10")      # cond: reg|[dir] OP valor (== != < > <= >= &)
r = c.cmd("resume", wait=True)                           # r["reason"]=="breakpoint"
c.cmd("step", wait=True); c.cmd("next", wait=True)       # next salta CALL/RST/LDIR
c.cmd("unbreak", addr="all")
```

**Quién escribe esta variable** (el caso más útil para bugs de estado)
```python
c.cmd("watch", addr="game_key", type="w")                # también len=, value=, cond=, type="rw"
r = c.cmd("resume", wait=True)                           # reason "watch", addr, value, pc_sym = la función culpable
c.cmd("unwatch", addr="all")
```

**El juego se reinicia o se cuelga** (resets a BASIC, pantalla negra)
```python
c.cmd("catch", on="reset,nmi,dihalt")      # para AL CAER; "rom" añade toda entrada RAM→ROM (ruidoso)
r = c.cmd("resume", wait=True)
print(c.cmd("crash"))                      # estado, regs, history(24), stack(8 palabras con símbolo), "from" = quién saltó
```
`dihalt` = HALT con interrupciones apagadas (bloqueo seguro). `reset` = entrar en $0000 desde RAM.
Mira `from`, el último elemento de `history` y `stack` (una dirección de retorno corrupta se ve ahí).

**Rendimiento: ¿cabe en el frame?**
```python
c.cmd("profile", on=True); c.cmd("resume", frames=50, wait=True)
print(c.cmd("profile", top=15))            # T-states y % por función (por símbolo del .map); by="addr" por dirección
c.cmd("framelog", set="[game_key],[_player_x]w")          # columnas: registros o [mem] (w = palabra)
c.cmd("resume", frames=100, wait=True); c.cmd("framelog", n=100)
```
Un frame son 69888 T (48K) / 70908 T (128K). En `framelog`, la columna `idle` son los T-states
gastados en HALT de ese frame: margen libre (0 = el juego no llega; se ve como frames perdidos).

**Reproducir una partida de forma determinista** (las teclas se sueltan por frames emulados, no por tiempo real)
```python
c.cmd("key", name="enter", frames=3)                     # tap; state="down"/"up" para mantener; "caps+1" combina
c.cmd("resume", frames=30, wait=True)
c.cmd("joy", dirs="right+fire", frames=20)               # Kempston; "none" suelta
c.cmd("resume", frames=20, wait=True)
c.cmd("get", addr="_player_x", len=2)                    # valor (little endian); para más bytes: mem
c.cmd("type", text="LOAD \"\"\n")                        # Typer de CLK
```

**128K / bancos**
```python
c.cmd("paging")                                          # p7ffd, banco en $C000, pantalla 5/7, rom, bloqueo
c.cmd("mem", addr=0x0000, len=32, bank=3)                # RAM banco 3 (offset 0-0x3FFF); rom=0 para ROM
c.cmd("poke", addr="_var", data="01FF")                  # o value=5; bank= para escribir en un banco
```
`mem`/`poke` sin `bank` ven lo que ve la CPU (lo paginado ahora). Los símbolos del `.map` no distinguen
banco: si una rutina vive en un banco paginado, su dirección es la de la ventana `$C000`.

## 4. Referencia rápida

| Orden | Parámetros |
|---|---|
| `load_map` | `path` |
| `pause` `resume` `step` `next` | `wait`, `until` (resume), `frames` (resume) |
| `break` `unbreak` `breaks` | `addr`, `cond` / `addr="all"` |
| `watch` `unwatch` `watches` | `addr`, `len`, `type` r/w/rw, `value`, `cond` |
| `regs` `status` `paging` | — |
| `mem` `poke` `get` | `addr`, `len`, `data` hex, `value`, `bank`, `rom` |
| `history` | `n` ≤ 4096 |
| `catch` `crash` | `on`: reset,nmi,rom,dihalt,all,none |
| `profile` `framelog` | ver recetas |
| `key` `joy` `type` | ver recetas |
| `sym` `symbols` | `q` / `filter`, `limit` |
| `screenshot` | `path`, `paper` |
| `reset` | — |

## 5. Límites y gotchas

- **Registros a medias tras un `watch`**: la parada es a mitad de instrucción (el acceso ya ocurrió); `pc` es el
  inicio de la instrucción. Para estado limpio haz `step`. No hay `setreg` (usa `poke` en memoria).
- **Breakpoint en un HALT** solo salta la primera vez que lo alcanza.
- La depuración es del core Clock Signal (Spectrum 16K–+3). **No** cubre `.nex`/Next ni otros targets de PRISMA (CPC, MSX, SMS).
- Sin líneas C: los símbolos dan función/variable (`_main+0x12`) y `sym` devuelve el `archivo.c:línea` de
  la *función*; para la línea exacta usa `build/*.lst`.
- El historial guarda PCs (64K instrucciones); en turbo de carga de cinta se llena muy rápido: depura
  con `.z80`/`.sna`.
- Una sola máquina por puerto: si abres otro juego en la app, el servidor se reabre en el mismo puerto y
  hay que reconectar (`Pdp(7878)` de nuevo y `load_map`).
- Si `build/game.map` cambia (recompilaste), vuelve a cargar el juego **y** el mapa.
