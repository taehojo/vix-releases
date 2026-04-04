#!/bin/bash
# vix installer for macOS and Linux
# Usage: curl -fsSL https://vix.codes/install.sh | bash

set -e

INSTALL_DIR="$HOME/.vix/bin"
REPO="taehojo/vix-releases"

echo ""
echo "  vix - AI Coding Agent"
echo "  ====================="
echo ""

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
  linux)  PLATFORM="linux" ;;
  darwin) PLATFORM="macos" ;;
  *)      echo "Error: Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH="x64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *)             echo "Error: Unsupported architecture: $ARCH"; exit 1 ;;
esac

TARGET="vix-${PLATFORM}-${ARCH}"
echo "  Detected: ${PLATFORM} ${ARCH}"

VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
if [ -z "$VERSION" ]; then
  echo "Error: Could not fetch version info"
  exit 1
fi
echo "  Version:  ${VERSION}"

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${TARGET}"
echo "  Downloading..."

mkdir -p "$INSTALL_DIR"
curl -fsSL "$DOWNLOAD_URL" -o "${INSTALL_DIR}/vix"
chmod +x "${INSTALL_DIR}/vix"

SHELL_NAME=$(basename "$SHELL")
PROFILE=""
case "$SHELL_NAME" in
  bash) PROFILE="$HOME/.bashrc" ;;
  zsh)  PROFILE="$HOME/.zshrc" ;;
esac

if [ -n "$PROFILE" ]; then
  if ! grep -q ".vix/bin" "$PROFILE" 2>/dev/null; then
    echo "" >> "$PROFILE"
    echo '# vix' >> "$PROFILE"
    echo 'export PATH="$HOME/.vix/bin:$PATH"' >> "$PROFILE"
    echo "  Added to PATH in $PROFILE"
  fi
fi

echo ""
echo "  Done! vix ${VERSION} installed."
echo ""
echo "  Next steps:"
echo "    1. Restart terminal (or: source $PROFILE)"
echo "    2. Get free API key: https://aistudio.google.com/app/apikey"
echo "    3. export GOOGLE_API_KEY=your-key"
echo "    4. vix --model gemma"
echo ""
