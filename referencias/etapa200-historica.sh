#!/bin/bash
clear
set -euo pipefail

export PICO_SDK_PATH="$HOME/pico-sdk"

BASE="$HOME/tc3102-pico-analisador"
DIR="$BASE/emulador-spi/testes/etapa200"
BUILD="$DIR/build"
PICOTOOL="$BASE/build/picotool-usb/picotool"
STAMP="$(date +%Y%m%d-%H%M%S)"
REL="$BASE/emulador-spi/relatorios/etapa200-$STAMP.log"

mkdir -p "$DIR" "$(dirname "$REL")"

cat > "$DIR/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.13)
include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(etapa200 C CXX ASM)
pico_sdk_init()

add_executable(etapa200 main.c)

target_link_libraries(etapa200
    pico_stdlib
    hardware_spi
    hardware_dma
)

pico_enable_stdio_usb(etapa200 1)
pico_enable_stdio_uart(etapa200 0)
pico_add_extra_outputs(etapa200)
CMAKE

cat > "$DIR/main.c" <<'C'
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "pico/stdlib.h"
#include "hardware/spi.h"
#include "hardware/dma.h"

#define CS 5
#define FLASH_SIZE (16u * 1024u * 1024u)
#define CHUNK 4096u

static uint8_t buffer[CHUNK];
static uint8_t dummy = 0xFF;
static int rx_dma;
static int tx_dma;
static dma_channel_config rx_cfg;
static dma_channel_config tx_cfg;

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

static void select_flash(void) {
    gpio_put(CS, 0);
}

static void release_flash(void) {
    gpio_put(CS, 1);
}

static void read_jedec(uint8_t id[3]) {
    uint8_t cmd = 0x9F;
    select_flash();
    spi_write_blocking(spi0, &cmd, 1);
    spi_read_blocking(spi0, 0xFF, id, 3);
    release_flash();
}

static void start_fast_read(void) {
    uint8_t cmd[5] = {0x0B, 0, 0, 0, 0};
    select_flash();
    spi_write_blocking(spi0, cmd, 5);
}

static void init_dma(void) {
    rx_dma = dma_claim_unused_channel(true);
    tx_dma = dma_claim_unused_channel(true);

    rx_cfg = dma_channel_get_default_config(rx_dma);
    channel_config_set_transfer_data_size(
        &rx_cfg, DMA_SIZE_8
    );
    channel_config_set_read_increment(&rx_cfg, false);
    channel_config_set_write_increment(&rx_cfg, true);
    channel_config_set_dreq(&rx_cfg, DREQ_SPI0_RX);

    tx_cfg = dma_channel_get_default_config(tx_dma);
    channel_config_set_transfer_data_size(
        &tx_cfg, DMA_SIZE_8
    );
    channel_config_set_read_increment(&tx_cfg, false);
    channel_config_set_write_increment(&tx_cfg, false);
    channel_config_set_dreq(&tx_cfg, DREQ_SPI0_TX);
}

static void dma_read_chunk(uint32_t count) {
    dma_channel_configure(
        rx_dma, &rx_cfg,
        buffer,
        &spi_get_hw(spi0)->dr,
        count,
        false
    );

    dma_channel_configure(
        tx_dma, &tx_cfg,
        &spi_get_hw(spi0)->dr,
        &dummy,
        count,
        false
    );

    dma_start_channel_mask(
        (1u << rx_dma) | (1u << tx_dma)
    );

    dma_channel_wait_for_finish_blocking(rx_dma);
    dma_channel_wait_for_finish_blocking(tx_dma);
}

static uint32_t benchmark(bool verify) {
    uint32_t errors = 0;
    uint32_t first = 0xFFFFFFFFu;
    uint32_t checksum = 0;

    printf("BENCH_BEGIN MODE=%u\n", verify ? 1 : 0);
    fflush(stdout);

    uint64_t start = time_us_64();

    start_fast_read();

    for (uint32_t addr = 0;
         addr < FLASH_SIZE;
         addr += CHUNK) {

        dma_read_chunk(CHUNK);

        if (verify) {
            for (uint32_t i = 0; i < CHUNK; i++) {
                if (buffer[i] != expected(addr + i)) {
                    errors++;
                    if (first == 0xFFFFFFFFu)
                        first = addr + i;
                }
            }
        } else {
            checksum ^= buffer[0];
            checksum ^= buffer[CHUNK - 1];
        }

        if (((addr + CHUNK) % (1024u * 1024u)) == 0) {
            uint32_t mib =
                (addr + CHUNK) / (1024u * 1024u);

            printf("PROGRESS MIB=%lu/16\n",
                   (unsigned long)mib);
            fflush(stdout);
        }
    }

    release_flash();

    uint64_t elapsed = time_us_64() - start;

    uint32_t kib_s = elapsed
        ? (uint32_t)(
            (uint64_t)FLASH_SIZE * 1000000ull /
            elapsed / 1024u
          )
        : 0;

    printf(
        "BENCH_END MODE=%u US=%llu KIB_S=%lu "
        "ERRORS=%lu FIRST=%08lX CHECK=%lu\n",
        verify ? 1 : 0,
        (unsigned long long)elapsed,
        (unsigned long)kib_s,
        (unsigned long)errors,
        (unsigned long)first,
        (unsigned long)checksum
    );
    fflush(stdout);

    return errors;
}

static void run_test(void) {
    uint8_t id[3];

    spi_set_baudrate(spi0, 1000000);
    read_jedec(id);

    printf("JEDEC=%02X%02X%02X\n",
           id[0], id[1], id[2]);

    if (id[0] != 0xC2 ||
        id[1] != 0x20 ||
        id[2] != 0x18) {
        printf("TEST_END RESULT=FAIL_JEDEC\n");
        fflush(stdout);
        return;
    }

    uint32_t hz = spi_set_baudrate(spi0, 32000000);
    printf("SPI_HZ=%lu\n", (unsigned long)hz);

    uint32_t errors = 0;

    benchmark(false);
    errors += benchmark(true);

    printf(
        "TEST_END RESULT=%s TOTAL_ERRORS=%lu\n",
        errors == 0 ? "PASS" : "FAIL",
        (unsigned long)errors
    );
    fflush(stdout);
}

int main(void) {
    stdio_init_all();

    gpio_init(CS);
    gpio_set_dir(CS, GPIO_OUT);
    release_flash();

    spi_init(spi0, 1000000);
    gpio_set_function(2, GPIO_FUNC_SPI);
    gpio_set_function(3, GPIO_FUNC_SPI);
    gpio_set_function(4, GPIO_FUNC_SPI);

    init_dma();

    char cmd[32];
    unsigned pos = 0;

    while (true) {
        int c = getchar_timeout_us(10000);

        if (c == PICO_ERROR_TIMEOUT)
            continue;

        if (c == '\r' || c == '\n') {
            cmd[pos] = 0;

            if (!strcmp(cmd, "PING")) {
                printf("PONG\n");
            } else if (!strcmp(cmd, "START")) {
                printf("START_OK\n");
                fflush(stdout);
                run_test();
            }

            fflush(stdout);
            pos = 0;
        } else if (pos < sizeof(cmd) - 1) {
            cmd[pos++] = (char)c;
        } else {
            pos = 0;
        }
    }
}
C

echo "=== ETAPA 200: COMPILANDO ==="

cmake -S "$DIR" -B "$BUILD" \
    -DPICO_BOARD=pico \
    -DPICO_PLATFORM=rp2040

cmake --build "$BUILD" -j2

UF2="$BUILD/etapa200.uf2"
test -s "$UF2"

echo
echo "=== GRAVANDO PICO ==="

sudo "$PICOTOOL" reboot -f -u || true

OK=0

for i in $(seq 1 40); do
    if sudo "$PICOTOOL" info >/dev/null 2>&1; then
        OK=1
        break
    fi
    sleep 0.5
done

[ "$OK" -eq 1 ] || {
    echo "ERRO: Pico nao entrou em BOOTSEL."
    exit 1
}

sudo "$PICOTOOL" load -v "$UF2"
sudo "$PICOTOOL" reboot

echo
echo "=== BENCHMARK DMA ==="

python3 - "$REL" <<'PY'
import os
import sys
import time
import select
import termios
import re

arquivo = sys.argv[1]
porta = "/dev/ttyACM0"

limite = time.monotonic() + 30

while not os.path.exists(porta):
    if time.monotonic() > limite:
        raise SystemExit("ERRO: USB CDC nao apareceu.")
    time.sleep(0.1)

fd = os.open(
    porta,
    os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK
)

attrs = termios.tcgetattr(fd)
attrs[0] = 0
attrs[1] = 0
attrs[3] = 0
attrs[6][termios.VMIN] = 0
attrs[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, attrs)

linhas = []
buffer = ""
terminou = False
ultimo = time.monotonic()

with open(arquivo, "w", buffering=1) as log:

    def registrar(linha):
        global terminou, ultimo

        ultimo = time.monotonic()
        log.write(linha + "\n")

        if linha.startswith("PROGRESS"):
            m = re.search(r"MIB=(\d+)/16", linha)
            if m:
                n = int(m.group(1))
                print(
                    f"\r[{'#'*n}{'-'*(16-n)}] "
                    f"{n*100/16:5.1f}%",
                    end="",
                    flush=True
                )
        else:
            if linha.startswith("BENCH_END"):
                print()
                linhas.append(linha)

            print(linha, flush=True)

        if linha.startswith("TEST_END"):
            terminou = True

    try:
        conectado = False

        for _ in range(15):
            os.write(fd, b"PING\n")
            time.sleep(0.2)

            pronto, _, _ = select.select([fd], [], [], 0.5)

            if pronto:
                dados = os.read(fd, 4096)
                if b"PONG" in dados:
                    conectado = True
                    registrar("PONG")
                    break

        if not conectado:
            raise RuntimeError("Pico nao respondeu ao PING.")

        os.write(fd, b"START\n")

        while not terminou:
            pronto, _, _ = select.select([fd], [], [], 0.2)

            if pronto:
                try:
                    dados = os.read(fd, 65536)
                except BlockingIOError:
                    continue

                if dados:
                    buffer += dados.decode(errors="replace")

                    while "\n" in buffer:
                        linha, buffer = buffer.split("\n", 1)
                        linha = linha.strip()

                        if linha:
                            registrar(linha)

            if time.monotonic() - ultimo > 120:
                print("\nERRO: 120s sem resposta.")
                break

    finally:
        os.close(fd)

print("\n=== COMPARACAO FINAL ===")
print("Etapa 199, SPI puro: 6.046190 s")
print("Etapa 199, verificado: 11.280484 s")

for linha in linhas:
    print("Etapa 200:", linha)

print("\nRelatorio:", arquivo)

if not terminou or len(linhas) != 2:
    raise SystemExit("ERRO: benchmark incompleto.")
PY

echo
echo "=== ETAPA 200 FINALIZADA ==="
