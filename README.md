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

## Full offline stack

```bash
chmod +x Scripts/fetch-models.sh Scripts/setup-neurokone.sh
./Scripts/fetch-models.sh          # Whisper + EstLLM + TTS weights + CLIs (~7GB)
./Scripts/setup-neurokone.sh       # Python venv for Neurokõne (one-time; needs python3.10)
```

If you already ran `fetch-models.sh`, **do not re-run it** for TTS weights — just run `setup-neurokone.sh`.

Models land in:

`~/Library/Application Support/Ezeesti/Models/`

Then rebuild/run the app — it auto-detects Whisper, EstLLM, and `neurokone-cli`.

**Hear target** uses Neurokõne (speaker `mari`). First play can take a while while TensorFlow / HiFi-GAN load.

## Architecture

```
App/                 SwiftUI macOS entry
Sources/
  EzeestiCore/       lessons, CEFR, model paths
  EzeestiASR/        mic + whisper.cpp CLI bridge
  EzeestiLLM/        EstLLM prompts + llama.cpp CLI bridge
  EzeestiTTS/        system voice (+ Neurokõne placeholder)
  EzeestiTutor/      speak → analyze → retry engine
  EzeestiUI/         lesson list + practice screen
Scripts/fetch-models.sh
```

MVP keeps ASR/LLM as **CLI process bridges** so the learning loop ships before XCFramework embedding.

## License notes

- TalTech Whisper fine-tune: MIT (verify card before distribution)
- EstLLM Llama line: Llama 3.1 Community License
- Neurokõne / Tartu TTS: check release terms before App Store shipping
