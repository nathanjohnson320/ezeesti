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
# Neurokõne weights live on gated HF (GitHub release zips were removed after v3.0).
TTS_HF_REPO="${TTS_HF_REPO:-tartuNLP/fastpitch-est}"
TTS_HF_REVISION="${TTS_HF_REVISION:-main}"
TTS_FILES=(config.yaml model_weights.hdf5)
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

# EstLLM catalog (filenames must match Sources/EzeestiCore/Models.swift).
LLM_8B_FILE="Llama-3.1-EstLLM-8B-Instruct-1125.Q4_K_M.gguf"
LLM_8B_URL="https://huggingface.co/mradermacher/Llama-3.1-EstLLM-8B-Instruct-1125-GGUF/resolve/main/${LLM_8B_FILE}"
LLM_70B_FILE="Llama-3.1-EstLLM-70B-Instruct-0826.Q4_K_M.gguf"
# Community Q4_K_M of tartuNLP/Llama-3.1-EstLLM-70B-Instruct-0826 (HF blob name lacks quant suffix).
LLM_70B_URL="https://huggingface.co/Dr-sdr/Llama-3.1-EstLLM-70B-Instruct-0826-GGUF/resolve/main/Llama-3.1-EstLLM-70B-Instruct-0826.gguf"
LLM_70B_MIN_GIB=48

mkdir -p "$MODELS_DIR/whisper" "$MODELS_DIR/llm" "$MODELS_DIR/tts" "$MODELS_DIR/bin" "$CACHE_DIR" "$VENDOR_DIR"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

physical_ram_gib() {
  local bytes
  bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  echo $(( bytes / 1024 / 1024 / 1024 ))
}

# Resolve which EstLLM GGUF(s) to download. EZEESTI_LLM=auto|8b|70b|both (default auto).
# If EZEESTI_LLM_GGUF points at an existing file, skip LLM downloads.
resolve_llm_targets() {
  LLM_TARGETS=()
  LLM_REQUIRED=()
  LLM_SELECTION_REASON=""

  if [[ -n "${EZEESTI_LLM_GGUF:-}" && -f "${EZEESTI_LLM_GGUF}" ]]; then
    LLM_SELECTION_REASON="EZEESTI_LLM_GGUF override → ${EZEESTI_LLM_GGUF}"
    LLM_REQUIRED+=("${EZEESTI_LLM_GGUF}")
    return
  fi

  local mode="${EZEESTI_LLM:-auto}"
  local gib
  gib="$(physical_ram_gib)"

  case "$mode" in
    auto)
      if [[ "$gib" -ge "$LLM_70B_MIN_GIB" ]]; then
        LLM_TARGETS+=("70b")
        LLM_SELECTION_REASON="auto (${gib} GiB ≥ ${LLM_70B_MIN_GIB} GiB) → 70B"
      else
        LLM_TARGETS+=("8b")
        LLM_SELECTION_REASON="auto (${gib} GiB < ${LLM_70B_MIN_GIB} GiB) → 8B"
      fi
      ;;
    8b|70b)
      LLM_TARGETS+=("$mode")
      LLM_SELECTION_REASON="EZEESTI_LLM=${mode}"
      ;;
    both)
      LLM_TARGETS+=("8b" "70b")
      LLM_SELECTION_REASON="EZEESTI_LLM=both"
      ;;
    *)
      echo "Unknown EZEESTI_LLM=${mode} (use auto|8b|70b|both)" >&2
      exit 1
      ;;
  esac

  local id
  for id in "${LLM_TARGETS[@]}"; do
    case "$id" in
      8b)  LLM_REQUIRED+=("$MODELS_DIR/llm/$LLM_8B_FILE") ;;
      70b) LLM_REQUIRED+=("$MODELS_DIR/llm/$LLM_70B_FILE") ;;
    esac
  done
}

download_selected_llms() {
  local id
  if [[ ${#LLM_TARGETS[@]} -eq 0 ]]; then
    echo "==> Skipping EstLLM download ($LLM_SELECTION_REASON)"
    return
  fi
  for id in "${LLM_TARGETS[@]}"; do
    case "$id" in
      8b)
        echo "==> Llama-3.1-EstLLM-8B-Instruct-1125 Q4_K_M"
        download "$LLM_8B_URL" "$MODELS_DIR/llm/$LLM_8B_FILE"
        ;;
      70b)
        echo "==> Llama-3.1-EstLLM-70B-Instruct-0826 Q4_K_M (~43 GB)"
        download "$LLM_70B_URL" "$MODELS_DIR/llm/$LLM_70B_FILE"
        ;;
    esac
  done
}

# Abort if transfer stalls below 8 KiB/s for 45s; retry/resume on failure.
curl_download() {
  local url="$1"
  local partial="$2"
  local -a auth=()
  if [[ -n "$HF_TOKEN" && "$url" == *huggingface.co* ]]; then
    auth=(-H "Authorization: Bearer ${HF_TOKEN}")
  fi
  curl -L --fail --progress-bar \
    --connect-timeout 30 \
    --retry 8 \
    --retry-delay 3 \
    --retry-all-errors \
    --speed-limit 8192 \
    --speed-time 45 \
    -C - \
    "${auth[@]}" \
    -o "$partial" \
    "$url"
}

download() {
  local url="$1"
  local dest="$2"
  local attempt rc
  if [[ -f "$dest" && -s "$dest" ]]; then
    echo "✓ exists: $dest"
    return
  fi
  echo "↓ $url"
  if have_cmd curl; then
    for attempt in 1 2 3 4 5; do
      if [[ -f "$dest.partial" ]]; then
        echo "  attempt ${attempt}/5 — resuming $(du -h "$dest.partial" | awk '{print $1}') partial…"
      else
        echo "  attempt ${attempt}/5"
      fi
      rc=0
      curl_download "$url" "$dest.partial" || rc=$?
      if [[ $rc -eq 0 && -s "$dest.partial" ]]; then
        mv "$dest.partial" "$dest"
        echo "✓ saved: $dest"
        return
      fi
      # 22 = HTTP error from --fail (401/403/404). Don't spin on permanent auth failures.
      if [[ $rc -eq 22 || $rc -eq 56 ]] && [[ "$url" == *huggingface.co*"${TTS_HF_REPO}"* ]]; then
        echo "Neurokõne weights are gated (HTTP error ${rc})." >&2
        echo "  • Request access: https://huggingface.co/${TTS_HF_REPO}" >&2
        echo "  • Or skip TTS and use macOS speech: SKIP_TTS=1 ./Scripts/fetch-models.sh" >&2
        return 22
      fi
      echo "  download stalled or failed (exit ${rc}) — retrying in 5s…"
      sleep 5
    done
    echo "Download failed after retries: $url" >&2
    exit 1
  else
    wget -c -O "$dest.partial" "$url"
    mv "$dest.partial" "$dest"
    echo "✓ saved: $dest"
  fi
}

download_tts_models() {
  local dest="$MODELS_DIR/tts/multispeaker"
  local file url rc
  TTS_READY=0

  if [[ "${SKIP_TTS:-0}" == "1" ]]; then
    echo "==> Skipping Neurokõne TTS (SKIP_TTS=1) — app will use macOS system speech"
    return 0
  fi

  mkdir -p "$dest"
  if [[ -s "$dest/model_weights.hdf5" && -s "$dest/config.yaml" ]]; then
    echo "✓ TTS models already present → $dest"
    TTS_READY=1
    return 0
  fi

  echo "==> Neurokõne multispeaker (${TTS_HF_REPO} @ ${TTS_HF_REVISION})"
  if [[ -z "$HF_TOKEN" ]]; then
    echo "  note: ${TTS_HF_REPO} is gated — needs approved HF access + HF_TOKEN"
  fi
  for file in "${TTS_FILES[@]}"; do
    url="https://huggingface.co/${TTS_HF_REPO}/resolve/${TTS_HF_REVISION}/${file}"
    rc=0
    download "$url" "$dest/$file" || rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "==> Continuing without Neurokõne (macOS system speech fallback)."
      echo "    Re-run with approved access later, or SKIP_TTS=1 to silence this attempt."
      return 0
    fi
  done
  if [[ -s "$dest/model_weights.hdf5" && -s "$dest/config.yaml" ]]; then
    TTS_READY=1
    echo "✓ TTS models → $dest"
  else
    echo "==> Neurokõne weights incomplete — using macOS system speech fallback."
  fi
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

resolve_llm_targets

echo "==> Models directory: $MODELS_DIR"
echo "==> Vendor directory: $VENDOR_DIR"
echo "==> EstLLM selection: $LLM_SELECTION_REASON"

echo "==> TalTech Whisper ggml (verbatim-2604)"
download "$WHISPER_HF" "$MODELS_DIR/whisper/ggml-model.bin"

download_selected_llms

download_tts_models

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
)
required_files+=("${LLM_REQUIRED[@]}")
if [[ "${TTS_READY:-0}" == "1" ]]; then
  required_files+=(
    "$MODELS_DIR/tts/multispeaker/config.yaml"
    "$MODELS_DIR/tts/multispeaker/model_weights.hdf5"
  )
fi
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
echo "EstLLM: $LLM_SELECTION_REASON"
if [[ "${TTS_READY:-0}" == "1" ]]; then
  echo "TTS: Neurokõne weights ready (run ./Scripts/setup-neurokone.sh)"
else
  echo "TTS: skipped — app falls back to macOS system speech"
fi
echo "In-process libs: $MODELS_DIR/native/{whisper,llama}/lib/libEzeesti*.dylib"
echo "Open Ezeesti.xcodeproj and run the macOS app."
