# Varis roadmap

Status: implementation audit and backlog cleanup, October 13, 2026.
This file lists remaining work; completed milestone detail is in [MILESTONE_HISTORY.md](MILESTONE_HISTORY.md). The [Varis Reference Manual](docs/README.md) remains the
only definition of current language behaviour; [LANGUAGE_EXTENSIONS_PLAN.md](LANGUAGE_EXTENSIONS_PLAN.md)
is the engineering history of phases 6–8.

How to read this file:

- **Direction** says what the product is.
- **Decision record** lists every decision that shapes the work, who made it and why. When two
  documents disagree, the decision record wins; fix the other document.
- **Order of work** says what to do next when nobody has said otherwise.
- **Remaining work** lists open milestones. Completed scope is linked under **Delivered work**.

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
| D7 | Errors travel as values (a status plus an error object stored on the thread), not as D exceptions. | Owner (follows from D6) | `core.pcall_error` is 37× C Lua and the time is all in the platform unwinder. | Milestone 46, stage L1: landed October 13, 2026 (only the host adapters of open decision 8 throw). |
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

## Language tiers (implemented)

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

The split is visible in `sample-game/project.lua`: content declarations are separated
from engine/host scripts (`world.lua`, `game.lua`, `main.lua` and `tools/`). Internally
`effect do … end` and `when { … }` remain compiled closures.

## Order of work

Completed prerequisites are in [MILESTONE_HISTORY.md](MILESTONE_HISTORY.md); do not
restart them. The two lanes remain independent (D14):

1. **Runtime:** L1's error-as-values conversion is done (milestone 46). Now measure the
   remaining call/frame costs and parity gaps. Preserve exact call
   records and register clearing; consult performance plan §5a before changing the
   executor. L2 is done, L3 met its recorded stage exit without compact encoding,
   and L4's measurement account is closed; none of these establishes core parity.
2. **Beyond parity:** X1–X4 (47), using measurements to select changes. Initial caches
   and fast paths already exist. Canonical bytecode and save identity stay unchanged.
3. **Hardware and footprint:** finish stage M (37), including real low-end measurements
   and Windows/Linux builds. S0, S1 and the world-model budget work are already delivered;
   W5(b) remains conditional on a measured need, not a prerequisite to restart.

**Presentation and production lane:** standard presentation (36) and production
localization (39) are delivered. V1 syntax, authoring A0–A6 and workbench milestones
42–44 are delivered. Their optional refinements below are not new blockers for the completed milestones.

## Remaining work

Audited against the source and executable fixtures on October 13, 2026. Numbers are
stable identifiers, not priority ranks. The detailed plans retain design rationale
and dated evidence; this table is the active milestone queue.

| Milestone | What remains | Completion evidence needed |
| --- | --- | --- |
| **46 — Lua core parity** | L1 is done: every language error in the core travels by value, including exit and coroutine close; the throws left are the host adapters of open decision 8. Left: measure the lean-frame / executor design (calls are 1.7–2.1× C Lua) and the remaining call, string and dispatch costs. | Preserve full semantics and gates; every C-Lua-comparable `goal.clua ≤ 1.0`. See [performance plan](benchmarks/PERFORMANCE_PLAN.md#track-l--lua-core-to-parity-milestone-46). |
| **47 — Beyond C Lua** | Remaining method-chain/global caches, specialization/fusion, execution-only optimizations and measured PGO/LTO experiments (toolchain permitting). | Per-change semantic validation and same-session timings; choose a below-parity target only after parity is measured. [Track X](benchmarks/PERFORMANCE_PLAN.md#track-x--lua-core-beyond-c-lua-milestone-47). |
| **37 — Portability and real hardware** | Build/test/package on Windows and Linux; resolve POSIX dependencies; select a real low-end reference machine and verify time, memory and collector-pause budgets. Android remains a stretch goal. | Recorded platform builds and reference-game measurements. Host idle collection and the macOS footprint audit already exist. [Stage M](benchmarks/PERFORMANCE_PLAN.md#stage-m--memory-pauses-the-host-boundary-real-hardware-milestones-36-37). |

### Optional refinements and deferred scope

These remain visible without reopening delivered milestones:

- **Authoring tools:** optional formatter, unified runtime template diagnostics,
  and stricter static checks where dynamic code prevents a complete answer.
  [Authoring limits](AUTHORING_TOOLS_PLAN.md#2-what-exists-today).
- **World model:** W5(b) partial availability caches only if the reference workload
  needs them; retain the naive oracle and existing budget gates.
- **Samples:** replace placeholder art/audio, review French drafts and playtest balance.
  [RPG deviations](SAMPLE_RPG_PLAN.md#9-as-built-october-12-2026) and
  [Lanternfall cuts](sample-td/README.md#as-built-against-the-plan) remain explicit.
- **Deferred language/mod features:** compound relation values, mixed scene/storylet
  streams, timed-choice syntax and mod packaging are not v1 requirements. See the
  [syntax disposition](docs/syntax.md#105--status-of-the-syntax-milestone-27) and open decisions.
- **Battle defaults:** hit-scan, BFS routing and full route rebuilds remain intentional;
  travelling projectiles and weighted/incremental routing require a demonstrated need.
  Cross-machine determinism and real hardware validation belong with milestone 37.

## Delivered work

The completed scope and evidence are indexed in [MILESTONE_HISTORY.md](MILESTONE_HISTORY.md).
Phases 1–7, the v1 language (9), authoring/workbench (10), and the first battle/sample
scope (13) have landed. Phase 8 is closed with 21–25 retired. Phase 11 retains 37,
46 and 47 (milestone 36 delivered); Phase 12 is completed (38, 39, 40, 41 delivered).
Preserve their regression coverage while doing the work above.

## Open decisions (owner)

Resolved choices 1 (content tiers) and 2 (file identity) are recorded below; their
identifiers are retained in history. For unresolved choices, use the stated default
and say so in the change. The
tower-defense plan's own open decisions (hex orientation, simulation rate, lanes or corridors,
what judging reports, the game-support layer) are in [TOWER_DEFENSE_PLAN.md](TOWER_DEFENSE_PLAN.md) §12.

| # | Question | Default until decided |
| --- | --- | --- |
| 3 | The reference low-end machine and the budget numbers in milestone 34. | The provisional budgets; an M1 performance core is assumed ten times faster than the low-end machine. |
| 4 | Which frozen Lua features are removed outright, and when. | Remove none; keep them passing on the instrumented executor. |
| 5 | How mods are packaged, loaded and recorded in saves (the localization plan only reserves room: packages with a declared source language and package-qualified keys). | Not designed; do not build on assumptions about it. |
| 6 | Whether script mods get the unrestricted standard library (`io`, `os`, `package`) or a sandboxed set. | Unrestricted, as today. |
| 7 | The order of the world-model track and the Lua-core track (D14). | World model first. |
| 8 | Whether the public D host API returns statuses only or also offers a throwing wrapper. | Status returns, with an optional thin throwing wrapper. |
| 9 | Workbench choices: the editor component, whether the server uses a third-party HTTP library, and the exact panel layout. | See [WORKBENCH_PLAN.md](WORKBENCH_PLAN.md) §9. |
| 10 | A target below 1.0× C Lua for milestone 47. | None until parity is reached and measured. |

### Phase 9 decisions — October 13, 2026

Approved by the owner and implemented in milestones 26–29, except the explicitly
deferred items. The manual defines the resulting syntax and semantics; this record
preserves the rationale.

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
  the implemented forms are in `docs/narrative.md` §6.11a and `docs/syntax.md` §10.5.
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
  template conditions beyond the implemented `{#if lua …}` form. Hosts use qualities and the approved metadata accessor; authors use
  named relations in template conditions. Preserve implemented rich text, links, variables,
  fragments, history, profile and save-slot facilities. Click-to-replace prose is host-level
  work outside the v1 language contract.

**Delivery, October 13, 2026:** milestones 26–29 landed: readable scenes with explicit
text ids and input statements, the syntax freeze, *Saltmarsh Light* migration and
`.varis` content in `sample-vn`, `sample-rpg` and `sample-td`.
*Saltmarsh Light* retains `.lua` filenames. Menu labels are catalog text (`scene.<label id>.label`);
character names are indexed as `character.<id>.name` and translated by `GameHost` and `SceneHost`.
The scene-only host difference was closed under milestone 39.

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

Closed October 11, 2026; milestones 19–20 delivered, 21–25 retired, not completed.
The [closure record](MILESTONE_HISTORY.md#closed-phase-8--core-lua-performance-and-conformance)
preserves the measurements and rationale. Core performance continues under 46–47;
the conformance half stays closed (D3). Existing regression gates remain in force.
