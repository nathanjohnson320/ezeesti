# Architecture

## Product decision

**Speech-first learning.** Production is always spoken (no writing).

## Learning loop (implemented)

1. Progress tracks known/learning lemmas in the background and estimates a working CEFR band
2. Due flagged words surface as review (speak + FSRS); nothing to pick from a lesson list
3. Recommended graded text continues at your level; all texts stay under a disclosure
4. Tap a word → English gloss (bundled, cached, or EstLLM on demand) + CEFR/POS; flag only what you need help with
5. Speak a short summary using flagged words; Whisper + EstLLM grade; FSRS updates

The app home is **Learn only**. Fixed-sentence Drill packs (~handful of lines) were removed from the UI — they don’t use the lexicon corpus and aren’t a curriculum.

`EzeestiTutor` / lesson packs remain in the tree for warmup and possible later pattern drills generated from the 10k lexicon + EstLLM.

## Modules

| Module | Role |
|---|---|
| `EzeestiCore` | FSRS, tokenizer, graded texts, lexicon, lesson packs |
| `EzeestiLearning` | SwiftData vocab store, `LearningEngine` |
| `EzeestiTutor` | Warmup + unused drill engine (kept for reuse) |
| ASR / LLM / TTS | Used by Learn |

## Models

Application Support `Ezeesti/Models/`: Whisper ggml, EstLLM GGUF, native dylibs, Neurokõne CLI when available.

## Later

- One shared Whisper/EstLLM instance (warmup currently on TutorEngine)
- More graded texts / EstLLM-generated passages from lexicon
- Vabamorf lemmas
- Phoneme pronunciation coaching
