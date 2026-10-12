# Varis Reference Manual — Narrative Programming

[Contents](README.md) · [Relations and state](relations.md) · [Library entries](libraries.md#73--logic-library)

## 6 — Narrative programming

### 6.1 — Content and sessions

Content definitions belong to a state-owned registry, `narrative.registry`, rather
than to a logical world. Storylets, choices, actions, decks, handlers, quality
metadata, labels, and formatters are registered during initialization. A world
snapshot does not duplicate the content registry.

`narrative.seal([version])` validates references and options, freezes the registry,
and returns its content version. Without an explicit authored string the runtime
fingerprints the canonical content manifest (without wording, see 6.9). Creating a session seals an open
registry. Registration after sealing is an error. Identifiers are symbols and
unique within their kind; choices are unique within their enclosing storylet.
The same symbol can identify a storylet, deck, and action independently.

`narrative.new(world)` creates a session with that world, the sealed registry,
turn zero, and an initial `:default` deck entry. A mutable world belongs to at most
one session; independent sessions use independent worlds. Call `session:seed`
with an explicit integer before random presentation. Session state includes RNG,
deck stack and histories, completion/action policies, periods, schedules, events,
and replay records.

Session commands cannot recursively start presentation/choice/scheduler work
from effects, rendering, or notifications. The specifically permitted effect
operations below participate in the current transaction instead.

### 6.2 — Storylets and parameters

```lua
storylet travel(?from, ?to)
    when { location(:player, ?from), road(?from, ?to) }
    deck :exploration
    priority 10
    weight 2
    title "Walk to {to}"
    text [[You leave {from}.]]
    choice proceed
        title "Continue"
        effect do
            set location(:player, to)
            narrative.emit(:travelled, from, to)
        end
    end
end
```

A storylet requires an availability `when { goals }`, a title, and at least one
choice. Every header parameter must be grounded by the availability query.
Each distinct parameter assignment identifies an instance. Other query variables
are existential and are not exposed to templates or effects.

| Field | Default | Requirement |
| --- | --- | --- |
| `deck` | `:default` | Known deck symbol |
| `priority` | `0` | Integer |
| `weight` | `1` | Finite nonnegative number |
| `cooldown` | `0` | Nonnegative integer turns |
| `repeatable` | `true` | Boolean |
| `sticky` | `false` | Boolean; include every eligible presentation without a draw slot |
| `order` | `0` | Integer; lower values display earlier |
| `title` | None | Required template string |
| `text` | Empty string | Template string |

Fields appear at most once, before choices. Procedural numeric/Boolean fields
are evaluated once at registration and frozen. A zero weight excludes random
selection without making the underlying query false.

`repeatable false` suppresses that particular instance after a successful choice.
`cooldown N` requires N completed turns after the successful choice's committed
turn before that instance is selectable again. Presentations do not advance time.
These policies distinguish instances with different bindings.

An instance key encodes content ID and parameter bindings canonically. Parameter
values must be portable scalars: nil, Boolean, integer, finite float, string, or
symbol. Mutable tables, functions, threads, userdata, and even portable composite
sequences are not scalar instance keys. Equal integer/float scalars have the same
instance identity. Query/hash enumeration order cannot alter identity. Instance
bindings are immutable and retain the availability world version.

### 6.3 — Choices, lexical binding, and tokens

A choice can introduce additional parameters and a correlated availability query:

```lua
choice buy(?item, ?cost)
    when { for_sale(?item, ?cost), quality(:player, :coins, ?balance), ?balance >= ?cost }
    title "Buy {item}"
    effect do
        adjust quality(:player, :coins) by -cost
        fact owns(:player, item)
    end
end
```

Storylet parameters are grounded inputs to this query. New choice parameters
must be grounded there. Without `when`, the choice is available whenever its
storylet is. A choice requires an `effect do ... end` block. Its title and text templates
default to empty strings when omitted. Each choice ID/binding combination is a distinct
choice instance.

Exposed parameters become read-only lexical locals without `?` in effects and
template contexts. They shadow outer ordinary locals, and cannot be assigned
through nested closures. Existential variables do not become locals. `?name`
remains declarative syntax, not ordinary effect syntax.

Unqualified narrative availability/effect references resolve in the owning
session world, bypassing surrounding local relation handles and registration-time
defaults. Ordinary helper closures still retain their own lexical worlds.
Consequently, calling a helper captured in another world does not authorize a
foreign-world write during an effect transaction. Quality library defaults follow
this lexical call metadata as described in section 6.8.

A presentation contains immutable storylet and choice records with opaque tokens.
Pass the exact `choice.token` to `session:choose`; do not reconstruct a token
from its text or instance key. Tokens belong to one session and exact deck entry.

Choosing opens an effect transaction and revalidates the exact storylet and choice
bindings, deck entry, eligibility, cooldown, and repeatability. It does not select
replacement bindings. Failure raises `STALE_CHOICE` without changes or turn
advancement. An unconsumed token survives unrelated world writes or additional
presentations when those checks still hold. A consumed, foreign, or invalidated
deck-entry token fails.

On success the effect, completion history, token consumption, and turn increment
commit together, then the post-choice phase runs. An effect error rolls back
transaction-aware changes and leaves the token retryable and turn unchanged.
Effects cannot yield, register rules/content, or recursively choose/present.
Arbitrary Lua object mutation and I/O are not undone. An error after commit in a
deferred callback or post-phase action does not undo the completed choice.

### 6.4 — Automatic actions

```lua
action warn(?person)
    when { quality(?person, :poison, ?n), ?n >= 10, not warned(?person) }
    phase :post
    priority 100
    once_per :game
    effect do
        fact warned(person)
        narrative.emit(:warning, person)
    end
end
```

Actions are procedural effects selected by a scheduler, never inference rules.
They require grounded scalar parameters, availability, and an effect. Defaults
are phase `:post`, priority zero, and `once_per :turn`. Phase must be `:pre` or
`:post`; priority is an integer.

The pre phase runs before presentation; the post phase follows a committed
choice. In either phase, due events are processed before each eligibility pass.
The scheduler enumerates available instances, excludes once-per suppression,
chooses highest priority, and breaks ties by canonical content ID and bindings.
It revalidates and commits one effect, records its execution, then reevaluates
from the new state. This continues until no action is eligible.

`once_per :turn` allows each instance once at a numbered turn, `:game` once per
session, and `:always` removes suppression. Other symbols use the current portable
value set by `session:set_period`; without a value the action is excluded. An
instance can run once for each distinct value of that named period.

The default action budget is 1,000 per phase, configurable with `session:limits`.
`ACTION_LIMIT` preserves earlier successful commits. A budget failure is not a
proof of an infinite cycle. Actions should make progress or use once-per policies;
inference evaluation order must never be used as a scheduler.

### 6.5 — Decks and deterministic selection

```lua
deck :exploration { draw = 3, replacement = false }
```

`draw` must be a positive integer and `replacement` a Boolean. The implicit
`:default` deck has draw one and replacement true unless explicitly configured.
Storylets name a deck; the active deck is the top session stack entry.

Inside effects, `narrative.push_deck` creates a fresh entry,
`narrative.pop_deck` removes the top but cannot remove the last,
`narrative.replace_deck` installs a fresh top entry, and
`narrative.reset_deck` clears the current entry's draw history. These changes are
transactional and take effect at the next presentation. Underlying entries keep
their history across a push/pop. Replaced/popped entries' tokens become stale.

Presentation filters policies and zero weights. Eligible `sticky true` instances
are always included without consuming draw slots or selection RNG and are exempt
from nonreplacement history. They still obey availability, deck, cooldown,
repeatability, and positive-weight checks. Non-sticky selection picks up to `draw`
instances, filling highest
priority tiers before lower tiers. Within each tier, weights determine sampling
probabilities. No instance appears twice in one presentation. With replacement
true it may appear on later presentations. With replacement false an instance
already drawn in that stack entry is excluded until reset or a fresh entry.
An empty presentation is valid; choosing a storylet is not required for a draw
to enter nonreplacement history.

Candidates are canonically ordered before sampling. Only the session RNG supplies
draws. Current algorithms use SplitMix64 seed initialization and xorshift64*
output using its high 53 bits, with weights normalized by the tier's maximum.
Algorithms are runtime-versioned; seeded reproducibility requires matching
runtime/content and command inputs. Query iteration order cannot change draws.

Rendering must succeed before draw history, new tokens, and RNG updates publish.
Already committed pre-phase actions remain committed if rendering later fails.
Returned storylets sort by ascending `order`, then descending `priority`, then
canonical instance key. Choices sort canonically. Display order does not change
selection priority; a sticky presentation can contain more than `draw` storylets.

### 6.6 — Presentation values and templates

`session:present()` returns an immutable record with `turn`, `deck`, and
`storylets`. `storylets` is an immutable one-based sequence; each record contains
`id`, `instance_key`, `bindings`, `title`, `text`, `world_version`, and `choices`.
Each choice record contains `id`, `instance_key`, `bindings`, `title`, `text`,
and `token`. Sequences support indexing and length, preserving nil slots.

A presentation can be rendered again in another language without presenting again
(`session:render`, section 7). The message key of a storylet's `title` is
`<storylet>.title`, of a choice's `<storylet>.<choice>.text`, and a translated name
of a symbol is `name.<symbol>`. A translation is written in the same template
grammar and may use the placeholders, the `{#if query ...}` conditions and the
variant groups of the source message, with the same number of options per group
(conditions and variants are not evaluated again: the results captured when the
presentation was made are used). Otherwise the message is shown in the source
language, as a whole.

Templates apply to title/text fields and explicit `narrative.template` calls;
ordinary string literals do not interpolate. `{name}` displays an exposed
parameter, `{{` and `}}` produce literal braces, and unknown placeholders are
validation errors. Nil displays as an empty string by default. Symbol labels
and pure registered formatters can customize display (section 7.4).

```text
{#if query trusted_by(:guard, :player)}Welcome back.{#else}Show your papers.{/if}
```

A condition tests existence of a query result, not truthiness of its iterator.
Nested conditions can use immutable parameters. All conditions read the same
presentation snapshot, obey query safety/purity, and prohibit writes and yields.
The scanner recognizes quoted strings, long strings, and comments inside queries
when locating their delimiters.

Weighted text alternatives are implemented:

```text
{#variant 3}Hello.{#variant 1}Welcome.{/variant}
{#variants}{#variant 2}Sunny.{/variant}{#variant 1}Rainy.{/variant}{/variants}
```

Weights are positive finite numbers; omitted weights default to one. `weight=3`
is also accepted. A `{#else}` alternative in a variant has weight one. An
alternative may also carry a **name**, a word after the weight (`{#variant 3 wind}`,
`{#variant gulls}`): the replay log records the drawn alternative's name beside its
index (`names`), and a translation may reorder named alternatives, which are then
found by name. Groups may
nest. The session chooses variants before rendering, records choices in replay,
and publishes RNG changes only on successful presentation. Rendering itself
consumes no RNG. Explicit template calls use supplied zero-based choices, or a
deterministic highest-weight default; they do not draw from session RNG.

Two more tags choose between branches by a parameter's value:

```text
{#plural coins}{#one}A coin{#other}{coins} coins{/plural}
{#select kind}{#case storm}A storm.{#case calm}Quiet.{#default}Weather.{/select}
```

`{#plural n}` takes an integer or float parameter and picks the branch named
by its plural category in the language of the text: `zero`, `one`, `two`, `few`,
`many` or `other`. English has `one` and `other`; French `one` (0 and 1) and
`other`; Russian, Ukrainian and Polish `one`, `few`, `many` and `other`; Chinese,
Japanese and Korean only `other`. `{#other}` is required, and is used when no
branch has the category. `{#select v}` compares the parameter (a symbol, string,
integer or Boolean) with each `{#case value}`; `{#default}` is required. Branches
may hold placeholders, conditions and variants. A number with a fraction is
`other`. The language of authored text is the manifest's `language`
(`narrative.source_language(tag)`, English by default); a translation uses the
rules of its own language.

### 6.7 — Events, schedules, and callbacks

`narrative.emit(kind, ...)` in an effect appends a transactional event. Kind is
a symbol and arguments must be portable values. Commit assigns increasing
sequence numbers. The reserved read-only relation
`narrative_event(sequence, turn, kind, args)` exposes committed history; its
argument sequence is immutable and preserves nil positions. Public writes and
rule heads targeting that relation are forbidden.

An event emitted by a player choice carries the pre-advance turn. That choice's
commit increments the turn and records completion at the new turn. Post actions
and due handlers see the new turn. Presentations, actions, and queries do not
independently advance it; named periods are explicit, not wall-clock time.

`narrative.schedule(kind, narrative.sequence(...), after_turns)` queues a due
turn and insertion sequence. Delay must be a nonnegative integer. A zero-delay
event is processed only after the current effect commits. Due events run before
automatic actions and before each subsequent eligibility pass, in due-turn then
insertion order. Delivery emits the history event and optionally invokes the
handler registered with `narrative.on(kind, function(world, kind, args) ... end)`
in its own transaction. An ordinary handler can use `logic (world) do ... end`
for explicit access to its supplied world.

A failed handler leaves its event queued; earlier handlers/actions remain
committed. The default event budget is 1,000 per phase, independent of the action
budget. `EVENT_LIMIT` preserves prior progress and bounds immediate chains.

`narrative.defer(function)` schedules a no-argument callback after successful
commit and cleanup. Savepoint rollback discards it; child commit merges it.
Callback errors propagate after committed state is published, with no rollback
or automatic retry. Prefer named portable events for persistence/replay rather
than relying on anonymous external callbacks.

### 6.8 — Qualities

Qualities use the keyed extensional relation
`quality(entity, name, value) key(entity, name)`, installed by the standard
library in library-created worlds. They are metadata and constrained base facts,
not a separate inference model.

`quality.define` registers a symbol name and immutable metadata: `initial`,
`minimum`, `maximum`, `visible`, and `label`. Initial defaults to nil, visible to
true, label to the identifier. Initial/unbounded values must be portable scalars;
bounds must be finite numbers in ascending order. Unknown names and invalid
metadata are errors.

Definition does not insert facts. `quality.initialize` inserts the initial value
only if absent; initialized nil is still present. `quality.get` returns the
actual value or nil, without defaults. `quality.set` and `quality.add` perform
keyed writes with bounds checked and no clamping. Add requires presence and a
numeric current value/delta. Deletion followed by initialization restores initial
membership. Use a query to distinguish absent membership from an initialized nil.

Constraints apply to all mutation paths, including direct fact/set/adjust,
`logic.add`, inherited worlds, transactions, and restoration. Derived qualities
belong in other relations because `quality` cannot be a rule head.

An explicit world argument selects the world directly. Without it, calls outside
effects use `logic.global`. Inside effects they use lexical call-world metadata:
the session world in the effect body, an enclosed world block, or an ordinary
helper's captured world. Aliasing a library function preserves this rule.
Foreign-world mutations still fail the effect transaction's world check.

### 6.9 — Portable saves and replay

Save only at an idle boundary, with no active transaction, effect, scheduler, or
presentation command in progress. A retained immutable presentation or a scene
waiting for advance does not prevent saving. `session:save()` returns canonical tagged JSON text. The current
wire format uses `varis-session-3` for sessions that have entered scenes (6.11),
`varis-session-2` for other sessions, and reads `varis-session-1` as well; the language rename does not silently change
persisted identities. Format 2 differs from 1 only in the content identity: wording
(titles, texts, names and labels) is not part of it, only the conditions, variant
weights and names, and plural/select parameters a text contains, so correcting a
typo does not invalidate saves. A `presentation` field records a digest of the
wording; it is informational and never refuses a save. Format 1 saves are
validated as they were written and are written back as format 2.

Saves include base tuples, ordered schemas/keys and versions, persistent world
identity, runtime/content/program fingerprints, turns, deck entries and draw
history, completion/action policies, periods, schedules/events, RNG and seed,
execution limits, consumed-token IDs, and replay inputs. Derived tuples are
recomputed. Query iterators and usable tokens are not portable continuations.

Portable values are nil, Booleans, integers, finite floats, byte strings, symbols,
and supported immutable sequences/records recursively containing them. The codec
preserves numeric representation/float bits and binary bytes. Ordinary tables,
functions, threads, userdata, and local-relation dependencies are not serialized.
Unsupported values produce a path diagnostic rather than being dropped.

`narrative.load(saved, world_factory [, migration])` calls authored code to rebuild
an idle unowned world, stages a fresh snapshot, and validates the entire save
before returning a session. The factory's world remains unchanged on success
and failure; arbitrary external side effects of the factory are not undone.
The restored world has a fresh runtime identity and retained persistent identity.

Pure portable-constant rules can be fingerprinted structurally. Guards and
aggregate callbacks require `narrative.program(world, nonempty_version)` during
authored initialization. It records a reconstruction assertion and fingerprint;
subsequent program/capture changes can make saves non-reconstructible. An authored
content version likewise asserts reconstruction for content captures. Hosts must
reestablish native callbacks or mutable capture environments covered by these
assertions. A version string does not serialize executable closures.

Validation compares code/capture fingerprints, complete ordered schemas, keys,
constraints, histories, counters, and runtime/content/program identities. On an
incompatibility only, an explicit migration receives the old text and immutable
target `runtime`/`content` identities and must return exactly one replacement
saved-text string, which undergoes full validation again. There is no silent
predicate renaming/reordering or schema migration.

`session:replay_log()` returns immutable version identities and command records
for seeds, limits, external period changes, successful presentations, variants,
and committed choices. `record_input(symbol, value)` logs host input without
applying it. Hosts replay from the same authored initial state and apply logged
external inputs themselves, matching instance keys to new presentation tokens.
The API does not automatically replay a log. Unrecorded writes, impure code,
and failed commands with partial scheduler commits need host reconstruction.
Subscriptions and queued closures must be reestablished after load.

### 6.10 — Explanations, subscriptions, and bounded analysis

These authoring facilities are implemented but have narrower guarantees than
full proof or exhaustive reachability systems.

`narrative.explain` freezes a world and reports goal-prefix outcomes and candidate
policy exclusions without writes or RNG use. Positives, aggregates, comparisons,
guards, and negation are diagnosed in evaluator order. Goal entries retain
authored index/kind/relation/terms, before/after binding counts, and
`success`, `failure`, `error`, or `not_reached`. Exclusions include deck, cooldown,
completion, zero weight, draw history, and once-per/unset periods; choice
availability is included. This is not a complete recursive proof tree. A storylet
ID resolves first; an otherwise unique action ID can also be explained.

`narrative.observe` snapshots a relation's committed visible set without notifying
existing membership. Later commits recompute base/derived visible sets and
dispatch enter/leave deltas after publication, never during inference. No-op
membership changes and rollbacks emit no delta. Order is canonical by relation
and tuple, then subscription registration order. Scalar ordering is portable;
reference ordering uses process-local addresses. Tuples are immutable sequences,
including zero arity and exact nil slots.

All baselines update before callbacks. All applicable observer/deferred callbacks
are attempted and the first error propagates after publication, without retrying
the transaction or repeating delivered deltas. Notifications cannot yield or
synchronously mutate/start commands on the notifying world, even via children.
`narrative.enqueue` requests later work; the host calls `narrative.flush` at an
idle boundary. Its default budget is 1,000. `OBSERVER_QUEUE_LIMIT` preserves
completed work and remaining entries; failed commands are removed before calling.
Subscriptions/queues are world-owned, not inherited or saved.

`narrative.analyze` explores one deterministic seeded presentation at each cloned
node and branches over every returned choice. It excludes alternate random draws,
repeated presentations without choices, future host input, and observer queues.
It copies Lua graph aliases/cycles/upvalues into separate states, sharing no
mutable object with the live session. Native host calls, I/O, process/debug/
coroutine operations, external loading, and shared `math.random` are blocked.
`require` can use already-loaded cloned modules. Even a caught forbidden operation
marks the report incomplete.

Default bounds are depth 3, nodes 100, VM steps 1,000,000, graph objects 200,000.
Depth accepts 0–32, nodes 1–10,000, step/object budgets must be positive, and graph
nesting is at most 256. Reports include scope, completeness, limits, transitions,
reached and not-reached-within-scope content, dead ends, potential action cycles,
frontiers, errors, and blocked operations. Exhausted bounds and errors make
`complete=false`. Neither bounded non-reachability nor action-budget exhaustion
proves global unreachability or a cycle. The original state and captures remain
unchanged.

### 6.11 — Scenes, beats, and stage state

A scene is a registered sequence of immutable beat records. `scene Name { ... }`
and `character Name { ... }` are contextual declarations, equivalent to
`narrative.scene(:Name, {...})` and `narrative.character(:Name, {...})`.
Their tables are copied at registration; subsequent author-table mutations have
no effect. Functions, cycles, nonfinite numbers, and arbitrary objects are rejected.
Registration is forbidden after sealing. Scene and character identifiers are unique
within their respective kinds.

```lua
character mira {
    name = "Mira", tag = :mira,
    attributes = {expression = {:quiet, :smile}},
    defaults = {expression = :quiet}
}
scene greeting {
    {kind=:background, tag=:harbour},
    {kind=:show, character=:mira, slot=:left},
    {kind=:input, ["local"]="visitor", text="Your name?"},
    {kind=:say, character=:mira, attributes={expression=:smile},
        id="greeting.welcome", text="Welcome, {visitor}."},
    {kind="return"}
}
```

`session:play(:greeting)` starts the scene at an idle boundary. Inside an existing
choice/action/handler effect, `narrative.play(:greeting)` starts it transactionally:
a failed effect restores the previous scene and stage along with the world.
Playing replaces the active scene stack and preserves the existing stage.
Control steps run until the first display beat before publishing the position;
a failed command publishes no partial position or stage.

While a scene is active, `session:present()` returns an immutable record with
`scene`, `beat_index` (1-based), `locals`, `beats` (one current beat), `stage`,
`token`, `turn`, and an empty `storylets` sequence. It does not advance the beat,
draw RNG, or append a scene presentation to the command log. The ordinary pre
phase still runs. `session:advance(presentation.token [, input])` consumes that
boundary and moves to the next one. Tokens belong to their session and exact
position object; an advance or a replacement play invalidates them. Tokens from
another session, before loading, or from an earlier position raise `STALE_BEAT`.
A rejected input leaves the position and token valid. Storylet choice tokens
cannot be used while a scene is active. Beat advances do not increment the
storylet turn or run the post phase.

| Beat kind | Fields and behavior |
| --- | --- |
| `say` | Required `character` and `text`; optional `attributes` update the character. `speaker` in the presentation contains its registered metadata. |
| `narration` | Required `text`, without a character. |
| `show` | Required `character` and named `slot`; optional `attributes`. Replaces another occupant of that slot. |
| `hide` | Required `character`; removes its slot and preserves attributes. |
| `background` | Required `tag`; replaces the background. |
| `audio` | Required `channel`; `tag` starts/replaces it, absent `tag` stops it. |
| `pause`, `transition`, `screen`, `picture` | Portable structured directives delivered to the host. Only character slots, attributes, background, and audio are persistent stage fields. |
| `input` | Required `local` name; advance stores its portable scalar input, including nil. |
| `menu` | Nonempty `choices`, each with `id`, `text`, and a scene `target`. Advance requires an exact choice id and jumps to its target. |
| `ended` | Delivered to the host; advancing it clears the scene stack. |
| `set` | Required `local` name and portable scalar `value`; updates locals without displaying a beat. |
| `jump`, `call` | Required scene `target`; jump replaces the current frame, call pushes a frame and saves the return address. `jump` to `:hub` clears the whole stack. |
| `"return"` | Pops the frame; falling off a scene does the same. The spelling is a string because `return` is a Lua keyword. |

Calls inherit a copy of the caller's scalar bindings; child changes remain local
to the child. Jumps preserve the current bindings. There are at most 128 frames
and 1,000 control steps per command; a loop or excess nesting is an error.
After the stack empties, presentation resumes the storylet deck; its presentation
also includes the retained stage. The engine owns tags, attributes, slots,
background and audio channel tags; assets, pixels, animation and audio playback
belong to the host. This version has no arbitrary procedural code between beats,
beat undo/history, or automatic exploration of scene branches by `narrative.analyze`.

Characters declare allowed attribute values in `attributes`, with optional
`defaults`. Unknown characters, attribute names, or values are rejected at seal;
`varis check --no-load` also checks literal scene/character references and
attribute values with source ranges. Portable scene locals are nil, Boolean,
integer, finite float, string, or symbol; tables and closures are never live locals.

Text beats have an authored `id`, or receive `<scene>.<1-based beat index>`.
Text ids are unique across the registry. Explicit ids preserve identity when
inserting or moving beats. The localization catalog key is `scene.<id>.text`;
character names use `character.<character>.name`. Scene line text uses ordinary
narrative templates with the current locals as bindings. `set_language` and
`render(presentation, language)` translate scene line text; re-rendering preserves
the token, captured template trace, position, and stage. Menu labels and character
metadata are currently delivered as authored text.

A session that has entered a scene saves as `varis-session-3`. It extends format 2
with validated frames (scene id, zero-based position, scalar locals) and stage
state. Current beat wording is reconstructed from the authored program, not saved.
Scene structure, targets, line ids and character attributes affect content identity;
wording does not, while template structure does. Loading recreates the current
beat without replaying earlier media or input. It validates the position and stage
before invoking the world factory, and issues fresh tokens only upon presentation.
Sessions that have never entered a scene still write format 2 unchanged. Older
formats remain readable; an older runtime rejects format 3. See the executable
[linear sample](../sample-vn/README.md) for a mid-scene and mid-call save/load proof.
