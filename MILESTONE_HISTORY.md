# Varis milestone history

Archived from the roadmap on October 13, 2026. This file preserves the original
scope, milestone identifiers, implementation notes and dated measurements. It is
**not a work queue**: later notes supersede earlier status statements. Current
work is in [ROADMAP.md](ROADMAP.md#remaining-work), current semantics in the
[manual](docs/README.md), and recorded test/benchmark results in [docs/STATUS.md](docs/STATUS.md).

## Completion index

| Milestones / phases | Disposition | Evidence / detailed record |
| --- | --- | --- |
| Phases 1–7; milestones 0–18 | Implemented Lua foundation, relations and narrative runtime | [Extension history](LANGUAGE_EXTENSIONS_PLAN.md), [coverage](docs/coverage.md), [narrative tests](tests/narrative/README.md) |
| Phase 8; 19–20 | Benchmark gates and official-suite regression gate delivered | [Closure](#closed-phase-8--core-lua-performance-and-conformance) |
| 21–25 | Retired, **not completed**; replaced by the stricter runtime plan | [Performance history](benchmarks/PERFORMANCE_WORK.md) |
| Phase 9; 26–29 | V1 tiers, symbols, conveniences, readable scenes and syntax freeze delivered | [Syntax](docs/syntax.md#105--status-of-the-syntax-milestone-27), suites `tiers`, `extensions`, `sample-game` |
| Phase 10; 30–33, 42–44 | Authoring A0–A6 and workbench/server/debugger delivered | [Authoring tools](AUTHORING_TOOLS_PLAN.md), [workbench acceptance](WORKBENCH_PLAN.md#1a-what-exists-today) |
| 34, 35, 45 | Safety net, world-model budget work and seam delivered; real hardware validation remains in 37 | [Performance plan](benchmarks/PERFORMANCE_PLAN.md), `logic-oracle`, `narrative_scale` benchmarks |
| 38, 40, 41 | Undo/profile/saves, conveniences and writer guide delivered | [Narrative manual](docs/narrative.md), [writer guide](docs/writers/README.md) |
| Phase 13; 48–50 | Battle, bridge, view and sample delivered with documented substitutions and cuts | [Battle manual](docs/battle.md), [battle design](TOWER_DEFENSE_PLAN.md), [sample](sample-td/README.md) |
| Sample RPG S0–S7; sample TD SA–SH | Implemented samples; draft translations and placeholder assets remain production work | [RPG as built](SAMPLE_RPG_PLAN.md#9-as-built-october-12-2026), [TD as built](sample-td/README.md#as-built-against-the-plan) |

Milestones 36, 37, 39, 46 and 47 remain open. Their original scope appears below
for traceability; use the roadmap for the remaining deliverables. Completion of a
stage does not imply every original implementation technique was used: L2 retained
string slices, L3 met its measured exit without a compact encoding, and the battle
view uses an overview texture instead of the proposed chunk-cache design. Historical
performance measurements do not establish current parity or cross-platform support.

## Documentation audit evidence — October 13, 2026

Status corrections were checked against the frontend/tier loader, scene index and
renderer, both host adapters, workbench protocol, native error channel, battle
budgets and their fixtures. `make test` passed with 322 passes, 3 known gaps,
1 partial and 1 skip. This is the full test tier; the generated status records a
separate release-tier run. No benchmark, platform or SDL visual measurement was
rerun for this documentation-only change; dated results retain their original scope.

## Original milestone scope and dated delivery notes

The following is the pre-cleanup roadmap record. Descriptions such as "planned",
"needs approval" and "remaining" refer to the date of the surrounding entry, not
the current backlog. In particular, L1 was subsequently authorized and started,
menu labels were localized, and the large-map battle budgets landed.


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
improvements and sample migration. See the [October 13 Phase 9 decisions](ROADMAP.md#phase-9-decisions--october-13-2026).

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
| 42 | **Workbench server.** `varis serve <project>`: the Varis executable hosts the project's state and serves a web application and a message protocol on the local machine. Commands typed in the browser run in the live state. No WebAssembly: the engine runs natively and the browser is only the user interface (D13). **First version done (October 11, 2026)**: command window, workspace with relation tables, story panel, plain editor, over request/response HTTP; see WORKBENCH_PLAN §1a. **WebSocket transport added October 13, 2026**: `/ws`, the same handlers, pushed `hello`, `stopped`, `output`, `workspaceChanged`, `fileChanged` and `publishDiagnostics` events; the browser page connects to `/ws` for requests and live event updates; milestone 42 is complete. |
| 43 | **Workbench user interface.** Command window on the left, editor on the right, workspace browser, a story panel that plays the game as text, a problems list (D10). The workspace shows variables and also what Varis has that MATLAB does not: worlds and their relations as tables, qualities, the session's turn, decks and history. **UI delivered (October 12, 2026):** vendored CodeMirror with inline diagnostics and breakpoint gutters, retained drafts and undo, shared source services, resizable panels, persistent command history and browser coverage of fix/Run/replay. Scene-beat playtesting (play, advance, stage and locals, replay) is in the story panel; see WORKBENCH_PLAN §1a. |
| 44 | **Debugging at the level of the source and the story** (D11). Story level: step one turn, rewind by replay, show what the last turn changed, explain why a storylet or choice is or is not available. Source level: breakpoints on lines, pause, step over/into/out, the call stack, locals in the workspace, evaluating an expression in a paused frame. Built on the instrumented executor of stage S1; the fast executor carries no debugging cost. **First version done (October 11, 2026):** story level (what a turn changed, why a storylet shows or not) and source level (line breakpoints, stop with frames alive, stack, locals, step over/into/out, continue) for code started from the command window or Run; Expanded October 12, 2026: story-panel effect breakpoints with tentative-state inspection, selectable frames and read-only frame expressions; manifest-backed seeded Start, Reload, Rewind and command history. Asynchronous Pause and Stop added October 12, 2026 (an accept thread sets the executor's interrupt and line-hook flags). **Error stops added October 13, 2026** (`LuaState.errorStopHook`, called in the raising frame before unwinding; `/api/breakonerror`). **Done October 13, 2026:** the fast and instrumented loops of stage S1 landed (milestone 45), so the debugger's line hook runs on the instrumented loop, the fast loop carries no debugging code, and a program is back on the fast loop when no breakpoint, step, pause or hook is pending (`"instrumented"` in `/api/breakpoints`, checked by the protocol test). Every listed feature exists; see WORKBENCH_PLAN §1a for what is deliberately not built (a per-function breakpoint table, writing locals). |

### Phase 11 — Fast runtime and host interface

Goal: the Lua core is at least as fast as C Lua, and a game of realistic size runs comfortably
under a graphical front end on a low-end machine. The staged plan, with the measurements behind
it, is [benchmarks/PERFORMANCE_PLAN.md](benchmarks/PERFORMANCE_PLAN.md). None of it depends on the
Phase 9 syntax.

| Milestone | Deliverable | Plan stages |
| --- | --- | --- |
| 34 | **Safety net, reference game, budgets.** `sample-game/` in the test tiers with a golden transcript and golden save bytes (D12). A synthetic reference game at realistic scale (about 100 rooms, 1000 storylets, thousands of facts, a recursive rule and an aggregate) as a benchmark group with enforced budgets in `benchmarks/targets.toml` for turn latency, content load time, peak memory and save time. Provisional low-end budgets: a turn (choose → effects → actions → next presentation) within 50 ms, no engine work on the render path between turns, content load under 1 s, `save()` under 50 ms, peak engine memory under 64 MB. Measured on an Apple M1 before the work started: a 100-room game with one recursive rule took about 0.8 s per presentation and 171 MB. **Done (October 11, 2026)**; **completed October 13, 2026:** the benchmark is the full reference game (recursive rule, aggregate, 500 turns) and checks each measure against its stand-in budget (turn p95 1.0 ms of 5, load 54–65 ms of 100, save 2.5 ms of 5, 49.8 MB of 64, no collection inside a turn); engine counters are `logic.counters()`. `save()` was 27 ms before this work. The stand-in budgets still rest on the assumed ten-times-slower low-end machine ([roadmap open decision 3](ROADMAP.md#open-decisions-owner)). | S0 |
| 45 | **The seam.** The Lua core no longer knows about worlds, transactions or narrative: no core module imports `varis.logic` or `varis.narrative`, plain Lua calls do no world bookkeeping, and one executor source generates the fast and the instrumented executors. No behaviour change; saves and fingerprints stay byte-identical. **Boundary done (October 11, 2026)** and enforced by `make check-sources`; 40 of 43 opcode handlers are shared between the two executors. **Completed October 13, 2026:** Lua-to-Lua calls do no world work (the call world is set where a native is called, which is the manual's lexical rule); a jump out of a `transaction` block goes through an execution-only `ExitTransaction` instruction, so an open transaction costs nothing per instruction; each executor has a fast loop without any hook, budget, collection or interrupt code and an instrumented loop, generated from one text and switched at safepoints; slow mode ends when no hook, analysis or debugger request needs it. Measured: `core.numeric_loop` 1.40× → 1.16×, `core.array_access` 1.50× → 1.17×, `core.fib` 2.24× → 1.93×, `programs.mandel` 1.76× → 1.43×; golden transcript and save unchanged. `Call`, `TailCall` and `Return` stay written per executor: they are the difference between the two, and L1 decides by measurement whether one of the executors goes. | S1 |
| 35 | **World-model engine.** Shared immutable fact storage instead of copying per query, rule bodies and queries compiled once to slot-based plans with indexes, semi-naive evaluation of recursive strata, derived relations cached per world version, storylets indexed by the constant parts of their conditions. The original evaluator stays as a test oracle. **Done (October 11, 2026):** 0.3 ms per presentation and 53 MB on the reference-scale game, including storylet indexing by a required fact; real low-end hardware is still unmeasured. | W1–W5 |
| 46 | **Lua core to parity with C Lua.** Errors as values (D7), a 16-byte value with string objects, a compact private execution encoding lowered from the canonical bytecode, a slimmer call path. Exit: every C-Lua-comparable core workload at or below 1.0×, including `core.pcall_error` and `core.deep_recursion`. **In progress:** errors are returned between Lua frames and the value is 16 bytes (`std.sumtype` gone, October 13, 2026); core workloads are at 0.5–2.3×; the call path is held by the owner's decisions of October 12. **October 13, 2026:** the owner reopened L4; measured ceilings and a per-workload account closed it ([performance history: L4 exit account](benchmarks/PERFORMANCE_HISTORY.md#track-l--lua-core-to-parity-milestone-46)); L3 step 1 (fused compare-and-jump) landed. **After stage S1's fast loop (same day):** core workloads are at 0.15–2.1×; L3's exit (`numeric_loop`, `array_access`, `sieve` at or below 1.2×) is met at 1.16×, 1.17× and 1.06× without the compact encoding; the L4 account was refreshed. **Still not complete:** L1's exit ("no `throw` in core modules") is unmet and its remainder is recorded as deferred, and calls are at 1.7–2.1× (about 33 ns against 17 ns), which needs a lean frame that depends on L1. Both need the owner's go-ahead (PERFORMANCE_PLAN §5a). **L1 remainder started (owner decision, October 13, 2026):** natives can report errors as values (`raise`, `state.raisedError`), the executor and `pcall` take them without a throw, and `lib/math.d`, `lib/table.d` and the natives of `lib/base.d` are converted; an argument error raised in Lua code costs 0.45 µs instead of 16.5 µs. **Later the same day:** L1 was completed: the other libraries, the pattern engine, table access, the operators, `forprep`, call checks, `__call`, close handlers, both executors, coroutine bodies and the frontend and loaders (lexer, parser, compiler, binary chunks) report errors as values; `executeFrame` and `executeDeepFrame` no longer throw a Lua error (`VM.execute` is the host adapter). Exit and coroutine-close signals, the debug hook, finalizers, the C API checks and `rawset` also report by value. What throws is the host-adapter layer of open decision 8 (PERFORMANCE_PLAN §5). Calls are still 1.7–2.1× (the lean frame is the next measured step). | L1–L4 |
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
