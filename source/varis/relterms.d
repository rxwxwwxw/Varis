/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The vocabulary of relational syntax that the frontend and the compiled templates need: kinds
/// of terms, goals and comparisons. It lives in the core because syntax is part of the language;
/// the world model (`varis.logic.model`) re-exports it. Nothing here depends on the world model.
module varis.relterms;

/// Term kind for relational patterns
enum TermKind {
    Constant,
    Variable,
    Anonymous
}

/// Comparison operator
enum CompareOp {
    Eq,
    Neq,
    Lt,
    Le,
    Gt,
    Ge
}

/// Kind of goal in rule or query body
enum GoalKind {
    PositiveAtom,
    NegatedAtom,
    Comparison,
    Guard,
    Aggregate
}

/// Where a query template keeps its compiled plan between queries (owned by logic.evaluate).
final class PlanHolder {
    Object plan;
}
