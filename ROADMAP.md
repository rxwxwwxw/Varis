# Varis roadmap

Status: direction revised October 11, 2026 (owner decisions, recorded below). Everything under
"Phases" is **planned, not implemented**. The [Varis Reference Manual](docs/README.md) remains the
only definition of current language behaviour; [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md)
is the engineering history of phases 6–8.

How to read this file:

- **Direction** says what the product is.
- **Decision record** lists every decision that shapes the work, who made it and why. When two
  documents disagree, the decision record wins; fix the other document.
- **Order of work** says what to do next when nobody has said otherwise.
- **Phases** define milestones. Milestone numbers are identifiers, not an order.

## Direction

Varis is a **narrative engine**: a language and runtime for authoring visual novels and story
games. It has three parts that must each be good on their own terms:

1. **A world model.** Facts and Datalog rules describe what is true. Storylets, choices, actions
   and templates ask the world model what is available ("Datalog-style resolution"). Effects
   change it inside transactions. Sessions save and replay deterministically. This is the part
   that makes Varis different from a scripting language with a dialogue library, and it is the
   owner's main concern.
2. **A full programming language, which is Lua.** The procedural core is derived from Lua 5.4 and
   stays a complete language, because people must be able to **mod a game however they like**. A
   modder who knows Lua should find nothing missing.
3. **Tools.** A workbench (an editor, a command window and a workspace browser, served to a web
   browser by the Varis executable itself) and language services built on the Varis frontend.

A substantial share of the writing will be subcontracted, so the people writing content are
writers first and programmers second or not at all.

Targets (owner, October 11, 2026):

- **Distribution:** mainly Steam.
- **Platforms:** Windows, macOS and Linux are the primary targets. An Android build is wanted if
  it is practical, not required.
- **Front end:** SDL3.
- **Languages:** a publisher may translate and localize for Simplified Chinese, Traditional
  Chinese (Hong Kong, Taiwan), Japanese and Korean, so the project's job is tooling that makes
  that handoff easy. French and Russian are the languages the owner can test personally. All
  original content is authored in English and English is the first release language; mods in
  other languages should remain possible. Translation catalog formats stay pluggable.
- **Presentation:** parity for story presentation with Ren'Py, Twine and RPG Maker's event
  commands (not its maps or battles), including character portraits and full-body sprites that
  change with lines of dialogue.

Priorities, in order:

1. **Easy and safe to author.** A contracted writer learns the content syntax from examples,
   gets errors that name their storylet and line, and cannot break saves by accident.
2. **Saveable and replayable by construction.** Every state reachable from authored content
   saves, loads and replays deterministically.
3. **Moddable with the full language.** Engine scripts and mods get all of Lua.
4. **Fast.** Two separate targets (decisions D4 and D5): the world model answers a turn inside a
   budget on low-end hardware, and the Lua core is never slower than C Lua.
5. **Tooling is part of the language.** The checker, the language services and the workbench are
   deliverables, not afterthoughts.
6. **Lua familiarity.** The procedural core keeps Lua's syntax and semantics. Passing more of the
   official Lua test suite is not a goal (D3).

What does not change: every relational, stateful and narrative semantic defined in the manual, the
test and benchmark gates, the single garbage collector (D8), and the licence obligations of a
Lua-derived work.

What is allowed to change, and is planned to: the internal architecture of the runtime (value
representation, instruction encoding, error handling, module layering). See
[benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md).

## Decision record

"Owner" means the project owner said it. "Plan" means it was proposed while planning, follows
from owner decisions, and the owner asked for it to be documented as the direction; the owner
can overturn it. All entries are dated October 11, 2026.

| Id | Decision | Source | Why | What follows from it |
| --- | --- | --- | --- | --- |
| D1 | Varis is a narrative engine for visual novels and story games, not a general Lua implementation. | Owner | Lua was a quick way to get a working interpreter; the product is the authoring language. | Judge features by whether they help authors, players or modders of story games. |
| D2 | The full language is Lua, and it stays complete. Mods may use all of it. | Owner | "People can mod it how they like, so we need a full language, which is Lua." | Do not remove procedural features to simplify the runtime. Restrictions apply to content files and to what may be saved, not to what the language can do. The Lua test suites protect modders and stay in `make test`. |
| D3 | Lua 5.4 conformance is not a goal. | Owner | The remaining gaps (exact collector behaviour, C API, debug-hook fidelity, upstream error text) do not help story games. | No work on closing the gaps listed in `tests/official/README.md`. A new failure in a Lua suite is still a failure. Deliberate divergence is allowed when recorded (policy table below). |
| D4 | The Lua core must not be slower than C Lua, and should become faster. | Owner | "It would be crazy to be slower than C Lua when we have so much more room for optimization." Mods run on the core. | `goal.clua` is 1.0 on every C-Lua-comparable workload. Interpreter restructuring is planned work (milestones 46, 47). This **replaces** the earlier same-day statement that performance is not measured against C Lua. |
| D5 | The world model must answer a turn within a budget on low-end hardware. | Owner | It is the product's distinguishing part and today its cost grows with content size (0.8 s per presentation on a 100-room map with one recursive rule). | Milestones 34 and 35. Budgets in the performance plan. |
| D6 | Implementation style is C-like D: `@nogc nothrow` code in hot paths, return values instead of exceptions, plain structs and tagged unions, templates where they remove duplication, classes where an object needs identity on the collector. Little Phobos. | Owner | Owner's preferred style and considered idiomatic D by the owner; the contributor who favoured Phobos has left. D exceptions and Phobos containers are also measured costs. | Style rules in [AGENTS.md](AGENTS.md) §3. New code follows them; old code is converted by the planned stages, not opportunistically. |
| D7 | Errors travel as values (a status plus an error object stored on the thread), not as D exceptions. | Owner (follows from D6) | `core.pcall_error` is 37× C Lua and the time is all in the platform unwinder. | Milestone 46, stage L1. Until that stage lands the runtime still throws `LuaException`. |
| D8 | One garbage collector: D's. Interpreter objects live and die on the same collector as host D code. No second collector, no reference counting, no handle tables. | Owner | Host code must be able to hold a table, world or session as an ordinary D reference. | `@nogc` code cannot allocate, so buffers are grown at named points outside hot loops. Full `-betterC` builds are impossible (betterC has no collector); "betterC style" means code that would compile under it apart from the allocation points. |
| D9 | The runtime is layered: Lua core, world model, narrative, tools. A lower layer never imports a higher one. | Plan | The world model currently sits on the Lua call path (every Lua-to-Lua call maintains a lexical world), which is part of why the core is slower than C Lua. Separating them lets each be optimized against its own target. | Milestone 45 (the seam). Layer rules in [AGENTS.md](AGENTS.md) §4. |
| D10 | The main development tool is a **workbench in a web browser, served by the Varis executable** (a D server). Layout follows MATLAB: command window on the left, editor on the right, a workspace browser. | Owner | Owner's preferred way of working (applied-mathematics background). One tool for the owner, writers and modders, on every platform, with no editor plug-in to install. | Milestones 42–44 and [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md). The language server for external editors (milestone 32) uses the same services. |
| D11 | Debugging is offered at the level of the **source and the story** (breakpoints on lines, stepping, the workspace, "why is this choice missing", stepping and rewinding turns), through the workbench. Lua's `debug.sethook` is not the debugging interface. | Owner ("have debug bits, but maybe at a higher level") | Authors think in storylets and lines, not instructions. Per-instruction hooks cost the fast path. | Debug support lives in an instrumented executor that the fast path does not pay for (stage S1). The `debug` library stays frozen. |
| D12 | `sample-game/` must keep working through every change. | Owner | It is the only complete game written against the manual. | It joins the test tiers with a golden transcript and golden save bytes (milestone 34, stage S0) before any restructuring starts. |
| D13 | Distribution, platforms, front end and languages as listed under Direction. A WebAssembly build is not planned. English is the source language. Catalog formats are adapters over one model (CSV, JSON and XLIFF first). | Owner | See Direction. | The workbench (D10) runs the engine natively and uses the browser only as a user interface; it does not need WebAssembly. |
| D14 | Default order of work: safety net, seam, world model, Lua core to parity, Lua core beyond C Lua. | Plan | A turn that takes 0.8 s makes a game unplayable; a core at 2× C Lua does not. The seam comes first because both tracks need it. | "Order of work" below. The owner may reorder; the world-model and core tracks are independent once the seam exists. |

## Lua compatibility policy

| Area | Policy |
| --- | --- |
| Procedural syntax and core semantics (values, tables, functions, closures, coroutines, metatables, control flow, strings, standard libraries) | Kept, complete (D2). Divergence needs a reason from the priorities above. |
| Official Lua 5.4.9 suite, core differential fixture, regression programs | Kept in `make test` as a **regression net**. A failure is still a failure and is never fixed by weakening a test. They are not a release goal (D3), and no work is planned on the remaining differences in [tests/official/README.md](tests/official/README.md). |
| Performance of the core against C Lua | A goal (D4). Measured per workload by `make bench`; `gate.clua` ratchets are enforced by `make bench-check`. |
| Deliberate divergence | Allowed when it serves authoring, saves/replay, portability or performance. Each one gets a `[[ledger]]` entry in `tests/manifest.toml`, a `Skip-Accepted:` commit trailer and a line in [docs/compatibility.md](docs/compatibility.md) §9. |
| Frozen features (no new work; candidates for removal) | The C API subset and `dlopen` modules (`capi.d`, `lua_api.exports`), binary chunks (`dump.d`), weak-table/finalizer emulation and collector tuning modes (`gc.d`), `debug.sethook` and line-attribution fidelity, exact PUC-Rio error text. Removing one is a separate recorded owner decision. Frozen features must keep passing their tests while they exist; they may run on the slower instrumented executor. |

## Language tiers (planned)

The language will have two tiers, enforced per file by the compiler (milestone 26):

- **Content files** — what contracted writers produce: narrative definitions, relations, rules,
  facts, effects and calls to named helpers. No coroutines, no function values that capture
  mutable state or are stored in world/session state, and no `io`, `os`, `debug`, `package`,
  `load` or metatables. The restriction exists so that writers cannot break saves by accident and
  so that a content-only package can be loaded without trusting its author. The exact list is an
  open decision.
- **Engine scripts and script mods** — the full language (D2), for world setup, shared helpers,
  host glue, tests, tools and mods that change how a game works.

The tiers are a property of files, not of the virtual machine: both compile to the same bytecode
and run on the same core, so core performance (D4) benefits both.

Evidence that the split is natural: in `sample-game/`, five of the seven content files contain no
`function` at all, nothing uses coroutines, and all procedural code lives in `world.lua`,
`game.lua`, `main.lua` and `tools/check.lua`. Internally `effect do … end` and `when { … }`
remain compiled closures.

## Order of work

There are two lanes. They do not block each other.

**Runtime lane (needs no owner decisions; the default thing to work on).** Stages are defined in
[benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md). Do them in this order unless
the owner says otherwise (D14):

1. Stage S0, safety net: sample game in the tests with golden output, reference-game benchmark
   (milestone 34).
2. Stage S1, the seam between the Lua core and the world model (milestone 45).
3. Stages W1–W5, world-model engine to its turn budget (milestone 35).
4. Stages L1–L4, Lua core to parity with C Lua (milestone 46).
5. Stages X1–X4, Lua core beyond C Lua (milestone 47).
6. Stage M, memory, pauses and real hardware (milestone 37).

**Language and tools lane (needs owner decisions on syntax).** Phase 9, then Phase 10. Within
Phase 10 the workbench server and the story-level debugger (milestones 42, 43 and the story half
of 44) need nothing from Phase 9 and can start at any time; source-level debugging needs stage S1.

## Phases

Phases 1–7 are complete and Phase 8 is closed (see the end of this file).

### Phase 9 — Authoring language v1: settle the syntax

Goal: freeze a reasonable content syntax quickly, so tools and content can be built on it.
Inputs: [sample-game/needed_extensions.md](sample-game/needed_extensions.md) (cited below by its
section numbers), [sample-game/REVIEW.md](sample-game/REVIEW.md) and
[sample-game/extensions/proposed.lua](sample-game/extensions/proposed.lua).

| Milestone | Deliverable |
| --- | --- |
| 26 | **Tiers and file identity.** Content/engine tiers enforced per file; a source extension and language id distinct from Lua (editors must not treat Varis files as Lua); the decisions recorded in `docs/compatibility.md`. |
| 27 | **Syntax triage and freeze.** Every proposal in `needed_extensions.md` is accepted, deferred or rejected. Accepted constructs get grammar in `docs/syntax.md` and semantics in the manual before they are implemented. Rules of thumb: one obvious way to write a thing; new words stay contextual; nothing in content requires understanding closures, iterators or metatables. The freeze includes the localization-ready decisions of [NARRATIVE_LOCALIZATION_PLAN.md](NARRATIVE_LOCALIZATION_PLAN.md) §3: message keys from authored names and line ids, one template grammar with named placeholders, a select/plural construct and named variants, literal display text in content files, and wording kept out of the gameplay fingerprint. |
| 28 | **Core authoring gaps.** Periods settable from effects (§1.1); `leads`/return sugar for decks (§1.2); clamped `adjust` and readable quality metadata (§1.3); a narration channel with events delivered in the presentation (§1.4); binding goals and `or` in rule bodies (§1.5); `expose` (§1.6); session-world binding for handlers and deferred callbacks (§1.7); terminal state (§1.8); `exists` and single-result queries (§1.9). New in this direction: **declared entities/symbols**, so a mistyped `:keepr` is an error instead of a storylet that silently never appears. |
| 29 | **Scenes, beats and the stage.** A `scene` content kind compiled to a resumable, serializable position (scene id, beat index, portable locals) rather than a coroutine (§3.1); characters and stable line ids (§3.2); media directives as structured beats (§3.3); beat-stream presentations (§4.1); `jump`/`call`/return between scenes and back to storylet hubs. **Stage state is engine data**: each character has a tag and a set of attributes (expression, outfit) that a dialogue line can change, plus who is on stage in which named slot, the background and named audio channels. It is carried in beats and saved in the session, so a load or rollback restores it and the checker can reject an unknown character or attribute. The engine never holds pixel positions, timing or image files. From the same state a front end can draw a face in the text box, a full-body sprite, or both. Parity checklist for this milestone: RPG Maker's story event commands (text with face/name/window position, choices with default and cancel, number and item input, pictures, screen fade/tint/flash/shake, waits, BGM/BGS/ME/SE, inline text codes for colour, size, pauses and speed, common events), Ren'Py's show/hide/scene with transitions, side images, menus and jump/call, and Twine's passages and inline links. |

Exit: syntax v1 is documented as frozen; *Saltmarsh Light* runs with its workarounds removed; a
second sample written in linear visual-novel style runs; a save taken mid-scene round-trips.

### Phase 10 — Authoring tools and the workbench

Goal: a writer starts `varis serve` in a project, opens the workbench in a browser, writes a
storylet, sees mistakes inline, playtests it and asks why a choice is missing, without reading D
or engine scripts. A writer who prefers their own editor gets the same diagnostics through a
language server. Design and rationale: [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md).

| Milestone | Deliverable |
| --- | --- |
| 30 | **`varis check`.** Loads a project without running a session and emits diagnostics (human and `--json`) with file, line/column ranges and stable codes. Surfaces the validation that already exists (arity, safety, stratification, unknown decks and placeholders, ungrounded parameters), enforces the content tier, and adds lints: undeclared or once-used symbols, unknown relations, storylets no bounded analysis can reach. Starting point: AST nodes already carry line and column (`ast.d`). **First version done (October 11, 2026):** `varis check [--json] [files]` compiles every file without running it and reports compile errors with file, line and a code (`source/varis/workbench/check.d`); the validation, tier and lint checks are not implemented. |
| 31 | **Parser recovery and writer-facing messages.** The parser stops at the first error today; recover at statement and definition boundaries so one typo does not hide the rest. Messages name the storylet, choice and field, and suggest the nearest known name. |
| 32 | **Language services and the language server.** One D library **built on the Varis frontend** (not adapted from a Lua server, which would understand none of the relational or narrative constructs): diagnostics, completion and go-to-definition for relations, symbols, qualities, decks, storylets and scenes, hover for schemas and quality bounds, rename. It is reached two ways: the workbench calls it directly, and a language server exposes it over the Language Server Protocol for external editors, together with a syntax-highlighting grammar. |
| 33 | **Writer workflow.** A text-mode playtest host with seeds and replay, "why is this storylet not showing?" built on `narrative.explain`, an author-test format generalizing `sample-game/tools/check.lua`, a CI recipe for checking contractor submissions, and optionally a formatter. |
| 42 | **Workbench server.** `varis serve <project>`: the Varis executable hosts the project's state and serves a web application and a message protocol on the local machine. Commands typed in the browser run in the live state. No WebAssembly: the engine runs natively and the browser is only the user interface (D13). **First version done (October 11, 2026)**: command window, workspace with relation tables, story panel, plain editor, over request/response HTTP; see WORKBENCH_PLAN §1a. |
| 43 | **Workbench user interface.** Command window on the left, editor on the right, workspace browser, a story panel that plays the game as text, a problems list (D10). The workspace shows variables and also what Varis has that MATLAB does not: worlds and their relations as tables, qualities, the session's turn, decks and history. |
| 44 | **Debugging at the level of the source and the story** (D11). Story level: step one turn, rewind by replay, show what the last turn changed, explain why a storylet or choice is or is not available. Source level: breakpoints on lines, pause, step over/into/out, the call stack, locals in the workspace, evaluating an expression in a paused frame. Built on the instrumented executor of stage S1; the fast executor carries no debugging cost. |

### Phase 11 — Fast runtime and host interface

Goal: the Lua core is at least as fast as C Lua, and a game of realistic size runs comfortably
under a graphical front end on a low-end machine. The staged plan, with the measurements behind
it, is [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md). None of it depends on the
Phase 9 syntax.

| Milestone | Deliverable | Plan stages |
| --- | --- | --- |
| 34 | **Safety net, reference game, budgets.** `sample-game/` in the test tiers with a golden transcript and golden save bytes (D12). A synthetic reference game at realistic scale (about 100 rooms, 1000 storylets, thousands of facts, a recursive rule and an aggregate) as a benchmark group with enforced budgets in `benchmarks/targets.toml` for turn latency, content load time, peak memory and save time. Provisional low-end budgets: a turn (choose → effects → actions → next presentation) within 50 ms, no engine work on the render path between turns, content load under 1 s, `save()` under 50 ms, peak engine memory under 64 MB. Measured on an Apple M1 before the work started: a 100-room game with one recursive rule took about 0.8 s per presentation and 171 MB. **Done (October 11, 2026)** except that the reference game does not yet use an aggregate and budgets are gates at measured cost, not yet the provisional budgets. | S0 |
| 45 | **The seam.** The Lua core no longer knows about worlds, transactions or narrative: no core module imports `varis.logic` or `varis.narrative`, plain Lua calls do no world bookkeeping, and one executor source generates the fast and the instrumented executors. No behaviour change; saves and fingerprints stay byte-identical. **Boundary done (October 11, 2026)** and enforced by `make check-sources`; 40 of 43 opcode handlers are shared between the two executors. The per-call world swap and a single instrumented executor remain. | S1 |
| 35 | **World-model engine.** Shared immutable fact storage instead of copying per query, rule bodies and queries compiled once to slot-based plans with indexes, semi-naive evaluation of recursive strata, derived relations cached per world version, storylets indexed by the constant parts of their conditions. The original evaluator stays as a test oracle. **Done (October 11, 2026):** 0.3 ms per presentation and 53 MB on the reference-scale game, including storylet indexing by a required fact; real low-end hardware is still unmeasured. | W1–W5 |
| 46 | **Lua core to parity with C Lua.** Errors as values (D7), a 16-byte value with string objects, a compact private execution encoding lowered from the canonical bytecode, a slimmer call path. Exit: every C-Lua-comparable core workload at or below 1.0×, including `core.pcall_error` and `core.deep_recursion`. **In progress:** errors are returned between Lua frames and the value is 16 bytes; core workloads are at 0.5–2.3×. | L1–L4 |
| 47 | **Lua core beyond C Lua.** Inline caches for field, method and global access, type-specialized and fused instructions, compiler passes on the typed AST, a second attempt at profile-guided builds. A just-in-time compiler is not planned. | X1–X4 |
| 36 | **Host interface and standard presentation layer.** A documented D embedding API: create a state, load content, run session commands, receive presentations and beats as typed D values (§4.11). Errors cross the host boundary as return values (D7), with an optional throwing wrapper. On top of it, a standard SDL3 presentation layer that implements the stage of milestone 29 (text box, portraits, sprites in slots, transitions, screen effects, audio channels, history log, skip and auto modes), so a game supplies a skin and an asset manifest rather than a renderer. Text layout there must handle scripts written without spaces and per-language fonts (localization plan §5). Starts with a spike on SDL3 bindings and text rendering from D. | |
| 37 | **Portability and footprint.** Builds for Windows, macOS and Linux, then an Android build through SDL3 if practical; development and all measurements so far are on macOS arm64, and several modules import `core.sys.posix` (`gc.d` uses `fork` for reachability probes, `package_lib.d` uses `dlopen`). Bounded collector pauses and heap, start-up time, binary size. Frozen Lua features that block portability are removed here. | M |

Exit: the reference game meets its budgets on the reference machine under the reference host, and
`make bench` reports no core workload behind its `goal.clua`.

### Phase 12 — Ergonomics and production features

| Milestone | Deliverable |
| --- | --- |
| 38 | Undo/rollback at turn and beat granularity (§2, §3.4); persistent cross-save data (§3.5); save slots and metadata (§4.8). |
| 39 | Localization pipeline per [NARRATIVE_LOCALIZATION_PLAN.md](NARRATIVE_LOCALIZATION_PLAN.md): catalogs, the publisher handoff kit, loadable translation packs, per-language text features for Chinese, Japanese, Korean, French and Russian. Built on the line ids of milestone 29 and the decisions frozen in milestone 27. |
| 40 | Twine-class conveniences: `var` sugar, `visited`/`last_chosen`, disabled choices with reasons, rich-text spans, text input, template fragments, pass-through content metadata (§2, §4.3–§4.6). |
| 41 | Writer documentation: a tutorial and cookbook for content authors, separate from the reference manual. |

## Open decisions (owner)

Until one of these is decided, use the stated default and say so in the change.

| # | Question | Default until decided |
| --- | --- | --- |
| 1 | The exact content-tier restrictions. | The list under "Language tiers". |
| 2 | The source file extension and language name shown in editors. | Keep `.lua`. |
| 3 | The reference low-end machine and the budget numbers in milestone 34. | The provisional budgets; an M1 performance core is assumed ten times faster than the low-end machine. |
| 4 | Which frozen Lua features are removed outright, and when. | Remove none; keep them passing on the instrumented executor. |
| 5 | How mods are packaged, loaded and recorded in saves (the localization plan only reserves room: packages with a declared source language and package-qualified keys). | Not designed; do not build on assumptions about it. |
| 6 | Whether script mods get the unrestricted standard library (`io`, `os`, `package`) or a sandboxed set. | Unrestricted, as today. |
| 7 | The order of the world-model track and the Lua-core track (D14). | World model first. |
| 8 | Whether the public D host API returns statuses only or also offers a throwing wrapper. | Status returns, with an optional thin throwing wrapper. |
| 9 | Workbench choices: the editor component, whether the server uses a third-party HTTP library, and the exact panel layout. | See [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md) §9. |
| 10 | A target below 1.0× C Lua for milestone 47. | None until parity is reached and measured. |

## Closed: Phase 8 — core-Lua performance and conformance

Closed October 11, 2026. State at closure ([docs/STATUS.md](docs/STATUS.md), commit `15522b1`):

- Official Lua 5.4.9 suite: 31 pass, 1 partial, 1 skipped, 0 fail.
- Core workloads at 0.60–2.41× C Lua and program workloads at 0.21–2.17×, with two known
  outliers: `core.pcall_error` (37.4×, D exceptions through the platform unwinder) and
  `core.deep_recursion` (8.4×).
- Milestones 19 and 20 are done (`tools/suite` runs the benchmark gates and the official suite).
  Milestones 21–25 are **retired, not completed**. Their target was "no more than 2× C Lua"
  reached by tuning the existing design.

Phase 8 stays closed. Core performance is a goal again (D4), with a stricter target (1.0×) and a
different method (restructuring, milestones 45–47), so it is tracked in Phase 11 and not by
reopening Phase 8. The conformance half of Phase 8 remains closed for good (D3).

The `gate.*` ratchets in `benchmarks/targets.toml` stay in force as regression floors.
[benchmarks/PERFORMANCE_WORK.md](benchmarks/PERFORMANCE_WORK.md) records what the Phase 8 work
changed and why the remaining gaps exist.
