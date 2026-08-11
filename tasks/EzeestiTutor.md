# EzeestiTutor – Idiomatic Swift Review

## TutorEngine.swift
- L100: `MainActor.assumeIsolated` used after observer callback with `queue: .main`. Guarantee not provable. Use `MainActor.run`.
- Protocol downcasts to concrete types `WhisperCppService`, `LlamaCppService`. Breaks abstraction; expose warmup/shutdown on protocols.
- Lossy error handling: `Phase.error(String)` carries raw description, discards error type and stack.
- L148-149: wrong warmup state – sets `loadingTutor` for speaker.
- `@Published public private(set)` exposes internal mutable state publicly.
- Existentials `any SpeechRecognizing / LanguageModeling / TextSpeaking` stored in `@MainActor` class without `Sendable`.
- Public `shutdownNativeModels()` should be `internal/private`.
- Missing doc comments for many public methods.
- Non-idiomatic bounds check `pack.items.indices.contains(itemIndex)`.
- Magic string `"et-EE"` hard-coded.
- Observer lifetime captures self weakly then assumes actor isolation – safer to use `MainActor.run`.
