# Reference migration and conformance map

[Manual contents](README.md)

This map preserves the ability to interpret existing test comments, audit rows,
and stable requirement IDs after replacing the two extension specifications.
Former section numbers below are historical identifiers, not a second reference.
Tests and audits record evidence; the linked manual chapters define semantics.

## Former declarative reference

| Former `LANGUAGE_EXTENSIONS.md` sections | Current reference |
| --- | --- |
| §1 introduction/model | [§1](language.md#1--introduction), [§4.9](relations.md#49--evaluation-and-versions) |
| §2 symbols, values, constants | [§2.1–2.2](language.md#21--values-and-types), [§4.1](relations.md#41--relations-and-equality), [§4.4–4.5](relations.md#44--rules-and-variable-scope) |
| §3 lexical conventions | [§3.1](language.md#31--lexical-conventions), [§10.2](syntax.md#102--relational-grammar) |
| §§4–5 relations and facts | [§4.1–4.3](relations.md#41--relations-and-equality) |
| §§6–9 rules, capture, negation, guards | [§4.4–4.6](relations.md#44--rules-and-variable-scope) |
| §10 local relations | [§4.7](relations.md#47--local-relations) |
| §11 worlds | [§4.2](relations.md#42--worlds-and-relation-resolution), [§4.9](relations.md#49--evaluation-and-versions) |
| §12 queries | [§4.8](relations.md#48--queries-and-binding-records) |
| §13 evaluation | [§4.9](relations.md#49--evaluation-and-versions) |
| §14 procedural interaction | [§2](language.md#2--basic-concepts), [§3.6](language.md#36--declarative-and-narrative-integration), [§5](relations.md#5--state-and-transactions) |
| §15 logic library | [§7.3](libraries.md#73--logic-library) |
| §16 errors | [§9.5](compatibility.md#95--error-categories) and the relevant semantic sections |
| §17 grammar | [§10](syntax.md#10--complete-syntax) |
| §18 examples | [Runnable examples](examples/README.md) and chapter fragments |
| §19 compatibility/conformance | [§9](compatibility.md#9--compatibility-and-implementation-limits) and requirement index below |

## Former stateful/narrative reference

| Former `LANGUAGE_EXTENSIONS2.md` sections | Current reference |
| --- | --- |
| §1 scope | [Manual authority](README.md#authority-and-maintenance) |
| §2 named/keyed relations | [§5.1–5.2](relations.md#51--named-schemas-and-keys) |
| §3 transactions | [§5.3–5.5](relations.md#53--transaction-execution) |
| §4 aggregates | [§4.6](relations.md#46--aggregates) |
| §5 runtime model | [§6.1](narrative.md#61--content-and-sessions) |
| §6 storylets | [§6.2](narrative.md#62--storylets-and-parameters) |
| §7 choices/effects | [§6.3](narrative.md#63--choices-lexical-binding-and-tokens) |
| §8 actions | [§6.4](narrative.md#64--automatic-actions) |
| §9 decks | [§6.5](narrative.md#65--decks-and-deterministic-selection) |
| §10 templates | [§6.6](narrative.md#66--presentation-values-and-templates) |
| §11 qualities | [§6.8](narrative.md#68--qualities) |
| §12 events/time/defer | [§6.7](narrative.md#67--events-schedules-and-callbacks) |
| §13 saves/replay | [§6.9](narrative.md#69--portable-saves-and-replay) |
| §14 authoring | [§6.10](narrative.md#610--explanations-subscriptions-and-bounded-analysis) |
| §15 grammar | [§10](syntax.md#10--complete-syntax) |
| §16 conformance/rejections | [§9.5](compatibility.md#95--error-categories), [requirement evidence](../tests/TRACEABILITY.md) |

## Stable requirement identifiers

The [machine-readable evidence map](../tests/requirements.toml) and its generated
[traceability report](../tests/TRACEABILITY.md) retain V1/C2 identifiers to avoid
renumbering test evidence. Historical paragraph suffixes in requirement titles
refer to the migration tables above.

| IDs | Current subject |
| --- | --- |
| V1.1 | §3.1 and §10: complete contextual grammar |
| V1.2 | §§2.1–2.2, 4.1: symbols and raw relational equality |
| V1.3 | §§4.3–4.4: runtime registration and atomicity |
| V1.4 | §§4.4–4.6: safety, ownership, and strict strata |
| V1.5 | §4.9: least fixed point and invalidation |
| V1.6 | §4.2: independent snapshot worlds |
| V1.7 | §4.7: lexical recursive locals |
| V1.8 | §4.8: snapshot iterators and projection |
| V1.9 | §§2.3–2.7, 4.5: lexical captures, calls, and errors |
| C2.2–C2.3 | §§5.1–5.2: schemas/keys/updates |
| C2.4–C2.5 | §§5.3–5.5: transaction behavior and restrictions |
| C2.6 | §4.6: aggregates (separate implemented feature) |
| C2.7–C2.9 | §§6.1–6.3: content, parameters, choices |
| C2.10–C2.12 | §§6.4–6.6: scheduler, decks, templates |
| C2.13 | §6.8: quality metadata and constraints |
| C2.14 | §6.7: event timing and deferred operations |
| C2.15 | §6.9: persistence/replay validation |
| C2.16–C2.18 | §6.10: optional subscriptions, explanations, bounded analysis |
| C2.19 | §10.3: stateful/narrative grammar |
| C2.20 | §§6.6, 7.4: formatters and weighted text variants |
| C2.E1–C2.E9 | §9.5 and §§4–6: required rejection categories |

Current `sticky` and `order` fields are documented in §§6.2 and 6.5 and exercised
by `tests/extensions/cases/narrative_sticky_order.lua`; these post-proposal fields
are not silently folded into the historical C2.20 formatter/variant requirement.

## Decisions consolidated from the implementation plan

This manual incorporates the plan's resolved edges: unknown retraction is a
no-op; cross-world queries can snapshot multiple worlds; query guard capture is
at construction; inference is lazy and failed iterators remain invalid; local
schemas remain numeric; key argument order follows the key list; transaction
schema/rule registration and local writes are forbidden; protected errors inside
a transaction retain earlier tentative writes; savepoint iterator invalidation
propagates through outer rollback; close handlers precede transaction cleanup.

Narrative decisions include session-world availability/effects with ordinary
lexical helper worlds; exact reusable-until-invalidated tokens; commit-time
turn/event distinctions; staged presentation draws; due-event ordering and
separate budgets; explicit quality initialization and lexical effect defaults;
authored reconstruction/migration assertions; post-commit observer errors and
queued work; and the precise bounded-analysis scope. The plan remains useful
engineering history, but changes to these contracts belong in this manual.
