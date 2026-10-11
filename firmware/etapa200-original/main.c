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
