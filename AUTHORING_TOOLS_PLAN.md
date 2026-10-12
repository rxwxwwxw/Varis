# Authoring tools plan: project model, checker, language services, writer workflow

Status: **proposed**, October 12, 2026; stage A0 implemented the same day (see §4). It details milestones 30, 31, 32 and 33 of
[ROADMAP.md](ROADMAP.md) Phase 10. Section 2 says what exists; everything else is a plan. Command
names, file names and formats below are proposals. Language behaviour is defined only by the
[manual](docs/README.md).

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

All three need the same thing: **a description of the project read from its source files, without
executing them**. Today each tool improvises its own (§2). The plan is to build that description
once and put every tool on it.

## 2. What exists today

| Piece | Today | Where |
| --- | --- | --- |
| `varis check [--json] [files]` | Compiles each file. Reports the **first** error of a file, with a line but no column or range. One lint: a symbol written exactly once in the project. JSON fields: `file`, `line`, `severity`, `code`, `message`. | `source/varis/workbench/check.d` |
| Symbol lint | Scans lexer tokens; does not use the AST. | same |
| Go to definition | Scans source **lines** for `storylet NAME`, `relation NAME`, `quality.define(:NAME` and similar prefixes. | `definitionsJson` in `workbench/server.d` |
| Completion | Reads the **live state**, so it knows only what has been loaded and run. | `W.complete` in `workbench/server.d` |
| Parser | Stops at the first error by throwing `LuaException`. | `parser.d` |
| Source positions | `SourceLoc` has a start line and column. Few nodes record where they end. | `ast.d` |
| Narrative definitions in the AST | `NarrativeDefinitionStmt` keeps the kind, name, parameters, goals, field names with their value expressions (so `title` and `text` literals are visible), choices and the effect block. | `ast.d` |
| Templates | Parsed when content is registered, by throwing code that keeps no positions inside the string. | `narrative/templates.d` |
| Registered content | `ContentDefinition` has no source file or line, so a load-time validation error cannot point at source. | `narrative/registry.d` |
| What a project is | Nothing declares it. `varis serve` takes a directory; `varis check` takes every `.lua` file under the current directory; *Saltmarsh Light* is loaded by `game.lua` through `require`. | |
| Playtest and author tests | Hand-written per game: `sample-game/main.lua` and `sample-game/tools/check.lua`. | |

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
   AGENTS §3: return values, no `throw`, explicit loops, little Phobos. Proposed home:
   `source/varis/services/`, added to the tools layer in `tools/check_sources.py` and to the
   Makefile list. `workbench/check.d` moves there in its own commit.

### 3.2 The project manifest

One file at the project root says what the project is. Proposed name `project.lua`; it is a single
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
  decision 2).
- `content` only records the author's intent until milestone 26 enforces the tier.
- This is not the mod packaging design (ROADMAP open decision 5). It reserves only an id and a
  source language, which is what the localization plan already reserved.

### 3.3 The project index

Built by parsing every listed file. Stored per file and merged, so editing one file re-indexes one
file.

| Table | One row per | Fields |
| --- | --- | --- |
| Files | source file | path, tier, content hash, parse diagnostics |
| Declarations | storylet, choice, action, deck, relation, rule head, quality, named label, function; later scene, character, declared symbol | kind, name, owner (a choice's storylet), source range, kind-specific data (a relation's arity, columns and keys; a quality's bounds; a storylet's parameters and deck) |
| References | use of a relation in a goal or fact, of a symbol, a deck, a quality, a storylet id | kind, name, arity where it applies, source range, the declaration it sits in |
| Messages | piece of display text: `title`, `text`, a quality `label`, a `narrative.name` label | key, source text, range of the string literal, owning declaration, placeholders, embedded conditions, variant groups, the owner's `when` clause as source text |

Things written as library calls and not as syntax (`quality.define(:coins, {label = "Coins"})`,
`narrative.name(:keeper, "the keeper")`) are indexed when their arguments are literals. A call with
computed arguments is indexed as "not statically known" and the checker says so; in
*Saltmarsh Light* `qualities.lua:21` is such a call.

Work the frontend needs first: every node the index reports must have an **end** position, and the
template parser must report positions inside the string. Both are additions to recorded data, not
changes to what compiles.

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

### 3.5 Two passes of `varis check`

| Pass | Runs project code | Finds |
| --- | --- | --- |
| **Static** (always) | No | Everything derivable from the index: §4 stage A3. |
| **Load** (default when the manifest has an `entry`; `--no-load` skips it) | Yes: the entry module, in a fresh state, up to `narrative.seal`. No session is created. | The validation the engine already performs when content is registered and rules are published (arity, variable safety, stratification, ungrounded parameters, unknown decks and placeholders), now reported with the source location of the definition. |
| **Analysis** (`--analyze`, off by default) | Yes: creates a session through the manifest's `session` function, in isolation | Storylets that bounded exploration never reaches, through `narrative.analyze`, which reports its own bounds and incompleteness. |

The load pass runs the project's own engine scripts with the user's permissions, exactly as
`varis serve` does. Checking a contractor's submission is safe to the extent that the contractor
changed only content files; milestone 26 is what makes that enforceable.

## 4. Stages

Stage letters are `A` (authoring tools). Do them in this order. Each stage passes `make test`.

| Stage | Milestone | Deliverable | Needs | Exit test |
| --- | --- | --- | --- | --- |
| A0 (done) | 30 | **Manifest, diagnostic record, ranges.** `project.lua` read by `check` and `serve`; the record of §3.4 in `check` output; end positions on AST nodes; a `check` suite in `tests/manifest.toml` with golden output. | Nothing | *Saltmarsh Light* has a manifest. `varis check --json` on it is a golden file. Its existing five fields are unchanged. |
| A1 | 30, 32 | **Project index.** The four tables of §3.3. The symbol lint and go-to-definition are reimplemented on it and the token and line scanners are deleted. A debugging dump (`varis check --index`). | A0 | The index dump of the sample game is a golden file. The workbench suite's definition requests return what they return today, plus choices and qualities found through the AST. |
| A2 | 31 | **Parser recovery.** In tool mode the parser records an error, skips to the next statement or definition boundary and continues, returning a partial AST and a list. In normal mode it behaves exactly as today. | A0 | A fixture with three independent mistakes reports three. Every existing rejection and error-message test is unchanged. `make bench-check` shows no load-time change. |
| A3 | 30, 31 | **Static checks with writer-facing messages.** See the list below. | A1, A2 | One fixture per code, each with the expected record. The sample game reports nothing new except findings reviewed and recorded in the change. |
| A4 | 30 | **Load and analysis passes** (§3.5). `ContentDefinition` gains a source location that is kept out of fingerprints. | A1 | A project with an unstratifiable rule and one with an ungrounded parameter each get a diagnostic on the right line. The sample game's golden save is byte-identical. |
| A5 | 32 | **Language services.** One D library over the index: diagnostics on change, completion, definition, references, hover (a relation's columns and keys, a quality's bounds, a storylet's deck and conditions), document outline, rename returning a set of edits. The workbench calls it in process; `varis lsp` exposes it on standard input and output; one syntax-highlighting grammar serves the workbench editor and external editors. | A1–A3 | Protocol tests without a browser or editor: scripted requests, golden responses. Renaming a relation in the sample game and running its check passes. Re-indexing one edited file and re-running the static checks is measured on the reference-scale game and given a budget then. |
| A6 | 33 | **Writer workflow.** `varis play` (text playtest: seed, save and load of the replay log, "why" for a missing storylet), `varis test` (author tests), a CI recipe, optionally a formatter. | A4; `session:choose_by` from milestone 28 | The sample game's `tools/check.lua` is rewritten as author tests and passes. The CI recipe rejects a seeded bad submission with a diagnostic naming the storylet. |

### Static checks of stage A3

Each is a code, a fixture and a message. Add them one per change if convenient.

| Code (proposed) | Finds | Severity |
| --- | --- | --- |
| `duplicate-id` | Two storylets, actions or decks with one name; two choices with one name in a storylet. | error |
| `unknown-deck` | `deck :x` where no deck `x` is declared. | error |
| `unknown-placeholder` | `{name}` in a title or text that is not a parameter of the definition. | error |
| `relation-arity` | One relation name used with two arities in the same world scope. | error |
| `unknown-relation` | A relation read in a condition that no file declares, asserts or derives. | warning |
| `unknown-quality` | `quality(_, :x, _)` where `x` is never defined. | warning |
| `symbol-once` | Exists today. Gains the nearest known symbol as a suggestion. | warning |
| `computed-text` | A `title`, `text` or label that is not a string literal (it cannot be extracted for translation). | warning now; error in content files once milestone 26 lands |
| `tier` | A content file using something outside the content tier. | waits for milestone 26 |
| `undeclared-symbol` | Replaces `symbol-once` when declared symbols exist. | waits for milestone 28 |

Rule for all of them: when a check cannot be sure (a relation created by a computed name, a deck
pushed from a script), it stays silent or reports a warning. A false error teaches writers to
ignore the checker.

### What does and does not wait for the syntax freeze

A0, A1, A2, A4, A5 and `varis play` need no owner decision on syntax. Scenes, characters, declared
symbols and the content tier each add rows to the index and checks to A3 when their milestone
lands; the tables of §3.3 are meant to take new kinds without redesign.

## 5. Author tests (proposal for stage A6)

`sample-game/tools/check.lua` is a scripted playthrough with assertions, written against session
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
storylet it expected. This needs `session:choose_by` (`needed_extensions.md` §1.9).

## 6. Combined order with the localization plan

Localization stages are `T0`–`T5` in the localization plan. Recommended order across both plans:

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
| Manifest file name and form | `project.lua`, a table of literals read without execution | No new parser; cannot run code. TOML is the alternative and needs a TOML reader in D. |
| Where the services live | `source/varis/services/` | Keeps `workbench/` for the server and page. |
| Whether `varis check` runs the load pass by default | Yes when the manifest names an entry | The engine's own validation is the most valuable set of diagnostics. |
| Author-test form | A Lua script using a `test` library (§5) | Writers copy examples; programmers get the full language. A purely declarative transcript format is the alternative. |
| Formatter | Deferred | Not needed for the exit of Phase 10. |
| Diagnostic codes | Short words (`unknown-deck`) | Matches the two codes that exist; readable in a problems list. |
