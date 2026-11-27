#!/usr/bin/env bash
# One-time Neurokõne Python env setup. Reuses models already downloaded by fetch-models.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache"
WORKER="$CACHE/text-to-speech-worker"
WORKER_TAG="${NEUROKONE_WORKER_TAG:-v3.2.0}"
VENV="$CACHE/neurokone-venv"
MODELS_TTS="${EZEESTI_MODELS_DIR:-$HOME/Library/Application Support/Ezeesti/Models}/tts/multispeaker"
BIN_DIR="${EZEESTI_MODELS_DIR:-$HOME/Library/Application Support/Ezeesti/Models}/bin"

# TensorFlow 2.13 only ships wheels for CPython 3.9–3.11, so a newer default
# python3 fails with a confusing "no matching distribution" error.
PYTHON_BIN="${NEUROKONE_PYTHON:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  for candidate in python3.10 python3.11 python3.9; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON_BIN="$(command -v "$candidate")"
      break
    fi
  done
fi

if [[ -z "$PYTHON_BIN" ]]; then
  echo "No compatible Python found (need 3.9–3.11, 3.10 recommended)."
  echo "Install with: brew install python@3.10"
  echo "Or point at an existing one: NEUROKONE_PYTHON=/path/to/python3.10 $0"
  exit 1
fi

PY_MINOR="$("$PYTHON_BIN" -c 'import sys; print(sys.version_info[1])')"
if [[ "$("$PYTHON_BIN" -c 'import sys; print(sys.version_info[0])')" != "3" || "$PY_MINOR" -lt 9 || "$PY_MINOR" -gt 11 ]]; then
  echo "$PYTHON_BIN is $("$PYTHON_BIN" --version), but Neurokõne needs Python 3.9–3.11 (TensorFlow 2.13 has no wheels beyond 3.11)."
  echo "Install with: brew install python@3.10"
  exit 1
fi

echo "Using Python: $PYTHON_BIN ($($PYTHON_BIN --version))"

if [[ ! -f "$MODELS_TTS/model_weights.hdf5" ]]; then
  echo "Missing TTS weights at $MODELS_TTS"
  echo "Run ./Scripts/fetch-models.sh first (needs HF_TOKEN for gated tartuNLP/fastpitch-est)."
  exit 1
fi

ensure_worker_checkout() {
  local current=""
  if [[ -d "$WORKER/.git" ]]; then
    current="$(git -C "$WORKER" describe --tags --exact-match 2>/dev/null || git -C "$WORKER" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    if [[ "$current" == "$WORKER_TAG" ]]; then
      echo "✓ text-to-speech-worker already at $WORKER_TAG"
      return
    fi
    echo "==> Existing checkout is ${current}; replacing with ${WORKER_TAG}"
    rm -rf "$WORKER"
  fi
  echo "==> Cloning TartuNLP text-to-speech-worker ${WORKER_TAG}"
  git clone --depth 1 --branch "$WORKER_TAG" --recurse-submodules \
    https://github.com/TartuNLP/text-to-speech-worker.git "$WORKER"
}

ensure_worker_checkout

mkdir -p "$WORKER/models" "$BIN_DIR"
ln -sfn "$MODELS_TTS" "$WORKER/models/multispeaker"

if [[ -d "$VENV" ]]; then
  VENV_VER="$("$VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown)"
  WANT_VER="$("$PYTHON_BIN" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  if [[ "$VENV_VER" != "$WANT_VER" ]]; then
    echo "==> Existing venv is Python $VENV_VER, need $WANT_VER — recreating"
    rm -rf "$VENV"
  fi
fi

if [[ ! -d "$VENV" ]]; then
  echo "==> Creating venv at $VENV"
  "$PYTHON_BIN" -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel setuptools

echo "==> Installing Neurokõne dependencies for ${WORKER_TAG} (this can take several minutes)"
# Prefer Apple Silicon TF when classic tensorflow wheel is unavailable.
if ! python -m pip install "tensorflow==2.13.0"; then
  echo "tensorflow==2.13.0 unavailable; trying tensorflow-macos==2.13.0"
  python -m pip install "tensorflow-macos==2.13.0"
fi

# Match v3.2.0 requirements.txt, but use stock macOS PyTorch wheels (not cu118).
python -m pip install \
  "librosa==0.11.0" \
  "ruamel.yaml" \
  "nltk==3.9.2" \
  "pika==1.3.2" \
  "pydantic" \
  "pydantic-settings" \
  "python-dotenv" \
  "scipy" \
  "numpy" \
  "speechbrain==1.0.3" \
  "torch==2.1.2" \
  "torchaudio==2.1.2" \
  "huggingface-hub==0.29.2" \
  "PyYAML" \
  "typing-extensions>=4.14.1" \
  "git+https://github.com/TartuNLP/tts_preprocess_et.git@v1.1.1" \
  "git+https://github.com/TartuNLP/tts_preprocess_smugri.git@54fa996"

python - <<'PY'
import nltk
for pkg in ("punkt", "punkt_tab"):
    try:
        nltk.download(pkg, quiet=True)
    except Exception as exc:
        print("nltk download warning:", pkg, exc)
PY

WRAPPER="$BIN_DIR/neurokone-cli"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT="$ROOT"
VENV="$VENV"
export EZEESTI_TTS_WORKER_ROOT="$WORKER"
export EZEESTI_TTS_MODEL_DIR="$MODELS_TTS"
export TF_CPP_MIN_LOG_LEVEL=2
export TF_ENABLE_ONEDNN_OPTS=0
# Cap input length (v3.2.0 reads TTS_MAX_INPUT_LENGTH instead of a ctor arg).
export TTS_MAX_INPUT_LENGTH="\${TTS_MAX_INPUT_LENGTH:-180}"
# shellcheck disable=SC1091
source "\$VENV/bin/activate"
exec python "\$ROOT/Scripts/neurokone_synthesize.py" "\$@"
EOF
chmod +x "$WRAPPER" "$ROOT/Scripts/neurokone_synthesize.py"

SMOKE_OUT="$(mktemp "${TMPDIR:-/tmp}/ezeesti-neurokone.XXXXXX.wav")"
trap 'rm -f "$SMOKE_OUT"' EXIT
echo "==> Verifying Neurokõne synthesis"
if ! "$WRAPPER" --text "Tere!" --out "$SMOKE_OUT"; then
  echo "Setup failed: Neurokõne could not synthesize speech" >&2
  exit 1
fi
if [[ ! -s "$SMOKE_OUT" ]]; then
  echo "Setup failed: Neurokõne produced no audio" >&2
  exit 1
fi

echo
echo "✓ Neurokõne ready: $WRAPPER"
