# ezeesti

Offline Estonian learning app for Apple Silicon Macs (M1–M4).

Speak → TalTech Whisper → EstLLM grammar “why” feedback → hear correction → retry.

## Requirements

- macOS 14+
- Xcode 16+
- Apple Silicon recommended
- Optional for full offline AI: `cmake`, `git`, ~7 GB disk for models

## Quick start (UI without models)

```bash
cd ezeesti
xcodegen generate
open Ezeesti.xcodeproj
```

Run the **Ezeesti** scheme. Without models the app uses:

- Mock ASR (canned transcript)
- Rule-based tutor (illative pattern heuristics)
- System speech synthesis

That is enough to exercise the speak → feedback → retry loop.

## Lexicon

Offline word list (~10k) from [Estonian-Wordlist-Enriched-Ekilex](https://github.com/KristjanPikhof/Estonian-Wordlist-Enriched-Ekilex) (CC-BY-SA 4.0): all CEFR-tagged lemmas (A1→C1), then frequency fill to 10k. Refresh with:

```bash
./Scripts/fetch-lexicon.sh
```

This is a **dictionary catalog**, not “known” vocabulary — your known % still starts at 0.

### Packaged English glosses

Ship glosses in `word-glosses.json` so the app does not need to ask EstLLM per tap. Generate offline (loads EstLLM **once**, batches ~20 words/call, resumes safely):

```bash
./Scripts/generate-glosses.sh              # A1–B2 + graded-text words
./Scripts/generate-glosses.sh --limit 40   # smoke test
# progress: terminal + .cache/gloss-gen/progress.log
```


```bash
chmod +x Scripts/fetch-models.sh Scripts/setup-neurokone.sh
./Scripts/fetch-models.sh          # Whisper + EstLLM weights + in-process dylibs (~7GB)
./Scripts/setup-neurokone.sh       # Python venv for Neurokõne (one-time; needs python3.10)
```

If you already ran `fetch-models.sh`, **do not re-run it** for TTS weights — just run `setup-neurokone.sh`.

Models and native libs land in:

`~/Library/Application Support/Ezeesti/Models/`

Then rebuild/run the app — it auto-detects Whisper, EstLLM, and `neurokone-cli`.

**Hear target** uses Neurokõne (speaker `mari`). First play can take a while while TensorFlow / HiFi-GAN load.

## Architecture

```
App/                 SwiftUI macOS entry
Sources/
  EzeestiCore/       lessons, CEFR, model paths
  EzeestiASR/        mic + in-process Whisper (dlopen)
  EzeestiLLM/        EstLLM prompts + in-process llama.cpp (dlopen)
  EzeestiTTS/        system voice (+ Neurokõne CLI)
  EzeestiTutor/      speak → analyze → retry engine
  EzeestiUI/         lesson list + practice screen
Native/              C bridges compiled into libEzeesti*.dylib by fetch-models.sh
Scripts/fetch-models.sh
```

ASR and the tutor LLM run **in-process** via Metal-backed dylibs (`libEzeestiWhisper` / `libEzeestiLlama`), loaded with `dlopen(RTLD_LOCAL)` so each engine keeps its own ggml. Weights stay on disk in Application Support. Neurokõne remains a Python CLI for now.

## License notes

- TalTech Whisper fine-tune: MIT (verify card before distribution)
- EstLLM Llama line: Llama 3.1 Community License
- Neurokõne / Tartu TTS: check release terms before App Store shipping
