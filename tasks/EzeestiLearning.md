# EzeestiLearning – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## LearningEngine.swift
- [~] `@MainActor` on UI class drives SwiftData access, Whisper/LLM calls and file I/O – blocks main thread. *(UI observation stays MainActor; heavy work should stay behind actors/services)*
- [ ] Fire-and-forget `Task { try? await speaker.prepare() }` discards failures.
- [ ] Extensive `try?` usage hides failures; errors flattened to `String` phase repeatedly.
- [ ] Public API properties/methods lack doc comments.
- [x] Existentials without `Sendable` constraints. *(ASR/LLM protocols are `Sendable`; shared native stack injected from UI)*
- [ ] Silent fallback parsing for sentence validation with no logging.
- [ ] Fuzzy lemma matching with `hasPrefix` overlap checks – error-prone.
- [ ] Hard-coded CEFR fallback logic.
- [x] Mic record/stop use async actor APIs. *(ASR concurrency pass)*
- [x] `shutdownNativeModels()` available for shared recognizer/LLM teardown.

## VocabStore.swift
- [~] `@MainActor` on data layer forces all SwiftData queries onto main thread. *(SwiftData/`ModelContext` is typically main-actor bound; redesign only if off-main contexts are introduced)*
- [ ] `@Model` classes expose public mutable vars – setters should be private/internal.
- [ ] Computed property masks errors by falling back to `.learning`.
- [ ] `modelContext` exposed publicly.
- [ ] Inefficient queries: repeated `fetchAll()` → N+1 scans for cards, known lemmas, due cards.
- [ ] Destructive seeding deletes rows individually with magic threshold `>=9000`.
- [ ] Direct `UserDefaults.standard` coupling inside store layer.
- [ ] Missing doc comments for public API.
- [ ] Silent early returns on bad input.
