#!/usr/bin/env bash
# Download offline models + build whisper.cpp / llama.cpp CLIs for ezeesti.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${EZEESTI_MODELS_DIR:-$HOME/Library/Application Support/Ezeesti/Models}"
CACHE_DIR="${EZEESTI_CACHE_DIR:-$ROOT/.cache}"
WHISPER_REPO="${WHISPER_REPO:-https://github.com/ggml-org/whisper.cpp.git}"
LLAMA_REPO="${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp.git}"

WHISPER_HF="https://huggingface.co/TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604/resolve/main/ggml/ggml-model.bin"
LLM_HF="https://huggingface.co/mradermacher/Llama-3.1-EstLLM-8B-Instruct-1125-GGUF/resolve/main/Llama-3.1-EstLLM-8B-Instruct-1125.Q4_K_M.gguf"
TTS_URL="https://github.com/TartuNLP/text-to-speech-worker/releases/download/v3.1.0/multispeaker.zip"

mkdir -p "$MODELS_DIR/whisper" "$MODELS_DIR/llm" "$MODELS_DIR/tts" "$MODELS_DIR/bin" "$CACHE_DIR"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

download() {
  local url="$1"
  local dest="$2"
  if [[ -f "$dest" ]]; then
    echo "✓ exists: $dest"
    return
  fi
  echo "↓ $url"
  if have_cmd curl; then
    curl -L --fail --progress-bar -o "$dest.partial" "$url"
  else
    wget -O "$dest.partial" "$url"
  fi
  mv "$dest.partial" "$dest"
  echo "✓ saved: $dest"
}

echo "==> Models directory: $MODELS_DIR"

echo "==> TalTech Whisper ggml (verbatim-2604)"
download "$WHISPER_HF" "$MODELS_DIR/whisper/ggml-model.bin"

echo "==> Llama-3.1-EstLLM-8B-Instruct-1125 Q4_K_M"
download "$LLM_HF" "$MODELS_DIR/llm/Llama-3.1-EstLLM-8B-Instruct-1125.Q4_K_M.gguf"

echo "==> Neurokõne multispeaker (text-to-speech-worker v3.1.0)"
TTS_ZIP="$CACHE_DIR/multispeaker.zip"
download "$TTS_URL" "$TTS_ZIP"
if [[ ! -d "$MODELS_DIR/tts/multispeaker" ]]; then
  unzip -qo "$TTS_ZIP" -d "$MODELS_DIR/tts"
  echo "✓ extracted TTS models"
else
  echo "✓ TTS already extracted"
fi

build_whisper() {
  local src="$CACHE_DIR/whisper.cpp"
  if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 --branch v1.9.1 "$WHISPER_REPO" "$src" || git clone --depth 1 "$WHISPER_REPO" "$src"
  fi
  cmake -S "$src" -B "$src/build" -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "$src/build" -j "$(sysctl -n hw.ncpu)" --target whisper-cli
  local bin
  bin="$(find "$src/build" -type f -name whisper-cli | head -n 1)"
  if [[ -z "$bin" ]]; then
    echo "whisper-cli binary not found after build" >&2
    exit 1
  fi
  cp "$bin" "$MODELS_DIR/bin/whisper-cli"
  chmod +x "$MODELS_DIR/bin/whisper-cli"
  echo "✓ whisper-cli → $MODELS_DIR/bin/whisper-cli"
}

build_llama() {
  local src="$CACHE_DIR/llama.cpp"
  if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 "$LLAMA_REPO" "$src"
  fi
  cmake -S "$src" -B "$src/build" -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build "$src/build" -j "$(sysctl -n hw.ncpu)" --target llama-cli
  local bin
  bin="$(find "$src/build" -type f -name llama-cli | head -n 1)"
  if [[ -z "$bin" ]]; then
    echo "llama-cli binary not found after build" >&2
    exit 1
  fi
  cp "$bin" "$MODELS_DIR/bin/llama-cli"
  chmod +x "$MODELS_DIR/bin/llama-cli"
  echo "✓ llama-cli → $MODELS_DIR/bin/llama-cli"
}

if [[ "${SKIP_BUILD_BINARIES:-0}" != "1" ]]; then
  if ! have_cmd cmake; then
    echo "cmake not found. Install with: brew install cmake" >&2
    exit 1
  fi
  echo "==> Building whisper.cpp (Metal)"
  build_whisper
  echo "==> Building llama.cpp (Metal)"
  build_llama
else
  echo "==> Skipping binary builds (SKIP_BUILD_BINARIES=1)"
fi

echo
echo "Done. Model root: $MODELS_DIR"
echo "Open Ezeesti.xcodeproj and run the macOS app."
