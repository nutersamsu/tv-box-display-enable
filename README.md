# tv box-display-enable

Relógio 24h no display frontal FD655 da TV box S905X3 (T95 Max+) rodando Armbian.
Mostra HH:MM com os dois-pontos piscando e acende os ícones de rede cabeada, Wi-Fi e USB.

Ícones de rede e Wi-Fi: **acesos** com a interface conectada e internet funcionando, **piscando** com a
interface conectada mas sem internet (ping a 1.1.1.1 e 8.8.8.8 a cada 30 s, ou 10 s quando cai) e
**apagados** sem conexão. USB acende quando há algum dispositivo USB conectado (hubs não contam).

## Box testada

Instalado e testado em 07/11/2026 em:

- **Box:** T95 Max+ (Amlogic S905X3, 4 GB RAM, eMMC 32 GB), display frontal FD655 de 4 dígitos
- **Firmware Android de fábrica:** T95MAX+-X3-9.0-2GB4GB (Android 9, kernel 4.9.113)
- **Sistema:** Armbian / Debian 13 (trixie), kernel 6.18.49-meson64, rodando pelo cartão microSD,
  `box=s905x3_generic`, device tree "Meson SM1 ac2xx reference board minimal 100M"
- **Testes:** dígitos e ícones conferidos no display, e o serviço volta sozinho após reboot

Outra box pode usar pinos, ordem de segmentos ou bits de ícone diferentes.
Use `tools/fd655_test.py` e `tools/fd655-icon-scan.py` para conferir.

## Instalação

```sh
sudo sh box_display.sh            # instala e inicia o serviço fd655-clock
sudo sh box_display.sh test       # mostra 12:34 por 10 s
sudo sh box_display.sh status
sudo sh box_display.sh uninstall
```

Só precisa de `python3` e `ping`, sem pacotes extras. O bit-bang é feito direto no `/dev/gpiochip`
(GPIO uAPI v2), nas linhas 22 (DAT, GPIOH_6) e 23 (CLK, GPIOH_7) do `periphs-banks`.

## Ícones (byte do endereço 0x66)

| bit  | ícone       |
|------|-------------|
| 0x02 | USB         |
| 0x10 | dois-pontos |
| 0x20 | rede (pisca sem internet)  |
| 0x40 | Wi-Fi (pisca sem internet) |

## Arquivos

- `box_display.sh`: instalador com tudo embutido
- `FD655-protocolo.md`: protocolo, tempos e mapa de segmentos tirados do driver do Android
- `tools/fd655-clock.py` e `tools/fd655-clock.service`: fontes do que o instalador grava
- `tools/fd655_test.py`: teste avulso (mostra um texto de 4 caracteres e informa o ACK)
- `tools/fd655-icon-scan.py`: acende um bit de ícone por vez para mapear as luzes
- `tools/armdis.py`: mini desmontador ARM32 usado para ler o driver do kernel Android
