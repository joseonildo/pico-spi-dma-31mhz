#!/bin/bash
clear
set -euo pipefail

ORIG="$HOME/tc3102-pico-analisador"
REPO="$HOME/pico-spi-dma-31mhz"
FONTE="$ORIG/emulador-spi/testes/etapa200"
PROJ="$REPO/firmware/etapa200-original"
BUILD="$PROJ/build"
PICOTOOL="$ORIG/build/picotool-usb/picotool"
UF2="$BUILD/etapa200.uf2"
PORTA="/dev/ttyACM0"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$REPO/resultados/etapa200-validacao-$STAMP.log"

export PICO_SDK_PATH="${PICO_SDK_PATH:-$HOME/pico-sdk}"

echo "=========================================="
echo " PICO SPI0 + DMA — ETAPA 200 ORIGINAL"
echo " VALIDAÇÃO A 31,25 MHz"
echo "=========================================="
echo
echo "GP2 = SCK"
echo "GP3 = MOSI"
echo "GP4 = MISO"
echo "GP5 = CS#"
echo
echo "Flash: MX25L12835F — 16 MiB"
echo "JEDEC esperado: C22018"
echo "Leitura apenas; nenhuma escrita na flash."
echo

# Verificacoes antes de qualquer gravacao.

for ARQ in main.c CMakeLists.txt; do
    test -s "$FONTE/$ARQ" || {
        echo "ERRO: original ausente: $FONTE/$ARQ"
        exit 1
    }
done

test -x "$PICOTOOL" || {
    echo "ERRO: picotool nao encontrado."
    exit 1
}

command -v cmake >/dev/null
command -v sha256sum >/dev/null

python3 -c "import serial" || {
    echo "ERRO: modulo pyserial indisponivel."
    exit 1
}

mkdir -p "$PROJ" "$REPO/resultados" "$REPO/referencias"

echo "=== COPIANDO FONTES ORIGINAIS ==="

cp -p "$FONTE/main.c" "$PROJ/main.c"
cp -p "$FONTE/CMakeLists.txt" "$PROJ/CMakeLists.txt"

cmp "$FONTE/main.c" "$PROJ/main.c"
cmp "$FONTE/CMakeLists.txt" "$PROJ/CMakeLists.txt"

python3 - "$PROJ/main.c" <<'PY'
from pathlib import Path
import sys

s = Path(sys.argv[1]).read_text()

checks = {
    "Controlador SPI0": "spi_init(spi0, 1000000)",
    "DMA RX": "DREQ_SPI0_RX",
    "DMA TX": "DREQ_SPI0_TX",
    "Clock solicitado": "spi_set_baudrate(spi0, 32000000)",
    "Comando FAST READ": "0x0B",
    "Teste JEDEC": "JEDEC=%02X%02X%02X",
    "Verificacao integral": "expected(addr + i)",
    "GP2": "gpio_set_function(2, GPIO_FUNC_SPI)",
    "GP3": "gpio_set_function(3, GPIO_FUNC_SPI)",
    "GP4": "gpio_set_function(4, GPIO_FUNC_SPI)",
    "CS GP5": "#define CS 5",
}

for nome, marcador in checks.items():
    if marcador not in s:
        raise SystemExit(
            f"ERRO: firmware inesperado: {nome}"
        )
    print(f"CONFIRMADO: {nome}")

# Inspecao preventiva de operacoes de escrita
# na flash. As rotinas de leitura sao preservadas.
import re
sem_comentarios = re.sub(
    r'/\*.*?\*/|//[^\n]*',
    '',
    s,
    flags=re.S
)

if re.search(
    r'\b(?:spi_flash_program|flash_range_program|'
    r'flash_range_erase)\s*\(',
    sem_comentarios
):
    raise SystemExit(
        "ERRO: operacao de gravacao encontrada."
    )

print("CODIGO_ORIGINAL=INALTERADO")
PY

echo
echo "=== HASHES DOS FONTES ==="

sha256sum "$PROJ/main.c" "$PROJ/CMakeLists.txt"

echo
echo "=== COMPILANDO ==="

cmake -S "$PROJ" -B "$BUILD" \
    -DPICO_BOARD=pico \
    -DPICO_PLATFORM=rp2040 \
    -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD" -j "$(nproc)"

test -s "$UF2"

echo
echo "=== FIRMWARE GERADO ==="
ls -lh "$UF2"
sha256sum "$UF2"

echo
echo "=== ENTRANDO EM BOOTSEL ==="

sudo "$PICOTOOL" reboot -f -u || true

echo
echo "Aguardando BOOTSEL."
echo "Se a USB desconectar do WSL, no PowerShell:"
echo "  usbipd list"
echo "  usbipd attach --wsl --busid SEU_BUSID"
echo

SEG=0

until sudo "$PICOTOOL" info >/dev/null 2>&1; do
    sleep 2
    SEG=$((SEG+2))

    if (( SEG % 10 == 0 )); then
        echo "Aguardando Pico BOOTSEL: ${SEG}s"
    fi
done

echo
echo "=== GRAVANDO FIRMWARE ORIGINAL ==="

sudo "$PICOTOOL" load -v "$UF2"
sudo "$PICOTOOL" reboot

echo
echo "=== AGUARDANDO USB SERIAL ==="

SEG=0

while [ ! -e "$PORTA" ]; do
    sleep 2
    SEG=$((SEG+2))

    if (( SEG % 10 == 0 )); then
        echo "Aguardando $PORTA: ${SEG}s"
        echo "Se necessario, reconecte com usbipd."
    fi
done

echo
echo "=== EXECUTANDO BENCHMARK ORIGINAL ==="

cat > "$REPO/receber-etapa200.py" <<'PY'
import sys
import time
import re
from pathlib import Path

import serial

log = Path(sys.argv[1])
port = "/dev/ttyACM0"

print()
print("=== VALIDACAO ORIGINAL ETAPA 200 ===")
print("Aguardando comunicacao...")
print()

with serial.Serial(port, 115200, timeout=0.5) as ser:
    time.sleep(1)
    ser.reset_input_buffer()

    conectado = False

    for tentativa in range(20):
        ser.write(b"PING\n")
        ser.flush()

        fim = time.monotonic() + 1.0

        while time.monotonic() < fim:
            line = ser.readline().decode(
                "utf-8", errors="replace"
            ).strip()

            if line == "PONG":
                conectado = True
                break

        if conectado:
            break

    if not conectado:
        raise SystemExit(
            "ERRO: Pico nao respondeu ao PING."
        )

    resultados = []
    terminou = False
    linhas = []
    ultimo = time.monotonic()

    ser.write(b"START\n")
    ser.flush()

    with log.open("w", buffering=1) as arq:
        arq.write("PONG\n")
        print("PONG")

        while time.monotonic() - ultimo < 120:
            line = ser.readline().decode(
                "utf-8", errors="replace"
            ).strip()

            if not line:
                continue

            ultimo = time.monotonic()
            arq.write(line + "\n")
            linhas.append(line)

            if line.startswith("PROGRESS MIB="):
                m = re.search(r"MIB=(\d+)/16", line)

                if m:
                    n = int(m.group(1))
                    print(
                        f"\r[{'#'*n}{'-'*(16-n)}] "
                        f"{100*n/16:5.1f}%",
                        end="",
                        flush=True
                    )
                continue

            if line.startswith("BENCH_END"):
                resultados.append(line)
                print()

            print(line, flush=True)

            if line.startswith("TEST_END"):
                terminou = True
                break

print()
print("=== COMPARACAO ===")

referencias = {
    0: 5.107000,
    1: 9.938644,
}

sucesso = terminou and len(resultados) == 2

for line in resultados:
    m = re.search(
        r'MODE=(\d+).*?US=(\d+).*?ERRORS=(\d+)',
        line
    )

    if not m:
        sucesso = False
        continue

    modo = int(m.group(1))
    segundos = int(m.group(2)) / 1_000_000
    erros = int(m.group(3))

    anterior = referencias.get(modo)

    print(
        f"MODO={modo} "
        f"TEMPO_ATUAL={segundos:.6f}s "
        f"TEMPO_ORIGINAL={anterior}s "
        f"ERROS_REPORTADOS={erros}"
    )

    if modo == 1 and erros != 0:
        sucesso = False

if "JEDEC=C22018" not in linhas:
    sucesso = False

if "SPI_HZ=31250000" not in linhas:
    sucesso = False

if "TEST_END RESULT=PASS TOTAL_ERRORS=0" not in linhas:
    sucesso = False

print()
print(
    "VALIDACAO=" +
    ("APROVADA" if sucesso else "REPROVADA")
)
print("LOG=" + str(log))

if not sucesso:
    raise SystemExit(1)
PY

if python3 "$REPO/receber-etapa200.py" "$LOG"; then

    echo
    echo "=== PRESERVANDO VALIDACAO APROVADA ==="

    (
        cd "$REPO"

        sha256sum \
            firmware/etapa200-original/main.c \
            firmware/etapa200-original/CMakeLists.txt \
            firmware/etapa200-original/build/etapa200.uf2 \
            > referencias/SHA256-etapa200-validada.txt
    )

    echo "FONTES=ORIGINAIS"
    echo "BENCHMARK=APROVADO"
    echo "GITHUB=A_PUBLICAR_POSTERIORMENTE"

else
    echo
    echo "VALIDACAO=NAO_APROVADA"
    echo "Consulte o log antes de prosseguir."
    exit 1
fi

echo
echo "=== CONCLUIDO ==="
