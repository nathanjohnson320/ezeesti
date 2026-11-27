# Architecture

## Product decision

**Three modes.** Words teaches lemmas and forms; Tutor practices speaking sentences from known vocabulary; Translate explains Estonian with grammar notes.

## Modes

### Words

1. Progress walks A1→B2 by frequency within the working CEFR band (~70% band coverage before advancing). Teaching stops at B2.
2. Show the next lemma (gloss / POS / CEFR), then ask EstLLM for the top common forms plus a few extras and cloze sentences.
3. Run a short Speakly-style drill queue: chips, typing, and speaking mixed at random.
4. Enough correct forms → **known** with exponential backoff; otherwise stay **learning** and due soon.

### Tutor

1. Builds one ephemeral sentence around a **known / learning / due** lemma only — never introduces brand-new unknowns. Empty until Words has taught something.
2. Tap a word → English gloss; flag hard words; **Read aloud** → Whisper + EstLLM grade.
3. Correct + unflagged focus → known with backoff; flagged/incorrect → learning due soon.

### Translate

Free-form Estonian → English via EstLLM with a phrase-by-phrase breakdown (literal sense + short grammar notes). No progress writes.

## Learning loop details

- Only word state is persisted (SwiftData `VocabCard`). Start = **0 known** at A1.
- Sentences are ephemeral — no hardcoded passage catalog and no disk cache of Tutor drafts.
- Forms for Words come from EstLLM on the fly (no bundled morphology tables yet; Vabamorf later).
- Passage generation is a **single** EstLLM sample gated by local usability checks — no second-pass validation rewrite.

`EzeestiTutor` / lesson packs remain in the tree for warmup and possible later pattern drills.

## Modules

| Module | Role |
|---|---|
| `EzeestiCore` | Tokenizer, graded text types, lexicon, exponential backoff helpers, lesson packs |
| `EzeestiLearning` | SwiftData vocab store, `LearningEngine` (Tutor), `WordsEngine` |
| `EzeestiTutor` | Warmup + unused drill engine (kept for reuse) |
| ASR / LLM / TTS | Used by Words + Tutor |

## Models

Application Support `Ezeesti/Models/` holds converted MLX directories for EstLLM + TalTech Whisper (and Neurokõne CLI when available). A required local OMLX server loads those dirs (`omlx serve --model-dir …`). The app calls `/v1/chat/completions` and `/v1/audio/transcriptions`.

## Later

- Vabamorf lemmas / morphology tables
- Phoneme pronunciation coaching
- Streaming chat completions in the UI
