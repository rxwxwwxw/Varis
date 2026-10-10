# Needed extensions

This file lists the language and runtime changes that *Saltmarsh Light* (this folder) and Twine- or Ren'Py-style games need, beyond the current [Varis Reference Manual](../docs/README.md). This is a proposal/workaround inventory, not a language specification; entries marked implemented (such as `sticky` and `order`) are defined in the manual. Historical section citations map through [docs/coverage.md](../docs/coverage.md).

The game itself uses only current-spec features. Where it has to work around a gap, the code points here, and [`extensions/proposed.lua`](extensions/proposed.lua) sketches the proposed syntax. Section numbers below (§1.1 and so on) are the ones the code comments cite.

Priority key: **P0** means the game needs a workaround today. **P1** is needed for Twine/Ren'Py-class games. **P2** is quality of life.

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
Each `present()` evaluates every storylet, choice, action and template condition by recomputing from scratch: naive fixpoint, unindexed nested-loop joins, no materialization cache. This game is small enough that it doesn't matter. A 100-room map with `reachable` would be noticeably slow per turn.

**Needed:** a version-keyed cache shared across all queries in one presentation snapshot, argument indexes, semi-naive evaluation, and slot-based bindings.

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
Storylets are the right *hub* model but the wrong tool for twenty lines of dialogue. Today each line would have to be its own storylet. Effects can't yield, so a coroutine-based script is forbidden.

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

1. **Beat-stream presentations.** `present()` returns an ordered list of beats: `say`, `narration`, `show`, `menu`/storylets, `input`, `pause`, `ended`. Today it returns only a flat storylet list. Hosts would render beats; choice tokens would stay opaque.
2. **Events in the presentation.** Committed events since the last presentation, so hosts don't poll `narrative_event` (§1.4).
3. **Disabled choices with reasons.** Twine and Ren'Py often show unaffordable options greyed out. Proposal: a choice `require { ... } because "..."` clause. Choices that pass `when` but fail `require` are presented with `enabled = false` and a reason string, and no usable token. `narrative.explain` already computes most of this.
4. **Arbitrary portable metadata on content.** `tags`, `icon`, `shortcut`, `style`: frozen at registration and passed through to the presentation. Today only the fixed fields exist.
5. **Rich text.** A small, portable markup (emphasis, strong, speaker colour, line break, link regions with ids) parsed with templates. Hosts would get spans, not ad hoc strings, which avoids format injection from bound values.
6. **Text input.** An `input` beat with a prompt, default value and validation. The reply comes back through `session:respond(token, value)`, is recorded for replay, and is portable-validated.
7. **Status / HUD data.** `session:status()` returns the visible qualities with labels and bounds, using the `visible`/`label` metadata `quality.define` already stores. The sample host builds its status line by hand.
8. **Save metadata and slots.** `session:save({label=..., meta=...})` returns a header the host can show (turn, day, label, timestamp supplied by the host) without restoring the save. Autosave hooks at idle boundaries.
9. **Undo/back** (§2, §3.4).
10. **Parser-style input (optional, P2).** For classic IF: `session:choose_by_text("take rope")`, matching against choice titles or authored `verbs`. Not needed for VN/Twine.
11. **Embedding API.** A documented D-side host API: create state, load content, run session commands, receive presentations as D structs. This lets a Qt or HTML/JS front end, or a WASM build, drive the engine without going through Lua tables.
12. **Localization.** Templates looked up by stable ids (§3.2) from per-language string tables, with `narrative.name` labels per locale. Content fingerprints should exclude translations, so a language pack doesn't invalidate saves.
