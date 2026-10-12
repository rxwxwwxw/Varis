/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The content tier (ROADMAP "Language tiers", open decision 1: the default list is used).
/// Content files hold what writers produce: narrative definitions, relations, rules, facts, effects
/// and calls to named helpers. They may not use coroutines, `io`, `os`, `debug`, `package`, `load`
/// or metatables, and may not create function values except as the callback of
/// `narrative.defer`, `narrative.formatter` or `narrative.on`, and then only a function that
/// captures no local of its enclosing code. The restriction exists so that content cannot break
/// saves by accident and a content-only package can be loaded without trusting its author.
///
/// Enforcement is static (`varis check`, the language server, CI): it reads the AST and runs
/// nothing. The runtime does not know which files are content.
module varis.services.tier;

import varis.ast;
import varis.exception : LuaException;
import varis.parser : Parser;
import varis.services.diagnostic;

private immutable string[] forbiddenGlobals = [
    "coroutine", "io", "os", "debug", "package", "load", "loadstring", "loadfile", "dofile",
    "setmetatable",
    "getmetatable"
];

private immutable string[] callbackFunctions = ["defer", "formatter", "on"];

private final class Walker {
    string file;
    Diagnostic[] found;
    // Locals in scope; `level` is the function nesting at which each was declared.
    string[] names;
    int[] levels;
    int[] marks; // scope boundaries: sizes of `names`
    int level;
    bool callbackPosition;

    this(string file) {
        this.file = file;
    }

    void report(Expr at, string message, string subject) {
        found ~= makeDiagnostic("error", "tier", file, at.loc.line, at.loc.column, at.loc.line,
                at.loc.column + 1, message, subject);
    }

    void push() {
        marks ~= cast(int) names.length;
    }

    void pop() {
        auto size = marks[$ - 1];
        marks.length--;
        names.length = size;
        levels.length = size;
    }

    void declare(string name) {
        names ~= name;
        levels ~= level;
    }

    /// The function level a name was declared at, or -1 for a global.
    int resolve(string name) {
        foreach_reverse (i, n; names)
            if (n == name)
                return levels[i];
        return -1;
    }

    void block(BlockStmt b) {
        if (b is null)
            return;
        push();
        foreach (s; b.statements)
            stmt(s);
        pop();
    }

    void stmt(Stmt s) {
        if (s is null)
            return;
        if (auto n = as!NarrativeDefinitionStmt(s)) {
            push();
            foreach (p; n.parameters)
                declare(p);
            goals(n.goals);
            foreach (v; n.fieldValues)
                expr(v);
            foreach (c; n.choices)
                stmt(c);
            block(n.effect);
            pop();
            return;
        }
        if (auto n = as!NarrativeDeckStmt(s))
            return expr(n.options);
        if (auto n = as!RuleDeclStmt(s)) {
            foreach (a; n.headArgs)
                expr(a);
            return goals(n.goals);
        }
        if (auto n = as!FactStmt(s)) {
            foreach (a; n.args)
                expr(a);
            return;
        }
        if (auto n = as!RetractStmt(s)) {
            foreach (a; n.args)
                expr(a);
            return;
        }
        if (auto n = as!UpdateStmt(s)) {
            foreach (a; n.args)
                expr(a);
            return expr(n.delta);
        }
        if (auto n = as!FunctionDeclStmt(s)) {
            // A named function in a content file is a function value that is not a callback.
            found ~= makeDiagnostic("error", "tier", file, n.loc.line, n.loc.column, n.loc.line, n.loc.column + 8,
                    "functions are not allowed in content files; define helpers in an engine script and call them",
                    "function");
            if (n.isLocal)
                declare(n.localName);
            function_(n.def.params, n.def.body);
            return;
        }
        if (auto n = as!BlockStmt(s))
            return block(n);
        if (auto n = as!AssignStmt(s)) {
            foreach (e; n.targets)
                expr(e);
            foreach (e; n.values)
                expr(e);
            return;
        }
        if (auto n = as!LocalDeclStmt(s)) {
            foreach (e; n.values)
                expr(e);
            foreach (name; n.names)
                declare(name);
            return;
        }
        if (auto n = as!CallStmt(s))
            return expr(n.call);
        if (auto n = as!DoStmt(s))
            return block(n.body);
        if (auto n = as!WhileStmt(s)) {
            expr(n.condition);
            return block(n.body);
        }
        if (auto n = as!RepeatStmt(s)) {
            block(n.body);
            return expr(n.condition);
        }
        if (auto n = as!IfStmt(s)) {
            foreach (branch; n.branches) {
                expr(branch.condition);
                block(branch.body);
            }
            return block(n.elseBody);
        }
        if (auto n = as!ForNumericStmt(s)) {
            expr(n.start);
            expr(n.limit);
            expr(n.step);
            push();
            declare(n.varName);
            block(n.body);
            pop();
            return;
        }
        if (auto n = as!ForGenericStmt(s)) {
            foreach (e; n.iterators)
                expr(e);
            push();
            foreach (name; n.varNames)
                declare(name);
            block(n.body);
            pop();
            return;
        }
        if (auto n = as!ReturnStmt(s)) {
            foreach (e; n.values)
                expr(e);
            return;
        }
        if (auto n = as!TransactionStmt(s)) {
            expr(n.worldExpr);
            return block(n.body);
        }
        if (auto n = as!WorldBlockStmt(s)) {
            expr(n.worldExpr);
            return block(n.body);
        }
    }

    void goals(AstGoal[] list) {
        foreach (g; list) {
            if (auto n = as!AstRelAtomGoal(g)) {
                foreach (t; n.terms)
                    expr(t);
            } else if (auto n = as!AstComparisonGoal(g)) {
                expr(n.left);
                expr(n.right);
            } else if (auto n = as!AstAggregateGoal(g)) {
                expr(n.expression);
                goals(n.goals);
            } else if (auto n = as!AstGuardGoal(g))
                expr(n.expr);
        }
    }

    void function_(string[] params, BlockStmt body) {
        ++level;
        push();
        foreach (p; params)
            declare(p);
        block(body);
        pop();
        --level;
    }

    void expr(Expr e) {
        if (e is null)
            return;
        if (auto n = as!VariableExpr(e)) {
            auto declaredAt = resolve(n.name);
            if (declaredAt < 0) {
                foreach (name; forbiddenGlobals)
                    if (name == n.name)
                        report(e, "`" ~ n.name ~ "` is not available in content files (the content tier has no "
                                ~ "coroutines, io, os, debug, package, load or metatables)", "global " ~ n.name);
            } else if (declaredAt < level) {
                report(e, "`" ~ n.name ~ "` is a local of the enclosing code; a function in a content file may not "
                        ~ "capture it", "local " ~ n.name);
            }
            return;
        }
        if (auto n = as!FieldExpr(e))
            return expr(n.table);
        if (auto n = as!IndexExpr(e)) {
            expr(n.table);
            return expr(n.key);
        }
        if (auto n = as!CallExpr(e)) {
            // A callback of narrative.defer / formatter / on may be a function value.
            bool callback;
            if (auto f = as!FieldExpr(n.callee))
                if (auto lib = as!VariableExpr(f.table))
                    if (lib.name == "narrative" && resolve("narrative") < 0)
                        foreach (name; callbackFunctions)
                            callback = callback || name == f.field;
            expr(n.callee);
            foreach (a; n.args) {
                if (callback && as!FunctionDefExpr(a) !is null) {
                    auto def = as!FunctionDefExpr(a);
                    function_(def.params, def.body);
                } else
                    expr(a);
            }
            return;
        }
        if (auto n = as!MethodCallExpr(e)) {
            expr(n.receiver);
            foreach (a; n.args)
                expr(a);
            return;
        }
        if (auto n = as!UnaryExpr(e))
            return expr(n.expr);
        if (auto n = as!BinaryExpr(e)) {
            expr(n.left);
            return expr(n.right);
        }
        if (auto n = as!TableConstructorExpr(e)) {
            foreach (field; n.fields) {
                expr(field.key);
                expr(field.value);
            }
            return;
        }
        if (auto n = as!FunctionDefExpr(e)) {
            report(e, "function values are not allowed in content files except as the callback of narrative.defer, "
                    ~ "narrative.formatter or narrative.on", "function");
            function_(n.params, n.body);
            return;
        }
        if (auto n = as!QueryExpr(e))
            return goals(n.goals);
    }
}

/// The tier violations of one content file. A file that does not parse is the syntax check's.
Diagnostic[] checkTier(string path, string content) {
    string source = content;
    if (source.length > 1 && source[0] == '#')
        source = "--" ~ source[2 .. $];
    auto parser = new Parser(source, "@" ~ path, true);
    BlockStmt block;
    try {
        block = parser.parse();
    } catch (LuaException) {
        return null;
    }
    if (parser.problems.length)
        return null;
    auto walker = new Walker(path);
    walker.block(block);
    return walker.found;
}
