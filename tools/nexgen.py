#!/usr/bin/env python3
"""Genera archivos .nex de prueba (programas Z80N hechos a mano) para probar el core Next.
Uso: python tools/nexgen.py <directorio_salida>"""
import struct, sys, os, math


class Asm:
    def __init__(self, org):
        self.org = org
        self.b = bytearray()
        self.labels = {}
        self.fix = []

    @property
    def pc(self):
        return self.org + len(self.b)

    def db(self, *v):
        self.b += bytes(x & 255 for x in v)

    def dw(self, v):
        self.b += struct.pack('<H', v & 0xFFFF)

    def label(self, n):
        self.labels[n] = self.pc

    def jr(self, n, op=0x18):
        self.db(op)
        self.fix.append((len(self.b), n))
        self.db(0)

    def djnz(self, n): self.jr(n, 0x10)
    def jrnz(self, n): self.jr(n, 0x20)
    def jrz(self, n): self.jr(n, 0x28)

    def jp(self, n):
        self.db(0xC3)
        self.fix.append((len(self.b), n, 'abs'))
        self.dw(0)

    def call(self, n):
        self.db(0xCD)
        self.fix.append((len(self.b), n, 'abs'))
        self.dw(0)

    def ld_hl(self, v):
        if isinstance(v, str):
            self.db(0x21); self.fix.append((len(self.b), v, 'abs')); self.dw(0)
        else:
            self.db(0x21); self.dw(v)

    def ld_de(self, v): self.db(0x11); self.dw(v)
    def ld_bc(self, v): self.db(0x01); self.dw(v)
    def ld_sp(self, v): self.db(0x31); self.dw(v)
    def ld_a(self, v): self.db(0x3E, v)
    def ld_b(self, v): self.db(0x06, v)
    def ld_c(self, v): self.db(0x0E, v)
    def ld_d(self, v): self.db(0x16, v)
    def ld_e(self, v): self.db(0x1E, v)
    def ld_mhl(self, v): self.db(0x36, v)
    def ld_mhl_a(self): self.db(0x77)
    def ld_a_mhl(self): self.db(0x7E)
    def inc_hl(self): self.db(0x23)
    def inc_a(self): self.db(0x3C)
    def dec_b(self): self.db(0x05)
    def out_c_a(self): self.db(0xED, 0x79)
    def otir(self): self.db(0xED, 0xB3)
    def ldir(self): self.db(0xED, 0xB0)
    def nextreg(self, r, v): self.db(0xED, 0x91, r, v)
    def nextreg_a(self, r): self.db(0xED, 0x92, r)
    def di(self): self.db(0xF3)
    def ei(self): self.db(0xFB)
    def halt(self): self.db(0x76)
    def ret(self): self.db(0xC9)
    def im2(self): self.db(0xED, 0x5E)
    def ld_i_a(self): self.db(0xED, 0x47)
    def xor_a(self): self.db(0xAF)
    def out_n_a(self, p): self.db(0xD3, p)
    def cp(self, v): self.db(0xFE, v)

    def finish(self):
        for f in self.fix:
            if len(f) == 2:
                pos, n = f
                rel = self.labels[n] - (self.org + pos + 1)
                assert -128 <= rel <= 127, (n, rel)
                self.b[pos] = rel & 255
            else:
                pos, n, _ = f
                struct.pack_into('<H', self.b, pos, self.labels[n])
        return bytes(self.b)


def make_nex(banks, pc, sp, l2=None, border=0, entry_bank=0):
    """banks: {numero_banco16K: bytes}. l2: 48K de Layer 2 (banks 9-11) o None."""
    hdr = bytearray(512)
    hdr[0:4] = b'Next'
    hdr[4:8] = b'V1.2'
    hdr[8] = 0
    hdr[9] = len(banks)
    hdr[10] = 0x01 | 0x80 if l2 is not None else 0x00
    hdr[11] = border
    struct.pack_into('<HH', hdr, 12, sp, pc)
    for b in banks:
        hdr[18 + b] = 1
    hdr[139] = entry_bank
    out = bytes(hdr)
    if l2 is not None:
        assert len(l2) == 0xC000
        out += l2
    order = [5, 2, 0, 1, 3, 4] + list(range(6, 112))
    for b in order:
        if b in banks:
            d = banks[b]
            out += d + bytes(0x4000 - len(d))
    return out


def gradient_l2():
    """Layer 2 256x192: degradado + rejilla + marco."""
    d = bytearray(0xC000)
    for y in range(192):
        for x in range(256):
            c = ((x >> 5) << 5) | (((y >> 5) & 7) << 2) | 0
            if x in (0, 255) or y in (0, 191): c = 0xFF
            elif x % 32 == 0 or y % 32 == 0: c = 0x00
            d[y * 256 + x] = c
    return bytes(d)


def demo():
    a = Asm(0x8000)
    a.di()
    a.nextreg(0x07, 3)            # 28 MHz
    a.nextreg(0x15, 0x01)         # sprites visibles, orden SLU
    # patrón de sprite 0: 16x16 8bpp (degradado diagonal)
    a.ld_bc(0x5B)                 # C = puerto, B=0 -> 256 bytes
    a.ld_b(0)
    a.ld_hl('pat')
    a.otir()
    # sprite 0 (ancla) y 1 (relativo)
    a.ld_bc(0x303B); a.xor_a(); a.out_c_a()
    a.ld_b(10); a.ld_c(0x57); a.ld_hl('attrs'); a.otir()
    # tilemap
    a.nextreg(0x6E, 0x2C)
    a.nextreg(0x6F, 0x20)
    a.nextreg(0x6B, 0x81)
    a.nextreg(0x1C, 0x08)
    for v in (0, 159, 200, 232): a.nextreg(0x1B, v)
    a.ld_hl(0x6C00); a.ld_de(0x6C01); a.ld_bc(0x09FF); a.ld_mhl(0x01); a.ldir()
    a.ld_hl(0x6020); a.ld_de(0x6021); a.ld_bc(31); a.ld_mhl(0x3C); a.ldir()   # tile 1 = franjas
    # ULA: unas líneas de píxeles y atributos
    a.ld_hl(0x4000); a.ld_de(0x4001); a.ld_bc(0x17FF); a.ld_mhl(0xAA); a.ldir()
    a.ld_hl(0x5800); a.ld_de(0x5801); a.ld_bc(0x2FF); a.ld_mhl(0x47); a.ldir()
    # DMA: copiar 256 bytes de 'pat' al tercio inferior de la pantalla ULA
    a.ld_hl('dmaprog'); a.ld_b(17); a.ld_c(0x6B); a.otir()
    # Copper: a la línea 100 cambia el scroll X de Layer 2
    a.nextreg(0x61, 0); a.nextreg(0x62, 0x00)
    a.ld_hl('coppr'); a.ld_b(8)
    a.label('cp')
    a.db(0x7E); a.db(0xED, 0x92, 0x60) if False else None
    a.ld_a_mhl(); a.nextreg_a(0x60); a.inc_hl(); a.djnz('cp')
    a.nextreg(0x62, 0xC0)
    a.label('loop')
    a.halt()
    a.jr('loop')
    # datos
    a.label('dmaprog')
    # WR6 reset, WR0: A->B, A inicio, longitud; WR1 A incrementa memoria; WR2 B incrementa; WR4 continuo B dir; load; enable
    a.db(0xC3)
    a.db(0x7D); a.dw(0x0000 + 0)  # placeholder: dirección A se parchea abajo
    a.db(0x00, 0x01)
    a.db(0x14, 0x10, 0xAD); a.dw(0x4800)
    a.db(0xCF, 0x87)
    a.label('coppr')
    # WAIT(h=0,v=100) = 0x8000 | 100 ; MOVE(reg 0x16, 40)
    a.db(0x80, 100, 0x16, 40)
    # WAIT(v=140) ; MOVE reg 0x16 <- 0
    a.db(0x80, 140, 0x16, 0)
    a.label('attrs')
    # sprite 0: x=100,y=100 ; attr2 pal 0, attr3 visible + patrón 0 + has4 ; attr4 = 0 (8 bit, escala 1)
    a.db(100, 100, 0x00, 0xC0, 0x00)
    # sprite 1: relativo con offset (+20, +10), patrón relativo
    a.db(20, 10, 0x00, 0xC0, 0x40)
    a.label('pat')
    for y in range(16):
        for x in range(16):
            a.db(((x + y) * 8) & 255 if x not in (0, 15) and y not in (0, 15) else 0xFF)
    code = a.finish()
    # parchear el programa DMA: A = 'pat' (se conoce tras finish)
    off = a.labels['dmaprog'] - a.org
    struct.pack_into('<H', bytearray(code), off + 2, 0)
    code = bytearray(code)
    struct.pack_into('<H', code, off + 2, a.labels['pat'])
    return make_nex({2: bytes(code)}, 0x8000, 0xBFF0, l2=gradient_l2())


def mouse_test():
    code = bytes([0x3E,0x07,0x32,0x00,0x58, 0x01,0xDF,0xFB,0xED,0x78,0x32,0x00,0x40, 0x01,0xDF,0xFF,0xED,0x78,0x32,0x00,0x41,
                  0x01,0xDF,0xFA,0xED,0x78,0x32,0x00,0x42, 0x18,0xE6])
    return make_nex({2: code}, 0x8000, 0xBFF0)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'demo.nex'), 'wb') as f:
        f.write(demo())
    with open(os.path.join(out, 'mouse.nex'), 'wb') as f:
        f.write(mouse_test())
    print('ok')


if __name__ == '__main__':
    main()
