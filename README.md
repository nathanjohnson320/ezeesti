# ezeesti

Offline Estonian learning app for Apple Silicon Macs (M series 1-6).

I made this tool because I don't think learning a language should cost money. If you like it and use it let me know, if there are things that could be improved also let me know. It's AI models, so not guaranteed to be 100% accurate, but for most things it works.

--- ai summary ---

Three modes: **Words** (lemma + form drills), **Tutor** (speak sentences from known vocab), **Translate** (Est→En with grammar notes). Whisper + EstLLM run locally via OMLX.

Inference runs through a required local [OMLX](https://github.com/jundot/omlx) server (OpenAI-compatible chat + transcription APIs). Neurokõne TTS stays optional as a Python CLI.

## Requirements

- macOS 15+, Xcode 16+, Apple Silicon
- [OMLX](https://omlx.ai/) installed and running (`brew tap jundot/omlx https://github.com/jundot/omlx && brew install jundot/omlx/omlx`)
- Disk for models: roughly ~7 GB with EstLLM 8B 4-bit + Whisper, or much more when converting EstLLM 70B (≥48 GiB RAM). Conversion also needs temporary Hugging Face download space.
- `brew install cmake git python@3.10` (Neurokõne only; see below)

Neurokõne needs Python 3.9–3.11 specifically — TensorFlow 2.13 publishes no wheels for 3.12+. A newer default `python3` will fail with `No matching distribution found for tensorflow`.

## Easy setup

### 1. Install OMLX + convert models

```bash
brew tap jundot/omlx https://github.com/jundot/omlx
brew install jundot/omlx/omlx

chmod +x Scripts/*.sh
# Without TartuNLP HF access (recommended default for local bring-up):
SKIP_TTS=1 ./Scripts/fetch-models.sh   # Whisper + EstLLM MLX; Hear uses macOS speech
# Optional Neurokõne later (gated tartuNLP/fastpitch-est — needs approved access + token):
#   export HF_TOKEN=hf_…
#   ./Scripts/fetch-models.sh && ./Scripts/setup-neurokone.sh
```

`fetch-models.sh` picks EstLLM by physical RAM (`EZEESTI_LLM=auto`, default):

| RAM | Model | Notes |
| --- | --- | --- |
| ≥48 GiB | `Llama-3.1-EstLLM-70B-Instruct-0826-4bit` | Large HF download + MLX convert |
| &lt;48 GiB | `Llama-3.1-EstLLM-8B-Instruct-1125-4bit` | Default |

Override with `EZEESTI_LLM=8b|70b|both`, or point at a custom MLX directory with `EZEESTI_LLM_DIR=/path/to/model`. The app resolves the best *installed* EstLLM directory the same way at launch.

Everything lands in `~/Library/Application Support/Ezeesti/Models/`. Whisper is converted from [TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604](https://huggingface.co/TalTechNLP/whisper-large-v3-turbo-et-verbatim-2604); EstLLM from the tartuNLP Hugging Face instruct checkpoints via `mlx_lm.convert`.

### 2. Start OMLX

```bash
omlx serve --model-dir "$HOME/Library/Application Support/Ezeesti/Models"
# Confirm IDs:
curl -s http://127.0.0.1:8000/v1/models | python3 -m json.tool
```

Optional env overrides for the app: `EZEESTI_OMLX_BASE_URL` (default `http://127.0.0.1:8000/v1`), `EZEESTI_OMLX_API_KEY`, `EZEESTI_OMLX_LLM_MODEL`, `EZEESTI_OMLX_STT_MODEL`.

If OMLX auth is enabled (default in the macOS app), Ezeesti reads the API key from `~/.omlx/settings.json` automatically. Override with `EZEESTI_OMLX_API_KEY` if needed (Xcode scheme → Run → Arguments → Environment Variables).

### 3. Run the app

```bash
xcodegen generate      # only if Ezeesti.xcodeproj is missing
open Ezeesti.xcodeproj
```

Run the **Ezeesti** scheme. The app checks OMLX for Whisper + EstLLM, then warms Neurokõne when installed. First **Hear target** playback is slow while TensorFlow / HiFi-GAN load.

## Optional data refresh

These are prebuilt and committed; only regenerate if you want to update them.

```bash
./Scripts/fetch-lexicon.sh                 # ~10k CEFR-first Estonian word list
./Scripts/generate-glosses.sh              # English glosses via OMLX EstLLM (A1–B2 + graded text)
./Scripts/generate-glosses.sh --limit 40   # smoke test
```

The lexicon is a dictionary catalog, not "known" vocabulary — your known % still starts at 0. Source: [Estonian-Wordlist-Enriched-Ekilex](https://github.com/KristjanPikhof/Estonian-Wordlist-Enriched-Ekilex) (CC-BY-SA 4.0).

## Architecture

```
App/                 SwiftUI macOS entry
Sources/
  EzeestiCore/       CEFR, lexicon, model paths, OMLX client
  EzeestiASR/        mic + OMLX /v1/audio/transcriptions
  EzeestiLLM/        EstLLM prompts + OMLX /v1/chat/completions
  EzeestiTTS/        Neurokõne CLI
  EzeestiLearning/   vocab store + Learn session engine
  EzeestiTutor/      model warmup (+ unused drill engine for later)
  EzeestiUI/         Learn UI
Scripts/             model convert, lexicon, gloss, and TTS setup
```

ASR and the tutor LLM talk to a **required local OMLX server** over HTTP. Converted MLX weights stay on disk in Application Support. Neurokõne TTS runs as a Python CLI when installed; otherwise macOS speech is used.

## License notes

- TalTech Whisper fine-tune: MIT (verify card before distribution)
- EstLLM (Llama 3.1): Llama 3.1 Community License
- Neurokõne / Tartu TTS: check release terms before App Store shipping
