# EzeestiLearning – Idiomatic Swift Review

## LearningEngine.swift
- `@MainActor` on UI class drives SwiftData access, Whisper/LLM calls and file I/O – blocks main thread.
- Fire-and-forget `Task { try? await speaker.prepare() }` discards failures.
- Extensive `try?` usage hides failures; errors flattened to `String` phase repeatedly.
- Public API properties/methods lack doc comments.
- Existentials without `Sendable` constraints.
- Silent fallback parsing for sentence validation with no logging.
- Fuzzy lemma matching with `hasPrefix` overlap checks – error-prone.
- Hard-coded CEFR fallback logic.

## VocabStore.swift
- `@MainActor` on data layer forces all SwiftData queries onto main thread.
- `@Model` classes expose public mutable vars – setters should be private/internal.
- Computed property masks errors by falling back to `.learning`.
- `modelContext` exposed publicly.
- Inefficient queries: repeated `fetchAll()` → N+1 scans for cards, known lemmas, due cards.
- Destructive seeding deletes rows individually with magic threshold `>=9000`.
- Direct `UserDefaults.standard` coupling inside store layer.
- Missing doc comments for public API.
- Silent early returns on bad input.
