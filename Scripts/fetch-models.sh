#!/usr/bin/env bash
# Download Hugging Face weights one file at a time (curl + resume), then convert to MLX
# for a required local OMLX server.
#
# Models land under Application Support and are meant to be served with:
#   omlx serve --model-dir "$MODELS_DIR"
#   # or copy/symlink into ~/.omlx/models and use the default omlx model dir
#
# Usage:
#   ./Scripts/fetch-models.sh
#   EZEESTI_LLM=8b|70b|both|auto ./Scripts/fetch-models.sh
#   SKIP_TTS=1 ./Scripts/fetch-models.sh
#   COPY_TO_OMLX=1 ./Scripts/fetch-models.sh   # also copy MLX dirs into ~/.omlx/models
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${EZEESTI_MODELS_DIR:-$HOME/Library/Application Support/Ezeesti/Models}"
CACHE_DIR="${EZEESTI_CACHE_DIR:-$ROOT/.cache}"
HF_CACHE="${EZEESTI_HF_CACHE:-$CACHE_DIR/hf}"
OMLX_MODELS_DIR="${EZEESTI_OMLX_MODELS_DIR:-$HOME/.omlx/models}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
COPY_TO_OMLX="${COPY_TO_OMLX:-1}"

# EstLLM catalog (directory names must match Sources/EzeestiCore/Models.swift).
LLM_8B_HF="tartuNLP/Llama-3.1-EstLLM-8B-Instruct-1125"
LLM_8B_DIR="Llama-3.1-EstLLM-8B-Instruct-1125-4bit"
LLM_70B_HF="tartuNLP/Llama-3.1-EstLLM-70B-Instruct-0826"
LLM_70B_DIR="Llama-3.1-EstLLM-70B-Instruct-0826-4bit"
LLM_70B_MIN_GIB=48

WHISPER_HF="TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604"
WHISPER_DIR="whisper-large-v3-turbo-et-verbatim-2604-mlx"

# Neurokõne weights live on gated HF (optional; SKIP_TTS=1 to skip).
TTS_HF_REPO="${TTS_HF_REPO:-tartuNLP/fastpitch-est}"
TTS_HF_REVISION="${TTS_HF_REVISION:-main}"
TTS_FILES=(config.yaml model_weights.hdf5)

mkdir -p "$MODELS_DIR/llm" "$MODELS_DIR/whisper" "$MODELS_DIR/tts" "$MODELS_DIR/bin" "$HF_CACHE"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

physical_ram_gib() {
  local bytes
  bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  echo $(( bytes / 1024 / 1024 / 1024 ))
}

model_dir_ready() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local count
  count="$(find "$dir" -type f 2>/dev/null | head -n 1 | wc -l | tr -d ' ')"
  [[ "$count" -ge 1 ]]
}

bytes_human() {
  local b="${1:-0}"
  if [[ "$b" -ge 1073741824 ]]; then
    awk -v b="$b" 'BEGIN { printf "%.1f GiB", b/1073741824 }'
  elif [[ "$b" -ge 1048576 ]]; then
    awk -v b="$b" 'BEGIN { printf "%.1f MiB", b/1048576 }'
  else
    echo "${b} B"
  fi
}

# Resolve which EstLLM variants to convert. EZEESTI_LLM=auto|8b|70b|both (default auto).
resolve_llm_targets() {
  LLM_TARGETS=()
  LLM_SELECTION_REASON=""

  if [[ -n "${EZEESTI_LLM_DIR:-}" && -d "${EZEESTI_LLM_DIR}" ]]; then
    LLM_SELECTION_REASON="EZEESTI_LLM_DIR override → ${EZEESTI_LLM_DIR}"
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
}

require_tools() {
  if ! have_cmd python3; then
    echo "python3 is required for MLX conversion" >&2
    exit 1
  fi
  if ! have_cmd curl; then
    echo "curl is required" >&2
    exit 1
  fi
  if ! have_cmd git; then
    echo "git is required (Whisper MLX convert via mlx-examples)" >&2
    exit 1
  fi

  if ! have_cmd omlx; then
    echo "warning: omlx not on PATH — install with:" >&2
    echo "  brew tap jundot/omlx https://github.com/jundot/omlx" >&2
    echo "  brew install jundot/omlx/omlx" >&2
  fi

  echo "==> Ensuring Python packages: mlx-lm"
  python3 -m pip install --upgrade 'mlx-lm' >/dev/null
  export PATH="$(python3 -c 'import site; print(site.USER_BASE)')/bin:${PATH}"
  if ! have_cmd mlx_lm.convert && ! python3 -c 'import mlx_lm' 2>/dev/null; then
    echo "mlx-lm did not install correctly" >&2
    exit 1
  fi
}

mlx_lm_convert() {
  if have_cmd mlx_lm.convert; then
    mlx_lm.convert "$@"
  else
    python3 -m mlx_lm convert "$@"
  fi
}

# Resume-friendly curl. Longer stall window for multi-GB shards.
curl_download() {
  local url="$1"
  local partial="$2"
  if [[ -n "$HF_TOKEN" && "$url" == *huggingface.co* ]]; then
    curl -L --fail --progress-bar \
      --connect-timeout 30 \
      --retry 12 \
      --retry-delay 5 \
      --retry-all-errors \
      --speed-limit 4096 \
      --speed-time 120 \
      -C - \
      -H "Authorization: Bearer ${HF_TOKEN}" \
      -o "$partial" \
      "$url"
  else
    curl -L --fail --progress-bar \
      --connect-timeout 30 \
      --retry 12 \
      --retry-delay 5 \
      --retry-all-errors \
      --speed-limit 4096 \
      --speed-time 120 \
      -C - \
      -o "$partial" \
      "$url"
  fi
}

download_file() {
  local url="$1"
  local dest="$2"
  local expected_size="${3:-}"

  mkdir -p "$(dirname "$dest")"

  if [[ -f "$dest" ]]; then
    if [[ -n "$expected_size" && "$expected_size" =~ ^[0-9]+$ ]]; then
      local have
      have="$(wc -c <"$dest" | tr -d ' ')"
      if [[ "$have" == "$expected_size" ]]; then
        echo "    exists ($(bytes_human "$have")): ${dest#"$HF_CACHE/"}"
        return
      fi
      echo "    size mismatch for ${dest#"$HF_CACHE/"} (have $have, want $expected_size) — re-downloading"
      rm -f "$dest"
    else
      echo "    exists: ${dest#"$HF_CACHE/"}"
      return
    fi
  fi

  local partial="${dest}.partial"
  local label
  label="${dest#"$HF_CACHE/"}"
  if [[ -n "$expected_size" && "$expected_size" =~ ^[0-9]+$ ]]; then
    echo "    downloading $label ($(bytes_human "$expected_size"))"
  else
    echo "    downloading $label"
  fi
  curl_download "$url" "$partial"

  if [[ -n "$expected_size" && "$expected_size" =~ ^[0-9]+$ ]]; then
    local got
    got="$(wc -c <"$partial" | tr -d ' ')"
    if [[ "$got" != "$expected_size" ]]; then
      echo "Incomplete download for $label (got $got, expected $expected_size)" >&2
      exit 1
    fi
  fi
  mv "$partial" "$dest"
}

# List files in an HF repo (path\tsize per line). Uses recursive tree API.
hf_list_files() {
  local repo="$1"
  local revision="${2:-main}"
  local api="https://huggingface.co/api/models/${repo}/tree/${revision}?recursive=1"
  local json
  if [[ -n "$HF_TOKEN" ]]; then
    json="$(curl -sL --fail --connect-timeout 30 -H "Authorization: Bearer ${HF_TOKEN}" "$api")"
  else
    json="$(curl -sL --fail --connect-timeout 30 "$api")"
  fi
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
for x in data:
    if x.get("type") != "file":
        continue
    path = x.get("path") or ""
    size = x.get("size")
    if size is None:
        size = ""
    print(f"{path}\t{size}")
' "$json"
}

# Download an HF repo into $HF_CACHE/<repo>, one file at a time.
# Optional 3rd arg: python regex of paths to skip.
# Progress goes to stderr; the only stdout line is the local dest path (for $(...)).
hf_download_repo() {
  local repo="$1"
  local revision="${2:-main}"
  local skip_re="${3:-}"
  local dest="$HF_CACHE/$repo"
  mkdir -p "$dest"

  echo "==> Listing $repo@$revision" >&2
  local listing
  listing="$(hf_list_files "$repo" "$revision")"
  if [[ -z "$listing" ]]; then
    echo "No files listed for $repo" >&2
    exit 1
  fi

  local path size total=0 count=0 skipped=0
  while IFS=$'\t' read -r path size; do
    [[ -n "$path" ]] || continue
    if [[ -n "$skip_re" ]] && python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$skip_re" "$path"; then
      echo "    skip: $path" >&2
      skipped=$((skipped + 1))
      continue
    fi
    count=$((count + 1))
    if [[ "$size" =~ ^[0-9]+$ ]]; then
      total=$((total + size))
    fi
  done <<<"$listing"
  echo "    will download $count files (~$(bytes_human "$total")); skipped $skipped" >&2

  local i=0
  while IFS=$'\t' read -r path size; do
    [[ -n "$path" ]] || continue
    if [[ -n "$skip_re" ]] && python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$skip_re" "$path"; then
      continue
    fi
    i=$((i + 1))
    echo "  [$i/$count] $path" >&2
    # download_file echos progress to stdout — redirect that to stderr too.
    download_file \
      "https://huggingface.co/${repo}/resolve/${revision}/${path}" \
      "$dest/$path" \
      "$size" >&2
  done <<<"$listing"

  printf '%s\n' "$dest"
}

convert_estllm() {
  local hf_repo="$1"
  local out_dir="$2"
  if model_dir_ready "$out_dir"; then
    echo "    exists: $(basename "$out_dir")"
    return
  fi

  local local_hf
  local_hf="$(hf_download_repo "$hf_repo" main)"

  local tmp="${out_dir}.converting.$$"
  rm -rf "$tmp"
  echo "    converting local $local_hf → $(basename "$out_dir") (4-bit MLX)"
  if [[ -n "$HF_TOKEN" ]]; then
    export HF_TOKEN HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
  fi
  mlx_lm_convert \
    --hf-path "$local_hf" \
    --mlx-path "$tmp" \
    -q --q-bits 4
  rm -rf "$out_dir"
  mv "$tmp" "$out_dir"
}

convert_selected_llms() {
  if [[ -n "${EZEESTI_LLM_DIR:-}" && -d "${EZEESTI_LLM_DIR}" ]]; then
    echo "==> Skipping EstLLM convert ($LLM_SELECTION_REASON)"
    return
  fi
  if [[ ${#LLM_TARGETS[@]} -eq 0 ]]; then
    echo "==> Skipping EstLLM convert ($LLM_SELECTION_REASON)"
    return
  fi
  local id
  for id in "${LLM_TARGETS[@]}"; do
    case "$id" in
      8b)
        echo "==> EstLLM 8B → download then MLX 4-bit ($LLM_8B_DIR)"
        convert_estllm "$LLM_8B_HF" "$MODELS_DIR/llm/$LLM_8B_DIR"
        ;;
      70b)
        echo "==> EstLLM 70B → download then MLX 4-bit ($LLM_70B_DIR)"
        echo "    note: HF safetensors are ~131 GiB before 4-bit quantize"
        convert_estllm "$LLM_70B_HF" "$MODELS_DIR/llm/$LLM_70B_DIR"
        ;;
    esac
  done
}

ensure_mlx_examples_whisper() {
  local src="$CACHE_DIR/mlx-examples"
  if [[ ! -d "$src/.git" ]]; then
    echo "==> Cloning mlx-examples (Whisper convert script)"
    rm -rf "$src"
    git clone --depth 1 https://github.com/ml-explore/mlx-examples.git "$src"
  fi
  if [[ ! -f "$src/whisper/convert.py" ]]; then
    echo "mlx-examples whisper/convert.py missing under $src" >&2
    exit 1
  fi
  python3 -m pip install --upgrade 'mlx' 'numpy' 'scipy' 'torch' 'torchaudio' 'tqdm' 'more-itertools' 'tiktoken' 'numba' 'huggingface-hub<1.0' >/dev/null
}

convert_whisper() {
  local out_dir="$MODELS_DIR/whisper/$WHISPER_DIR"
  if model_dir_ready "$out_dir"; then
    echo "==> Whisper MLX exists: $WHISPER_DIR"
    return
  fi

  # Skip ggml/ct2/demo/native — convert only needs transformers weights + tokenizer.
  local local_hf
  local_hf="$(hf_download_repo "$WHISPER_HF" main '^(ggml/|ct2/|demo/|native/)')"
  ensure_mlx_examples_whisper

  local tmp="${out_dir}.converting.$$"
  rm -rf "$tmp"
  echo "==> Converting local Whisper → $WHISPER_DIR"
  (
    cd "$CACHE_DIR/mlx-examples/whisper"
    python3 convert.py \
      --torch-name-or-path "$local_hf" \
      --mlx-path "$tmp"
  )
  rm -rf "$out_dir"
  mkdir -p "$(dirname "$out_dir")"
  mv "$tmp" "$out_dir"

  # OMLX STT requires HF processor/tokenizer files that mlx-examples convert omits.
  echo "    copying Whisper processor/tokenizer files for OMLX"
  local f
  for f in preprocessor_config.json tokenizer.json tokenizer_config.json \
           special_tokens_map.json vocab.json merges.txt added_tokens.json \
           normalizer.json generation_config.json; do
    if [[ -f "$local_hf/$f" ]]; then
      cp -f "$local_hf/$f" "$out_dir/$f"
    fi
  done
}

download_tts_weights() {
  if [[ "${SKIP_TTS:-0}" == "1" ]]; then
    echo "==> Skipping Neurokõne weights (SKIP_TTS=1)"
    return
  fi
  if [[ -z "$HF_TOKEN" ]]; then
    echo "==> Skipping Neurokõne weights (set HF_TOKEN for gated tartuNLP/fastpitch-est, or SKIP_TTS=1)"
    echo "    Hear target still works via macOS speech without Neurokõne."
    return
  fi
  echo "==> Neurokõne FastPitch weights ($TTS_HF_REPO@$TTS_HF_REVISION)"
  local f
  for f in "${TTS_FILES[@]}"; do
    download_file \
      "https://huggingface.co/${TTS_HF_REPO}/resolve/${TTS_HF_REVISION}/${f}" \
      "$MODELS_DIR/tts/$f"
  done
}

link_model_alias() {
  local real="$1"
  local name
  name="$(basename "$real")"
  local alias_path="$MODELS_DIR/$name"
  [[ -d "$real" ]] || return 0
  if [[ -L "$alias_path" || -e "$alias_path" ]]; then
    return 0
  fi
  local parent
  parent="$(basename "$(dirname "$real")")"
  ln -s "${parent}/${name}" "$alias_path"
}

copy_to_omlx() {
  if [[ "$COPY_TO_OMLX" != "1" ]]; then
    return
  fi
  mkdir -p "$OMLX_MODELS_DIR"
  echo "==> Copying MLX models into $OMLX_MODELS_DIR"
  local src name dest
  for src in "$MODELS_DIR/llm"/* "$MODELS_DIR/whisper"/*; do
    [[ -d "$src" ]] || continue
    name="$(basename "$src")"
    dest="$OMLX_MODELS_DIR/$name"
    if model_dir_ready "$dest"; then
      echo "    exists: $name"
      continue
    fi
    echo "    copying $name (APFS clone when possible)"
    rm -rf "$dest"
    if cp -cR "$src" "$dest" 2>/dev/null; then
      :
    else
      cp -R "$src" "$dest"
    fi
  done
}

resolve_llm_targets
require_tools

echo "==> Models directory: $MODELS_DIR"
echo "==> HF download cache: $HF_CACHE"
echo "==> EstLLM selection: $LLM_SELECTION_REASON"

convert_selected_llms
convert_whisper
download_tts_weights

for d in "$MODELS_DIR/llm"/* "$MODELS_DIR/whisper"/*; do
  [[ -d "$d" ]] || continue
  link_model_alias "$d"
done

copy_to_omlx

echo
echo "==> Done."
echo "Serve with OMLX:"
echo "  omlx serve"
echo "  # or: omlx serve --model-dir \"$MODELS_DIR\""
echo
echo "Confirm model IDs:"
echo "  curl -s http://127.0.0.1:8000/v1/models | python3 -m json.tool"
echo
echo "Default MLX directory names:"
echo "  LLM:  $MODELS_DIR/llm/{${LLM_8B_DIR}|${LLM_70B_DIR}}"
echo "  STT:  $MODELS_DIR/whisper/$WHISPER_DIR"
if [[ "$COPY_TO_OMLX" == "1" ]]; then
  echo "  OMLX: $OMLX_MODELS_DIR/"
fi
