# EzeestiTTS – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## TextSpeaking.swift
- [ ] L18: global mutable singleton `static let shared = NeurokoneSession()`. Prefer dependency injection.
- [-] Naming inconsistency: type `NeurokoneSession` vs domain *Neurokõne*. *(ASCII type names are fine; domain spelling belongs in docs/UI copy)*
- [ ] Magic literal `defaultSpeaker = "mari"` without named constant.
- [ ] Unnecessary `var` binding for request string; use immutable binding + interpolation.
- [ ] Silent error swallowing: `try? stdinHandle?.close()`, `try? FileManager.default.removeItem(at:)`.
- [ ] `_ = languageCode` pattern – declare parameter as `_` or document why unused.
- [ ] Missing doc comments for public API `NeurokoneTTSService` and protocol method.
- [~] Actor methods use `DispatchQueue.global(qos:.userInitiated).async` + `Thread.sleep` polling, breaking actor isolation.
- [~] Polling + blocking sleep instead of async primitives / `AsyncSequence`.
- [~] `AudioPlayerDelegate` marked `@unchecked Sendable` with mutable state and static retained array.
- [~] ObjC runtime retention hack via `objc_setAssociatedObject`.
- [ ] Fragile line-based JSON protocol parsing.
