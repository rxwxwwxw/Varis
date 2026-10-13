# Varis roadmap

Status: direction revised October 11, 2026; implementation status audited October 12, 2026.
The phases mix implemented stages, partial milestones and future work; status notes distinguish them. The [Varis Reference Manual](docs/README.md) remains the
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

Two tiers enforced per file (milestone 26, implemented October 13, 2026). The manifest records
tiers; `varis check` and the language server enforce the default content restrictions
statically; and a host that has read the manifest enforces them when files load, in a
restricted environment (manual §8.3). A plain script run with no manifest keeps the full
language:

- **Content files** — what contracted writers produce: narrative definitions, relations, rules,
  facts, transactional effects, ordinary expressions, local variables and structured control
  flow, plus calls to named helpers explicitly exposed by engine scripts. No author-defined
  function values, coroutines, metatables, dynamic loading or direct access to `io`, `os`,
  `debug` or `package`. Compilation/loading must enforce this policy with a restricted
  environment so aliases cannot trivially bypass it. Exposed helpers are trusted engine code
  responsible for respecting save/replay rules. Decided October 13, 2026; implemented the
  same day (the helpers are exposed with `narrative.helper`).
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
| 26 | **Tiers and file identity.** Content/engine tiers enforced per file; a source extension and language id distinct from Lua (editors must not treat Varis files as Lua); the decisions recorded in `docs/compatibility.md`. **Implemented October 13, 2026:** source files may use `.varis` (`require` finds `a/b.varis`, manifest patterns written `.lua` also match it, `project.varis` is read, editors' grammar and the language server accept it; `.lua` loads as before); a host that has read the manifest installs a load-time policy (`LuaState.fileTierHook`, `services/tier.d`): a file matching `content` is vetted by the static tier check and runs in a restricted environment (no `io`, `os`, `debug`, `package`, `load`, `coroutine` or metatable functions; helpers exposed with `narrative.helper`; unknown globals are errors naming it). Suite `tiers`. Manual §8.3. |
| 27 | **Syntax triage and freeze.** Every proposal in `needed_extensions.md` is accepted, deferred or rejected. Accepted constructs get grammar in `docs/syntax.md` and semantics in the manual in the same change that implements and tests them; unimplemented syntax stays in proposals. Rules of thumb: one obvious way to write a thing; new words stay contextual; nothing in content requires understanding closures, iterators or metatables. The freeze includes the localization-ready decisions of [NARRATIVE_LOCALIZATION_PLAN.md](NARRATIVE_LOCALIZATION_PLAN.md) §3: message keys from authored names and line ids, one template grammar with named placeholders, a select/plural construct and named variants, literal display text in content files, and wording kept out of the gameplay fingerprint. **Done October 13, 2026:** every topic of the inventory has a disposition (table in `sample-game/needed_extensions.md`), the implemented constructs have grammar in `docs/syntax.md` §10 and semantics in the manual, and §10.5 records what is frozen, what is accepted but not built (readable scene bodies, explicit text ids in content, readable input statements: milestone 29) and what is deferred. The migration of *Saltmarsh Light* off its workarounds is separate work. |
| 28 | **Core authoring gaps.** Periods settable from effects (§1.1); `leads`/return sugar for decks (§1.2); clamped `adjust` and readable quality metadata (§1.3); a narration channel with events delivered in the presentation (§1.4); binding goals and `or` in rule bodies (§1.5); `expose` (§1.6); session-world binding for handlers and deferred callbacks (§1.7); terminal state (§1.8); `exists` and single-result queries (§1.9). New in this direction: **declared entities/symbols**, so a mistyped `:keepr` is an error instead of a storylet that silently never appears. **Implemented October 13, 2026:** `narrative.set_period`; choice `leads :deck` and `narrative.return_deck`; `adjust … clamp`, `quality.add(…, {clamp = true})` and `quality.metadata`; presentation `events` and `session:events_since` (the cursor is saved only when events are waiting); computed bindings `?x := expr` (rejected in recursive rules) and parenthesized `or`; `expose ?x`; handler and `narrative.defer` callbacks default to the session's world; `narrative.finish` and `session:ended`; `exists { … }` and `logic.one`; `symbols a, b` with the manifest list (strict once either exists; refused at load in content). Manual §§4.6a, 4.8a, 6.2–6.8a, 7.4, 8.3, 10. Suite cases `phase9_*` in `tests/extensions`. |
| 29 | **Scenes, beats and the stage.** A `scene` content kind compiled to a resumable, serializable position (scene id, beat index, portable locals) rather than a coroutine (§3.1); characters and stable line ids (§3.2); media directives as structured beats (§3.3); beat-stream presentations (§4.1); `jump`/`call`/return between scenes and back to storylet hubs. **Stage state is engine data**: each character has a tag and a set of attributes (expression, outfit) that a dialogue line can change, plus who is on stage in which named slot, the background and named audio channels. It is carried in beats and saved in the session, so a load or rollback restores it and the checker can reject an unknown character or attribute. The engine never holds pixel positions, timing or image files. From the same state a front end can draw a face in the text box, a full-body sprite, or both. Parity checklist for this milestone: RPG Maker's story event commands (text with face/name/window position, choices with default and cancel, number and item input, pictures, screen fade/tint/flash/shake, waits, BGM/BGS/ME/SE, inline text codes for colour, size, pauses and speed, common events), Ren'Py's show/hide/scene with transitions, side images, menus and jump/call, and Twine's passages and inline links. |

Milestone 29, readable scenes (October 13, 2026): `scene name() … end` with `say … id …`,
`narrate`, `show … at`, `hide`, `background`, `audio`, structured directives, `input … id`,
`set`, `menu`/`option`, `if`/`elseif`/`else` on a local, `effect name(…)` and
`effect using … do … end`, `jump`/`call`/`return`/`ended`; it lowers at parse time to the beat
tables (plus a `branch` beat and generated scenes/procedures), requires an explicit
scene-scoped id on every line, and is documented in manual 6.11a and `docs/syntax.md` §10.
*Saltmarsh Light* was migrated off its workarounds (golden and format-1 fixture regenerated in
their own commit) and `sample-vn` is written in the readable form (`content.varis`).

Milestone 29 first version (October 12, 2026): declarative `scene`/`character`
programs, scalar locals, jump/call/return, menu/input beats, stable line ids,
engine-owned stage and format 3 scene saves are implemented; see manual §6.11.
`sample-vn/` proves mid-scene and mid-call restoration, including fresh-process
loading and wording compatibility. The current manual also documents beat undo and input
validation. The writer-facing procedural syntax landed on October 13 (above). The full presentation
parity checklist above is retained as a comparison target; by owner decision October 13,
advanced rendering belongs to milestone 36 and does not block the Phase 9 syntax freeze.
General mixed scene/storylet beat streams and a separate passage kind are deferred.

Exit: syntax v1 is documented as frozen; *Saltmarsh Light* runs with its workarounds removed; a
second sample written in linear visual-novel style runs; a save taken mid-scene round-trips.
The agreed v1 boundary includes readable branching scenes, calls, input, transactional effects,
beat undo, saveable stage state, structured media directives, stable text ids and localization
coverage (including menu labels and character display names), plus the agreed relational/session
improvements and sample migration. See the October 13 Phase 9 decisions below.

### Phase 10 — Authoring tools and the workbench

Goal: a writer starts `varis serve` in a project, opens the workbench in a browser, writes a
storylet, sees mistakes inline, playtests it and asks why a choice is missing, without reading D
or engine scripts. A writer who prefers their own editor gets the same diagnostics through a
language server. Design and rationale: [AUTHORING_TOOLS_PLAN.md](AUTHORING_TOOLS_PLAN.md) for
milestones 30–33 (stages A0–A6, and the order combined with localization) and
[WORKBENCH_PLAN.md](WORKBENCH_PLAN.md) for milestones 42–44.

| Milestone | Deliverable |
| --- | --- |
| 30 | **`varis check`.** Loads a project without running a session and emits diagnostics (human and `--json`) with file, line/column ranges and stable codes. Surfaces the validation that already exists (arity, safety, stratification, unknown decks and placeholders, ungrounded parameters), enforces the content tier, and adds lints: undeclared or once-used symbols, unknown relations, storylets no bounded analysis can reach. Starting point: AST nodes already carry line and column (`ast.d`). **Implemented October 12, 2026** (authoring tools plan stages A0–A4): `varis check [--json] [--index] [--no-load] [--locale L] [--analyze] [files]` reads the project manifest, reports every syntax error with a range, runs the static checks (`duplicate-id`, `unknown-deck`, `unknown-placeholder`, `relation-arity`, `unknown-relation`, `unknown-quality`, `symbol-once`, `computed-text`), loads the entry module to surface the engine's validation at the definition's line, and with `--analyze` lists storylets bounded exploration does not reach. The content tier of milestone 26 is enforced statically with the default list below (`tier`). Declared symbols exist in their smallest form (a `symbols` list in the manifest, `undeclared-symbol`); a language-level declaration syntax is not designed. |
| 31 | **Parser recovery and writer-facing messages.** Tool-mode parsing recovers at statement and definition boundaries so one typo does not hide the rest; normal loading still stops at the first error. Messages name the storylet, choice and field, and suggest the nearest known name. **Implemented (A2, A3).** |
| 32 | **Language services and the language server.** One D library **built on the Varis frontend** (not adapted from a Lua server, which would understand none of the relational or narrative constructs): diagnostics, completion and go-to-definition for relations, symbols, qualities, decks, storylets and scenes, hover for schemas and quality bounds, rename. It is reached two ways: the workbench calls it directly, and a language server exposes it over the Language Server Protocol for external editors, together with a syntax-highlighting grammar. **Implemented (A5):** `services/lang.d`, `varis lsp`, `editors/`; the workbench's problems list uses it; its editor uses vendored CodeMirror 6 with syntax highlighting and inline diagnostics. The editor now shares static completion, definitions, hover and rename with LSP, including unsaved buffers; command-window completion reads live state. |
| 33 | **Writer workflow.** A text-mode playtest host with seeds and replay, "why is this storylet not showing?" built on `narrative.explain`, an author-test format generalizing `sample-game/tools/check.lua`, a CI recipe for checking contractor submissions, and optionally a formatter. **Implemented (A6):** `varis play`, `varis test`, `tools/project_ci.sh`; no formatter. |
| 42 | **Workbench server.** `varis serve <project>`: the Varis executable hosts the project's state and serves a web application and a message protocol on the local machine. Commands typed in the browser run in the live state. No WebAssembly: the engine runs natively and the browser is only the user interface (D13). **First version done (October 11, 2026)**: command window, workspace with relation tables, story panel, plain editor, over request/response HTTP; see WORKBENCH_PLAN §1a. **WebSocket transport added October 13, 2026**: `/ws`, the same handlers, pushed `hello`, `stopped`, `output`, `workspaceChanged`, `fileChanged` and `publishDiagnostics` events; the protocol scope of 42 is complete. |
| 43 | **Workbench user interface.** Command window on the left, editor on the right, workspace browser, a story panel that plays the game as text, a problems list (D10). The workspace shows variables and also what Varis has that MATLAB does not: worlds and their relations as tables, qualities, the session's turn, decks and history. **UI delivered (October 12, 2026):** vendored CodeMirror with inline diagnostics and breakpoint gutters, retained drafts and undo, shared source services, resizable panels, persistent command history and browser coverage of fix/Run/replay. Scene-beat playtesting (play, advance, stage and locals, replay) is in the story panel; see WORKBENCH_PLAN §1a. |
| 44 | **Debugging at the level of the source and the story** (D11). Story level: step one turn, rewind by replay, show what the last turn changed, explain why a storylet or choice is or is not available. Source level: breakpoints on lines, pause, step over/into/out, the call stack, locals in the workspace, evaluating an expression in a paused frame. Built on the instrumented executor of stage S1; the fast executor carries no debugging cost. **First version done (October 11, 2026):** story level (what a turn changed, why a storylet shows or not) and source level (line breakpoints, stop with frames alive, stack, locals, step over/into/out, continue) for code started from the command window or Run; Expanded October 12, 2026: story-panel effect breakpoints with tentative-state inspection, selectable frames and read-only frame expressions; manifest-backed seeded Start, Reload, Rewind and command history. Asynchronous Pause and Stop added October 12, 2026 (an accept thread sets the executor's interrupt and line-hook flags). **Error stops added October 13, 2026** (`LuaState.errorStopHook`, called in the raising frame before unwinding; `/api/breakonerror`). **Done October 13, 2026:** the fast and instrumented loops of stage S1 landed (milestone 45), so the debugger's line hook runs on the instrumented loop, the fast loop carries no debugging code, and a program is back on the fast loop when no breakpoint, step, pause or hook is pending (`"instrumented"` in `/api/breakpoints`, checked by the protocol test). Every listed feature exists; see WORKBENCH_PLAN §1a for what is deliberately not built (a per-function breakpoint table, writing locals). |

### Phase 11 — Fast runtime and host interface

Goal: the Lua core is at least as fast as C Lua, and a game of realistic size runs comfortably
under a graphical front end on a low-end machine. The staged plan, with the measurements behind
it, is [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md). None of it depends on the
Phase 9 syntax.

| Milestone | Deliverable | Plan stages |
| --- | --- | --- |
| 34 | **Safety net, reference game, budgets.** `sample-game/` in the test tiers with a golden transcript and golden save bytes (D12). A synthetic reference game at realistic scale (about 100 rooms, 1000 storylets, thousands of facts, a recursive rule and an aggregate) as a benchmark group with enforced budgets in `benchmarks/targets.toml` for turn latency, content load time, peak memory and save time. Provisional low-end budgets: a turn (choose → effects → actions → next presentation) within 50 ms, no engine work on the render path between turns, content load under 1 s, `save()` under 50 ms, peak engine memory under 64 MB. Measured on an Apple M1 before the work started: a 100-room game with one recursive rule took about 0.8 s per presentation and 171 MB. **Done (October 11, 2026)**; **completed October 13, 2026:** the benchmark is the full reference game (recursive rule, aggregate, 500 turns) and checks each measure against its stand-in budget (turn p95 1.0 ms of 5, load 54–65 ms of 100, save 2.5 ms of 5, 49.8 MB of 64, no collection inside a turn); engine counters are `logic.counters()`. `save()` was 27 ms before this work. The stand-in budgets still rest on the assumed ten-times-slower low-end machine (open decision 3). | S0 |
| 45 | **The seam.** The Lua core no longer knows about worlds, transactions or narrative: no core module imports `varis.logic` or `varis.narrative`, plain Lua calls do no world bookkeeping, and one executor source generates the fast and the instrumented executors. No behaviour change; saves and fingerprints stay byte-identical. **Boundary done (October 11, 2026)** and enforced by `make check-sources`; 40 of 43 opcode handlers are shared between the two executors. **Completed October 13, 2026:** Lua-to-Lua calls do no world work (the call world is set where a native is called, which is the manual's lexical rule); a jump out of a `transaction` block goes through an execution-only `ExitTransaction` instruction, so an open transaction costs nothing per instruction; each executor has a fast loop without any hook, budget, collection or interrupt code and an instrumented loop, generated from one text and switched at safepoints; slow mode ends when no hook, analysis or debugger request needs it. Measured: `core.numeric_loop` 1.40× → 1.16×, `core.array_access` 1.50× → 1.17×, `core.fib` 2.24× → 1.93×, `programs.mandel` 1.76× → 1.43×; golden transcript and save unchanged. `Call`, `TailCall` and `Return` stay written per executor: they are the difference between the two, and L1 decides by measurement whether one of the executors goes. | S1 |
| 35 | **World-model engine.** Shared immutable fact storage instead of copying per query, rule bodies and queries compiled once to slot-based plans with indexes, semi-naive evaluation of recursive strata, derived relations cached per world version, storylets indexed by the constant parts of their conditions. The original evaluator stays as a test oracle. **Done (October 11, 2026):** 0.3 ms per presentation and 53 MB on the reference-scale game, including storylet indexing by a required fact; real low-end hardware is still unmeasured. | W1–W5 |
| 46 | **Lua core to parity with C Lua.** Errors as values (D7), a 16-byte value with string objects, a compact private execution encoding lowered from the canonical bytecode, a slimmer call path. Exit: every C-Lua-comparable core workload at or below 1.0×, including `core.pcall_error` and `core.deep_recursion`. **In progress:** errors are returned between Lua frames and the value is 16 bytes (`std.sumtype` gone, October 13, 2026); core workloads are at 0.5–2.3×; the call path is held by the owner's decisions of October 12. **October 13, 2026:** the owner reopened L4; measured ceilings and a per-workload account closed it (PERFORMANCE_PLAN §L4 exit account); L3 step 1 (fused compare-and-jump) landed. **After stage S1's fast loop (same day):** core workloads are at 0.15–2.1×; L3's exit (`numeric_loop`, `array_access`, `sieve` at or below 1.2×) is met at 1.16×, 1.17× and 1.06× without the compact encoding; the L4 account was refreshed. **Still not complete:** L1's exit ("no `throw` in core modules") is unmet and its remainder is recorded as deferred, and calls are at 1.7–2.1× (about 33 ns against 17 ns), which needs a lean frame that depends on L1. Both need the owner's go-ahead (PERFORMANCE_PLAN §5a). **L1 remainder started (owner decision, October 13, 2026):** natives can report errors as values (`raise`, `state.raisedError`), the executor and `pcall` take them without a throw, and `lib/math.d` is the first converted module; an argument error raised in Lua code costs 0.45 µs instead of 16.5 µs. About 400 throw sites in the other core modules remain. | L1–L4 |
| 47 | **Lua core beyond C Lua.** Inline caches for field, method and global access, type-specialized and fused instructions, compiler passes on the typed AST, a second attempt at profile-guided builds. A just-in-time compiler is not planned. | X1–X4 |
| 36 | **Host interface and standard presentation layer.** A documented D embedding API: create a state, load content, run session commands, receive presentations and beats as typed D values (§4.11). Errors cross the host boundary as return values (D7), with an optional throwing wrapper. On top of it, a standard SDL3 presentation layer that implements the stage of milestone 29 (text box, portraits, sprites in slots, transitions, screen effects, audio channels, history log, skip and auto modes), so a game supplies a skin and an asset manifest rather than a renderer. Text layout there must handle scripts written without spaces and per-language fonts (localization plan §5). Starts with a spike on SDL3 bindings and text rendering from D. **Initial scene player implemented (October 12, 2026, owner-requested):** optional `varis-sdl`, status-returning scene host, asset manifest, backgrounds, expression/outfit sprites in slots, portraits, dialogue/menu/input, audio channels, quicksave/load, recent history, skip/auto and basic fade. See [docs/presentation.md](docs/presentation.md); complete presentation parity and advanced typography remain planned. **October 13, 2026:** the D embedding contract (`GameHost`, `SceneHost`: statuses, inert reads, saves, undo, profile, language, battles) is documented in [docs/embedding.md](docs/embedding.md) and pinned by the `embeddingContract` unit test; a versioned package or C ABI is not built. | |
| 37 | **Portability and footprint.** **Partial (October 13, 2026):** the host "idle now" call (`session:idle()`, `GameHost.idle()`, used by the SDL player) and the footprint measurements and POSIX audit in PERFORMANCE_PLAN stage M; no Windows or Linux build was attempted or verified. Original scope follows. Builds for Windows, macOS and Linux, then an Android build through SDL3 if practical; development and all measurements so far are on macOS arm64, and several modules import `core.sys.posix` (`gc.d` uses `fork` for reachability probes, `package_lib.d` uses `dlopen`). Bounded collector pauses and heap, start-up time, binary size. Frozen Lua features that block portability are removed here. | M |

Exit: the reference game meets its budgets on the reference machine under the reference host, and
`make bench` reports no core workload behind its `goal.clua`.

### Phase 12 — Ergonomics and production features

| Milestone | Deliverable |
| --- | --- |
| 38 | Undo/rollback at turn and beat granularity (§2, §3.4); persistent cross-save data (§3.5); save slots and metadata (§4.8). **Implemented October 13, 2026:** `session:set_undo_limit(n)`, `undo_depth()` and `undo()` restore the last choice or beat advance in place (facts shared copy-on-write, session data, scene position; the undone command's presentation comes back with usable tokens; not saved; off by default), with `GameHost.back`/`SceneHost.back` and the SDL player's B key; `narrative.profile_*`, a host-owned cross-save store outside saves, fingerprints and replay (reads refused in effects, effect writes applied after commit); `session:save{label=, meta=}` and `narrative.save_info`. Also `session:set_autosave` (a callback with the save text after every committed command), `narrative.save_slot` / `list_slots` / `load_slot` / `delete_slot`, and profile storage in the SDL player (`profile.json`). Manual section 6.9a. |
| 39 | Localization pipeline per [NARRATIVE_LOCALIZATION_PLAN.md](NARRATIVE_LOCALIZATION_PLAN.md): catalogs, the publisher handoff kit, loadable translation packs, per-language text features for Chinese, Japanese, Korean, French and Russian. Built on the line ids of milestone 29 and the decisions frozen in milestone 27. Its stage T1 (extraction and the source catalog) needs neither and starts once the project index of milestone 30 exists. **Status (October 12, 2026):** T1–T4 are implemented (T2, the wording split and the plural/select/named-variant syntax, were approved by the owner on October 12, 2026); scene line ids, catalog extraction and translated line rendering are implemented in the first milestone 29 slice. Menu labels and scene character metadata still render authored text. T5 has engine text helpers and character-set output and (October 13, 2026) per-language `font`/`heading_font` in the SDL manifest; complete CJK layout and ruby drawing remain unfinished; see the plan's status note. |
| 40 | Twine-class conveniences (**disabled choices with reasons done October 12, 2026**: `require … because`). **Done October 13, 2026:** `session:visited` / `last_chosen` (and `narrative.visited` / `last_chosen` in effects), derived from data a save already carries; `narrative.meta` pass-through metadata on storylets and choices, outside the content identity; `narrative.spans` and `narrative.escape_markup` for a portable rich-text markup; `default`, `min_length`/`max_length` and `min`/`max` on scene `input` beats. Also `var name = v` with `{$name}` (sugar over the keyed relation `var`), `narrative.fragment` with `{>name}`, `{#if lua …}` read-only conditions, and `[[text->choice]]` passage links: validated against the storylet's choices at seal, delivered as `links` with each choice's token, and drawn inline from `narrative.spans`. Manual section 6.6a. |
| 41 | Writer documentation: a tutorial and cookbook for content authors, separate from the reference manual. **Done October 13, 2026:** [docs/writers/](docs/writers/README.md) (guide, eight-step tutorial, fifteen-recipe cookbook). Every program in it is run by suite `writers-docs` (`tests/writers/test_docs.py`: scratch project, `varis check`, `varis test`, play transcripts), so the pages cannot drift from the engine. Scope complete; translated guides are a localization-plan matter, not part of this milestone. |

### Phase 13 — Tower-defense battle (proposed, October 12, 2026)

Goal: the battle half of the tower-defense / visual-novel hybrid: a native D, fixed-step integer
simulation on a hex map (about 15–20 ns per live enemy per step, against about 3 µs for the same
step in relations), a 2.5D pointy-top zoomable battle view in the SDL3 player, and a narrow bridge
to the story engine: relationships and story state become a battle setup through rules, story
moments interrupt a battle as ordinary scenes, and the outcome returns through one transaction.
There is no saving during a battle; abandoning restores the snapshot taken at its start. The
design, measurements, decisions (owner, October 12, 2026) and stages TD0–TD8 are in
[TOWER_DEFENSE_PLAN.md](TOWER_DEFENSE_PLAN.md); the fifteen-minute sample that tests all of it
(*Lanternfall*, `sample-td/`) is in [SAMPLE_TD_PLAN.md](SAMPLE_TD_PLAN.md). **Status, October 12,
2026: implemented as a first complete slice** (native simulation with all ten ability primitives,
the bridge in `GameHost`, the SDL battle view, the four-night sample with French pack and tests);
the remaining TD0/TD5 items (budget entries, render caches at the largest map) and the cuts listed in
`sample-td/README.md` are open. It needs none of the
Lua-core stages and does not block them. These milestone numbers are proposed identifiers, not an
order:

| Milestone | Deliverable | Plan stages |
| --- | --- | --- |
| 48 | **Done October 13, 2026.** **Native battle and bridge.** `source/varis/game/` (hex, terrain from seed plus edits, fog, routing, kinds, the simulation, digest), `varis battle`, and the bridge in `services/battlehost.d`: setup, moments as scenes, sync, result, abandon by snapshot. | TD0–TD3 |
| 49 | **Done October 13, 2026** (the large-map overview texture, shared minimap and per-band frame times at 435,600 tiles included). **Battle view.** SDL bridge primitives (geometry, points, render targets, buttons and drag), the 2.5D pointy-top view with camera, picking, zoom bands and fog, HUD, moment overlay. | TD4–TD5 |
| 50 | **Done October 13, 2026** (`td_native` benchmark group with the §9 budgets; the sample plays at 435,600 tiles). **Tower-defense game.** Hub ↔ battle, weekly cadence with silent judging, economy, fog growth, heroes and relationships, content depth, 435,600-tile scale and budgets. | TD6–TD8 |

## Open decisions (owner)

Until one of these is decided, use the stated default and say so in the change. The
tower-defense plan's own open decisions (hex orientation, simulation rate, lanes or corridors,
what judging reports, the game-support layer) are in [TOWER_DEFENSE_PLAN.md](TOWER_DEFENSE_PLAN.md) §10.

| # | Question | Default until decided |
| --- | --- | --- |
| 1 | The exact content-tier restrictions. | Decided October 13, 2026; see "Language tiers" and the Phase 9 decisions below. Implemented (milestone 26): static checks and load-time enforcement. |
| 2 | The source file extension and language name shown in editors. | Decided October 13, 2026: `.varis`, editor language "Varis"; retain `.lua` loading compatibility. Implemented (milestone 26); samples still use `.lua` and migrate separately. |
| 3 | The reference low-end machine and the budget numbers in milestone 34. | The provisional budgets; an M1 performance core is assumed ten times faster than the low-end machine. |
| 4 | Which frozen Lua features are removed outright, and when. | Remove none; keep them passing on the instrumented executor. |
| 5 | How mods are packaged, loaded and recorded in saves (the localization plan only reserves room: packages with a declared source language and package-qualified keys). | Not designed; do not build on assumptions about it. |
| 6 | Whether script mods get the unrestricted standard library (`io`, `os`, `package`) or a sandboxed set. | Unrestricted, as today. |
| 7 | The order of the world-model track and the Lua-core track (D14). | World model first. |
| 8 | Whether the public D host API returns statuses only or also offers a throwing wrapper. | Status returns, with an optional thin throwing wrapper. |
| 9 | Workbench choices: the editor component, whether the server uses a third-party HTTP library, and the exact panel layout. | See [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md) §9. |
| 10 | A target below 1.0× C Lua for milestone 47. | None until parity is reached and measured. |

### Phase 9 decisions — October 13, 2026

Approved by the owner; these are implementation targets, not current language semantics.

- **File identity:** `.varis` for new content and engine scripts, editor language name
  **Varis**. The project manifest determines the tier; the extension identifies the language.
  Keep loading existing `.lua` files. Migrate samples separately.
- **Content tier:** use the restrictions under "Language tiers" above, including explicitly
  exposed named helpers and compiler/load-time enforcement through a restricted environment.
  Engine scripts retain the full language. Writers do not define function values or classify
  captures as safe/unsafe.
- **Declared symbols:** contextual source declaration `symbols player, keeper, lamp_room,
  resolve`; references keep `:keeper` spelling. Declarations are project-wide and
  order-independent and introduce ordinary symbols, not a new entity type. Manifest symbol
  declarations remain supported. Unknown symbols are errors in content; engine scripts retain
  dynamic symbol creation. Named definitions declare their corresponding symbol where
  applicable (for example characters and decks), avoiding duplicate declarations.
- **Computed bindings:** `?name := expression` binds a new variable from grounded inputs.
  Positive relation joins run first, then bindings and aggregates in written order, then
  filters. Expressions follow guard purity and no-yield rules. For v1, computed bindings
  are rejected in recursive rule cycles so they cannot generate an unbounded domain;
  ordinary relational recursion remains supported.
- **Disjunction:** allow parenthesized `or` alternatives in grounded filters, with
  left-to-right short-circuit evaluation. Defer branching relation bodies that introduce
  bindings; separate rules remain the v1 way to express those alternatives.
- **Query conveniences:** `exists { goals }` returns a Boolean without exporting bindings.
  `logic.one(query ...)` returns the sole binding record, nil for no match, and an error
  for multiple matches. Defer `first` because query results are unordered.
- **Exposed bindings:** `expose ?name` makes a matched value available to templates and
  effects without adding it to instance identity or cooldown/history keys. For each
  instance, require exactly one distinct exposed value across matching bindings; repeated
  equal values are allowed, ambiguity is an author-facing error. Choosing revalidates
  exposed bindings against the current world.
- **Effect period changes:** `narrative.set_period(:period, value)` targets the executing
  session in an effect or handler; elsewhere it errors. Changes are transaction-aware,
  visible immediately within the effect, discarded on rollback, and visible to subsequent
  actions after commit. Setting a period neither advances the turn nor starts a nested action
  phase. Keep `session:set_period` for hosts.
- **Explicit clamping:** `adjust quality(...) by delta clamp` and
  `quality.add(entity, name, delta, {clamp = true})` saturate at declared quality bounds.
  An absent bound leaves that side unrestricted; an absent value still errors. Ordinary
  adjustment retains its bounds errors. For v1, reject `clamp` on relations without supported
  quality bounds. `quality.metadata(:name)` exposes read-only metadata.
- **Deck navigation:** `leads :deck` belongs to a choice and pushes the destination after
  its authored effect, in the same transaction; a failed effect does not navigate.
  `narrative.return_deck()` pops, with an error at the root. Ordinary Lua `return` is unchanged
  and existing push/pop APIs remain available to engine scripts. Reject a choice combining
  `leads` with explicit deck navigation in its effect, preventing double navigation.
- **Narration delivery:** keep `narrative.emit(:say, text)`; add ordered
  `session:events_since(sequence)` and presentation `events` containing events committed
  since the previous successful presentation. Stable sequence numbers permit host
  deduplication. Failed effects emit nothing; save/load preserves the presentation event
  cursor; re-rendering an existing presentation consumes nothing. Defer action `text` syntax.
- **Handler/callback world context:** unqualified relations and `quality.*` in session
  handlers and deferred callbacks default to the originating session world. Explicit worlds
  and helpers deliberately capturing another world retain their meaning. Handlers remain
  transactional. Deferred callbacks run after commit, cannot undo it on failure, do not retry
  automatically, and gain no permission to use effect-only operations. Gameplay changes belong
  in effects or scheduled handlers; deferred callbacks serve host notifications/external work.
- **Terminal sessions:** `narrative.finish(:ending)` records an ending transactionally.
  The current effect finishes normally; commit stops subsequent automatic actions and
  scheduled-event delivery, but already committed notifications still run. `session:ended()`
  returns the ending symbol or nil. Terminal `present()` returns the ending and final pending
  narration without choices; choose/advance error. Save/load preserves the ending and undo
  may restore the preceding nonterminal state. Repeating the same ending is harmless;
  conflicting endings in one transaction error. Cross-save achievements remain profile data.
- **Readable scenes:** add writer-facing statements over the existing serializable scene
  model, with explicit effect blocks, scalar locals, conditionals, menus, jump/call/return
  and media directives. Keep beat records as a lower-level engine-script interface. Defer
  arbitrary Lua loops and function definitions in scenes. Effects between presentation
  boundaries commit together; failure restores position, locals, stage and world. No
  coroutine implementation. The approved illustrative syntax uses `scene greeting()`,
  `show mira at :left`, `say mira id greeting_hello "Welcome back."`, and `effect do ... end`;
  complete grammar remains implementation work.
- **Stable text identity:** content scenes require explicit authored ids for dialogue,
  narration, menu options and input prompts. Short ids are scene-scoped. Editors may generate
  them once and preserve them across moves; missing ids are content errors. Position-generated
  ids remain for legacy/engine-created scenes. Menu labels and character display names must
  participate in localization before the authoring syntax is frozen.
- **V1 scope:** require the authoring contract stated at the Phase 9 exit above. Retain the
  RPG Maker/Ren'Py/Twine comparison checklist, but finish advanced rendering under milestone 36.
  Defer compound relation values/destructuring, a separate `passage` kind, general mixed
  scene/storylet beat streams, timed-choice syntax and parser-style text commands. Existing
  implemented conveniences remain supported.
- **Nested relational subqueries:** defer correlated nested `exists { ... }` and
  `not { ... }` goals. The approved Boolean `exists` expression remains in v1; auxiliary
  relations and existing stratified negation express relational alternatives.
- **Choice-by-name:** retain selection by name in author-test tools; defer public
  `session:choose_by`. Gameplay hosts select exact presentation tokens, preserving instance
  identity and availability checks.
- **HUD/template additions:** defer `session:status()` and arbitrary Lua expressions in
  template conditions. Hosts use qualities and the approved metadata accessor; authors use
  named relations in template conditions. Preserve implemented rich text, links, variables,
  fragments, history, profile and save-slot facilities. Click-to-replace prose is host-level
  work outside the v1 language contract.

The high-level Phase 9 decision pass is complete. The proposal inventory records the
disposition of each topic; full grammar, implementation, tests, sample migration and the
documented syntax freeze remain work. Approval of these targets does not complete Phase 9.

**Status, October 13, 2026:** milestones 26, 27, 28 and 29 are done (see their rows), which
completes Phase 9: readable scenes with explicit text ids and input statements, *Saltmarsh
Light* migrated off its workarounds, `sample-vn` in `.varis`. Menu option labels are catalog text
(`scene.<label id>.label`), character names were already (`character.<id>.name`), and all
three samples keep content in `.varis` with their French packs rebuilt.

Decided October 12, 2026 (owner, asked while planning the executor work):

- **Stack limits may be approximate.** Done: small frames are charged a flat amount (see
  `docs/compatibility.md` §9.1). Measured gain on `core.fib`: within noise; `regression.limits`
  went to 0.83× C Lua.
- **Call records and register clearing stay exact.** The owner did not choose lazy call records
  or weaker dead-register clearing, so tracebacks, `debug.getinfo` and the weak-table and
  finalizer emulation keep their current behaviour and cost. With both kept, the measurements in
  the performance plan put the reachable call speed at roughly 1.5–2× C Lua, not parity.
- **Coroutines without fibers must keep "yield from Lua and across `pcall`".** Yielding inside
  `table.sort` comparators, `gsub` callbacks and similar natives may remain an error (it already
  is for sort and gsub). This is the specification for replacing `core.thread.Fiber`; it is not
  implemented.

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
