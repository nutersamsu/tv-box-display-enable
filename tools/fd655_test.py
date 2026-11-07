#!/usr/bin/env python3
"""Teste do display FD655 da TV box no Armbian, por bit-bang no /dev/gpiochip (GPIO uAPI v2).
Tempos e sequência copiados do driver do Android (ver ../FD655-protocolo.md).
Uso: fd655_test.py [texto de 4 caracteres] [icones_hex]   ex.: fd655_test.py 1234 10
"""
import fcntl, os, struct, sys, time

DAT, CLK = 22, 23          # GPIOH_6, GPIOH_7 no banco de periféricos
DELAY = 0.0005             # ~500 us, igual ao Android
SEG = {'0': 0x3f, '1': 0x30, '2': 0x5b, '3': 0x79, '4': 0x74, '5': 0x6d, '6': 0x6f,
       '7': 0x38, '8': 0x7f, '9': 0x7d, 'a': 0x77, 'b': 0x67, 'c': 0x58, 'C': 0x39,
       'd': 0x5e, 'o': 0x63, 't': 0x47, 'f': 0x71, '-': 0x40, ' ': 0x00}

def IOWR(nr, size): return (3 << 30) | (size << 16) | (0xB4 << 8) | nr
def IOR(nr, size): return (2 << 30) | (size << 16) | (0xB4 << 8) | nr
F_INPUT, F_OUTPUT = 1 << 2, 1 << 3

def find_chip():
    for n in sorted(os.listdir('/dev')):
        if not n.startswith('gpiochip'):
            continue
        fd = os.open('/dev/' + n, os.O_RDWR)
        info = fcntl.ioctl(fd, IOR(0x01, 68), bytes(68))
        name, label = info[:32].rstrip(b'\0'), info[32:64].rstrip(b'\0')
        lines = struct.unpack_from('<I', info, 64)[0]
        print(f'{n}: {label.decode()} ({lines} linhas)')
        if b'periphs' in label:
            return fd
        os.close(fd)
    sys.exit('chip de periféricos não encontrado')

def config(dat_input=False):
    attrs = b''
    num = 0
    if dat_input:
        attrs = struct.pack('<IIQQ', 1, 0, F_INPUT, 1)  # id=FLAGS, máscara = linha 0 (DAT)
        num = 1
    return struct.pack('<QI20x', F_OUTPUT, num) + attrs.ljust(240, b'\0')

class Bus:
    def __init__(self, chip):
        offs = struct.pack('<64I', DAT, CLK, *([0] * 62))
        req = offs + b'fd655-test'.ljust(32, b'\0') + config() + struct.pack('<II20xi', 2, 0, 0)
        assert len(req) == 592
        buf = bytearray(req)
        fcntl.ioctl(chip, IOWR(0x07, 592), buf)
        self.fd = struct.unpack_from('<i', buf, 588)[0]
        self.dat = self.clk = 1
        self.dat_in = False
        self.put()

    def put(self):
        bits = (self.dat & 1) | ((self.clk & 1) << 1)
        mask = 2 if self.dat_in else 3
        fcntl.ioctl(self.fd, IOWR(0x0F, 16), struct.pack('<QQ', bits, mask))
        time.sleep(DELAY)

    def set(self, dat=None, clk=None):
        if dat is not None: self.dat = dat
        if clk is not None: self.clk = clk
        self.put()

    def start(self):
        self.set(dat=1); self.set(clk=1); self.set(dat=0); self.set(clk=0)

    def stop(self):
        self.set(dat=0); self.set(clk=1); self.set(dat=1)

    def byte(self, b):
        for i in range(8):
            self.set(dat=(b >> (7 - i)) & 1)
            self.set(clk=1); self.set(clk=0)
        # ACK: solta o DAT (entrada) e lê no pulso de clock; o Android não confere
        self.dat = 1
        fcntl.ioctl(self.fd, IOWR(0x0D, 272), config(dat_input=True))
        self.dat_in = True
        self.set(clk=1)
        v = bytearray(struct.pack('<QQ', 0, 1))
        fcntl.ioctl(self.fd, IOWR(0x0E, 16), v)
        ack = struct.unpack_from('<Q', v)[0] & 1
        self.set(clk=0)
        fcntl.ioctl(self.fd, IOWR(0x0D, 272), config())
        self.dat_in = False
        self.put()
        return 'ACK' if ack == 0 else 'sem ACK'

    def send(self, a, b):
        self.start(); r = (self.byte(a), self.byte(b)); self.stop()
        print(f'  {a:#04x} {b:#04x}: {r[0]}, {r[1]}')

def main():
    text = (sys.argv[1] if len(sys.argv) > 1 else '1234')[:4].rjust(4)
    icons = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x10
    bus = Bus(find_chip())
    bus.send(0x48, 0x03)                       # liga o display (igual ao Android)
    for addr, ch in zip((0x68, 0x6a, 0x6c, 0x6e), text):
        bus.send(addr, SEG.get(ch, 0))
    bus.send(0x66, icons)
    os.close(bus.fd)

if __name__ == '__main__':
    main()
