#!/usr/bin/env bash
# One-time Neurokõne Python env setup. Reuses models already downloaded by fetch-models.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache"
WORKER="$CACHE/text-to-speech-worker"
VENV="$CACHE/neurokone-venv"
MODELS_TTS="${EZEESTI_MODELS_DIR:-$HOME/Library/Application Support/Ezeesti/Models}/tts/multispeaker"
BIN_DIR="${EZEESTI_MODELS_DIR:-$HOME/Library/Application Support/Ezeesti/Models}/bin"

PYTHON_BIN="${NEUROKONE_PYTHON:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3.10 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3.10)"
  else
    PYTHON_BIN="$(command -v python3)"
  fi
fi

echo "Using Python: $PYTHON_BIN ($($PYTHON_BIN --version))"

if [[ ! -f "$MODELS_TTS/model_weights.hdf5" ]]; then
  echo "Missing TTS weights at $MODELS_TTS"
  echo "Run ./Scripts/fetch-models.sh first (or SKIP_BUILD_BINARIES=1 ./Scripts/fetch-models.sh)."
  exit 1
fi

if [[ ! -d "$WORKER/.git" ]]; then
  echo "==> Cloning TartuNLP text-to-speech-worker v3.1.0"
  git clone --depth 1 --branch v3.1.0 --recurse-submodules \
    https://github.com/TartuNLP/text-to-speech-worker.git "$WORKER"
fi

mkdir -p "$WORKER/models" "$BIN_DIR"
ln -sfn "$MODELS_TTS" "$WORKER/models/multispeaker"

if [[ ! -d "$VENV" ]]; then
  echo "==> Creating venv at $VENV"
  "$PYTHON_BIN" -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip wheel setuptools

echo "==> Installing Neurokõne dependencies (this can take several minutes)"
# Prefer Apple Silicon TF when classic tensorflow wheel is unavailable.
if ! python -m pip install "tensorflow==2.13.0"; then
  echo "tensorflow==2.13.0 unavailable; trying tensorflow-macos==2.13.0"
  python -m pip install "tensorflow-macos==2.13.0"
fi

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
  "speechbrain==1.0.2" \
  "torch==2.1.2" \
  "torchaudio==2.1.2" \
  "huggingface-hub==0.29.2" \
  "PyYAML" \
  "typing-extensions>=4.14.1" \
  "git+https://github.com/TartuNLP/tts_preprocess_et.git@v1.1.0"

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
# shellcheck disable=SC1091
source "\$VENV/bin/activate"
exec python "\$ROOT/Scripts/neurokone_synthesize.py" "\$@"
EOF
chmod +x "$WRAPPER" "$ROOT/Scripts/neurokone_synthesize.py"

echo
echo "✓ Neurokõne ready: $WRAPPER"
echo "Smoke test:"
echo "  \"$WRAPPER\" --text 'Tere!' --out /tmp/ezeesti-nk.wav"
