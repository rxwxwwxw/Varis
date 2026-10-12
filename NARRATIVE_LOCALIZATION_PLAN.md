# Narrative localization plan

Status: **proposed**, rewritten October 11, 2026 for the project's actual targets. Nothing here
is implemented. The [Varis Reference Manual](docs/README.md) remains authoritative for current
semantics; API names, syntax and commands below are proposals.

The first version of this plan (commit `dbb0960` and earlier) was a general design centred on an
English/Arabic slice, MessageFormat 2 and UUID annotations. Its right-to-left, bidi and
multi-script material is deferred, not rejected; read it there if a right-to-left language is
ever committed.

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
   the presentation layer. The engine hands over structured spans in logical order.

## 3. Decisions to freeze with the syntax (ROADMAP milestones 27 and 29)

These are cheap to decide now and expensive to retrofit. None of them requires a translation to
exist.

1. **Keys come from authored names.** A storylet's title is `topic_lamp.title`, a choice's is
   `topic_lamp.nod.title`, a scene line uses the stable line id of milestone 29. Renaming a
   storylet already breaks saves, so these names are already permanent; no generated identifiers
   appear in content files. The rename of the language services (ROADMAP milestone 32, used by both the workbench and the
   language server) rewrites catalogs. Two messages with the
   same English text stay separate.
2. **Scene lines need an id that survives editing.** Lines have no authored name, and an id
   derived from position breaks when a line is inserted. Milestone 29 must choose between a short
   tool-written tag on the line and an id derived from the line's first-seen text; either way the
   checker reports duplicates and the tool never guesses identity from similar text.
3. **One template grammar.** The Varis template language gains named placeholders (already
   present), a `select` on a declared value with a required fallback branch, a plural select on a
   number, and **named** variant alternatives. Translators write the same grammar as writers.
   MessageFormat's ideas are used; its syntax is not added as a second language.
4. **Named variants, not indices.** Replay logs record which alternative was drawn by name, so a
   translation can reorder alternatives and the log format never needs migrating.
5. **Literal display text in content files.** Titles, text and dialogue are string literals with
   placeholders; the checker rejects computed strings there and flags byte-oriented operations
   (`#`, `string.sub`) applied to display text. Extraction then needs no execution.
6. **Wording leaves the gameplay fingerprint.** Today the content fingerprint hashes every option
   of a definition, including `title` and `text`, so fixing a typo invalidates saves. Split it:
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

These are opportunities to take once the catalog pipeline exists, not commitments of stage L2.

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

## 7. Saves, replay and versions

- **Gameplay compatibility** covers definitions, schemas, effects, conditions (including those
  embedded in text) and variant structure. **Presentation revision** covers wording, catalogs and
  the plural table. A translation-only or wording-only change never invalidates a save.
- Changing a message's arguments or its select branches invalidates the language packs that
  translate it, not saves.
- The split is a new save-format revision behind a versioned reader. Old saves keep their
  current validation, and a fingerprint mismatch is never silently accepted.
- The chosen language may be stored as a preference alongside a save. It is never an input to
  eligibility or compatibility. Gameplay replay is independent of language.

## 8. Stages

| Stage | Deliverable | Exit evidence |
| --- | --- | --- |
| L0, with milestones 27 and 29 | The §3 decisions in the grammar and the manual; fingerprint split designed. This is all the English-first release needs | Keys derivable for every message in the sample games; a wording edit no longer changes the gameplay fingerprint; old save fixtures behave as before. |
| L1 | Selection/render split and span output, delivered with beat-stream presentations | Re-rendering a presentation changes no token, draw, turn or replay log. |
| L2 | Catalog model, extraction, CSV/JSON/XLIFF adapters with round-trip tests, `check --locale`, pseudo-locale, plural table, select and plural in templates, translatable names with attributes | French and Russian translations of *Saltmarsh Light* pass the checker and read correctly to the owner; every plural category and a case-inflected name are exercised. |
| L3 | Handoff kit export and import, loadable packs, key overlay | A pack built only from the exported kit loads into a release build; a deliberately broken pack is rejected with useful diagnostics. |
| L4, with milestone 36 | Line breaking, per-language fonts, ruby, Korean particle formatter, character-set output | A Chinese, a Japanese and a Korean sample render correctly in the SDL3 layer, reviewed by a reader of each language; fonts subset from the emitted character sets. |

L0 and L1 belong to the syntax and presentation work and should not wait for milestone 39. The
feature is announced after L3 and L4, with review by native readers, not when the first
translated string renders.

## 9. Deferred

- Right-to-left languages and bidirectional text. The span stream carries a language per span
  from the start, which is the part that would be hard to add later.
- Per-region editions with different content.
- A general Unicode library (ICU), full MessageFormat 2 syntax, locale-aware dates, units and
  currency.
- Exact presentation replay (reproducing the wording, not only the gameplay), hot reload of
  packs inside a running session, vertical text.

## 10. Verification

- Unit and extension cases for: key derivation and duplicates, rename with catalog rewrite,
  select and plural totality, argument reordering and omission, stale marking, pack rejection,
  fallback of a whole message, re-rendering without side effects, save compatibility across a
  translation-only change, and gameplay replay in two languages producing identical logs.
- Language fixtures for the five target languages covering the rows of §4.
- Measured costs on the reference game: catalog load, pack memory and render time per
  presentation, inside the budgets of [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md).
- Engine tests cannot establish that text reads well or displays correctly. Each shipped
  language needs a reader's review in the real front end.
