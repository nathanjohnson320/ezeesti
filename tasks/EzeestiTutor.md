# EzeestiTutor – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## TutorEngine.swift
- [x] L100: `MainActor.assumeIsolated` used after observer callback with `queue: .main`. Guarantee not provable. Use `MainActor.run`. *(replaced with `Task { @MainActor in await … }`)*
- [x] Protocol downcasts to concrete types `WhisperCppService`, `LlamaCppService`. Breaks abstraction; expose warmup/shutdown on protocols.
- [x] Lossy error handling: `Phase.error(String)` carries raw description, discards error type and stack. *(`PhaseFailure` keeps message + `String(describing:)` dump; DEBUG log)*
- [x] L148-149: wrong warmup state – sets `loadingTutor` for speaker. *(added `loadingVoice`)*
- [x] `@Published public private(set)` exposes internal mutable state publicly. *(`@Observable` migration; `public private(set)` retained for UI)*
- [x] Existentials `any SpeechRecognizing / LanguageModeling / TextSpeaking` stored in `@MainActor` class without `Sendable`. *(protocols are `Sendable`)*
- [x] Public `shutdownNativeModels()` should be `internal/private`. *(now internal)*
- [x] Missing doc comments for many public methods.
- [x] Non-idiomatic bounds check `pack.items.indices.contains(itemIndex)`. *(explicit `0..<count`)*
- [x] Magic string `"et-EE"` hard-coded. *(`speechLanguageCode` constant)*
- [x] Observer lifetime captures self weakly then assumes actor isolation – safer to use `MainActor.run`. *(terminate path now hops via `Task` + `await shutdownNativeModels()`)*
- [x] Mic record/stop use async actor APIs. *(ASR concurrency pass)*
