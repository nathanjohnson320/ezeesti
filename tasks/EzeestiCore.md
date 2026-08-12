# EzeestiCore – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## ExponentialBackoff.swift
- [-] Empty `enum ExponentialBackoff: Sendable` used as namespace → use `struct`/`final class` with private init. *(caseless `enum` is idiomatic Swift for namespaces; keep)*
- [ ] Public `static let` constants and static methods exposed publicly without `///` docs. Consider `internal` unless part of public API.
- [ ] Add doc comments for public API.

## GradedText.swift
- [ ] L67-68: `try? Data(contentsOf:)` / `try? JSONDecoder().decode` silently returns `[]`. Prefer throwing or logging instead of silent `try?`.
- [ ] L66: `candidates.compactMap({ $0 }).first` is odd; simplify.
- [ ] L98-107: `baselineFunctionWords` contains duplicate `"see"` and is an `Array`. Use `Set<String>` for O(1) contains.
- [ ] L51: `knownRatio` returns `1` for empty text. Returning `0`/`nil` is more predictable.
- [ ] Public types `VocabFamiliarity`, `GradedText`, `TextFamiliarityReport`, `GradedTextCatalog` lack `///` documentation.

## LearnerProgress.swift
- [ ] L64-70: working-level estimate logic bug – sets `working = level` before checking mastery, returns first failing band.
- [ ] L104, L113-114: static method accesses mutable singleton `LexiconCatalog.shared`. Avoid side effects in pure estimation.
- [ ] L117: fallback `LexiconEntry(pos: "")` uses empty string sentinel. Make `pos` optional.
- [ ] L146: `baselineFunctionWords.contains(key)` inside filter loop is O(n). Use a `Set`.
- [ ] L155-171: sorting closure does multiple look-ups per comparison – expensive.

## LessonCatalog.swift
- [ ] L5-8: deduplication via `Array(Set(...))` loses stable ordering.
- [ ] L14-19: re-throw discards original error cause. Preserve cause with `throw EzeestiError...` wrapping `error`.
- [ ] Missing doc comment for public `loadBundled()`.

## Lexicon.swift
- [~] L55: `final class LexiconCatalog: @unchecked Sendable` holds mutable state without synchronization.
- [ ] L64-84: silent `try?` on load – failures are ignored.
- [ ] L89-91: `entry(forSurface:)` calls `loadBundledIfNeeded()` on every access – hidden side effect.
- [ ] L93-96: `lemmas(at:)` scans `entriesByLemma.values` each call – O(n). Pre-group.
- [ ] L19-26: `isPassageFocusCandidate` parses `pos` string on every call.

## Models.swift
- [ ] Public enum `CEFRLevel`, `ModelPaths`, `EzeestiError` lack docs.
- [ ] `ModelPaths` holds mutable vars and creates directories as side effect – surprising for a value type.
- [ ] L107-119: `FileManager.default.fileExists(atPath:)` discouraged; use `URL.checkResourceIsReachable`.
- [-] Error descriptions hard-coded English, no localisation. *(app is English-first for now; defer until product needs it)*

## Tokenizer.swift
- [-] L18: `enum EstonianTokenizer` with only static methods – namespace misuse. *(caseless `enum` namespace is idiomatic; keep)*
- [ ] `normalize(_:)` only trims punctuation, unclear intent.
- [ ] Manual character state machine – regex/`CharacterSet` more idiomatic.
- [ ] No doc comments for public API.

## WordGloss.swift
- [~] Static `map`/`loaded` not synchronized – not thread-safe.
- [ ] Silent `try?` failures on load.
- [ ] Public types lack documentation.
