# tv box-display-enable

Relógio 24h no display frontal de TV boxes rodando Linux (Armbian e afins).
Mostra HH:MM com os dois-pontos piscando e acende os ícones de rede cabeada, Wi-Fi e USB.

Ícones de rede e Wi-Fi: **acesos** com a interface conectada e internet funcionando, **piscando** com a
interface conectada mas sem internet (ping a 1.1.1.1 e 8.8.8.8 a cada 30 s, ou 10 s quando cai) e
**apagados** sem conexão. USB acende quando há algum dispositivo USB conectado (hubs não contam).

## Compatibilidade

- **Chips:** displays de 4 dígitos com chip da família **FD650 / FD655 / FD6551 / TM1650**
  (2 fios: DAT e CLK; comando `0x48` liga o display, dígitos nos endereços `0x68`–`0x6E`).
  Comuns em boxes Amlogic (S905X, S905W, S905X2, S905X3, S905X4) e em algumas Allwinner e Rockchip.
- **Não serve** para chips de 3 fios (**FD628, TM1628, AiP1628**), que usam outro protocolo.
- **Sistema:** Linux com kernel 5.10 ou mais novo (GPIO uAPI v2), `python3` e `ping`. Sem pacotes extras.

Pinos, nome do gpiochip, mapa de segmentos, ordem dos dígitos e bits dos ícones mudam de box para box
e ficam em `/etc/fd655-clock.conf`. Sem alterações, valem os da box testada.

## Box testada

Instalado e testado em 07/11/2026 em:

- **Box:** T95 Max+ (Amlogic S905X3, 4 GB RAM, eMMC 32 GB), display frontal FD655 de 4 dígitos
- **Firmware Android de fábrica:** T95MAX+-X3-9.0-2GB4GB (Android 9, kernel 4.9.113)
- **Sistema:** Armbian / Debian 13 (trixie), kernel 6.18.49-meson64, rodando pelo cartão microSD,
  `box=s905x3_generic`, device tree "Meson SM1 ac2xx reference board minimal 100M"
- **Pinos:** GPIOH_6 = DAT (linha 22) e GPIOH_7 = CLK (linha 23) do gpiochip `periphs-banks`
- **Testes:** dígitos e ícones conferidos no display, pisca sem internet, e o serviço volta sozinho após reboot

## Instalação

```sh
sudo sh box_display.sh                  # instala (ou atualiza) e inicia o serviço fd655-clock
sudo sh box_display.sh test 1234        # mostra 4 dígitos por 10 s
sudo sh box_display.sh config           # mostra a configuração em uso
sudo sh box_display.sh status
sudo sh box_display.sh uninstall        # remove tudo, mas mantém /etc/fd655-clock.conf
```

Atualizar não sobrescreve um `/etc/fd655-clock.conf` que já exista.

## Adaptar a outra box

1. **Ache o chip e os pinos.** No Android de fábrica, procure no device tree um nó como `fd650`, `fd655`
   ou `openvfd` (`/proc/device-tree`), ou use o `vfd.conf` da sua box no CoreELEC/OpenVFD.
   No Linux, veja os gpiochips com `ls /dev/gpiochip*`: o banco de periféricos dos Amlogic é o `periphs-banks`.
   No Android antigo a numeração das linhas pode vir deslocada (nesta box era 1 a mais).
2. **Configure** `GPIO_CHIP`, `DAT_LINE` e `CLK_LINE` em `/etc/fd655-clock.conf`.
3. **Teste:** `sudo sh box_display.sh test 1234`. Se acender algo embaralhado, a comunicação está ok.
4. **Mapeie os segmentos:** `sudo sh box_display.sh scan-segments` acende um bit por vez; anote qual
   segmento acende em cada bit e preencha `SEGMENTS=a:BIT,b:BIT,...` (a = topo, sentido horário, g = meio).
   Se os dígitos saírem na ordem errada, troque a ordem em `DIGIT_ADDR`.
5. **Mapeie os ícones:** `sudo sh box_display.sh scan-icons` acende um bit de ícone por vez e mostra o
   número do passo; preencha `ICON_COLON`, `ICON_LAN`, `ICON_WIFI` e `ICON_USB` (0 desativa).
6. `sudo systemctl restart fd655-clock`.

Se adaptar para outra box, um pull request com a configuração dela é bem-vindo.

## Ícones na T95 Max+ (byte do endereço 0x66)

| bit  | ícone                      |
|------|----------------------------|
| 0x02 | USB                        |
| 0x10 | dois-pontos                |
| 0x20 | rede (pisca sem internet)  |
| 0x40 | Wi-Fi (pisca sem internet) |

## Arquivos

- `box_display.sh`: instalador com tudo embutido
- `FD655-protocolo.md`: protocolo, tempos e mapa de segmentos tirados do driver do Android
- `tools/fd655-clock.py`, `tools/fd655-clock.conf` e `tools/fd655-clock.service`: fontes do que o instalador grava
- `tools/armdis.py`: mini desmontador ARM32 usado para ler o driver do kernel Android
