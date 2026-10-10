# Varis Reference Manual — Language

[Contents](README.md) · [Relations and state](relations.md) · [Libraries](libraries.md)

## 1 — Introduction

A Varis program can compute values with functions and tables, describe finite
relations with facts and rules, and execute state changes in transactions.
Narrative definitions add choices and scheduled effects over those same worlds.
Inference determines what is true. Effects change state only when procedural
execution or the narrative scheduler invokes them.

```lua
fact edge(:a, :b)
fact edge(:b, :c)
rule path(?x, ?y) :- edge(?x, ?y)
rule path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)
for row in query path(:a, ?destination) do
    print(row.destination)
end
```

This program prints `:b` and `:c` in an unspecified order. `:a` is a symbol,
`?destination` is a logic variable, and `row` is an ordinary local variable.
A relation and a function can share a name because they occupy separate
namespaces. Facts and rules execute when control reaches their statements.

## 2 — Basic concepts

### 2.1 — Values and types

Variables hold values without a declared type. The primitive types reported by
`type` are `nil`, `boolean`, `number`, `string`, `symbol`, `table`, `function`,
`userdata`, and `thread`. Worlds, sessions, immutable records, and immutable
sequences are opaque runtime objects exposed through userdata; they are not
ordinary mutable tables.

`nil` denotes absence in ordinary variables and table fields. Booleans are
`false` and `true`. Only `nil` and `false` are false in conditions. Zero, the empty
string, empty tables, query iterators, and empty records are true.

Numbers have two representations: signed 64-bit integers and double-precision
floating-point values. `math.type` distinguishes them. Integral floats and equal
integers compare numerically equal when their mathematical values coincide;
comparison must not lose integer precision by converting both sides to floats.
Integer arithmetic wraps modulo 2^64. Floating-point arithmetic can produce
infinities and NaN. NaN is unequal to every value, including itself, and is
prohibited in relational tuples and captured relational constants. Portable
narrative values also exclude infinities.

Strings are immutable byte sequences. Lengths and ordinary string indexes count
bytes; embedded zero bytes are valid. UTF-8 interpretation is supplied explicitly
by `utf8`. Tables are mutable maps. Keys may be any value except `nil` and NaN;
setting a field to `nil` removes it. An integral floating-point key is normalized
to its corresponding integer key. Tables, functions, userdata, and threads are
reference values: assignment and parameter passing preserve identity and do not
copy their contents.

### 2.2 — Symbols

A symbol is an immutable interned byte name, distinct from a string. `:room` is a
literal; `symbol("room")` constructs the same value. `type(:room)` is `"symbol"`.
A name may be empty or contain arbitrary bytes through `symbol`, even when it
cannot be written as a literal. Interning is shared across worlds in one state.
Symbols support equality and table keys, but primitive ordering is an error.
Compare `logic.symbolname` results when an ordering of names is needed.

`tostring` prints a colon followed by an identifier name, or a quoted name for
other byte strings. Narrative display labels are a separate facility and do not
change symbol identity or `tostring`.

### 2.3 — Environments and visibility

A free ordinary name `x` is an access to `_ENV.x`. Each loaded chunk has an `_ENV`
upvalue, normally the global table. `_G` refers to that initial table; rebinding
`_G` does not change another closure's environment. Locals and parameters use
lexical scope. Nested functions capture upvalues and keep them alive after the
outer call returns. A local declaration becomes visible after its initializer;
`local function f(...) ... end` allows recursive references to its own binding.

Relations have a separate lexical namespace and default world
([section 4.2](relations.md#42--worlds-and-relation-resolution)). Ordinary `_ENV`
and a lexical default world solve different name-resolution problems. Narrative
availability and effect bodies receive their session world explicitly.

### 2.4 — Errors

An error interrupts execution and unwinds to the nearest protected call.
`error(value)` can raise any value, including a non-string object. `pcall` returns
`true` followed by results on success, or `false` and the error object on failure.
`xpcall` additionally invokes an error handler. A caught error does not undo
previous ordinary assignments, I/O, or committed logical changes.

Transactions undo their own tentative logical and narrative changes when an
error escapes them. An error caught inside the transaction does not exit it.
Failed individual fact/update/rule operations publish none of that operation's
logical changes, including implicit declarations. Inference errors invalidate the
iterator that encountered them; earlier successful program mutations remain.

### 2.5 — Metatables

A metatable can customize ordinary operations on tables and userdata. A table's
metatable is set with `setmetatable`; `__metatable` protects ordinary inspection
and replacement. The debug library can bypass that protection and is intended
for trusted diagnostics.

| Event | Metamethods and behavior |
| --- | --- |
| Missing indexing | `__index`: table lookup or function `(object, key)` |
| Assignment to missing field | `__newindex`: table assignment or function `(object, key, value)` |
| Arithmetic | `__add`, `__sub`, `__mul`, `__div`, `__idiv`, `__mod`, `__pow`, `__unm` |
| Bit operations | `__band`, `__bor`, `__bxor`, `__bnot`, `__shl`, `__shr` |
| Concatenation and length | `__concat`, `__len` |
| Ordinary comparisons | `__eq`, `__lt`, `__le` where primitive operations do not decide the result |
| Calling | `__call`; the called object is prepended to the arguments |
| Conversion and iteration | `__tostring`, `__pairs` |
| Resource lifetime | `__close`, `__gc`; weak references use `__mode` |

Raw table access bypasses indexing metamethods. Relational equality, joins, keys,
and comparisons bypass equality and ordering metamethods entirely. Relational
ordering accepts primitive numbers or strings only.

### 2.6 — Collection and resources

The runtime uses D's collector and emulates weak tables, ephemerons, and
finalizers. Unreachable objects can be reclaimed without explicit deallocation,
but collection timing and exact memory counts are not language guarantees.
`__mode = "k"`, `"v"`, or `"kv"` requests weak table entries. A `__gc` finalizer
provides eventual cleanup; use to-be-closed locals for deterministic scope cleanup.
Exact Lua collector reachability and tuning are outside the compatibility claim
([section 9](compatibility.md#9--compatibility-and-implementation-limits)).

A local declared with `<close>` closes on normal or error exit, in reverse order
of declaration. A non-nil, non-false value must support `__close`. Its close
handler receives the value and the active error, or nil on normal exit.
`<close>` locals are not assignable. `<const>` locals likewise cannot be assigned
after initialization, including through a nested closure. A close error can
replace the active error. Transaction cleanup includes scoped close handlers
before deciding commit or rollback.

### 2.7 — Coroutines

Coroutines suspend execution with `coroutine.yield` and resume with
`coroutine.resume`; arguments and results cross the suspension point. Resuming a
coroutine is synchronous. The runtime preserves separate call stacks and lexical
contexts for each coroutine. Query iterators retain their original snapshots
between calls, even when other coroutines commit changes meanwhile.

An unprotected coroutine error retains suspended frames and close handlers until
`coroutine.close`. Protected errors unwind at their handler. Closing prohibits
yielding and reentrant close, unwinds resources, and reports the retained or
replacement error; a later close does not repeat that error.

Inference guards, transactions, read-only narrative evaluation, and observer
callbacks prohibit yielding, including indirectly through helper functions or a
synchronously resumed child coroutine. `coroutine.isyieldable()` reflects these
dynamic restrictions and restores its prior behavior when they end. Sort and
string-substitution callbacks also have non-yieldable boundaries.

## 3 — The procedural language

### 3.1 — Lexical conventions

Names are case-sensitive identifiers beginning with a letter or underscore and
continuing with letters, digits, or underscores. The following words are reserved:

```text
and break do else elseif end false for function goto if in
local nil not or repeat return then true until while
```

Other language words are contextual: `fact`, `retract`, `relation`, `rule`,
`query`, `where`, `logic`, `key`, `set`, `delete`, `adjust`, `by`, `transaction`,
`rollback`, `storylet`, `choice`, `action`, `deck`, `when`, `effect`, `phase`,
`priority`, `weight`, `cooldown`, `repeatable`, `sticky`, `order`, `title`, `text`, `once_per`,
`count`, `sum`, `min`, and `max`. They remain identifiers in ordinary calls,
assignments, fields, methods, and labels. Full construct recognition decides
whether a contextual word introduces special syntax.

Whitespace separates tokens but does not terminate statements. `--` starts a
line comment; `--[[...]]` and equal-delimited long brackets form long comments.
A semicolon may separate statements. Long strings use `[[...]]`, `[=[...]=]`, and
matching equal counts; an initial newline after the opener is omitted.

Short strings use single or double quotes. Escapes include `\a \b \f \n \r \t \v`,
backslash, quotes, a backslash followed by a newline, `\z` to skip subsequent
whitespace, decimal byte escapes (up to three digits), `\xHH`, and `\u{...}`.
Decimal and hexadecimal numerals support fractional and exponent parts; decimal
exponents use `e`, hexadecimal exponents use `p`. A numeral's representation is
integer when the integer lexical form fits the applicable integer rules,
otherwise floating point.

`:name` introduces a symbol in expression position, `?name` a logic variable in
declarative contexts, and `:-` a rule body. `object:method()` and `::label::`
retain their ordinary meanings. Logic variables are not permitted as ordinary
procedural expressions outside declarative guards and aggregate expressions.

### 3.2 — Variables and assignment

Variables are locals, upvalues, globals through `_ENV`, and indexed fields.
`t.name` abbreviates `t["name"]`. Assignment computes the right-hand values and
assigns them to the targets; missing values become nil and excess values are
discarded. Multiple assignment evaluates its expressions before publishing the
assignments. A local initializer uses the previously visible bindings.

```lua
local x, y = 10, 20
x, y = y, x
local t = { name = "Varis", [2] = :room }
```

### 3.3 — Blocks and control flow

A chunk is an executable block, compiled as a function with varargs. Blocks
contain statements and an optional final `return`. `do ... end` introduces a
scope. `if ... then ... elseif ... else ... end`, `while ... do ... end`, and
`repeat ... until condition` use ordinary truthiness. The repeat condition can
see locals declared in its body.

`break` leaves the innermost loop. `goto name` transfers to a visible label
`::name::` without entering the scope of a local. Leaving a scope closes its
resources and upvalues; leaving a transaction through non-error control flow
commits it. `return` leaves a function with zero or more values.

Numeric `for name = initial, limit [, step] do ... end` evaluates its bounds once
and uses an inclusive limit; step defaults to one and must not be zero. Generic
`for names in explist do ... end` adjusts the initial list to iterator, state,
control, and closing value. It repeatedly calls the iterator with state and
control, stopping when its first result is nil. Each iteration has its own scoped
locals; the fourth initial value is closed when the loop exits. Query iterators
are directly usable in this form.

### 3.4 — Operators

Arithmetic operators are `+ - * / // % ^` and unary `-`. `/` and `^` use floating
arithmetic; `//` rounds the quotient downward; `%` uses that floor quotient.
Bit operations `& | ~ << >>` and unary `~` require integers or exactly convertible
integral floats, use 64-bit words, and shift in zero bits. Negative shift counts
reverse direction; shifts by at least the word width yield zero.

Ordinary comparison operators are `== ~= < > <= >=`. Equality follows primitive
value equality or the applicable metatable event; unlike relational matching,
ordinary table/userdata equality can call `__eq`. Ordering supports primitive
numbers and strings, or applicable metamethods. String ordering is byte based.

`not` yields a Boolean. `a and b` returns `a` if falsey and otherwise evaluates and
returns `b`; `a or b` returns `a` if truthy and otherwise evaluates and returns
`b`. They short-circuit and return operands. `..` concatenates strings or numeric
string representations, with metamethod fallback. `#` counts string bytes or
finds a table border, with `__len` where applicable. A table with holes can have
multiple borders; do not rely on one particular length for such a table.

From lowest to highest precedence:

```text
or
and
< > <= >= ~= ==
|
~                 (binary exclusive or)
&
<< >>
..
+ -
* / // %
not # - ~         (unary)
^
```

Exponentiation and concatenation associate right; other binary operators
associate left. Parentheses override precedence and adjust a multiple-result
expression to one value.

### 3.5 — Constructors, calls, and functions

`{}` constructs a table. Fields may be `[expression] = expression`,
`name = expression`, or list expressions numbered from one; commas and semicolons
separate fields and a trailing separator is allowed. A final list call or vararg
may contribute multiple values.

`f(arguments)` calls a value. `f "text"` and `f { fields }` are single-argument
forms. `object:method(args)` supplies `object` as the first argument without
evaluating the receiver twice. A function call can be a statement with its
results discarded. Functions are declared with `function ... end`, global or
field function statements, or `local function`. Method definitions implicitly
add a `self` parameter. Parameters are locals; extra arguments are discarded
unless captured by `...`, and missing arguments are nil.

A call or `...` in the final position of an ordinary argument list, return list,
assignment list, or constructor list field contributes all its results. Other
positions contribute one value. Parentheses force one result. A direct returned
call supports tail transfer, subject to resource cleanup. Relational argument
lists deliberately differ: every syntactic constant expression contributes
exactly one value, including the final call or vararg.

### 3.6 — Declarative and narrative integration

Facts, updates, rules, world blocks, transactions, and content declarations are
statements alongside ordinary control flow. Queries are expressions that return
callable snapshot iterators. Logic variables in rules and queries have their own
scopes. Content parameters become read-only ordinary locals in their nested
effects. The following chapters define these facilities in full rather than
requiring a separate extension dialect.
