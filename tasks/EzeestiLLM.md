# EzeestiLLM – Idiomatic Swift Review

## GrammarTutor.swift
- L73, L79: `try? JSONDecoder().decode` swallowed; parser fabricates `TutorFeedback` on failure.
- `stripMarkdownFences` only removes leading fence, leaves trailing fences.
- `extractJSONObject` uses first/last brace – fragile for nested objects.
- Public API lacks doc comments.

## LlamaCppService.swift
- L7: `@unchecked Sendable` with `NSLock`-protected mutable state used from async continuations.
- Manual `NSLock` usage; missing `defer` unlock in some paths.
- `String(cString:)` on potentially non-null-terminated C buffers – unsafe.
- `unsafeBitCast` for dlsym function pointers without signature verification.
- No doc comments for public API.

## PassageGeneration.swift
- L116-122: `try?` decode returns nil indistinguishably from empty response.
- Duplicate `"ei"` in `nonPossessableFocus`.
- Fragile markdown strip / brace extraction duplicated.
- Magic `max(1, requiredFocus.count)`.
- Public types lack documentation.

## SentenceValidation.swift
- L122-128: `try?` decode silently drops errors.
- L133-136: encoding failure hidden via `try? … ?? Data()` then forced UTF-8.
- Unnecessary round-trip encode → parse of `PassageDraft`.
- No doc comments.

## SpokenSummary.swift
- Duplicate `"ei"` in `contentIgnore`.
- Placeholder detection with markup-like strings – false positives risk.
- Same fragile strip/extract duplicated across module.
- ~500-line enum mixes parsing, heuristics, scoring, Levenshtein – violates SRP.
- Public API undocumented.

## WordGlossPrompt.swift
- `pos: String` uses empty string as sentinel; prefer optional.
- `cefr` optional interpolated conditionally – confusing API.
- Decoding via `try?` with plain-text fallback hides JSON errors.
- Duplicate fragile strip/extract implementations.
- No doc comments.
