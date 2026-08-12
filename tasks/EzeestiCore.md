# EzeestiCore – Idiomatic Swift Review

Status legend: `[x]` done · `[ ]` open · `[~]` deferred (needs redesign) · `[-]` rejected / not Swift-standard

## ExponentialBackoff.swift
- [-] Empty `enum ExponentialBackoff: Sendable` used as namespace → use `struct`/`final class` with private init. *(caseless `enum` is idiomatic Swift for namespaces; keep)*
- [x] Public `static let` constants and static methods exposed publicly without `///` docs. Consider `internal` unless part of public API. *(kept public — used by Learning; docs added)*
- [x] Add doc comments for public API.

## GradedText.swift
- [x] L67-68: `try? Data(contentsOf:)` / `try? JSONDecoder().decode` silently returns `[]`. Prefer throwing or logging instead of silent `try?`. *(throwing `loadSeedKnownLemmasThrowing()` + non-throwing wrapper)*
- [x] L66: `candidates.compactMap({ $0 }).first` is odd; simplify.
- [x] L98-107: `baselineFunctionWords` contains duplicate `"see"` and is an `Array`. Use `Set<String>` for O(1) contains.
- [x] L51: `knownRatio` returns `1` for empty text. Returning `0`/`nil` is more predictable. *(now returns `0`)*
- [x] Public types `VocabFamiliarity`, `GradedText`, `TextFamiliarityReport`, `GradedTextCatalog` lack `///` documentation.

## LearnerProgress.swift
- [-] L64-70: working-level estimate logic bug – sets `working = level` before checking mastery, returns first failing band. *(intentional: working level = first band below mastery; clarified in docs)*
- [x] L104, L113-114: static method accesses mutable singleton `LexiconCatalog.shared`. Avoid side effects in pure estimation. *(injectable `lexicon:` parameter, default `.shared`)*
- [x] L117: fallback `LexiconEntry(pos: "")` uses empty string sentinel. Make `pos` optional.
- [x] L146: `baselineFunctionWords.contains(key)` inside filter loop is O(n). Use a `Set`.
- [x] L155-171: sorting closure does multiple look-ups per comparison – expensive. *(precomputed `Ranked` keys)*

## LessonCatalog.swift
- [x] L5-8: deduplication via `Array(Set(...))` loses stable ordering. *(stable first-seen dedupe)*
- [x] L14-19: re-throw discards original error cause. Preserve cause with `throw EzeestiError...` wrapping `error`. *(message includes underlying `localizedDescription`)*
- [x] Missing doc comment for public `loadBundled()`.

## Lexicon.swift
- [x] L55: `final class LexiconCatalog: @unchecked Sendable` holds mutable state without synchronization. *(`OSAllocatedUnfairLock` snapshot state)*
- [x] L64-84: silent `try?` on load – failures are ignored. *(throwing `loadBundled()`; soft wrapper leaves unloaded on failure so retries work)*
- [x] L89-91: `entry(forSurface:)` calls `loadBundledIfNeeded()` on every access – hidden side effect. *(documented; load is idempotent after success)*
- [x] L93-96: `lemmas(at:)` scans `entriesByLemma.values` each call – O(n). Pre-group.
- [x] L19-26: `isPassageFocusCandidate` parses `pos` string on every call. *(computed once at init/decode)*

## Models.swift
- [x] Public enum `CEFRLevel`, `ModelPaths`, `EzeestiError` lack docs.
- [x] `ModelPaths` holds mutable vars and creates directories as side effect – surprising for a value type. *(properties are `let`; factory documents directory creation)*
- [x] L107-119: `FileManager.default.fileExists(atPath:)` discouraged; use `URL.checkResourceIsReachable`.
- [-] Error descriptions hard-coded English, no localisation. *(app is English-first for now; defer until product needs it)*

## Tokenizer.swift
- [-] L18: `enum EstonianTokenizer` with only static methods – namespace misuse. *(caseless `enum` namespace is idiomatic; keep)*
- [x] `normalize(_:)` only trims punctuation, unclear intent. *(documented: lowercase + strip quotes for lemma keys)*
- [-] Manual character state machine – regex/`CharacterSet` more idiomatic. *(kept explicit scanner; word extras use `CharacterSet`)*
- [x] No doc comments for public API.

## WordGloss.swift
- [x] Static `map`/`loaded` not synchronized – not thread-safe. *(`OSAllocatedUnfairLock`)*
- [x] Silent `try?` failures on load. *(throwing `loadBundled()`; soft wrapper retries on failure)*
- [x] Public types lack documentation.
