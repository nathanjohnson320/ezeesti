# EzeestiTutor – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## TutorEngine.swift
- [x] L100: `MainActor.assumeIsolated` used after observer callback with `queue: .main`. Guarantee not provable. Use `MainActor.run`. *(replaced with `Task { @MainActor in await … }`)*
- [x] Protocol downcasts to concrete types `WhisperCppService`, `LlamaCppService`. Breaks abstraction; expose warmup/shutdown on protocols.
- [ ] Lossy error handling: `Phase.error(String)` carries raw description, discards error type and stack.
- [ ] L148-149: wrong warmup state – sets `loadingTutor` for speaker.
- [-] `@Published public private(set)` exposes internal mutable state publicly. *(normal `ObservableObject` pattern; keep until Observation migration)*
- [x] Existentials `any SpeechRecognizing / LanguageModeling / TextSpeaking` stored in `@MainActor` class without `Sendable`. *(protocols are `Sendable`)*
- [ ] Public `shutdownNativeModels()` should be `internal/private`.
- [ ] Missing doc comments for many public methods.
- [ ] Non-idiomatic bounds check `pack.items.indices.contains(itemIndex)`.
- [ ] Magic string `"et-EE"` hard-coded.
- [x] Observer lifetime captures self weakly then assumes actor isolation – safer to use `MainActor.run`. *(terminate path now hops via `Task` + `await shutdownNativeModels()`)*
- [x] Mic record/stop use async actor APIs. *(ASR concurrency pass)*
