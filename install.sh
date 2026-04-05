#!/bin/bash
# vix installer for macOS and Linux
# Usage: curl -fsSL https://vix.codes/install.sh | bash

set -e

INSTALL_DIR="$HOME/.vix/bin"
CONFIG_DIR="$HOME/.vix"
REPO="taehojo/vix-releases"

echo ""
echo "  vix - AI Coding Agent"
echo "  ====================="
echo ""

# === Detect system ===
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

# Detect RAM (in GB)
if [ "$PLATFORM" = "macos" ]; then
  RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  RAM_GB=$((RAM_BYTES / 1024 / 1024 / 1024))
else
  RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
  RAM_GB=$((RAM_KB / 1024 / 1024))
fi

# Detect CPU cores
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

echo "  Detected system:"
echo "    OS:    $PLATFORM $ARCH"
echo "    RAM:   ${RAM_GB}GB"
echo "    CPU:   ${CORES} cores"
echo ""

# === Recommend model based on RAM ===
if [ "$RAM_GB" -ge 16 ]; then
  MODEL="gemma3:4b"
  MODEL_NAME="Gemma 3 4B"
  MODEL_SIZE="3.3GB"
  MODEL_SHORTCUT="local-medium"
elif [ "$RAM_GB" -ge 8 ]; then
  MODEL="gemma3:1b"
  MODEL_NAME="Gemma 3 1B"
  MODEL_SIZE="815MB"
  MODEL_SHORTCUT="local"
else
  MODEL="llama3.2:1b"
  MODEL_NAME="Llama 3.2 1B"
  MODEL_SIZE="1.3GB"
  MODEL_SHORTCUT="local-small"
fi

echo "  Recommended model for your system:"
echo "    $MODEL_NAME (download size: $MODEL_SIZE)"
echo "    This runs locally on your CPU — free, unlimited, offline"
echo ""

# Ask for confirmation (skip if piped)
if [ -t 0 ]; then
  read -p "  Install now? [Y/n] " confirm
else
  # When piped (curl | bash), open /dev/tty for input
  if [ -t 1 ] && [ -r /dev/tty ]; then
    read -p "  Install now? [Y/n] " confirm < /dev/tty
  else
    confirm="y"
  fi
fi

case "$confirm" in
  n|N|no|No) echo "  Cancelled."; exit 0 ;;
esac

echo ""

# === Download vix binary ===
TARGET="vix-${PLATFORM}-${ARCH}"
VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
if [ -z "$VERSION" ]; then
  echo "  Error: Could not fetch version info"
  exit 1
fi
echo "  [1/3] Downloading vix ${VERSION}..."
mkdir -p "$INSTALL_DIR"
curl -fsSL "https://github.com/${REPO}/releases/download/${VERSION}/${TARGET}" -o "${INSTALL_DIR}/vix"
chmod +x "${INSTALL_DIR}/vix"
echo "        Done."

# === Install Ollama ===
if ! command -v ollama >/dev/null 2>&1; then
  echo "  [2/3] Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
  echo "        Done."
else
  echo "  [2/3] Ollama already installed."
fi

# Start Ollama if not running
if ! pgrep -x ollama >/dev/null 2>&1; then
  if [ "$PLATFORM" = "linux" ]; then
    nohup ollama serve >/dev/null 2>&1 &
    sleep 2
  fi
fi

# === Pull model ===
echo "  [3/3] Downloading ${MODEL_NAME}..."
ollama pull "$MODEL"
echo "        Done."

# === Save default model in config ===
mkdir -p "$CONFIG_DIR"
echo "{\"default_model\": \"${MODEL_SHORTCUT}\"}" > "${CONFIG_DIR}/config.json"

# === Add to PATH ===
SHELL_NAME=$(basename "$SHELL")
PROFILE=""
case "$SHELL_NAME" in
  bash) PROFILE="$HOME/.bashrc" ;;
  zsh)  PROFILE="$HOME/.zshrc" ;;
esac

if [ -n "$PROFILE" ] && ! grep -q ".vix/bin" "$PROFILE" 2>/dev/null; then
  echo "" >> "$PROFILE"
  echo '# vix' >> "$PROFILE"
  echo 'export PATH="$HOME/.vix/bin:$PATH"' >> "$PROFILE"
fi

export PATH="$INSTALL_DIR:$PATH"

echo ""
echo "  vix installed successfully!"
echo ""
echo "  Default model: ${MODEL_NAME} (local, free, unlimited)"
echo "  Run 'vix' anytime to start."
echo ""
echo "  Starting vix now..."
echo ""
exec "${INSTALL_DIR}/vix"
