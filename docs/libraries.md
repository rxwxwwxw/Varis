# Varis Reference Manual — Standard Libraries

[Contents](README.md) · [Language](language.md) · [Narrative semantics](narrative.md)

## 7 — Standard libraries

The standalone interpreter opens the basic, coroutine, package, string, utf8,
table, math, io, os, debug, logic, narrative, and quality libraries. An embedded
host can choose which to open. Optional arguments default as described below;
passing nil ordinarily requests the default. The debug library is a trusted
inspection interface, not a sandbox boundary.

### 7.1 — Basic functions

| Entry | Contract |
| --- | --- |
| `_G` | Initial global environment table. Assigning it does not replace `_ENV`. |
| `_VERSION` | Current compatibility string; still identifies Lua 5.4, not a Varis release. |
| `assert(v [, message])` | Returns all arguments when v is truthy; otherwise raises message or an assertion error. |
| `error(value [, level])` | Raises value. Level defaults to 1 for source attribution; zero suppresses that prefix. |
| `pcall(f, ...)` | Returns true and f's results, or false and its error object. |
| `xpcall(f, handler, ...)` | Protected call with a message/error handler. |
| `type(v)` | Returns the primitive type name, including `symbol`. |
| `tostring(v)` | String form, honoring `__tostring`; symbols use literal/quoted-name form. |
| `tonumber(v [, base])` | Converts a number or numeric string, or returns nil. Explicit base is 2–36 and parses an integer string. |
| `select(index, ...)` | `"#"` returns argument count; an integer selects the suffix, with negative indexes counting from the end. |
| `print(...)` | Writes string forms separated by tabs, followed by newline. |
| `warn(...)` | Emits concatenated string warning fragments; `@on`/`@off` control warnings. |
| `rawequal(a, b)` | Equality without `__eq`. |
| `rawget(t, k)` | Table lookup without `__index`. |
| `rawset(t, k, v)` | Table assignment without `__newindex`; returns t and still rejects invalid keys. |
| `rawlen(v)` | String byte length or table border without `__len`. |
| `getmetatable(v)` | Metatable, protected `__metatable` value, or nil. |
| `setmetatable(t, mt)` | Sets/removes an unprotected table metatable; returns t. |
| `next(t [, key])` | Next key/value or nil. Order unspecified; invalid continuation keys error. |
| `pairs(t)` | Uses `__pairs`, otherwise returns next, t, nil. |
| `ipairs(t)` | Iterates consecutive one-based indexes, stopping at the first nil. |
| `load(chunk [, name [, mode [, env]]])` | Compiles a source string or reader function; returns a function or nil/error. Mode `t`, `b`, or `bt` defaults to both. Env supplies the first upvalue. |
| `loadfile([filename [, mode [, env]]])` | Loads a file or stdin, returning a function or nil/error. |
| `dofile([filename])` | Loads and executes file/stdin, propagating errors and returning all results. |
| `collectgarbage([option [, arg ...]])` | D-backed collection interface; see implementation limits below. |

`load` compiles Varis syntax, including relational/narrative constructs. Binary
loads accept this implementation's private chunk body, not arbitrary C Lua
bytecode. `collectgarbage("collect")`, `"stop"`, `"restart"`, `"count"`,
`"isrunning"`, and `"step"` expose collection/control operations; tuning options
are compatibility approximations, not the Lua incremental/generational policy.

### 7.2 — Procedural libraries

#### 7.2.1 — Coroutine manipulation

| Entry | Contract |
| --- | --- |
| `coroutine.create(f)` | Creates a suspended thread starting at f. |
| `coroutine.resume(co, ...)` | Returns true and yielded/final values, or false and an error. |
| `coroutine.yield(...)` | Suspends with results; a later resume supplies its return values. Errors at non-yieldable boundaries. |
| `coroutine.wrap(f)` | Returns a resume wrapper that yields values directly and raises errors. |
| `coroutine.running()` | Current thread and whether it is the main thread. |
| `coroutine.status(co)` | `running`, `suspended`, `normal`, or `dead`. |
| `coroutine.isyieldable([co])` | Whether the selected/current coroutine can yield under current boundaries. |
| `coroutine.close(co)` | Closes an eligible suspended/dead coroutine, returning true or false/error. |

See [section 2.7](language.md#27--coroutines) for error retention and dynamic
no-yield contexts.

#### 7.2.2 — Modules

`require(name)` returns a loaded module and, for a new load, loader data. It
checks `package.loaded`, tries `package.searchers`, invokes a found loader, and
caches its non-nil return (or true if no value was installed). Searchers cover
preloaded modules, source files, and supported shared libraries.

| Entry | Contract |
| --- | --- |
| `package.loaded` | Loaded-module cache. |
| `package.preload` | Name-to-loader table. |
| `package.searchers` | Ordered loader-search functions. |
| `package.path`, `package.cpath` | Semicolon-separated source/native templates; `?` substitutes the module path. |
| `package.config` | Platform path separators and template conventions. |
| `package.searchpath(name, path [, sep [, rep]])` | Resolves a template path or returns nil and attempted-path diagnostics; separator defaults to dot. |
| `package.loadlib(path, init)` | Opens a native library and resolves an initialization symbol, or returns nil/error/where. |

Native module compatibility is limited to the exported C API subset
([section 8.2](compatibility.md#82--embedding-and-native-modules)).

#### 7.2.3 — Strings

String methods are also available through `s:method(...)`. Positions are one
based; negative positions count from the end. Byte operations never require
valid UTF-8.

| Entry | Contract |
| --- | --- |
| `string.byte(s [, i [, j]])` | Returns byte codes in the inclusive range; i defaults to 1, j to i. |
| `string.char(...)` | Constructs bytes from integer codes 0–255. |
| `string.len(s)` | Byte length. |
| `string.sub(s, i [, j])` | Inclusive substring; j defaults to -1. |
| `string.rep(s, n [, sep])` | n copies, with optional separators. |
| `string.reverse(s)` | Reverses bytes. |
| `string.lower(s)`, `string.upper(s)` | Character-case conversion under the runtime locale. |
| `string.find(s, pattern [, init [, plain]])` | Start/end indexes and captures, or nil. Plain true requests literal byte search. |
| `string.match(s, pattern [, init])` | Captures or the whole match, or nil. |
| `string.gmatch(s, pattern [, init])` | Iterator over successive matches. |
| `string.gsub(s, pattern, replacement [, n])` | Replaced string and match count; replacement is string, table, or function. Nil/false replacement keeps a match. |
| `string.format(format, ...)` | Formatted output with percent conversions; `%q` quotes supported scalar values. |
| `string.pack(format, ...)` | Binary string using the packing format below. |
| `string.packsize(format)` | Fixed byte size; variable-size directives error. |
| `string.unpack(format, s [, pos])` | Decoded values followed by the next byte position. |
| `string.dump(f [, strip])` | Implementation binary chunk for a compiled function, optionally without debug information. |

Patterns are byte-oriented patterns, not regular expressions. `.` matches a
byte; `%a %c %d %g %l %p %s %u %w %x %z` denote alphabetic, control, digit,
graphic, lowercase, punctuation, whitespace, uppercase, alphanumeric, hexadecimal,
and zero-byte classes; uppercase class letters complement their class.
`[set]` and `[^set]` combine classes/ranges. `%` quotes a magic character.
`*` repeats zero or more greedily, `+` one or more greedily, `-` zero or more
minimally, and `?` zero or one. `^` and `$` anchor applicable searches.
Parentheses capture; `()` captures a position, `%1`–`%9` match prior captures,
`%bxy` matches balanced delimiters, and `%f[set]` tests a frontier.
Substitution strings use `%0` for the whole match, `%1`–`%9` for captures, and
`%%` for a percent. Pattern callback boundaries are non-yieldable.

Packing formats support `<`, `>`, `=` for endianness; `![n]` for maximum
alignment; `b B h H l L j J T i[n] I[n]` for integer widths/signedness;
`f d n` for floats; `c[n]` for fixed strings; `z` for zero-terminated strings;
`s[n]` for length-prefixed strings; `x` for padding; and `Xop` for alignment to
another directive. Width/range, alignment, and available-input errors are
reported rather than truncating unsupported values. Spaces are ignored.

#### 7.2.4 — UTF-8

| Entry | Contract |
| --- | --- |
| `utf8.char(...)` | Encodes code points as UTF-8 bytes. |
| `utf8.charpattern` | Pattern matching one UTF-8 byte sequence; not full validity checking. |
| `utf8.codes(s [, lax])` | Iterator of byte position/code point; malformed input errors. |
| `utf8.codepoint(s [, i [, j [, lax]]])` | Code points beginning in the inclusive byte interval. |
| `utf8.len(s [, i [, j [, lax]]])` | Code point count or nil and the first invalid position. |
| `utf8.offset(s, n [, i])` | Byte position of the nth code point relative to i; zero finds the containing sequence start. |

Strict decoding rejects surrogate/out-of-range Unicode values. Lax decoding
accepts the extended encoding range supported by the Lua-compatible UTF-8
implementation; malformed byte sequences still fail. Strings themselves remain
unvalidated byte strings.

#### 7.2.5 — Tables

| Entry | Contract |
| --- | --- |
| `table.concat(list [, sep [, i [, j]]])` | Concatenates string/number elements, defaults separator empty and interval 1 through length. |
| `table.insert(list, [pos,] value)` | Inserts at pos (default end), shifting later elements. |
| `table.remove(list [, pos])` | Removes/returns the element (default end), shifting later elements. |
| `table.move(a, first, last, target [, dest])` | Copies an inclusive index range, safely handling overlap; returns destination. |
| `table.pack(...)` | Table of argument positions with `n` preserving total count including nils. |
| `table.unpack(list [, i [, j]])` | Returns elements in an inclusive interval. |
| `table.sort(list [, comp])` | Sorts in place using comp or ordinary `<`; requires a consistent strict ordering and cannot yield through its comparator. |

#### 7.2.6 — Mathematics

`math.pi`, `math.huge`, `math.maxinteger`, and `math.mininteger` are numeric
constants. The following functions are installed:

| Entry | Contract |
| --- | --- |
| `math.abs(x)` | Absolute value. |
| `math.acos(x)`, `math.asin(x)`, `math.atan(y [, x])` | Inverse trigonometric functions in radians; atan's x defaults to 1. |
| `math.cos(x)`, `math.sin(x)`, `math.tan(x)` | Trigonometric functions in radians. |
| `math.deg(x)`, `math.rad(x)` | Radian/degree conversion. |
| `math.exp(x)`, `math.log(x [, base])`, `math.sqrt(x)` | Exponential, logarithm (natural by default), and square root. |
| `math.ceil(x)`, `math.floor(x)` | Integral rounding upward/downward, returning an integer when representable. |
| `math.fmod(x, y)` | Remainder using a quotient truncated toward zero. |
| `math.modf(x)` | Integral and fractional parts. |
| `math.max(x, ...)`, `math.min(x, ...)` | Maximum/minimum using ordinary comparison. |
| `math.tointeger(x)` | Exact integer conversion or nil. |
| `math.type(x)` | `integer`, `float`, or nil for a nonnumber. |
| `math.ult(a, b)` | Unsigned comparison of two integer bit patterns. |
| `math.random()` | Shared generator float in [0,1). |
| `math.random(m [, n])` | Uniform integer from 1 through m or m through n; single zero requests a full-width integer. |
| `math.randomseed([x [, y]])` | Seeds the shared generator and returns the seed components. |

The shared mathematical RNG is distinct from a session's deterministic RNG.
Using it in guards violates purity; isolated narrative analysis blocks it.

#### 7.2.7 — Input and output

`io.stdin`, `io.stdout`, and `io.stderr` are standard file handles. Operations
usually return success or nil/message/error-number; closing and pipe status
follow the relevant system operation.

| Entry | Contract |
| --- | --- |
| `io.open(filename [, mode])` | File handle or error; mode defaults to `r`. Modes include `r w a`, optional `+` and `b`. |
| `io.close([file])` | Closes file/default output. |
| `io.flush()` | Flushes default output. |
| `io.input([file])`, `io.output([file])` | Gets/sets default handle; a filename opens it. |
| `io.read(...)`, `io.write(...)` | Reads/writes through the default handles. |
| `io.lines([filename, ...])` | Line/format iterator; a named file closes at termination. |
| `io.popen(command [, mode])` | Process pipe where supported. |
| `io.tmpfile()` | Temporary file handle. |
| `io.type(value)` | `file`, `closed file`, or nil. |
| `file:close()`, `file:flush()` | Handle operations. |
| `file:read(...)` | Formats `n`, `a`, `l`, `L` (optional leading `*`), or a nonnegative byte count; default line without newline. |
| `file:write(...)` | Writes string/number arguments and returns the handle on success. |
| `file:lines(...)` | Iterator using read formats on an existing handle. |
| `file:seek([whence [, offset]])` | Position relative to `set`, `cur` (default), or `end`, with offset default zero. |
| `file:setvbuf(mode [, size])` | Buffering `no`, `full`, or `line`. |

I/O is external state and is never rolled back by a logical transaction.

#### 7.2.8 — Operating system

| Entry | Contract |
| --- | --- |
| `os.clock()` | Approximate process CPU seconds. |
| `os.date([format [, time]])` | Formatted date or `*t` table; leading `!` requests UTC. |
| `os.time([table])` | Current epoch time or conversion of a date table. |
| `os.difftime(t2, t1)` | Difference in seconds. |
| `os.execute([command])` | Shell availability or command status (success/nil, exit/signal, code). |
| `os.exit([code [, close]])` | Exits the process; not a transactional rollback facility. |
| `os.getenv(name)` | Environment value or nil. |
| `os.remove(path)`, `os.rename(old, new)` | Filesystem mutation with status/error results. |
| `os.setlocale(locale [, category])` | Sets/queries the system locale. |
| `os.tmpname()` | Temporary filename. |

#### 7.2.9 — Debugging

| Entry | Contract |
| --- | --- |
| `debug.debug()` | Interactive diagnostic input. |
| `debug.getinfo([thread,] f_or_level [, what])` | Selected function/frame metadata. |
| `debug.getlocal([thread,] level_or_function, n)` | Local/parameter name and, for a live frame, value; negative n addresses varargs. |
| `debug.setlocal([thread,] level, n, value)` | Replaces a live local and returns its name or nil. |
| `debug.getupvalue(f, n)`, `debug.setupvalue(f, n, value)` | Reads/replaces an upvalue, returning its name when present. |
| `debug.upvalueid(f, n)` | Identity of the captured upvalue cell. |
| `debug.upvaluejoin(f1, n1, f2, n2)` | Makes one compiled closure's upvalue share another cell. |
| `debug.getmetatable(v)`, `debug.setmetatable(v, mt)` | Unprotected metatable access. |
| `debug.getregistry()` | State registry. |
| `debug.getuservalue(u [, n])`, `debug.setuservalue(u, value [, n])` | Userdata uservalue access. |
| `debug.gethook([thread])`, `debug.sethook([thread,] hook, mask [, count])` | Call/return/line/count hooks; mask uses `c`, `r`, `l`. |
| `debug.traceback([thread,] [message [, level]])` | Stack diagnostic. |

Debug metadata and temporary-slot attribution have implementation limitations;
consult section 9 before depending on exact upstream diagnostics.

### 7.3 — Logic library

#### `logic.global`

The state's distinguished global world. It is the default parent of `logic.world`
and the default for declarative code without a lexical world block.

#### `logic.world([parent])`

Returns an independent snapshot of parent, defaulting to global. It copies
schemas/facts/rules and rebinds rules, while preserving referenced object identity.

#### `logic.emptyworld()`

Returns a world with no inherited user program. With standard libraries open,
reserved quality schema configuration still applies.

#### `logic.add(world, name, ...)` · `logic.retract(world, name, ...)`

Insert/retract one base tuple using a dynamic string relation name. All supplied
varargs are tuple elements, including nils. These perform the same validation,
atomicity, transaction, and runtime-constraint checks as syntax operations.
They return no values. Unknown retraction is a no-op. There is no public Lua
programmatic rule/query builder in this edition.

#### `symbol(value)` · `logic.symbol(value)`

Returns a string's interned symbol, or the same symbol if already a symbol.
Other types error. Arbitrary byte names, including empty strings and zeros, are
supported.

#### `logic.symbolname(value)`

Returns a symbol's byte name; other types error.

#### `logic.hasbinding(record, name)` · `logic.binding(record, name)`

Tests binding presence or returns its value in a query record. Nil is a present
value. `binding` errors on an absent name. These operate on query binding records;
ordinary tables are not interchangeable nil-preserving records.

### 7.4 — Narrative library

Section 6 defines lifecycle and atomicity. Unless specified otherwise, mutation
helpers return no values. Initialization functions require an open registry;
effect functions require an active narrative effect.

| Initialization entry | Contract |
| --- | --- |
| `narrative.registry` | Opaque state-owned registry. |
| `narrative.seal([authored_version])` | Validates/freezes content and returns its version string. |
| `narrative.name(symbol, label)` | Registers a stable display label string. |
| `narrative.formatter(function)` | Registers the default display formatter. |
| `narrative.formatter(key, function)` | Registers a formatter by string/symbol key. Duplicate keys error. |
| `narrative.on(kind, handler)` | Registers a unique symbol's event handler `(world, kind, immutable_args)`. |
| `narrative.program(world, version)` | Records a nonempty authored rule-program version/fingerprint for reconstruction. |
| `narrative.new(world)` | Seals registry if needed and returns an independent session owning this world. |

#### `narrative.display(value)`

Returns display text. Formatter functions receive the value; their first string
result is accepted, otherwise lookup falls through. Nil tries the `nil` formatter,
then `default`, then empty text. A symbol tries its exact name formatter, a
registered display label, the `symbol` formatter, `default`, then its raw name.
Other values try the type key (`boolean`, `number`, `string`, or `other`), then
`default`, then primitive conversion. Formatters used in rendering must be pure;
world/session writes and yields are prohibited in that context. Exact-name and
type keys share the same formatter namespace.

#### `narrative.sequence(...)`

Constructs an immutable one-based portable sequence preserving nil positions and
explicit length. Every value is validated. This is the argument container required
by `schedule`; a mutable table is not a substitute.

#### `narrative.template(text, bindings [, world [, selections]])`

Parses and renders an explicit template against a world snapshot, defaulting to
`logic.global`. Bindings accept a table or supported immutable record; use a
record to preserve explicit nil presence. Unknown names error. Selections are a
zero-based variant index or a table of indexes in group order. Without explicit
selection, each group uses its highest-weight alternative. Rendering is read-only
and consumes no RNG. This function returns one string.

| Effect entry | Contract |
| --- | --- |
| `narrative.push_deck(deck)` | Push fresh entry for a known symbol deck. |
| `narrative.pop_deck()` | Pop top entry; cannot remove the last. |
| `narrative.replace_deck(deck)` | Replace active entry with a fresh known deck entry. |
| `narrative.reset_deck()` | Clear active entry's nonreplacement draw history. |
| `narrative.emit(kind, ...)` | Queue a portable event for this transaction's commit. |
| `narrative.schedule(kind, args, after_turns)` | Queue a symbol event with immutable sequence args and nonnegative integer delay. |
| `narrative.translate(tag, {key = text, ...})` | Register a language pack: message keys (`lamp.title`, `lamp.light.title`, `name.keeper`) to template text. The pack is rejected as a whole, with one line per bad key, if any text does not parse. Not content: not fingerprinted, not saved. |
| `narrative.load_pack(directory)` | Load a language pack built by `varis l10n build` (the directory holds `pack.json`); returns its language tag. Accepted or rejected as a whole, as `narrative.translate`. |
| `narrative.particle(word, "은/는")` | The Korean particle form that follows `word` (`은/는`, `이/가`, `을/를`, `과/와`, `으로/로`): the first after a final consonant, the second after a vowel; `으로/로` takes `로` after ㄹ; digits by how they are read. |
| `narrative.graphemes(text)` · `narrative.truncate(text, n)` | The number of grapheme clusters, and the first `n` of them: a combining mark, variation selector, skin tone, joined emoji or flag stays with its base. |
| `narrative.line_breaks(text)` | Immutable sequence of 1-based byte positions where a line may break: after spaces, between wide (Chinese, Japanese, Korean) characters, never before a closing mark, small kana or `ー`, never after an opening bracket, never inside a Latin word. |
| `narrative.ruby(text)` | Immutable sequence of `{text, reading}` spans: `｜東京《とうきょう》` or ideographs directly before `《reading》`; `reading` is nil for plain text. |
| `narrative.languages()` | Immutable sequence of registered language tags. |
| `narrative.defer(callback)` | Request no-argument callback after commit; discarded on rollback. |

#### Session methods

| Entry | Contract |
| --- | --- |
| `session:world()` | Owning world. |
| `session:turn()` | Current visible turn. |
| `session:active_deck()` | Top deck symbol. |
| `session:seed(integer)` | Set and record deterministic session RNG seed at idle boundary. |
| `session:limits(actions, events)` | Set positive integer per-phase budgets; default 1,000 each. |
| `session:set_period(symbol, value)` | Set a portable named period at idle or as a permitted transaction-aware effect write. |
| `session:present()` | Run pre phase and return an immutable presentation; may be empty. |
| `session:choose(token)` | Revalidate/commit exact choice, advance turn, run post phase; no result values. |
| `session:set_language(tag\|nil)` · `session:language()` | The language `present` renders in; nil is the source language. A host preference: not saved, no input to eligibility, draws or replay. |
| `session:render(presentation [, tag])` | The same presentation with titles and texts in `tag` (nil or omitted: the source language). Draws nothing, issues no token, writes nothing; choices keep their tokens. |
| `session:save()` | Canonical versioned JSON string at idle boundary. |
| `session:record_input(symbol, value)` | Record portable external input at idle, without applying it. |
| `session:replay_log()` | Immutable record with runtime, content, program, schema, and inputs. |

Presentation shapes, token validity, and failure behavior are specified in
[sections 6.3–6.6](narrative.md#63--choices-lexical-binding-and-tokens).

#### `narrative.load(saved, world_factory [, migration])`

Validates saved text against an authored factory world and returns a restored
session from a staged snapshot. Factory world is unchanged. Optional migration
runs only on incompatibility, receives `(saved, target_versions)`, and returns
exactly one replacement string. Full validation is repeated. See section 6.9 for
reconstruction and portable-value limits.

#### `narrative.explain(session, content_symbol [, bindings])`

Returns immutable eligibility and policy diagnostics. Bindings may be a table or
supported query/presentation record; unknown parameter names and nonportable
instance bindings error. It does not mutate state or consume RNG. This is a
conjunction-prefix explanation, not a full recursive proof.

#### `narrative.observe(world, relation_name, callbacks)`

Registers `on_enter`/`on_leave` functions for committed visible-set deltas and
returns a cancellation function. Name accepts a string or symbol. Callbacks
receive one immutable tuple sequence. Existing membership is not delivered;
rollback/no-op visible changes produce no callback. See section 6.10 for ordering,
write restrictions, callback errors, and nonserialization.

#### `narrative.enqueue(callback)` · `narrative.flush(world [, positive_limit])`

Enqueue is available from the current notification callback. Flush executes
queued work later at an idle boundary, with default limit 1,000; recursive flush
is rejected. `OBSERVER_QUEUE_LIMIT` preserves pending entries and prior work.
A failed command is removed before invocation and its error propagates.

#### `narrative.analyze(session [, options])`

Returns immutable bounded cloned-choice exploration. Options are integer fields
`depth`, `max_nodes`, `max_steps`, and `max_objects`. Defaults and scope limits
are in section 6.10. Check report completeness and diagnostics before drawing
reachability conclusions.

### 7.5 — Quality library

| Entry | Contract |
| --- | --- |
| `quality.define(name, metadata)` | Register symbol metadata before sealing; allowed fields initial/minimum/maximum/visible/label. Inserts no tuples. |
| `quality.initialize(entity, name [, world])` | Insert initial value only when absent. |
| `quality.get(entity, name [, world])` | Actual value or nil; no implicit initialization/default. |
| `quality.set(entity, name, value [, world])` | Atomic constrained keyed replacement. |
| `quality.add(entity, name, delta [, world])` | Atomic constrained numeric adjustment of an existing tuple. |

Names must be declared symbols. All writes enforce metadata, even through direct
relational operations. Omitted world means global outside effects and lexical
call world inside effects; explicit world writes still obey transaction ownership.
Quality mutation functions return no values. Presence of an initialized nil must
be checked relationally, not by the return from get.
