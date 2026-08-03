#!/usr/bin/env bash
# Pre-generate English glosses with local EstLLM (one model load) and merge into the bundle.
#
# Usage:
#   ./Scripts/generate-glosses.sh                 # A1–B2 + graded-text surfaces
#   ./Scripts/generate-glosses.sh --limit 40       # smoke test
#   ./Scripts/generate-glosses.sh --batch 25       # words per EstLLM call (default 20)
#   ./Scripts/generate-glosses.sh --cefr A1,A2     # subset of bands
#
# Requires Models from ./Scripts/fetch-models.sh (libEzeestiLlama + EstLLM GGUF).
# Resumes: skips lemmas already in word-glosses.json.
# Progress: prints live ETA + writes .cache/gloss-gen/progress.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="${EZEESTI_MODELS:-$HOME/Library/Application Support/Ezeesti/Models}"
LIB_DIR="$MODELS/native/llama/lib"
DYLIB="$LIB_DIR/libEzeestiLlama.dylib"
GGUF="$MODELS/llm/Llama-3.1-EstLLM-8B-Instruct-1125.Q4_K_M.gguf"
LEXICON="$ROOT/Sources/EzeestiCore/Resources/Lexicon/estonian-top10k.json"
OUT="$ROOT/Sources/EzeestiCore/Resources/Lexicon/word-glosses.json"
TEXTS_DIR="$ROOT/Sources/EzeestiCore/Resources/Texts"
CACHE="$ROOT/.cache/gloss-gen"
CEFR_FILTER="${CEFR:-A1,A2,B1,B2}"
LIMIT="${LIMIT:-0}"
BATCH="${BATCH:-20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --batch) BATCH="$2"; shift 2 ;;
    --cefr) CEFR_FILTER="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$DYLIB" ]]; then
  echo "Missing $DYLIB — run ./Scripts/fetch-models.sh" >&2
  exit 1
fi
if [[ ! -f "$GGUF" ]]; then
  echo "Missing EstLLM GGUF at $GGUF — run ./Scripts/fetch-models.sh" >&2
  exit 1
fi
if [[ ! -f "$LEXICON" ]]; then
  echo "Missing lexicon $LEXICON — run ./Scripts/fetch-lexicon.sh" >&2
  exit 1
fi

mkdir -p "$CACHE"

export ROOT LEXICON OUT TEXTS_DIR CACHE CEFR_FILTER LIMIT BATCH LIB_DIR DYLIB GGUF

# Ensure ggml/llama dylibs resolve when ctypes loads the umbrella.
export DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$LIB_DIR${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"

python3 << 'PY'
import ctypes
import json
import os
import re
import sys
import time
from pathlib import Path

lexicon = json.loads(Path(os.environ["LEXICON"]).read_text(encoding="utf-8"))
out_path = Path(os.environ["OUT"])
texts_dir = Path(os.environ["TEXTS_DIR"])
cache = Path(os.environ["CACHE"])
log_path = cache / "progress.log"
cefr_allow = {x.strip().upper() for x in os.environ["CEFR_FILTER"].split(",") if x.strip()}
limit = int(os.environ["LIMIT"])
batch_size = max(1, int(os.environ["BATCH"]))
lib_dir = Path(os.environ["LIB_DIR"])
dylib = Path(os.environ["DYLIB"])
gguf = Path(os.environ["GGUF"])

existing = {}
if out_path.exists():
    existing = json.loads(out_path.read_text(encoding="utf-8"))

SYSTEM = """You are a concise Estonian–English dictionary for language learners.
Always respond with ONLY valid JSON object mapping each lemma to a short English gloss.
Example: {"ma":"I","kohv":"coffee"}
Keep each gloss under 12 words. Prefer the most common learner sense.
Do not wrap the JSON in markdown fences. No other keys or commentary."""


def log(msg: str) -> None:
    line = f"{time.strftime('%H:%M:%S')}  {msg}"
    print(line, flush=True)
    with log_path.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def normalize(w: str) -> str:
    return w.strip().casefold()


def collect_targets():
    surfaces = []
    seen = set()
    for path in sorted(texts_dir.glob("text-*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        body = data.get("body") or ""
        for w in re.findall(r"[A-Za-zÄÖÜÕäöüõšžŠŽ\-]+", body):
            key = normalize(w)
            if key in seen or key in existing:
                continue
            seen.add(key)
            surfaces.append({"lemma": key, "surface": w, "cefr": data.get("cefr"), "pos": ""})

    for entry in lexicon.get("words", []):
        level = (entry.get("cefr") or "").upper()
        if level not in cefr_allow:
            continue
        lemma = normalize(entry["lemma"])
        if lemma in seen or lemma in existing:
            continue
        seen.add(lemma)
        surfaces.append(
            {
                "lemma": lemma,
                "surface": entry["lemma"],
                "cefr": level or None,
                "pos": entry.get("pos") or "",
            }
        )
    return surfaces


def chunks(items, n):
    for i in range(0, len(items), n):
        yield items[i : i + n]


def build_prompt(batch) -> str:
    lines = ["Gloss these Estonian words:", ""]
    for i, item in enumerate(batch, 1):
        meta = []
        if item.get("cefr"):
            meta.append(item["cefr"])
        if item.get("pos"):
            meta.append(item["pos"])
        suffix = f" ({', '.join(meta)})" if meta else ""
        lines.append(f"{i}. {item['lemma']}{suffix}")
    lines.append("")
    lines.append('Reply with JSON only, like {"lemma":"english gloss", ...}')
    user = "\n".join(lines)
    return (
        "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
        f"{SYSTEM}<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n"
        f"{user}<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
    )


def extract_json_object(text: str) -> dict | None:
    text = text.strip()
    if text.startswith("```"):
        text = text.replace("```json", "").replace("```", "").strip()
    # Prefer last balanced {...} in case of preamble.
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        return None
    blob = text[start : end + 1]
    try:
        data = json.loads(blob)
        if isinstance(data, dict):
            return data
    except json.JSONDecodeError:
        pass
    # Tolerate single quotes / trailing commas lightly via regex pairs.
    pairs = re.findall(r"\"([^\"]+)\"\s*:\s*\"([^\"]*)\"", blob)
    if pairs:
        return {k: v for k, v in pairs}
    return None


class EstLLM:
    """Load EstLLM once via libEzeestiLlama; keep weights resident across batches."""

    def __init__(self, dylib_path: Path, lib_dir: Path, model_path: Path):
        # Preload deps so dlopen of the umbrella resolves ggml/llama.
        self._deps = []
        for name in sorted(lib_dir.glob("libggml*.dylib")) + sorted(lib_dir.glob("libllama*.dylib")):
            if "Ezeesti" in name.name:
                continue
            try:
                self._deps.append(ctypes.CDLL(str(name), mode=ctypes.RTLD_GLOBAL))
            except OSError:
                pass
        self.lib = ctypes.CDLL(str(dylib_path))
        self.lib.ezeesti_llama_load.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
        ]
        self.lib.ezeesti_llama_load.restype = ctypes.c_int
        self.lib.ezeesti_llama_unload.argtypes = []
        self.lib.ezeesti_llama_unload.restype = None
        self.lib.ezeesti_llama_complete.argtypes = [
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_float,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
        ]
        self.lib.ezeesti_llama_complete.restype = ctypes.c_int
        self.model_path = model_path
        self.lib_dir = lib_dir

    def load(self) -> None:
        err = ctypes.create_string_buffer(1024)
        rc = self.lib.ezeesti_llama_load(
            str(self.lib_dir).encode(),
            str(self.model_path).encode(),
            2048,
            err,
            1024,
        )
        if rc != 0:
            raise RuntimeError(err.value.decode(errors="replace") or "load failed")

    def complete(self, prompt: str, n_predict: int = 768, temperature: float = 0.2) -> str:
        err = ctypes.create_string_buffer(1024)
        out = ctypes.create_string_buffer(65536)
        rc = self.lib.ezeesti_llama_complete(
            prompt.encode(),
            int(n_predict),
            float(temperature),
            out,
            65536,
            err,
            1024,
        )
        if rc != 0:
            raise RuntimeError(err.value.decode(errors="replace") or "complete failed")
        raw = out.value.decode(errors="replace")
        return raw.split("<|eot_id|>")[0].strip()

    def unload(self) -> None:
        self.lib.ezeesti_llama_unload()


targets = collect_targets()
if limit > 0:
    targets = targets[:limit]

batches = list(chunks(targets, batch_size))
log_path.write_text("", encoding="utf-8")
log(
    f"Plan: {len(targets)} words in {len(batches)} batches "
    f"(batch={batch_size}, existing={len(existing)}, cefr={sorted(cefr_allow)})"
)
log(f"Model: {gguf.name}")
log(f"Output: {out_path}")
log(f"Progress log: {log_path}")

if not targets:
    log("Nothing to do — catalog already covers the filter.")
    sys.exit(0)

llm = EstLLM(dylib, lib_dir, gguf)
log("Loading EstLLM into Metal once (this can take 30–90s)…")
t0 = time.time()
llm.load()
log(f"Model ready in {time.time() - t0:.1f}s — keeping it loaded for all batches")

updated = dict(existing)
failures = 0
ok_words = 0
batch_times: list[float] = []
run_start = time.time()

try:
    for bi, batch in enumerate(batches, 1):
        labels = ", ".join(x["surface"] for x in batch[:5])
        if len(batch) > 5:
            labels += f", … (+{len(batch) - 5})"
        log(f"Batch {bi}/{len(batches)} — {len(batch)} words: {labels}")

        # ETA from completed batches.
        if batch_times:
            avg = sum(batch_times) / len(batch_times)
            remaining = avg * (len(batches) - bi + 1)
            log(f"  ETA ~{remaining / 60:.1f} min ({avg:.1f}s/batch avg)")

        prompt = build_prompt(batch)
        # ~25 tokens per gloss JSON entry; pad for safety.
        n_predict = min(2048, max(256, 40 * len(batch)))
        t_batch = time.time()
        try:
            raw = llm.complete(prompt, n_predict=n_predict)
        except Exception as e:
            failures += len(batch)
            fail_path = cache / f"fail-batch-{bi}.txt"
            fail_path.write_text(str(e), encoding="utf-8")
            log(f"  ! batch failed: {e} (see {fail_path})")
            continue

        elapsed = time.time() - t_batch
        batch_times.append(elapsed)
        parsed = extract_json_object(raw) or {}
        # Normalize keys from model.
        parsed_norm = {normalize(k): str(v).strip() for k, v in parsed.items() if str(v).strip()}

        got = 0
        missing = []
        for item in batch:
            lemma = item["lemma"]
            gloss = parsed_norm.get(lemma) or parsed_norm.get(normalize(item["surface"]))
            if not gloss:
                missing.append(lemma)
                continue
            updated[lemma] = gloss
            got += 1
            ok_words += 1

        if missing:
            failures += len(missing)
            # One-at-a-time retry for misses while model is still loaded.
            log(f"  retrying {len(missing)} misses individually…")
            for lemma in missing:
                item = next(x for x in batch if x["lemma"] == lemma)
                single_prompt = build_prompt([item])
                try:
                    raw1 = llm.complete(single_prompt, n_predict=96)
                    one = extract_json_object(raw1) or {}
                    one_norm = {normalize(k): str(v).strip() for k, v in one.items() if str(v).strip()}
                    gloss = one_norm.get(lemma) or next(iter(one_norm.values()), None)
                    if gloss:
                        updated[lemma] = gloss
                        got += 1
                        ok_words += 1
                        failures -= 1
                        log(f"    ✓ {lemma} → {gloss}")
                    else:
                        (cache / f"fail-{lemma}.txt").write_text(raw1[-2000:], encoding="utf-8")
                        log(f"    ✗ {lemma}")
                except Exception as e:
                    log(f"    ✗ {lemma}: {e}")

        log(
            f"  → {got}/{len(batch)} glosses in {elapsed:.1f}s "
            f"(catalog={len(updated)}, ok={ok_words}, fail={failures})"
        )

        # Checkpoint after every batch so Ctrl-C is safe.
        out_path.write_text(
            json.dumps(dict(sorted(updated.items())), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        # Also dump raw response for debugging odd batches.
        (cache / f"raw-batch-{bi}.txt").write_text(raw[-8000:], encoding="utf-8")
finally:
    log("Unloading EstLLM…")
    llm.unload()

total = time.time() - run_start
log(
    f"Done in {total / 60:.1f} min — wrote {out_path} "
    f"({len(updated)} glosses, +{ok_words} new, {failures} failures)"
)
PY

echo
echo "Rebuild the app to pick up Resources/Lexicon/word-glosses.json"
echo "Live log also at: $CACHE/progress.log"
echo "Runtime EstLLM glossing remains as a fallback for words not in the bundle."
