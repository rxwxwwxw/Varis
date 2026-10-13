# Authoring tools plan: project model, checker, language services, writer workflow

Status: **delivered design record, A0–A6 and milestones 30–33 implemented**,
audited October 13, 2026. Content-tier loading, source symbol declarations,
`.varis` files and the workbench UI have also landed. Remaining optional work is a
formatter, unified runtime template diagnostics and the static-analysis limits
in §2/§4. The stage table and combined order preserve delivery history, not tasks
to repeat. Language semantics are defined by the [manual](docs/README.md).

Neighbouring documents:

- [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md) covers the server, the web user interface and the
  debugger (milestones 42–44). This plan supplies what the workbench's editor and problems list
  call.
- [NARRATIVE_LOCALIZATION_PLAN.md](NARRATIVE_LOCALIZATION_PLAN.md) covers translation (milestone
  39). Its extraction, checking and rename steps are built on the project index of §3.2 here.
  Section 6 gives the combined order of the two plans.

## 1. What this plan is for

A contracted writer, who may not program, must be able to write a storylet, be told about every
mistake in words that name their storylet and line, playtest it, and hand it in. The owner must be
able to check a contractor's submission mechanically. A translator's tools (the localization plan)
must be able to find every piece of display text without running the game.

All three use **a description of the project read from its source files, without
executing them**: the shared project index in `services/index.d`. The workbench's
workspace and command completion still inspect live state; static diagnostics and
source completion, navigation, hover and rename use the frontend/index, including unsaved drafts.

## 2. What exists today

| Piece | Today | Where |
| --- | --- | --- |
| Project model | Literal `project.varis` or `project.lua` manifest; indexed declarations, references, messages and source ranges; scene and character records included. | `services/manifest.d`, `index.d` |
| `varis check` | Recovering parse, compile/static checks, content-tier and optional strict-symbol checks; load pass by default for a manifest entry; optional bounded analysis and locale checks. `--no-load`, `--index`, `--symbols`, `--json` are available. | `services/check.d`, `checks.d`, `tier.d`, `loadpass.d` |
| Diagnostics | Stable codes, severity and source ranges, with subjects/suggestions where known. Loading code still stops at the first error. | `services/diagnostic.d`, `parser.d`, `ast.d` |
| Language services | Static diagnostics, completion, definition, references, hover, outline and rename; `varis lsp` exposes them over standard input/output. | `services/lang.d`, `lsp.d`, `editors/` |
| Workbench integration | Project-wide static/compile diagnostics, indexed source completion/definitions, hover and rename preview over unsaved drafts; vendored CodeMirror with inline diagnostics and breakpoint gutters, retained buffers/undo, resizable panels and persistent command history. Command completion reads live state. | `workbench/server.d`, `page.d` |
| Load-time definition locations | Registry errors carry definition kind/id; the checker resolves the source location through the index, without adding location data to content identity. | `narrative/registry.d`, `services/loadpass.d` |
| Localization | Source catalogs, CSV/JSON/XLIFF kits, review, packs, language selection and translation editing. Scene lines and menu labels are extracted and translated; host/typography limits are in the localization plan. | `services/{catalog,xliff,l10n}.d`, `narrative/translation.d` |
| Playtest and author tests | `varis play`, `varis test`, `require("varis.test")`, CI script; sample author checks use this library. | `services/play.d`, `tools/project_ci.sh`, `sample-game/tests/` |

These tools understand literal declarations; dynamically constructed definitions cannot all be
resolved statically. Content-tier checks also run at project load time, with a restricted environment;
trusted engine helpers remain responsible for save/replay safety (manual §8.3). Template
parsing still uses legacy throwing code; the index separately scans templates and maps
references to source ranges. A unified runtime template diagnostic interface remains work.

## 3. Design

### 3.1 Rules

1. **Two sources of knowledge, never mixed up.** The **static index** (§3.3) is read from source
   files and knows about files that are broken or not yet loaded. The **live state** is what the
   workbench's workspace shows. Language services (diagnostics, completion, definition, rename)
   answer from the static index. The workspace and the debugger answer from the live state.
   Completion may add names from the live state as a second, marked source.
2. **Tools do not execute content to understand it.** Extraction, navigation and the static checks
   read the AST. Only the load pass of the checker (§3.5) runs project code, and it never creates
   a session (AGENTS §8 guideline 18).
3. **One diagnostic record** (§3.4) for every tool: the command line, the workbench problems list,
   the language server and the localization checker.
4. **The runtime's behaviour does not change.** Parser recovery is a mode that only tools turn on.
   `load`, `require` and the error text they produce stay byte-identical; the Lua suites pin them.
5. **Nothing here enters fingerprints or saves.** Source locations added to registered content are
   kept out of `contentFingerprint`.
6. **Layer and style.** All of this is the tools layer (AGENTS §4.1) and new code, so it follows
   AGENTS §3: return values, no `throw`, explicit loops, little Phobos. Implemented home:
   `source/varis/services/`, included in the tools layer in `tools/check_sources.py` and the
   Makefile list. The former `workbench/check.d` has moved there.

### 3.2 The project manifest

One file at the project root says what the project is. Implemented names `project.varis` and `project.lua`; it is a single
table of literals and is **read with the Varis parser, never executed**, so it needs no new parser
and cannot do anything.

```lua
return {
    id       = "saltmarsh",            -- package id; qualifies message keys (localization plan §3.8)
    language = "en",                   -- source language of the display text
    entry    = "game",                 -- module that loads and seals the content
    content  = { "content/*.lua", "qualities.lua" },   -- files held to the content tier
    scripts  = { "*.lua", "tools/*.lua" },             -- engine scripts (full language)
    session  = "game.new_session",     -- function(seed) -> session, for play, test and analysis
    locales  = { "fr", "ru" },         -- translations kept in this repository
}
```

- Without a manifest every tool behaves as it does today.
- File lists are patterns, so the tools do not depend on the `.lua` extension (ROADMAP open
  decision 2, resolved as `.varis` with `.lua` compatibility).
- `content` enables static tier checking in `check` and LSP and load-time enforcement
  in manifest-backed hosts (milestone 26, `services/tier.d`).
- This is not the mod packaging design (ROADMAP open decision 5). It reserves only an id and a
  source language, which is what the localization plan already reserved.

### 3.3 The project index

Built by parsing every listed file. Stored per file and merged, so editing one file re-indexes one
file.

| Table | One row per | Fields |
| --- | --- | --- |
| Files | source file | path, tier, content hash, parse diagnostics |
| Declarations | storylet, choice, action, deck, relation, rule head, quality, named label, function, scene, character, declared symbol | kind, name, owner (a choice's storylet), source range, kind-specific data (a relation's arity, columns and keys; a quality's bounds; a storylet's parameters and deck) |
| References | use of a relation in a goal or fact, of a symbol, a deck, a quality, a storylet id | kind, name, arity where it applies, source range, the declaration it sits in |
| Messages | piece of display text: `title`, `text`, a quality `label`, a `narrative.name` label, scene line/menu label, character name | key, source text, range of the string literal, owning declaration, placeholders, embedded conditions, variant groups, the owner's `when` clause as source text |

Things written as library calls and not as syntax (`quality.define(:coins, {label = "Coins"})`,
`narrative.name(:keeper, "the keeper")`) are indexed when their arguments are literals. A call with
computed arguments is indexed as "not statically known" and the checker says so.

Indexed nodes carry end positions. The index scans templates for source ranges;
a unified diagnostic interface with the runtime template parser remains optional work.

### 3.4 The diagnostic record

| Field | Meaning |
| --- | --- |
| `code` | Stable short word, as today (`syntax`, `symbol-once`). Codes are documented in the manual once they exist and are never reused for another meaning. |
| `severity` | `error`, `warning` or `note`. Only errors fail `varis check`. |
| `file`, `range` | Start and end line and column. Columns are bytes internally; the language server converts to what its protocol wants. |
| `subject` | What the writer would call it: `storylet topic_key`, `choice topic_key.accept`, field `title`. |
| `message` | One sentence that names the subject. |
| `related` | Other locations (the other declaration of a duplicate id). |
| `suggestion` | The nearest known name, when one is close. |

`--json` keeps today's five fields and adds the rest, so existing consumers keep working.

### 3.5 Checker passes of `varis check`

| Pass | Runs project code | Finds |
| --- | --- | --- |
| **Static** (always) | No | Checks implemented over the index: §4 stage A3; computed/dynamic cases remain limited. |
| **Load** (default when the manifest has an `entry`; `--no-load` skips it) | Yes: the entry module, in a fresh state, up to `narrative.seal`. No session is created. | The validation the engine already performs when content is registered and rules are published (arity, variable safety, stratification, ungrounded parameters, unknown decks and placeholders), now reported with the source location of the definition. |
| **Analysis** (`--analyze`, off by default) | Yes: creates a session through the manifest's `session` function, in isolation | Storylets that bounded exploration never reaches, through `narrative.analyze`, which reports its own bounds and incompleteness. |

The load pass runs the project's own engine scripts with the user's permissions, exactly as
`varis serve` does. Checking a contractor's submission is safe to the extent that the contractor
changed only content files; milestone 26 is what makes that enforceable.

## 4. Delivered stages

Stage letters are `A` (authoring tools). All stages below are delivered; this is their
dependency and acceptance record. Preserve their `make test` coverage.

| Stage | Milestone | Deliverable | Needs | Exit test |
| --- | --- | --- | --- | --- |
| A0 (done) | 30 | **Manifest, diagnostic record, ranges.** `project.lua` read by `check` and `serve`; the record of §3.4 in `check` output; end positions on AST nodes; a `check` suite in `tests/manifest.toml` with golden output. | Nothing | *Saltmarsh Light* has a manifest. `varis check --json` on it is a golden file. Its existing five fields are unchanged. |
| A1 (done) | 30, 32 | **Project index.** The four tables of §3.3. The symbol lint and go-to-definition are reimplemented on it and the token and line scanners are deleted. A debugging dump (`varis check --index`). | A0 | The index dump of the sample game is a golden file. The workbench suite's definition requests return what they return today, plus choices and qualities found through the AST. |
| A2 (done) | 31 | **Parser recovery.** In tool mode the parser records an error, skips to the next statement or definition boundary and continues, returning a partial AST and a list. In normal mode it behaves exactly as today. | A0 | A fixture with three independent mistakes reports three. Every existing rejection and error-message test is unchanged. `make bench-check` shows no load-time change. |
| A3 (done) | 30, 31 | **Static checks with writer-facing messages.** See the list below. | A1, A2 | One fixture per code, each with the expected record. The sample game reports nothing new except findings reviewed and recorded in the change. |
| A4 (done) | 30 | **Load and analysis passes** (§3.5). `ContentDefinition` gains a source location that is kept out of fingerprints. | A1 | A project with an unstratifiable rule and one with an ungrounded parameter each get a diagnostic on the right line. The sample game's golden save is byte-identical. |
| A5 (done) | 32 | **Language services.** One D library over the index: diagnostics on change, completion, definition, references, hover (a relation's columns and keys, a quality's bounds, a storylet's deck and conditions), document outline, rename returning a set of edits. The workbench calls it in process; `varis lsp` exposes it on standard input and output; one syntax-highlighting grammar serves the workbench editor and external editors. | A1–A3 | Protocol tests without a browser or editor: scripted requests, golden responses. Renaming a relation in the sample game and running its check passes. Re-indexing one edited file and re-running the static checks is measured on the reference-scale game and given a budget then. |
| A6 (done) | 33 | **Writer workflow.** `varis play` (text playtest: seed, save and load of the replay log, "why" for a missing storylet), `varis test` (author tests), a CI recipe, optionally a formatter. | A4; wrapper resolves choice ids from presentations | The sample game's `tools/check.lua` is rewritten as author tests and passes. The CI recipe rejects a seeded bad submission with a diagnostic naming the storylet. |

Implementation note for A4: the source location of a rejected definition is found by looking its
kind and id up in the project index, not by storing a location in `ContentDefinition`. That keeps
`Prototype`, the binary-chunk format and the fingerprints untouched; the registry only annotates the
`LuaException` it raises with the kind and id of the definition (`contentKind`, `contentId`).

### Static checks of stage A3

Each check has a stable code, fixtures and messages. The table records the implemented
checks and remaining strictness proposals.

| Code (implemented) | Finds | Severity |
| --- | --- | --- |
| `duplicate-id` | Two storylets, actions, decks, scenes or characters with one name; two choices with one name in a storylet. | error |
| `unknown-deck` | `deck :x` where no deck `x` is declared. | error |
| `unknown-placeholder` | `{name}` in a title or text that is not a parameter of the definition. | error |
| `relation-arity` | One relation name used with two arities in the same world scope. | error |
| `unknown-relation` | A relation read in a condition that no file declares, asserts or derives. | warning |
| `unknown-quality` | `quality(_, :x, _)` where `x` is never defined. | warning |
| `symbol-once` | Exists today. Gains the nearest known symbol as a suggestion. | warning |
| `computed-text` | A `title`, `text` or label that is not a string literal (it cannot be extracted for translation). | warning now; error in content files once milestone 26 lands |
| `tier` | A content file using something outside the content tier (**done**, default list of ROADMAP decision 1; static only). | error |
| `unknown-scene`, `unknown-character`, `unknown-character-attribute` | Unresolved literal scene targets, characters or allowed attribute values. | error |
| `undeclared-symbol` | Replaces `symbol-once` when the manifest declares `symbols` (**done** in its smallest reversible form: a manifest list, no new syntax). | error |

Rule for all of them: when a check cannot be sure (a relation created by a computed name, a deck
pushed from a script), it stays silent or reports a warning. A false error teaches writers to
ignore the checker.

### What does and does not wait for the syntax freeze

A0, A1, A2, A4, A5 and `varis play` need no owner decision on syntax. Scenes, characters, declared
symbols and the content tier have initial index/check support. Further syntax can extend
the tables of §3.3 without redesign. V1 syntax was frozen with milestones 27/29
on October 13, 2026; the manual records deferred constructs.

## 5. Author tests (implemented stage A6)

`sample-game/tools/check.lua` was a scripted playthrough with assertions, written against session
internals. The general form is an engine-tier script using a small library, so that a writer can
copy an example:

```lua
local t = test.play { seed = 7 }
t:expect_shown "topic_lamp"
t:choose("topic_lamp", "nod")
t:expect_fact [[ told(:lamp) ]]
t:expect_hidden "topic_lamp"
```

`varis test` runs every file under the manifest's test pattern, each in a fresh state, and reports
failures as diagnostics on the failing line. A failing test can print `narrative.explain` for the
storylet it expected. The author-test wrapper resolves exact choices from a presentation; a public runtime
`session:choose_by` is deferred (`needed_extensions.md` §1.9).

## 6. Historical delivery order with the localization plan

Localization stages are `T0`–`T5` in the localization plan. This records the dependency
order used for delivery; A0–A6 and T0–T4 are implemented. T5 and production refinements
remain in the active roadmap, not the earlier steps below:

| Step | Stage | Why here |
| --- | --- | --- |
| 1 | A0, A1 | Everything else reads the index. |
| 2 | T1: extraction and source catalog | Needs only A1 and no runtime change. It shows at once which text in a real game cannot be extracted, which is evidence for the syntax freeze. |
| 3 | A2, A3, A4 | The checker a writer can use. |
| 4 | T0, T2: owner decisions, then the fingerprint split and named variants | These change the save format, so they should land before content is written in volume. |
| 5 | A5 | Services, with rename that also rewrites catalogs. |
| 6 | T3: translated rendering, French and Russian | Needs the checker to host `--locale`. |
| 7 | A6 | Playtest and tests gain `--locale`. |
| 8 | T4, T5 | Handoff kit and packs; presentation layer with milestone 36. |

The runtime lane of ROADMAP "Order of work" is independent of all of this.

## 7. Open choices (owner)

Use the default until decided, and say so in the change.

| Choice | Default | Reason |
| --- | --- | --- |
| Manifest file name and form | `project.varis` or `project.lua`, a table of literals read without execution | No new parser; cannot run code. TOML is the alternative and needs a TOML reader in D. |
| Where the services live | `source/varis/services/` | Keeps `workbench/` for the server and page. |
| Whether `varis check` runs the load pass by default | Yes when the manifest names an entry | The engine's own validation is the most valuable set of diagnostics. |
| Author-test form | A Lua script using a `test` library (§5) | Writers copy examples; programmers get the full language. A purely declarative transcript format is the alternative. |
| Formatter | Deferred | Not needed for the exit of Phase 10. |
| Diagnostic codes | Short words (`unknown-deck`) | Matches the implemented code vocabulary; readable in a problems list. |
