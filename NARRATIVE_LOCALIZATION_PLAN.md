# Narrative localization plan

Status: design plan, rewritten October 11, 2026 for the project's actual targets.
T1–T4 and the first scene-line catalog integration are implemented (October 12, 2026);
scene keys are `scene.<line-id>.text`, character names `character.<id>.name`.
Menu label and character-name rendering in scenes remain authored-text only.
The historical inventory below predates these implementations. The [Varis Reference Manual](docs/README.md) remains authoritative for current
semantics. Later sections retain the target design; implemented commands and template
syntax are documented in the manual, while remaining proposals are identified below.

The first version of this plan (commit `dbb0960` and earlier) was a general design centred on an
English/Arabic slice, MessageFormat 2 and UUID annotations. Its right-to-left, bidi and
multi-script material is deferred, not rejected; read it there if a right-to-left language is
ever committed.

Revised October 12, 2026: added what exists today (§1a) and the workflows by role (§7); the
stages (§9) are reordered so that extraction can start on today's syntax, and renamed from
`L0`–`L4` to `T0`–`T5`, because `L1`–`L4` are the Lua-core stages of
[benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md). The tools this plan relies on
(project manifest, project index, checker) are in [AUTHORING_TOOLS_PLAN.md](AUTHORING_TOOLS_PLAN.md),
which also gives the combined order of the two plans.

## 1a. What exists today

| Piece | Today | Remaining limits |
| --- | --- | --- |
| Display text and keys | Storylet/choice fields, quality labels, named symbols, scene lines and character names are indexed when literal. Scene line keys are `scene.<line-id>.text`. | Computed text cannot be extracted; scene menu labels are not cataloged. Explicit scene ids are recommended over positional defaults. |
| Rendering | Selection captures bindings, condition outcomes and variant draws. `session:render` and `set_language` re-render without changing tokens, turns or RNG. Scene line text is translated. | Scene menu labels and character metadata still render authored text; structured rich-text spans are unfinished. |
| Variants and templates | Named variants, plural and select blocks, generated plural rules, translated names and pseudo-localization exist. | Legacy unnamed variants retain positional identity. |
| Fingerprints and saves | Wording is excluded from format 2/3 content identity; template structure remains significant. Format 1 retains legacy validation. Translations are never saved or fingerprinted. | Structural edits still invalidate content identity; scene saves use format 3. |
| Catalogs and handoff | Extract/status, CSV/JSON/XLIFF, revision tracking, kits/delta kits, glossary, import/review, checks, packs and character-set output. | Font subsetting itself and configurable per-locale manifest coverage remain unfinished. |
| Tools and presentation | CLI locale options, workbench selector/editor, engine grapheme/line-break/ruby/particle helpers, initial SDL3 scene player with a supplied UTF-8 font. | Complete CJK layout, font fallback within one text run (per-language font switching exists), ruby drawing and native-reader validation remain T5 work. |

## 1. Targets and what they imply

| Fact (owner, October 11, 2026) | Consequence |
| --- | --- |
| Distribution mainly through Steam; Windows, macOS, Linux first, Android if practical | One global build with selectable languages. No per-region editions are planned; nothing here should prevent adding a build-time content flag later. |
| A publisher may translate and localize for Simplified Chinese, Traditional Chinese (Hong Kong, Taiwan), Japanese and Korean | Translation is done by people outside the project, without the source tree. The deliverable is a **handoff kit** and a way for them to load and check their own work. |
| The owner can test French and Russian | These are the in-house test locales. Usefully, they exercise what Chinese, Japanese and Korean do not: plural categories, gender agreement and case. |
| Writers are contractors and often not programmers | Localization must add nothing to what a writer types. Keys come from names writers already choose. |
| SDL3 front end on low-end hardware | No large Unicode library in the engine. Fonts for these scripts are the main memory and packaging cost. |
| All original content is authored in English, and English is the first release language | English is the source language of the base game. Extraction, checking and the fingerprint split (§3) come before any translation feature. |
| There should be room for mods in other languages | The source language is a property of a content package, not of the engine. Nothing may assume that source text is English or ASCII. See §3.8. |
| Catalog formats should be as flexible as possible, since others may use Varis | No format is privileged. One canonical model, with formats as adapters (§6.2). |

## 2. Design principles (kept from the first version)

1. **Language is a view.** Eligibility, effects, choice identity, draws, turns and saves never
   depend on the selected language. One session can be rendered in several languages.
2. **Selection is separate from rendering.** A presentation captures bindings, condition results,
   chosen variants and tokens once. Rendering it in a language is a pure function that consumes
   no random numbers and issues no new tokens. Switching language re-renders; it never calls
   `present()` again.
3. **Translations are data.** A translated message can reorder, repeat or omit its arguments and
   choose among declared grammatical branches. It cannot add conditions, queries, effects,
   weights or random choices.
4. **Whole messages.** Translators get complete sentences or paragraphs, never fragments glued
   together by code. A message with a missing translation falls back as a whole.
5. **The engine does not lay out text.** Shaping, fonts, line breaking and text boxes belong to
   the presentation layer. The target output is structured spans in logical order; current presentations
   still carry rendered strings.

## 3. Decisions to freeze with the syntax (ROADMAP milestones 27 and 29)

These are cheap to decide now and expensive to retrofit. None of them requires a translation to
exist.

1. **Keys come from authored names.** A storylet's title is `topic_lamp.title`, a choice's is
   `topic_lamp.nod.title`, a scene line uses the stable line id of milestone 29. Renaming a
   storylet already breaks saves, so these names are already permanent; no generated identifiers
   appear in content files. The language services' rename operation (ROADMAP milestone 32, exposed through the
   language server) rewrites catalogs; workbench UI rename is unfinished. Two messages with the
   same English text stay separate.
2. **Scene lines need an id that survives editing.** Lines have no authored name, and an id
   derived from position breaks when a line is inserted. The implemented declarative beats use an explicit `id` field, falling back to
   `<scene>.<beat-index>`. Positional ids do not survive insertion, so authors should set
   explicit ids. Registry validation rejects duplicate text ids. Automatic tool-written
   tags for a future compact syntax remain proposed.
3. **One template grammar.** The Varis template language gains named placeholders (already
   present), a `select` on a declared value with a required fallback branch, a plural select on a
   number, and **named** variant alternatives. Translators write the same grammar as writers.
   MessageFormat's ideas are used; its syntax is not added as a second language.
4. **Named variants, not indices.** Replay logs record which alternative was drawn by name, so a
   translation can reorder alternatives and the log format never needs migrating.
5. **Literal display text in content files.** Titles, text and dialogue are string literals with
   placeholders; the checker rejects computed strings there and flags byte-oriented operations
   (`#`, `string.sub`) applied to display text. Extraction then needs no execution.
6. **Wording leaves the gameplay fingerprint (implemented T2).** Formats 2/3 split it:
   conditions embedded in text and the structure of variants stay in the gameplay fingerprint;
   wording moves to a presentation revision. This is worth doing even with no translations.
7. **Presentation output is spans.** Rendered text is a sequence of spans carrying markup
   (emphasis, colour, pauses, ruby annotations) and, for substituted values, a marker that they
   are data. Arguments can never inject markup.
8. **Content comes in packages, and a package declares its source language.** The base game is
   one package with source language English. A mod is another package: it may add translations
   of an existing package (a language pack), or new content written in any language, which can
   in turn be translated. Message keys are qualified by package, so two mods cannot collide.
   This is the minimum needed to leave room for modding; load order, how mods extend sealed
   content and how saves record the set of packages are a separate design, not part of this
   plan. Whether identifiers (as opposed to display text) may use non-ASCII letters is a
   milestone 27 decision. The restricted content tier of ROADMAP milestone 26 is also what makes
   loading someone else's content-only package safe; script mods use the full language and
   are trusted like any program (ROADMAP open decision 6).

## 4. What each target language needs

| Language | Needs from templates and data | Needs from the presentation layer |
| --- | --- | --- |
| Simplified and Traditional Chinese | Measure words: "3 apples" takes a classifier that depends on the noun, so items carry a translatable classifier or the message selects on the item. No plural forms. Two separate catalogs (`zh-Hans`, `zh-Hant`) with no automatic fallback between them. | Line breaking without spaces, with punctuation that may not start or end a line. Full-width punctuation. |
| Japanese | No plural forms. Counters, like Chinese classifiers. Honorifics and sentence endings vary by speaker and listener, so translators restructure whole lines. | Same line breaking rules. **Ruby** (small reading annotations above characters) as a span type. |
| Korean | Particles change with the final sound of the preceding word (은/는, 이/가, 을/를), which matters whenever a name is substituted. Provide a built-in formatter that picks the particle from the substituted text's last syllable. | Breaks at spaces, and within words where the font size demands. |
| French | Plural categories (0 and 1 are singular), gender agreement with substituted nouns, elision (`le`/`l'`). Substituted names and items need a declared gender; elision needs a select or a formatter. | Non-breaking spaces before some punctuation. |
| Russian | Four plural categories (one, few, many, other) and six cases: a substituted name must be supplied in the form the sentence needs, so `narrative.name` labels need optional per-case forms. Gendered past-tense verbs. | Nothing unusual. |

Shared consequences:

- **Plural rules** come from a small generated table for the shipped languages, not a Unicode
  library. Chinese, Japanese and Korean use a single category; French and Russian exercise the rest.
- **Names and labels** (`narrative.name`, quality labels, character names) are translatable and
  can carry grammatical attributes: gender, classifier, case forms. Nothing is inferred from a name.
- **Fonts are per language.** Chinese, Japanese and Korean share many code points but need
  different glyphs, so the font chain is chosen by language, not by character. The catalog
  compiler emits the set of characters each language actually uses, so fonts can be subset; a
  full font for one of these scripts is 10–20 MB.
- **Text is counted in graphemes.** Typewriter reveal, truncation and length limits never cut a
  character in half.
- **Player-entered names** need input-method support in the front end, and are substituted as data.

## 5. The presentation layer's share (ROADMAP milestone 36)

The standard SDL3 presentation layer, not the engine, implements:

- Line breaking for scripts without spaces, including the prohibited-position rules, and
  ordinary breaking for the others.
- Per-language font selection, fallback and glyph caching.
- Ruby annotations, emphasis, colour, pauses and text speed from the span stream.
- A language switch that asks the engine to re-render the current presentation.

Localized assets (images with text in them, voice) are resolved through the asset manifest by
language, with fallback to the source asset. The engine only names the asset.

## 6. Catalogs and the publisher handoff

### 6.1 Catalog model

One canonical catalog model per package and language, held in D and stored in the repository
as deterministic UTF-8 JSON so it diffs well. Each entry holds the key, the source text and its
revision hash, the translation, a status (untranslated, draft, reviewed, stale), and context. A
changed source text marks its translations stale; it never discards them.

### 6.2 Formats are adapters

No interchange format is privileged, because different translators, publishers and other users
of Varis will want different ones.

- A format adapter is two functions over the catalog model: export to bytes, and import from
  bytes to a set of proposed changes plus diagnostics. Import never writes the catalog directly;
  the changes go through the same validation as any other edit.
- **Why any format can work:** grammatical branches (select, plural, variants) live inside the
  message text in the one template grammar (§3.3), so a translation is always a single string
  per key. A two-column spreadsheet is therefore a complete format. Richer formats only add
  places to put context and status.
- Built in from the start: **CSV** (opens in any spreadsheet), the canonical **JSON**, and
  **XLIFF**. Each adapter states what it cannot carry (CSV has no native status or notes fields,
  so they travel as extra columns) and has a round-trip test: export, import, compare.
- Something unforeseen is handled either by a small new adapter in D, or without touching the
  engine at all by converting to and from the canonical JSON, whose schema is documented and
  versioned for that purpose.

### 6.3 What owning the frontend makes possible

Because extraction reads the Varis AST rather than scanning strings, the tools can derive what
translators usually have to ask for:

- **Context from structure:** the speaker, the scene order, and the condition under which a line
  appears ("shown when the keeper's trust is at least 1"), taken from the `when` clause.
- **Argument kinds from schemas:** a placeholder bound to a numeric column needs plural handling
  in languages that have it; one bound to a character or item needs that entity's grammatical
  attributes. The checker can require exactly the branches a language needs, and no others.
- **Every branch rendered:** sample renderings of each message for each plural category and
  select value, generated mechanically for review and screenshots.
- **Meaningful change detection:** a source edit that changes only spacing or punctuation can
  be told apart from one that changes arguments or structure, so translations are marked stale
  only when a translator needs to look.
- **Untranslatable constructs found at authoring time:** computed strings, concatenation and
  byte-wise string operations on display text are reported to the writer, not discovered by
  the translator.

These are opportunities to take once the catalog pipeline exists, not commitments of stage T3.

### 6.4 Handoff kit

`varis l10n export` produces, for a language or a set of them:

- The messages through whichever adapter the recipient wants.
- **Context per message:** speaker, the neighbouring lines in scene order, the storylet or scene
  it belongs to, the arguments with example values and their grammatical attributes, the writer's
  note if any, and a length limit where the text box imposes one.
- A **glossary** of character names, place names and recurring terms with their attributes, so
  they are translated once and consistently.
- The character set and font requirements per language.

### 6.5 Loadable translation packs

A compiled language pack is a directory the released game loads at start-up. The publisher, or
a player making a fan translation, can drop in a new pack and see it running without a rebuild
and without the source tree. A pack
that fails validation is rejected as a whole with diagnostics naming the key and language.

### 6.6 Checking and preview, for the publisher and for CI

Folded into the planned tools rather than a separate suite of commands:

- `varis check --locale <tag>`: unknown or missing arguments, a select without a fallback, missing
  plural categories for that language, markup that the source does not permit, text over its
  length limit, characters the configured fonts lack, untranslated and stale entries. Reports
  message coverage and branch coverage separately.
- A **pseudo-locale** that lengthens and accents the source text, to find clipped text boxes and
  hard-coded strings before any translator is involved.
- The playtest host takes `--locale` and can overlay message keys on screen, so a tester can
  report "this line is wrong" by key.
- The language services show missing and stale translations as diagnostics on the source line,
  in the workbench editor and through the language server.

Machine translation or translation memory is the publisher's business; anything imported
arrives as draft and is never marked reviewed automatically.

## 7. Workflows

Who does what, with which command, and what is kept where. This is the target; §9 says which
stage delivers each command. Commands are proposals. Every command
reads the project manifest (`project.lua`, AUTHORING_TOOLS_PLAN §3.2) for the package id, the
source language and the list of locales.

### 7.1 Files

| Path | Written by | In the repository | Holds |
| --- | --- | --- | --- |
| `l10n/source.json` | `varis l10n extract` | Yes | Every message of the package: key, source text, revision hash, arguments and their kinds, context. Never edited by hand. |
| `l10n/<locale>.json` | `varis l10n import`, the workbench | Yes | Translations for one language: key, text, status, the source revision that was translated. |
| `l10n/glossary.json` | The owner or lead writer | Yes | Names and recurring terms with grammatical attributes and notes. |
| `kit/` | `varis l10n export` | No (sent out) | A handoff kit (§6.4) with a **kit id**: the hash of the source catalog it was made from. |
| `packs/<locale>/` | `varis l10n build` | No (build output) | A compiled language pack (§6.5) and the list of characters it uses. |

A translation's status is one of `untranslated`, `draft`, `reviewed`, `stale`. Only an explicit
review step sets `reviewed`. Only a source change sets `stale`.

### 7.2 The writer, every day

Nothing new to type. The writer writes English text inline as now.

- `varis check` (and the workbench problems list) reports text that cannot be translated: a title
  or text built by code (`computed-text`), a placeholder that is not a parameter.
- Optional: a `note "…"` field on a storylet, choice or line, shown to translators and never to
  players. This is new content syntax, so it is a proposal for milestone 27.
- Renaming a storylet or choice through the language services rewrites the keys in every catalog
  in the same edit. Renaming by hand makes the old key "removed" and the new one "untranslated";
  `extract` reports that pair as a probable rename and offers to carry the translations over.

### 7.3 The owner, at each merge of content

```sh
varis l10n extract            # rewrite l10n/source.json from the source files
varis l10n extract --check    # for CI: fail if source.json is out of date
varis l10n status             # per locale: translated, draft, stale, missing; by storylet
varis play --locale x-pseudo  # play with lengthened, accented text
```

`extract` prints what changed: added, removed and changed messages, and for each changed message
whether the change is **cosmetic** (spacing, punctuation, capitalisation: translations keep their
status and get a note) or **substantive** (words, placeholders, branches: translations become
`stale`). The diff of `l10n/source.json` in the commit is the record of what the writer's change
costs translators.

### 7.4 Handoff to the publisher

```sh
varis l10n export --locale zh-Hans,zh-Hant,ja,ko --format xliff --out kit/
```

The kit is self-contained: messages with context, glossary, character-set and font requirements,
and the argument metadata the checker needs. The publisher needs no source tree. With the kit
they can run:

```sh
varis l10n check --kit kit/ their-file.xlf     # the same checks as `varis check --locale`
```

and they can drop a pack into a release build of the game to see it running (§6.5), with the key
overlay (§6.6) for reporting a line by key.

### 7.5 Translations coming back

```sh
varis l10n import their-file.xlf --locale ja   # proposed changes and diagnostics; writes nothing
varis l10n import their-file.xlf --locale ja --apply
varis check --locale ja
varis l10n review --locale ja [keys…]          # mark as reviewed
```

- Import validates every entry (§6.6). Entries that pass are written as `draft`; entries that fail
  are listed with key and reason and are not written.
- An entry translated from an older source revision than the current one arrives as `stale`, not
  `draft`: the translator saw different English.
- Import never deletes. A key missing from the file keeps what the catalog has.

### 7.6 The source changes after a handoff

This is the usual case, not the exception: a writer fixes a line while translators are working.

```sh
varis l10n export --locale ja --changed-since <kit id> --out kit-delta/
```

The delta kit holds only new and stale messages. Each stale message carries the old English, the
new English and the existing translation, so the translator edits rather than starts again.
Cosmetic changes (§7.3) are not sent. The kit id makes the delta relative to what the publisher
actually holds, not to the last commit.

### 7.7 In-house testing in the workbench (French and Russian)

- The story panel has a language selector. Changing it re-renders the current presentation; it
  does not call `present()` again (§2, principle 2).
- A translation panel lists the messages of the current presentation: key, source, translation,
  status. Editing a translation saves it to `l10n/<locale>.json` as `draft` and re-renders.
- For a message with plural or select branches, the panel shows every branch rendered with sample
  values (§6.3).
- Locale diagnostics appear in the problems list on the source line of the message.

### 7.8 A fan translation or a mod in another language

A player copies a pack directory next to the game. The game validates it at start-up and either
loads it or rejects it whole, writing the reasons to a log by key. A mod with its own content
declares its own source language (§3.8) and is extracted and translated with the same commands.

### 7.9 A release build

```sh
varis check --locale all --require reviewed    # the release gate
varis l10n build --out packs/                  # compiled packs and per-language character sets
```

The manifest may set a minimum coverage per locale; below it the gate fails. A message that is
missing or stale at run time falls back to the source text as a whole (§2, principle 4), so an
incomplete language is playable but never ships by accident.

## 8. Saves, replay and versions

- **Gameplay compatibility** covers definitions, schemas, effects, conditions (including those
  embedded in text) and variant structure. **Presentation revision** covers wording, catalogs and
  the plural table. A translation-only or wording-only change never invalidates a save.
- Changing a message's arguments or its select branches invalidates the language packs that
  translate it, not saves.
- The split is a new save-format revision behind a versioned reader. Old saves keep their
  current validation, and a fingerprint mismatch is never silently accepted.
- The chosen language may be stored as a preference alongside a save. It is never an input to
  eligibility or compatibility. Gameplay replay is independent of language.

## 9. Stages

Stage letters are `T` (translation). Earlier revisions of this plan called them `L0`–`L4`; the
old `L0` is now T0 and T2, `L1` is part of T3, `L2` is T1 and T3, `L3` is T4 and `L4` is T5.

| Stage | Deliverable | Needs | Changes the runtime or saves | Exit evidence |
| --- | --- | --- | --- | --- |
| T0 | **Decisions.** The §3 decisions written into the grammar and the manual with milestone 27; the scene-line id scheme with milestone 29; the owner choices of §12. | Owner | No | Each §3 item is recorded as accepted, changed or rejected. |
| T1 (done) | **Extraction.** The message table of the project index; key derivation for storylets, choices, quality labels and named symbols; the catalog model and canonical JSON; the CSV adapter; `varis l10n extract`, `extract --check` and `status`; the `computed-text` diagnostic; cosmetic versus substantive change detection. | Stages A0 and A1 of the authoring tools plan | No | Every title, text and label of *Saltmarsh Light* has a key or a diagnostic. Extraction is deterministic (golden file). Editing one source string marks exactly its translations stale in a fixture catalog. CSV export and import round-trip. |
| T2 (done) | **Wording out of the gameplay fingerprint; named variants.** A new save-format revision behind a versioned reader (§8). | T0, and the owner's approval of the save-format change (AGENTS §8.1 item 5) | **Yes** | A wording edit no longer changes the gameplay fingerprint. Old save fixtures load as before. A replay log names its variants, and reordering alternatives replays identically. The sample game's golden file is regenerated once, in its own reviewed commit. |
| T3 (done for storylets; scene lines implemented, menus/metadata/spans incomplete) | **Translated rendering.** Selection separated from rendering; a session language that can be switched and re-rendered; catalog lookup with whole-message fallback; the pseudo-locale; `select` and plural in templates with the generated plural table; translatable names with grammatical attributes; `varis check --locale`; the workbench language selector and translation panel (§7.7). Span output arrives with beat-stream presentations (milestone 29) and is not required for this stage's exit. | T1, T2; stage A3 for the checker | Yes (additive: presentations gain what re-rendering needs) | Re-rendering changes no token, draw, turn or replay log. French and Russian translations of *Saltmarsh Light* pass the checker and read correctly to the owner; every plural category and a case-inflected name are exercised. A gameplay replay in two languages produces identical logs. |
| T4 (implemented; remaining production refinements below) | **Handoff.** Kit export with context and glossary, kit ids and delta kits, the XLIFF adapter, import with review states, `varis l10n check --kit`, loadable packs with whole-pack rejection, the key overlay, the release gate. | T3 | No | A pack built only from an exported kit loads into a release build. A deliberately broken pack is rejected with diagnostics by key. A delta kit after a source edit contains exactly the stale and new messages. |
| T5, with milestone 36 | **Presentation.** Line breaking, per-language fonts, ruby, the Korean particle formatter, character-set output for font subsetting. | T4; the SDL3 presentation layer | No | A Chinese, a Japanese and a Korean sample render correctly in the SDL3 layer, reviewed by a reader of each language; fonts are subset from the emitted character sets. |

**Status, October 12, 2026.** T1–T4 are implemented within the limits in §1a.
T2 was approved by the owner on October 12: format 2 removes wording from gameplay
identity, with legacy format 1 validation; named variants, `{#plural}` and `{#select}`
use block tags. Format 3 adds scene positions/stage. The first scene slice supplies
line ids, catalog extraction and translated line rendering; menus and character metadata
remain authored text. The proposed generated `#tag` line annotation is not implemented:
current declarative beat records use an `id` field, with a positional fallback.

The workbench language selector, draft editor and branch previews work. T4 includes
kits with context/glossary/character sets/ids, delta kits, CSV/JSON/XLIFF adapters,
review states, kit checks, built packs with whole-pack rejection, key display and the
reviewed-translation gate. Font subsetting and manifest per-locale coverage policy remain.

T5 is partial: engine text helpers (`particle`, `graphemes`, `truncate`, `line_breaks`,
`ruby`) and character-set output exist. The [SDL3 player](docs/presentation.md) renders
UTF-8 through SDL3_ttf with one supplied font. Per-locale font chains, ruby drawing,
complete CJK layout and native-reader validation remain unfinished. Production localization
is not complete merely because translated strings render.

## 10. Deferred

- Right-to-left languages and bidirectional text. The span stream carries a language per span
  from the start, which is the part that would be hard to add later.
- Per-region editions with different content.
- A general Unicode library (ICU), full MessageFormat 2 syntax, locale-aware dates, units and
  currency.
- Exact presentation replay (reproducing the wording, not only the gameplay), hot reload of
  packs inside a running session, vertical text.

## 11. Verification

- Unit and extension cases for: key derivation and duplicates, rename with catalog rewrite,
  select and plural totality, argument reordering and omission, stale marking, pack rejection,
  fallback of a whole message, re-rendering without side effects, save compatibility across a
  translation-only change, and gameplay replay in two languages producing identical logs.
- Language fixtures for the five target languages covering the rows of §4.
- Measured costs on the reference game: catalog load, pack memory and render time per
  presentation, inside the budgets of [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md).
- Engine tests cannot establish that text reads well or displays correctly. Each shipped
  language needs a reader's review in the real front end.

## 12. Open choices (owner)

Use the default until decided, and say so in the change.

| Choice | Default | Reason for the default |
| --- | --- | --- |
| Scene-line ids (§3.2), future compact syntax | Tool-written short tag remains a proposal; current beat tables use explicit `id`, with a positional fallback | Explicit ids survive wording edits and insertion. Automatic annotation is not implemented. |
| Translator notes | A `note "…"` field, decided with milestone 27 | Context that structure cannot supply has to come from the writer. |
| Where catalogs live | `l10n/` in the game's repository, one JSON file per locale | Diffs and history for free. |
| Who may set `reviewed` | Implemented: `varis l10n review`; workbench edits save drafts, imports cannot approve | A returned file saying "final" has not been read by anyone on the project. |
| Coverage required to ship a locale | `l10n check --locale all --require reviewed` enforces reviewed coverage; per-locale manifest policy remains proposed | A lower number is a deliberate choice, not an accident. |
| Pack format | Implemented: locale directory containing `pack.json` with messages and charset | Readable by fan translators; a binary form can come later if load time needs it. |
| Non-ASCII identifiers (§3.8) | Not allowed; display text may be any UTF-8 | Decided with milestone 27. |
