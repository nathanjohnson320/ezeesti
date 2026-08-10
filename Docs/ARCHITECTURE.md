# Architecture

## Product decision

**Speech-first learning.** Production is always spoken (no writing).

## Learning loop (implemented)

1. Progress tracks known/learning lemmas; only word state is persisted (SwiftData `VocabCard`). Start = **0 known** at A1.
2. Each load drafts one ephemeral sentence around **one** content lemma (prefer a due word, then learning, then an unknown noun/verb/adjective at the working CEFR band). Prefer ~8–16 words so the sentence is speakable and useful. A second LLM pass **validates or rewrites** the draft before it is shown.
3. Due words (including known words whose backoff interval has elapsed) surface via sidebar review, which generates a sentence with those focus words and uses the same read-aloud path.
4. Tap a word → English gloss (bundled, cached, or EstLLM on demand) + CEFR/POS; flag only what you need help with.
5. From reading, **Read aloud** starts the mic; stop to grade the transcript against the target sentence (Whisper + EstLLM). Feedback includes pronunciation/phrasing tips.
6. Correct + unflagged focus lemmas → **known** with exponential backoff (1 → 2 → 4 → … days, capped at 180). Flagged or incorrect focus lemmas stay **learning** and are due soon.
7. After a perfect Done, the next sentence is generated from leftover / due words.

The app home is **Learn only**. There is no hardcoded text catalog and no disk cache of passages — sentences live only in the current session.

`EzeestiTutor` / lesson packs remain in the tree for warmup and possible later pattern drills generated from the 10k lexicon + EstLLM.

## Modules

| Module | Role |
|---|---|
| `EzeestiCore` | Tokenizer, graded text types, lexicon, exponential backoff helpers, lesson packs |
| `EzeestiLearning` | SwiftData vocab store, `LearningEngine` |
| `EzeestiTutor` | Warmup + unused drill engine (kept for reuse) |
| ASR / LLM / TTS | Used by Learn |

## Models

Application Support `Ezeesti/Models/`: Whisper ggml, EstLLM GGUF, native dylibs, Neurokõne CLI when available.

## Later

- One shared Whisper/EstLLM instance (warmup currently on TutorEngine)
- Vabamorf lemmas
- Phoneme pronunciation coaching
