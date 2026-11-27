#!/usr/bin/env bash
# Pre-generate English glosses via OMLX EstLLM chat completions and merge into the bundle.
#
# Usage:
#   ./Scripts/generate-glosses.sh                 # A1–B2 + graded-text surfaces
#   ./Scripts/generate-glosses.sh --limit 40       # smoke test
#   ./Scripts/generate-glosses.sh --batch 25       # words per EstLLM call (default 20)
#   ./Scripts/generate-glosses.sh --cefr A1,A2     # subset of bands
#
# Requires: OMLX serving EstLLM (see Scripts/fetch-models.sh), then:
#   omlx serve --model-dir "$HOME/Library/Application Support/Ezeesti/Models"
# Resumes: skips lemmas already in word-glosses.json.
# Progress: prints live ETA + writes .cache/gloss-gen/progress.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="${EZEESTI_MODELS:-$HOME/Library/Application Support/Ezeesti/Models}"
LLM_DIR="$MODELS/llm"
LLM_70B_DIR="Llama-3.1-EstLLM-70B-Instruct-0826-4bit"
LLM_8B_DIR="Llama-3.1-EstLLM-8B-Instruct-1125-4bit"
LLM_70B_MIN_GIB=48
OMLX_BASE="${EZEESTI_OMLX_BASE_URL:-http://127.0.0.1:8000/v1}"
LEXICON="$ROOT/Sources/EzeestiCore/Resources/Lexicon/estonian-top10k.json"
OUT="$ROOT/Sources/EzeestiCore/Resources/Lexicon/word-glosses.json"
TEXTS_DIR="$ROOT/Sources/EzeestiCore/Resources/Texts"
CACHE="$ROOT/.cache/gloss-gen"
CEFR_FILTER="${CEFR:-A1,A2,B1,B2}"
LIMIT="${LIMIT:-0}"
BATCH="${BATCH:-20}"

physical_ram_gib() {
  local bytes
  bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  echo $(( bytes / 1024 / 1024 / 1024 ))
}

# Mirror ModelPaths.resolveEstLLMDirectory: override → best fit for RAM → largest installed.
resolve_llm_model_id() {
  if [[ -n "${EZEESTI_OMLX_LLM_MODEL:-}" ]]; then
    echo "${EZEESTI_OMLX_LLM_MODEL}"
    return
  fi
  if [[ -n "${EZEESTI_LLM_DIR:-}" && -d "${EZEESTI_LLM_DIR}" ]]; then
    basename "${EZEESTI_LLM_DIR}"
    return
  fi
  local gib
  gib="$(physical_ram_gib)"
  local best_fit="" best_any=""
  if [[ -d "$LLM_DIR/$LLM_70B_DIR" ]]; then
    best_any="$LLM_70B_DIR"
    if [[ "$gib" -ge "$LLM_70B_MIN_GIB" ]]; then
      best_fit="$LLM_70B_DIR"
    fi
  fi
  if [[ -d "$LLM_DIR/$LLM_8B_DIR" ]]; then
    [[ -n "$best_any" ]] || best_any="$LLM_8B_DIR"
    if [[ -z "$best_fit" ]]; then
      best_fit="$LLM_8B_DIR"
    fi
  fi
  echo "${best_fit:-$best_any}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --batch) BATCH="$2"; shift 2 ;;
    --cefr) CEFR_FILTER="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

LLM_MODEL="$(resolve_llm_model_id)"

if [[ -z "$LLM_MODEL" ]]; then
  echo "Missing EstLLM MLX under $LLM_DIR — run ./Scripts/fetch-models.sh" >&2
  exit 1
fi
if [[ ! -f "$LEXICON" ]]; then
  echo "Missing lexicon $LEXICON — run ./Scripts/fetch-lexicon.sh" >&2
  exit 1
fi

echo "Using OMLX model id: $LLM_MODEL @ $OMLX_BASE"
if ! curl -sf "${OMLX_BASE}/models" >/dev/null; then
  echo "OMLX not reachable at ${OMLX_BASE} — start with:" >&2
  echo "  omlx serve --model-dir \"$MODELS\"" >&2
  exit 1
fi

mkdir -p "$CACHE"

export ROOT LEXICON OUT TEXTS_DIR CACHE CEFR_FILTER LIMIT BATCH OMLX_BASE LLM_MODEL

python3 << 'PY'
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

lexicon = json.loads(Path(os.environ["LEXICON"]).read_text(encoding="utf-8"))
out_path = Path(os.environ["OUT"])
texts_dir = Path(os.environ["TEXTS_DIR"])
cache = Path(os.environ["CACHE"])
log_path = cache / "progress.log"
cefr_allow = {x.strip().upper() for x in os.environ["CEFR_FILTER"].split(",") if x.strip()}
limit = int(os.environ["LIMIT"])
batch_size = max(1, int(os.environ["BATCH"]))
omlx_base = os.environ["OMLX_BASE"].rstrip("/")
llm_model = os.environ["LLM_MODEL"]
api_key = os.environ.get("EZEESTI_OMLX_API_KEY") or os.environ.get("OMLX_API_KEY") or ""

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


def build_user(batch) -> str:
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
    return "\n".join(lines)


def extract_json_object(text: str) -> dict | None:
    text = text.strip()
    if text.startswith("```"):
        text = text.replace("```json", "").replace("```", "").strip()
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
    pairs = re.findall(r"\"([^\"]+)\"\s*:\s*\"([^\"]*)\"", blob)
    if pairs:
        return {k: v for k, v in pairs}
    return None


class EstLLM:
    """Chat completions against a required local OMLX server."""

    def __init__(self, base: str, model: str, api_key: str = ""):
        self.base = base.rstrip("/")
        self.model = model
        self.api_key = api_key

    def complete(self, user: str, max_tokens: int = 768, temperature: float = 0.2) -> str:
        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": user},
            ],
            "max_tokens": int(max_tokens),
            "temperature": float(temperature),
            "stream": False,
        }
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            f"{self.base}/chat/completions",
            data=data,
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        if self.api_key:
            req.add_header("Authorization", f"Bearer {self.api_key}")
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                payload = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            raise RuntimeError(f"OMLX HTTP {e.code}: {detail[:500]}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"OMLX unreachable: {e}") from e

        choices = payload.get("choices") or []
        if not choices:
            raise RuntimeError("OMLX returned no choices")
        content = (choices[0].get("message") or {}).get("content") or ""
        return content.strip()


targets = collect_targets()
if limit > 0:
    targets = targets[:limit]

batches = list(chunks(targets, batch_size))
log_path.write_text("", encoding="utf-8")
log(
    f"Plan: {len(targets)} words in {len(batches)} batches "
    f"(batch={batch_size}, existing={len(existing)}, cefr={sorted(cefr_allow)})"
)
log(f"Model: {llm_model} @ {omlx_base}")
log(f"Output: {out_path}")
log(f"Progress log: {log_path}")

if not targets:
    log("Nothing to do — catalog already covers the filter.")
    sys.exit(0)

llm = EstLLM(omlx_base, llm_model, api_key)
log("Checking OMLX…")
t0 = time.time()
_ = llm.complete('Reply with JSON only: {"ping":"pong"}', max_tokens=32)
log(f"OMLX ready in {time.time() - t0:.1f}s")

updated = dict(existing)
failures = 0
ok_words = 0
batch_times: list[float] = []
run_start = time.time()

for bi, batch in enumerate(batches, 1):
    labels = ", ".join(x["surface"] for x in batch[:5])
    if len(batch) > 5:
        labels += f", … (+{len(batch) - 5})"
    log(f"Batch {bi}/{len(batches)} — {len(batch)} words: {labels}")

    if batch_times:
        avg = sum(batch_times) / len(batch_times)
        remaining = avg * (len(batches) - bi + 1)
        log(f"  ETA ~{remaining / 60:.1f} min ({avg:.1f}s/batch avg)")

    user = build_user(batch)
    n_predict = min(2048, max(256, 40 * len(batch)))
    t_batch = time.time()
    try:
        raw = llm.complete(user, max_tokens=n_predict)
    except Exception as e:
        failures += len(batch)
        fail_path = cache / f"fail-batch-{bi}.txt"
        fail_path.write_text(str(e), encoding="utf-8")
        log(f"  ! batch failed: {e} (see {fail_path})")
        continue

    elapsed = time.time() - t_batch
    batch_times.append(elapsed)
    parsed = extract_json_object(raw) or {}
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
        log(f"  retrying {len(missing)} misses individually…")
        for lemma in missing:
            item = next(x for x in batch if x["lemma"] == lemma)
            try:
                raw1 = llm.complete(build_user([item]), max_tokens=96)
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

    out_path.write_text(
        json.dumps(dict(sorted(updated.items())), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (cache / f"raw-batch-{bi}.txt").write_text(raw[-8000:], encoding="utf-8")

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
