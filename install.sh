#!/bin/bash
# vix installer for macOS and Linux
# Usage: curl -fsSL https://vix.codes/install.sh | bash

set -e

INSTALL_DIR="$HOME/.vix/bin"
CONFIG_DIR="$HOME/.vix"
REPO="taehojo/vix-releases"

G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

# Use /dev/tty for input when piped
read_input() {
  if [ -r /dev/tty ]; then
    read -p "$1" $2 < /dev/tty
  else
    read -p "$1" $2
  fi
}

echo ""
echo -e "  ${C}vix - AI Coding Agent${N}"
echo -e "  ${C}=====================${N}"
echo ""

# === Detect platform ===
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS" in
  linux)  PLATFORM="linux" ;;
  darwin) PLATFORM="macos" ;;
  *)      echo "Unsupported OS: $OS"; exit 1 ;;
esac
case "$ARCH" in
  x86_64|amd64) ARCH="x64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *)             echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# === Choose installation mode ===
echo -e "  ${Y}Choose how to use vix:${N}"
echo ""
echo -e "    ${G}1)${N} Local LLM — free, unlimited, offline (recommended)"
echo -e "    ${G}2)${N} Cloud API — choose your own model (OpenAI, Claude, Gemma, etc.)"
echo ""
read_input "  Select [1/2]: " mode
echo ""

if [ -z "$mode" ]; then mode="1"; fi

# === Install vix binary first (common to both modes) ===
install_vix_binary() {
  TARGET="vix-${PLATFORM}-${ARCH}"
  VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
  if [ -z "$VERSION" ]; then
    echo "  Error: Could not fetch version"
    exit 1
  fi
  echo -e "  ${C}[*]${N} Downloading vix ${VERSION}..."
  mkdir -p "$INSTALL_DIR"
  curl -# -fL "https://github.com/${REPO}/releases/download/${VERSION}/${TARGET}" -o "${INSTALL_DIR}/vix"
  chmod +x "${INSTALL_DIR}/vix"
}

setup_path() {
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
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "${CONFIG_DIR}/config.json" << EOF
{
  "default_model": "$1",
  "mode": "$2"
}
EOF
}

save_env_var() {
  # $1 = var name, $2 = value
  SHELL_NAME=$(basename "$SHELL")
  PROFILE=""
  case "$SHELL_NAME" in
    bash) PROFILE="$HOME/.bashrc" ;;
    zsh)  PROFILE="$HOME/.zshrc" ;;
  esac
  if [ -n "$PROFILE" ]; then
    # Remove old entry if exists
    grep -v "^export $1=" "$PROFILE" > "${PROFILE}.tmp" 2>/dev/null && mv "${PROFILE}.tmp" "$PROFILE" || true
    echo "export $1=\"$2\"" >> "$PROFILE"
  fi
  export "$1=$2"
}

# ==============================================================
# MODE 1: LOCAL LLM
# ==============================================================
if [ "$mode" = "1" ]; then
  # Detect RAM
  if [ "$PLATFORM" = "macos" ]; then
    RAM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
  else
    RAM_GB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0) / 1024 / 1024 ))
  fi
  CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

  # Detect GPU
  GPU_NAME="none"
  VRAM_GB=0
  if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    VRAM_GB=$((VRAM_MB / 1024))
  elif [ "$PLATFORM" = "macos" ] && [ "$ARCH" = "arm64" ]; then
    GPU_NAME="Apple Silicon (unified)"
    VRAM_GB=$((RAM_GB * 60 / 100))
  fi

  echo -e "  ${Y}Detected system:${N}"
  echo "    RAM:   ${RAM_GB}GB"
  echo "    CPU:   ${CORES} cores"
  echo "    GPU:   ${GPU_NAME} (${VRAM_GB}GB VRAM)"
  echo ""

  # Recommend model
  if [ "$VRAM_GB" -ge 80 ]; then
    MODEL="qwen2.5:72b"; MODEL_NAME="Qwen 2.5 72B"; MODEL_SIZE="47GB"
  elif [ "$VRAM_GB" -ge 24 ]; then
    MODEL="qwen2.5-coder:32b"; MODEL_NAME="Qwen 2.5 Coder 32B"; MODEL_SIZE="20GB"
  elif [ "$VRAM_GB" -ge 12 ]; then
    MODEL="deepseek-coder-v2:16b"; MODEL_NAME="DeepSeek Coder V2 16B"; MODEL_SIZE="9GB"
  elif [ "$VRAM_GB" -ge 8 ]; then
    MODEL="qwen2.5-coder:7b"; MODEL_NAME="Qwen 2.5 Coder 7B"; MODEL_SIZE="4.7GB"
  elif [ "$VRAM_GB" -ge 5 ]; then
    MODEL="qwen2.5-coder:3b"; MODEL_NAME="Qwen 2.5 Coder 3B"; MODEL_SIZE="1.9GB"
  elif [ "$VRAM_GB" -ge 4 ]; then
    MODEL="qwen2.5-coder:1.5b"; MODEL_NAME="Qwen 2.5 Coder 1.5B"; MODEL_SIZE="986MB"
  elif [ "$RAM_GB" -ge 16 ]; then
    MODEL="gemma3:4b"; MODEL_NAME="Gemma 3 4B"; MODEL_SIZE="3.3GB"
  elif [ "$RAM_GB" -ge 8 ]; then
    MODEL="gemma3:1b"; MODEL_NAME="Gemma 3 1B"; MODEL_SIZE="815MB"
  else
    MODEL="llama3.2:1b"; MODEL_NAME="Llama 3.2 1B"; MODEL_SIZE="1.3GB"
  fi

  echo -e "  ${Y}Recommended model:${N} ${G}${MODEL_NAME}${N} (${MODEL_SIZE})"
  echo ""
  read_input "  Install now? [Y/n]: " confirm
  case "$confirm" in n|N) echo "  Cancelled."; exit 0 ;; esac
  echo ""

  echo -e "  ${C}[1/3]${N} Downloading vix..."
  install_vix_binary

  if ! command -v ollama >/dev/null 2>&1; then
    echo -e "  ${C}[2/3]${N} Installing Ollama (1-2 minutes)..."
    if [ "$PLATFORM" = "macos" ]; then
      curl -# -fL "https://ollama.com/download/Ollama-darwin.zip" -o /tmp/ollama.zip
      unzip -q /tmp/ollama.zip -d /Applications/
      rm /tmp/ollama.zip
      export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
    else
      curl -fsSL https://ollama.com/install.sh | sh
    fi
  else
    echo -e "  ${C}[2/3]${N} Ollama already installed."
  fi

  if ! pgrep -x ollama >/dev/null 2>&1; then
    nohup ollama serve >/dev/null 2>&1 &
    sleep 3
  fi

  echo -e "  ${C}[3/3]${N} Downloading ${MODEL_NAME} (${MODEL_SIZE})..."
  echo ""
  ollama pull "$MODEL"
  echo ""

  save_config "$MODEL" "local"
  setup_path

  echo ""
  echo -e "  ${G}Done!${N} Default model: ${C}${MODEL_NAME}${N} (local, free, unlimited)"
  echo -e "  Run ${C}vix${N} anytime to start."
  echo ""
  echo -e "  ${C}Starting vix...${N}"
  echo ""
  exec "${INSTALL_DIR}/vix"

# ==============================================================
# MODE 2: CLOUD API
# ==============================================================
elif [ "$mode" = "2" ]; then
  echo -e "  ${Y}Choose your API model:${N}"
  echo ""
  echo -e "    ${G}1)${N} Gemma 4 31B   (free, Google AI Studio)"
  echo -e "    ${G}2)${N} Gemini Flash  (free, higher limits)"
  echo -e "    ${G}3)${N} Llama 3.3 70B (free, Groq)"
  echo -e "    ${G}4)${N} GPT-4o        (paid, OpenAI)"
  echo -e "    ${G}5)${N} Claude Sonnet (paid, Anthropic)"
  echo ""
  read_input "  Select [1-5]: " model_choice
  echo ""

  case "$model_choice" in
    1) MODEL="gemma"; PROVIDER_NAME="Google AI Studio"; KEY_VAR="GOOGLE_API_KEY"; KEY_URL="https://aistudio.google.com/app/apikey" ;;
    2) MODEL="gemini"; PROVIDER_NAME="Google AI Studio"; KEY_VAR="GOOGLE_API_KEY"; KEY_URL="https://aistudio.google.com/app/apikey" ;;
    3) MODEL="llama"; PROVIDER_NAME="Groq"; KEY_VAR="GROQ_API_KEY"; KEY_URL="https://console.groq.com/keys" ;;
    4) MODEL="gpt-4o"; PROVIDER_NAME="OpenAI"; KEY_VAR="OPENAI_API_KEY"; KEY_URL="https://platform.openai.com/api-keys" ;;
    5) MODEL="claude"; PROVIDER_NAME="Anthropic"; KEY_VAR="ANTHROPIC_API_KEY"; KEY_URL="https://console.anthropic.com/settings/keys" ;;
    *) echo "  Invalid choice."; exit 1 ;;
  esac

  echo -e "  Selected: ${G}${MODEL}${N} (${PROVIDER_NAME})"
  echo ""
  echo -e "  ${Y}Get your API key at:${N}"
  echo -e "  ${C}${KEY_URL}${N}"
  echo ""
  read_input "  Paste API key: " api_key
  echo ""

  if [ -z "$api_key" ]; then
    echo "  No key entered. Cancelling."
    exit 1
  fi

  echo -e "  ${C}[1/1]${N} Downloading vix..."
  install_vix_binary

  save_config "$MODEL" "api"
  save_env_var "$KEY_VAR" "$api_key"
  setup_path

  echo ""
  echo -e "  ${G}Done!${N} Default model: ${C}${MODEL}${N} (${PROVIDER_NAME})"
  echo -e "  API key saved to shell profile."
  echo -e "  Run ${C}vix${N} anytime to start."
  echo ""
  echo -e "  ${C}Starting vix...${N}"
  echo ""
  exec "${INSTALL_DIR}/vix"

else
  echo "  Invalid choice."
  exit 1
fi
