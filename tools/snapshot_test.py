#!/usr/bin/env python3
"""Autotest de zx_save_snapshot (.z80 / .sna) con zx_bridge.dll.

  python tools/snapshot_test.py [--dll ruta/zx_bridge.dll]

Por cada modelo arranca BASIC, lo deja quieto, guarda .z80 y .sna, los vuelve a abrir y
compara la pantalla (la de BASIC es estática). Además, con el SNA de gigascreen_test.py
(128K que alterna banco 5 / banco 7 en cada interrupción) revisa el contenido del .z80:
cabecera v2 de 128K, PC dentro del bucle, bancos 5 y 7 con sus pantallas.
"""
import argparse, ctypes, os, sys, tempfile

sys.path.insert(0, os.path.dirname(__file__))
import gigascreen_test as gt

ROOT = gt.ROOT
FB = 320 * 256 * 4
MODELS = {"16k": 0, "48k": 1, "128k": 2, "+2": 3, "+2a": 4, "+3": 5}


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
    L.zx_save_snapshot.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    L.zx_destroy.argtypes = [ctypes.c_void_p]
    return L


class Machine:
    def __init__(self, L, media, model):
        self.L = L
        self.h = L.zx_create(os.path.join(ROOT, "assets", "roms").encode(), model, media.encode(), 48000)
        if not self.h:
            raise RuntimeError("zx_create: " + L.zx_last_error().decode())
        self.audio = (ctypes.c_int16 * 65536)()

    def run(self, secs):
        for _ in range(int(secs / 0.02)):
            self.L.zx_run(self.h, 0.02)
            self.L.zx_get_audio(self.h, self.audio, 65536)

    def screen(self):
        return ctypes.string_at(self.L.zx_get_framebuffer(self.h), FB)

    def save(self, path):
        fmt = 1 if path.endswith(".sna") else 0
        if self.L.zx_save_snapshot(self.h, path.encode(), fmt) != 0:
            raise RuntimeError("zx_save_snapshot: " + self.L.zx_last_error().decode())

    def close(self):
        self.L.zx_destroy(self.h)


def z80_pages(data):
    """Descomprime los bloques de un .z80 v2/v3 → {página: 16 KB}."""
    extra = data[30] | data[31] << 8
    i, pages = 32 + extra, {}
    while i < len(data):
        n = data[i] | data[i + 1] << 8
        page = data[i + 2]
        i += 3
        if n == 0xFFFF:
            pages[page] = data[i:i + 16384]
            i += 16384
            continue
        blk, out, j = data[i:i + n], bytearray(), 0
        while j < len(blk):
            if blk[j] == 0xED and j + 1 < len(blk) and blk[j + 1] == 0xED:
                out += bytes([blk[j + 3]]) * blk[j + 2]
                j += 4
            else:
                out.append(blk[j])
                j += 1
        assert len(out) == 16384, (page, len(out))
        pages[page] = bytes(out)
        i += n
    return pages


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--dll")
    a = ap.parse_args()
    dll = a.dll or next((d for d in gt.DLLS if os.path.exists(d)), None)
    if not dll:
        sys.exit("zx_bridge.dll no encontrada (usa --dll)")
    L = load_dll(dll)
    tmp = tempfile.mkdtemp(prefix="zxsnap_")
    failures = 0

    def check(ok, msg):
        nonlocal failures
        print(("  OK    " if ok else "  FALLA ") + msg)
        failures += 0 if ok else 1

    print("Ida y vuelta desde BASIC (misma pantalla y mismo modelo al reabrir):")
    for name, model in MODELS.items():
        m = Machine(L, "", model)
        m.run(4)
        before = m.screen()
        files = []
        for ext in ("z80", "sna"):
            path = os.path.join(tmp, f"basic_{name.replace('+', 'p')}.{ext}")
            m.save(path)
            files.append(path)
        m.run(0.5)
        check(m.screen() == before, f"{name}: la máquina sigue igual tras guardar")
        m.close()
        for path in files:
            r = Machine(L, path, model)
            r.run(0.5)
            got_model = L.zx_get_model(r.h)
            # .sna no distingue modelos dentro de su familia (48K/16K → 48K, 128K-familia → 128K).
            want = model if path.endswith(".z80") else (1 if model < 2 else 2)
            # Un .sna de +2/+2A/+3 se abre como 128K, con su ROM: la pantalla de BASIC cambia.
            same = r.screen() == before or (path.endswith(".sna") and model >= 3)
            check(same and got_model == want,
                  f"{name} {os.path.basename(path)[-3:]}: {os.path.getsize(path)} bytes, modelo {got_model} "
                  f"(esperado {want}), pantalla {'igual' if r.screen() == before else 'distinta (ROM 128K)' if same else 'DISTINTA'}")
            r.close()

    print("Contenido del .z80 de un 128K con pantalla sombra (gigascreen_test):")
    sna = os.path.join(tmp, "giga.sna")
    gt.make_sna(sna)
    m = Machine(L, sna, 2)
    m.run(1)
    z80 = os.path.join(tmp, "giga.z80")
    m.save(z80)
    m.close()
    d = open(z80, "rb").read()
    extra, pc, mode, p7ffd = d[30] | d[31] << 8, d[32] | d[33] << 8, d[34], d[35]
    check(extra == 23 and mode == 3, f"cabecera v2, modo 3 (128K): longitud {extra}, modo {mode}")
    check(0x8000 <= pc < 0x8000 + len(gt.CODE), f"PC dentro del bucle: {pc:#06x}")
    check(p7ffd & 0xF7 == gt.PORT_7FFD, f"$7FFD = {p7ffd:#04x} (solo cambia el bit 3)")
    pages = z80_pages(d)
    check(sorted(pages) == list(range(3, 11)), f"8 bancos: páginas {sorted(pages)}")
    b5, b7 = pages[3 + 5], pages[3 + 7]
    check(b5[6144] == 0x08 and b7[6144] == 0x10 and b7[2048] == 0xFF,
          "bancos 5 y 7 con su pantalla (azul / rojo, píxeles FF en la sombra)")
    check(pages[3 + 2][:len(gt.CODE)] == gt.CODE, "código en el banco 2")

    print("\n" + ("TODO OK" if not failures else f"{failures} FALLA(S)"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
