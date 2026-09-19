#!/usr/bin/env bash
# install-cockroach.sh
# Downloads the cockroach CLI binary (v23.2.3) to ~/.local/bin/cockroach.
# This is the binary that darkroom_spec.lua uses to connect to the Docker
# CockroachDB container at 127.0.0.1:26257.
#
# Usage: ./scripts/install-cockroach.sh
set -euo pipefail

VERSION="23.2.3"
INSTALL_DIR="${HOME}/.local/bin"
BINARY="${INSTALL_DIR}/cockroach"

if command -v cockroach &>/dev/null; then
    FOUND=$(command -v cockroach)
    echo "[install-cockroach] cockroach already on PATH: ${FOUND}"
    cockroach version --short 2>/dev/null || true
    exit 0
fi

mkdir -p "${INSTALL_DIR}"

ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  ARCH_TAG="amd64" ;;
    aarch64) ARCH_TAG="arm64" ;;
    arm64)   ARCH_TAG="arm64" ;;
    *)
        echo "[install-cockroach] ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
if [ "${OS}" != "linux" ] && [ "${OS}" != "darwin" ]; then
    echo "[install-cockroach] ERROR: Unsupported OS: ${OS}" >&2
    exit 1
fi

TARBALL="cockroach-v${VERSION}.${OS}-${ARCH_TAG}.tgz"
URL="https://binaries.cockroachdb.com/${TARBALL}"

echo "[install-cockroach] Downloading cockroach v${VERSION} (${OS}/${ARCH_TAG})..."
TMP=$(mktemp -d)
trap "rm -rf ${TMP}" EXIT

curl -fsSL "${URL}" -o "${TMP}/${TARBALL}"
tar -xzf "${TMP}/${TARBALL}" -C "${TMP}"
cp "${TMP}/cockroach-v${VERSION}.${OS}-${ARCH_TAG}/cockroach" "${BINARY}"
chmod +x "${BINARY}"

echo "[install-cockroach] Installed: ${BINARY}"
echo "[install-cockroach] Version: $(${BINARY} version --short 2>/dev/null || echo 'ok')"
echo ""
echo "  Add to PATH if not already there:"
echo "    export PATH=\"\${HOME}/.local/bin:\${PATH}\""
