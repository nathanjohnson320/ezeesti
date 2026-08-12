# EzeestiASR – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## MicrophoneRecorder.swift
- [x] L24: `guard !isRecording else { return }` silently no-ops. Return error / throw.
- [x] L40: guard combines two side-effecting calls `prepareToRecord()` and `record()`.
- [x] Magic thresholds `0.6 s`, `-45 dB` without named constants/docs.
- [x] `@MainActor` on AVFoundation I/O class blocks main thread. *(converted to `actor`)*
- [x] Public API methods lack doc comments. *(type-level docs added; expand per-method if needed)*

## SpeechRecognizing.swift
- [x] L15: `@MainActor public protocol AudioRecording` forces conformers to main actor; requirements include synchronous I/O. *(removed `@MainActor`; async mic API)*
- [-] `public protocol SpeechRecognizing: Sendable` marks return type as Sendable without verification. *(valid: `Transcript` is `Sendable`; keep)*
- [x] Missing documentation for protocol requirements.

## TranscriptCleaner.swift
- [-] L6: `enum TranscriptCleaner` used only as namespace. Use `struct` with private init. *(caseless `enum` is idiomatic Swift for namespaces; keep)*
- [x] Helpers like `collapseRepeatedWords`, `looksLikeRepetitionHallucination` are `internal` instead of `private`. *(`collapseRepeatedWords` stays internal for Whisper fallback; repetition helper is private)*
- [x] Repeated `text.lowercased()` allocations inside loops. *(suffix loop caches once per pass)*
- [x] L194-208: `splitSentences` builds string by repeatedly appending single characters → O(n²). Use `String.Index`/ranges.
- [x] Dead code branch in `align(toExpected:transcript:)`.
- [x] Magic thresholds for repetition detection and overlap with no named constants.

## WhisperCppService.swift
- [x] L7: `@unchecked Sendable` with `NSLock`-protected mutable state – hides data race risk. *(converted to `actor`)*
- [x] L32-34: `deinit { shutdown() }` calls into C dylibs/Metal during deallocation – unsafe. *(removed; explicit `shutdown()` on terminate)*
- [x] L60: warm-up failure silently discarded via `try?`. *(explicit non-fatal catch + comment)*
- [x] L235: force-unwrap of `AVAudioFormat(...)!`. Guard and throw.
- [x] Force unwrap `initialPrompt!` after check – use optional binding.
- [x] Magic numbers for audio validation without named constants.
- [x] Manual GCD + continuations instead of structured concurrency. *(actor methods)*
- [x] Public stored properties exposed without docs.

---

## Follow-ups outside ASR
- Apply the same `actor` + explicit lifecycle pattern to `LlamaCppService`.
- Share one native stack from UI (done in `RootView`) — keep that pattern when adding new engines.
