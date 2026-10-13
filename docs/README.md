# Varis Reference Manual

**Current interpreter edition · October 12, 2026**

Varis is a language for authoring visual novels and story games. It is dynamically
typed and combines procedural programming, finite relational inference,
transactional state, and a deterministic narrative runtime. Its procedural
foundation comes from Lua 5.4. This manual defines the language implemented in
this repository, including the facilities previously described as Lua extensions.

The implementation is built as `bin/varis`, uses `.lua` source files, and reports a
Lua compatibility version. This manual describes **only what is implemented**. The
project's goals and planned changes, including a restricted tier for content
files and a distinct source extension, are in the [roadmap](../ROADMAP.md) and are not
part of the language until they appear here. The procedural core stays a complete
Lua-derived language so that games can be modded with all of it; passing more of
the official Lua 5.4 test suite is not a goal of Varis. Section 9 states the
relationship.

## Contents

1. [Introduction and basic concepts](language.md#1--introduction)
2. [Values, environments, errors, metatables, and coroutines](language.md#2--basic-concepts)
3. [The procedural language](language.md#3--the-procedural-language)
4. [Relations, worlds, rules, and queries](relations.md#4--relational-computation)
5. [Keyed state and transactions](relations.md#5--state-and-transactions)
6. [Narrative definitions and execution](narrative.md#6--narrative-programming)
7. [The standard libraries](libraries.md#7--standard-libraries)
   The battle library is described in [battle.md](battle.md).
8. [The interpreter, project tools, workbench and host interfaces](compatibility.md#8--the-interpreter-and-host-interfaces)
9. [Compatibility and implementation limits](compatibility.md#9--compatibility-and-implementation-limits)
10. [Complete syntax](syntax.md#10--complete-syntax)

Writers who want a gentler start have a separate [writer's guide](writers/README.md):
a tutorial and a cookbook whose programs are run by the test suite.

[Runnable examples](examples/README.md) accompany the reference. The chapters
form one manual; they are not independent extension specifications. Section
numbers are unique across chapters. Function signatures use brackets for optional
arguments and `...` for variable argument lists; brackets are not literal syntax.
Grammar notation is explained in section 10.

## Authority and maintenance

This directory is the single source of truth for current Varis language
semantics. It supersedes `LANGUAGE_EXTENSIONS.md` and `LANGUAGE_EXTENSIONS2.md`.
`LANGUAGE_EXTENSIONS_PLAN.md` remains an engineering history, and `ROADMAP.md`
states direction and planned work; neither is a second language definition.
Unimplemented proposals in `ROADMAP.md`, `sample-game/needed_extensions.md` and
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
- [Lua compatibility audit](../tests/official/README.md), kept as a regression
  record for the procedural core rather than as a conformance target.
- [Coverage migration map](coverage.md), connecting former specification sections
  and requirement identifiers to this manual.

The organization follows the reference-manual tradition of the
[Lua 5.4 Reference Manual](https://www.lua.org/manual/5.4/): concepts, language
rules, callable library entries, implementation boundaries, and grammar. Lua is
credited to Lua.org and PUC-Rio; see the repository [license](../LICENSE). This
manual uses original explanatory prose and repository specifications; the Lua
manual remains an upstream compatibility reference, not a prerequisite for
understanding Varis relations or narrative behavior.

The optional native scene player and D scene-host adapter are documented in
[SDL3 presentation](presentation.md).
