# EzeestiASR – Idiomatic Swift Review

## MicrophoneRecorder.swift
- L24: `guard !isRecording else { return }` silently no-ops. Return error / throw.
- L40: guard combines two side-effecting calls `prepareToRecord()` and `record()`.
- Magic thresholds `0.6 s`, `-45 dB` without named constants/docs.
- `@MainActor` on AVFoundation I/O class blocks main thread.
- Public API methods lack doc comments.

## SpeechRecognizing.swift
- L15: `@MainActor public protocol AudioRecording` forces conformers to main actor; requirements include synchronous I/O.
- `public protocol SpeechRecognizing: Sendable` marks return type as Sendable without verification.
- Missing documentation for protocol requirements.

## TranscriptCleaner.swift
- L6: `enum TranscriptCleaner` used only as namespace. Use `struct` with private init.
- Helpers like `collapseRepeatedWords`, `looksLikeRepetitionHallucination`, `splitSentences` are `internal` instead of `private`.
- Repeated `text.lowercased()` allocations inside loops.
- L194-208: `splitSentences` builds string by repeatedly appending single characters → O(n²). Use `String.Index`/ranges.
- Dead code branch in `align(toExpected:transcript:)`.
- Magic thresholds for repetition detection and overlap with no named constants.

## WhisperCppService.swift
- L7: `@unchecked Sendable` with `NSLock`-protected mutable state – hides data race risk.
- L32-34: `deinit { shutdown() }` calls into C dylibs/Metal during deallocation – unsafe.
- L60: warm-up failure silently discarded via `try?`.
- L235: force-unwrap of `AVAudioFormat(...)!`. Guard and throw.
- Force unwrap `initialPrompt!` after check – use optional binding.
- Magic numbers for audio validation without named constants.
- Manual GCD + continuations instead of structured concurrency.
- Public stored properties exposed without docs.
