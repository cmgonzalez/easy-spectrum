# PDP — Prisma Debug Protocol (fase 1)

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
Símbolos (`.map`/`.lst`), historial de PC y detección de caída, watchpoints, condiciones, bancos
explícitos, perfilador, `frame-log`, input, `setreg`, ZX Spectrum Next, Android (no compilado aún),
activar desde la app de Flutter.
