#!/bin/sh
# box_display.sh: instala um relógio 24h no display frontal de TV boxes com Linux (Armbian e afins).
# Funciona com displays de 4 dígitos com chip da família FD650/FD655/FD6551/TM1650 (2 fios: DAT e CLK).
# Não serve para chips de 3 fios (FD628, TM1628, AiP1628).
#
# Mostra HH:MM com os dois-pontos piscando e os ícones de rede cabeada, Wi-Fi e USB.
# Rede/Wi-Fi: acesos com internet, piscando sem internet (ping), apagados sem conexão.
# Não precisa de pacotes extras: só python3, ping e o /dev/gpiochip (GPIO uAPI v2, kernel 5.10+).
#
# Tudo o que muda de uma box para outra (pinos, gpiochip, segmentos, ícones) fica em
# /etc/fd655-clock.conf. Sem esse arquivo valem os padrões da box testada:
#
# Instalado e testado em 07/11/2026 em:
#   Box:      T95 Max+ (Amlogic S905X3, 4 GB RAM, eMMC 32 GB), display frontal FD655 (4 dígitos)
#             Firmware Android de fábrica: T95MAX+-X3-9.0-2GB4GB (Android 9, kernel 4.9.113)
#   Sistema:  Armbian / Debian 13 (trixie), kernel 6.18.49-meson64, rodando pelo cartão microSD
#             boot.config: box=s905x3_generic; device tree: "Meson SM1 ac2xx reference board minimal 100M"
#   Pinos:    GPIOH_6 = DAT (linha 22) e GPIOH_7 = CLK (linha 23) do gpiochip "periphs-banks"
#   Testes:   dígitos e ícones conferidos no display; serviço volta sozinho após reboot
#
# Uso (como root):
#   sh box_display.sh                 instala (ou atualiza) e inicia; não sobrescreve a config
#   sh box_display.sh test [1234]     mostra 4 dígitos por 10 s (para o relógio durante o teste)
#   sh box_display.sh scan-segments   acende um bit de segmento por vez (para montar SEGMENTS)
#   sh box_display.sh scan-icons      acende um bit de ícone por vez (para achar os ICON_*)
#   sh box_display.sh config          mostra a configuração em uso
#   sh box_display.sh status          mostra o estado do serviço
#   sh box_display.sh uninstall       para, apaga o display e remove tudo (a config fica)
#
# Adaptar a outra box: pegue os pinos no device tree do Android de fábrica (nó fd650/fd655/
# openvfd, ou o vfd.conf do CoreELEC/OpenVFD), ajuste /etc/fd655-clock.conf, rode
# "test", depois "scan-segments" e "scan-icons", e reinicie o serviço.
set -eu

BIN=/usr/local/sbin/fd655-clock
UNIT=/etc/systemd/system/fd655-clock.service
CONF=/etc/fd655-clock.conf

[ "$(id -u)" = 0 ] || { echo "rode como root"; exit 1; }

need() {
    command -v python3 >/dev/null || { echo "python3 não encontrado (apt install python3)"; exit 1; }
    ls /dev/gpiochip* >/dev/null 2>&1 || { echo "nenhum /dev/gpiochip encontrado"; exit 1; }
}

write_bin() {
cat > "$BIN" <<'PYEOF'
#!/usr/bin/env python3
"""Relógio 24h para displays frontais de 4 dígitos com chip da família FD650/FD655/FD6551/TM1650
(protocolo de 2 fios: DAT e CLK), por bit-bang no /dev/gpiochip (GPIO uAPI v2, kernel 5.10+).

Tudo o que muda de uma box para outra fica em /etc/fd655-clock.conf (veja CONFIG_PADRAO).
Os valores padrão são os da T95 Max+ (Amlogic S905X3), onde foi testado.

Comportamento:
  - HH:MM com os dois-pontos piscando a cada segundo;
  - ícones de rede e Wi-Fi: acesos com a interface conectada e internet funcionando,
    piscando sem internet (ping numa thread) e apagados sem conexão;
  - ícone USB: aceso quando há algum dispositivo USB que não seja hub;
  - o display apaga quando o serviço para.

Modos de teste (pare o serviço antes: systemctl stop fd655-clock):
  fd655-clock --test 1234          mostra 4 dígitos por 10 s
  fd655-clock --scan-segments      acende um bit de segmento por vez (para montar o SEGMENTS)
  fd655-clock --scan-icons         acende um bit de ícone por vez (para achar os ICON_*)
  fd655-clock --show-config        mostra a configuração em uso
"""
import fcntl, os, signal, struct, subprocess, sys, threading, time

CONF = '/etc/fd655-clock.conf'

CONFIG_PADRAO = {
    'GPIO_CHIP': 'periphs',          # parte do nome (label) do gpiochip, ou caminho /dev/gpiochipN
    'DAT_LINE': '22',                # linha do DAT nesse gpiochip (aqui GPIOH_6)
    'CLK_LINE': '23',                # linha do CLK nesse gpiochip (aqui GPIOH_7)
    'DELAY_US': '500',               # atraso entre transições (o driver do Android usa ~500 us)
    'DISPLAY_ON': '0x03',            # byte enviado após o comando 0x48 para ligar o display
    'DIGIT_ADDR': '0x68,0x6a,0x6c,0x6e',   # endereços dos dígitos, da esquerda para a direita
    'ICON_ADDR': '0x66',             # endereço do byte de ícones (vazio = display sem ícones)
    'SEGMENTS': 'a:3,b:4,c:5,d:0,e:1,f:2,g:6',  # bit de cada segmento (a = topo, sentido horário, g = meio)
    'ICON_COLON': '0x10',            # bits dos ícones no byte de ícones; 0 desativa
    'ICON_LAN': '0x20',
    'ICON_WIFI': '0x40',
    'ICON_USB': '0x02',
    'PING_TARGETS': '1.1.1.1,8.8.8.8',
    'PING_INTERVAL': '30',           # segundos entre testes de internet
    'PING_INTERVAL_DOWN': '10',      # idem, enquanto a internet está fora
}

# segmentos acesos em cada dígito, no padrão de 7 segmentos (a a g)
DIGITOS = ['abcdef', 'bc', 'abdeg', 'abcdg', 'bcfg', 'acdfg', 'acdefg', 'abc', 'abcdefg', 'abcdfg']
F_INPUT, F_OUTPUT = 1 << 2, 1 << 3


def carregar_config():
    cfg = dict(CONFIG_PADRAO)
    try:
        with open(CONF) as f:
            for n, linha in enumerate(f, 1):
                linha = linha.split('#', 1)[0].strip()
                if not linha:
                    continue
                if '=' not in linha:
                    sys.exit(f'{CONF}:{n}: linha sem "=": {linha}')
                k, v = (x.strip() for x in linha.split('=', 1))
                if k not in CONFIG_PADRAO:
                    sys.exit(f'{CONF}:{n}: chave desconhecida: {k}')
                cfg[k] = v.strip('"\'')
    except FileNotFoundError:
        pass
    return cfg


def num(v): return int(v, 0)
def lista(v): return [x.strip() for x in v.split(',') if x.strip()]


class Config:
    def __init__(self, c):
        self.raw = c
        self.chip = c['GPIO_CHIP']
        self.dat, self.clk = num(c['DAT_LINE']), num(c['CLK_LINE'])
        self.delay = num(c['DELAY_US']) / 1e6
        self.display_on = num(c['DISPLAY_ON'])
        self.digit_addr = [num(x) for x in lista(c['DIGIT_ADDR'])]
        self.icon_addr = num(c['ICON_ADDR']) if c['ICON_ADDR'] else None
        seg = {}
        for par in lista(c['SEGMENTS']):
            nome, bit = par.split(':')
            seg[nome.strip()] = 1 << num(bit)
        if sorted(seg) != list('abcdefg'):
            sys.exit('SEGMENTS precisa definir os 7 segmentos a, b, c, d, e, f e g')
        self.digit = [sum(seg[s] for s in d) for d in DIGITOS]
        self.colon, self.lan, self.wifi, self.usb = (num(c[k]) for k in ('ICON_COLON', 'ICON_LAN', 'ICON_WIFI', 'ICON_USB'))
        self.ping_targets = lista(c['PING_TARGETS'])
        self.ping_ok_s, self.ping_down_s = num(c['PING_INTERVAL']), num(c['PING_INTERVAL_DOWN'])


def iowr(nr, size): return (3 << 30) | (size << 16) | (0xB4 << 8) | nr
def ior(nr, size): return (2 << 30) | (size << 16) | (0xB4 << 8) | nr


def line_config(dat_input=False):
    attrs, n = b'', 0
    if dat_input:                                   # só a linha 0 (DAT) vira entrada
        attrs, n = struct.pack('<IIQQ', 1, 0, F_INPUT, 1), 1
    return struct.pack('<QI20x', F_OUTPUT, n) + attrs.ljust(240, b'\0')


def abrir_chip(chip):
    if chip.startswith('/dev/'):
        return os.open(chip, os.O_RDWR)
    nomes = []
    for n in sorted(os.listdir('/dev')):
        if n.startswith('gpiochip'):
            fd = os.open('/dev/' + n, os.O_RDWR)
            label = fcntl.ioctl(fd, ior(0x01, 68), bytes(68))[32:64].rstrip(b'\0').decode()
            nomes.append(f'{n}={label}')
            if chip in label:
                return fd
            os.close(fd)
    sys.exit(f'gpiochip com "{chip}" no nome não encontrado. Disponíveis: {", ".join(nomes)}')


class FD655:
    def __init__(self, cfg):
        self.cfg = cfg
        chip = abrir_chip(cfg.chip)
        req = bytearray(struct.pack('<64I', cfg.dat, cfg.clk, *([0] * 62)) + b'fd655-clock'.ljust(32, b'\0')
                        + line_config() + struct.pack('<II20xi', 2, 0, 0))
        try:
            fcntl.ioctl(chip, iowr(0x07, 592), req)
        except OSError as e:
            sys.exit(f'não consegui reservar as linhas {cfg.dat} e {cfg.clk}: {e} (outro programa está usando?)')
        os.close(chip)
        self.fd = struct.unpack_from('<i', req, 588)[0]
        self.dat = self.clk = 1
        self.dat_in = False
        self._put()

    def _put(self):
        bits = (self.dat & 1) | ((self.clk & 1) << 1)
        fcntl.ioctl(self.fd, iowr(0x0F, 16), struct.pack('<QQ', bits, 2 if self.dat_in else 3))
        time.sleep(self.cfg.delay)

    def _set(self, dat=None, clk=None):
        if dat is not None: self.dat = dat
        if clk is not None: self.clk = clk
        self._put()

    def _byte(self, b):
        for i in range(8):
            self._set(dat=(b >> (7 - i)) & 1)
            self._set(clk=1); self._set(clk=0)
        # pulso do ACK com o DAT solto, como no driver do Android (o ACK não é conferido)
        self.dat = 1
        fcntl.ioctl(self.fd, iowr(0x0D, 272), line_config(dat_input=True))
        self.dat_in = True
        self._set(clk=1); self._set(clk=0)
        fcntl.ioctl(self.fd, iowr(0x0D, 272), line_config())
        self.dat_in = False
        self._put()

    def send(self, a, b):
        self._set(dat=1); self._set(clk=1); self._set(dat=0); self._set(clk=0)   # start
        self._byte(a); self._byte(b)
        self._set(dat=0); self._set(clk=1); self._set(dat=1)                      # stop

    def icons(self, valor):
        if self.cfg.icon_addr is not None:
            self.send(self.cfg.icon_addr, valor)

    def show(self, segs, icons):
        self.send(0x48, self.cfg.display_on)  # liga o display (repete para se recuperar sozinho)
        for addr, s in zip(self.cfg.digit_addr, segs):
            self.send(addr, s)
        self.icons(icons)

    def blank(self):
        self.show([0] * len(self.cfg.digit_addr), 0)
        self.send(0x48, 0x00)                 # desliga o display


def net_icons(cfg):
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
            icons |= cfg.wifi if os.path.isdir(base + '/wireless') else cfg.lan
    return icons


def usb_icon(cfg):
    root = '/sys/bus/usb/devices'
    for n in os.listdir(root):
        try:
            with open(f'{root}/{n}/bDeviceClass') as f:
                if f.read().strip() != '09':  # 09 = hub (inclui os hubs raiz)
                    return cfg.usb
        except OSError:
            continue                          # interfaces (ex.: 1-1:1.0) não têm esse arquivo
    return 0


internet_ok = True                            # começa "ok" para não piscar à toa no boot


def vigia_internet(cfg):
    global internet_ok
    while True:
        ok = any(subprocess.run(['ping', '-c', '1', '-W', '2', alvo], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL).returncode == 0 for alvo in cfg.ping_targets)
        internet_ok = ok
        time.sleep(cfg.ping_ok_s if ok else cfg.ping_down_s)


def relogio(cfg):
    disp = FD655(cfg)
    running = True

    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    if cfg.ping_targets and (cfg.lan or cfg.wifi):
        threading.Thread(target=vigia_internet, args=(cfg,), daemon=True).start()
    last = None
    while running:
        now = time.localtime()
        hhmm = time.strftime('%H%M', now)
        par = now.tm_sec % 2 == 0
        rede = net_icons(cfg)
        if not internet_ok and not par:
            rede = 0                          # sem internet: ícone de rede pisca
        icons = (cfg.colon if par else 0) | rede | usb_icon(cfg)
        segs = [cfg.digit[int(c)] for c in hhmm]
        if (hhmm, icons) != last:
            if last is None or hhmm != last[0] or now.tm_sec == 0:
                disp.show(segs, icons)        # redesenha tudo ao mudar o minuto
            else:
                disp.icons(icons)             # só atualiza dois-pontos e ícones
            last = (hhmm, icons)
        time.sleep(1.0 - (time.time() % 1.0) + 0.01)
    disp.blank()


def teste(cfg, texto):
    disp = FD655(cfg)
    n = len(cfg.digit_addr)
    segs = [cfg.digit[int(c)] if c.isdigit() else 0 for c in texto.ljust(n)[:n]]
    disp.show(segs, cfg.colon)
    print(f'o display deve mostrar {texto} com os dois-pontos por 10 s')
    time.sleep(10)
    disp.blank()


def scan_segments(cfg):
    disp = FD655(cfg)
    print('Cada passo acende o mesmo bit em todos os dígitos por 5 s.')
    print('Anote qual segmento acende (a = topo, b = cima à direita, c = baixo à direita,')
    print('d = base, e = baixo à esquerda, f = cima à esquerda, g = meio, ou "ponto"/nada).')
    for bit in range(8):
        print(f'  bit {bit}...', flush=True)
        disp.show([1 << bit] * len(cfg.digit_addr), 0)
        time.sleep(5)
    disp.blank()
    print('Monte o SEGMENTS no formato a:BIT,b:BIT,... e grave em', CONF)


def scan_icons(cfg):
    if cfg.icon_addr is None:
        sys.exit('ICON_ADDR vazio: este display não tem ícones configurados')
    disp = FD655(cfg)
    print('Cada passo acende um bit de ícone por 6 s; o display mostra o número do passo (1 a 8).')
    for bit in range(8):
        print(f'  passo {bit + 1}: bit {1 << bit:#04x}', flush=True)
        segs = [0] * len(cfg.digit_addr)
        segs[-1] = cfg.digit[bit + 1]
        disp.show(segs, 1 << bit)
        time.sleep(6)
    disp.blank()


def main():
    cfg = Config(carregar_config())
    args = sys.argv[1:]
    if not args:
        relogio(cfg)
    elif args[0] == '--test':
        teste(cfg, args[1] if len(args) > 1 else '1234')
    elif args[0] == '--scan-segments':
        scan_segments(cfg)
    elif args[0] == '--scan-icons':
        scan_icons(cfg)
    elif args[0] == '--show-config':
        for k in CONFIG_PADRAO:
            origem = '' if cfg.raw[k] == CONFIG_PADRAO[k] else '   (do arquivo)'
            print(f'{k}={cfg.raw[k]}{origem}')
        print('# tabela de dígitos 0-9:', ' '.join(f'{d:02x}' for d in cfg.digit))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
PYEOF
chmod 755 "$BIN"
}

write_unit() {
cat > "$UNIT" <<'UNITEOF'
[Unit]
Description=Relogio 24h no display FD655 da frente da box
After=time-sync.target
Wants=time-sync.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -I /usr/local/sbin/fd655-clock
Restart=always
RestartSec=5
Nice=5

[Install]
WantedBy=multi-user.target
UNITEOF
}

write_conf() {
cat > "$CONF" <<'CONFEOF'
# /etc/fd655-clock.conf: configuração do relógio no display frontal (chips FD650/FD655/FD6551/TM1650).
# Linhas comentadas usam o valor padrão, que é o da T95 Max+ (S905X3), onde foi testado.
# Depois de mudar: systemctl restart fd655-clock    (ver o que está valendo: fd655-clock --show-config)

# --- ligação do chip ---
#GPIO_CHIP=periphs           # parte do nome do gpiochip (veja: ls /dev/gpiochip*) ou /dev/gpiochipN
#DAT_LINE=22                 # linha do DAT (T95 Max+: GPIOH_6)
#CLK_LINE=23                 # linha do CLK (T95 Max+: GPIOH_7)
#DELAY_US=500                # atraso entre transições, em microssegundos
#DISPLAY_ON=0x03             # byte após o comando 0x48 que liga o display

# --- dígitos e segmentos ---
#DIGIT_ADDR=0x68,0x6a,0x6c,0x6e    # endereços dos dígitos, da esquerda para a direita
#SEGMENTS=a:3,b:4,c:5,d:0,e:1,f:2,g:6   # descubra com: fd655-clock --scan-segments

# --- ícones (bits do byte de ícones; 0 desativa) ---
#ICON_ADDR=0x66              # vazio se o display não tiver ícones
#ICON_COLON=0x10             # descubra com: fd655-clock --scan-icons
#ICON_LAN=0x20
#ICON_WIFI=0x40
#ICON_USB=0x02

# --- teste de internet (ícones de rede piscam sem internet) ---
#PING_TARGETS=1.1.1.1,8.8.8.8     # vazio desativa o teste
#PING_INTERVAL=30
#PING_INTERVAL_DOWN=10
CONFEOF
chmod 644 "$CONF"
}

# roda um modo de teste com o serviço parado e depois o religa se estava ativo
com_servico_parado() {
    need
    [ -f "$BIN" ] || write_bin
    was_active=$(systemctl is-active fd655-clock 2>/dev/null || true)
    systemctl stop fd655-clock 2>/dev/null || true
    python3 -I "$BIN" "$@" || true
    [ "$was_active" = active ] && systemctl start fd655-clock
    return 0
}

case "${1:-install}" in
install)
    need
    write_bin
    write_unit
    [ -f "$CONF" ] || write_conf
    systemctl daemon-reload
    systemctl enable fd655-clock >/dev/null 2>&1
    systemctl restart fd655-clock
    sleep 2
    echo "fd655-clock: $(systemctl is-active fd655-clock)   (config: $CONF)"
    ;;
test)          com_servico_parado --test "${2:-1234}" ;;
scan-segments) com_servico_parado --scan-segments ;;
scan-icons)    com_servico_parado --scan-icons ;;
config)        need; [ -f "$BIN" ] || write_bin; python3 -I "$BIN" --show-config ;;
status)
    systemctl status fd655-clock --no-pager || true
    ;;
uninstall)
    systemctl disable --now fd655-clock 2>/dev/null || true
    rm -f "$UNIT" "$BIN"
    systemctl daemon-reload
    echo "removido (a configuração $CONF foi mantida)"
    ;;
*)
    echo "uso: $0 [install|test [1234]|scan-segments|scan-icons|config|status|uninstall]"; exit 1
    ;;
esac
