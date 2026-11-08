#!/usr/bin/env bash
set -e

# 1. Check if zig is in PATH
if command -v zig >/dev/null 2>&1; then
    exec zig "$@"
fi

# 2. Check if locally installed in .zig/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOCAL_ZIG="$(find "${ROOT_DIR}/.zig" -name "zig" -type f 2>/dev/null | head -n 1 || true)"
if [ -n "${LOCAL_ZIG}" ] && [ -x "${LOCAL_ZIG}" ]; then
    exec "${LOCAL_ZIG}" "$@"
fi

# 3. Auto-download Zig 0.17.1
echo "======================================================================"
echo "[Zig Bootstrap] 'zig' not found in PATH or ${ROOT_DIR}/.zig"
OS="$(uname -s)"
ARCH="$(uname -m)"
ZIG_VERSION="0.17.1"
echo "[Zig Bootstrap] Detected ${OS} (${ARCH})"
echo "======================================================================"

mkdir -p "${ROOT_DIR}/.zig"

case "${OS}" in
    Darwin)
        case "${ARCH}" in
            arm64|aarch64) TARBALL="zig-aarch64-macos-${ZIG_VERSION}.tar.xz" ;;
            x86_64)       TARBALL="zig-x86_64-macos-${ZIG_VERSION}.tar.xz" ;;
            *) echo "[Zig Bootstrap] Unsupported architecture: ${ARCH}"; exit 1 ;;
        esac
        ;;
    Linux)
        case "${ARCH}" in
            x86_64)       TARBALL="zig-x86_64-linux-${ZIG_VERSION}.tar.xz" ;;
            aarch64)      TARBALL="zig-aarch64-linux-${ZIG_VERSION}.tar.xz" ;;
            armv7*)       TARBALL="zig-arm-linux-${ZIG_VERSION}.tar.xz" ;;
            *) echo "[Zig Bootstrap] Unsupported architecture: ${ARCH}"; exit 1 ;;
        esac
        ;;
    *)
        echo "[Zig Bootstrap] Unsupported OS: ${OS}"; exit 1 ;;
esac

URL="https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
echo "[Zig Bootstrap] Downloading Zig ${ZIG_VERSION} (live progress):"
curl -# -fSL "${URL}" -o "${ROOT_DIR}/.zig/${TARBALL}"
echo ""
echo "[Zig Bootstrap] Extracting archive..."
tar -xf "${ROOT_DIR}/.zig/${TARBALL}" -C "${ROOT_DIR}/.zig"
rm -f "${ROOT_DIR}/.zig/${TARBALL}"

LOCAL_ZIG="$(find "${ROOT_DIR}/.zig" -name "zig" -type f 2>/dev/null | head -n 1)"
chmod +x "${LOCAL_ZIG}"
echo "[Zig Bootstrap] Extraction complete."
echo "[Zig Bootstrap] Zig ${ZIG_VERSION} ready at: ${LOCAL_ZIG}"
echo "======================================================================"
exec "${LOCAL_ZIG}" "$@"
