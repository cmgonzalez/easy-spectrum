#!/usr/bin/env python3
"""Host headless del core (zx_bridge.dll) con servidor PDP, para depurar sin la app de Flutter.

  python tools/pdp_host.py juego.tap --model 48k --port 7878

Corre el emulador a tiempo real (ticks de 20 ms como el Ticker) y deja el protocolo PDP en
127.0.0.1:<port>. Ver doc/PDP.md.
"""
import argparse, ctypes, os, sys, time

MODELS = {"16k": 0, "48k": 1, "128k": 2, "+2": 3, "+2a": 4, "+3": 5}
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DLLS = [os.path.join(ROOT, "build/windows/x64/zx_bridge/Release/zx_bridge.dll"),
        os.path.join(ROOT, "build/windows/x64/runner/Release/zx_bridge.dll")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("media", nargs="?", default="")
    ap.add_argument("--model", default="48k")
    ap.add_argument("--port", type=int, default=7878)
    ap.add_argument("--dll")
    ap.add_argument("--seconds", type=float, default=0, help="salir tras N segundos (0 = indefinido)")
    a = ap.parse_args()
    dll = a.dll or next((d for d in DLLS if os.path.exists(d)), None)
    if not dll:
        sys.exit("zx_bridge.dll no encontrada (usa --dll)")
    L = ctypes.CDLL(dll)
    L.zx_create.restype = ctypes.c_void_p
    L.zx_create.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    L.zx_last_error.restype = ctypes.c_char_p
    L.zx_run.argtypes = [ctypes.c_void_p, ctypes.c_double]
    L.zx_pdp_start.argtypes = [ctypes.c_void_p, ctypes.c_int]
    L.zx_destroy.argtypes = [ctypes.c_void_p]
    L.zx_get_audio.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
    roms = os.path.join(ROOT, "assets", "roms")
    h = L.zx_create(roms.encode(), MODELS.get(a.model.lower(), 1), a.media.encode(), 48000)
    if not h:
        sys.exit("zx_create fallo: " + L.zx_last_error().decode())
    port = L.zx_pdp_start(h, a.port)
    if port < 0:
        sys.exit("no se pudo abrir el puerto %d" % a.port)
    print("PDP escuchando en 127.0.0.1:%d" % port, flush=True)
    buf = (ctypes.c_int16 * 65536)()
    t0 = nxt = time.time()
    try:
        while not a.seconds or time.time() - t0 < a.seconds:
            L.zx_run(h, 0.02)
            L.zx_get_audio(h, buf, 65536)   # vaciar el ring de audio
            nxt += 0.02
            d = nxt - time.time()
            if d > 0:
                time.sleep(d)
            else:
                nxt = time.time()
    except KeyboardInterrupt:
        pass
    L.zx_destroy(h)


main()
