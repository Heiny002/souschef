> **Second, independent audit pass.** This report was produced by a separate audit and
> overlaps substantially with [`AUDIT.md`](./AUDIT.md); the two were run independently and
> agree on the major findings (dietary-safety matching, the duplicate-ingredient crash, the
> bundled API key, the always-nil `sourceURL`, CloudKit misconfiguration). It is kept as a
> distinct document because it surfaces several issues the first pass did not — an
> integer-overflow crash in the cook timer (`CookTimerManager.swift:84`), a `CookVoiceController`
> retain-cycle leak (`CookModeView.swift:63`), untrusted URLs flowing into `AsyncImage`/`Link`
> in `SimilarRecipePreviewSheet.swift`, an SSRF framing of `WebPageFetcher`, and a reverse
> substring bug in `IngredientConverter` — and because it pins a **more severe root cause** for
> the dietary findings:
>
> Its Critical #1 (diet/food/substitution JSON never loads because of the `subdirectory: "Data"`
> argument) was verified by static inspection of `SousChef.xcodeproj/project.pbxproj`: the three
> JSON files are added to Copy Bundle Resources as individual files inside a plain group
> (`path = Data`), not a folder reference, so Xcode flattens them to the bundle **root** and the
> `subdirectory: "Data"` lookups return nil. If confirmed by an actual build, the diet/allergy
> feature is **inert in shipping builds** — every ingredient reports "Compatible" — which sits
> *above* the matching-logic bugs in `AUDIT.md` (those only manifest once the data loads). Fix
> the bundling first, then the matching logic.

---

# SousChef App Audit

SousChef is a SwiftData/CloudKit iOS app that imports recipes by scraping social-media and web content and running it through Anthropic LLM calls. The audit surfaced two dominant themes. First, **untrusted scraped content flows into unhardened sinks**: a family of SSRF holes in `WebPageFetcher`, a UTF-16/Character index crash and offset-corruption in `IngredientAnnotator`, an integer-overflow crash in the cook timer, a `Dictionary(uniqueKeysWithValues:)` trap in diet matching, and prompt injection into the LLM. Second, **build/config wiring silently disables core features**: the diet/allergy safety dataset never loads in the shipping bundle, CloudKit sync can never initialize, and recipe provenance is dropped on save — each failure masked by `try?` or a dead ternary so nothing is surfaced to the user or developer. Separately, a provider API key is baked into the shipped IPA. The code itself is mostly clean and well-structured; the risk concentrates in resource packaging, secret handling, and the trust boundary around scraped input.

## Top risks
- Diet/allergy safety feature is inert in the shipping build — every ingredient reports Compatible (`DietDefinition.swift:39`).
- Anthropic API key ships in cleartext inside any Release IPA built with a real key (`Info.plist:22`).
- SSRF: untrusted scraped URLs are fetched with no scheme/host validation, reaching localhost and LAN hosts (`WebPageFetcher.swift:51`).
- Multiple attacker-controlled-content crashes: emoji/accented text (`IngredientAnnotator.swift:44`), duplicate ingredient names (`ProfileMatcher.swift:57`), huge durations (`CookTimerManager.swift:84`).
- Recipe source URL is never persisted — every import loses its link back to the origin (`ReviewView.swift:298`).
- CloudKit sync is structurally impossible and silently downgraded to local-only (`SousChefApp.swift:14`).

## Findings by severity

### Critical

**Diet/food/substitution JSON never loads — `Sources/SousChef/Models/DietDefinition.swift:39`** `[correctness] [CONFIRMED]`
`DietLibrary.load()` (and identically `FoodDictionary.load()` and `SubstitutionLibrary.load()`) resolve JSON with `subdirectory: "Data"`, but the resources live in a yellow PBXGroup and are copied flat into the bundle root, so `url(forResource:subdirectory:"Data")` returns nil and each `guard ... else { return }` silently leaves the datasets empty. `ProfileMatcher.evaluate` then reports every ingredient GREEN/Compatible and offers no substitutions — the entire allergy/diet safety feature is dead in the shipping build, masked by `try?`.
*Fix:* Drop the `subdirectory: "Data"` argument (or make `Data` a real blue folder reference). For a safety-critical dataset, replace silent `return` with a logged error/`assertionFailure` and surface a non-loaded state so the UI never claims "Compatible" on empty data.

**Anthropic API key embedded in shipped app bundle — `Sources/SousChef/Info.plist:22`** `[security] [CONFIRMED]`
`Info.plist` injects `$(ANTHROPIC_API_KEY)`, and `ExtractionPipeline.swift:131` reads it back via `Bundle.main.infoDictionary`, POSTing it directly to `api.anthropic.com`. Because `Config.xcconfig` serves both Debug and Release, any Release IPA built with a populated `Secrets.xcconfig` ships the key in cleartext — trivially extracted via `unzip Payload/SousChef.app/Info.plist`, enabling unlimited billed use of your account. (This is the same defect reported at `ExtractionPipeline.swift:131`.)
*Fix:* Remove `ANTHROPIC_API_KEY` from `Info.plist` entirely and route all provider calls through a backend proxy that holds the key and enforces per-user auth/rate limits. If a proxy is out of scope, at minimum isolate the key to a Debug-only xcconfig, and treat any previously shipped key as compromised and rotate it.

### High

**SSRF: untrusted scraped URLs fetched with no scheme/host allow-listing — `Sources/SousChef/Extraction/WebPageFetcher.swift:51`** `[security] [CONFIRMED]`
`fetch(urlString:)` issues `session.data(for:)` against any `URL(string:)`-parseable input with zero validation — no `http/https` check, no host allowlist, no rejection of loopback/link-local/RFC1918. Every URL it receives is attacker-influenceable: caption URLs from `CaptionAnalyzer.extractDirectURL` (via `ExtractionPipeline.swift:58`), bio/aggregator hrefs from `BioLinkResolver`, and `link`/`<loc>` fields from `BlogRecipeSearch`. A malicious caption or bio page can drive GETs to `http://127.0.0.1:8000` (the local transcript server), router admin pages, or other LAN hosts. (Consolidates the SSRF findings at `WebPageFetcher.swift:43`, `WebPageFetcher.swift:51`, and `ExtractionPipeline.swift:58`.)
*Fix:* Centrally in `fetch`, require `scheme == https`, and reject loopback (`127.0.0.0/8`, `::1`, `localhost`), link-local (`169.254.0.0/16`, `fe80::/10`), RFC1918/ULA ranges, `.local`, and non-standard ports. Prefer an explicit origin allowlist for the blog/bio flows, and re-validate after every redirect hop.

**Redirect handling is a no-op — `Sources/SousChef/Extraction/WebPageFetcher.swift:34`** `[security] [CONFIRMED]`
The `"Handle redirects manually via delegate"` comment is false: the session is created with no `URLSessionTaskDelegate`, so URLSession auto-follows ~20 redirects, and `maxRedirects` is dead config never read after init (`tooManyRedirects` is never thrown). This means any host validation added at fetch time is bypassed — an allowed URL can 302 to `http://localhost` or an internal host and the fetcher follows silently.
*Fix:* Construct the session with a delegate implementing `urlSession(_:task:willPerformHTTPRedirection:...)` that counts hops against `maxRedirects` and re-runs the SSRF/host check on each `newRequest.url`; call `completionHandler(nil)` to stop. Remove the comment if manual handling is not wired.

**NSRange (UTF-16) offset used as Character index — `Sources/SousChef/Extraction/IngredientAnnotator.swift:44`** `[correctness] [CONFIRMED]`
`wordBoundaryRange` returns UTF-16 offsets (measured against `lowered`) that `annotateStep` feeds to `result.index(_:offsetBy:)`, which counts grapheme clusters over the original-case `result`. For any emoji/accented/combining char — routine in scraped text — the offset overshoots: the measurement inserts mid-word, and when it exceeds `result.count` the app traps. Input is attacker-controlled, so this is a reachable remote-content crash.
*Fix:* Don't carry NSRange integers across strings. Convert via `Range(match.range, in: text)` and match/insert against `result` directly using `Range<String.Index>` (e.g. `result.range(of:options:[.caseInsensitive, .regularExpression])`).

**Stale match offsets corrupt multi-ingredient annotation — `Sources/SousChef/Extraction/IngredientAnnotator.swift:28`** `[correctness] [CONFIRMED]`
`lowered` is computed once, but each ingredient's offset (against the fixed `lowered`) is used to insert into the growing `result`. After the first `" (measurement)"` insertion, `result` is longer than `lowered`, so later insertions land earlier than intended — e.g. "Add the carrots and celery" yields garbled output with a measurement spliced into "and". Reproduces with pure ASCII, independent of the UTF-16 bug above.
*Fix:* Re-search the current `result` each iteration (re-lowercasing), or accumulate insertions and apply right-to-left. Best combined with the `String.Index` refactor above, eliminating the separate offset space.

**`match()` traps on duplicate ingredient rawText — `Sources/SousChef/Diet/ProfileMatcher.swift:57`** `[correctness] [CONFIRMED]`
Results are built with `Dictionary(uniqueKeysWithValues:)` keyed by `ingredient.rawText`, which `fatalError`s on any repeated key. Recipes routinely repeat rawText ("Salt", "to taste", duplicated/noisy lines), crashing the app the moment `CompatibilityView.onAppear` runs `computeResults()`. `dinerResultsFor` also keys by rawText, so duplicates collide there too.
*Fix:* Key by the stable `ingredient.id` (UUID) throughout, or use `Dictionary(_:uniquingKeysWith:)` to tolerate duplicates.

**Integer-overflow crash converting untrusted duration — `Sources/SousChef/CookMode/CookTimerManager.swift:84`** `[security] [CONFIRMED]`
`TimerDetector` runs on scraped instruction text; the number regex accepts an unbounded digit run parsed to `Double`, multiplied by 60/3600, then force-cast with `Int(...)`, which traps above `Int.max`. A step like "cook for 99999999999999999999 minutes" crashes the app. The `secs >= 10` guard runs only after the crashing conversion, and the same trap exists in the `Int(lo)`/`Int(hi)`/`Int(value)` label builders.
*Fix:* Clamp in `Double` space first — `guard raw.isFinite, raw >= 10, raw <= 86_400 else { return nil }` — then convert. Apply to the label computations too, or bound the regex digit length.

**`sourceURL` always saved as nil — `Sources/SousChef/Views/ReviewView.swift:298`** `[correctness] [CONFIRMED]`
`saveRecipe()` builds the Recipe with `sourceURL: extractionResult.ingredients.isEmpty ? nil : nil` — both branches are nil, so provenance is never persisted despite `ExtractionResult` carrying `originalSourceURL`/`recipePageURL`. Every saved recipe loses its link to the origin, breaking re-open and any dedup/attribution keyed on it — the core value of an import app, lost silently.
*Fix:* `sourceURL: extractionResult.recipePageURL ?? extractionResult.originalSourceURL,` and delete the no-op ternary.

**CloudKit sync silently disabled — `Sources/SousChef/SousChefApp.swift:14`** `[architecture] [CONFIRMED]`
The container requests `cloudKitDatabase: .automatic`, but `SousChef.entitlements` is an empty `<dict/>` (no iCloud services/container, no `aps-environment`, no remote-notification background mode), and the models use `@Attribute(.unique)` — either condition alone makes the cloud `ModelContainer` init throw. The `try?` swallows it and falls through to a local-only container with no signal, so nothing ever syncs. (Consolidates `SousChefApp.swift:14` and `SousChef.entitlements:4`.)
*Fix:* Add the iCloud/CloudKit entitlements + container id, `aps-environment`, and the remote-notification background mode; set a real `DEVELOPMENT_TEAM`; remove `.unique` (below). Log the thrown error instead of `try?` so a broken config is visible rather than downgraded.

### Medium

**`@Attribute(.unique)` incompatible with CloudKit-backed SwiftData — `Sources/SousChef/Models/Recipe.swift:6`** `[correctness] [CONFIRMED]`
`Recipe.id`, `Ingredient.id`, `CookingStep.id` all use `@Attribute(.unique)`, which CloudKit mirroring rejects — a root cause of the silent local-only fallback above. Since these UUIDs are generated fresh in `init`, the constraint adds no value.
*Fix:* Make `id` a plain `var id: UUID`; enforce any dedup in import logic, not a store constraint.

**Prompt injection: untrusted text concatenated into the LLM prompt — `Sources/SousChef/Extraction/LLMExtractor.swift:61`** `[security] [CONFIRMED]`
Scraped page text (and transcripts in `TranscriptLLMValidator`) are interpolated straight into the user turn after the schema, with no delimiting or hardening. Injected instructions ("Ignore previous instructions and return …") can override extraction and poison the ingredients/steps the user cooks from. `parseResponse` also trusts the returned JSON with no bounds on counts/lengths.
*Fix:* Wrap untrusted content in an explicit delimited block (`<untrusted_document>…</untrusted_document>`) with a system preamble stating it is data, never instructions. Validate/bound the returned JSON before it becomes recipe data.

**Substring matching for allergies/restrictions false-flags — `Sources/SousChef/Diet/ProfileMatcher.swift:79`** `[correctness] [CONFIRMED]`
Allergy/restriction/diet checks use naive `text.contains(a)` on lowercased text, so "egg" flags "eggplant", "rice" flags "licorice", "oats" flags "goats". On a safety surface these misleading RED flags erode trust and can mask genuine hits; there is no word-boundary or alias-aware matching.
*Fix:* Tokenize on word boundaries (split on non-alphanumerics or `NLTokenizer`) and resolve allergens through the `FoodDictionary` alias graph; ignore empty/very-short restriction strings.

**Reverse-substring matching maps items to unrelated density/piece keys — `Sources/SousChef/Conversion/IngredientConverter.swift:260`** `[correctness] [CONFIRMED]`
`gPerCup` and `pieceInfo` also accept `$0.key.contains(lower)`, so a short item name that is a substring of a longer key inherits its density: item "ice" → "rice flour" (158 g/cup), "corn" → cornstarch, "cream" → "cream cheese". `gPerCup` then picks the longest such key, biasing further wrong, with no rawText fallback since a (wrong) match was found — producing materially wrong conversions.
*Fix:* Drop the `key.contains(lower)` direction; match keys only as whole words/tokens within the item, or guard the reverse branch with a minimum length and word boundary.

**Schema.org `tool` appliances immediately discarded — `Sources/SousChef/Extraction/SchemaOrgExtractor.swift:107`** `[correctness] [CONFIRMED]`
`extractRecipe` parses publisher-declared `tool[]` into `result.appliances`, then unconditionally overwrites it with `ApplianceDetector.detect(...)`. Explicit tools not inferable from ingredient/step text (stand mixer, candy thermometer) are lost.
*Fix:* Merge instead of overwrite — `Array(Set(toolNames).union(ApplianceDetector.detect(...))).sorted()`.

**Microdata duration fallback never runs — `Sources/SousChef/Extraction/MicrodataExtractor.swift:74`** `[correctness] [CONFIRMED]`
SwiftSoup's `attr(_:)` returns `""` (not nil) for a missing attribute, so `(try? el.attr("datetime")) ?? …` yields `Optional("")` and the `??` chain stops at the first term — the `content` and `text()` fallbacks are unreachable. Recipes with time in element text (`<span itemprop="cookTime">PT1H</span>`) parse to nil and drop the times.
*Fix:* Select the first non-empty candidate: `[datetime, content, txt].first { !$0.isEmpty } ?? ""`.

**No response size cap — `Sources/SousChef/Extraction/WebPageFetcher.swift:51`** `[performance] [CONFIRMED]`
`session.data(for:)` buffers the entire body before any check, then `String(data:encoding:)` copies it again, with no byte budget or `Content-Length` guard. An untrusted URL pointing at a very large/chunked response can cause memory-pressure termination.
*Fix:* Stream with `session.bytes(for:)` and abort past a budget (5–10 MB), or reject early when `expectedContentLength` exceeds it; keep `timeoutIntervalForResource` as a backstop.

**Attacker-influenced URLs loaded/opened without scheme validation — `Sources/SousChef/Views/SimilarRecipePreviewSheet.swift:69`** `[security] [CONFIRMED]`
`alternatives` come from the web-search substitute path, so `thumbnailURL` and `recipePageURL` are untrusted. `thumbnailURL` goes straight into `AsyncImage(url:)` (a GET fired on appear from the user's IP), and `recipePageURL` into `Link(destination:)` with no `https`/host check, allowing cleartext or app-scheme links to be surfaced as a "source".
*Fix:* Require `url.scheme == "https"` and reject IP-literal/localhost hosts for both the image source and the link destination; fall back to placeholder / hide the link on failure.

**Google CSE API key placed in URL query string — `Sources/SousChef/Extraction/WebRecipeSearcher.swift:76`** `[security] [CONFIRMED]`
The bundle-embedded CSE key is interpolated into the request URL query (captured by server/proxy logs), and only `query` is percent-encoded — raw `apiKey`/`cseID` would corrupt the URL on any reserved char (and `URL(string:)` then silently returns nil).
*Fix:* Proxy CSE calls through your backend. If direct, build with `URLComponents`/`URLQueryItem` so each value is encoded.

**Hardcoded `http://localhost:8000` search endpoint is dead in production — `Sources/SousChef/Extraction/WebRecipeSearcher.swift:34`** `[correctness] [CONFIRMED]`
Strategy 1 always targets `http://localhost:8000/search-recipe`, which no shipped device serves (and cleartext http has no ATS exception), so it silently degrades to the usually-unconfigured Google CSE — the SC-076 recovery chain rarely runs. Same localhost assumption recurs in `CreatorProfileSearcher`/`TranscriptFetcher`.
*Fix:* Use the real backend base URL from config over https; gate any dev-only localhost path behind `#if DEBUG` with a scoped ATS exception.

**Retain cycle leaks `CookVoiceController` — `Sources/SousChef/CookMode/CookModeView.swift:63`** `[architecture] [CONFIRMED]`
`voice.onCommand = { [self] cmd in … }` captures the View struct, whose `@StateObject` box strongly retains the controller, which stores the closure — closing a cycle. `onDisappear` calls `deactivate()` but never clears `onCommand`, so each Cook Mode visit leaks a controller (with its `AVAudioEngine`/`SFSpeechRecognizer`/`AVAudioSession`).
*Fix:* Set `voice.onCommand = nil` in `onDisappear`, or expose commands via `@Published`/`AsyncStream` and capture `[weak]`.

**Per-side timer advances but never resumes counting — `Sources/SousChef/CookMode/CookTimerManager.swift:181`** `[correctness] [CONFIRMED]`
On side-1 completion `tick()` sets `isRunning=false` and nils the ticker; the 1.5s-later block advances `sideNumber` and resets `secondsRemaining` but never restarts the ticker or sets `isRunning`, leaving side 2 configured-but-paused. The hands-free per-side flow stops until the user manually presses start.
*Fix:* Call `start()` (or set `isRunning=true` and reschedule the ticker) inside the `asyncAfter` block after resetting `secondsRemaining`.

**Voice recognition dies after finalization and never restarts — `Sources/SousChef/CookMode/CookVoiceController.swift:142`** `[correctness] [CONFIRMED]`
On `result?.isFinal == true` (or error) the callback only sets `isListening=false` — it never stops the engine, removes the tap, nils the request/task, or restarts. `SFSpeechRecognizer` force-finalizes after ~1 minute, so during the multi-minute gap after a step is read, commands go silently unresponsive while the engine/tap keep running and the finished task leaks, defeating the hands-free premise.
*Fix:* On finalization, fully tear down and, if still meant to be listening and not speaking, start a fresh recognition session.

### Low

**Cancelling the import sheet silently completes onboarding — `Sources/SousChef/Views/OnboardingView.swift:42`** `[correctness] [CONFIRMED]`
`.sheet(onDismiss: { hasCompletedOnboarding = true })` fires on any dismissal — swipe or Cancel — so a user who opens Import just to look is permanently pushed past onboarding via the persisted `AppStorage` flag.
*Fix:* Set the flag only on a successful save reported by `ImportView` (completion callback), not in `onDismiss`.

**Auto-Adapt offered for yellow-only recipes produces an identical duplicate — `Sources/SousChef/Views/CompatibilityView.swift:137`** `[correctness] [CONFIRMED]`
`canAutoAdapt` is true for `worstLevel > .green` (yellow or red), but `autoAdapt()` only substitutes when `worstLevel == .red`; yellow-flagged ingredients fall through to a plain copy, yielding a full "… (Adapted)" duplicate with zero changes despite the confirmation promising substitutions.
*Fix:* Gate `canAutoAdapt` on at least one ingredient having an available substitution (or handle `.yellow`), and never insert an adapted Recipe when nothing changed.

**Static regex recompiled on every call — `Sources/SousChef/Extraction/CaptionAnalyzer.swift:122`** `[performance] [CONFIRMED]`
`matchesLinkInBio` compiles ~18 constant `bioPatterns` per invocation; `VideoMetadataFetcher.extractOGContent` and `TranscriptExtractor.extractYield/extractTime` do the same. Avoidable per-call CPU on the extraction path.
*Fix:* Precompile into `static let [NSRegularExpression]` (or one alternation) and reuse.

**Filter+sort recomputed in a body-evaluated property — `Sources/SousChef/Views/RecipeLibraryView.swift:19`** `[performance] [CONFIRMED]`
`@Query` fetches unsorted, and `filteredRecipes` re-runs `.filter` + in-memory `.sort` on every body evaluation (every keystroke, every unrelated `@State` change) instead of using SwiftData sort descriptors.
*Fix:* Drive ordering via `@Query(sort:)` and push the title filter into a `#Predicate` where possible.

**`@unchecked Sendable` singleton with mutable write-once state — `Sources/SousChef/Extraction/FoodDictionary.swift:55`** `[architecture] [CONFIRMED]`
`entries`/`lookup` are `var` but written only in `init`; no live race today, yet `var` + `@unchecked` suppresses the compiler check and any future mutating method would race the concurrent readers.
*Fix:* Make them `let`, build in the initializer, and drop `@unchecked` for plain `Sendable`; if lazy load must stay, guard behind a lock or actor.

## Quick wins
- Delete the no-op ternary and persist the real source URL (`ReviewView.swift:298`) — one-line fix, restores core import value.
- Drop `subdirectory: "Data"` so the safety dataset actually loads (`DietDefinition.swift:39` and the two sibling loaders).
- Key `match()` by `ingredient.id` or use `uniquingKeysWith:` (`ProfileMatcher.swift:57`) — removes a real crash.
- Merge parsed `tool[]` with detector output (`SchemaOrgExtractor.swift:107`) and select first-non-empty for durations (`MicrodataExtractor.swift:74`).
- `voice.onCommand = nil` in `onDisappear` (`CookModeView.swift:63`) — kills the leak.
- Remove `.unique` from the three `@Model` ids (`Recipe.swift:6`) — one blocker off the CloudKit path.
- Precompile the static regex sets (`CaptionAnalyzer.swift:122`).

## What looked solid
Adversarial verification did its job: **4 candidate findings were rejected** before this report, and several survivors were kept only after their over-stated framing was pared back (e.g. the CloudKit "marketed sync" narrative, the mobile-context SSRF severity, and the imperfect food-collision examples were corrected rather than accepted wholesale). Beyond the packaging and trust-boundary issues, the codebase reads as competent and idiomatic Swift: models, extractors, and views are cleanly separated; the extraction pipeline has a sensible strategy/fallback structure; UUIDs and SwiftData relationships are modeled reasonably; and the LLM output path already forces low confidence and user review, which meaningfully blunts the prompt-injection risk. The defects cluster in a few fixable seams — resource bundling, secret handling, and input hardening at the scrape boundary — rather than being spread through the core logic.
