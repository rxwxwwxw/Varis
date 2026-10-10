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
                 | factstat | retractstat | relationstat | localrelstat
                 | rulestat | worldstat | setstat | deletestat | adjuststat
                 | transactionstat | rollbackstat
                 | storyletdef | actiondef | deckdef

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
                 | queryexp | exp binop exp | unop exp
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
relationstat   ::= 'relation' Name '(' Integer ')'
                 | 'relation' Name '(' [ namelist ] ')'
                   [ 'key' '(' namelist ')' ]
localrelstat   ::= 'local' 'relation' Name '(' Integer ')'
rulestat       ::= 'rule' relref '(' [ headargs ] ')' ':-' goals
worldstat      ::= 'logic' '(' exp ')' 'do' block 'end'
queryexp       ::= 'query' relatom | 'query' '{' goals '}'
goals          ::= goal { ',' goal }
goal           ::= relatom | 'not' relatom
                 | term relop term
                 | 'where' '(' guardexp ')'
                 | aggregategoal
relop          ::= '==' | '~=' | '<' | '<=' | '>' | '>='
aggregategoal  ::= logicvar '=' 'count' '{' goals '}'
                 | logicvar '=' valueaggregate '{' aggregateexp ':' goals '}'
valueaggregate ::= 'sum' | 'min' | 'max'
```

`?_` is lexically a logic-variable form but is interpreted as a fresh anonymous
occurrence, and is disallowed in heads, comparisons, guards, and result positions.
`guardexp` and `aggregateexp` use ordinary expression syntax extended with logic
variable references. Ordinary `exp` constant terms must not contain logic
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
adjuststat     ::= 'adjust' relref '(' [ explist ] ')' 'by' exp
transactionstat ::= 'transaction' [ '(' exp ')' ] 'do' block 'end'
rollbackstat   ::= 'rollback'

params         ::= logicvar { ',' logicvar }
whenclause     ::= 'when' '{' goals '}'
storyletdef    ::= 'storylet' Name '(' [ params ] ')' whenclause
                   { storyletfield } choicedef { choicedef } 'end'
storyletfield  ::= 'deck' exp | 'priority' exp | 'weight' exp
                 | 'cooldown' exp | 'repeatable' exp | 'sticky' exp | 'order' exp
                 | 'title' LiteralString | 'text' LiteralString
choicedef      ::= 'choice' Name [ '(' [ params ] ')' ] [ whenclause ]
                   { choicefield } 'effect' 'do' block 'end' 'end'
choicefield    ::= 'title' LiteralString | 'text' LiteralString
actiondef      ::= 'action' Name '(' [ params ] ')' whenclause
                   { actionfield } 'effect' 'do' block 'end' 'end'
actionfield    ::= 'phase' exp | 'priority' exp | 'once_per' exp
deckdef        ::= 'deck' symbol tableconstructor
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
| `{#variant [weight]}a{#variant [weight]}b{/variant}` | Weighted alternatives; brackets here mean optional numeric weight. |
| `{#variant [weight]}a{#else}b{/variant}` | Alternative b has default weight one. |
| `{#variants}{#variant [weight]}a{/variant}...{/variants}` | Explicit grouped alternatives. |

Weights can also use `weight=number`. Conditional/variant groups may nest;
placeholders and query scopes are validated. Explicit selection indexes are zero
based; immutable sequence indexes and source string/table indexes are one based.
