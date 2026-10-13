# Needed extensions

> **Decision status (October 13, 2026):** this inventory is the input to Phase 9 of the
> [roadmap](../ROADMAP.md#phase-9-decisions--october-13-2026). Its owner-approved decision
> record supersedes the original proposals below: accepted targets are not necessarily
> implemented. In particular, `leads` is choice-level, queries use `exists { ... }` and
> `logic.one`, content scene text requires explicit ids, and the v1 scope defers compound
> relation values, passages, mixed beat streams, timed choices and parser-style input.
> High-level inventory triage is complete; the disposition table below controls scope.
> Full grammar, implementation and verification remain prerequisites for the syntax freeze.

This file lists the language and runtime changes that *Saltmarsh Light* (this folder) and Twine- or Ren'Py-style games need, beyond the current [Varis Reference Manual](../docs/README.md). This is a proposal/workaround inventory, not a language specification; entries marked implemented (such as `sticky` and `order`) are defined in the manual. Historical section citations map through [docs/coverage.md](../docs/coverage.md).

The game itself uses only current-spec features. Where it has to work around a gap, the code points here, and [`extensions/proposed.lua`](extensions/proposed.lua) sketches the proposed syntax. Section numbers below (§1.1 and so on) are the ones the code comments cite.

Status of the triage (October 13, 2026, milestone 27): every topic below has a disposition in the
table; the constructs marked **Implemented** have grammar in
[docs/syntax.md](../docs/syntax.md) §10 and semantics in the manual; the scene-body and
input-statement items, and the migration of this game off its workarounds (for example the host
`sync_periods` that `narrative.set_period` now makes unnecessary), are accepted work that is not
yet done, and stay here and in milestone 29 until they land.

Current status (October 12, 2026): declarative scenes, characters, stage state, scene
input/menu beats, format 3 mid-scene saves, scene-line localization and an initial SDL3
player are implemented; see [manual §6.11](../docs/narrative.md#611--scenes-beats-and-stage-state)
and [Harbour Window](../sample-vn/README.md). The current manual also documents beat undo,
profile data and input validation. Writer-facing procedural scene bodies remain planned;
advanced presentation parity is milestone 36 work. `varis test` supplies a choice-by-name
wrapper; a public `session:choose_by` method remains proposed. Localization catalogs,
packs and language switching also exist; see manual §§8.4–8.7.

Priority key: **P0** means the game needs a workaround today. **P1** is needed for Twine/Ren'Py-class games. **P2** is quality of life.

## V1 disposition — owner decisions, October 13, 2026

Accepted means in scope, not implemented. Historical examples and descriptions below remain
motivation; the roadmap decision record controls the final design and the manual controls
current behavior. Existing implemented facilities remain supported without accepting every
alternative API or syntax suggested in the historical inventory.

| Inventory topic | Disposition |
| --- | --- |
| §1.1 Period changes | Accept transaction-aware `narrative.set_period`. **Implemented (milestone 28).** |
| §1.2 Sticky/order and navigation | Retain sticky/order; accept choice-level `leads` and `narrative.return_deck`. **Implemented (milestone 28).** |
| §1.3 Clamping/metadata | Accept explicit quality clamping and read-only metadata. **Implemented (milestone 28):** `adjust … clamp`, `quality.add(…, {clamp = true})`, `quality.metadata`. |
| §1.4 Narration | Accept ordered events and presentation delivery; defer action `text` syntax. **Implemented (milestone 28):** presentation `events`, `session:events_since`. |
| §1.5 Binding/disjunction/subqueries | Accept nonrecursive computed bindings, grounded filter `or`, and Boolean `exists`; defer binding-producing alternatives and correlated nested relational subqueries. **Implemented (milestone 28):** `?x := expr`, `(a or b)`, `exists { … }`. |
| §1.6 Exposed variables | Accept unique exposed values outside instance identity. **Implemented (milestone 28):** `expose ?name`. |
| §1.7 Handler/callback worlds | Accept originating-session defaults with explicit-world preservation. **Implemented (milestone 28).** |
| §1.8 Terminal sessions | Accept transactional finish; cross-save data stays in the profile. **Implemented (milestone 28):** `narrative.finish`, `session:ended`. |
| §1.9 Query/selection conveniences | Accept `exists { ... }` and exact-one `logic.one`; defer unordered first-result selection and public `session:choose_by`; retain author-test selection helpers. **Implemented (milestone 28):** `exists`, `logic.one`. |
| §1.10 Compound values/destructuring | Defer. |
| §1.11 Inference performance | Runtime lane, milestone 35; not new Phase 9 syntax work. |
| §2 Passages/focus mode | Defer a separate passage kind; use scenes and storylet hubs. |
| §2 Links, variables, history, fragments and initialization | Retain implemented facilities; no separate Twine syntax required for v1. |
| §2 Lua expressions in templates | Defer; use named relational conditions. |
| §2 Click-to-replace prose | Host-level, outside v1 language scope. |
| §2 Undo and §3.4 beat rollback | Required; retain implemented undo and verify readable scenes integrate with it. |
| §3.1 Scene control flow/effects | Accept readable scene statements over serializable positions; defer arbitrary Lua loops and function definitions. |
| §3.2 Characters/line identity | Accept explicit scene-scoped text ids in content; retain legacy/generated ids for engine-created scenes. |
| §3.3 Media/stage | Require structured directives and saveable stage; advanced rendering parity belongs to milestone 36. |
| §3.5 Persistent data | Retain implemented host-owned profile facilities. |
| §3.6 Timed choices | Defer new timed-choice syntax; retain existing pause directives. |
| §4.1 Mixed beat stream | Defer general mixed scene/storylet streams; retain current scene and hub presentations. |
| §4.2 Events | Accept as §1.4. |
| §4.3 Disabled choices | Retain implemented `require ... because`. |
| §4.4–5 Metadata/rich text | Retain implemented facilities; advanced presentation work belongs to milestone 36. |
| §4.6 Input | Require readable input statements using existing advance/token and validation model; no separate `respond` API required for v1. |
| §4.7 HUD | Defer `session:status`; hosts compose qualities and metadata. |
| §4.8 Save slots/headers | Retain implemented facilities. |
| §4.9 Undo | Required as above. |
| §4.10 Parser-style input | Defer. |
| §4.11 Embedding | Milestone 36; retain the scene adapter, general embedding is separate work. |
| §4.12 Localization | Retain implemented pipeline; require stable ids and menu/character text coverage for the authoring freeze. |

---

## 1. Needed by this game (workarounds in place)

### 1.1 Setting periods from effects (P0)
`once_per :day` needs `session:set_period(:day, v)`. Effects can't call session methods, because session commands aren't reentrant (§5.2). So the day rolls over inside an action, but the period only updates when the host calls `G.sync_periods(session)` after every `choose`. Until then, a post-phase action in the same phase sees a stale period.

**Proposal:** a transaction-aware `narrative.set_period(symbol, value)`, usable from effects and handlers. It would be recorded in the session, saved, and logged for replay like the existing period changes.

### 1.2 Always-shown storylets, and display order separate from selection (P0) — implemented: `sticky`, `order`
Exits from sub-decks ("Leave the stalls", "Get up") must always appear. Under tier filling (§9.3), a low-priority exit can be crowded out by `draw`, which strands the player. The game gives exits `priority 100` so they are drawn first. As a side effect they are also *listed* first, because display order is the same as priority order.

**Proposal:**
- `sticky true`: always included, doesn't use a draw slot, not subject to `replacement`.
- An `order` field for presentation order, separate from selection `priority`.
- Wordgrind-style `leads :deck` sugar (push on choose; `narrative.return_deck()` pops). It would remove most hand-written `push_deck`/`pop_deck` pairs.

### 1.3 Clamped adjustment (P0)
Quality constraints raise errors rather than clamping (§11.2). That's correct as a default, but in practice every `adjust` near a bound needs a guard in `when` (see `wait`, `small_talk`, `topic_storm`, `daily_wage`). Otherwise the effect fails and the player sees an error.

**Proposal:** `adjust rel(k) by n clamp` and `quality.add(e, q, n, {clamp = true})`. Both would saturate at the declared bounds. Also add `quality.metadata(name)`, so code can read the bounds without duplicating them.

### 1.4 A narration/message channel (P0)
Actions and handlers have no text of their own. The game sends narration through `narrative.emit(:say, text)`, and the host has to scan the whole `narrative_event` relation each turn, keep `last_seq`, and sort the results. That scan is O(history) per turn.

**Proposal:**
- `session:events_since(seq)`, returning events in sequence order.
- A standard `:say`-style event kind that a presentation can include directly. Presentations would carry `events` committed since the previous presentation.
- Optional text templates for actions (`text "..."`, rendered at commit), so automatic actions can narrate without bespoke event kinds.

### 1.5 Arithmetic and disjunction in rule bodies (P0)
Rule heads can't compute values, and guards can't bind. So:
- `load(?p, ?kg)` has to be written as an aggregate.
- `night()` is two rules, because a goal can't use `or`.
- A derived "effective" stat can't be written at all except as a one-element aggregate.

**Proposal:**
- A binding goal `?x := expr`, where every logic variable in `expr` is already bound. Its range is still finite because it's a function of bound values.
- `or` inside comparisons and guards.
- Optionally, `exists { ... }` / `not { ... }` subqueries (negation of a conjunction).

### 1.6 Existential variables in templates (P1)
Only declared parameters can appear in text (§7.2). `talk_keeper` can't say *where* the keeper is without making `?room` a parameter. Doing that would change instance identity, and with it cooldown and repeatability.

**Proposal:** `expose ?v`, which makes a functionally determined existential readable in templates and effects without becoming part of the instance key. Validation should reject it when the value isn't unique for an instance.

### 1.7 World context for handlers and helpers (P0)
Unqualified relations in an effect resolve to the session world (§7.2). Handlers registered with `narrative.on` are ordinary closures, so they resolve to their lexical world. The `:storm` handler has to wrap its body in `logic (world) do ... end`.

**Proposal:** handlers and `narrative.defer` callbacks get the same session-world rebinding as effect blocks. `quality.*` would default to the session world there too.

### 1.8 Terminal state (P1)
Nothing marks a session as finished. The game sets `flag(:game_over)` and the host checks for it, while `present()` would happily keep going.

**Proposal:**
- `narrative.finish(:ending_id)` from an effect, which sets `session:ended()`.
- `present()` returning `{ended = :id}`.
- Endings recorded in persistent data (§4.7).

### 1.9 Small query conveniences (P2)
The idiom `(query p(x))() ~= nil` is everywhere.

**Proposal:** `exists p(x)` as an expression, and `query.one`/`query.first`. Also add `session:choose_by(storylet_id, choice_id, bindings)` for tests and automation; `tools/check.lua` reimplements it.

### 1.10 Compound values (P1)
Inventories, dialogue history, paths and multi-part arguments have to be split across flat relations. Immutable portable sequences and records already exist for events (`narrative.sequence`).

**Proposal:** allow those values as relation terms, with structural equality, and add simple destructuring goals (`?seq[1]`, `#?seq`). This stops short of Prolog unification.

### 1.11 Inference performance (P0 for real games)
Each `present()` evaluates every storylet, choice, action and template condition by recomputing from scratch: naive fixpoint, unindexed nested-loop joins, no materialization cache. This game is small enough that it doesn't matter. A 100-room map with `reachable` is slow: a synthetic game of that size measures about 0.8 s per presentation on an Apple M1 (see [benchmarks/PERFORMANCE_PLAN.md](../benchmarks/PERFORMANCE_PLAN.md), which also holds the staged fix).

**Needed:** shared fact storage instead of per-query copies, slot-based bindings, argument indexes, semi-naive evaluation, a version-keyed cache shared across all queries in one presentation snapshot, and storylets indexed by the constant parts of their conditions (track W of the performance plan, ROADMAP milestone 35).

---

## 2. Twine-style games

Twine is passage-and-link based: one "current passage", inline links, `$variables`, macros, visit counts, and back/undo.

| Twine feature | Current Varis | Needed |
| --- | --- | --- |
| Passages addressed by name, `goto` | Storylets are selected, not addressed | **`passage` content kind** (or `narrative.goto(:id)`) with a *focus* mode: the presentation is exactly that passage, with no deck draw (P1) |
| Inline links in prose `[[text->Target]]` | Choices are separate from text | Template link syntax that compiles to choices, keeping position information so the host can render the links inline (P1) |
| `$gold`, `$name` variables | Keyed relations / qualities (verbose) | `var gold = 0` sugar over a keyed `var(name, value)` relation, readable in templates as `{gold}` (P1) |
| `visited("X")`, `turns since` | Completion history exists but isn't queryable | Read-only relations `visited(content, count)` and `last_chosen(content, turn)` (P1) |
| `<<if>>` / `<<set>>` in text | `{#if query}` only; no effects in text | Lua expressions in conditions (`{#if lua coins > 3}`, read-only); keep effects out of text |
| `<<include>>`, reusable text snippets | — | Named template fragments: `{>fragment}` (P2) |
| Text that changes when clicked (replace/append) | — | Host-level; needs link/region IDs in the rendered output (§5.3) (P2) |
| Back/undo | Not available | **`session:undo()`** over a bounded ring of committed snapshots. Worlds are already snapshot-capable; RNG and decks must roll back too (P1) |
| Story-wide `StoryInit` | Authored init code | Works today |

## 3. Ren'Py-style games

Ren'Py is mostly linear: `say` lines, `menu`, `jump`/`call`/`return`, `show`/`hide`/`scene`, rollback, read-text skipping, persistent data.

### 3.1 Scenes: linear scripts with menus, jump/call/return (P1)
Storylets are the right *hub* model but the wrong tool for twenty lines of dialogue. The first scene implementation now represents lines as declarative beat records; arbitrary
procedural statements between them remain unsupported. Effects can't yield, so a coroutine-based script is forbidden.

**Proposal:** a `scene` content kind, run by the session as a resumable script:
- **Beats:** each `say`, `menu`, `pause`, `input` or media directive is a *beat* that suspends the scene and returns a presentation.
- **Commits:** code between beats runs in its own transaction and commits before the beat is shown, so yielding never happens inside a transaction.
- **Serializable position:** the scene's position must survive a save. Store it as `(scene id, beat index, local variable snapshot)`, not as a Lua coroutine. This means compiling scenes to a resumable state machine with portable locals, the way Ink and Ren'Py do.
- **Control flow:** `jump scene`, `call scene` (with a return stack saved in the session), and `jump hub`, which returns to storylet presentation.
- **Interop:** storylets and actions can start a scene with `narrative.play(scene)`, and scenes can push decks.

### 3.2 Characters and say lines (P1)
- A `character` definition (display name, style metadata, default image tag) registered in the content registry.
- Each `say` beat carries a **stable line id** derived from the scene id and authored order, or set explicitly. Read-tracking, skip-read, localization and voice files all need it.

### 3.3 Media directives (P1)
`show`/`hide`/`scene`/`play music`/`with transition` as structured beats with portable arguments: symbols, numbers and strings. The engine doesn't interpret them; it orders them, saves the current "stage state" (which images are shown, current music) so a load restores the scene, and rolls them back with undo.

### 3.4 Rollback (P1)
Same mechanism as Twine undo (§2), but at beat granularity. It needs scene positions and stage state in the snapshot.

### 3.5 Persistent (cross-save) data (P1)
Seen lines, unlocked endings, achievements and gallery entries survive new games. Today the game keeps `Achievements` in a Lua table, which is lost on restart and changed only through `narrative.defer`.

**Proposal:** a `persistent` world or keyed relation, owned by the host profile rather than the session. It would be written only after commit, and excluded from session saves and replay determinism.

### 3.6 Timed choices and real-time pauses (P2)
The engine stays turn-based. Hosts report timeouts as `session:record_input(:timeout, choice_id)` plus a default choice field on the menu beat.

## 4. User interaction changes

These change what the engine hands to the host, not how it's drawn.

1. **Beat-stream presentations.** `present()` returns an ordered list of beats: `say`, `narration`, `show`, `menu`/storylets, `input`, `pause`, `ended`. Active scenes now return one current beat plus stage and an advance token; storylet hubs
still return storylets. A general mixed beat stream remains proposed. Hosts would render beats; choice tokens would stay opaque.
2. **Events in the presentation.** Committed events since the last presentation, so hosts don't poll `narrative_event` (§1.4).
3. **Disabled choices with reasons.** *Implemented October 12, 2026* as `require { … } because "…"` (manual §6.3); *The Hollowbrook Summer* uses it. Twine and Ren'Py often show unaffordable options greyed out. Original proposal: a choice `require { ... } because "..."` clause. Choices that pass `when` but fail `require` are presented with `enabled = false` and a reason string, and no usable token. `narrative.explain` already computes most of this.
4. **Arbitrary portable metadata on content.** `tags`, `icon`, `shortcut`, `style`: frozen at registration and passed through to the presentation. Today only the fixed fields exist.
5. **Rich text.** A small, portable markup (emphasis, strong, speaker colour, line break, link regions with ids) parsed with templates. Hosts would get spans, not ad hoc strings, which avoids format injection from bound values.
6. **Text input.** An `input` beat with a prompt, default value and validation. The current scene input beat uses `session:advance(token, value)` and scalar portable
locals. The proposed `respond` API, general validation and replay-input policy remain design work.
7. **Status / HUD data.** `session:status()` returns the visible qualities with labels and bounds, using the `visible`/`label` metadata `quality.define` already stores. The sample host builds its status line by hand.
8. **Save metadata and slots.** `session:save({label=..., meta=...})` returns a header the host can show (turn, day, label, timestamp supplied by the host) without restoring the save. Autosave hooks at idle boundaries.
9. **Undo/back** (§2, §3.4).
10. **Parser-style input (optional, P2).** For classic IF: `session:choose_by_text("take rope")`, matching against choice titles or authored `verbs`. Not needed for VN/Twine.
11. **Embedding API.** A documented D-side host API: create state, load content, run session commands, receive presentations as D structs. An initial status-returning `SceneHost` adapter and SDL3 player exist; a general embedding
API remains work. WebAssembly is not planned (ROADMAP D13).
12. **Localization.** Templates looked up by stable ids (§3.2) from per-language string tables, with `narrative.name` labels per locale. Content fingerprints should exclude translations, so a language pack doesn't invalidate saves.
