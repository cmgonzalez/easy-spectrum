#!/usr/bin/env python3
"""Autotest de PDP fase 1: genera un SNA 48K sintético, lo carga en el host y ejercita el protocolo."""
import os
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdp import Pdp

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 7891
CODE = bytes([
    0x3E, 0x00,             # 8000 LD A,0
    0x3C,                   # 8002 INC A
    0x32, 0x00, 0x90,       # 8003 LD (9000),A
    0xCD, 0x10, 0x80,       # 8006 CALL 8010
    0x18, 0xF7,             # 8009 JR 8002
])
SUB = bytes([0x06, 0x03, 0x10, 0xFE, 0xC9])   # 8010 LD B,3 ; 8012 DJNZ $ ; 8014 RET


def make_sna(path):
    ram = bytearray(49152)
    ram[0x8000 - 0x4000:0x8000 - 0x4000 + len(CODE)] = CODE
    ram[0x8010 - 0x4000:0x8010 - 0x4000 + len(SUB)] = SUB
    sp = 0xFF00
    ram[sp - 0x4000:sp - 0x4000 + 2] = b"\x00\x80"      # PC en la pila
    hdr = bytearray(27)
    hdr[23:25] = struct.pack("<H", sp)
    hdr[25] = 1         # IM 1
    hdr[19] = 0         # IFF2 = 0 (DI)
    open(path, "wb").write(bytes(hdr) + bytes(ram))


bad = 0


def check(cond, msg):
    global bad
    print(("ok    " if cond else "FALLO ") + msg)
    if not cond:
        bad += 1


def hx(v):
    return int(v, 16)


def main():
    sna = os.path.join(os.environ.get("TEMP", "."), "pdp_test.sna")
    make_sna(sna)
    host = subprocess.Popen([sys.executable, os.path.join(HERE, "pdp_host.py"), sna, "--port", str(PORT), "--seconds", "60"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(host.stdout.readline().decode().strip())
    try:
        c = Pdp(PORT)
        r = c.cmd("hello")
        check(r["ok"] and r["protocol"] == "pdp/1", "hello " + str(r))
        time.sleep(0.3)
        r = c.cmd("pause", wait=True)
        check(r["state"] == "stopped" and r["reason"] == "pause", "pause -> " + str(r))
        pc = hx(r["pc"])
        check(0x8000 <= pc <= 0x8014, "pc dentro del programa: %04X" % pc)
        r = c.cmd("mem", addr="0x8000", len=11)
        check(r["data"] == CODE.hex().upper(), "mem = codigo")
        c.cmd("break", addr="0x8003")
        r = c.cmd("resume", wait=True)
        check(r["reason"] == "breakpoint" and hx(r["pc"]) == 0x8003, "break en 8003: " + str(r))
        a1 = hx(c.cmd("regs")["regs"]["af"]) >> 8
        r = c.cmd("resume", wait=True)
        check(hx(r["pc"]) == 0x8003, "segundo hit en 8003")
        a2 = hx(c.cmd("regs")["regs"]["af"]) >> 8
        check((a2 - a1) & 0xFF == 1, "A avanza 1 por vuelta (%d -> %d)" % (a1, a2))
        r = c.cmd("step", wait=True)
        check(hx(r["pc"]) == 0x8006 and r["reason"] == "step", "step 8003 -> 8006: " + str(r))
        r = c.cmd("mem", addr="0x9000", len=1)
        check(int(r["data"], 16) == a2, "LD (9000),A ejecutado")
        sp0 = hx(c.cmd("regs")["regs"]["sp"])
        r = c.cmd("step", wait=True)
        check(hx(r["pc"]) == 0x8010, "step entra en CALL -> 8010")
        check(hx(c.cmd("regs")["regs"]["sp"]) == sp0 - 2, "CALL empujo la direccion de retorno")
        c.cmd("unbreak", addr="all")
        c.cmd("step", wait=True)
        r = c.cmd("step", wait=True)
        check(hx(r["pc"]) == 0x8012, "DJNZ: pc 8012")
        c.cmd("break", addr="0x8006")
        r = c.cmd("resume", wait=True)
        check(hx(r["pc"]) == 0x8006, "vuelta al CALL (8006)")
        r = c.cmd("next", wait=True)
        check(hx(r["pc"]) == 0x8009 and r["reason"] == "until", "next sobre CALL -> 8009: " + str(r))
        c.cmd("unbreak", addr="all")
        # --- fase 2: simbolos, condiciones, watchpoints, historial
        mp = os.path.join(os.environ.get("TEMP", "."), "pdp_test.map")
        open(mp, "w").write("\n".join([
            "_main = $8000 ; addr, public, , t_c, code_compiler, t.c:1",
            "_sub = $8010 ; addr, public, , t_c, code_compiler, t.c:9",
            "_var = $9000 ; addr, public, , t_c, bss_compiler, t.c:2",
            "CRT_ORG = $5C20 ; const, local, , crt, , crt.m4:1", ""]))
        r = c.cmd("load_map", path=mp); check(r["symbols"] == 3, "load_map (solo addr): " + str(r.get("symbols")))
        r = c.cmd("sym", q="0x8004"); check(r["addr_sym"] == "_main+0x4" and r["src"] == "t.c:1", "sym inversa: " + str(r))
        r = c.cmd("sym", q="var"); check(r["addr"] == "0x9000", "sym por nombre sin _")
        r = c.cmd("break", addr="_main+3", cond="a==10"); check(r["ok"], "break con simbolo y cond")
        r = c.cmd("resume", wait=True)
        check(r["reason"] == "breakpoint" and hx(c.cmd("regs")["regs"]["af"]) >> 8 == 10, "cond a==10: " + str(r))
        check(r.get("pc_sym") == "_main+0x3", "pc_sym en el estado")
        c.cmd("unbreak", addr="all")
        r = c.cmd("watch", addr="_var", type="w", cond="a==40"); check(r["ok"], "watch con cond")
        r = c.cmd("resume", wait=True)
        check(r["reason"] == "watch" and r["access"] == "write" and r["addr"] == "0x9000" and r["value"] == 40 and r["pc"] == "0x8003",
              "watch write a 9000 con A==40: " + str(r))
        h = c.cmd("history", n=3)["history"]
        check(len(h) == 3 and h[-1].startswith("0x8003"), "history: " + str(h))
        c.cmd("unwatch", addr="all")
        r = c.cmd("watch", addr="_var", type="r")
        c.cmd("unwatch", addr="all")
        r = c.cmd("get", addr="_var"); check(r["value"] == 40, "get _var = 40")
        # --- fase 3: frames, perfilador, frame-log
        c.cmd("unbreak", addr="all")
        f0 = c.cmd("status")["frame"]
        r = c.cmd("resume", frames=5, wait=True)
        check(r["reason"] == "frames", "resume frames=5 para por frames: " + str(r))
        check(c.cmd("status")["frame"] - f0 == 5, "avanzo exactamente 5 frames")
        c.cmd("profile", on=True)
        c.cmd("framelog", set="a,[_var]")
        c.cmd("resume", frames=10, wait=True)
        r = c.cmd("profile", top=5)
        names = [e["name"] for e in r["profile"]]
        check(abs(r["total_tstates"] - 10 * 69888) < 0.02 * 10 * 69888, "perfil: %d T-states en 10 frames" % r["total_tstates"])
        check("_main" in names and "_sub" in names, "perfil por funcion: " + str(names))
        check(abs(sum(e["pct"] for e in r["profile"]) - 100) < 0.5, "porcentajes suman 100")
        r = c.cmd("framelog", n=10)
        rows = r["rows"]
        check(r["columns"] == ["frame", "idle", "a", "[_var]"] and len(rows) == 10, "framelog columnas/filas: " + str(rows[:2]))
        check(all(rows[i + 1][0] - rows[i][0] == 1 for i in range(len(rows) - 1)), "frames consecutivos")
        check(all(row[1] == 0 for row in rows), "sin HALT: idle 0")
        c.cmd("profile", on=False)
        c.cmd("framelog", stop=True)
        c.cmd("unbreak", addr="all")
        r = c.cmd("poke", addr="0x9100", data="DEADBEEF")
        check(r["written"] == 4, "poke")
        r = c.cmd("mem", addr="0x9100", len=4)
        check(r["data"] == "DEADBEEF", "mem lee lo poked")
        r = c.cmd("resume")
        check(r["ok"], "resume sin wait: " + r["state"])
        time.sleep(0.3)
        m1 = c.cmd("mem", addr="0x9000", len=1)["data"]
        time.sleep(0.2)
        m2 = c.cmd("mem", addr="0x9000", len=1)["data"]
        check(m1 != m2, "corre libre: 9000 cambia (%s -> %s)" % (m1, m2))
        r = c.cmd("pause", wait=True)
        check(r["state"] == "stopped", "pause final")
        r = c.cmd("reset")
        check(r["ok"], "reset")
        time.sleep(0.3)
        r = c.cmd("status")
        check(r["state"] == "running", "tras reset corre: " + str(r))
    finally:
        host.kill()


def crash_test():
    """Programa que salta a 0 (reset): catch + crash (desde, historial, pila)."""
    sna = os.path.join(os.environ.get("TEMP", "."), "pdp_crash.sna")
    ram = bytearray(49152)
    code = bytes([0x18, 0xFE, 0x3E, 0x07, 0xC3, 0x00, 0x00])    # 8000 JR $ ; 8002 LD A,7 ; 8004 JP 0
    ram[0x8000 - 0x4000:0x8000 - 0x4000 + len(code)] = code
    sp = 0xFE00
    ram[sp - 0x4000:sp - 0x4000 + 6] = bytes([0x00, 0x80, 0x34, 0x12, 0x78, 0x56])   # PC, y datos en la pila
    hdr = bytearray(27)
    hdr[23:25] = struct.pack("<H", sp)
    hdr[25] = 1
    open(sna, "wb").write(bytes(hdr) + bytes(ram))
    host = subprocess.Popen([sys.executable, os.path.join(HERE, "pdp_host.py"), sna, "--port", str(PORT + 1), "--seconds", "30"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    host.stdout.readline()
    try:
        c = Pdp(PORT + 1)
        c.cmd("catch", on="reset")
        c.cmd("poke", addr="0x8000", data="0000")   # libera el JR $: cae por LD A,7 y JP 0
        time.sleep(0.5)
        r = c.cmd("status")
        check(r["state"] == "stopped" and r["reason"] == "crash" and r["detail"] == "reset", "crash reset detectado: " + str(r))
        check(r["pc"] == "0x0000" and r["from"] == "0x8004", "desde JP 0 en 8004")
        r = c.cmd("crash")
        check(r["history"][-2].startswith("0x8004") and r["history"][-3].startswith("0x8002"),
              "historial previo al crash: " + str(r["history"][-3:]))
        check(r["regs"]["af"].startswith("0x07"), "A=7 tras LD A,7")
        check(len(r["stack"]) == 8 and r["stack"][0] == "0x1234", "volcado de pila: " + str(r["stack"][:2]))
    finally:
        host.kill()


def input_test():
    """Teclado / joystick / bancos: programa que copia la fila A-G del teclado (puerto FDFE) a 9200."""
    sna = os.path.join(os.environ.get("TEMP", "."), "pdp_keys.sna")
    ram = bytearray(49152)
    code = bytes([0x01, 0xFE, 0xFD,       # 8000 LD BC,FDFE
                  0xED, 0x78,             # 8003 IN A,(C)
                  0x32, 0x00, 0x92,       # 8005 LD (9200),A
                  0xDB, 0x1F,             # 8008 IN A,(1F)   Kempston
                  0x32, 0x01, 0x92,       # 800A LD (9201),A
                  0x18, 0xF1])            # 800D JR 8000
    ram[0x8000 - 0x4000:0x8000 - 0x4000 + len(code)] = code
    sp = 0xFE00
    ram[sp - 0x4000:sp - 0x4000 + 2] = bytes([0x00, 0x80])
    hdr = bytearray(27)
    hdr[23:25] = struct.pack("<H", sp)
    hdr[25] = 1
    open(sna, "wb").write(bytes(hdr) + bytes(ram))
    host = subprocess.Popen([sys.executable, os.path.join(HERE, "pdp_host.py"), sna, "--port", str(PORT + 2), "--seconds", "30"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    host.stdout.readline()
    try:
        c = Pdp(PORT + 2)
        c.cmd("pause", wait=True)

        def keyrow():
            return int(c.cmd("mem", addr="0x9200", len=1)["data"], 16)

        c.cmd("resume", frames=3, wait=True)
        check(keyrow() & 1, "tecla A suelta")
        c.cmd("key", name="a", frames=4)
        c.cmd("resume", frames=2, wait=True)
        check(not keyrow() & 1, "tecla A pulsada (bit0 a 0)")
        c.cmd("resume", frames=6, wait=True)
        check(keyrow() & 1, "tecla A soltada sola tras 4 frames")
        c.cmd("joy", dirs="left+fire", frames=3)
        c.cmd("resume", frames=2, wait=True)
        kemp = int(c.cmd("mem", addr="0x9201", len=1)["data"], 16)
        check(kemp == 0x12, "joy Kempston left+fire = 0x%02X (esperado 12)" % kemp)
        c.cmd("resume", frames=5, wait=True)
        check(int(c.cmd("mem", addr="0x9201", len=1)["data"], 16) == 0, "joy soltado")
        c.cmd("key", name="a", state="down")
        c.cmd("resume", frames=2, wait=True)
        check(not keyrow() & 1, "key down se mantiene")
        c.cmd("key", name="a", state="up")
        c.cmd("resume", frames=2, wait=True)
        check(keyrow() & 1, "key up suelta")
        check(not c.cmd("key", name="zzz")["ok"], "tecla desconocida da error")
        png = os.path.join(os.environ.get("TEMP", "."), "pdp_shot.png")
        r = c.cmd("screenshot", path=png, paper=True)
        data = open(png, "rb").read()
        check(r["ok"] and data[:4] == bytes([0x89, 0x50, 0x4E, 0x47]), "screenshot escribe un PNG")
        w, h = struct.unpack(">II", data[16:24])
        import zlib
        i = data.index(b"IDAT")
        n = struct.unpack(">I", data[i - 4:i])[0]
        raw = zlib.decompress(data[i + 4:i + 4 + n])
        check((w, h) == (256, 192) and len(raw) == h * (w * 3 + 1), "PNG valido %dx%d, %d bytes descomprimidos" % (w, h, len(raw)))
        check(len(c.cmd("screenshot")["png_base64"]) > 1000, "screenshot en base64")
    finally:
        host.kill()


def bank_test():
    """128K sin medio: bancos explicitos y paginacion."""
    host = subprocess.Popen([sys.executable, os.path.join(HERE, "pdp_host.py"), "--model", "128k", "--port", str(PORT + 3), "--seconds", "20"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    host.stdout.readline()
    try:
        c = Pdp(PORT + 3)
        time.sleep(0.5)
        c.cmd("pause", wait=True)
        r = c.cmd("poke", addr="0x10", bank=3, data="ABCD")
        check(r["ok"], "poke en banco 3")
        check(c.cmd("mem", addr="0x10", len=2, bank=3)["data"] == "ABCD", "mem banco 3")
        check(c.cmd("mem", addr="0x10", len=2, bank=4)["data"] != "ABCD", "banco 4 distinto")
        r = c.cmd("mem", addr="0", len=4, rom=0)
        check(len(r["data"]) == 8 and r["data"] != "00000000", "ROM 0 legible: " + r["data"])
        check(not c.cmd("poke", addr="0", rom=0, data="00")["ok"], "la ROM no se escribe")
        r = c.cmd("paging")
        check(r["ok"] and "ram_c000" in r and r["screen"] == 5, "paging: " + str(r))
        # La RAM paginada en C000 se ve igual por direccion y por banco
        bank = r["ram_c000"]
        c.cmd("poke", addr="0xC010", data="5A")
        check(c.cmd("mem", addr="0x10", len=1, bank=bank)["data"] == "5A", "C000 == banco %d" % bank)
    finally:
        host.kill()


main()
crash_test()
input_test()
bank_test()
print("\n" + ("TODO OK" if not bad else "%d FALLOS" % bad))
sys.exit(1 if bad else 0)
