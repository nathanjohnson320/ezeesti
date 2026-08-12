# EzeestiTTS – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## TextSpeaking.swift
- [x] L18: global mutable singleton `static let shared = NeurokoneSession()`. Prefer dependency injection. *(`NeurokoneTTSService` owns/injects a session)*
- [-] Naming inconsistency: type `NeurokoneSession` vs domain *Neurokõne*. *(ASCII type names are fine; domain spelling belongs in docs/UI copy)*
- [x] Magic literal `defaultSpeaker = "mari"` without named constant. *(`NeurokoneSession.defaultVoiceID`)*
- [x] Unnecessary `var` binding for request string; use immutable binding + interpolation.
- [x] Silent error swallowing: `try? stdinHandle?.close()`, `try? FileManager.default.removeItem(at:)`. *(explicit best-effort `do/catch`)*
- [x] `_ = languageCode` pattern – declare parameter as `_` or document why unused. *(`languageCode _:` + docs)*
- [x] Missing doc comments for public API `NeurokoneTTSService` and protocol method.
- [x] Actor methods use `DispatchQueue.global(qos:.userInitiated).async` + `Thread.sleep` polling, breaking actor isolation. *(`Task.sleep` on the actor)*
- [x] Polling + blocking sleep instead of async primitives / `AsyncSequence`. *(`FileHandleLineReader` via readabilityHandler + async wait)*
- [x] `AudioPlayerDelegate` marked `@unchecked Sendable` with mutable state and static retained array. *(`@MainActor PlaybackSession` + registry)*
- [x] ObjC runtime retention hack via `objc_setAssociatedObject`. *(registry retains sessions until finish)*
- [x] Fragile line-based JSON protocol parsing. *(typed object parse + required `ok` flag; clearer errors)*
