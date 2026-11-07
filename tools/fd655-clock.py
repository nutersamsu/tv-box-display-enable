#!/usr/bin/env python3
"""Relógio 24h no display FD655 da TV box (Armbian), por bit-bang no /dev/gpiochip.
Protocolo e tempos copiados do driver do Android (ver FD655-protocolo.md).
Os dois-pontos piscam a cada segundo. Ícones: rede cabeada (0x20) e Wi-Fi (0x40)
acendem quando a interface física correspondente está conectada (operstate up);
USB (0x02) acende quando há algum dispositivo USB que não seja hub.
O display apaga quando o serviço para.
"""
import fcntl, os, signal, struct, sys, time

DAT, CLK = 22, 23          # GPIOH_6, GPIOH_7 no banco de periféricos
DELAY = 0.0005             # ~500 us, igual ao Android
DIGIT = [0x3f, 0x30, 0x5b, 0x79, 0x74, 0x6d, 0x6f, 0x38, 0x7f, 0x7d]
ADDR = (0x68, 0x6a, 0x6c, 0x6e)
ICONS, COLON = 0x66, 0x10
ICON_LAN, ICON_WIFI, ICON_USB = 0x20, 0x40, 0x02
F_INPUT, F_OUTPUT = 1 << 2, 1 << 3


def iowr(nr, size): return (3 << 30) | (size << 16) | (0xB4 << 8) | nr
def ior(nr, size): return (2 << 30) | (size << 16) | (0xB4 << 8) | nr


def config(dat_input=False):
    attrs, num = b'', 0
    if dat_input:
        attrs, num = struct.pack('<IIQQ', 1, 0, F_INPUT, 1), 1
    return struct.pack('<QI20x', F_OUTPUT, num) + attrs.ljust(240, b'\0')


def open_chip():
    for n in sorted(os.listdir('/dev')):
        if n.startswith('gpiochip'):
            fd = os.open('/dev/' + n, os.O_RDWR)
            info = fcntl.ioctl(fd, ior(0x01, 68), bytes(68))
            if b'periphs' in info[32:64]:
                return fd
            os.close(fd)
    sys.exit('chip de GPIO dos periféricos não encontrado')


class FD655:
    def __init__(self):
        chip = open_chip()
        req = bytearray(struct.pack('<64I', DAT, CLK, *([0] * 62)) + b'fd655-clock'.ljust(32, b'\0')
                        + config() + struct.pack('<II20xi', 2, 0, 0))
        fcntl.ioctl(chip, iowr(0x07, 592), req)
        os.close(chip)
        self.fd = struct.unpack_from('<i', req, 588)[0]
        self.dat = self.clk = 1
        self.dat_in = False
        self._put()

    def _put(self):
        bits = (self.dat & 1) | ((self.clk & 1) << 1)
        fcntl.ioctl(self.fd, iowr(0x0F, 16), struct.pack('<QQ', bits, 2 if self.dat_in else 3))
        time.sleep(DELAY)

    def _set(self, dat=None, clk=None):
        if dat is not None: self.dat = dat
        if clk is not None: self.clk = clk
        self._put()

    def _byte(self, b):
        for i in range(8):
            self._set(dat=(b >> (7 - i)) & 1)
            self._set(clk=1); self._set(clk=0)
        # pulso do ACK com o DAT solto, como no Android (o ACK não é conferido)
        self.dat = 1
        fcntl.ioctl(self.fd, iowr(0x0D, 272), config(dat_input=True))
        self.dat_in = True
        self._set(clk=1); self._set(clk=0)
        fcntl.ioctl(self.fd, iowr(0x0D, 272), config())
        self.dat_in = False
        self._put()

    def send(self, a, b):
        self._set(dat=1); self._set(clk=1); self._set(dat=0); self._set(clk=0)   # start
        self._byte(a); self._byte(b)
        self._set(dat=0); self._set(clk=1); self._set(dat=1)                      # stop

    def show(self, digits, icons):
        self.send(0x48, 0x03)                 # liga o display (repete para se recuperar sozinho)
        for addr, seg in zip(ADDR, digits):
            self.send(addr, seg)
        self.send(ICONS, icons)

    def blank(self):
        self.show([0, 0, 0, 0], 0)
        self.send(0x48, 0x00)                 # desliga o display


def net_icons():
    icons = 0
    for n in os.listdir('/sys/class/net'):
        base = f'/sys/class/net/{n}'
        if not os.path.exists(base + '/device'):
            continue                          # ignora docker, bridges, veth e lo
        try:
            with open(base + '/operstate') as f:
                up = f.read().strip() == 'up'
        except OSError:
            continue
        if up:
            icons |= ICON_WIFI if os.path.isdir(base + '/wireless') else ICON_LAN
    return icons


def usb_icon():
    root = '/sys/bus/usb/devices'
    for n in os.listdir(root):
        try:
            with open(f'{root}/{n}/bDeviceClass') as f:
                if f.read().strip() != '09':  # 09 = hub (inclui os hubs raiz)
                    return ICON_USB
        except OSError:
            continue                          # interfaces (ex.: 1-1:1.0) não têm esse arquivo
    return 0


def main():
    disp = FD655()
    running = True

    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    last = None
    while running:
        now = time.localtime()
        hhmm = time.strftime('%H%M', now)
        icons = (COLON if now.tm_sec % 2 == 0 else 0) | net_icons() | usb_icon()
        digits = [DIGIT[int(c)] for c in hhmm]
        if (hhmm, icons) != last:
            if last is None or hhmm != last[0] or now.tm_sec == 0:
                disp.show(digits, icons)      # redesenha tudo ao mudar o minuto
            else:
                disp.send(ICONS, icons)       # só atualiza dois-pontos e ícones
            last = (hhmm, icons)
        time.sleep(1.0 - (time.time() % 1.0) + 0.01)
    disp.blank()


if __name__ == '__main__':
    main()
