# EzeestiUI – Idiomatic Swift Review

## RootView.swift
- Public `struct RootView: View` and `LearningSessionView` exported without doc comments.
- `@StateObject` pattern pre-iOS 17; `@Observable`/`Observation` is idiomatic today.
- `EngineHolder` publishes properties with internal writable access – should be `private(set)`.
- `didStart` mutable flag exposed; name `hasStarted` clearer.
- Methods `attach`, `markReady`, `fail` are internal but only used from view – should be `private/fileprivate`.
- `.task` creates unstructured task mutating state; encapsulate start-up in holder.
- Error converted to string, information lost.
- `ForEach(..., id: \.lemma)` relies on uniqueness; prefer `Identifiable`.
- Manual bounds checks repeated; helper would clarify intent.
- Normalise computed twice per render.

## SetupPresentation.swift
- Enum internal with no explicit access modifier – unclear if public API.
- `screen(...)` takes four Bool/string parameters – noisy API; use a value type.
- `case failed(String)` stores raw message, loses error information.
- Missing doc comments for factory function.
