# Architecture

## Product decision

**Speech-first learning.** Production is always spoken (no writing).

## Learning loop (implemented)

1. Progress tracks known/learning lemmas; only word state is persisted (SwiftData `VocabCard`)
2. Each load drafts an ephemeral graded passage around **1–2 content lemmas** (noun/verb/adjective) at the working CEFR band — a short everyday scene, not a vocabulary list
3. Due flagged/weak words surface as FSRS review; known words are never retargeted
4. Tap a word → English gloss (bundled, cached, or EstLLM on demand) + CEFR/POS; flag only what you need help with
5. From reading, **Record summary** starts the mic immediately (required words shown on the reading page); stop to grade with Whisper + EstLLM
6. Perfect grade → those required lemmas become **known immediately**; imperfect → FSRS Again/Good while staying `.learning` until graduation
7. After a perfect Done, the next passage is generated from leftover words

The app home is **Learn only**. There is no hardcoded text catalog and no disk cache of passages — texts live only in the current session.

`EzeestiTutor` / lesson packs remain in the tree for warmup and possible later pattern drills generated from the 10k lexicon + EstLLM.

## Modules

| Module | Role |
|---|---|
| `EzeestiCore` | FSRS, tokenizer, graded text types, lexicon, lesson packs |
| `EzeestiLearning` | SwiftData vocab store, `LearningEngine` |
| `EzeestiTutor` | Warmup + unused drill engine (kept for reuse) |
| ASR / LLM / TTS | Used by Learn |

## Models

Application Support `Ezeesti/Models/`: Whisper ggml, EstLLM GGUF, native dylibs, Neurokõne CLI when available.

## Later

- One shared Whisper/EstLLM instance (warmup currently on TutorEngine)
- Vabamorf lemmas
- Phoneme pronunciation coaching
