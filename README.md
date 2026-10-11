# Raspberry Pi Pico — SPI0 + DMA a 31,25 MHz

**Leitura de 16 MiB de memória SPI NOR em 5,107 segundos com Raspberry Pi Pico (RP2040).**

Este repositório preserva um experimento de leitura SPI NOR utilizando o periférico **SPI0 de hardware** e dois canais **DMA** do RP2040, sem PIO e sem overclock do clock do sistema. O ensaio foi repetido em 11/10/2026, reproduzindo praticamente os mesmos tempos da execução original.

> **Estado:** benchmark original reproduzido e validado. O firmware-fonte e o arquivo UF2 foram preservados no ambiente WSL do experimento e serão adicionados a este repositório separadamente. Este README não significa que os demais arquivos já estejam publicados.

## Resultados reproduzidos

| Modalidade | Registro histórico | Nova execução | Integridade |
| --- | ---: | ---: | --- |
| Modo 0 — transferência SPI + DMA | 5,107000 s | **5,106939 s** | Sem verificação integral dos bytes |
| Modo 1 — transferência SPI + DMA com verificação | 9,938644 s | **9,938581 s** | **Zero erros em 16 MiB** |

**Parâmetros:** flash Macronix MX25L12835F, capacidade de 16 MiB, JEDEC `C2 20 18`, SPI0 a **31.250.000 Hz** efetivos informados pelo Pico SDK, RP2040 a **125 MHz**. A taxa útil do modo 0 foi aproximadamente **3,13 MiB/s**.

O modo 0 lê os 16 MiB com consumo mínimo dos dados recebidos, mas **não verifica cada byte**; o `ERRORS=0` desse modo não constitui prova de integridade. O modo 1 compara todos os bytes contra o conteúdo esperado e confirmou zero erros.

### Registro da execução de 11/10/2026

```text
PONG
START_OK
JEDEC=C22018
SPI_HZ=31250000
BENCH_BEGIN MODE=0
BENCH_END MODE=0 US=5106939 KIB_S=3208 ERRORS=0 FIRST=FFFFFFFF CHECK=228
BENCH_BEGIN MODE=1
BENCH_END MODE=1 US=9938581 KIB_S=1648 ERRORS=0 FIRST=FFFFFFFF CHECK=0
TEST_END RESULT=PASS TOTAL_ERRORS=0
```

## Hardware e pinout original

A montagem validada usa **SPI0**, não uma implementação SPI em PIO. Os GPIOs foram ligados diretamente à flash externa em **3,3 V**.

| Sinal | Raspberry Pi Pico | Pino físico Pico | Flash SPI, encapsulamento 8 pinos |
| --- | --- | ---: | --- |
| SCK / CLK | GP2 | 4 | 6 |
| MOSI / SI | GP3 | 5 | 5 |
| MISO / SO | GP4 | 6 | 2 |
| CS# | GP5 | 7 | 1 |
| GND | GND | 8 | 4 |
| VCC | 3V3 | 36 | 8 |
| WP# | 3V3 por resistor de 10 kΩ | — | 3 |
| HOLD#/RESET# | 3V3 por resistor de 10 kΩ | — | 7 |

```text
Raspberry Pi Pico                   MX25L12835F (SPI NOR)
GP5  (CS#)  ----------------------> 1  CS#
GP4  (RX)   <---------------------- 2  SO / MISO
3V3 ---[10k]---------------------> 3  WP#
GND          --------------------- 4  GND
GP3  (TX)   ---------------------> 5  SI / MOSI
GP2  (SCK)  ---------------------> 6  CLK
3V3 ---[10k]---------------------> 7  HOLD#/RESET#
3V3          --------------------- 8  VCC
```

**Segurança:** desligue a alimentação para alterar conexões; use fios curtos, referência de GND comum e somente 3,3 V nos GPIOs e na flash. Não conecte dois dispositivos dirigindo a linha MISO simultaneamente.

## Metodologia dos testes

### 1. Preparação da flash

A memória continha previamente um padrão pseudoaleatório **determinístico**, escrito em todos os 16 MiB durante os ensaios históricos. O benchmark da Etapa 200 **somente lê**; não grava nem apaga a flash.

O valor esperado para cada endereço é calculado pelo firmware com a transformação:

```c
static uint32_t prng(uint32_t x) {
    x ^= x >> 16;
    x *= 0x7FEB352Du;
    x ^= x >> 15;
    x *= 0x846CA68Bu;
    x ^= x >> 16;
    return x;
}
static inline uint8_t expected(uint32_t addr) {
    return (uint8_t)prng(addr + 0x19720210u);
}
```

Para reproduzir a verificação integral, a memória testada precisa conter **esse mesmo padrão no endereço correspondente**. Uma flash diferente, ainda que responda ao JEDEC, pode produzir erros de verificação sem que haja falha elétrica no SPI.

### 2. Inicialização e identificação

1. Configurar GP2/GP3/GP4 para a função periférica SPI0, e GP5 como CS# via GPIO.
2. Inicializar SPI0 a 1 MHz e dois canais de DMA: `DREQ_SPI0_RX` e `DREQ_SPI0_TX`.
3. Ler a identificação JEDEC com o comando `0x9F`; exigir `C22018`.
4. Solicitar 32 MHz com `spi_set_baudrate(spi0, 32000000)` e registrar os **31.250.000 Hz** retornados pelo SDK.

O valor de frequência é derivado da configuração do periférico, **não de uma medição independente com osciloscópio**.

### 3. Transferência DMA

O ensaio usa o comando `0x0B` (**FAST READ**):

```text
CS# baixo
0x0B | endereço 24 bits | 1 byte dummy
Leitura contínua de 16 MiB
CS# alto
```

O CS# permanece ativo na leitura contínua. O buffer de recepção possui **4.096 bytes** e é reutilizado ao longo dos 16 MiB. O DMA RX transfere do registrador `SPI0 DR` para o buffer, enquanto o DMA TX envia repetidamente `0xFF` para gerar os pulsos de relógio necessários.

### 4. Duas modalidades

**Modo 0 (desempenho):** transfere 16 MiB com processamento mínimo dos dados. Mede principalmente a vazão da leitura SPI + DMA.

**Modo 1 (integridade):** repete a leitura dos 16 MiB e compara **cada byte** ao valor pseudoaleatório esperado. A duração inclui o custo do processamento de verificação feito pelo RP2040.

Os tempos vêm de `time_us_64()` no firmware e incluem o trabalho delimitado pela função de benchmark. Os valores podem variar conforme montagem, SDK, compilador e condições elétricas.

### 5. Critérios de validação usados

- JEDEC `C22018` e clock informado `31250000`.
- Duas transferências completas de **16 MiB**.
- Modo 1 com `ERRORS=0` e `FIRST=FFFFFFFF`.
- Resultado final `TEST_END RESULT=PASS TOTAL_ERRORS=0`.

## Como compilar e executar

A implementação original da **Etapa 200** usa **Pico SDK**, CMake, compilador ARM para RP2040 e bibliotecas `pico_stdlib`, `hardware_spi` e `hardware_dma`.

Quando os arquivos `main.c` e `CMakeLists.txt` da Etapa 200 estiverem publicados em `firmware/etapa200-original/`, a compilação será:

```bash
export PICO_SDK_PATH="$HOME/pico-sdk"
cmake -S firmware/etapa200-original -B build -DPICO_BOARD=pico -DPICO_PLATFORM=rp2040
cmake --build build -j2
```

O firmware expõe uma porta serial USB CDC. Após instalá-lo no Pico, os comandos de controle são:

```text
PING
START
```

`PING` responde `PONG`; `START` inicia o benchmark. A comunicação USB é usada para controle e registro dos resultados, não para transferir os 16 MiB ao computador.

## Escopo e limitações

- Este experimento valida o Pico como **mestre SPI**, não como slave nem como emulador de memória.
- A etapa de 5,107 s **não** equivale a uma verificação integral de dados; esta ocorre no modo 1.
- O teste de 31,25 MHz usa **SPI0 nativo**, diferentemente dos experimentos posteriores com PIO.
- Os números são medições desta montagem, não uma classificação universal de desempenho do RP2040.
- O conteúdo da memória externa é requisito para reproduzir a validação byte a byte.

## Origem e preservação

Projeto experimental de **José Onildo Sousa**, com testes históricos das Etapas 199 e 200 realizados em 10/10/2026 e reprodução da Etapa 200 em **11/10/2026**. O objetivo é preservar os fontes originais, scripts, logs e hashes SHA-256 do ensaio comprovado.

Repositório: https://github.com/joseonildo/pico-spi-dma-31mhz
