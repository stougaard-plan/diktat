#!/usr/bin/env python3
"""Finder en ledig portbase til en testkørsel: skriver B, så B+offset er ledige på 127.0.0.1 for alle offsets.
Brug: pick_port_base.py <offset> [<offset> ...]. Tilfældig start, så to testkørsler samtidig får hver sin base."""
import random
import socket
import sys

offsets = [int(a) for a in sys.argv[1:]] or [1]
for _ in range(200):
    base = random.randint(20000, 45000)
    ok = True
    socks = []
    for o in offsets:
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", base + o))
            socks.append(s)
        except OSError:
            ok = False
            break
    for s in socks:
        s.close()
    if ok:
        print(base)
        sys.exit(0)
sys.exit("Ingen ledig portbase fundet")
