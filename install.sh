#!/bin/bash
# vix installer for macOS and Linux
# Usage: curl -fsSL https://vix.codes/install.sh | bash

set -e

INSTALL_DIR="$HOME/.vix/bin"
CONFIG_DIR="$HOME/.vix"
REPO="taehojo/vix-releases"

# Colors
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

echo ""
echo -e "  ${C}vix - AI Coding Agent${N}"
echo -e "  ${C}=====================${N}"
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

CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

# Detect GPU + VRAM
GPU_NAME="none"
VRAM_GB=0
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  VRAM_GB=$((VRAM_MB / 1024))
elif [ "$PLATFORM" = "macos" ]; then
  # Apple Silicon: unified memory, use 60% of RAM as effective VRAM
  if [ "$ARCH" = "arm64" ]; then
    GPU_NAME="Apple Silicon (unified)"
    VRAM_GB=$((RAM_GB * 60 / 100))
  fi
fi

echo -e "  ${Y}Detected system:${N}"
echo "    OS:    $PLATFORM $ARCH"
echo "    RAM:   ${RAM_GB}GB"
echo "    CPU:   ${CORES} cores"
echo "    GPU:   ${GPU_NAME} (${VRAM_GB}GB VRAM)"
echo ""

# === Recommend model ===
if [ "$VRAM_GB" -ge 80 ]; then
  MODEL="qwen2.5:72b"; MODEL_NAME="Qwen 2.5 72B"; MODEL_SIZE="47GB"; TIER="gpu-ultra"
elif [ "$VRAM_GB" -ge 48 ]; then
  MODEL="qwen2.5-coder:32b"; MODEL_NAME="Qwen 2.5 Coder 32B"; MODEL_SIZE="20GB"; TIER="gpu-xlarge"
elif [ "$VRAM_GB" -ge 24 ]; then
  MODEL="qwen2.5-coder:32b"; MODEL_NAME="Qwen 2.5 Coder 32B"; MODEL_SIZE="20GB"; TIER="gpu-large"
elif [ "$VRAM_GB" -ge 12 ]; then
  MODEL="deepseek-coder-v2:16b"; MODEL_NAME="DeepSeek Coder V2 16B"; MODEL_SIZE="9GB"; TIER="gpu-medium"
elif [ "$VRAM_GB" -ge 6 ]; then
  MODEL="qwen2.5-coder:7b"; MODEL_NAME="Qwen 2.5 Coder 7B"; MODEL_SIZE="4.7GB"; TIER="gpu-small"
elif [ "$RAM_GB" -ge 16 ]; then
  MODEL="gemma3:4b"; MODEL_NAME="Gemma 3 4B"; MODEL_SIZE="3.3GB"; TIER="medium"
elif [ "$RAM_GB" -ge 8 ]; then
  MODEL="gemma3:1b"; MODEL_NAME="Gemma 3 1B"; MODEL_SIZE="815MB"; TIER="small"
else
  MODEL="llama3.2:1b"; MODEL_NAME="Llama 3.2 1B"; MODEL_SIZE="1.3GB"; TIER="minimal"
fi

echo -e "  ${Y}Recommended model:${N}"
echo -e "    ${G}${MODEL_NAME}${N} (${MODEL_SIZE})"
echo "    Tier: $TIER"
echo "    Runs locally - free, unlimited, offline"
echo ""

# Ask for confirmation
if [ -t 0 ]; then
  read -p "  Install now? [Y/n] " confirm
elif [ -r /dev/tty ]; then
  read -p "  Install now? [Y/n] " confirm < /dev/tty
else
  confirm="y"
fi

case "$confirm" in
  n|N|no|No) echo "  Cancelled."; exit 0 ;;
esac

echo ""

# === Progress helpers ===
step() { echo -e "  ${C}[$1/$2]${N} $3"; }

# === Step 1: Download vix binary ===
TARGET="vix-${PLATFORM}-${ARCH}"
VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
if [ -z "$VERSION" ]; then
  echo "  Error: Could not fetch version info"
  exit 1
fi

step "1" "3" "Downloading vix ${VERSION}..."
mkdir -p "$INSTALL_DIR"
curl -# -fL "https://github.com/${REPO}/releases/download/${VERSION}/${TARGET}" -o "${INSTALL_DIR}/vix"
chmod +x "${INSTALL_DIR}/vix"

# === Step 2: Install Ollama ===
if ! command -v ollama >/dev/null 2>&1; then
  step "2" "3" "Installing Ollama (this may take 1-2 minutes)..."
  if [ "$PLATFORM" = "macos" ]; then
    # macOS: download .dmg/.zip
    curl -# -fL "https://ollama.com/download/Ollama-darwin.zip" -o /tmp/ollama.zip
    unzip -q /tmp/ollama.zip -d /Applications/
    rm /tmp/ollama.zip
    export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
  else
    # Linux: use their install script
    curl -fsSL https://ollama.com/install.sh | sh 2>&1 | grep -E "Downloading|Installing|complete" || true
  fi
else
  step "2" "3" "Ollama already installed."
fi

# Start Ollama
if ! pgrep -x ollama >/dev/null 2>&1; then
  nohup ollama serve >/dev/null 2>&1 &
  sleep 3
fi

# === Step 3: Pull model ===
step "3" "3" "Downloading ${MODEL_NAME} (${MODEL_SIZE}) — ollama will show progress"
echo ""
ollama pull "$MODEL"
echo ""

# === Save config ===
mkdir -p "$CONFIG_DIR"
cat > "${CONFIG_DIR}/config.json" << EOF
{
  "default_model": "${MODEL}",
  "tier": "${TIER}",
  "detected": {
    "ram_gb": ${RAM_GB},
    "vram_gb": ${VRAM_GB},
    "cores": ${CORES},
    "gpu": "${GPU_NAME}"
  }
}
EOF

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
echo -e "  ${G}vix installed successfully!${N}"
echo ""
echo -e "  Default model: ${C}${MODEL_NAME}${N} (local, free, unlimited)"
echo "  Run 'vix' anytime to start."
echo ""
echo -e "  ${C}Starting vix now...${N}"
echo ""
exec "${INSTALL_DIR}/vix"
