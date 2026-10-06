# PDP — Prisma Debug Protocol (fases 1 a 4)

Depurador del core CLK (Spectrum 16K–+3) y de la Next (`.nex`) para juegos PRISMA. JSON por línea sobre TCP,
solo `127.0.0.1`. Un objeto por línea; cada petición lleva `id` y `cmd`; la respuesta repite el `id`
con `ok` (o `error`). Direcciones: decimal, `0x1F`, `$1F`; en las respuestas, `"0x1F00"`.

Host headless: `python tools/pdp_host.py juego.tap --model 48k --port 7878` (usa `zx_bridge.dll`;
compilar con `bash build-app.sh windows` o con el cmake de `build/windows/x64/zx_bridge`).
Cliente: `python tools/pdp.py regs`. Autotest: `python tools/pdp_selftest.py`.
Desde C: `zx_pdp_start(h, port)` / `zx_pdp_stop(h)` (zx_bridge.h).

| cmd | parámetros | respuesta |
|---|---|---|
| `hello` | | protocolo, máquina, `model` (`48k`, `128k`, `+3`, `tc2048`, `ts2068`, `next`…), `state` |
| `status` | | `state`, `emulated` (s), `breakpoints` |
| `pause` / `resume` (`run`) / `step` / `next` | `wait:true` espera a la parada; `resume` admite `until` | `state`, `reason`, `pc` |
| `regs` | | `regs{pc,sp,af,bc,de,hl,af2..hl2,ix,iy,memptr,i,r,iff1,iff2,im,flags}` |
| `mem` | `addr`, `len` (≤4096) | `data` (hex) |
| `poke` | `addr`, `data` (hex) o `value` | `written` |
| `break` / `unbreak` / `breaks` | `addr` (`"all"` en unbreak) | |
| `reset` | | |

### Fase 2: símbolos, condiciones, watchpoints, historial, caídas
| cmd | parámetros | respuesta |
|---|---|---|
| `load_map` | `path` (`build/game.map` de z88dk; solo entradas `addr`) | `symbols` |
| `sym` | `q` = símbolo o dirección | `addr`, `addr_sym` (`_main+0x3`), `src` (`archivo.c:línea` del símbolo) |
| `symbols` | `filter`, `limit` | lista `"0xADDR nombre"` |
| `get` | `addr`, `len` (1-4) | `value` (little endian) |
| `watch` | `addr`, `len`, `type` (`r`/`w`/`rw`), `value` (solo escrituras de ese valor), `cond` | |
| `unwatch` / `watches` | `addr` o `"all"` | |
| `history` | `n` (≤4096) | últimas instrucciones, la más antigua primero, con símbolo |
| `catch` | `on`: `reset,nmi,rom,dihalt` (`all` = todo salvo `rom`; `none`) | |
| `crash` | (detenida) | estado + `regs` + `history`(24) + `stack`(8 palabras) |

- **Símbolos** valen en cualquier dirección: `"addr":"_main+3"` (con o sin `_`). Las respuestas llevan
  `pc_sym`, `addr_sym`, `from_sym`.
- **`cond`** (en `break` y `watch`): `reg OP valor` o `[dir]`/`[dir]w` (byte/palabra) `OP valor`;
  OP = `== != < > <= >= &`; regs `pc sp af bc de hl ix iy a f b c d e h l i r iff1 iff2 im`.
  Ej.: `a==10`, `[game_key]!=0`, `hl&0x8000`.
- **Watch**: para con el acceso ya hecho y a mitad de instrucción; `pc` = inicio de la instrucción que
  accedió (los registros de `regs` pueden estar a medias). Stop con `reason:"watch"`, `addr`, `value`, `access`.
- **Caídas** (`reason:"crash"`, `detail`, `from` = instrucción anterior): `reset` = entrar en `$0000` desde
  RAM; `nmi` = `$0066`; `rom` = cualquier RAM→ROM salvo `$0038` (ruidoso: los juegos llaman a la ROM);
  `dihalt` = HALT con interrupciones apagadas (bloqueo seguro). El último elemento de `history` es la
  propia búsqueda que paró (p. ej. `0x0000`).
- El historial (64K instrucciones, solo PCs) se graba siempre que el servidor está activo.

### Fase 3: bancos, frames, perfilador, frame-log, entrada
| cmd | parámetros | respuesta |
|---|---|---|
| `mem` / `poke` | `bank` (RAM 0-7) o `rom` (0-3, solo lectura); `addr` = desplazamiento 0-0x3FFF | |
| `paging` | | `p7ffd`, `p1ffd`, `ram_c000` (banco en C000), `screen` (5/7), `rom_bit`, `locked`; en TC2048/TS2068 además `timex_ff`, `timex_f4` y `screen_mode` (b0-2 de `$FF`) |
| `resume` | `frames:N` | para tras N frames exactos (`reason:"frames"`) |
| `profile` | `on:true/false`, `reset:true`; sin ellos informa: `top`, `by:"func"\|"addr"` | `total_tstates`, `profile[{name,tstates,pct,instr}]` |
| `framelog` | `set:"a,[_var],[game_key]w"` (columnas y arranca), `stop`/`start`/`clear`; sin ellos: `n` | `columns`, `rows` = `[frame, idle, valores...]` |
| `key` | `name` (`a`, `enter`, `caps+1`), `state:"tap"\|"down"\|"up"`, `frames` (defecto 3) | |
| `joy` | `dirs` (`left+fire`, `none`) o `mask`, `state`, `frames` | `mask` |
| `type` | `text` (Typer de CLK) | |

- El reloj de la máquina cuenta half cycles (parche en `advance`); un frame = 69888 T (16K/48K) o 70908 T
  (128K y posteriores). `status` da `frame`. Con `resume frames:N` + `key`/`joy` se puede reproducir una
  partida de forma determinista (las teclas se sueltan por frames emulados, no por tiempo real).
- **Perfilador**: tiempo entre dos búsquedas consecutivas = duración de la instrucción anterior
  (incluye contención y el reconocimiento de interrupciones). Agrupa por símbolo del `.map`
  (`?0xNN00` si no hay). Verificado: 10 frames = 698868 T (ideal 698880).
- **`idle` del frame-log** = T-states gastados ejecutando HALT en ese frame: margen libre del juego.
- `frame-log` guarda 8192 frames en anillo.

### Fase 4: captura y activación desde la app
- `screenshot`: `path` (escribe un PNG) o, sin él, `png_base64`; `paper:true` = solo 256×192 sin borde.
  PNG sin dependencias (deflate "stored"), 320×256 por defecto.
- **App de Flutter (escritorio)**: con `EASYSPECTRUM_PDP_PORT=7878` en el entorno, cada máquina que arranca
  abre el servidor en ese puerto (`ZxBridge.start`). Sin la variable no se abre nada. Android: no se activa.
- `zx_pdp.cpp` pasa `clang -fsyntax-only` con el NDK (x86_64-android24); falta una compilación Android completa.

Evento asíncrono a todos los clientes al detenerse: `{"event":"stopped","reason":...,"pc":...}`.
`reason`: `pause`, `breakpoint`, `step`, `until`. `next` salta CALL/RST/HALT/bloques (LDIR…).

## Cómo funciona (no obvio)
- `zx_debug.h`: `on_fetch()` se llama desde el bus handler en cada `ReadOpcode` (parche 4 de
  `native/CMakeLists.txt` + `clk_patches/pdp_methods.inc`). Con el servidor apagado cuesta un bool.
- Para detener la CPU el bus handler devuelve un retraso enorme (2^40 half cycles): el Z80 de CLK lo
  resta de su contador y sale de `run_for()` en la siguiente operación de bus con el estado intacto.
  Reanudar = devolvérselo (`credit`). **Detenida, no se debe llamar a `run_for()`** (`zx_run` ya lo evita).
- Los registros son una foto al inicio de la instrucción en la que se paró; por eso no hay `setreg`.
- Prefijos CB/ED/DD/FD: solo la primera búsqueda cuenta como inicio de instrucción. HALT solo dispara
  un breakpoint la primera vez (re-busca su opcode en cada ciclo).
- Todos los comandos corren en el hilo del emulador (`pdp::pump`, desde `zx_run`); el hilo del servidor
  solo mueve bytes.

## Pendiente (fases siguientes)
Líneas C (`.lst`), `setreg`, compilación Android completa.

## ZX Spectrum Next (`.nex`)

La máquina propia de `native/next/` también se depura con el mismo servidor (`hello` → `machine:"next"`).
No hay hook de bus ni deuda de ciclos como en CLK: `NextMachine::cpu_step()` llama a `zxdbg::on_fetch`
antes de cada instrucción y, si para, `run_line()` sale sin ejecutarla (la línea se retoma al reanudar,
`dbg_skip_` evita re-evaluar el punto de parada de la instrucción en la que se paró). Al ser parada
entre instrucciones, `regs` es exacto. Diferencias:
- **Watchpoints**: se evalúan en `read()`/`write()` del bus (no en el fetch de opcodes/inmediatos); la
  instrucción termina antes de parar, y `regs` la refleja ya ejecutada (`pc` = inicio de la instrucción).
  Los accesos de la DMA también cuentan.
- `mem`/`poke`/`get` usan el mapa **actual** del MMU (slot 0 = ROM si `$FF`). Extras: `bank` = banco de
  16 KB (0-127), `page` = página de 8 KB (0-255, `addr` = desplazamiento 0-0x1FFF).
- `mmu` → `mmu:[8 páginas]` (`255` = ROM) y `speed` (0..3 = 3,5/7/14/28 MHz). `nextreg` (`reg`, `len`) lee NextRegs.
  `paging` solo da `p7ffd`. Estos tres solo existen en la Next.
- `profile`/`framelog`: el reloj va en half cycles de 3,5 MHz aunque la CPU corra a 28 MHz.
- Probar sin Flutter: `clang++ -std=c++17 -O2 -DNOMINMAX tools/nextpdp.cpp native/zx_pdp.cpp native/next/*.cpp -lws2_32`
  y `python tools/pdp_next_selftest.py <nextpdp.exe>` (25 comprobaciones: break, step, next, watch, mem, page, mmu, reset).
