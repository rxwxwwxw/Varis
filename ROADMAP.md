# Varis roadmap

Status: direction set October 11, 2026 (owner decision). Everything under "Phases" is
**planned, not implemented**. The [Varis Reference Manual](docs/README.md) remains the only
definition of current language behaviour; [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md)
is the engineering history of phases 6–8.

## Direction

Varis is a language and runtime for **authoring visual novels and story games**: quality-based
narrative (storylets, qualities, decks, choices) over a relational world model in the spirit of
Wordgrind, with deterministic saves and replay. A substantial share of the writing will be
subcontracted, so the people writing content are writers first and programmers second or not at all.

The project began as a D port of Lua 5.4 because a real, existing language was the quickest way to
a working interpreter. That job is done. **Lua 5.4 conformance is no longer a project goal.**

Priorities, in order:

1. **Easy and safe to author.** A contracted writer learns the content syntax from examples,
   gets errors that name their storylet and line, and cannot break saves by accident.
2. **Saveable and replayable by construction.** Every state reachable from authored content
   saves, loads and replays deterministically. Language features that cannot be saved or replayed
   are restricted in content rather than documented as obligations.
3. **Tooling is part of the language.** A project checker, editor support and a language server
   are deliverables, not afterthoughts.
4. **Runs well under a graphical front end on low-end hardware.** Performance is measured as
   turn latency, load time and memory on a reference game, not as a ratio against C Lua.
5. **Lua familiarity where it is free.** The procedural core keeps Lua's syntax and semantics so
   existing knowledge and examples carry over.

What does not change: the pipeline and runtime architecture (typed AST, typed instructions,
`SumType` values, D GC), every relational, stateful and narrative semantic defined in the manual,
the test and benchmark gates, and the licence obligations of a Lua-derived work.

## Lua compatibility policy

| Area | Policy |
| --- | --- |
| Procedural syntax and core semantics (values, tables, functions, control flow, strings) | Kept. Divergence needs a reason from the priorities above. |
| Official Lua 5.4.9 suite, core differential fixture, regression programs | Kept in `make test` as a **regression net**. A failure is still a failure and is never fixed by weakening a test. They are no longer a release goal, and no work is planned on the remaining differences in [tests/official/README.md](tests/official/README.md). |
| Deliberate divergence | Allowed when it serves authoring, saves/replay, portability or the low-end budgets. Each one gets a `[[ledger]]` entry in `tests/manifest.toml`, a `Skip-Accepted:` commit trailer and a line in [docs/compatibility.md](docs/compatibility.md) §9. |
| Frozen features (no new work; candidates for removal) | The C API subset and `dlopen` modules (`capi.d`, `lua_api.exports`), binary chunks (`dump.d`), weak-table/finalizer emulation and collector tuning modes (`gc.d`), debug-hook and line-attribution fidelity, exact PUC-Rio error text. Removing one is a separate recorded decision. |

## Language tiers (planned)

The language will have two tiers, enforced per file by the compiler (milestone 26):

- **Content files** — what contracted writers produce: narrative definitions, relations, rules,
  facts, effects and calls to named helpers. No coroutines, no function values that capture
  mutable state or are stored in world/session state, and no `io`, `os`, `debug`, `package`,
  `load` or metatables. The exact list is an open decision.
- **Engine scripts** — the full language, for world setup, shared helpers, host glue, tests and
  tools.

Evidence that the split is natural: in `sample-game/`, five of the seven content files contain no
`function` at all, nothing uses coroutines, and all procedural code lives in `world.lua`,
`game.lua`, `main.lua` and `tools/check.lua`. Internally `effect do … end` and `when { … }`
remain compiled closures; the restriction is on what authors may write, not on the VM.

## Phases

Phases 1–7 are complete and Phase 8 is closed (see the end of this file). Order below is the
intended order of work; phases 11 and 12 may interleave.

### Phase 9 — Authoring language v1: settle the syntax

Goal: freeze a reasonable content syntax quickly, so tools and content can be built on it.
Inputs: [sample-game/needed_extensions.md](sample-game/needed_extensions.md) (cited below by its
section numbers), [sample-game/REVIEW.md](sample-game/REVIEW.md) and
[sample-game/extensions/proposed.lua](sample-game/extensions/proposed.lua).

| Milestone | Deliverable |
| --- | --- |
| 26 | **Tiers and file identity.** Content/engine tiers enforced per file; a source extension and language id distinct from Lua (editors must not treat Varis files as Lua); the decisions recorded in `docs/compatibility.md`. |
| 27 | **Syntax triage and freeze.** Every proposal in `needed_extensions.md` is accepted, deferred or rejected. Accepted constructs get grammar in `docs/syntax.md` and semantics in the manual before they are implemented. Rules of thumb: one obvious way to write a thing; new words stay contextual; nothing in content requires understanding closures, iterators or metatables. |
| 28 | **Core authoring gaps.** Periods settable from effects (§1.1); `leads`/return sugar for decks (§1.2); clamped `adjust` and readable quality metadata (§1.3); a narration channel with events delivered in the presentation (§1.4); binding goals and `or` in rule bodies (§1.5); `expose` (§1.6); session-world binding for handlers and deferred callbacks (§1.7); terminal state (§1.8); `exists` and single-result queries (§1.9). New in this direction: **declared entities/symbols**, so a mistyped `:keepr` is an error instead of a storylet that silently never appears. |
| 29 | **Scenes and beats.** A `scene` content kind compiled to a resumable, serializable position (scene id, beat index, portable locals) rather than a coroutine (§3.1); characters and stable line ids (§3.2); media directives as structured beats (§3.3); beat-stream presentations (§4.1); `jump`/`call`/return between scenes and back to storylet hubs. |

Exit: syntax v1 is documented as frozen; *Saltmarsh Light* runs with its workarounds removed; a
second sample written in linear visual-novel style runs; a save taken mid-scene round-trips.

### Phase 10 — Authoring tools

Goal: a contracted writer installs an editor extension, writes a storylet, sees mistakes inline
and playtests it, without reading D or engine scripts.

| Milestone | Deliverable |
| --- | --- |
| 30 | **`varis check`.** Loads a project without running a session and emits diagnostics (human and `--json`) with file, line/column ranges and stable codes. Surfaces the validation that already exists (arity, safety, stratification, unknown decks and placeholders, ungrounded parameters), enforces the content tier, and adds lints: undeclared or once-used symbols, unknown relations, storylets no bounded analysis can reach. Starting point: AST nodes already carry line and column (`ast.d`); the CLI has no check-only mode. |
| 31 | **Parser recovery and writer-facing messages.** The parser stops at the first error today; recover at statement and definition boundaries so one typo does not hide the rest. Messages name the storylet, choice and field, and suggest the nearest known name. |
| 32 | **Editor support.** A syntax-highlighting grammar, then a language server **built on the Varis frontend** (not adapted from a Lua server, which would understand none of the relational or narrative constructs): diagnostics, completion and go-to-definition for relations, symbols, qualities, decks, storylets and scenes, hover for schemas and quality bounds, rename. |
| 33 | **Writer workflow.** A text-mode playtest host with seeds and replay, "why is this storylet not showing?" built on `narrative.explain`, an author-test format generalizing `sample-game/tools/check.lua`, a CI recipe for checking contractor submissions, and optionally a formatter. |

### Phase 11 — Low-end runtime and host interface

Goal: a game of realistic size runs comfortably under a graphical front end on a low-end machine.

| Milestone | Deliverable |
| --- | --- |
| 34 | **Reference game, reference machine, budgets.** A synthetic game at realistic scale (hundreds of storylets, a map of about a hundred rooms, thousands of facts) and enforced budgets in `benchmarks/targets.toml` for turn latency, content load time, peak memory and save/load time. Provisional starting points, to be replaced by measurement: a turn (choose → effects → actions → next presentation) within 50 ms, no engine work on the render path between turns, content load under 1 s, engine heap under 64 MB. |
| 35 | **Inference engine.** Semi-naive evaluation, argument indexes, a version-keyed materialization cache shared across one presentation snapshot, slot-based bindings (§1.11). Today every `present()` recomputes with a naive fixpoint and unindexed nested-loop joins. Value or tuple representation changes only on profile evidence. |
| 36 | **Host interface.** A documented D embedding API: create a state, load content, run session commands, receive presentations and beats as typed D values (§4.11); a reference graphical host. The front-end technology is an open decision. |
| 37 | **Portability and footprint.** Builds for the platforms low-end machines actually run; development and all measurements so far are on macOS arm64, and several modules import `core.sys.posix` (`gc.d` uses `fork` for reachability probes, `package_lib.d` uses `dlopen`). Bounded GC pauses and heap, start-up time, binary size. Frozen Lua features that block portability are removed here. |

Exit: the reference game meets its budgets on the reference machine under the reference host.

### Phase 12 — Ergonomics and production features

| Milestone | Deliverable |
| --- | --- |
| 38 | Undo/rollback at turn and beat granularity (§2, §3.4); persistent cross-save data (§3.5); save slots and metadata (§4.8). |
| 39 | Localization per [NARRATIVE_LOCALIZATION_PLAN.md](NARRATIVE_LOCALIZATION_PLAN.md), built on the stable line ids of milestone 29. |
| 40 | Twine-class conveniences: `var` sugar, `visited`/`last_chosen`, disabled choices with reasons, rich-text spans, text input, template fragments, pass-through content metadata (§2, §4.3–§4.6). |
| 41 | Writer documentation: a tutorial and cookbook for content authors, separate from the reference manual. |

## Open decisions (owner)

1. The exact content-tier restrictions, and whether engine scripts stay a strict Lua superset.
2. The source file extension and language name shown in editors.
3. The reference low-end machine and the budget numbers in milestone 34.
4. The graphical front-end technology, and whether a WebAssembly build is a target.
5. Which frozen Lua features are removed outright, and when.

## Closed: Phase 8 — core-Lua performance and conformance

Closed October 11, 2026. State at closure ([docs/STATUS.md](docs/STATUS.md), commit `72f5c8d`):

- Official Lua 5.4.9 suite: 31 pass, 1 partial, 1 skipped, 0 fail.
- Core workloads at 0.60–2.41× C Lua and program workloads at 0.21–2.13×, with two known
  outliers: `core.pcall_error` (37.5×, D exceptions through the platform unwinder) and
  `core.deep_recursion` (8.1×).
- Milestones 19 and 20 are done (`tools/suite` runs the benchmark gates and the official suite).
  Milestones 21–25 are **retired, not completed**: the ≤2× C Lua target is no longer pursued.

The `gate.*` ratchets in `benchmarks/targets.toml` stay in force as regression floors, and the
`goal.clua` values stay as an informational reference. See
[benchmarks/PERFORMANCE_WORK.md](benchmarks/PERFORMANCE_WORK.md) for what was done and why the
remaining gaps exist.
