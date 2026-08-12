# EzeestiUI – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## RootView.swift
- [x] Public `struct RootView: View` and `LearningSessionView` exported without doc comments.
- [x] `@StateObject` pattern pre-iOS 17; `@Observable`/`Observation` is idiomatic today. *(`@State` + `@Observable` EngineHolder / engines)*
- [x] `EngineHolder` publishes properties with internal writable access – should be `private(set)`.
- [x] `didStart` mutable flag exposed; name `hasStarted` clearer. *(private `hasStarted`)*
- [x] Methods `attach`, `markReady`, `fail` are internal but only used from view – should be `private/fileprivate`. *(folded into `start(modelContext:)`)*
- [x] `.task` creates unstructured task mutating state; encapsulate start-up in holder.
- [x] Error converted to string, information lost. *(`SetupFailure` message + debug dump)*
- [x] `ForEach(..., id: \.lemma)` relies on uniqueness; prefer `Identifiable`. *(`ForEach(duePreview)` via SwiftData `Identifiable`)*
- [x] Manual bounds checks repeated; helper would clarify intent. *(`wordSurface(in:at:)`)*
- [x] Normalise computed twice per render. *(`lemmaDiffersFromSurface`)*
- [x] Shared Whisper/Llama/TTS stack constructed once and injected into tutor + learning. *(ASR lifecycle pass)*

## SetupPresentation.swift
- [x] Enum internal with no explicit access modifier – unclear if public API. *(documented module-internal launch helper)*
- [x] `screen(...)` takes four Bool/string parameters – noisy API; use a value type. *(`SetupSnapshot`)*
- [x] `case failed(String)` stores raw message, loses error information. *(`SetupFailure`)*
- [x] Missing doc comments for factory function.
