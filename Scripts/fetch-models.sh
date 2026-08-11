#!/usr/bin/env bash
# Download offline models + build in-process whisper/llama umbrella dylibs for ezeesti.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${EZEESTI_MODELS_DIR:-$HOME/Library/Application Support/Ezeesti/Models}"
VENDOR_DIR="${EZEESTI_VENDOR_DIR:-$ROOT/Vendor/native}"
CACHE_DIR="${EZEESTI_CACHE_DIR:-$ROOT/.cache}"
WHISPER_REPO="${WHISPER_REPO:-https://github.com/ggml-org/whisper.cpp.git}"
WHISPER_TAG="${WHISPER_TAG:-v1.9.2}"
LLAMA_REPO="${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp.git}"

WHISPER_HF="https://huggingface.co/TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604/resolve/main/ggml/ggml-model.bin"
LLM_HF="https://huggingface.co/mradermacher/Llama-3.1-EstLLM-8B-Instruct-1125-GGUF/resolve/main/Llama-3.1-EstLLM-8B-Instruct-1125.Q4_K_M.gguf"
TTS_URL="https://github.com/TartuNLP/text-to-speech-worker/releases/download/v3.1.0/multispeaker.zip"

mkdir -p "$MODELS_DIR/whisper" "$MODELS_DIR/llm" "$MODELS_DIR/tts" "$MODELS_DIR/bin" "$CACHE_DIR" "$VENDOR_DIR"

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

fix_dylib_rpaths() {
  local dir="$1"
  local dylib
  for dylib in "$dir"/*.dylib; do
    [[ -f "$dylib" ]] || continue
    [[ -L "$dylib" ]] && continue
    local base dep
    base="$(basename "$dylib")"
    install_name_tool -id "@loader_path/$base" "$dylib" 2>/dev/null || true
    while IFS= read -r dep; do
      case "$dep" in
        @rpath/*.dylib)
          local depbase="${dep#@rpath/}"
          if [[ -e "$dir/$depbase" ]]; then
            install_name_tool -change "$dep" "@loader_path/$depbase" "$dylib" 2>/dev/null || true
          fi
          ;;
      esac
    done < <(otool -L "$dylib" | awk 'NR>1 {print $1}')
  done
}

mirror_to_vendor() {
  local name="$1"
  local primary="$MODELS_DIR/native/$name/lib"
  local vendor="$VENDOR_DIR/$name/lib"
  rm -rf "$vendor"
  mkdir -p "$vendor"
  cp -a "$primary"/. "$vendor/"
}

APPLE_FRAMEWORKS=(
  -framework Foundation
  -framework Metal
  -framework MetalKit
  -framework Accelerate
  -framework CoreGraphics
)

echo "==> Models directory: $MODELS_DIR"
echo "==> Vendor directory: $VENDOR_DIR"

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
    git clone --depth 1 --branch "$WHISPER_TAG" "$WHISPER_REPO" "$src" || git clone --depth 1 "$WHISPER_REPO" "$src"
  elif [[ "$(git -C "$src" describe --tags 2>/dev/null)" != "$WHISPER_TAG" ]]; then
    # Cached checkout is on an older tag; move it forward instead of silently reusing it.
    echo "==> Updating cached whisper.cpp to $WHISPER_TAG"
    git -C "$src" fetch --depth 1 origin tag "$WHISPER_TAG" --no-tags
    git -C "$src" checkout -q "$WHISPER_TAG"
    rm -rf "$src/build"
  fi
  cmake -S "$src" -B "$src/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF
  cmake --build "$src/build" -j "$(sysctl -n hw.ncpu)"

  local bin_dir="$src/build/bin"
  local primary="$MODELS_DIR/native/whisper/lib"
  mkdir -p "$primary"
  find "$bin_dir" -maxdepth 1 \( -type f -o -type l \) \( -name 'libggml*.dylib' -o -name 'libwhisper*.dylib' \) -exec cp -a {} "$primary/" \;

  if [[ ! -f "$primary/libwhisper.dylib" ]]; then
    echo "libwhisper.dylib missing after copy" >&2
    exit 1
  fi

  echo "==> Linking libEzeestiWhisper.dylib"
  clang -dynamiclib \
    -o "$primary/libEzeestiWhisper.dylib" \
    "$ROOT/Native/ezeesti_whisper.c" \
    -I"$ROOT/Native/include" \
    -I"$src/include" \
    -I"$src/ggml/include" \
    -L"$primary" \
    -lwhisper \
    "${APPLE_FRAMEWORKS[@]}" \
    -lc++ \
    -install_name "@loader_path/libEzeestiWhisper.dylib" \
    -Wl,-rpath,@loader_path

  fix_dylib_rpaths "$primary"
  mirror_to_vendor whisper
  echo "✓ whisper native → $primary"

  if [[ -f "$bin_dir/whisper-cli" ]]; then
    cp "$bin_dir/whisper-cli" "$MODELS_DIR/bin/whisper-cli"
    chmod +x "$MODELS_DIR/bin/whisper-cli"
  fi
}

build_llama() {
  local src="$CACHE_DIR/llama.cpp"
  if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 "$LLAMA_REPO" "$src"
  fi
  cmake -S "$src" -B "$src/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF
  cmake --build "$src/build" -j "$(sysctl -n hw.ncpu)" --target llama

  local bin_dir="$src/build/bin"
  local primary="$MODELS_DIR/native/llama/lib"
  mkdir -p "$primary"
  find "$bin_dir" -maxdepth 1 \( -type f -o -type l \) \( -name 'libggml*.dylib' -o -name 'libllama*.dylib' \) -exec cp -a {} "$primary/" \;
  # Drop server/cli helper dylibs if present — not needed for inference.
  rm -f "$primary"/libllama-server*.dylib "$primary"/libllama-cli*.dylib "$primary"/libllama-common*.dylib "$primary"/libmtmd*.dylib

  if [[ ! -f "$primary/libllama.dylib" ]]; then
    echo "libllama.dylib missing after copy" >&2
    exit 1
  fi

  echo "==> Linking libEzeestiLlama.dylib"
  clang -dynamiclib \
    -o "$primary/libEzeestiLlama.dylib" \
    "$ROOT/Native/ezeesti_llama.c" \
    -I"$ROOT/Native/include" \
    -I"$src/include" \
    -I"$src/ggml/include" \
    -L"$primary" \
    -lllama \
    "${APPLE_FRAMEWORKS[@]}" \
    -lc++ \
    -install_name "@loader_path/libEzeestiLlama.dylib" \
    -Wl,-rpath,@loader_path

  fix_dylib_rpaths "$primary"
  mirror_to_vendor llama
  echo "✓ llama native → $primary"

  if [[ -f "$bin_dir/llama-cli" ]]; then
    cp "$bin_dir/llama-cli" "$MODELS_DIR/bin/llama-cli"
    chmod +x "$MODELS_DIR/bin/llama-cli"
  fi
}

if [[ "${SKIP_BUILD_BINARIES:-0}" != "1" ]]; then
  if ! have_cmd cmake; then
    echo "cmake not found. Install with: brew install cmake" >&2
    exit 1
  fi
  echo "==> Building whisper.cpp (Metal shared + umbrella)"
  build_whisper
  echo "==> Building llama.cpp (Metal shared + umbrella)"
  build_llama
else
  echo "==> Skipping binary builds (SKIP_BUILD_BINARIES=1)"
fi

required_files=(
  "$MODELS_DIR/whisper/ggml-model.bin"
  "$MODELS_DIR/llm/Llama-3.1-EstLLM-8B-Instruct-1125.Q4_K_M.gguf"
)
if [[ "${SKIP_BUILD_BINARIES:-0}" != "1" ]]; then
  required_files+=(
    "$MODELS_DIR/native/whisper/lib/libEzeestiWhisper.dylib"
    "$MODELS_DIR/native/llama/lib/libEzeestiLlama.dylib"
  )
fi
for required in "${required_files[@]}"; do
  if [[ ! -s "$required" ]]; then
    echo "Setup failed: required file missing or empty: $required" >&2
    exit 1
  fi
done

echo
echo "Done. Model root: $MODELS_DIR"
echo "In-process libs: $MODELS_DIR/native/{whisper,llama}/lib/libEzeesti*.dylib"
echo "Open Ezeesti.xcodeproj and run the macOS app."
