#!/usr/bin/env python3
"""Autotest de Timex (TC2048 / TS2068) y ULAplus extendido con zx_bridge.dll.

  python tools/timex_test.py [--dll ruta/zx_bridge.dll] [--ppm carpeta]

Genera .z80 v3 propios y comprueba en el framebuffer:
  - TC2048 y TS2068 arrancan en BASIC (ROM tc2048.rom / ts2068.rom).
  - Modos de $FF: segunda pantalla ($6000), hi-color 8x1 y hi-res 512 (colores y borde).
  - ULAplus extendido en un 48K: OUT ($BF3B),$42 activa el hi-color; con el ajuste en 1
    (solo paleta) o 0 (apagado), no.
  - TS2068: la MMU ($F4 + bit 7 de $FF) mapea el EXROM en $0000, el AY en $F5/$F6 se lee y
    el joystick 1 sale por el registro 14 (activo a 0).
"""
import argparse, ctypes, os, sys, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DLLS = [os.path.join(ROOT, "build/windows/x64/zx_bridge/Release/zx_bridge.dll"),
        os.path.join(ROOT, "build/windows/x64/runner/Release/zx_bridge.dll")]
ROMS = os.path.join(ROOT, "assets/roms")
FB_W, FB_H = 320, 256
PX, PY = 32, 32
M48, TC2048, TS2068 = 1, 7, 8
JOY_UP, JOY_FIRE = 1, 16

PAL = [(0, 0, 0), (0, 0, 0xD7), (0xD7, 0, 0), (0xD7, 0, 0xD7), (0, 0xD7, 0), (0, 0xD7, 0xD7), (0xD7, 0xD7, 0), (0xD7, 0xD7, 0xD7),
       (0, 0, 0), (0, 0, 0xFF), (0xFF, 0, 0), (0xFF, 0, 0xFF), (0, 0xFF, 0), (0, 0xFF, 0xFF), (0xFF, 0xFF, 0), (0xFF, 0xFF, 0xFF)]


def load_dll(path):
    L = ctypes.CDLL(path)
    L.zx_create.restype = ctypes.c_void_p
    L.zx_create.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    L.zx_last_error.restype = ctypes.c_char_p
    L.zx_run.argtypes = [ctypes.c_void_p, ctypes.c_double]
    L.zx_get_framebuffer.restype = ctypes.POINTER(ctypes.c_uint8)
    L.zx_get_framebuffer.argtypes = [ctypes.c_void_p]
    L.zx_get_audio.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
    L.zx_get_model.argtypes = [ctypes.c_void_p]
    L.zx_set_joystick.argtypes = [ctypes.c_void_p, ctypes.c_int]
    L.zx_set_ulaplus.argtypes = [ctypes.c_void_p, ctypes.c_int]
    L.zx_save_snapshot.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    L.zx_destroy.argtypes = [ctypes.c_void_p]
    return L


class Machine:
    def __init__(self, L, model, path=None):
        self.L = L
        self.h = L.zx_create(ROMS.encode(), model, (path or "").encode(), 48000)
        if not self.h:
            raise RuntimeError("zx_create: " + L.zx_last_error().decode())
        self.audio = (ctypes.c_int16 * 65536)()

    def run(self, seconds):
        t = 0.0
        while t < seconds:
            self.L.zx_run(self.h, 0.02)
            self.L.zx_get_audio(self.h, self.audio, 32768)
            t += 0.02

    def fb(self):
        return ctypes.string_at(self.L.zx_get_framebuffer(self.h), FB_W * FB_H * 4)

    def close(self):
        self.L.zx_destroy(self.h)


def px(fb, x, y):
    o = (y * FB_W + x) * 4
    return tuple(fb[o:o + 3])


def save_ppm(fb, path):
    with open(path, "wb") as f:
        f.write(b"P6 %d %d 255\n" % (FB_W, FB_H))
        f.write(b"".join(fb[i:i + 3] for i in range(0, len(fb), 4)))


def compress(page):
    out, i = bytearray(), 0
    while i < len(page):
        b, n = page[i], 1
        while i + n < len(page) and page[i + n] == b and n < 255:
            n += 1
        if n >= 5 or (b == 0xED and n >= 2):
            out += bytes([0xED, 0xED, n, b])
            i += n
        else:
            out.append(b)
            if b == 0xED and i + 1 < len(page):	# ED suelto seguido de otro byte: no comprimir el siguiente
                out.append(page[i + 1])
                i += 1
            i += 1
    return bytes(out)


def make_z80(path, hw, ram48, pc, ff=0, f4=0, sp=0xFF00):
    """.z80 v3 (54 bytes) con 48K lineal desde $4000 (ram48[0] = $4000)."""
    h = bytearray(30)
    h[8:10] = sp.to_bytes(2, "little")
    h[12] = 0                       # borde negro
    h[23:25] = (0x5C3A).to_bytes(2, "little")   # IY
    h[29] = 1                       # IM 1
    x = bytearray(56)
    x[0:2] = (54).to_bytes(2, "little")
    x[2:4] = pc.to_bytes(2, "little")
    x[4] = hw
    x[5] = f4
    x[6] = ff
    data = h + x
    for page, off in ((8, 0x0000), (4, 0x4000), (5, 0x8000)):
        c = compress(ram48[off:off + 0x4000])
        data += len(c).to_bytes(2, "little") + bytes([page]) + c
    with open(path, "wb") as f:
        f.write(data)


def scr_addr(y, xbyte):
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | xbyte


FAILS = []


def check(name, ok, detail=""):
    print(("OK   " if ok else "FAIL ") + name + ("" if ok else "  " + detail))
    if not ok:
        FAILS.append(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dll")
    ap.add_argument("--ppm", help="carpeta donde guardar capturas .ppm")
    a = ap.parse_args()
    dll = a.dll or next((d for d in DLLS if os.path.exists(d)), None)
    if not dll:
        sys.exit("zx_bridge.dll no encontrada (usa --dll)")
    L = load_dll(dll)
    tmp = tempfile.mkdtemp()

    def shot(m, name):
        fb = m.fb()
        if a.ppm:
            os.makedirs(a.ppm, exist_ok=True)
            save_ppm(fb, os.path.join(a.ppm, name + ".ppm"))
        return fb

    # 1. Arranque en BASIC: papel blanco y texto negro abajo (copyright).
    for model, name in ((TC2048, "tc2048"), (TS2068, "ts2068")):
        m = Machine(L, model)
        m.run(4.0)
        fb = shot(m, "boot_" + name)
        check(f"{name}: modelo", L.zx_get_model(m.h) == model)
        bottom = {px(fb, x, y) for y in range(PY + 176, PY + 192) for x in range(PX, PX + 256)}
        check(f"{name}: BASIC (texto en la última fila)", (0, 0, 0) in bottom and PAL[7] in bottom, str(bottom))
        m.close()

    loop = bytes([0xF3, 0x18, 0xFE])    # DI / JR $

    # 2. Modos de $FF en el TC2048 (desde el .z80: byte 36 = último OUT a $FF).
    ram = bytearray(0xC000)
    ram[0x4000:0x4000 + len(loop)] = loop
    for y in range(192):                # pantalla 0: píxeles 0; pantalla 1: píxeles $F0
        for xb in range(32):
            ram[scr_addr(y, xb)] = 0x00
            ram[0x2000 + scr_addr(y, xb)] = 0xF0
            ram[0x2000 + scr_addr(y, xb)] = 0xF0
    ram[0x1800:0x1B00] = bytes([0x38]) * 768             # atributos clásicos: papel blanco
    ram[0x3800:0x3B00] = bytes([0x0A]) * 768             # pantalla 1: tinta roja, papel azul
    p = os.path.join(tmp, "modes.z80")

    make_z80(p, 14, ram, 0x8000, ff=0)
    m = Machine(L, M48, p); m.run(0.2); fb = shot(m, "tc_mode0")
    check("tc2048 .z80 (hardware 14)", L.zx_get_model(m.h) == TC2048, str(L.zx_get_model(m.h)))
    check("modo 0: pantalla normal", px(fb, PX + 5, PY + 5) == PAL[7], str(px(fb, PX + 5, PY + 5)))
    m.close()

    make_z80(p, 14, ram, 0x8000, ff=1)
    m = Machine(L, M48, p); m.run(0.2); fb = shot(m, "tc_mode1")
    check("modo 1: segunda pantalla (tinta)", px(fb, PX + 1, PY + 5) == PAL[2], str(px(fb, PX + 1, PY + 5)))
    check("modo 1: segunda pantalla (papel)", px(fb, PX + 5, PY + 5) == PAL[1], str(px(fb, PX + 5, PY + 5)))
    m.close()

    # Hi-color: atributo por línea en $6000 (papel = línea & 7), píxeles a 0 en $4000.
    hc = bytearray(ram)
    for y in range(192):
        for xb in range(32):
            hc[0x2000 + scr_addr(y, xb)] = (y & 7) << 3
    make_z80(p, 14, hc, 0x8000, ff=2)
    m = Machine(L, M48, p); m.run(0.2); fb = shot(m, "tc_mode2")
    got = [px(fb, PX + 100, PY + y) for y in range(8)]
    check("modo 2: hi-color 8x1", got == PAL[0:8], str(got))
    # Ida y vuelta por zx_save_snapshot: el .z80 guarda el modelo y el $FF.
    q = os.path.join(tmp, "saved.z80")
    check("tc2048: guardar .z80", L.zx_save_snapshot(m.h, q.encode(), 0) == 0)
    m.close()
    head = open(q, "rb").read(40)
    check("tc2048: .z80 hardware 14 y $FF = 2", head[34] == 14 and head[36] == 2, f"{head[34]} {head[36]}")
    m = Machine(L, M48, q); m.run(0.2); fb = m.fb()
    got = [px(fb, PX + 100, PY + y) for y in range(8)]
    check("tc2048: snapshot recargado en hi-color", L.zx_get_model(m.h) == TC2048 and got == PAL[0:8], str(got))
    m.close()

    # Hi-res: pantalla 0 = $FF, pantalla 1 = $00 → 8 px de tinta y 8 de papel alternos (4 + 4
    # muestras). Tinta 1 (azul BRIGHT), papel 6 (amarillo BRIGHT), borde = papel.
    hr = bytearray(ram)
    for y in range(192):
        for xb in range(32):
            hr[scr_addr(y, xb)] = 0xFF
            hr[0x2000 + scr_addr(y, xb)] = 0x00
    make_z80(p, 14, hr, 0x8000, ff=0x06 | (1 << 3))
    m = Machine(L, M48, p); m.run(0.2); fb = shot(m, "tc_mode6")
    got = [px(fb, PX + x, PY + 10) for x in range(8)]
    check("modo 6: hi-res 512 (tinta/papel)", got == [PAL[9]] * 4 + [PAL[14]] * 4, str(got))
    check("modo 6: borde = papel", px(fb, 4, 4) == PAL[14], str(px(fb, 4, 4)))
    m.close()

    # 3. ULAplus extendido en 48K: OUT ($BF3B),$42 → hi-color.
    code = bytes([0xF3, 0x01, 0x3B, 0xBF, 0x3E, 0x42, 0xED, 0x79, 0x18, 0xFE])
    ux = bytearray(hc)
    ux[0x4000:0x4000 + len(code)] = code
    make_z80(p, 0, ux, 0x8000)
    for mode, expect in ((2, PAL[0:8]), (1, [PAL[7]] * 8), (0, [PAL[7]] * 8)):
        m = Machine(L, M48, p)
        L.zx_set_ulaplus(m.h, mode)
        m.run(0.2)
        fb = shot(m, f"ulaplus_ext_{mode}")
        got = [px(fb, PX + 100, PY + y) for y in range(8)]
        check(f"48K ULAplus ajuste {mode}: {'hi-color' if mode == 2 else 'sin cambio'}", got == expect, str(got))
        m.close()
    L.zx_set_ulaplus(None, 2)

    # 4. TS2068: EXROM por la MMU, AY y joystick. Resultados como píxeles en $4000-$4003
    #    (atributos tinta negra / papel blanco: bit a 1 = negro).
    code = bytes([
        0xF3,
        0x3E, 0x01, 0xD3, 0xF4,         # LD A,1 / OUT ($F4),A   chunk 0 desde DOCK/EXROM
        0x3E, 0x80, 0xD3, 0xFF,         # LD A,$80 / OUT ($FF),A EXROM
        0x2A, 0x00, 0x00,               # LD HL,($0000)
        0x22, 0x00, 0x40,               # LD ($4000),HL
        0xAF, 0xD3, 0xF4, 0xD3, 0xFF,   # XOR A / OUT ($F4),A / OUT ($FF),A
        0x3E, 0x07, 0xD3, 0xF5,         # AY: registro 7
        0x3E, 0x3F, 0xD3, 0xF6,         #     = $3F (sin tonos ni ruido; puerto A de entrada)
        0x3E, 0x00, 0xD3, 0xF5,         # registro 0
        0x3E, 0x5A, 0xD3, 0xF6,         #     = $5A
        0xDB, 0xF6,                     # IN A,($F6)   (A = 0 → puerto $00F6)
        0x32, 0x02, 0x40,               # LD ($4002),A
        0x3E, 0x0E, 0xD3, 0xF5,         # registro 14
        0x01, 0xF6, 0x01, 0xED, 0x78,   # LD BC,$01F6 / IN A,(C)   joystick 1
        0x32, 0x03, 0x40,               # LD ($4003),A
        0x18, 0xFE])
    ts = bytearray(0xC000)
    ts[0x4000:0x4000 + len(code)] = code
    ts[0x1800:0x1B00] = bytes([0x38]) * 768
    make_z80(p, 128, ts, 0x8000)
    m = Machine(L, M48, p)
    check("ts2068 .z80 (hardware 128)", L.zx_get_model(m.h) == TS2068, str(L.zx_get_model(m.h)))
    L.zx_set_joystick(m.h, JOY_UP | JOY_FIRE)
    m.run(1.0)    # el CRT NTSC tarda más en fijar la posición vertical
    fb = shot(m, "ts_mmu")

    def byte_at(xb):
        return sum((1 << (7 - b)) for b in range(8) if px(fb, PX + xb * 8 + b, PY) == (0, 0, 0))

    rom = open(os.path.join(ROMS, "ts2068.rom"), "rb").read()
    got = [byte_at(0), byte_at(1)]
    check("ts2068: EXROM en $0000", got == list(rom[0x4000:0x4002]), f"{got} vs {list(rom[0x4000:0x4002])}")
    check("ts2068: AY en $F5/$F6", byte_at(2) == 0x5A, hex(byte_at(2)))
    check("ts2068: joystick 1 (arriba + fuego, activo a 0)", byte_at(3) == 0x7E, hex(byte_at(3)))
    m.close()

    print("\n" + ("TODO OK" if not FAILS else f"{len(FAILS)} FALLOS: " + ", ".join(FAILS)))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
