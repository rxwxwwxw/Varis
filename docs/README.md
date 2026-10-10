# Varis Reference Manual

**Current interpreter edition · October 10, 2026**

Varis is a dynamically typed language combining procedural programming, finite
relational inference, transactional state, and a deterministic narrative runtime.
Its procedural foundation comes from Lua 5.4. This manual defines the language
implemented in this repository, including the facilities previously described as
Lua extensions.

The language name is **Varis**. The implementation is still built as `bin/varis`,
uses `.lua` source files and `varis` D modules, and reports a Lua compatibility
version. Those implementation names have not yet been migrated. This manual does
not introduce a `varis` command, a new extension for source files, or new syntax
for existing features.

## Contents

1. [Introduction and basic concepts](language.md#1--introduction)
2. [Values, environments, errors, metatables, and coroutines](language.md#2--basic-concepts)
3. [The procedural language](language.md#3--the-procedural-language)
4. [Relations, worlds, rules, and queries](relations.md#4--relational-computation)
5. [Keyed state and transactions](relations.md#5--state-and-transactions)
6. [Narrative definitions and execution](narrative.md#6--narrative-programming)
7. [The standard libraries](libraries.md#7--standard-libraries)
8. [The interpreter and host interfaces](compatibility.md#8--the-interpreter-and-host-interfaces)
9. [Compatibility and implementation limits](compatibility.md#9--compatibility-and-implementation-limits)
10. [Complete syntax](syntax.md#10--complete-syntax)

[Runnable examples](examples/README.md) accompany the reference. The chapters
form one manual; they are not independent extension specifications. Section
numbers are unique across chapters. Function signatures use brackets for optional
arguments and `...` for variable argument lists; brackets are not literal syntax.
Grammar notation is explained in section 10.

## Authority and maintenance

This directory is the single source of truth for current Varis language
semantics. It supersedes `LANGUAGE_EXTENSIONS.md` and `LANGUAGE_EXTENSIONS2.md`.
`LANGUAGE_EXTENSIONS_PLAN.md` remains an engineering history and roadmap, not a
second language definition. Unimplemented proposals in `sample-game/needed_extensions.md` and
`sample-game/extensions/proposed.lua` are not part of Varis. Implemented additions
such as `sticky` and `order` are included in this manual.

Descriptions state the current contract. Detected errors are ordinary language
errors unless an entry says otherwise. Requirements on guard purity and host
reconstruction cannot all be checked automatically; their limits are stated
where they apply. A discrepancy between this manual and implementation should be
reported and resolved explicitly, with executable evidence, rather than treating
an old proposal or an accidental implementation behavior as another authority.

Conformance evidence remains separate from the reference:

- [Requirement-to-test index](../tests/TRACEABILITY.md), with stable historical
  `V1` and `C2` requirement identifiers.
- [Stateful and narrative audit](../tests/narrative/README.md).
- [Lua compatibility audit](../tests/official/README.md).
- [Coverage migration map](coverage.md), connecting former specification sections
  and requirement identifiers to this manual.

The organization follows the reference-manual tradition of the
[Lua 5.4 Reference Manual](https://www.lua.org/manual/5.4/): concepts, language
rules, callable library entries, implementation boundaries, and grammar. Lua is
credited to Lua.org and PUC-Rio; see the repository [license](../LICENSE). This
manual uses original explanatory prose and repository specifications; the Lua
manual remains an upstream compatibility reference, not a prerequisite for
understanding Varis relations or narrative behavior.
