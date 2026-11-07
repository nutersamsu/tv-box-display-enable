#!/usr/bin/env python3
# Acende um bit do byte de ícones (0x66) por vez, por 6 s, mostrando "b  N" (N = 1 a 8 = bit 0 a 7).
import importlib.machinery, importlib.util, time
spec = importlib.util.spec_from_file_location('clk', '/usr/local/sbin/fd655-clock',
                                              loader=importlib.machinery.SourceFileLoader('clk', '/usr/local/sbin/fd655-clock'))
clk = importlib.util.module_from_spec(spec); spec.loader.exec_module(clk)
d = clk.FD655()
import sys
bits = [int(b) - 1 for b in sys.argv[1:]] or range(8)
for bit in bits:
    d.show([0x67, 0, 0, clk.DIGIT[bit + 1]], 1 << bit)
    time.sleep(6)
d.show([0x67, 0, 0, 0x40], 0xff)   # todos acesos: "b  -"
time.sleep(8)
