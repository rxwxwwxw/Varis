/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.ast;

/// Source code location for diagnostics and debug info
struct SourceLoc {
    int line = 1;
    int column = 1;

    string toString() const @safe pure {
        import std.format : format;

        return format("%d:%d", line, column);
    }
}

/// Abstract base class for all AST nodes
/// Exact-type downcast of an AST node: the node classes are final, so one comparison of the
/// runtime type replaces the checked class cast (a function call per test).
pragma(inline, true)
T as(T : AstNode)(AstNode node) @trusted {
    return node !is null && typeid(node) is typeid(T) ? cast(T) cast(void*) node : null;
}

abstract class AstNode {
    SourceLoc loc;
    /// Position just after the node's last token; line 0 when the parser did not record it.
    /// Recorded for statements, definitions and string literals (tools report ranges).
    SourceLoc end = SourceLoc(0, 0);

    this(SourceLoc loc = SourceLoc.init) {
        this.loc = loc;
    }
}

// -----------------------------------------------------------------------------
// Expressions
// -----------------------------------------------------------------------------

abstract class Expr : AstNode {
    bool parenthesized;
    int lastTokenLine; // line of the last token of the expression (instruction line for indexing)
    this(SourceLoc loc = SourceLoc.init) {
        super(loc);
    }
}

final class LiteralNilExpr : Expr {
    this(SourceLoc loc = SourceLoc.init) {
        super(loc);
    }
}

final class LiteralBoolExpr : Expr {
    bool value;

    this(bool value, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.value = value;
    }
}

final class LiteralIntExpr : Expr {
    long value;

    this(long value, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.value = value;
    }
}

final class LiteralFloatExpr : Expr {
    double value;

    this(double value, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.value = value;
    }
}

final class LiteralStringExpr : Expr {
    string value;

    this(string value, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.value = value;
    }
}

final class VarargExpr : Expr {
    this(SourceLoc loc = SourceLoc.init) {
        super(loc);
    }
}

final class VariableExpr : Expr {
    string name;

    this(string name, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.name = name;
    }
}

final class SymbolLiteralExpr : Expr {
    string name;

    this(string name, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.name = name;
    }
}

final class LogicVarExpr : Expr {
    string name;
    bool isAnonymous;

    this(string name, bool isAnonymous = false, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.name = name;
        this.isAnonymous = isAnonymous;
    }
}

final class QueryExpr : Expr {
    AstGoal[] goals;
    bool isBraced;

    this(AstGoal[] goals, bool isBraced = false, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.goals = goals;
        this.isBraced = isBraced;
    }
}

struct TableField {
    Expr key; // null if list element
    Expr value;
}

final class TableConstructorExpr : Expr {
    TableField[] fields;

    this(TableField[] fields, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.fields = fields;
    }
}

final class IndexExpr : Expr {
    Expr table;
    Expr key;

    this(Expr table, Expr key, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.table = table;
        this.key = key;
    }
}

final class FieldExpr : Expr {
    Expr table;
    string field;

    this(Expr table, string field, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.table = table;
        this.field = field;
    }
}

final class CallExpr : Expr {
    Expr callee;
    Expr[] args;

    this(Expr callee, Expr[] args, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.callee = callee;
        this.args = args;
    }
}

final class MethodCallExpr : Expr {
    int nameLine; // line of the method name (OP_SELF)
    int argsLine; // line of the call arguments (OP_CALL)
    Expr receiver;
    string method;
    Expr[] args;

    this(Expr receiver, string method, Expr[] args, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.receiver = receiver;
        this.method = method;
        this.args = args;
    }
}

enum UnaryOp {
    Neg, // -
    Not, // not
    BitNot, // ~
    Len // #
}

final class UnaryExpr : Expr {
    UnaryOp op;
    Expr expr;

    this(UnaryOp op, Expr expr, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.op = op;
        this.expr = expr;
    }
}

enum BinaryOp {
    Add, // +
    Sub, // -
    Mul, // *
    Mod, // %
    Pow, // ^
    Div, // /
    IDiv, // //
    BAnd, // &
    BOr, // |
    BXor, // ~
    Shl, // <<
    Shr, // >>
    Concat, // ..
    Eq, // ==
    Ne, // ~=
    Lt, // <
    Le, // <=
    Gt, // >
    Ge, // >=
    And, // and
    Or // or
}

final class BinaryExpr : Expr {
    BinaryOp op;
    Expr left;
    Expr right;

    this(BinaryOp op, Expr left, Expr right, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.op = op;
        this.left = left;
        this.right = right;
    }
}

final class FunctionDefExpr : Expr {
    int endLine;
    string[] params;
    bool isVararg;
    BlockStmt body;

    this(string[] params, bool isVararg, BlockStmt body, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.params = params;
        this.isVararg = isVararg;
        this.body = body;
    }
}

// -----------------------------------------------------------------------------
// Statements
// -----------------------------------------------------------------------------

abstract class Stmt : AstNode {
    this(SourceLoc loc = SourceLoc.init) {
        super(loc);
    }
}

final class BlockStmt : Stmt {
    Stmt[] statements;
    int endLine; // line of the last token of the block (chunks only)

    this(Stmt[] statements = null, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.statements = statements;
    }
}

final class EmptyStmt : Stmt {
    this(SourceLoc loc = SourceLoc.init) {
        super(loc);
    }
}

final class AssignStmt : Stmt {
    Expr[] targets;
    Expr[] values;

    this(Expr[] targets, Expr[] values, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.targets = targets;
        this.values = values;
    }
}

final class LocalDeclStmt : Stmt {
    string[] names;
    string[] attributes;
    Expr[] values;

    this(string[] names, Expr[] values = null, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.names = names;
        this.values = values;
    }
}

final class CallStmt : Stmt {
    Expr call; // CallExpr or MethodCallExpr

    this(Expr call, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.call = call;
    }
}

final class DoStmt : Stmt {
    BlockStmt body;

    this(BlockStmt body, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.body = body;
    }
}

final class WhileStmt : Stmt {
    Expr condition;
    BlockStmt body;

    this(Expr condition, BlockStmt body, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.condition = condition;
        this.body = body;
    }
}

final class RepeatStmt : Stmt {
    BlockStmt body;
    Expr condition;

    this(BlockStmt body, Expr condition, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.body = body;
        this.condition = condition;
    }
}

struct IfBranch {
    Expr condition;
    BlockStmt body;
    SourceLoc loc;
    int thenLine; // line of the 'then' token
}

final class IfStmt : Stmt {
    IfBranch[] branches;
    BlockStmt elseBody; // may be null

    this(IfBranch[] branches, BlockStmt elseBody = null, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.branches = branches;
        this.elseBody = elseBody;
    }
}

final class ForNumericStmt : Stmt {
    string varName;
    Expr start;
    Expr limit;
    Expr step; // null if default 1
    BlockStmt body;

    this(string varName, Expr start, Expr limit, Expr step, BlockStmt body, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.varName = varName;
        this.start = start;
        this.limit = limit;
        this.step = step;
        this.body = body;
    }
}

final class ForGenericStmt : Stmt {
    string[] varNames;
    Expr[] iterators;
    BlockStmt body;

    this(string[] varNames, Expr[] iterators, BlockStmt body, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.varNames = varNames;
        this.iterators = iterators;
        this.body = body;
    }
}

final class FunctionDeclStmt : Stmt {
    Expr target; // e.g. VariableExpr, FieldExpr, IndexExpr
    FunctionDefExpr def;
    bool isLocal;
    string localName;
    SourceLoc nameLoc; // the last name of the function's name, for tools
    SourceLoc nameEnd;

    this(Expr target, FunctionDefExpr def, bool isLocal = false, string localName = "", SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.target = target;
        this.def = def;
        this.isLocal = isLocal;
        this.localName = localName;
    }
}

final class ReturnStmt : Stmt {
    Expr[] values;

    this(Expr[] values = null, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.values = values;
    }
}

final class BreakStmt : Stmt {
    this(SourceLoc loc = SourceLoc.init) {
        super(loc);
    }
}

final class GotoStmt : Stmt {
    string label;

    this(string label, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.label = label;
    }
}

final class LabelStmt : Stmt {
    string label;

    this(string label, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.label = label;
    }
}

// -----------------------------------------------------------------------------
// Declarative / Datalog AST Nodes (Phase 6)
// -----------------------------------------------------------------------------

import varis.relterms : CompareOp;

final class AstRelRef : AstNode {
    string[] worldPath;
    string name;

    this(string[] worldPath, string name, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.worldPath = worldPath;
        this.name = name;
    }
}

abstract class AstGoal : AstNode {
    this(SourceLoc loc = SourceLoc.init) {
        super(loc);
    }
}

final class AstRelAtomGoal : AstGoal {
    AstRelRef relRef;
    Expr[] terms;
    bool isNegated;

    this(AstRelRef relRef, Expr[] terms, bool isNegated = false, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.relRef = relRef;
        this.terms = terms;
        this.isNegated = isNegated;
    }
}

final class AstComparisonGoal : AstGoal {
    Expr left;
    CompareOp op;
    Expr right;

    this(Expr left, CompareOp op, Expr right, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.left = left;
        this.op = op;
        this.right = right;
    }
}

final class AstAggregateGoal : AstGoal {
    string resultVariable;
    string operation;
    Expr expression;
    AstGoal[] goals;
    this(string resultVariable, string operation, Expr expression, AstGoal[] goals, SourceLoc loc) {
        super(loc);
        this.resultVariable = resultVariable;
        this.operation = operation;
        this.expression = expression;
        this.goals = goals;
    }
}

final class AstGuardGoal : AstGoal {
    Expr expr;

    this(Expr expr, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.expr = expr;
    }
}

final class FactStmt : Stmt {
    AstRelRef relRef;
    Expr[] args;

    this(AstRelRef relRef, Expr[] args, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.relRef = relRef;
        this.args = args;
    }
}

final class RetractStmt : Stmt {
    AstRelRef relRef;
    Expr[] args;

    this(AstRelRef relRef, Expr[] args, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.relRef = relRef;
        this.args = args;
    }
}

final class NarrativeDefinitionStmt : Stmt {
    string kind;
    string name;
    SourceLoc nameLoc; // where the name is written, for tools
    SourceLoc nameEnd;
    string[] parameters;
    AstGoal[] goals;
    string[] fieldNames;
    Expr[] fieldValues;
    NarrativeDefinitionStmt[] choices;
    BlockStmt effect;
    this(string kind, string name, SourceLoc loc) {
        super(loc);
        this.kind = kind;
        this.name = name;
    }
}

final class NarrativeDeckStmt : Stmt {
    string name;
    SourceLoc nameLoc;
    SourceLoc nameEnd;
    Expr options;
    this(string name, Expr options, SourceLoc loc) {
        super(loc);
        this.name = name;
        this.options = options;
    }
}

final class TransactionStmt : Stmt {
    Expr worldExpr;
    BlockStmt body;
    this(Expr worldExpr, BlockStmt body, SourceLoc loc) {
        super(loc);
        this.worldExpr = worldExpr;
        this.body = body;
    }
}

final class RollbackStmt : Stmt {
    this(SourceLoc loc) {
        super(loc);
    }
}

final class UpdateStmt : Stmt {
    string operation;
    AstRelRef relRef;
    Expr[] args;
    Expr delta;
    this(string operation, AstRelRef relRef, Expr[] args, Expr delta, SourceLoc loc) {
        super(loc);
        this.operation = operation;
        this.relRef = relRef;
        this.args = args;
        this.delta = delta;
    }
}

final class RelationDeclStmt : Stmt {
    string name;
    SourceLoc nameLoc;
    SourceLoc nameEnd;
    int arity;
    string[] columns;
    string[] keys;
    bool named;

    this(string name, int arity, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.name = name;
        this.arity = arity;
    }
}

final class LocalRelationDeclStmt : Stmt {
    string name;
    SourceLoc nameLoc;
    SourceLoc nameEnd;
    int arity;

    this(string name, int arity, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.name = name;
        this.arity = arity;
    }
}

final class RuleDeclStmt : Stmt {
    AstRelRef headRel;
    Expr[] headArgs;
    AstGoal[] goals;

    this(AstRelRef headRel, Expr[] headArgs, AstGoal[] goals, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.headRel = headRel;
        this.headArgs = headArgs;
        this.goals = goals;
    }
}

final class WorldBlockStmt : Stmt {
    Expr worldExpr;
    BlockStmt body;

    this(Expr worldExpr, BlockStmt body, SourceLoc loc = SourceLoc.init) {
        super(loc);
        this.worldExpr = worldExpr;
        this.body = body;
    }
}

// Backward compatibility alias for RuleStmt
alias RuleStmt = RuleDeclStmt;
