# EzeestiLearning – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## LearningEngine.swift
- [x] `@MainActor` on UI class drives SwiftData access, Whisper/LLM calls and file I/O – blocks main thread. *(UI observation stays MainActor; Whisper/LLM/TTS are actors; lexicon seed/cleanup via `VocabBackgroundStore`)*
- [x] Fire-and-forget `Task { try? await speaker.prepare() }` discards failures. *(async `bootstrap()` awaits prepare; failures → `lastSpeakerError`)*
- [x] Extensive `try?` usage hides failures; errors flattened to `String` phase repeatedly. *(progress/familiarity now throw into `phase.error`; Phase still uses String)*
- [x] Public API properties/methods lack doc comments.
- [x] Existentials without `Sendable` constraints. *(ASR/LLM protocols are `Sendable`; shared native stack injected from UI)*
- [x] Silent fallback parsing for sentence validation with no logging. *(surfaces via `generationDetail` when keeping draft)*
- [x] Fuzzy lemma matching with `hasPrefix` overlap checks – error-prone. *(bounded near-match: stem ≥ 3, length Δ ≤ 2)*
- [x] Hard-coded CEFR fallback logic. *(named `maxPassageCEFR` + `passageGenerationLevel`)*
- [x] Mic record/stop use async actor APIs. *(ASR concurrency pass)*
- [x] `shutdownNativeModels()` available for shared recognizer/LLM teardown.

## VocabStore.swift
- [x] `@MainActor` on data layer forces all SwiftData queries onto main thread. *(interactive card/gloss APIs stay main-actor for `@Model` UI use; seed/cleanup on `@ModelActor VocabBackgroundStore`)*
- [-] `@Model` classes expose public mutable vars – setters should be private/internal. *(SwiftData persistence needs writable stored properties; mutate via `VocabStore` API)*
- [x] Computed property masks errors by falling back to `.learning`. *(invalid raw → `.unknown`)*
- [x] `modelContext` exposed publicly. *(now private)*
- [x] Inefficient queries: repeated `fetchAll()` → N+1 scans for cards, known lemmas, due cards. *(predicate fetches + `learningLemmas()` / `dueCount`)*
- [x] Destructive seeding deletes rows individually with magic threshold `>=9000`. *(named constant + `delete(model:)`)*
- [x] Direct `UserDefaults.standard` coupling inside store layer. *(injected `defaults:` parameter)*
- [x] Missing doc comments for public API.
- [x] Silent early returns on bad input. *(empty surface/gloss/lemmas throw)*
