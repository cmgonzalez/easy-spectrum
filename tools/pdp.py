#!/usr/bin/env python3
"""Cliente PDP (Prisma Debug Protocol). Librería + CLI.

  python tools/pdp.py [--port 7878] regs
  python tools/pdp.py break 0x8003
  python tools/pdp.py resume --wait
  python tools/pdp.py mem 0x8000 16

Como librería: c = Pdp(port); c.cmd("regs"); c.cmd("resume", wait=True).
"""
import itertools
import json
import socket
import sys


class Pdp:
    def __init__(self, port=7878, host="127.0.0.1", timeout=15):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.f = self.s.makefile("rwb", buffering=0)
        self.ids = itertools.count(1)
        self.events = []   # eventos asíncronos recibidos mientras se esperaba una respuesta

    def cmd(self, _cmd, /, **kw):
        i = next(self.ids)
        self.s.sendall((json.dumps({"id": i, "cmd": _cmd, **kw}) + "\n").encode())
        while True:
            line = self.f.readline()
            if not line:
                raise ConnectionError("servidor cerrado")
            m = json.loads(line)
            if m.get("event"):
                self.events.append(m)
                continue
            if m.get("id") == i:
                return m


POSITIONAL = {"break": ["addr"], "unbreak": ["addr"], "mem": ["addr", "len"], "poke": ["addr", "data"],
              "resume": ["until"], "run": ["until"]}


def main():
    a = sys.argv[1:]
    port = 7878
    if a[:1] == ["--port"]:
        port = int(a[1])
        a = a[2:]
    if not a:
        sys.exit(__doc__)
    kw, pos = {}, []
    for x in a[1:]:
        if x.startswith("--"):
            kw[x[2:]] = True
        else:
            pos.append(x)
    for k, v in zip(POSITIONAL.get(a[0], []), pos):
        kw[k] = v
    print(json.dumps(Pdp(port).cmd(a[0], **kw), indent=1))


if __name__ == "__main__":
    main()
