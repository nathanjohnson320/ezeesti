# EzeestiLLM – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## GrammarTutor.swift
- [x] L73, L79: `try? JSONDecoder().decode` swallowed; parser fabricates `TutorFeedback` on failure. *(throws via shared `LLMJSON.decode`)*
- [x] `stripMarkdownFences` only removes leading fence, leaves trailing fences. *(shared helper strips both)*
- [x] `extractJSONObject` uses first/last brace – fragile for nested objects. *(brace-balanced scanner in `LLMJSON`)*
- [x] Public API lacks doc comments.

## LlamaCppService.swift
- [x] L7: `@unchecked Sendable` with `NSLock`-protected mutable state used from async continuations. *(`actor` + explicit `shutdown()` lifecycle, same as Whisper)*
- [x] Manual `NSLock` usage; missing `defer` unlock in some paths. *(locks removed; actor isolation)*
- [x] `String(cString:)` on potentially non-null-terminated C buffers – unsafe. *(`stringFromCBuffer` respects NUL/bounds)*
- [-] `unsafeBitCast` for dlsym function pointers without signature verification. *(required for `dlsym`; signatures documented to match C exports)*
- [x] No doc comments for public API.
- [x] Protocol `warmup()` / `shutdown()` available via `LanguageModeling`. *(ASR lifecycle pass)*

## PassageGeneration.swift
- [x] L116-122: `try?` decode returns nil indistinguishably from empty response. *(shared `LLMJSON.decodeIfPresent`)*
- [x] Duplicate `"ei"` in `nonPossessableFocus`. *(no duplicate present; cleaned related sets in SpokenSummary)*
- [x] Fragile markdown strip / brace extraction duplicated. *(uses `LLMJSON`)*
- [x] Magic `max(1, requiredFocus.count)`. *(named `minimumRequiredFocusHits`)*
- [x] Public types lack documentation.

## SentenceValidation.swift
- [x] L122-128: `try?` decode silently drops errors. *(shared decoder)*
- [x] L133-136: encoding failure hidden via `try? … ?? Data()` then forced UTF-8. *(round-trip removed)*
- [x] Unnecessary round-trip encode → parse of `PassageDraft`. *(`PassageGenerationParser.gradedText(from:)`)*
- [x] No doc comments.

## SpokenSummary.swift
- [x] Duplicate `"ei"` in `contentIgnore`.
- [x] Placeholder detection with markup-like strings – false positives risk. *(dropped short `<>` fragments; min fragment length)*
- [x] Same fragile strip/extract duplicated across module. *(uses `LLMJSON`)*
- [x] ~500-line enum mixes parsing, heuristics, scoring, Levenshtein – violates SRP. *(split into `SpokenSummaryFeedbackParser` + `SpokenSummaryHeuristics` + `SpokenSummaryAlignment`)*
- [x] Public API undocumented.

## WordGlossPrompt.swift
- [x] `pos: String` uses empty string as sentinel; prefer optional.
- [x] `cefr` optional interpolated conditionally – confusing API. *(documented; optional lines only when present)*
- [x] Decoding via `try?` with plain-text fallback hides JSON errors. *(JSON path via `LLMJSON`; plain fallback only when not JSON-like)*
- [x] Duplicate fragile strip/extract implementations. *(uses `LLMJSON`)*
- [x] No doc comments.
