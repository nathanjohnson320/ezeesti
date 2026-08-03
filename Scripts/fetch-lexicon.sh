#!/usr/bin/env bash
# Rebuild offline Estonian lexicon (CEFR-first ~10k) from public GitHub data.
# Source: https://github.com/KristjanPikhof/Estonian-Wordlist-Enriched-Ekilex
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache/lexicon"
OUT="$ROOT/Sources/EzeestiCore/Resources/Lexicon"
BASE="https://raw.githubusercontent.com/KristjanPikhof/Estonian-Wordlist-Enriched-Ekilex/main/data"

mkdir -p "$CACHE" "$OUT"

curl -L --fail --progress-bar -o "$CACHE/est_words_160k.tsv" "$BASE/est_words_160k.tsv"
curl -L --fail --progress-bar -o "$CACHE/est_proficiency_words.tsv" "$BASE/est_proficiency_words.tsv"

python3 << PY
import csv, json
from pathlib import Path
from collections import Counter

cache = Path("$CACHE")
out = Path("$OUT")

freq, pos_from_main = {}, {}
with (cache / "est_words_160k.tsv").open(encoding="utf-8") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        w = row["word"].strip()
        try:
            fr = int(row["freq_rank"] or 0)
        except ValueError:
            fr = 0
        freq[w] = fr
        if row.get("pos"):
            pos_from_main[w] = row["pos"].strip()

cefr_order = {"A1": 0, "A2": 1, "B1": 2, "B2": 3, "C1": 4}
entries = []
with (cache / "est_proficiency_words.tsv").open(encoding="utf-8") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        w = row["word"].strip()
        level = (row.get("proficiency") or "").strip().upper()
        if level not in cefr_order:
            continue
        fr = freq.get(w, 0)
        entries.append({
            "lemma": w,
            "cefr": level,
            "pos": (row.get("pos") or pos_from_main.get(w) or "").strip(),
            "freqRank": fr if fr > 0 else None,
            "_sort": (cefr_order[level], fr if fr > 0 else 10_000_000, w),
        })

entries.sort(key=lambda e: e["_sort"])
taken = {e["lemma"] for e in entries}
if len(entries) < 10000:
    extras = []
    with (cache / "est_words_160k.tsv").open(encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            w = row["word"].strip()
            if w in taken:
                continue
            try:
                fr = int(row["freq_rank"] or 0)
            except ValueError:
                fr = 0
            if fr <= 0:
                continue
            extras.append({
                "lemma": w,
                "cefr": None,
                "pos": (row.get("pos") or "").strip(),
                "freqRank": fr,
                "_sort": (5, fr, w),
            })
            if len(entries) + len(extras) >= 10000:
                break
    extras.sort(key=lambda e: e["_sort"])
    entries.extend(extras[: 10000 - len(entries)])

for e in entries:
    e.pop("_sort", None)

counts = Counter(e["cefr"] or "none" for e in entries)
payload = {
    "source": "KristjanPikhof/Estonian-Wordlist-Enriched-Ekilex",
    "license": "CC-BY-SA-4.0",
    "attribution": [
        "EKI Ekilex (CC-BY 4.0)",
        "Hermit Dave FrequencyWords / OpenSubtitles (CC-BY-SA 4.0)",
        "Combined by Kristjan Pikhof",
    ],
    "selection": "All CEFR-tagged lemmas (A1→C1), then frequency fill to 10k",
    "count": len(entries),
    "cefrCounts": dict(counts),
    "words": entries,
}
(out / "estonian-top10k.json").write_text(
    json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
    encoding="utf-8",
)
print(f"Wrote {out / 'estonian-top10k.json'} ({len(entries)} words) {dict(counts)}")
PY

echo "Done. Rebuild the app to pick up Resources/Lexicon/estonian-top10k.json"
