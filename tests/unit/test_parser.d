/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

/*
** dlua - Unit tests for Frontend (AST, Lexer, Parser)
*/

module tests.unit.test_parser;

import dlua;
import dlua.ast;
import dlua.lexer;
import dlua.parser;
import std.stdio : writeln;

void testLexer() {
    string src = q"{
        local x = 123
        local y = 0x1f
        local f = 3.14159
        local s = "hello\nworld"
        local longStr = [[
first line
second line]]
        -- single line comment
        --[[ long comment ]]
        x = x + 1
    }";

    auto lexer = new Lexer(src);
    Token tok;
    int count = 0;
    do {
        tok = lexer.nextToken();
        count++;
    }
    while (tok.type != TokenType.EOF);

    assert(count > 10);
    writeln("  [PASS] testLexer");
}

void testExpressions() {
    // Arithmetic precedence: 1 + 2 * 3 should be 1 + (2 * 3)
    string code = "return a + b * c";
    auto parser = new Parser(code);
    auto block = parser.parse();

    assert(block.statements.length == 1);
    auto retStmt = cast(ReturnStmt) block.statements[0];
    assert(retStmt !is null);
    assert(retStmt.values.length == 1);

    auto addExpr = cast(BinaryExpr) retStmt.values[0];
    assert(addExpr !is null);
    assert(addExpr.op == BinaryOp.Add);

    auto mulExpr = cast(BinaryExpr) addExpr.right;
    assert(mulExpr !is null);
    assert(mulExpr.op == BinaryOp.Mul);

    // Numeric literal operations are folded at parse time, as in lcode.c.
    auto folded = new Parser("return 1 + 2 * 3, -4, 7 // 2, 1 / 0, 2 ^ 2, 1 << 62, ~0, not nil").parse();
    auto foldedValues = (cast(ReturnStmt) folded.statements[0]).values;
    assert(cast(LiteralIntExpr) foldedValues[0]!is null && (cast(LiteralIntExpr) foldedValues[0]).value == 7);
    assert(cast(LiteralIntExpr) foldedValues[1]!is null && (cast(LiteralIntExpr) foldedValues[1]).value == -4);
    assert((cast(LiteralIntExpr) foldedValues[2]).value == 3);
    assert(cast(BinaryExpr) foldedValues[3]!is null); // division by zero is never folded
    assert(cast(LiteralFloatExpr) foldedValues[4]!is null && (cast(LiteralFloatExpr) foldedValues[4]).value == 4.0);
    assert((cast(LiteralIntExpr) foldedValues[5]).value == 1L << 62);
    assert((cast(LiteralIntExpr) foldedValues[6]).value == -1);
    assert(cast(LiteralBoolExpr) foldedValues[7]!is null && (cast(LiteralBoolExpr) foldedValues[7]).value);

    writeln("  [PASS] testExpressions");
}

void testControlFlow() {
    string code = q"{
        local a = 10
        if a > 5 then
            a = a - 1
        elseif a == 5 then
            a = 0
        else
            a = 100
        end

        while a > 0 do
            a = a - 1
        end

        repeat
            a = a + 1
        until a == 10

        for i = 1, 10, 2 do
            a = a + i
        end

        for k, v in pairs(t) do
            print(k, v)
        end
    }";

    auto parser = new Parser(code);
    auto block = parser.parse();
    assert(block.statements.length == 6);

    assert(cast(LocalDeclStmt) block.statements[0]!is null);
    assert(cast(IfStmt) block.statements[1]!is null);
    assert(cast(WhileStmt) block.statements[2]!is null);
    assert(cast(RepeatStmt) block.statements[3]!is null);
    assert(cast(ForNumericStmt) block.statements[4]!is null);
    assert(cast(ForGenericStmt) block.statements[5]!is null);

    writeln("  [PASS] testControlFlow");
}

void testTablesAndFunctions() {
    string code = q"{
        local t = { 10, 20, x = "foo", ["key"] = true }

        local function add(a, b, ...)
            return a + b
        end

        function t:greet(msg)
            return self.x .. ": " .. msg
        end

        t:greet("hello")
    }";

    auto parser = new Parser(code);
    auto block = parser.parse();
    assert(block.statements.length == 4);

    // Table declaration
    auto localT = cast(LocalDeclStmt) block.statements[0];
    assert(localT !is null);
    assert(localT.values.length == 1);
    auto tableCtor = cast(TableConstructorExpr) localT.values[0];
    assert(tableCtor !is null);
    assert(tableCtor.fields.length == 4);

    // Local function
    auto fnDecl = cast(FunctionDeclStmt) block.statements[1];
    assert(fnDecl !is null);
    assert(fnDecl.isLocal);
    assert(fnDecl.localName == "add");
    assert(fnDecl.def.params.length == 2);
    assert(fnDecl.def.isVararg);

    // Method declaration
    auto methodDecl = cast(FunctionDeclStmt) block.statements[2];
    assert(methodDecl !is null);
    assert(methodDecl.def.params.length == 2);
    assert(methodDecl.def.params[0] == "self");

    // Method call
    auto callStmt = cast(CallStmt) block.statements[3];
    assert(callStmt !is null);
    auto methodCall = cast(MethodCallExpr) callStmt.call;
    assert(methodCall !is null);
    assert(methodCall.method == "greet");

    writeln("  [PASS] testTablesAndFunctions");
}

void testDeclarativeParser() {
    string code = q"{
        -- Contextual keywords in ordinary Lua
        local fact = 12
        local query = function(x) return x end
        local r = query(fact)
        ::mylbl::

        -- Declarative extensions
        local alpha = :alpha
        relation edge(2)
        fact edge(:a, :b)
        retract edge(:a, :b)

        local relation reach(1)
        rule reach(?x) :- edge(:a, ?x)

        logic (sim) do
            fact edge(:b, :c)
        end

        for m in query reach(?dst) do
        end

        for m in query {
            edge(:a, ?mid),
            edge(?mid, ?dst),
            not hazard(?dst),
            where (?dst ~= :lava)
        } do
        end
    }";

    auto parser = new Parser(code);
    auto block = parser.parse();
    assert(block !is null);
    assert(block.statements.length >= 10);

    writeln("  [PASS] testDeclarativeParser");
}

int main() {
    writeln("Running dlua Frontend (AST, Lexer, Parser) Unit Tests...");
    testLexer();
    testExpressions();
    testControlFlow();
    testTablesAndFunctions();
    testDeclarativeParser();
    writeln("All Frontend Tests Passed Successfully!");
    return 0;
}
