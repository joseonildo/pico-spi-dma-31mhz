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
