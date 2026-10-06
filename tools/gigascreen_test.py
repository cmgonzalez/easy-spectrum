#!/usr/bin/env python3
"""Autotest de Gigascreen con la pantalla normal (banco 5) y la sombra (banco 7) de 128K.

  python tools/gigascreen_test.py [--dll ruta/zx_bridge.dll] [--keep]

Genera un .sna de 128K cuyo programa, en cada interrupción, conmuta el bit 3 de $7FFD
(pantalla normal <-> sombra) y comprueba en el framebuffer de zx_bridge.dll:
  - Sin Gigascreen: cada frame muestra una de las dos pantallas, y se ven las dos.
  - Con Gigascreen: se ve la mezcla en luz lineal, fija, y lo que es igual en ambas no cambia.

Contenido de las pantallas (tercios del papel):
  superior: banco 5 papel azul, banco 7 papel rojo  -> atributos distintos
  central:  mismo atributo (tinta blanca, papel negro); banco 5 píxeles 00, banco 7 FF
            -> difieren solo los píxeles
  inferior: idéntico en las dos (papel verde)          -> no debe cambiar nunca
"""
import argparse, ctypes, os, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DLLS = [os.path.join(ROOT, "build/windows/x64/zx_bridge/Release/zx_bridge.dll"),
        os.path.join(ROOT, "build/windows/x64/runner/Release/zx_bridge.dll")]
MODEL_128K = 2
BANK = 16384
FB_W, FB_H = 320, 256
PAPER_X, PAPER_Y = 32, 32

# Programa en $8000 (banco 2, nunca se pagina). Variable con el valor de $7FFD en $8100.
#   loop: HALT
#         LD A,($8100) / XOR 8 / LD ($8100),A
#         LD BC,$7FFD / OUT (C),A
#         JR loop
CODE = bytes([0x76,
              0x3A, 0x00, 0x81, 0xEE, 0x08, 0x32, 0x00, 0x81,
              0x01, 0xFD, 0x7F, 0xED, 0x79,
              0x18, 0xF0])
PORT_7FFD = 0x10    # ROM 48 BASIC (su IM1 es inofensiva con IY=$5C3A), banco 0, pantalla normal


def screen(attr_top, attr_mid, attr_bot, pix_mid):
    """Pantalla de 6912 bytes: píxeles 0 salvo el tercio central; atributos por tercio."""
    s = bytearray(6912)
    for third, pix in ((0, 0), (1, pix_mid), (2, 0)):
        s[third * 2048:(third + 1) * 2048] = bytes([pix]) * 2048
    for row in range(24):
        a = (attr_top, attr_mid, attr_bot)[row // 8]
        s[6144 + row * 32:6144 + (row + 1) * 32] = bytes([a]) * 32
    return bytes(s)


def make_sna(path):
    banks = [bytearray(BANK) for _ in range(8)]
    banks[5][0:6912] = screen(0x08, 0x07, 0x20, 0x00)   # azul / blanco-negro con 00 / verde
    banks[7][0:6912] = screen(0x10, 0x07, 0x20, 0xFF)   # rojo / blanco-negro con FF / verde
    banks[2][0:len(CODE)] = CODE                         # $8000
    banks[2][0x100] = PORT_7FFD                          # $8100

    h = bytearray(27)
    h[0x0F:0x11] = (0x5C3A).to_bytes(2, "little")        # IY
    h[0x13] = 0x04                                       # IFF2 = 1 (interrupciones activas)
    h[0x14] = 0                                          # R
    h[0x17:0x19] = (0x9000).to_bytes(2, "little")        # SP
    h[0x19] = 1                                          # IM 1
    h[0x1A] = 0                                          # borde negro
    paged = PORT_7FFD & 7
    data = h + banks[5] + banks[2] + banks[paged]
    data += (0x8000).to_bytes(2, "little") + bytes([PORT_7FFD, 0])
    data += b"".join(banks[b] for b in range(8) if b not in (2, 5, paged))
    assert len(data) == 131103
    with open(path, "wb") as f:
        f.write(data)


# Misma mezcla que SoftScanTarget::blend_into_front (gamma 2,2, tablas de 12 bits).
def to_linear(v): return round((v / 255) ** 2.2 * 4095)
def to_srgb(l): return round((l / 4095) ** (1 / 2.2) * 255)
def blend(a, b): return tuple(to_srgb((to_linear(x) + to_linear(y)) >> 1) for x, y in zip(a, b))


BLACK, BLUE, RED, GREEN, WHITE = (0, 0, 0), (0, 0, 0xD7), (0xD7, 0, 0), (0, 0xD7, 0), (0xD7, 0xD7, 0xD7)
# (nombre, fila de papel, color en banco 5, color en banco 7)
PROBES = [("superior (atributos)", 32, BLUE, RED),
          ("central (píxeles)", 96, BLACK, WHITE),
          ("inferior (igual)", 160, GREEN, GREEN)]


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--dll")
    ap.add_argument("--keep", action="store_true", help="dejar el .sna generado en tools/")
    a = ap.parse_args()
    dll = a.dll or next((d for d in DLLS if os.path.exists(d)), None)
    if not dll:
        sys.exit("zx_bridge.dll no encontrada (usa --dll)")
    L = ctypes.CDLL(dll)
    L.zx_create.restype = ctypes.c_void_p
    L.zx_create.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    L.zx_last_error.restype = ctypes.c_char_p
    L.zx_run.argtypes = [ctypes.c_void_p, ctypes.c_double]
    L.zx_get_framebuffer.restype = ctypes.POINTER(ctypes.c_uint8)
    L.zx_get_framebuffer.argtypes = [ctypes.c_void_p]
    L.zx_set_gigascreen.argtypes = [ctypes.c_void_p, ctypes.c_int]
    L.zx_get_audio.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
    L.zx_destroy.argtypes = [ctypes.c_void_p]

    sna = os.path.join(ROOT, "tools", "gigascreen_test.sna") if a.keep \
        else os.path.join(tempfile.gettempdir(), "gigascreen_test.sna")
    make_sna(sna)
    roms = os.path.join(ROOT, "assets", "roms")
    h = L.zx_create(roms.encode(), MODEL_128K, sna.encode(), 48000)
    if not h:
        sys.exit("zx_create falló: " + L.zx_last_error().decode())
    audio = (ctypes.c_int16 * 65536)()

    def pixel(y):
        fb = L.zx_get_framebuffer(h)
        i = ((PAPER_Y + y) * FB_W + PAPER_X + 128) * 4
        return (fb[i], fb[i + 1], fb[i + 2])

    def sample(ticks):
        """Una muestra por cada tick que produjo al menos un frame."""
        out = []
        for _ in range(ticks):
            n = L.zx_run(h, 0.02)
            L.zx_get_audio(h, audio, 65536)
            if n > 0:
                out.append({name: pixel(y) for name, y, _, _ in PROBES})
        return out

    failures = 0

    def check(ok, msg):
        nonlocal failures
        print(("  OK    " if ok else "  FALLA ") + msg)
        failures += 0 if ok else 1

    sample(25)   # medio segundo para asentar
    print("Sin Gigascreen (cada frame = una pantalla):")
    s = sample(100)
    for name, _, c5, c7 in PROBES:
        seen = {x[name] for x in s}
        want = {c5, c7}
        check(seen == want, f"{name}: visto {sorted(seen)}, esperado {sorted(want)}")
    alternating = sum(1 for p, q in zip(s, s[1:]) if p[PROBES[0][0]] != q[PROBES[0][0]])
    check(alternating > len(s) * 0.8, f"alterna entre frames consecutivos ({alternating}/{len(s) - 1})")

    L.zx_set_gigascreen(h, 1)
    sample(5)    # el primer frame tras activar sale sin mezclar
    print("Con Gigascreen (mezcla de normal + sombra):")
    s = sample(100)
    for name, _, c5, c7 in PROBES:
        seen = {x[name] for x in s}
        want = blend(c5, c7)
        check(seen == {want}, f"{name}: visto {sorted(seen)}, esperado {want}")

    L.zx_set_gigascreen(h, 0)
    sample(5)
    print("Gigascreen apagado de nuevo:")
    s = sample(50)
    seen = {x[PROBES[0][0]] for x in s}
    check(seen == {BLUE, RED}, f"vuelve a alternar: {sorted(seen)}")

    L.zx_destroy(h)
    if not a.keep:
        os.remove(sna)
    print("\n" + ("TODO OK" if not failures else f"{failures} FALLA(S)"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
