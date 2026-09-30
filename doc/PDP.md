# PDP — Prisma Debug Protocol (fases 1 y 2)

Depurador del core CLK (Spectrum 16K–+3) para juegos PRISMA. JSON por línea sobre TCP,
solo `127.0.0.1`. Un objeto por línea; cada petición lleva `id` y `cmd`; la respuesta repite el `id`
con `ok` (o `error`). Direcciones: decimal, `0x1F`, `$1F`; en las respuestas, `"0x1F00"`.

Host headless: `python tools/pdp_host.py juego.tap --model 48k --port 7878` (usa `zx_bridge.dll`;
compilar con `bash build-app.sh windows` o con el cmake de `build/windows/x64/zx_bridge`).
Cliente: `python tools/pdp.py regs`. Autotest: `python tools/pdp_selftest.py`.
Desde C: `zx_pdp_start(h, port)` / `zx_pdp_stop(h)` (zx_bridge.h).

| cmd | parámetros | respuesta |
|---|---|---|
| `hello` | | protocolo, máquina, `state` |
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
Líneas C (`.lst`), bancos explícitos (`$7FFD`), perfilador, `frame-log`, input, `setreg`,
ZX Spectrum Next, Android (no compilado aún), activar desde la app de Flutter.
