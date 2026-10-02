#!/usr/bin/env python3
"""Autotest del depurador PDP sobre la Next (host tools/nextpdp.cpp, sin Flutter).

  python tools/pdp_next_selftest.py <nextpdp.exe>
"""
import os, struct, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(__file__))
from pdp import Pdp
from nexgen import make_nex

# 8000 LD SP,BFF0 / 8003 LD A,0 / 8005 INC A / 8006 CALL 8010 / 8009 LD (9000),A / 800C JR 8005 / 8010 NOP / 8011 RET
CODE = bytes([0x31, 0xF0, 0xBF, 0x3E, 0x00, 0x3C, 0xCD, 0x10, 0x80, 0x32, 0x00, 0x90, 0x18, 0xF7, 0x00, 0x00,
              0x00, 0xC9])
PORT = 7891
fails = 0


def check(name, cond, info=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(info)))
    if not cond:
        fails += 1


def main():
    exe = sys.argv[1]
    nex = os.path.join(tempfile.gettempdir(), "pdp_next_test.nex")
    open(nex, "wb").write(make_nex({2: CODE}, 0x8000, 0xBFF0, entry_bank=2))
    p = subprocess.Popen([exe, nex, str(PORT), "30"], stdout=subprocess.PIPE)
    p.stdout.readline()
    c = Pdp(PORT)
    try:
        r = c.cmd("hello")
        check("hello", r["ok"] and r["machine"] == "next" and r["debug"], r)

        r = c.cmd("pause", wait=True)
        check("pause", r["state"] == "stopped" and 0x8000 <= int(r["pc"], 16) <= 0x8011, r)

        c.cmd("break", addr=0x8009)
        r = c.cmd("resume", wait=True)
        check("breakpoint 8009", r["reason"] == "breakpoint" and r["pc"] == "0x8009", r)
        regs = c.cmd("regs")["regs"]
        check("regs SP/A", regs["sp"] == "0xBFF0" and regs["pc"] == "0x8009", regs)

        a0 = int(regs["af"], 16) >> 8
        r = c.cmd("step", wait=True)
        check("step -> 800C", r["reason"] == "step" and r["pc"] == "0x800C", r)
        r = c.cmd("step", wait=True)
        check("step JR -> 8005", r["pc"] == "0x8005", r)
        r = c.cmd("step", wait=True)
        r = c.cmd("step", wait=True)
        check("step INC A, CALL -> 8010", r["pc"] == "0x8010", r)
        a1 = int(c.cmd("regs")["regs"]["af"], 16) >> 8
        check("A avanzo", a1 == (a0 + 1) & 255, (a0, a1))

        r = c.cmd("step", wait=True)
        r = c.cmd("step", wait=True)
        check("step RET -> 8009", r["pc"] == "0x8009", r)

        c.cmd("unbreak", addr="all")
        r = c.cmd("step", wait=True)
        r = c.cmd("step", wait=True)
        r = c.cmd("step", wait=True)
        check("de vuelta en 8006", r["pc"] == "0x8006", r)
        r = c.cmd("next", wait=True)
        check("next salta el CALL", r["reason"] == "until" and r["pc"] == "0x8009", r)

        c.cmd("watch", addr=0x9000, type="w")
        r = c.cmd("resume", wait=True)
        check("watch escritura 9000", r["reason"] == "watch" and r["addr"] == "0x9000", r)
        check("watch reporta pc de la instruccion", r["pc"] == "0x8009", r)
        c.cmd("unwatch", addr="all")

        r = c.cmd("mem", addr=0x8000, len=4)
        check("mem 8000", r["data"] == "31F0BF3E", r)
        r = c.cmd("mem", addr=0x0000, len=2)
        check("mem ROM (slot 0)", r["ok"] and len(r["data"]) == 4, r)
        r = c.cmd("mmu")
        check("mmu", r["ok"] and r["mmu"][4:6] == [4, 5], r)
        r = c.cmd("nextreg", reg=0x14)
        check("nextreg 14 (color transparente)", r["ok"] and r["data"] == "E3", r)
        r = c.cmd("poke", addr=0x9100, value=0x5A)
        r = c.cmd("get", addr=0x9100)
        check("poke/get", r["value"] == 0x5A, r)
        r = c.cmd("mem", addr=0x1000, len=2, page=4)
        check("mem page 4", r["ok"], r)

        r = c.cmd("history", n=8)
        check("history", r["ok"] and len(r["history"]) == 8, r)

        c.cmd("break", addr=0x8005)
        r = c.cmd("resume", wait=True)
        check("breakpoint al reanudar (no repite el actual)", r["reason"] == "breakpoint" and r["pc"] == "0x8005", r)

        c.cmd("unbreak", addr="all")
        c.cmd("resume")
        time.sleep(0.3)
        v1 = c.cmd("get", addr=0x9000)["value"]
        time.sleep(0.3)
        v2 = c.cmd("get", addr=0x9000)["value"]
        check("corre libre (contador cambia)", v1 != v2, (v1, v2))

        r = c.cmd("profile", on=True)
        time.sleep(0.3)
        r = c.cmd("profile", top=3)
        check("profile", r["ok"] and r["total_tstates"] > 0, r)

        r = c.cmd("pause", wait=True)
        r = c.cmd("reset")
        check("reset", r["ok"], r)
        time.sleep(0.2)
        r = c.cmd("status")
        check("corre tras reset", r["state"] == "running", r)
    finally:
        p.terminate()
    print("%d fallos" % fails)
    sys.exit(1 if fails else 0)


main()
