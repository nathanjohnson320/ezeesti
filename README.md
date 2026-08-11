# ezeesti

Offline Estonian learning app for Apple Silicon Macs (M1–M4).

Speak → Whisper transcribes → EstLLM explains the grammar "why" → hear the correction → retry.

## Requirements

- macOS 14+, Xcode 16+, Apple Silicon
- ~7 GB free disk for models
- `brew install cmake git python@3.10`

Neurokõne needs Python 3.9–3.11 specifically — TensorFlow 2.13 publishes no wheels for 3.12+. A newer default `python3` will fail with `No matching distribution found for tensorflow`.

## Easy setup

### 1. Install models

```bash
chmod +x Scripts/*.sh
./Scripts/fetch-models.sh       # Whisper + EstLLM weights + in-process dylibs (~7 GB, needs cmake)
./Scripts/setup-neurokone.sh    # one-time Python venv for Neurokõne TTS (needs python3.10)
```

Everything lands in `~/Library/Application Support/Ezeesti/Models/`.

> Already ran `fetch-models.sh`? Don't re-run it for TTS — just run `setup-neurokone.sh`.

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
