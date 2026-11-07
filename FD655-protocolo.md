# Display FD655 da TV box S905X3: dados tirados do Android (07/11/2026)

Fonte: kernel do Android 9 (Linux 4.9.113, ARM 32 bits), partição `boot` copiada por ADB
para `android-dump/`. Os símbolos foram recuperados do kallsyms (`android-dump/symbols.txt`)
e a desmontagem está em `android-dump/fd655.dis` (feita com `tools/armdis.py`).
No arquivo vmlinux.bin, deslocamento = VA - 0xc0108000.

## Pinos (device tree do Android, nó `fd655_dev`, compatible `amlogic,fd655_dev`)
- Banco: `pinctrl@ff634480/banks@ff6346c0` (periféricos, não é o AO)
- Números do Android: dat_pin = 23 e clk_pin = 24, ou seja, GPIOH_6 = DAT e GPIOH_7 = CLK
- No Armbian (mainline): DAT = linha 22 e CLK = linha 23 do gpiochip dos periféricos
- No Android, os GPIOs 433 e 434 ficam "out hi" quando o display está parado
- Existe também um `fd6513_dev` (LED multicolor) no banco AO: dat = GPIOAO_6, clk = GPIOAO_7

## Protocolo (bit-bang, parecido com TM1650/FD650, mas sem endereço I2C)
- Atraso entre transições: `__const_udelay(0x20c498)`, cerca de 500 µs (bem lento)
- Start: DAT=1, CLK=1, espera, DAT=0, espera, CLK=0
- Byte: MSB primeiro. Para cada bit: DAT=bit, espera, CLK=1, espera, CLK=0
- ACK: DAT=1, DAT vira entrada, espera, CLK=1, espera, CLK=0. **O driver não lê o ACK.**
- Stop: DAT=0, espera, CLK=1, espera, DAT=1, espera
- Comando de sistema (ao abrir o dispositivo): Start, 0x48, 0x03, Stop
- Dígitos: Start, endereço, segmentos, Stop
  - Endereços: 0x68, 0x6A, 0x6C e 0x6E para os dígitos 1 a 4; 0x66 para os ícones
  - O dígito 1 é o mais à esquerda (é o primeiro byte do write)

## Mapa de segmentos
bit0=d, bit1=e, bit2=f, bit3=a, bit4=b, bit5=c, bit6=g

Tabela do driver (caractere → byte):
0=3f 1=30 2=5b 3=79 4=74 5=6d 6=6f 7=38 8=7f 9=7d
a/A=77 b=67 B=7c c=58 C=39 d/D=5e o=63 t=47 f/F=71 ':'=10
Os bytes 0x00 a 0x09 também viram os dígitos 0 a 9, que é o que o script de relógio usa.
O driver mostra algumas letras: a, b, c, d, o, t, f.

## Ícones (byte para o endereço 0x66)
- O 5º byte do write vai direto para lá, com ajustes de play e pause (bits 0x04 e 0x08)
- 0x10 = dois-pontos. O relógio alterna entre 0x45 e 0x55.

## Ícones confirmados no Armbian (varredura de 07/11/2026)
- 0x10 = dois-pontos
- 0x20 = rede cabeada
- 0x40 = Wi-Fi
- 0x02 = USB
- Os bits 0x01, 0x04, 0x08 e 0x80 não acenderam nada que o usuário tenha identificado.
