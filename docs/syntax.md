# Varis Reference Manual — Syntax

[Contents](README.md) · [Language](language.md) · [Relations](relations.md) · [Narrative](narrative.md)

## 10 — Complete syntax

`::=` defines a production, `|` separates alternatives, `[ ... ]` is optional,
and `{ ... }` repeats zero or more times. Quoted text is a literal token.
`Name`, `Integer`, `Numeral`, and `LiteralString` are lexical categories. `Integer`
in arity declarations is a nonnegative integer token, not a computed expression.
Literal strings include short quoted and long-bracket strings. Grammar alone
does not express scope, required fields, safety, type/value constraints, ownership,
or stratification; the preceding chapters impose those conditions.

### 10.1 — Procedural grammar

```ebnf
chunk          ::= block
block          ::= { stat } [ retstat ]
retstat        ::= 'return' [ explist ] [ ';' ]

stat           ::= ';'
                 | varlist '=' explist
                 | functioncall
                 | label
                 | 'break'
                 | 'goto' Name
                 | 'do' block 'end'
                 | 'while' exp 'do' block 'end'
                 | 'repeat' block 'until' exp
                 | 'if' exp 'then' block
                   { 'elseif' exp 'then' block } [ 'else' block ] 'end'
                 | 'for' Name '=' exp ',' exp [ ',' exp ] 'do' block 'end'
                 | 'for' namelist 'in' explist 'do' block 'end'
                 | 'function' funcname funcbody
                 | 'local' 'function' Name funcbody
                 | 'local' attnamelist [ '=' explist ]
                 | varstat | symbolsstat | factstat | retractstat | relationstat | localrelstat
                 | rulestat | worldstat | setstat | deletestat | adjuststat
                 | transactionstat | rollbackstat
                 | storyletdef | actiondef | proceduredef | deckdef | scenedef | characterdef

attnamelist    ::= Name [ attrib ] { ',' Name [ attrib ] }
attrib         ::= '<' Name '>'
label          ::= '::' Name '::'
funcname       ::= Name { '.' Name } [ ':' Name ]
varlist        ::= var { ',' var }
var            ::= Name | prefixexp '[' exp ']' | prefixexp '.' Name
namelist       ::= Name { ',' Name }
explist        ::= exp { ',' exp }

exp            ::= 'nil' | 'false' | 'true' | Numeral | LiteralString | '...'
                 | functiondef | prefixexp | tableconstructor | symbol
                 | queryexp | existsexp | exp binop exp | unop exp
prefixexp      ::= var | functioncall | '(' exp ')'
functioncall   ::= prefixexp args | prefixexp ':' Name args
args           ::= '(' [ explist ] ')' | tableconstructor | LiteralString
functiondef    ::= 'function' funcbody
funcbody       ::= '(' [ parlist ] ')' block 'end'
parlist        ::= namelist [ ',' '...' ] | '...'
tableconstructor ::= '{' [ fieldlist ] '}'
fieldlist      ::= field { fieldsep field } [ fieldsep ]
field          ::= '[' exp ']' '=' exp | Name '=' exp | exp
fieldsep       ::= ',' | ';'
binop          ::= '+' | '-' | '*' | '/' | '//' | '^' | '%'
                 | '&' | '~' | '|' | '>>' | '<<' | '..'
                 | '<' | '<=' | '>' | '>=' | '==' | '~=' | 'and' | 'or'
unop           ::= '-' | 'not' | '#' | '~'
```

The only local attributes defined here are `const` and `close`. Operator
precedence is given in section 3.4, rather than encoded by this compact expression
production. Contextual constructs are recognized by their full forms, preserving
ordinary identifier calls/assignments and method/label syntax.

### 10.2 — Relational grammar

```ebnf
symbol         ::= ':' Name
logicvar       ::= '?' Name
anonymous      ::= '?' '_'

relref         ::= Name | worldpath '.' Name
worldpath      ::= Name { '.' Name }
relatom        ::= relref '(' [ terms ] ')'
terms          ::= term { ',' term }
term           ::= logicvar | exp
headargs       ::= headterm { ',' headterm }
headterm       ::= logicvar | exp

factstat       ::= 'fact' relref '(' [ explist ] ')'
retractstat    ::= 'retract' relref '(' [ explist ] ')'
varstat        ::= 'var' Name '=' exp          (* contextual; sugar for narrative.var(:Name, exp) *)
symbolsstat    ::= 'symbols' Name { ',' Name } (* contextual; declares symbols, runs nothing *)
relationstat   ::= 'relation' Name '(' Integer ')'
                 | 'relation' Name '(' [ namelist ] ')'
                   [ 'key' '(' namelist ')' ]
localrelstat   ::= 'local' 'relation' Name '(' Integer ')'
rulestat       ::= 'rule' relref '(' [ headargs ] ')' ':-' goals
worldstat      ::= 'logic' '(' exp ')' 'do' block 'end'
queryexp       ::= 'query' relatom | 'query' '{' goals '}'
existsexp      ::= 'exists' '{' goals '}'      (* contextual; true when the query has a match *)
goals          ::= goal { ',' goal }
goal           ::= relatom | 'not' relatom
                 | term relop term
                 | 'where' '(' guardexp ')'
                 | '(' guardexp 'or' guardexp { 'or' guardexp } ')'
                 | aggregategoal
                 | computedgoal
computedgoal   ::= logicvar ':=' aggregateexp
relop          ::= '==' | '~=' | '<' | '<=' | '>' | '>='
aggregategoal  ::= logicvar '=' 'count' '{' goals '}'
                 | logicvar '=' valueaggregate '{' aggregateexp ':' goals '}'
valueaggregate ::= 'sum' | 'min' | 'max'
```

`?_` is lexically a logic-variable form but is interpreted as a fresh anonymous
occurrence, and is disallowed in heads, comparisons, guards, and result positions.
`guardexp` and `aggregateexp` use ordinary expression syntax extended with logic
variable references. A parenthesized group with an `or` at its own level is a guard:
it is the same as `where( ... )` and its alternatives are tried left to right (§4.6a). Ordinary `exp` constant terms must not contain logic
variables. Head variables and comparison operands must satisfy the restrictions
in section 4; compound logical terms and computed variable-dependent heads are
not defined. Every relational constant expression supplies exactly one value.

Goals have no trailing comma. A rule ends when its last complete goal is no
longer followed by a comma continuing the body; no period or newline delimiter
is required. Braced queries have at least one goal. Empty tuple argument lists
are legal and distinct from an empty goal list.

### 10.3 — Stateful and narrative grammar

```ebnf
setstat        ::= 'set' relref '(' [ explist ] ')'
deletestat     ::= 'delete' relref '(' [ explist ] ')'
adjuststat     ::= 'adjust' relref '(' [ explist ] ')' 'by' exp [ 'clamp' ]
transactionstat ::= 'transaction' [ '(' exp ')' ] 'do' block 'end'
rollbackstat   ::= 'rollback'

params         ::= logicvar { ',' logicvar }
whenclause     ::= 'when' '{' goals '}'
exposeclause   ::= 'expose' logicvar { ',' logicvar }
storyletdef    ::= 'storylet' Name '(' [ params ] ')' whenclause [ exposeclause ]
                   { storyletfield } choicedef { choicedef } 'end'
storyletfield  ::= 'deck' exp | 'priority' exp | 'weight' exp
                 | 'cooldown' exp | 'repeatable' exp | 'sticky' exp | 'order' exp
                 | 'title' LiteralString | 'text' LiteralString
choicedef      ::= 'choice' Name [ '(' [ params ] ')' ] [ whenclause ] [ exposeclause ]
                   { choicefield } 'effect' 'do' block 'end' 'end'
choicefield    ::= 'title' LiteralString | 'text' LiteralString
                 | 'require' '{' goals '}' | 'because' LiteralString
                 | 'leads' symbol
proceduredef   ::= 'procedure' Name '(' [ params ] ')' 'effect' 'do' block 'end' 'end'
actiondef      ::= 'action' Name '(' [ params ] ')' whenclause [ exposeclause ]
                   { actionfield } 'effect' 'do' block 'end' 'end'
actionfield    ::= 'phase' exp | 'priority' exp | 'once_per' exp
deckdef        ::= 'deck' symbol tableconstructor
scenedef       ::= 'scene' Name tableconstructor
                 | 'scene' Name '(' ')' { scenestmt } 'end'
scenestmt      ::= 'say' Name [ 'with' attrs ] 'id' Name LiteralString
                 | 'narrate' 'id' Name LiteralString
                 | 'show' Name 'at' exp [ 'with' attrs ] | 'hide' Name
                 | 'background' exp | 'audio' Name ( exp | 'off' )
                 | ( 'pause' | 'transition' | 'screen' | 'picture' ) tableconstructor
                 | 'input' Name 'id' Name LiteralString [ 'with' attrs ]
                 | 'set' Name '=' exp
                 | 'if' Name cmpop exp 'then' { scenestmt }
                   { 'elseif' Name cmpop exp 'then' { scenestmt } }
                   [ 'else' { scenestmt } ] 'end'
                 | 'menu' { 'option' Name LiteralString 'do' { scenestmt } 'end' } 'end'
                 | 'effect' Name '(' [ Name '=' ( Name | exp ) { ',' ... } ] ')'
                 | 'effect' 'using' Name { ',' Name } 'do' block 'end'
                 | ( 'jump' | 'call' ) Name | 'return' | 'ended'
attrs          ::= Name '=' exp { ',' Name '=' exp }
cmpop          ::= '==' | '~=' | '<' | '<=' | '>' | '>='
characterdef   ::= 'character' Name tableconstructor
```

Required fields, field uniqueness, scalar parameter identity, and binding safety
are semantic constraints. Storylet fields precede choices; choice/action fields
precede their effects. `end` closes both an effect block and its enclosing choice
or action. Deck option keys are `draw` and `replacement`. Named relation schemas
are world-owned; local named/keyed declaration syntax is not implemented.

### 10.4 — Template notation

Template notation is interpreted after a string is parsed, only in template
fields and explicit template calls. It does not extend ordinary string escapes.

| Form | Meaning |
| --- | --- |
| `{name}` | Display a declared exposed binding. |
| `{{`, `}}` | Literal opening/closing brace. |
| `{#if query ...}yes{#else}no{/if}` | Query-existence conditional; else optional. |
| `{#if lua expr}yes{#else}no{/if}` | Read-only Lua expression over the parameters, by Lua truthiness. |
| `{$name}` | The story variable `name` (`var name = v`). |
| `{>name}` | Text of `narrative.fragment(:name, ...)`, expanded at registration. |
| `{#variant [weight]}a{#variant [weight]}b{/variant}` | Weighted alternatives; brackets here mean optional numeric weight. |
| `{#variant [weight]}a{#else}b{/variant}` | Alternative b has default weight one. |
| `{#variants}{#variant [weight]}a{/variant}...{/variants}` | Explicit grouped alternatives. |
| `{#variant 3 wind}a{#variant gulls}b{/variant}` | Named weighted alternatives; names preserve translated/replayed selection identity. |
| `{#plural n}{#one}a{#other}b{/plural}` | Select a locale plural category; `other` is required. |
| `{#select v}{#case value}a{#default}b{/select}` | Select by parameter value; `default` is required. |

Weights can also use `weight=number`. Plural categories include `zero`, `one`, `two`,
`few`, `many`, and `other`; applicable rules depend on the message language (§6.6).
Conditional, variant, plural and select groups may nest;
placeholders and query scopes are validated. Explicit selection indexes are zero
based; immutable sequence indexes and source string/table indexes are one based.

### 10.5 — Status of the syntax (milestone 27)

The grammar in 10.1–10.4 is the **v1 syntax of what is implemented**: every production
there runs, is tested, and is described in the chapters above. A new construct enters the
manual in the change that implements and tests it; a proposal that has not landed is not in
this chapter. The rules the triage applied:

- one obvious way to write a thing: an accepted construct does not get a second spelling
  (`exists { … }` and `logic.one` rather than several query-result shortcuts);
- new words are contextual: `symbols`, `expose`, `leads`,
  `clamp`, `exists` and the `:=` of a computed binding are recognized only in their full
  forms, so ordinary identifiers, calls, assignments, method colons and labels keep their
  meaning (a local named `symbols` or a function named `clamp` still works);
- nothing in content requires understanding closures, iterators or metatables.

The localization decisions that were part of the freeze are in place: message keys come
from authored names and line ids (6.6, 8.4), one template grammar with named placeholders
(10.4), a select/plural construct and named variants, literal display text in content files
(`computed-text` is reported), and wording kept out of the content identity (6.9).

| Construct | State |
| --- | --- |
| Procedural core (10.1) | Frozen: Lua 5.4. |
| Facts, rules, queries, aggregates, guards, local relations, worlds (10.2) | Frozen. |
| `?x := expr`, `(a or b)` alternatives, `exists { … }`, `logic.one` | Implemented, in 10.2 and 4.6a/4.8a. |
| `set`/`delete`/`adjust … by … [clamp]`, transactions (10.3) | Frozen. |
| `expose ?x`, `leads :deck`, `require … because`, `symbols a, b` | Implemented, in 10.3 and 6.2/6.3/6.5. |
| Storylets, choices, actions, procedures, decks, scenes, characters, template notation | Frozen as written in 10.3–10.4. |
| Readable procedural scene bodies (`scene greeting()`, `say … id …`, `show … at …`, `menu`, `if`, `effect`) | Implemented (milestone 29), manual 6.11a; they lower to the beat tables of 6.11. |
| Explicit scene-scoped text ids | Implemented: every `say`, `narrate` and `input` in a readable scene must carry `id name`; tables keep legacy and generated ids. |
| Readable `input` statements | Implemented (`input visitor id ask "Name?" with min_length = 1`). |
| Compound relation values and destructuring; a separate `passage` kind; mixed scene/storylet beat streams; timed choices; parser-style input; `session:status`; `session:choose_by`; correlated nested `exists`/`not`; binding-producing `or`; unordered `first` | Deferred. |
| Lua expressions in template conditions beyond `{#if lua …}`; click-to-replace prose | Deferred / host-level. |

The disposition of each proposal, with its reason, is the table in
[sample-game/needed_extensions.md](../sample-game/needed_extensions.md); the order and the
owner's decisions are in [ROADMAP.md](../ROADMAP.md).
