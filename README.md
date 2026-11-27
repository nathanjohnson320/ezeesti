# ezeesti

Offline Estonian learning app for Apple Silicon Macs (M1–M4).

Speak → Whisper transcribes → EstLLM explains the grammar "why" → hear the correction → retry.

## Requirements

- macOS 14+, Xcode 16+, Apple Silicon
- Disk for models: ~7 GB with EstLLM 8B, or ~50 GB when auto-selecting EstLLM 70B (≥48 GiB RAM)
- `brew install cmake git python@3.10`

Neurokõne needs Python 3.9–3.11 specifically — TensorFlow 2.13 publishes no wheels for 3.12+. A newer default `python3` will fail with `No matching distribution found for tensorflow`.

## Easy setup

### 1. Install models

```bash
chmod +x Scripts/*.sh
# Without TartuNLP HF access (recommended default for local bring-up):
SKIP_TTS=1 ./Scripts/fetch-models.sh   # Whisper + EstLLM + dylibs; Hear uses macOS speech
# Optional Neurokõne later (gated tartuNLP/fastpitch-est — needs approved access + token):
#   export HF_TOKEN=hf_…
#   ./Scripts/fetch-models.sh && ./Scripts/setup-neurokone.sh
```

`fetch-models.sh` picks EstLLM by physical RAM (`EZEESTI_LLM=auto`, default):

| RAM | Model | Disk |
| --- | --- | --- |
| ≥48 GiB | `Llama-3.1-EstLLM-70B-Instruct-0826` Q4_K_M (~43 GB) | ~50 GB total |
| &lt;48 GiB | `Llama-3.1-EstLLM-8B-Instruct-1125` Q4_K_M (~5 GB) | ~7 GB total |

Override with `EZEESTI_LLM=8b|70b|both`, or point at a custom GGUF with `EZEESTI_LLM_GGUF=/path/to/model.gguf`. The app resolves the best *installed* GGUF the same way at launch.

The 70B file is a community Q4_K_M of [tartuNLP/Llama-3.1-EstLLM-70B-Instruct-0826](https://huggingface.co/tartuNLP/Llama-3.1-EstLLM-70B-Instruct-0826); first load is slower than 8B.

Everything lands in `~/Library/Application Support/Ezeesti/Models/`.

> Already have Whisper/EstLLM weights? You can still run `fetch-models.sh` — it skips existing files — then `setup-neurokone.sh` for the v3.2.0 Python worker.

### 2. Run the app

```bash
xcodegen generate      # only if Ezeesti.xcodeproj is missing
open Ezeesti.xcodeproj
```

Run the **Ezeesti** scheme. The app auto-detects Whisper, EstLLM, and `neurokone-cli`. First **Hear target** playback is slow while TensorFlow / HiFi-GAN load.

## Optional data refresh

These are prebuilt and committed; only regenerate if you want to update them.

```bash
./Scripts/fetch-lexicon.sh                 # ~10k CEFR-first Estonian word list
./Scripts/generate-glosses.sh              # English glosses (A1–B2 + graded text)
./Scripts/generate-glosses.sh --limit 40   # smoke test
```

The lexicon is a dictionary catalog, not "known" vocabulary — your known % still starts at 0. Source: [Estonian-Wordlist-Enriched-Ekilex](https://github.com/KristjanPikhof/Estonian-Wordlist-Enriched-Ekilex) (CC-BY-SA 4.0).

## Architecture

```
App/                 SwiftUI macOS entry
Sources/
  EzeestiCore/       CEFR, lexicon, model paths, lesson packs
  EzeestiASR/        mic + in-process Whisper (dlopen)
  EzeestiLLM/        EstLLM prompts + in-process llama.cpp (dlopen)
  EzeestiTTS/        Neurokõne CLI
  EzeestiLearning/   vocab store + Learn session engine
  EzeestiTutor/      model warmup (+ unused drill engine for later)
  EzeestiUI/         Learn UI
Native/              C bridges compiled into libEzeesti*.dylib by fetch-models.sh
Scripts/             model, lexicon, gloss, and TTS setup
```

ASR and the tutor LLM run **in-process** via Metal-backed dylibs (`libEzeestiWhisper` / `libEzeestiLlama`), each `dlopen`ed with `RTLD_LOCAL` so they keep separate ggml copies. Weights stay on disk in Application Support. Neurokõne TTS runs as a Python CLI.

## License notes

- TalTech Whisper fine-tune: MIT (verify card before distribution)
- EstLLM (Llama 3.1): Llama 3.1 Community License
- Neurokõne / Tartu TTS: check release terms before App Store shipping
