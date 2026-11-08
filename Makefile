# Makefile for BeagleBone Black FreeRTOS Zig Project

ifeq ($(OS),Windows_NT)
    ZIG := cmd.exe /c "tools\run_zig.bat"
else
    ZIG := ./tools/run_zig.sh
endif

.PHONY: all clean test flash

all:
	$(ZIG) build

clean:
	$(ZIG) build clean

test:
	$(ZIG) build test --summary all
