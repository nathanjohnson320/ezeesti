# Architecture

## Product decision (locked)

**Speech-first learning.** No writing requirement. Production is always spoken.

Core systems:

- Vocab DB (lemma, forms seen, familiarity)
- Graded input (~90%+ known words)
- FSRS scheduling for flagged / weak words
- Whisper ASR + EstLLM grading of spoken output

## Target learning loop

```text
[Optional] FSRS due cards — speak the word/sentence, grade recall
        │
        ▼
Open graded Estonian text (~90%+ known vs vocab DB)
        │
        ▼
Parse tokens / lemmas; highlight likely unknowns
        │
        ▼
User reads (silently or aloud) and taps true unknown words
        │
        ▼
Unknowns → FSRS deck (lemma + form + sentence context)
        │
        ▼
LLM prompt: “Summarize this text in spoken Estonian.
             You must use: [new words]. Keep it A2 / short.”
        │
        ▼
User SPEAKS the summary (mic)
        │
        ▼
Whisper → transcript
        │
        ▼
Grade:
  - Did they use the required new words?
  - Grammar / case “why” feedback (EstLLM)
  - Pronunciation mismatch vs target forms (later)
        │
        ▼
Update vocab DB + FSRS (Again / Hard / Good / Easy
  from how well they produced the words in speech)
        │
        ▼
Hear model correction → retry speaking if needed
```

## What exists today (v0 scaffold)

1. Fixed lesson sentence + tip
2. Record → ASR (mock or Whisper CLI)
3. Tutor grammar feedback (rules or EstLLM)
4. Hear correction → retry / next sibling

No vocab DB, FSRS, or graded reading yet.

## Model loading

`TutorEngine` checks Application Support paths on launch:

- whisper ggml + whisper-cli → real ASR
- EstLLM GGUF + llama-cli → real tutor
- otherwise mocks / rules so UI development is unblocked

Only one heavy model needs to be hot at a time for the turn-based loop.

## Next build slices

1. SwiftData vocab DB (lemma, status: unknown / learning / known)
2. Graded text packs + token highlight + tap-to-flag
3. FSRS scheduler (open algorithm; card = word-in-context)
4. Spoken summary prompt + ASR grade (must-use words + grammar)
5. Session start = FSRS speech review, then new text

## Later

- Embed whisper.cpp / llama.cpp XCFrameworks (drop CLI)
- Real Neurokõne inference
- Morph analyzer (Vabamorf) for better lemma matching
- Phoneme-level pronunciation coaching
