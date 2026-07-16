# SousChef App Audit

A parallel audit of the SousChef iOS app across correctness, iOS/Swift architecture,
security & privacy, performance, and UI/UX — plus an engagement evaluation of how to grow
usage beyond the moment of cooking.

- **Commit:** `7b40b90` (main)
- **Date:** 2026-07-16
- **Scope:** ~9.7k LOC
- **Method:** 8 subsystem auditors ran in parallel across 5 dimensions; each critical/high
  finding was re-checked by an independent verifier prompted to refute it
  (**27/27 confirmed, 0 refuted**). The extraction/parsing-core pass was re-run separately
  after a transient API overload; its 15 findings (2 high, 13 medium) are included but did
  **not** go through the second verifier pass. Counts are de-duplicated across overlapping
  subsystems; cross-agent corroboration is noted per finding.
- **Caveat:** these are static-analysis findings — the code was read but not built/run
  (no macOS/Xcode in the audit environment).
- **Companion report:** an independent second pass is recorded in
  [`AUDIT-second-pass.md`](./AUDIT-second-pass.md). The two agree on the major findings and are
  kept separate because the second pass adds a few issues this one missed (see *Additional
  findings from the second pass* below) and pins a more severe root cause for the dietary
  cluster (see the escalation note after the safety callout).

## Summary

| Severity | Count |
|----------|-------|
| Critical | 6 |
| High     | 17 |
| Medium   | ~40 |
| Low      | 11 |

**By dimension (raw, pre-dedup):** correctness 48 · ui/ux 14 · security 10 · architecture 10 · performance 6

> ### ⚠️ Read this first
> The most serious cluster is in the **dietary safety path**. The allergy check silently
> matches nothing for category allergens (the app's own placeholder examples — "peanuts,
> shellfish, tree nuts" — all show **Compatible**), and Auto-Adapt can **insert one diner's
> allergen** (almond flour for a nut-allergic member) into a recipe it labels "Adapted" and
> marks verified. These are life-safety false negatives, not polish. They also frame the
> EpiCure question: keep that dataset strictly out of allergen decisions.

> ### ⬆️ Escalation from the second pass (verified)
> The [second audit](./AUDIT-second-pass.md) pins a more severe root cause for the dietary
> cluster: `DietLibrary`/`FoodDictionary`/`SubstitutionLibrary` all load their JSON with
> `subdirectory: "Data"`, but the three files are added to Copy Bundle Resources as individual
> files in a plain group (`path = Data`) — **verified in `SousChef.xcodeproj/project.pbxproj`** —
> so Xcode flattens them to the bundle **root** and the lookups return nil. If confirmed by an
> actual build, the diet/allergy feature is **inert in shipping builds** — every ingredient
> reports "Compatible" regardless of the matching bugs below. **Fix the bundling first**
> (drop `subdirectory: "Data"` or make `Data` a folder reference), then fix the matching logic.
> This supersedes the framing of the medium finding "DietLibrary silently loads zero diets"
> and sits above C2/C3/H1/H3/H4.

---

## Critical & high findings

Each was read by an auditor and then re-checked by an independent verifier instructed to
refute it. All 27 survived.

### Critical

#### C1 — Compatibility screen crashes on any recipe with a duplicate ingredient line
`correctness` · `Sources/SousChef/Diet/ProfileMatcher.swift:57` · *flagged by 3 agents (models · diet · ui)*

- **Evidence:** `Dictionary(uniqueKeysWithValues: ingredients.map { (ingredient.rawText, compat) })`
  traps on duplicate keys, keyed by `rawText`. Imported recipes routinely repeat a line
  ("1 tsp salt" in both a cake and a frosting section; sloppy extraction; user-typed dupes) —
  nothing dedupes them.
- **Fails when:** the user opens the Compatibility sheet (`onAppear → computeResults`) on such
  a recipe → hard crash. Lookups keyed by `rawText` also collapse dupes even without the crash.
- **Fix:** key results by the ingredient's stable `id`, or use `Dictionary(_:uniquingKeysWith:)`
  keeping the worst level; update `dinerResultsFor` to match.

#### C2 — Allergy check never consults the allergen dictionary; category allergens silently match nothing
`correctness · safety` · `Sources/SousChef/Diet/ProfileMatcher.swift:92`

- **Evidence:** the loop is only `if text.contains(a) || item.contains(a)` on the diner's
  literal typed string. `FoodEntry.commonAllergens` (shrimp→shellfish, mayonnaise→eggs,
  flour→gluten) is never cross-referenced against `diner.allergies`.
- **Fails when:** the app's own placeholder suggests typing "peanuts, shellfish, tree nuts".
  "shellfish" doesn't match *shrimp/prawns/crab*; "tree nuts" matches nothing; "peanuts"
  (plural) misses "peanut butter"; "egg" misses "mayonnaise". All render **GREEN "Compatible"** —
  a false negative for an anaphylactic user.
- **Fix:** tokenize on word stems and resolve each ingredient through `FoodDictionary`; flag
  when any `commonAllergens` (with synonyms) intersects `diner.allergies`. Treat unresolvable
  ingredients as YELLOW for allergic diners, never GREEN.

#### C3 — Auto-Adapt can inject another diner's allergen into a recipe it labels "Adapted" & verified
`correctness · safety` · `Sources/SousChef/Views/CompatibilityView.swift:161`

- **Evidence:** `results.values.first(where:{ $0.level == .red })?.triggeringDiet` picks an
  *arbitrary* red diner (unordered), then takes the first substitution blindly. The first
  gluten-free swap for "flour" is `almond flour`; the copy is saved as "(Adapted)" with
  `userVerified = true` and ProfileMatcher is never re-run.
- **Fails when:** a household has a gluten-free diner + a nut-allergic diner → Auto-Adapt swaps
  flour to almond flour and presents the result as adapted & trusted. The app introduces a
  tree-nut allergen.
- **Fix:** re-run ProfileMatcher against *all* diners on the adapted list; pick the first
  option that's green for everyone (skip & flag if none). Never set `userVerified` on
  machine-generated copies. Choose the red result deterministically.

#### C4 — Cook Mode timer freezes on screen-lock/background and never alerts on expiry
`correctness` · `Sources/SousChef/CookMode/CookTimerManager.swift:137`

- **Evidence:** the countdown decrements `secondsRemaining -= 1` on a repeating `Timer` — no
  stored end `Date`, no scene-phase reconciliation, zero `UNUserNotificationCenter` usage in
  the repo, no background audio mode. Expiry "alert" is `AudioServicesPlaySystemSound` ×3,
  silenced by the ring switch and foreground-only.
- **Fails when:** the user starts a 12-min simmer, locks the phone, walks away → the app
  suspends, every second is lost, nothing ever fires. Unlocking 15 min later shows ~11:xx
  remaining while the food burns.
- **Fix:** anchor to wall clock (`endDate = Date()+seconds`, recompute on tick & on `.active`);
  schedule a `UNTimeIntervalNotificationTrigger` with `.timeSensitive` so expiry fires through
  lock; add haptics for the foreground case.

#### C5 — extractJSON off-by-one crashes on bare JSON — the exact format both prompts request
`correctness` · `Sources/SousChef/Extraction/LLMExtractor.swift:128` · `TranscriptLLMValidator.swift:158`

- **Evidence:** `String(text[start.lowerBound...end.upperBound])` — a closed range ending one
  index past the final `}`. When the response ends exactly with `}` (the normal case; both
  prompts say "Return ONLY valid JSON"), `end.upperBound == endIndex` and the subscript is a
  runtime trap. Bug is copy-pasted in both call sites.
- **Fails when:** any successful LLM extraction/validation whose text ends in `}` → crash
  mid-import.
- **Fix:** half-open range `..<end.upperBound`, guard `lowerBound < upperBound`, extract one
  shared helper, add a test with a response that is exactly `{…}`.

#### C6 — Anthropic API key ships in the app bundle and is called directly from the client
`security` · `Sources/SousChef/Info.plist:21` · `ExtractionPipeline.swift:131` · `TranscriptLLMValidator.swift:45` · *flagged by 2 agents (networking: critical · security: high for a single-user build)*

- **Evidence:** `Config.xcconfig` injects `$(ANTHROPIC_API_KEY)` into `Info.plist`, read via
  `Bundle.main.infoDictionary` and sent as the `x-api-key` header. Info.plist is plaintext in
  any distributed IPA — extractable with `unzip` + `plutil`, no reverse engineering.
- **Fails when:** anyone who installs a distributed build reads the key and runs unlimited
  billed requests; or the key gets revoked and every user's LLM fallback silently dies.
- **Fix:** never embed a shared provider key. Proxy the two Messages calls through a backend,
  or make the key user-supplied in Settings stored in Keychain. Treat any bundled key as
  public; set hard spend limits.

### High

#### H1 — No word-boundary matching → systematic false positives destroy trust in the safety signal
`correctness` · `Sources/SousChef/Diet/ProfileMatcher.swift:146`

- **Evidence:** `item.contains(r)` with raw restriction words: "egg" flags *eggplant* RED on
  vegan; "wheat" flags *buckwheat* on GF; "milk" flags *coconut/almond/oat milk* RED on
  dairy-free — contradicting that diet's own notes. Auto-Adapt then "fixes" coconut milk with
  oat milk.
- **Fix:** match whole words/tokens with a small plural stemmer; add per-restriction exception
  lists (milk except coconut/almond/oat/soy; egg except eggplant; wheat except buckwheat).

#### H2 — Auto-Adapt keeps unfixable RED ingredients in a copy titled "Adapted" & marked verified
`correctness · safety` · `Sources/SousChef/Views/CompatibilityView.swift:163` · *flagged by 2 agents (diet · ui)*

- **Evidence:** for allergy/custom reds, `triggeringDiet` is "Allergy"/"Custom Restriction" —
  not a diet id — so `options(for:diet:)` returns `[]` and `sub?.first ?? ingredient.item`
  keeps the allergen. Same when options are explicitly `nil` (butter on keto). The dialog
  promises "substitutions applied for all flagged ingredients."
- **Fails when:** a peanut-allergic household member — the peanut line survives unchanged in the
  "verified" adapted copy with no warning.
- **Fix:** track which flagged ingredients couldn't be substituted; show a post-adapt summary
  ("3 substituted, 2 could not be fixed — still unsafe for Sam"). Distinguish `nil` (prohibited)
  from `[]` (no data).

#### H3 — Religious diets miss common forms — bacon & prawns show GREEN for kosher
`correctness` · `Sources/SousChef/Resources/Data/diets.json:127`

- **Evidence:** kosher has empty `restrictedCategories` and lists "pork, shrimp, lobster…" — but
  "bacon", "ham", "prosciutto", "pancetta", "prawns" contain none of those substrings, and with
  no category the dictionary resolution never fires. Halal similarly misses
  pancetta/sausage/pepperoni and all spirits.
- **Fix:** add pork-derived + shellfish categories and the missing product words; add spirits to
  the dictionary with an "alcohol" category.

#### H4 — Gluten-free misses couscous/seitan/oatmeal; low-sodium never flags "salt"
`correctness` · `Sources/SousChef/Resources/Data/diets.json:72`

- **Evidence:** GF lists "flour, bread, pasta, oats" — "couscous" and "seitan" (pure gluten)
  match nothing → GREEN for a celiac user; "orzo" only reaches YELLOW. Low-sodium lists sauces
  but omits "salt" itself, so "2 tsp salt" is GREEN on a <1500 mg/day diet.
- **Fix:** add couscous, seitan, orzo, malt, "gluten" to GF; add "salt" to low-sodium; make
  `restrictedCategories` non-empty so category resolution contributes.

#### H5 — Every saved recipe loses its source URL, platform, and photo
`correctness` · `Sources/SousChef/Views/ReviewView.swift:298` · *flagged by 3 agents (models · ui · engagement)*

- **Evidence:** `sourceURL: extractionResult.ingredients.isEmpty ? nil : nil` — both branches
  nil. `sourceType` is hardcoded to "web"/"web-search-substitute". `thumbnailURL` has no field
  to land in. The pipeline already fetched all three.
- **Fails when:** every TikTok/YouTube import shows a "WEB" badge, "sort by Source" is
  meaningless, and the original page/video can never be reopened.
- **Fix:** persist `recipePageURL ?? originalSourceURL`; derive `sourceType` from `URLRouter`;
  add a `thumbnailURL` field to `Recipe`. (Also unblocks library thumbnails & a "View original"
  link.)

#### H6 — CloudKit container can never initialize; the failure is swallowed and a migration fault becomes a launch crash-loop
`architecture` · `Sources/SousChef/SousChefApp.swift:12`

- **Evidence:** `cloudKitDatabase: .automatic` but the schema is CloudKit-incompatible on three
  counts: `@Attribute(.unique)` ids, non-optional attributes without defaults, non-optional
  to-many relationships. The `try?` throws every launch → silent local-only; advertised sync is
  dead. The `try?/try?/fatalError` ladder turns a future failed migration into an unrecoverable
  crash-loop with no diagnostics.
- **Fix:** make the schema CloudKit-conformant (drop `.unique`, add defaults, optional
  relationships) + add the entitlement, or remove the cloud config. Log the thrown error;
  replace `fatalError` with a recovery path.

#### H7 — Voice recognition stops after Apple's ~60-second limit and is never restarted
`correctness` · `Sources/SousChef/CookMode/CookVoiceController.swift:112`

- **Evidence:** server-based `SFSpeechRecognizer` requests end after ~1 min; the completion path
  only sets `isListening = false`. Restart triggers exist only on TTS finish and after a
  recognized command.
- **Fails when:** "Simmer for 20 minutes" → the user waits; ~60s after TTS ends, recognition
  dies and every "next"/"stop timer"/"repeat" is ignored for the rest of the step — precisely
  when hands are wet and voice was the whole point. The only cue is a dimming mic glyph.
- **Fix:** restart listening after a short delay whenever still active and not speaking (with
  error backoff); set `requiresOnDeviceRecognition = true` where supported to remove the limit.

#### H8 — Advancing to the next step destroys the running timer — no way to simmer while you prep
`ui/ux` · `Sources/SousChef/Views/CookModeView.swift:104`

- **Evidence:** `advance(by:)` calls `timerState.stop()` unconditionally on every step change
  (tap, swipe, voice "next"/"back").
- **Fails when:** "Simmer 20 min" → start timer → "next" to chop garnish → timer is silently
  obliterated, unrecoverable except by re-entering the duration. The pinned-timer visual design
  implies the opposite.
- **Fix:** let a running timer survive navigation (it already renders pinned); only offer a new
  timer when the new step has one, with a replace confirmation. Longer term: a small list of
  concurrent timers keyed by step.

#### H9 — IngredientAnnotator splices measurements into stale offsets, mangling step text that's read aloud
`correctness` · `Sources/SousChef/Extraction/IngredientAnnotator.swift:44`

- **Evidence:** match ranges are computed against the original `lowered` text but inserted into
  the progressively mutated `result`. Ingredients iterate longest-name-first, not by position,
  so later insertions land short by the earlier insertion's length.
- **Fails when:** "Add the olive oil and garlic." → `"Add the olive oil (2 tbsp) a (1 clove)nd garlic."`
  — shown at 26pt and spoken by TTS.
- **Fix:** collect all matches first, apply insertions in descending position order against the
  original string; add a two-ingredient test with the longer name first.

#### H10 — MicroStepSplitter silently drops instruction content & fabricates nonsense steps
`correctness` · `Sources/SousChef/Extraction/MicroStepSplitter.swift:90`

- **Evidence:** `parseObjectList` filters comma parts >4 words but proceeds if 3+ short parts
  remain, so the filtered part vanishes. Trailing verb clauses survive and become "objects".
- **Fails when:** "Add the flour, sugar, salt, and the softened butter cut into cubes." → the
  butter step is gone. "…onion, garlic, and cook until fragrant, about 2 minutes." → "Add cook
  until fragrant." + "Add about 2 minutes." (the latter even triggers a bogus timer) — all
  spoken aloud.
- **Fix:** abort the compound split (return the original sentence) whenever any part is filtered
  out or fails a noun-phrase check. Losing a split is safe; losing an ingredient or inventing
  steps is not.

#### H11 — StepSequencer can move a preheat past an intermediate oven step → bake in a cold oven
`correctness` · `Sources/SousChef/Extraction/StepSequencer.swift:27`

- **Evidence:** the reorder checks oven use exists *after* the downtime but never checks steps
  *between* the preheat and the wait. For a par-bake ("Preheat" → "Bake crust 10 min" →
  "Chill 30 min" → "Bake pie 25 min"), it moves the preheat after the crust bake.
- **Fails when:** any two-bake / par-bake / toast-then-chill recipe — the intermediate bake now
  precedes the preheat. This is exactly the hazard the module comment claims to avoid; no test
  covers it.
- **Fix:** bail if any step in `(preheatIdx+1)..<waitIdx` is oven use; broaden `isOvenUse`
  ("toast", "in the oven"); add a regression test.

#### H12 — Three network layers point at hardcoded http://localhost:8000 — dead on every real device
`correctness` · `TranscriptFetcher.swift:25` · `WebRecipeSearcher.swift:34` · `CreatorProfileSearcher.swift:128` · *flagged by 2 agents (networking · security)*

- **Evidence:** Whisper transcript fetch, server recipe search, and Stage-0 creator-profile
  search all target `http://localhost:8000`. On a user's phone nothing listens there (and plain
  HTTP needs an ATS exception). Every call is wrapped in `try?`, so failure is invisible.
- **Fails when:** video imports silently lose the transcript layer and profile search, degrading
  to caption-only — no error surfaced.
- **Fix:** move the base URL to build config with an HTTPS production value; treat unreachable
  server as an explicit logged state, not a `try?` swallow. At minimum gate the localhost
  default behind `#if DEBUG`.

#### H13 — LLM web-page fallback (Layer 4) is never wired in — an advertised feature is missing
`architecture` · `Sources/SousChef/Extraction/ExtractionPipeline.swift:320`

- **Evidence:** `extractFromHTML` ends with `// Layer 4: LLM fallback — stub`; the entire
  147-line `LLMExtractor` actor is unreferenced. The README promises "…→ LLM fallback".
- **Fails when:** any blog without structured data (older/custom recipe sites) returns a
  low-confidence heuristic result instead of the working LLM extraction the code already
  contains.
- **Fix:** call `LLMExtractor.extract(html:)` in the async web path when layers 1–3 fall below
  the reject threshold and a key is configured; take the higher-confidence result. Or
  delete/feature-flag the dead actor + its embedded prompt.

#### H14 — "Similar recipes" (Stage B) can never produce results and silently refetches pages
`correctness` · `Sources/SousChef/Extraction/ExtractionPipeline.swift:223`

- **Evidence:** Stage B is only reached after Stage A2 found no `isViable` candidate, then
  re-runs extraction on the same candidates with the same `isViable` predicate — same verdict,
  so `alternatives` is always empty. The "no extra network call" comment is false:
  `extractFromWebPage` refetches each URL (up to 3 redundant downloads).
- **Fix:** cache each candidate's result in Stage A2; return the first viable one, else populate
  `alternatives` from the cache using a lower bar (title + some ingredients) instead of
  refetching.

#### H15 — There is no way to delete a recipe anywhere in the app
`ui/ux` · `Sources/SousChef/Views/RecipeLibraryView.swift:63` · *flagged by 2 agents (ui · models)*

- **Evidence:** the library grid has no swipe action, context menu, or edit mode;
  `RecipeDetailView` offers no delete. Repo-wide, `modelContext.delete` is called only for
  `DinerProfile`.
- **Fails when:** every failed/duplicate/test import accumulates forever; the only escape is
  deleting the app (which, with CloudKit `.automatic`, may not even clear the data).
- **Fix:** add a destructive Delete (with confirmation) via `.contextMenu` on the card and in
  detail; cascade rules already handle ingredients/steps.

#### H16 — Microdata prep/cook times are silently lost because SwiftSoup `attr()` returns "" not nil
`correctness · parser re-audit` · `Sources/SousChef/Extraction/MicrodataExtractor.swift:74`

- **Evidence:** `(try? el.attr("datetime")) ?? (try? el.attr("content")) ?? (try? el.text())` —
  SwiftSoup's `attr` returns `Optional("")` when absent, so the `??` chain stops at the first
  element and never consults `content` or text.
- **Fails when:** common markup `<time itemprop="prepTime" content="PT15M">15 minutes</time>`
  (no `datetime`) → value is "" → prep/cook/total time silently dropped though the duration was
  present.
- **Fix:** treat empty as missing:
  `[attr("datetime"), attr("content"), text()].compactMap{$0}.first{!$0.isEmpty}`, or check
  `hasAttr` first.

#### H17 — Heuristic title fallback splits on hyphens — hyphenated recipe titles get truncated to one word
`correctness · parser re-audit` · `Sources/SousChef/Extraction/HeuristicExtractor.swift:63`

- **Evidence:** `title.components(separatedBy: CharacterSet(charactersIn: "|-"))` splits on
  *any* hyphen, not just the site separator.
- **Fails when:** a page with no structured data: "Bang-Bang Shrimp | Food Blog" → "Bang";
  "Slow-Cooker Beef Stew - MySite" → "Slow".
- **Fix:** split only on space-delimited separators — `" | "` then `" - "` — preserving
  intra-word hyphens.

---

## Medium findings

De-duplicated, grouped by dimension.

### Correctness

| Finding | Location |
|---------|----------|
| `DietLibrary` silently loads **zero diets** on any bundle/decode failure — disabling every diet safety check with no signal | `DietDefinition.swift:38` |
| Import cancellation is swallowed by pervasive `try?` — a cancelled import keeps running the whole network + paid-LLM chain | `ExtractionPipeline.swift:42` |
| StepSequencer moves a preheat to the start of **arbitrarily long** downtime — oven left running for hours (overnight marinade) | `StepSequencer.swift:52` |
| Per-side timer's delayed reset closure is never cancelled and clobbers a subsequently configured timer | `CookTimerManager.swift:182` |
| `pieceTable` ordering + substring match give large weight errors: cherry tomato at 150 g, eggplant at 50 g | `IngredientConverter.swift:218` |
| oEmbed request URL built with `.urlQueryAllowed` — video URLs containing `&` get truncated | `VideoMetadataFetcher.swift:148` |
| Anthropic error paths collapse into one opaque error: no 429/529 backoff, no `stop_reason`/truncation check | `TranscriptLLMValidator.swift:50` |
| Auto-Adapt copy drops `recipeDescription`, step temperature, and timer labels | `CompatibilityView.swift:182` |
| Review validation runs once `onAppear` and never re-runs after edits — stale before save | `ReviewView.swift:63` |

### Extraction / parsing core *(parser re-audit, unverified pass)*

| Finding | Location |
|---------|----------|
| `IngredientAnnotator` treats UTF-16 (NSRange) offsets as Character offsets — emoji before a match (common in TikTok step text) mis-place the measurement and can **trap/crash** | `IngredientAnnotator.swift:44` |
| ISO8601 duration parser drops decimal components — `PT1.5H` returns nil, so a 90-min time reads as absent | `ISO8601DurationParser.swift:22` |
| Compound durations truncated to first component — "1 hr 30 min" → 60 min (also in TranscriptExtractor) | `HeuristicExtractor.swift:187` |
| En-dash ranges not parsed as quantities — "2–3 cloves garlic" loses its quantity (ASCII "2-3" works) | `IngredientParser.swift:132` |
| Word-number + fraction abandoned — "one and a half cups flour" parses quantity as "1", item as "and a half cups flour" | `IngredientParser.swift:89` |
| Numeric JSON-LD `recipeYield` (`"recipeYield": 4`) is dropped — only String/[String] handled | `SchemaOrgExtractor.swift:74` |
| HTML entity decoder ignores hex entities (`&#x27;`, `&#xe9;`) — shown verbatim in titles/ingredients | `SchemaOrgExtractor.swift:212` |
| Explicit schema.org `tool` appliances are overwritten by keyword detection (stand mixer, candy thermometer lost) | `SchemaOrgExtractor.swift:107` |
| Heuristic ingredient regex requires a leading ASCII digit — lines starting with "½ cup" are missed | `HeuristicExtractor.swift:92` |
| `ApplianceDetector` reports a kitchen scale for any recipe listing grams / containing "weigh"; temp regex misfires on "12 c," | `ApplianceDetector.swift:87` |
| Direct-URL detection captures trailing punctuation — "recipe at https://…/pasta." keeps the dot → 404 | `CaptionAnalyzer.swift:101` |
| Web pipeline parses the full HTML with SwiftSoup 2–3× per page (once per layer); `doc.text()` computed twice | `ExtractionPipeline.swift:301` |
| Quantity/unit/fraction/entity logic is duplicated & **divergent** across IngredientParser, TranscriptExtractor & HeuristicExtractor — same string parses differently by layer | `TranscriptExtractor.swift:72` |

### Security & privacy

| Finding | Location |
|---------|----------|
| Prompt injection: untrusted page text & transcripts are interpolated raw into LLM prompts — a malicious recipe page can steer extraction output | `LLMExtractor.swift:61` |
| Continuous kitchen audio is streamed to Apple's servers whenever TTS is idle; on-device recognition is never requested | `CookVoiceController.swift:96` |
| User data sent off-device to Anthropic, Google & social platforms with no disclosure or consent surface | `ImportView.swift:412` |
| Google CSE API key embedded in Info.plist and sent in the URL query string | `WebRecipeSearcher.swift:76` |

### Architecture

| Finding | Location |
|---------|----------|
| In-flight import is never cancelled when the sheet is dismissed — network & paid LLM calls continue | `ImportView.swift:320` |
| No `VersionedSchema`/migration plan; stringly-typed enum fields (`sourceType`, `extractionMethod`) make schema evolution risky | `Recipe.swift:9` |
| No explicit `modelContext.save()` or error handling anywhere — all persistence rides on implicit autosave | `ReviewView.swift:327` |
| `WebPageFetcher` claims redirect control (`maxRedirects`/`tooManyRedirects`) that is dead code | `WebPageFetcher.swift:34` |
| `ReviewView` nests a `NavigationStack` inside a `navigationDestination` push | `ReviewView.swift:38` |
| `hiddenRestrictions` are unmatched prose — the YELLOW layer is mostly dead, and some entries are exceptions phrased as restrictions | `diets.json:95` |

### Performance

| Finding | Location |
|---------|----------|
| Levenshtein `fuzzyFind` over the whole dictionary runs per ingredient **per diner**, synchronously on the main thread | `ProfileMatcher.swift:103` |
| Library filters & sorts the entire recipe set in memory on every keystroke | `RecipeLibraryView.swift:19` |
| Video import has no overall deadline — worst case is 20+ sequential requests over several minutes | `ExtractionPipeline.swift:38` |
| `WebPageFetcher` loads arbitrary URLs fully into memory with no size or content-type guard | `WebPageFetcher.swift:51` |

### UI/UX & accessibility

| Finding | Location |
|---------|----------|
| Body/label/caption fonts don't scale with Dynamic Type — fixed point sizes throughout the design system | `DesignSystem.swift:55` |
| Safety status is conveyed by color-only dots — indistinguishable for red-green colorblind users, no VoiceOver semantics | `CompatibilityView.swift:232` |
| Denying mic/speech permission silently disables TTS read-aloud too, with zero user feedback | `CookModeView.swift:60` |
| Substring command matching false-triggers on ambient speech; a misheard "next" on the last step instantly exits Cook Mode | `CookVoiceController.swift:175` |
| "Start timer" voice command is a no-op on the first step (and any step where the timer wasn't pre-configured) | `CookModeView.swift:131` |

---

## Low findings

| Finding | Location |
|---------|----------|
| Quantity formatting glitches: "¼ cups", "0 lb 8 oz", and 1.95 rendered as "1 ⅞" | `IngredientConverter.swift:352` |
| Density lookup's bidirectional `contains` matches bare/partial items to the wrong densities | `IngredientConverter.swift:260` |
| `CookingStep.duration/temperature/timerLabel` are dead schema fields — Cook Mode re-parses instruction text instead | `Recipe.swift:74` |
| Instagram oEmbed fallback targets an endpoint retired in 2020 | `VideoMetadataFetcher.swift:35` |
| `BioLinkResolver` per-host rate limit isn't enforced across concurrent resolves (actor reentrancy) | `BioLinkResolver.swift:205` |
| Google CSE key passed in the URL query string, and the config keys are never actually wired | `WebRecipeSearcher.swift:76` |
| No `PrivacyInfo.xcprivacy` manifest despite required-reason APIs & third-party data collection | `BioLinkResolver.swift:25` |
| `WebPageFetcher` claims manual redirect control it doesn't implement, and accepts any URL scheme with no size cap | `WebPageFetcher.swift:34` |
| Dismissing the onboarding import sheet for any reason ends onboarding | `OnboardingView.swift:42` |
| No voice command to dismiss the ingredients sheet; navigation commands still act on the hidden step behind it | `CookVoiceController.swift:169` |
| Tag remove button is a ~19pt tap target (below the 44pt minimum) | `TagInputView.swift:101` |

---

## Additional findings from the second pass

Issues surfaced by [`AUDIT-second-pass.md`](./AUDIT-second-pass.md) that this report did not
have (or rated lower). See that document for full evidence and fixes.

| Sev | Finding | Location |
|-----|---------|----------|
| High | **Diet/food/substitution JSON never loads in the shipping bundle** (`subdirectory: "Data"` → nil) — the escalation noted above | `DietDefinition.swift:39` + sibling loaders |
| High | **Integer-overflow crash** converting an untrusted duration — "cook for 99999999999999999999 minutes" traps on `Int(...)` before the `>= 10` guard | `CookTimerManager.swift:84` |
| High | **SSRF** — scraped URLs fetched with no scheme/host validation, reaching loopback/LAN; redirect check is a no-op so any host guard is bypassed | `WebPageFetcher.swift:51` · `:34` |
| Medium | Untrusted `thumbnailURL`/`recipePageURL` from the search path flow into `AsyncImage`/`Link` with no `https`/host check | `SimilarRecipePreviewSheet.swift:69` |
| Medium | **Retain-cycle leak** of `CookVoiceController` (with its audio engine/recognizer) on every Cook Mode visit — `onCommand` never cleared | `CookModeView.swift:63` |
| Medium | Reverse-substring density mapping — "ice" → rice flour, "corn" → cornstarch — materially wrong conversions | `IngredientConverter.swift:260` |
| Low | Auto-Adapt on a yellow-only recipe produces an identical "(Adapted)" duplicate with nothing changed | `CompatibilityView.swift:137` |
| Low | Constant regex sets recompiled on every call on the extraction path | `CaptionAnalyzer.swift:122` |
| Low | `@unchecked Sendable` singleton with `var` write-once state — suppresses the race check | `FoodDictionary.swift:55` |

---

## Subsystem health

| Subsystem | State | Notes |
|-----------|-------|-------|
| **Dietary logic** | 🔴 Needs work | Well-structured RED/YELLOW/GREEN layering, but core matching is naive case-insensitive substring containment with no word boundaries and no allergen-category mapping — producing both dangerous false negatives and constant false positives. Auto-Adapt can introduce one diner's allergen while fixing another's and never re-validates. The highest-risk area in the app. |
| **Cook Mode** | 🔴 Needs work | Clean MainActor isolation and a conservative, tested StepSequencer — but it fails where a kitchen product must not: the timer freezes on lock and never alerts, speech recognition dies after ~60s, and the text pipeline can drop or mangle instructions that are then read aloud. Strong happy-path demo; several first-cook bugs. |
| **Networking / Search / LLM** | 🟠 Fragile | Thoughtfully layered and failure-tolerant — but tolerance comes from blanket `try?` that hides dead endpoints (localhost:8000), a never-wired LLM layer, and a crashing JSON helper. Valid Haiku model id and headers, but the key ships client-side and error handling has no retry/backoff or truncation detection. |
| **Data models & persistence** | 🟠 Fragile | Small, mostly sane schema, but provenance is discarded on every save (always-nil bug), CloudKit can never initialize yet its failure is swallowed, and a rawText-keyed dictionary crashes on duplicate lines. No migration plan, no explicit save/error handling, no delete path. |
| **UI layer & design system** | 🟡 Solid, gaps | Visually coherent, idiomatic SwiftUI with good empty states and a thoughtful import-failure flow. Real defects: the compatibility crash surfaces here, saved recipes lose source/photo, Auto-Adapt over-promises, no delete, weak accessibility (fixed fonts, color-only status), and the import task isn't cancelled on dismiss. |
| **Security & privacy** | 🟡 Solid, gaps | Repo secret hygiene is genuinely good — git history holds no live key, secrets gitignored, CI uses an empty key. Runtime is weaker: the key ships in plaintext Info.plist, scraped text flows into prompts with no injection hardening or disclosure, and Cook Mode streams kitchen audio to Apple when on-device would do. |
| **Extraction / parsing core** | 🟠 Fragile | Happy-path layers work, but correctness defects cluster in HTML-attribute handling, entity decoding, and numeric/range/duration parsing — silently dropping durations, yields, hyphenated titles, and unicode-fraction ingredients on common inputs. Quantity/unit/fraction logic is duplicated and divergent across three extractors, and only IngredientParser + URLRouter have any tests. |

---

## Engagement & retention roadmap

How to keep users in the app longer per session and coming back across the week — every idea
grounded in code that already exists.

**The core problem:** engagement is confined to two transactional moments — import and cooking —
with nothing persisted about the cook and no reason to open the app between cooks. Every flow
ends by `dismiss()`ing back to a static library. The single highest-leverage fix is **closing
the post-cook loop**: the last Cook Mode step literally discards the session. Capturing it turns
every cook into stored state that powers history, resurfacing, digests, and sharing.

### Quick wins (low effort, build on what's shipped)

1. **Post-cook wrap-up: rating, notes, photo, cook count** — *habit loop.* Replace the final-step
   `dismiss()` with a wrap-up sheet (stars, a note, optional photo) incrementing new
   `timesCooked/lastCookedAt/rating/notes/photo` fields. The keystone the other ideas depend on.
   *Builds on:* `CookModeView.goNext()/isLast` · `Recipe` model (`dateAdded/userVerified`
   precedent) · `DinerProfile.favoriteFoods` inline-default migration pattern.
2. **Fulfill the `favoriteFoods` promise — "Tonight's picks" row** — *more visits.* The profile
   editor collects `favoriteFoods` under a footer saying "Used for personalized suggestions" —
   but nothing reads it. Score recipes by matching ingredients against diners' favorites + green
   compatibility. *Builds on:* `DinerProfile.favoriteFoods` (unused) · `FoodDictionary.fuzzyFind`
   · `ProfileMatcher` · `Ingredient.item`.
3. **Cook history, streaks & "never cooked" resurfacing** — *retention.* Extend `SortOption` with
   "Most Cooked"/"Recently Cooked", add a "Cooked 4×" badge, pin a "Saved 2 weeks ago, never
   cooked" shelf from `dateAdded` vs `lastCookedAt`. *Builds on:* `RecipeLibraryView.SortOption` ·
   RecipeCard badge row · `Recipe.dateAdded` · post-cook fields.
4. **Close the Auto-Adapt dead end + servings scaler** — *longer sessions.* Land on the adapted
   recipe with a "what changed" diff and a Cook button; add a "Serves 2/4/8" stepper on detail
   (the ingredient pipeline already parses fractions). *Fix the safety bugs C3/H2 before promoting
   Auto-Adapt.* *Builds on:* `CompatibilityView.autoAdapt()` · `RecipeDetailView` ·
   `IngredientConverter.parseQuantity()/display()` · `Recipe.recipeYield`.

### Bigger bets (higher effort, larger payoff)

5. **iOS Share Extension — import from the TikTok/Instagram/YouTube share sheet** — *more visits.*
   The largest frequency lever in the codebase; a share-extension target hands the URL straight to
   the existing pipeline (`URLRouter` already classifies these hosts). *Builds on:*
   `ExtractionPipeline` + `URLRouter` · ImportView's clipboard flow it replaces · `Recipe.sourceType`.
6. **Shopping list aggregated from structured ingredients** — *habit loop.* Ingredients already
   store parsed `quantity/unit/item/section`, and `IngredientConverter` can normalize & sum across
   recipes. A "Cook this week" multi-select producing a checkable, section-grouped list creates the
   guaranteed twice-weekly grocery-store app open. *Builds on:* `Ingredient` fields ·
   `IngredientParser` · `IngredientConverter.parseQuantity/canonicalUnit` · `RecipeLibraryView`.
7. **Weekly meal planner with per-diner compatibility** — *habit loop.* A Mon–Sun planner with
   ProfileMatcher pre-computing the red/yellow/green dot row per meal so conflicts surface at
   planning time; feeds the shopping list. *Builds on:* `ProfileMatcher.match()` +
   `CompatibilityView.dinerLegend` · `Recipe.totalTime/recipeYield` · a new `MealPlanEntry @Model`.
8. **Local notifications + household CloudKit sharing** — *retention / social.* Add cook reminders
   and a Sunday digest, each deep-linking into the cook funnel; longer term, `CKShare` over the
   already-configured CloudKit container makes a partner a daily-active surface. The data model was
   multi-person (`DinerProfile`) from day one, so "add your partner" is a built-in referral.
   *Builds on:* `Recipe.dateAdded` + `lastCookedAt` · `SousChefApp` ModelContainer
   `cloudKitDatabase:.automatic` · `DinerProfile`.

### Ties into EpiCure

The pairing/similarity engine (Kaikaku EpiCure, CC BY 4.0 / MIT) slots directly into this
roadmap — offline "more like this" across the user's own library, "pairs well with," and
browse-by-cuisine are all discovery surfaces with no safety exposure. **Keep EpiCure strictly out
of the allergen path** (findings C2/C3/H2), where it must never remove or downgrade a flag.
