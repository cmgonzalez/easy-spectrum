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
    print("\n" + ("TODO OK" if not bad else "%d FALLOS" % bad))
    sys.exit(1 if bad else 0)


main()
