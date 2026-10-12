# Narrative localization implementation plan

Status: proposed, October 11, 2026. No functionality in this document is implemented
by this change. The [Varis Reference Manual](docs/README.md) remains authoritative
for current semantics. API names, annotations, and commands below are proposals.

## 1. Recommended design

Build localization as a versioned presentation layer over narrative content. Give
authored objects permanent localization identities, extract complete messages into
translator-facing catalogs, and render them using locale-aware formatting and
explicit language/direction metadata. Keep eligibility, effects, choice identity,
draws, and persistence independent of the selected language.

The engine owns message selection, formatting, isolation metadata, and reproducible
presentation inputs. Host renderers own font fallback, shaping, visual bidi layout,
line breaking, accessibility, and interface layout. A headless engine cannot promise
correct Arabic display in a terminal that lacks shaping or bidi support.

Deliver one complete vertical slice first: an automatically labeled storylet and
choice, English and Arabic catalogs, a mixed-direction name and plural quantity,
language switching on an existing presentation, and identical gameplay replay.

## 2. Existing integration points and constraints

| Existing component | Consequence for this work |
| --- | --- |
| `registry.d`: named storylets/actions, nested choices, sealed content | Retain existing runtime names; add localization metadata without changing registration identity. |
| `compiler.d`: narrative fields are expressions evaluated at registration | Static extraction cannot assume every field is a literal or safely execute arbitrary source. |
| `templates.d`: parameters, query conditions, weighted variants | Separate executable authored conditions and random selection from translated message syntax. |
| `session.d`: immutable records containing string title/text and opaque tokens | Preserve string fields and token behavior; add structured localized output through an opt-in interface. |
| `session.d`: variant indices are selected and logged before rendering | Translating, reordering, or adding linguistic branches must not change RNG consumption. |
| `fingerprint.d`, `registry.d`, `persistence.d`: text/options, labels, code and captures participate in compatibility | Splitting presentation and gameplay versions requires a deliberate save-format migration and audit. |
| `registry.d`: symbol display names, quality labels, custom formatters | These need localization coverage as well as storylet prose. |
| Lua strings and portable codec are binary-safe | Validate UTF-8 at the new localization boundary; preserve ordinary Lua string semantics. |

## 3. Stable automatic identifiers

Keep three identities distinct:

| Identity | Example (abbreviated) | Lifetime |
| --- | --- | --- |
| Runtime name / instance key | `travel`, plus canonical bindings | Existing gameplay, saves, policies, tokens; unchanged. |
| Permanent localization object ID | `urn:uuid:…` on a storylet or choice | Generated once, committed, survives rename, move, and prose edits. |
| Message ID and source revision | `<object-id>/title`, `<object-id>/text`, plus source hash | Message ID stays stable; hash detects translations needing review. |

Use a committed project namespace UUID and full randomly generated object UUIDs.
Use readable aliases such as `harbor.travel.title` in tools, never as the sole
durable key. Titles, source paths, line numbers, registration order, and content
hashes must not determine permanent IDs. Identical English text in different
contexts gets separate IDs unless the author explicitly shares a message.

Proposed authoring workflow:

1. `tools/localize label --check` reports unlabeled translatable objects.
2. `tools/localize label --write` inserts a machine-readable comment immediately
   before each storylet, choice, or standalone message declaration. Initial form:
   `-- @varis-l10n-id <full-uuid>`. This is tooling metadata, not a new keyword.
3. The frontend retains this one annotation class and attaches it to the following
   relevant AST node; compiler metadata carries it into prototypes/definitions.
   Define exact attachment rules across whitespace/comments and reject orphaned,
   malformed, conflicting, or duplicate annotations. Ordinary comments stay inert.
4. A generated manifest maps IDs to kind, current runtime name, readable alias,
   source location, fields, and translator context. Regeneration is deterministic;
   re-running labeling changes nothing once IDs exist.
5. Check duplicates across the entire packaged project, including imported content.
   Copying content requires a fresh ID; provide an explicit duplicate/rekey command.
   Moving or renaming content retains its annotation. Never guess identity from
   similar text after a merge conflict.

Choices receive their own IDs, so moving one between storylets preserves its
translation history. That does **not** make its gameplay identity/save history
portable: runtime renames or reparenting still need existing migration rules.
Deleted IDs become tombstones; never recycle them. Splitting/merging messages
creates new IDs with explicit translation-history links. Explicit authored IDs
are supported with collision validation. Dynamic content factories must supply
stable IDs from an authored manifest; no runtime-generated localization UUIDs.

Fields default to object ID plus role. A role rename needs an explicit alias or
migration. Structural conditional/variant nodes also need persisted authoring IDs
or explicit names; tree positions and text hashes are insufficient. Prototype an
editor-managed sidecar for these internal nodes; unresolved structural edits fail
extraction until their mappings are reconciled rather than silently rekeyed.

## 4. Catalogs and translator workflow

Use a versioned UTF-8 JSON catalog as the canonical editable interchange first,
with deterministic serialization and a separately compiled runtime bundle. Include:

- Project/object/message IDs, source locale, source revision, source text, and alias.
- Translator notes, speaker, narrative context, sample bindings, and source location.
- Argument contract: stable name, value category, formatting role, required selectors,
  and direction/language hints; distinguish absent from present-with-nil.
- Locale, translated pattern, review status, and the source revision it translates.
- Named semantic branches/variant alternatives and permitted markup/formatters.

Extract complete sentences or paragraphs rather than concatenated translated
fragments. Allow parameters to move, repeat, or be omitted when linguistically
appropriate; reject unknown arguments and require all selection paths to be total.
Do not require identical placeholder counts in source and target.

The extractor reads AST/template metadata without executing game code. Cover
storylet and choice titles/text, quality labels, symbol display names, and explicit
standalone messages. Report computed strings and dynamic registrations with exact
locations. Require a declared message/argument contract for those cases; do not
silently report full coverage. A host can explicitly export its constructed registry
for coverage comparison, but extraction never automatically runs a story to do so.

Proposed commands: `label`, `extract`, `check`, `compile`, `coverage`, and `pseudo`.
Translation changes retain their IDs; source revisions mark entries stale for review.
Compilation validates the entire bundle before publishing it. Invalid translations
produce message-ID/locale/source-path diagnostics. Production policy uses approved,
current entries with fallback; development strict mode makes gaps errors. CI can
require 100% reviewed coverage for release locales without requiring every draft
locale to be complete. Count messages and branch coverage separately.

Add XLIFF import/export after the internal schema stabilizes, with round-trip tests
for notes, IDs, branches, and status. Translation-memory or machine-translation
integration is optional tooling: generated translations remain drafts and never
alter executable content or receive automatic publication approval.

## 5. Message grammar and linguistic support

Target a documented, versioned profile of Unicode MessageFormat 2 for catalog
patterns, compiled to engine-owned message IR. Keep existing Varis template syntax
working in legacy mode. Do not silently reinterpret its braces as MessageFormat.
Evaluate a maintained implementation/provider before committing to a D parser;
if only a subset ships, reject unsupported constructs and name the supported profile.
MessageFormat supplies structured selection and locale-aware formatting facilities.
See [Unicode MessageFormat](https://messageformat.unicode.org/) and its
[function reference](https://messageformat.unicode.org/docs/reference/functions/).

Support cardinal/ordinal plural selection, exact numeric matches, grammatical
selectors, number formatting, and explicit locale-aware lists. Use CLDR data for
plural categories and decimal operands; English singular/plural rules are
insufficient. Preserve integer precision above 2^53 and define how visible decimal
precision is supplied when it affects a plural category. Every selector needs a
fallback. See [CLDR plural rules](https://cldr.unicode.org/index/cldr-spec/plural-rules).

Authors supply semantic grammatical features, including inflected proper-name
forms where needed. Never infer gender, pronouns, or grammatical case from a name.
Let translators restructure whole clauses. Keep symbol identity separate from its
localized label. Date/time/unit/currency formatters can follow the core slice, with
explicit time zone, calendar, numbering system, and unit inputs; never read the
machine clock or process-global locale during rendering.

Use a provider interface for version-pinned Unicode/CLDR data and formatting.
Compare ICU via its C API with generated, narrowly scoped CLDR tables in an initial
dependency spike: supported platforms, license notices, bundle size, determinism,
integer correctness, build integration, and available MessageFormat support.
Do not implement a new bidi or Arabic shaping algorithm in Varis.

## 6. RTL, LTR, and Unicode contract

Use validated BCP 47 language tags, with script/region information retained. Store
direction independently as `ltr`, `rtl`, or explicit `auto` where appropriate;
language alone is not a sufficient direction contract. See
[BCP 47](https://www.rfc-editor.org/info/rfc5646/) and
[W3C language/direction guidance](https://www.w3.org/International/articles/lang-bidi-use-cases/).

Localized output should be an immutable structured value containing logical-order
text/runs, resolved language, base direction, message ID, bundle revision, and
fallback provenance. Runs retain language, direction, and isolation boundaries for
substituted names, URLs, numbers, and nested language changes. Resolve unknown
direction from first-strong rules at the renderer boundary, with a documented
all-neutral fallback. Never reverse strings or manually reorder glyphs. Follow
[Unicode UAX #9](https://www.unicode.org/reports/tr9/).

Provide two adapter contracts:

- HTML: escape literal text, use `lang`/`dir` and isolated inline spans or `bdi` for
  substitutions. Only emit allowlisted structural markup from the message IR.
- Plain text: serialize isolation with LRI/RLI/FSI and PDI as appropriate, retaining
  logical order. Controls belong to output, never to message IDs, bindings, or
  persisted gameplay values. Document terminal capability limitations.

These techniques follow [W3C inline bidi guidance](https://www.w3.org/International/articles/inline-bidi-markup/).
The renderer contract also covers logical start/end alignment, selective icon
mirroring, keyboard focus order, screen-reader language, and font coverage. Do not
reverse the engine's canonical choice order to create an RTL interface.

Require valid UTF-8 for localized patterns and displayed text inputs in strict mode.
Offer explicit replacement diagnostics for host-provided invalid display bytes;
never change underlying Lua strings, symbols, equality, hashing, or serialization.
Do not strip combining marks, ZWJ/ZWNJ, or normalize player names silently. Any
normalization used for catalog lookup must be specified and confined to that layer.

Lint invisible bidi controls in authored catalogs and escape them in diagnostics.
Use a documented display-input policy for untrusted control characters; isolation
does not remove the need to handle embedded controls. Translators should normally
use structured direction metadata instead of inserting invisible overrides.
Rendered arguments remain data: they cannot inject template syntax or markup.

Hosts must truncate, select, and reveal text using grapheme boundaries, not byte
offsets or individual code points; use [UAX #29](https://unicode.org/reports/tr29/).
Test CJK wrapping, Thai segmentation, Indic shaping, emoji sequences, combining
marks, and text expansion as well as RTL. Vertical writing remains a future host
layout capability; the engine must preserve logical text without assuming a visual axis.

## 7. Locale resolution, rendering, and deterministic behavior

Make locale a presentation/view setting, not a mutable global or world fact. One
session can support multiple views without language changes affecting simulation.
An immutable render context pins requested locale, resolved catalog chain, bundle
revision, formatter/data versions, and explicit formatting preferences.

Use a validated fallback graph: exact locale, configured script-aware parents,
project default, embedded source. Reject cycles at bundle build time; do not blindly
drop subtags and accidentally cross scripts. Resolve each whole message atomically,
including its branches. Format fallback text using its resolved message locale by
default, retaining separately configured numeric preferences when explicitly enabled.
Expose which message fell back, its actual language, and why.

Refactor presentation into selection and rendering internally. Selection captures
bindings, snapshot, tokens, authored condition results, and semantic variant choices.
Rendering can run repeatedly on that immutable selection without drawing cards,
allocating new token identities, consuming RNG, advancing turns, or executing effects.
An illustrative new API is `narrative.render(presentation, context)`; it must reuse
the original choice tokens and preserve their normal stale/consumed checks. Calling
`present()` again must not be the prescribed way to switch languages.

Translated messages may select linguistic alternatives from declared values; they
cannot add Lua, query goals, state access, callbacks, weights, or RNG operations.
Existing authored query conditionals become named immutable selector results;
evaluate them against the original snapshot under current purity/no-yield rules.
Keep original conditional nesting and evaluation semantics; do not eagerly execute
previously unreachable queries. Expose no additional hidden bindings to translations.

Select weighted semantic variants from the authored template before localization.
Catalog branches reference permanent alternative IDs, allowing translators to
reorder syntax without changing selection. Linguistic plural branches are distinct
from random alternatives. Preserve current variant traversal/RNG behavior for old
content, including nested groups. Version any transition from index-based replay
to named alternatives and provide explicit mapping. Adding a translation must not
introduce a new random draw; missing alternatives fall back as a whole message.

Legacy custom formatters can observe external mutable state despite the authored
purity obligation. Localized mode must freeze their display inputs/results at
selection or require an explicit deterministic locale-aware formatter contract.
Cache by immutable selection/context identity; never cache only by message ID and
locale when values or snapshots differ. Failed rendering publishes no partial view.
Bundle hot reload creates a new immutable bundle; existing views keep their old one.

## 8. Saves, replay, and compatibility

Separate three version domains in a new, explicit format revision:

- Gameplay compatibility: definitions, schemas, policies, effects/code/captures,
  authored condition logic, and weighted variant structure.
- Message contract: permanent IDs, arguments, selector/alternative IDs, formatter
  contracts, and permitted markup.
- Presentation revision: source/translated wording, catalog approval state,
  locale data, and formatting implementation versions.

Translation-only edits must not invalidate gameplay saves. Message contract changes
invalidate incompatible bundles. Source prose-only edits should eventually avoid
gameplay incompatibility too, but first audit all current fingerprint paths: simply
omitting `title`/`text` would also omit embedded queries and weighted variant logic.
Keep those semantic components in gameplay fingerprints. Audit quality labels,
symbol labels, formatter captures, and explicit authored version assertions.

Preserve old save validation unchanged. Load a new format only through a versioned
reader; upgrading old saves requires verified compatible content or the existing
explicit migration protocol. Never silently accept an old fingerprint mismatch.
Localization IDs supplement existing runtime identity; do not rewrite instance keys.

Distinguish gameplay replay from exact presentation replay. Gameplay replay is
locale-independent. Exact presentation replay pins catalogs, source messages,
formatting/data versions, view locale, and any captured external formatter output;
it fails clearly if required artifacts are unavailable. Locale preferences may be
saved as optional view metadata, never as an eligibility or save-compatibility input.

## 9. Implementation sequence and acceptance gates

| Stage | Deliverable | Exit evidence |
| --- | --- | --- |
| L0: contract and dependency spike | Provider decision, catalog schema, locale/direction contract, threat/resource limits, save/replay split design | English/Arabic proof of concept with exact integer plural behavior, mixed-direction output, dependency/license/build report; no runtime compatibility changes. |
| L1: permanent identity and extraction | Annotation retention, AST/prototype metadata, label/extract/check tools, translator manifest | Idempotent labeling; IDs survive rename/move/reorder/prose edits; duplicates fail; computed fields appear in coverage gaps; branch-ID edits require reconciliation. |
| L2: catalog compiler and messages | Versioned IR, argument validation, plurals/selectors, symbol/quality localization, fallback | Invalid bundles fail atomically; all supported branches render; no executable translation input; legacy templates remain byte-compatible. |
| L3: presentation integration | Immutable render context/result, selection reuse, plain-text and HTML adapters | Locale switching preserves token identity, snapshot, choices, RNG, turns, and replay; mixed-direction visual tests pass in a declared renderer. |
| L4: compatibility and replay | Split fingerprints, new save/replay versions, audited migration behavior | Translation-only update loads saves; gameplay edits still reject; exact replay detects missing bundle/provider; old format fixtures keep existing behavior. |
| L5: authoring and release gate | Pseudolocales, coverage reports, translator round trip, reference/manual updates | Full automated gates, native-speaker review, measured runtime/bundle cost, published host support limits. |

L0 and L1 precede runtime integration. L2 precedes L3; settle L4's compatibility
design before merging changes to fingerprints. The public feature ships after L4
and L5, not after the first translated string renders. Keep changes small and
reviewable; runtime optimization is a separate measured task.

Suggested module boundaries: `narrative/localization/{model,catalog,validate,render,locale}.d`,
with an explicit formatter-provider adapter and tooling under `tools/localize`.
Touch lexer/AST/parser/compiler/prototype metadata for annotations; registry/templates
for message contracts; session/lib for views; fingerprint/persistence for versioning.
Audit registry cloning in analysis and both VM execution paths where metadata flows.
Every new D module receives the required license header and explicit Makefile entry.

## 10. Verification and release limits

Add a separate localization suite and conformance matrix. Preserve core stateful,
aggregate, narrative, optional authoring, and official Lua gates as distinct evidence.

- Identity fixtures: file moves, name changes, duplicate aliases/text, copy/paste,
  deleted/reintroduced content, concurrent-branch merges, and dynamic manifests.
- Language fixtures: English, Arabic, Hebrew, Polish or Russian, Japanese, Turkish,
  Thai, and an Indic script; script-sensitive locale fallback and unknown locales.
- Message fixtures: zero/one/two/few/many/other where applicable, ordinals, decimals,
  negative and large integers, nil, repeated/omitted parameters, selector fallback,
  names with grammatical forms, escaped braces, and deliberate translation errors.
- Bidi/Unicode fixtures: Latin names and URLs inside Arabic, Arabic inside English,
  punctuation/parentheses, numbers, nested runs, neutral-only inputs, control attacks,
  malformed UTF-8, combining marks, emoji, and long expanded text.
- Narrative fixtures: repeated rerendering, two locales over one selection, stale
  tokens, state mutation after capture, rollback, nested variants, query failures,
  custom formatter failures/yields, analysis isolation, and concurrent sessions.
- Compatibility fixtures: translation-only update, source-only prose edit, argument
  change, altered query/weights, corrupt/unsupported bundle, hot reload, old saves,
  gameplay replay and exact presentation replay.
- Resource fixtures: bounded catalog size, nesting, output length, formatter cost,
  and total fallback work; reject malformed inputs with diagnostics rather than
  stack overflow, hangs, or partial registry publication.

Use pseudolocalization for expansion/accenting and a separate bidi stress mode;
neither replaces review by Arabic/Hebrew readers. Visual QA must check shaped output,
wrapping, focus/navigation, copying, and screen-reader language in the supported
host. Golden strings alone cannot establish correct display.

For implementation, run targeted tests, full `make test`, optimized assertion-enabled
validation, and release CLI fixtures. Measure cold catalog load, bundle memory, and
warm render cost for representative small/large catalogs on an idle machine; establish
budgets from that evidence without resetting existing performance baselines.

Before release, update the reference's narrative/library/syntax/compatibility pages
and the narrative conformance audit with implemented APIs and explicit limitations.
Do not claim universal script rendering, automatic grammatical correctness, complete
MessageFormat support, or translation quality based solely on engine tests.
