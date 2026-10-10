/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.parser;

import dlua.types : LuaValue;

import dlua.ast;
import dlua.lexer;
import dlua.logic.model : CompareOp;
import dlua.exception : LuaException, shortSourceName;
import std.format : format;
import std.conv : to;

class Parser {
    Lexer lexer;
    Token current;
    Token previous;
    string sourceName;
    Token[] lookahead;
    bool inDeclarative = false;

    this(string source, string sourceName = "=stdin") {
        varargContext = [true];
        activeLocals = [0];
        functionStartLines = [0];
        this.sourceName = sourceName;
        this.lexer = new Lexer(source, sourceName);
        advance();
    }

    Token peekToken(size_t k = 0) {
        while (lookahead.length <= k) {
            lookahead ~= lexer.nextToken();
        }
        return lookahead[k];
    }

    private void advance() {
        previous = current;
        if (lookahead.length > 0) {
            current = lookahead[0];
            lookahead = lookahead[1 .. $];
        } else {
            current = lexer.nextToken();
        }
    }

    private bool check(TokenType type) const {
        return current.type == type;
    }

    private bool match(TokenType type) {
        if (check(type)) {
            advance();
            return true;
        }
        return false;
    }

    private string formatSourceName() const { return shortSourceName(sourceName); }

    private string formatNear(Token tok) const {
        if (tok.type == TokenType.EOF || tok.text == "<eof>") {
            return "<eof>";
        }
        if (tok.type == TokenType.Invalid) {
            ubyte code = cast(ubyte)tok.text[0];
            if (code >= 32 && code < 127) return "'" ~ tok.text ~ "'";
            return "'<\\" ~ code.to!string ~ ">'";
        }
        return "'" ~ (tok.raw.length ? tok.raw : tok.text) ~ "'";
    }

    /// check_match: closes a construct, mentioning where it was opened when on another line.
    private void checkMatch(TokenType what, string whatText, string whoText, int whereLine) {
        if (check(what)) { advance(); return; }
        if (whereLine == current.loc.line) syntaxError(whatText ~ " expected", current);
        else syntaxError(whatText ~ " expected (to close " ~ whoText ~ " at line " ~ whereLine.to!string ~ ")", current);
    }

    private void syntaxErrorNoNear(string msg, int line) {
        throw new LuaException(LuaValue(format("%s:%d: %s", formatSourceName(), line, msg)));
    }

    private bool[] varargContext;
    private int nestingLevel;
    private int[] activeLocals;       // active local variables per function being parsed
    private int[] functionStartLines;  // line where each function being parsed starts

    private void declareLocals(int count = 1) {
        activeLocals[$ - 1] += count;
        if (activeLocals[$ - 1] > 200) {
            auto line = functionStartLines[$ - 1];
            syntaxError("too many local variables (limit is 200) in " ~
                (line == 0 ? "main function" : "function at line " ~ line.to!string), current);
        }
    }

    /// enterlevel: bounds recursive descent like LUAI_MAXCCALLS in lparser.c.
    private void enterLevel() {
        if (++nestingLevel > 195) {
            auto failure = new LuaException(LuaValue("C stack overflow"));
            throw failure;
        }
    }

    private void syntaxError(string msg, Token tok) {
        throw new LuaException(LuaValue(format("%s:%d: %s near %s", formatSourceName(), tok.loc.line, msg, formatNear(tok))));
    }

    private Token consume(TokenType type, string message) {
        if (check(type)) {
            advance();
            return previous;
        }
        syntaxError(message, current);
        return current;
    }

    /// Parse top-level chunk into BlockStmt
    BlockStmt parse() {
        auto loc = current.loc;
        auto block = parseBlock();
        if (!check(TokenType.EOF)) {
            syntaxError("<eof> expected", current);
        }
        block.endLine = previous.loc.line > 0 ? previous.loc.line : 1;
        return block;
    }

    // -------------------------------------------------------------------------
    // Blocks and Statements
    // -------------------------------------------------------------------------

    BlockStmt parseBlock() {
        auto loc = current.loc;
        Stmt[] stmts;
        int savedLocals = activeLocals[$ - 1];
        scope(exit) activeLocals[$ - 1] = savedLocals;

        while (!isAtEnd() && !isBlockEnd()) {
            if (check(TokenType.KwReturn)) {
                stmts ~= parseReturnStmt();
                break; // In Lua, return is the last statement in a block
            }
            auto stmt = parseStatement();
            if (stmt !is null) {
                stmts ~= stmt;
            }
        }

        return new BlockStmt(stmts, loc);
    }

    private bool isBlockEnd() const {
        return check(TokenType.KwEnd) ||
               check(TokenType.KwElse) ||
               check(TokenType.KwElseIf) ||
               check(TokenType.KwUntil) ||
               check(TokenType.EOF);
    }

    private bool isAtEnd() const {
        return check(TokenType.EOF);
    }

    private Stmt parseStatement() {
        enterLevel();
        scope(exit) --nestingLevel;
        auto loc = current.loc;

        if (match(TokenType.Semicolon)) {
            return new EmptyStmt(loc);
        }

        if (check(TokenType.DoubleColon)) {
            return parseLabelStmt();
        }

        if (match(TokenType.KwBreak)) {
            return new BreakStmt(loc);
        }

        if (match(TokenType.KwGoto)) {
            auto label = consume(TokenType.Identifier, "<name> expected").text;
            return new GotoStmt(label, loc);
        }

        if (match(TokenType.KwDo)) {
            auto body = parseBlock();
            checkMatch(TokenType.KwEnd, "'end'", "'do'", loc.line);
            return new DoStmt(body, loc);
        }

        if (match(TokenType.KwWhile)) {
            auto cond = parseExpr();
            consume(TokenType.KwDo, "'do' expected");
            auto body = parseBlock();
            checkMatch(TokenType.KwEnd, "'end'", "'while'", loc.line);
            return new WhileStmt(cond, body, loc);
        }

        if (match(TokenType.KwRepeat)) {
            auto body = parseBlock();
            checkMatch(TokenType.KwUntil, "'until'", "'repeat'", loc.line);
            auto cond = parseExpr();
            return new RepeatStmt(body, cond, loc);
        }

        if (match(TokenType.KwIf)) {
            return parseIfStmt(loc);
        }

        if (match(TokenType.KwFor)) {
            return parseForStmt(loc);
        }

        if (match(TokenType.KwFunction)) {
            return parseFunctionDecl(false, loc);
        }

        if (match(TokenType.KwLocal)) {
            if (match(TokenType.KwFunction)) {
                return parseFunctionDecl(true, loc);
            }
            if (check(TokenType.Identifier) && current.text == "relation" && peekToken(0).type == TokenType.Identifier && peekToken(1).type == TokenType.LParen) {
                return parseLocalRelationDeclStmt(loc);
            }
            return parseLocalDecl(loc);
        }

        // Declarative Statements (Phase 6)
        if (check(TokenType.Identifier)) {
            if ((current.text == "storylet" || current.text == "action") && peekToken(0).type == TokenType.Identifier && peekToken(1).type == TokenType.LParen)
                return parseNarrativeDefinition(current.text, loc);
            if (current.text == "deck" && peekToken(0).type == TokenType.Colon && peekToken(1).type == TokenType.Identifier && peekToken(2).type == TokenType.LBrace) {
                advance(); advance();
                string name = consume(TokenType.Identifier, "deck symbol expected").text;
                consume(TokenType.LBrace, "deck configuration expected");
                return new NarrativeDeckStmt(name, parseTableConstructor(loc), loc);
            }
            if (current.text == "transaction" && (peekToken(0).type == TokenType.KwDo || isWorldBlockStmt("transaction"))) {
                advance();
                Expr world;
                if (match(TokenType.LParen)) {
                    world = parseExpr(); consume(TokenType.RParen, "')' expected after transaction world");
                }
                consume(TokenType.KwDo, "'do' expected");
                auto body = parseBlock();
                consume(TokenType.KwEnd, "'end' expected after transaction");
                return new TransactionStmt(world, body, loc);
            }
            if (current.text == "rollback" && peekToken(0).type != TokenType.Equal && peekToken(0).type != TokenType.LParen && peekToken(0).type != TokenType.Dot && peekToken(0).type != TokenType.Colon && peekToken(0).type != TokenType.Comma && peekToken(0).type != TokenType.LBracket && peekToken(0).type != TokenType.String && peekToken(0).type != TokenType.LBrace) {
                advance(); return new RollbackStmt(loc);
            }
            if ((current.text == "set" || current.text == "delete" || current.text == "adjust") && peekToken(0).type == TokenType.Identifier)
                return parseUpdateStmt(loc);
            if (current.text == "fact" && peekToken(0).type == TokenType.Identifier) {
                return parseFactStmt(loc);
            }
            if (current.text == "retract" && peekToken(0).type == TokenType.Identifier) {
                return parseRetractStmt(loc);
            }
            if (current.text == "relation" && peekToken(0).type == TokenType.Identifier && peekToken(1).type == TokenType.LParen) {
                return parseRelationDeclStmt(loc);
            }
            if (current.text == "rule" && peekToken(0).type == TokenType.Identifier) {
                return parseRuleDeclStmt(loc);
            }
            if (isWorldBlockStmt()) {
                return parseWorldBlockStmt(loc);
            }
        }

        // Assignment or Function Call starting with prefix expression
        return parseExprOrAssignStmt();
    }

    private Stmt parseLabelStmt() {
        auto loc = current.loc;
        consume(TokenType.DoubleColon, "'::' expected");
        auto label = consume(TokenType.Identifier, "<name> expected").text;
        consume(TokenType.DoubleColon, "'::' expected");
        return new LabelStmt(label, loc);
    }

    private Stmt parseReturnStmt() {
        auto loc = current.loc;
        advance(); // consume 'return'
        Expr[] values;

        if (!isBlockEnd() && !check(TokenType.Semicolon)) {
            values = parseExprList();
        }

        match(TokenType.Semicolon); // optional trailing semicolon
        return new ReturnStmt(values, loc);
    }

    private Stmt parseIfStmt(SourceLoc loc) {
        IfBranch[] branches;

        // First if
        auto cond = parseExpr();
        consume(TokenType.KwThen, "'then' expected");
        int thenLine = previous.loc.line;
        auto body = parseBlock();
        branches ~= IfBranch(cond, body, loc, thenLine);

        // elseif branches
        while (match(TokenType.KwElseIf)) {
            auto branchLoc = previous.loc;
            auto elifCond = parseExpr();
            consume(TokenType.KwThen, "'then' expected");
            int elifThenLine = previous.loc.line;
            auto elifBody = parseBlock();
            branches ~= IfBranch(elifCond, elifBody, branchLoc, elifThenLine);
        }

        // else branch
        BlockStmt elseBody = null;
        if (match(TokenType.KwElse)) {
            elseBody = parseBlock();
        }

        checkMatch(TokenType.KwEnd, "'end'", "'if'", loc.line);
        return new IfStmt(branches, elseBody, loc);
    }

    private Stmt parseForStmt(SourceLoc loc) {
        int savedLocals = activeLocals[$ - 1];
        scope(exit) activeLocals[$ - 1] = savedLocals;
        auto varName = consume(TokenType.Identifier, "<name> expected").text;

        if (!check(TokenType.Equal) && !check(TokenType.Comma) && !check(TokenType.KwIn))
            syntaxError("'=' or 'in' expected", current);
        if (match(TokenType.Equal)) {
            declareLocals(4);
            // Numeric for: for var = start, limit [, step] do body end
            auto start = parseExpr();
            consume(TokenType.Comma, "',' expected");
            auto limit = parseExpr();
            Expr step = null;
            if (match(TokenType.Comma)) {
                step = parseExpr();
            }
            consume(TokenType.KwDo, "'do' expected");
            auto body = parseBlock();
            checkMatch(TokenType.KwEnd, "'end'", "'for'", loc.line);
            return new ForNumericStmt(varName, start, limit, step, body, loc);
        } else {
            // Generic for: for var1, var2 in explist do body end
            string[] varNames = [varName];
            declareLocals(5);
            while (match(TokenType.Comma)) {
                varNames ~= consume(TokenType.Identifier, "<name> expected").text;
                declareLocals(1);
            }
            consume(TokenType.KwIn, "'in' expected");
            auto iterators = parseExprList();
            consume(TokenType.KwDo, "'do' expected");
            auto body = parseBlock();
            checkMatch(TokenType.KwEnd, "'end'", "'for'", loc.line);
            return new ForGenericStmt(varNames, iterators, body, loc);
        }
    }

    private Stmt parseFunctionDecl(bool isLocal, SourceLoc loc) {
        if (isLocal) {
            auto name = consume(TokenType.Identifier, "<name> expected").text;
            declareLocals();
            auto def = parseFunctionDef(loc);
            return new FunctionDeclStmt(new VariableExpr(name, loc), def, true, name, loc);
        }

        // Global / Member function: Name {'.' Name} [':' Name]
        auto nameToken = consume(TokenType.Identifier, "<name> expected");
        Expr target = new VariableExpr(nameToken.text, nameToken.loc);
        bool isMethod = false;

        while (match(TokenType.Dot)) {
            auto field = consume(TokenType.Identifier, "<name> expected").text;
            target = new FieldExpr(target, field, previous.loc);
        }

        if (match(TokenType.Colon)) {
            auto method = consume(TokenType.Identifier, "<name> expected").text;
            target = new FieldExpr(target, method, previous.loc);
            isMethod = true;
        }

        auto def = parseFunctionDef(loc, isMethod);
        return new FunctionDeclStmt(target, def, false, "", loc);
    }

    private Stmt parseLocalDecl(SourceLoc loc) {
        string[] names;
        string[] attributes;
        string attribute;
        // Lua 5.4 attributes: <const> or <close>
        names ~= parseNameWithAttribute(attribute);
        attributes ~= attribute;
        declareLocals();

        while (match(TokenType.Comma)) {
            names ~= parseNameWithAttribute(attribute);
            attributes ~= attribute;
            declareLocals();
        }

        Expr[] values = null;
        if (match(TokenType.Equal)) {
            values = parseExprList();
        }

        auto declaration = new LocalDeclStmt(names, values, loc);
        bool hasClose;
        foreach (attr; attributes) if (attr == "close") {
            if (hasClose) syntaxErrorNoNear("multiple to-be-closed variables in local list", previous.loc.line);
            hasClose = true;
        }
        declaration.attributes = attributes;
        return declaration;
    }

    private string parseNameWithAttribute(out string attribute) {
        auto name = consume(TokenType.Identifier, "<name> expected").text;
        if (match(TokenType.Less)) {
            // Attribute: <const> or <close>
            auto attr = consume(TokenType.Identifier, "<name> expected").text;
            consume(TokenType.Greater, "'>' expected");
            if (attr != "const" && attr != "close") syntaxErrorNoNear("unknown attribute '" ~ attr ~ "'", previous.loc.line);
            attribute = attr;
        }
        return name;
    }

    private Stmt parseExprOrAssignStmt() {
        auto loc = current.loc;
        auto expr = parsePrefixExpr();

        // Check if this is a function call statement
        if (cast(CallExpr)expr !is null || cast(MethodCallExpr)expr !is null) {
            if (!check(TokenType.Comma) && !check(TokenType.Equal)) {
                return new CallStmt(expr, loc);
            }
        }

        // Otherwise, it must be an assignment: varlist '=' explist
        bool isVariable(Expr e) { return !e.parenthesized && (cast(VariableExpr)e !is null || cast(IndexExpr)e !is null || cast(FieldExpr)e !is null); }
        if (!check(TokenType.Comma) && !check(TokenType.Equal)) syntaxError("syntax error", current);
        if (!isVariable(expr)) syntaxError("syntax error", current);
        Expr[] targets = [expr];
        while (match(TokenType.Comma)) {
            if (targets.length + nestingLevel > 195) syntaxError("too many C levels (limit is 200)", current);
            auto target = parsePrefixExpr();
            if (!isVariable(target)) syntaxError("syntax error", current);
            targets ~= target;
        }

        consume(TokenType.Equal, "'=' expected");
        auto values = parseExprList();
        return new AssignStmt(targets, values, loc);
    }

    // -------------------------------------------------------------------------
    // Expressions
    // -------------------------------------------------------------------------

    Expr[] parseExprList() {
        Expr[] list = [parseExpr()];
        while (match(TokenType.Comma)) {
            list ~= parseExpr();
        }
        return list;
    }

    private size_t expressionDepth;

    Expr parseExpr() {
        expressionDepth++;
        scope(exit) expressionDepth--;
        return parseBinaryExpr(0);
    }

    // Binary operator precedence table
    private static struct OpInfo {
        BinaryOp op;
        int leftPrec;
        int rightPrec;
    }

    private static bool getBinaryOpInfo(TokenType type, out OpInfo info) {
        switch (type) {
            case TokenType.KwOr:
                info = OpInfo(BinaryOp.Or, 1, 1); return true;
            case TokenType.KwAnd:
                info = OpInfo(BinaryOp.And, 2, 2); return true;
            case TokenType.Less:
                info = OpInfo(BinaryOp.Lt, 3, 3); return true;
            case TokenType.Greater:
                info = OpInfo(BinaryOp.Gt, 3, 3); return true;
            case TokenType.LessEqual:
                info = OpInfo(BinaryOp.Le, 3, 3); return true;
            case TokenType.GreaterEqual:
                info = OpInfo(BinaryOp.Ge, 3, 3); return true;
            case TokenType.TildeEqual:
                info = OpInfo(BinaryOp.Ne, 3, 3); return true;
            case TokenType.DoubleEqual:
                info = OpInfo(BinaryOp.Eq, 3, 3); return true;
            case TokenType.Pipe:
                info = OpInfo(BinaryOp.BOr, 4, 4); return true;
            case TokenType.Tilde:
                info = OpInfo(BinaryOp.BXor, 5, 5); return true;
            case TokenType.Ampersand:
                info = OpInfo(BinaryOp.BAnd, 6, 6); return true;
            case TokenType.DoubleLess:
                info = OpInfo(BinaryOp.Shl, 7, 7); return true;
            case TokenType.DoubleGreater:
                info = OpInfo(BinaryOp.Shr, 7, 7); return true;
            case TokenType.DoubleDot: // Right-associative
                info = OpInfo(BinaryOp.Concat, 9, 8); return true;
            case TokenType.Plus:
                info = OpInfo(BinaryOp.Add, 10, 10); return true;
            case TokenType.Minus:
                info = OpInfo(BinaryOp.Sub, 10, 10); return true;
            case TokenType.Star:
                info = OpInfo(BinaryOp.Mul, 11, 11); return true;
            case TokenType.Slash:
                info = OpInfo(BinaryOp.Div, 11, 11); return true;
            case TokenType.DoubleSlash:
                info = OpInfo(BinaryOp.IDiv, 11, 11); return true;
            case TokenType.Percent:
                info = OpInfo(BinaryOp.Mod, 11, 11); return true;
            case TokenType.Caret: // Right-associative
                info = OpInfo(BinaryOp.Pow, 14, 13); return true;
            default:
                return false;
        }
    }

    private Expr parseBinaryExpr(int minPrec) {
        enterLevel();
        scope(exit) --nestingLevel;
        auto left = parseUnaryExpr();

        while (true) {
            OpInfo info;
            if (!getBinaryOpInfo(current.type, info)) {
                break;
            }

            if (info.leftPrec <= minPrec) {
                break;
            }

            advance(); // consume operator
            auto loc = previous.loc;
            auto right = parseBinaryExpr(info.rightPrec);
            auto folded = foldBinary(info.op, left, right, loc);
            left = folded !is null ? folded : new BinaryExpr(info.op, left, right, loc);
            left.lastTokenLine = previous.loc.line;
        }

        return left;
    }

    private Expr parseUnaryExpr() {
        auto loc = current.loc;

        UnaryOp op;
        bool unary = true;
        if (match(TokenType.Minus)) op = UnaryOp.Neg;
        else if (match(TokenType.KwNot)) op = UnaryOp.Not;
        else if (match(TokenType.Hash)) op = UnaryOp.Len;
        else if (match(TokenType.Tilde)) op = UnaryOp.BitNot;
        else unary = false;
        if (unary) {
            auto operand = parseBinaryExpr(12);
            auto folded = foldUnary(op, operand, loc);
            auto expression = folded !is null ? folded : new UnaryExpr(op, operand, loc);
            expression.lastTokenLine = previous.loc.line;
            return expression;
        }

        auto primary = parsePrimaryExpr();
        if (primary.lastTokenLine == 0) primary.lastTokenLine = previous.loc.line;
        return primary;
    }

    private Expr parsePrimaryExpr() {
        auto loc = current.loc;

        if (match(TokenType.KwNil)) {
            return new LiteralNilExpr(loc);
        }
        if (match(TokenType.KwFalse)) {
            return new LiteralBoolExpr(false, loc);
        }
        if (match(TokenType.KwTrue)) {
            return new LiteralBoolExpr(true, loc);
        }
        if (match(TokenType.Integer)) {
            return new LiteralIntExpr(previous.intValue, loc);
        }
        if (match(TokenType.Float)) {
            return new LiteralFloatExpr(previous.floatValue, loc);
        }
        if (match(TokenType.String)) {
            return new LiteralStringExpr(previous.text, loc);
        }
        if (match(TokenType.TripleDot)) {
            if (!varargContext[$ - 1]) syntaxError("cannot use '...' outside a vararg function", previous);
            return new VarargExpr(loc);
        }
        if (match(TokenType.LBrace)) {
            return parseTableConstructor(loc);
        }
        if (match(TokenType.KwFunction)) {
            return parseFunctionDef(loc);
        }

        if (match(TokenType.Colon)) {
            auto name = consume(TokenType.Identifier, "<name> expected for symbol literal").text;
            return new SymbolLiteralExpr(name, loc);
        }

        if (check(TokenType.Identifier) && current.text == "query") {
            if (peekToken(0).type == TokenType.Identifier || peekToken(0).type == TokenType.LBrace) {
                advance(); // consume "query"
                return parseQueryExpr(loc);
            }
        }

        if (match(TokenType.Question)) {
            if (!inDeclarative) {
                syntaxError("unexpected symbol", previous);
            }
            auto varTok = consume(TokenType.Identifier, "<name> expected for logic variable");
            if (varTok.text == "_") {
                return new LogicVarExpr("_", true, loc);
            }
            return new LogicVarExpr(varTok.text, false, loc);
        }

        return parsePrefixExpr();
    }

    private bool isMethodSuffix() {
        if (!aggregateExpressionMode || expressionDepth > aggregateExpressionDepth) return true;
        if (peekToken(0).type != TokenType.Identifier) return false;
        size_t end = 1;
        auto opening = peekToken(end).type;
        if (opening == TokenType.LParen || opening == TokenType.LBrace) {
            auto closing = opening == TokenType.LParen ? TokenType.RParen : TokenType.RBrace;
            int depth = 1;
            while (depth) {
                auto token = peekToken(++end).type;
                if (token == TokenType.EOF) return false;
                if (token == opening) depth++;
                if (token == closing) depth--;
            }
        } else if (opening != TokenType.String) return false;
        auto following = peekToken(end + 1).type;
        // A relation goal after the separator ends at a comma or aggregate brace.
        return following != TokenType.Comma && following != TokenType.RBrace && following != TokenType.EOF;
    }

    private Expr parsePrefixExpr() {
        auto loc = current.loc;
        Expr expr;

        if (match(TokenType.LParen)) {
            expr = parseExpr();
            checkMatch(TokenType.RParen, "')'", "'('", loc.line);
            expr.parenthesized = true;
        } else if (match(TokenType.Identifier)) {
            expr = new VariableExpr(previous.text, loc);
        } else {
            syntaxError("unexpected symbol", current);
        }

        // Suffixes: field access (.name), index ([exp]), method call (:name(...)), function call ((...))
        while (true) {
            auto suffixLoc = current.loc;

            if (match(TokenType.Dot)) {
                auto field = consume(TokenType.Identifier, "<name> expected").text;
                expr = new FieldExpr(expr, field, suffixLoc);
                expr.lastTokenLine = previous.loc.line;
            } else if (match(TokenType.LBracket)) {
                auto key = parseExpr();
                consume(TokenType.RBracket, "']' expected");
                expr = new IndexExpr(expr, key, suffixLoc);
                expr.lastTokenLine = previous.loc.line;
            } else if (isMethodSuffix() && check(TokenType.Colon) && (!inDeclarative || (peekToken(0).type == TokenType.Identifier &&
                       (peekToken(1).type == TokenType.LParen || peekToken(1).type == TokenType.LBrace || peekToken(1).type == TokenType.String)))) {
                advance();
                auto method = consume(TokenType.Identifier, "<name> expected").text;
                int nameLine = previous.loc.line;
                int argsLine = current.loc.line;
                Expr[] args = parseArgs();
                auto methodCall = new MethodCallExpr(expr, method, args, suffixLoc);
                methodCall.nameLine = nameLine; methodCall.argsLine = argsLine;
                expr = methodCall;
            } else if (check(TokenType.LParen) || check(TokenType.LBrace) || check(TokenType.String)) {
                Expr[] args = parseArgs();
                expr = new CallExpr(expr, args, suffixLoc);
                expr.lastTokenLine = previous.loc.line;
            } else {
                break;
            }
        }

        return expr;
    }

    private Expr[] parseArgs() {
        auto loc = current.loc;

        if (match(TokenType.LParen)) {
            Expr[] args;
            if (!check(TokenType.RParen)) {
                args = parseExprList();
            }
            checkMatch(TokenType.RParen, "')'", "'('", loc.line);
            return args;
        } else if (match(TokenType.LBrace)) {
            return [parseTableConstructor(loc)];
        } else if (match(TokenType.String)) {
            return [new LiteralStringExpr(previous.text, loc)];
        }

        syntaxError("function arguments expected", current);
        return [];
    }

    private TableConstructorExpr parseTableConstructor(SourceLoc loc) {
        TableField[] fields;

        while (!check(TokenType.RBrace)) {
            auto fieldLoc = current.loc;

            if (match(TokenType.LBracket)) {
                // [exp] = exp
                auto key = parseExpr();
                consume(TokenType.RBracket, "']' expected");
                consume(TokenType.Equal, "'=' expected");
                auto val = parseExpr();
                fields ~= TableField(key, val);
            } else if (check(TokenType.Identifier) && lexer.peekToken().type == TokenType.Equal) {
                // Name = exp
                auto keyName = consume(TokenType.Identifier, "<name> expected").text;
                consume(TokenType.Equal, "'=' expected");
                auto val = parseExpr();
                fields ~= TableField(new LiteralStringExpr(keyName, fieldLoc), val);
            } else {
                // List exp
                auto val = parseExpr();
                fields ~= TableField(null, val);
            }

            // Field separator: comma or semicolon
            if (!match(TokenType.Comma) && !match(TokenType.Semicolon)) {
                break;
            }
        }

        checkMatch(TokenType.RBrace, "'}'", "'{'", loc.line);
        return new TableConstructorExpr(fields, loc);
    }

    private FunctionDefExpr parseFunctionDef(SourceLoc loc, bool isMethod = false) {
        consume(TokenType.LParen, "'(' expected");

        string[] params;
        bool isVararg = false;
        // The function's context is active while its parameters are parsed, so that the limit on
        // local variables is reported at the offending parameter, as lparser.c does.
        activeLocals ~= 0;
        functionStartLines ~= loc.line;
        varargContext ~= false;
        scope(exit) { varargContext.length--; activeLocals.length--; functionStartLines.length--; }

        if (isMethod) {
            params ~= "self";
            declareLocals();
        }

        if (!check(TokenType.RParen)) {
            if (match(TokenType.TripleDot)) {
                isVararg = true;
            } else {
                params ~= consume(TokenType.Identifier, "<name> or '...' expected").text;
                declareLocals();
                while (match(TokenType.Comma)) {
                    if (match(TokenType.TripleDot)) {
                        isVararg = true;
                        break;
                    }
                    params ~= consume(TokenType.Identifier, "<name> or '...' expected").text;
                    declareLocals();
                }
            }
        }

        consume(TokenType.RParen, "')' expected");
        varargContext[$ - 1] = isVararg;
        auto body = parseBlock();
        checkMatch(TokenType.KwEnd, "'end'", "'function'", loc.line);

        auto definition = new FunctionDefExpr(params, isVararg, body, loc);
        definition.endLine = previous.loc.line;
        return definition;
    }

    // -------------------------------------------------------------------------
    // Declarative Syntax Parsing (Phase 6)
    // -------------------------------------------------------------------------

    private AstRelRef parseRelRef() {
        auto loc = current.loc;
        string[] parts;
        auto first = consume(TokenType.Identifier, "relation name expected").text;
        parts ~= first;
        while (match(TokenType.Dot)) {
            auto next = consume(TokenType.Identifier, "relation name expected after '.'").text;
            parts ~= next;
        }
        if (parts.length == 1) {
            return new AstRelRef([], parts[0], loc);
        } else {
            return new AstRelRef(parts[0 .. $ - 1], parts[$ - 1], loc);
        }
    }

    private Stmt parseFactStmt(SourceLoc loc) {
        advance(); // consume "fact"
        auto relRef = parseRelRef();
        consume(TokenType.LParen, "'(' expected after relation name in fact");
        Expr[] args;
        if (!check(TokenType.RParen)) {
            while (true) {
                args ~= parseExpr();
                if (!match(TokenType.Comma)) break;
                if (check(TokenType.RParen)) {
                    syntaxError("trailing comma not permitted in fact arguments", previous);
                }
            }
        }
        consume(TokenType.RParen, "')' expected to close fact arguments");
        return new FactStmt(relRef, args, loc);
    }

    private Stmt parseRetractStmt(SourceLoc loc) {
        advance(); // consume "retract"
        auto relRef = parseRelRef();
        consume(TokenType.LParen, "'(' expected after relation name in retract");
        Expr[] args;
        if (!check(TokenType.RParen)) {
            while (true) {
                args ~= parseExpr();
                if (!match(TokenType.Comma)) break;
                if (check(TokenType.RParen)) {
                    syntaxError("trailing comma not permitted in retract arguments", previous);
                }
            }
        }
        consume(TokenType.RParen, "')' expected to close retract arguments");
        return new RetractStmt(relRef, args, loc);
    }

    private AstGoal[] parseWhenClause() {
        auto when = consume(TokenType.Identifier, "'when' expected");
        if (when.text != "when") syntaxError("'when' expected", when);
        consume(TokenType.LBrace, "'{' expected after when");
        AstGoal[] goals;
        do {
            goals ~= parseGoal();
            if (!match(TokenType.Comma)) break;
        } while (true);
        consume(TokenType.RBrace, "'}' expected after availability goals");
        return goals;
    }

    private NarrativeDefinitionStmt parseNarrativeDefinition(string kind, SourceLoc loc) {
        advance();
        string name = consume(TokenType.Identifier, "content identifier expected").text;
        auto definition = new NarrativeDefinitionStmt(kind, name, loc);
        if (kind != "choice" || check(TokenType.LParen)) {
            consume(TokenType.LParen, "'(' expected after content identifier");
            if (!check(TokenType.RParen)) do {
                consume(TokenType.Question, "logic parameter expected");
                string parameter = consume(TokenType.Identifier, "parameter name expected").text;
                if (parameter == "_") syntaxError("anonymous content parameter is prohibited", previous);
                definition.parameters ~= parameter;
                if (!match(TokenType.Comma)) break;
            } while (true);
            consume(TokenType.RParen, "')' expected after parameters");
        }
        if (kind != "choice" || (check(TokenType.Identifier) && current.text == "when")) definition.goals = parseWhenClause();
        bool[string] fields;
        while (check(TokenType.Identifier)) {
            string field = current.text;
            if (field == "choice" || field == "effect") break;
            bool allowed = kind != "action" && (field == "title" || field == "text");
            if (kind == "storylet") allowed = allowed || field == "deck" || field == "priority" || field == "weight" || field == "cooldown" || field == "repeatable";
            if (kind == "action") allowed = field == "phase" || field == "priority" || field == "once_per";
            if (!allowed) syntaxError("invalid " ~ kind ~ " field '" ~ field ~ "'", current);
            if (field in fields) syntaxError("duplicate content field '" ~ field ~ "'", current);
            fields[field] = true;
            advance();
            definition.fieldNames ~= field;
            if (field == "title" || field == "text") {
                auto value = consume(TokenType.String, "template string literal expected");
                definition.fieldValues ~= new LiteralStringExpr(value.text, value.loc);
            } else definition.fieldValues ~= parseExpr();
        }
        if (kind == "storylet") {
            while (check(TokenType.Identifier) && current.text == "choice")
                definition.choices ~= parseNarrativeDefinition("choice", current.loc);
            if (!definition.choices.length) syntaxError("storylet requires at least one choice", current);
        } else {
            auto effect = consume(TokenType.Identifier, "'effect' expected");
            if (effect.text != "effect") syntaxError("'effect' expected", effect);
            consume(TokenType.KwDo, "'do' expected after effect");
            definition.effect = parseBlock();
            consume(TokenType.KwEnd, "'end' expected after effect");
        }
        consume(TokenType.KwEnd, "'end' expected after " ~ kind);
        return definition;
    }

    private Stmt parseUpdateStmt(SourceLoc loc) {
        string operation = current.text;
        advance();
        auto reference = parseRelRef();
        consume(TokenType.LParen, "'(' expected after relation name");
        Expr[] args;
        if (!check(TokenType.RParen)) {
            do {
                args ~= parseExpr();
                if (!match(TokenType.Comma)) break;
                if (check(TokenType.RParen)) syntaxError("trailing comma in update", current);
            } while (true);
        }
        consume(TokenType.RParen, "')' expected after update arguments");
        Expr delta;
        if (operation == "adjust") {
            auto by = consume(TokenType.Identifier, "'by' expected after adjust key");
            if (by.text != "by") syntaxError("'by' expected after adjust key", by);
            delta = parseExpr();
        }
        return new UpdateStmt(operation, reference, args, delta, loc);
    }

    private Stmt parseRelationDeclStmt(SourceLoc loc) {
        advance();
        auto name = consume(TokenType.Identifier, "relation name expected").text;
        consume(TokenType.LParen, "'(' expected after relation name");
        if (check(TokenType.Integer)) {
            auto intTok = current;
            advance();
            consume(TokenType.RParen, "')' expected after relation arity");
            return new RelationDeclStmt(name, cast(int)intTok.intValue, loc);
        }
        string[] columns;
        if (!check(TokenType.RParen)) {
            do {
                columns ~= consume(TokenType.Identifier, "column name expected").text;
                if (!match(TokenType.Comma)) break;
            } while (true);
        }
        consume(TokenType.RParen, "')' expected after column names");
        string[] keys;
        if (check(TokenType.Identifier) && current.text == "key" && peekToken(0).type == TokenType.LParen) {
            advance(); advance();
            do {
                keys ~= consume(TokenType.Identifier, "key column expected").text;
                if (!match(TokenType.Comma)) break;
            } while (true);
            consume(TokenType.RParen, "')' expected after keys");
        }
        auto declaration = new RelationDeclStmt(name, cast(int)columns.length, loc);
        declaration.columns = columns; declaration.keys = keys; declaration.named = true;
        return declaration;
    }

    private Stmt parseLocalRelationDeclStmt(SourceLoc loc) {
        advance(); // consume "relation"
        auto name = consume(TokenType.Identifier, "relation name expected").text;
        consume(TokenType.LParen, "'(' expected after relation name");
        auto intTok = consume(TokenType.Integer, "integer arity expected");
        consume(TokenType.RParen, "')' expected after relation arity");
        return new LocalRelationDeclStmt(name, cast(int)intTok.intValue, loc);
    }

    private bool isWorldBlockStmt(string keyword = "logic") {
        if (!check(TokenType.Identifier) || current.text != keyword) return false;
        if (peekToken(0).type != TokenType.LParen) return false;
        size_t k = 1;
        int parenDepth = 1;
        while (parenDepth > 0) {
            auto tok = peekToken(k++);
            if (tok.type == TokenType.EOF) return false;
            if (tok.type == TokenType.LParen) parenDepth++;
            else if (tok.type == TokenType.RParen) parenDepth--;
        }
        return peekToken(k).type == TokenType.KwDo;
    }

    private Stmt parseWorldBlockStmt(SourceLoc loc) {
        advance(); // consume "logic"
        consume(TokenType.LParen, "'(' expected after 'logic'");
        auto worldExpr = parseExpr();
        consume(TokenType.RParen, "')' expected after world expression");
        consume(TokenType.KwDo, "'do' expected to start world block");
        auto body = parseBlock();
        consume(TokenType.KwEnd, "'end' expected to close world block");
        return new WorldBlockStmt(worldExpr, body, loc);
    }

    private Stmt parseRuleDeclStmt(SourceLoc loc) {
        advance(); // consume "rule"
        auto headRel = parseRelRef();
        consume(TokenType.LParen, "'(' expected after rule head relation name");
        Expr[] headArgs;
        if (!check(TokenType.RParen)) {
            while (true) {
                headArgs ~= parseDeclarativeTerm();
                if (!match(TokenType.Comma)) break;
                if (check(TokenType.RParen)) {
                    syntaxError("trailing comma not permitted in rule head", previous);
                }
            }
        }
        consume(TokenType.RParen, "')' expected to close rule head");
        consume(TokenType.RuleOp, "':-' expected after rule head");

        AstGoal[] goals;
        while (true) {
            goals ~= parseGoal();
            if (match(TokenType.Comma)) {
                if (!isGoalStart() || check(TokenType.EOF) || isBlockEnd()) {
                    syntaxError("trailing comma not permitted in rule body", previous);
                }
            } else {
                break;
            }
        }
        return new RuleDeclStmt(headRel, headArgs, goals, loc);
    }

    private Expr parseDeclarativeTerm() {
        auto loc = current.loc;
        if (match(TokenType.Question)) {
            auto varTok = consume(TokenType.Identifier, "<name> expected for logic variable");
            if (varTok.text == "_") {
                return new LogicVarExpr("_", true, loc);
            }
            return new LogicVarExpr(varTok.text, false, loc);
        }

        bool saved = inDeclarative;
        inDeclarative = false;
        scope(exit) inDeclarative = saved;
        return parseExpr();
    }

    private bool isGoalStart() {
        if (check(TokenType.KwNot)) return true;
        if (check(TokenType.Question)) return true;
        if (check(TokenType.Identifier)) return true;
        if (check(TokenType.Colon) || check(TokenType.Integer) || check(TokenType.Float) || check(TokenType.String) || check(TokenType.LParen)) return true;
        return false;
    }

    private bool aggregateExpressionMode;
    private size_t aggregateExpressionDepth;

    private AstGoal parseGoal() {
        auto loc = current.loc;
        if (check(TokenType.Question) && peekToken(0).type == TokenType.Identifier && peekToken(1).type == TokenType.Equal) {
            advance();
            string result = consume(TokenType.Identifier, "aggregate result variable expected").text;
            if (result == "_") syntaxError("anonymous aggregate result is prohibited", previous);
            consume(TokenType.Equal, "'=' expected before aggregate");
            string operation = consume(TokenType.Identifier, "aggregate operator expected").text;
            if (operation != "count" && operation != "sum" && operation != "min" && operation != "max")
                syntaxError("unknown aggregate operator", previous);
            consume(TokenType.LBrace, "'{' expected after aggregate");
            Expr expression;
            if (operation != "count") {
                bool saved = inDeclarative;
                inDeclarative = true;
                bool previousMode = aggregateExpressionMode;
                aggregateExpressionMode = true;
                auto previousDepth = aggregateExpressionDepth;
                aggregateExpressionDepth = expressionDepth + 1;
                expression = parseExpr();
                aggregateExpressionDepth = previousDepth;
                aggregateExpressionMode = previousMode;
                inDeclarative = saved;
                consume(TokenType.Colon, "':' expected after aggregate expression");
            }
            AstGoal[] goals;
            do {
                goals ~= parseGoal();
                if (!match(TokenType.Comma)) break;
            } while (true);
            consume(TokenType.RBrace, "'}' expected after aggregate goals");
            return new AstAggregateGoal(result, operation, expression, goals, loc);
        }

        // 1. Negated atom: not relatom
        if (match(TokenType.KwNot)) {
            auto relRef = parseRelRef();
            consume(TokenType.LParen, "'(' expected after relation name in negated atom");
            Expr[] terms;
            if (!check(TokenType.RParen)) {
                while (true) {
                    terms ~= parseDeclarativeTerm();
                    if (!match(TokenType.Comma)) break;
                    if (check(TokenType.RParen)) {
                        syntaxError("trailing comma not permitted in negated atom terms", previous);
                    }
                }
            }
            consume(TokenType.RParen, "')' expected after negated atom terms");
            return new AstRelAtomGoal(relRef, terms, true, loc);
        }

        // 2. Guard: where ( guardexp )
        if (check(TokenType.Identifier) && current.text == "where" && peekToken(0).type == TokenType.LParen) {
            advance(); // consume "where"
            consume(TokenType.LParen, "'(' expected after 'where'");
            bool saved = inDeclarative;
            inDeclarative = true;
            scope(exit) inDeclarative = saved;
            auto guardExpr = parseExpr();
            consume(TokenType.RParen, "')' expected after guard expression");
            return new AstGuardGoal(guardExpr, loc);
        }

        // 3. Comparison or positive relation atom
        if (check(TokenType.Question)) {
            auto left = parseDeclarativeTerm();
            CompareOp op = parseCompareOp();
            auto right = parseDeclarativeTerm();
            return new AstComparisonGoal(left, op, right, loc);
        }

        if (check(TokenType.Identifier)) {
            if (isCompareOp(peekToken(0).type)) {
                auto left = parseDeclarativeTerm();
                CompareOp op = parseCompareOp();
                auto right = parseDeclarativeTerm();
                return new AstComparisonGoal(left, op, right, loc);
            }
            auto relRef = parseRelRef();
            consume(TokenType.LParen, "'(' expected after relation name");
            Expr[] terms;
            if (!check(TokenType.RParen)) {
                while (true) {
                    terms ~= parseDeclarativeTerm();
                    if (!match(TokenType.Comma)) break;
                    if (check(TokenType.RParen)) {
                        syntaxError("trailing comma not permitted in relation terms", previous);
                    }
                }
            }
            consume(TokenType.RParen, "')' expected after relation terms");
            return new AstRelAtomGoal(relRef, terms, false, loc);
        }

        auto left = parseDeclarativeTerm();
        CompareOp op = parseCompareOp();
        auto right = parseDeclarativeTerm();
        return new AstComparisonGoal(left, op, right, loc);
    }

    private bool isCompareOp(TokenType t) {
        return t == TokenType.DoubleEqual ||
               t == TokenType.TildeEqual ||
               t == TokenType.Less ||
               t == TokenType.LessEqual ||
               t == TokenType.Greater ||
               t == TokenType.GreaterEqual;
    }

    private CompareOp parseCompareOp() {
        if (match(TokenType.DoubleEqual)) return CompareOp.Eq;
        if (match(TokenType.TildeEqual)) return CompareOp.Neq;
        if (match(TokenType.Less)) return CompareOp.Lt;
        if (match(TokenType.LessEqual)) return CompareOp.Le;
        if (match(TokenType.Greater)) return CompareOp.Gt;
        if (match(TokenType.GreaterEqual)) return CompareOp.Ge;
        syntaxError("comparison operator expected (==, ~=, <, <=, >, >=)", current);
        return CompareOp.Eq;
    }

    private Expr parseQueryExpr(SourceLoc loc) {
        if (match(TokenType.LBrace)) {
            AstGoal[] goals;
            while (!check(TokenType.RBrace)) {
                goals ~= parseGoal();
                if (match(TokenType.Comma)) {
                    if (check(TokenType.RBrace)) {
                        syntaxError("trailing comma not permitted in query body", previous);
                    }
                } else {
                    break;
                }
            }
            consume(TokenType.RBrace, "'}' expected to close query body");
            return new QueryExpr(goals, true, loc);
        } else {
            auto g = parseGoal();
            if (auto atomGoal = cast(AstRelAtomGoal)g) {
                if (atomGoal.isNegated) {
                    syntaxError("simple query must be a positive relation atom", previous);
                }
                return new QueryExpr([atomGoal], false, loc);
            }
            syntaxError("simple query must be a positive relation atom", current);
            return null;
        }
    }
}

// -----------------------------------------------------------------------------
// Constant folding (lcode.c constfolding): numeric operations on numeric literals are evaluated
// at parse time, except division by zero and results that are NaN or zero.
// -----------------------------------------------------------------------------

private struct Numeral {
    bool isInt;
    long i;
    double d;
    double asFloat() const { return isInt ? cast(double)i : d; }
}

private bool numeralOf(Expr e, out Numeral n) {
    if (auto li = cast(LiteralIntExpr)e) { n.isInt = true; n.i = li.value; return true; }
    if (auto lf = cast(LiteralFloatExpr)e) { n.isInt = false; n.d = lf.value; return true; }
    return false;
}

private bool toExactInteger(Numeral n, out long result) {
    import dlua.types : floatToInteger;
    if (n.isInt) { result = n.i; return true; }
    return floatToInteger(n.d, result);
}

private Expr numeralExpr(Numeral n, SourceLoc loc) {
    import std.math : isNaN;
    if (n.isInt) return new LiteralIntExpr(n.i, loc);
    if (isNaN(n.d) || n.d == 0) return null;  // folds neither NaN nor 0.0 (-0.0 problems)
    return new LiteralFloatExpr(n.d, loc);
}

private long shiftLeft(long x, long y) {
    if (y <= -64 || y >= 64) return 0;
    if (y >= 0) return cast(long)(cast(ulong)x << y);
    return cast(long)(cast(ulong)x >> -y);
}

private Expr foldBinary(BinaryOp op, Expr left, Expr right, SourceLoc loc) {
    import core.stdc.math : pow, fmod;
    import std.math : floor;
    Numeral a, b;
    if (!numeralOf(left, a) || !numeralOf(right, b)) return null;
    Numeral r;
    switch (op) {
        case BinaryOp.Add, BinaryOp.Sub, BinaryOp.Mul:
            if (a.isInt && b.isInt) {
                r.isInt = true;
                ulong x = cast(ulong)a.i, y = cast(ulong)b.i;
                r.i = cast(long)(op == BinaryOp.Add ? x + y : op == BinaryOp.Sub ? x - y : x * y);
            } else {
                double x = a.asFloat, y = b.asFloat;
                r.d = op == BinaryOp.Add ? x + y : op == BinaryOp.Sub ? x - y : x * y;
            }
            break;
        case BinaryOp.Div:
            if (b.asFloat == 0) return null;
            r.d = a.asFloat / b.asFloat;
            break;
        case BinaryOp.Pow:
            r.d = pow(a.asFloat, b.asFloat);
            break;
        case BinaryOp.IDiv:
            if (b.asFloat == 0) return null;
            if (a.isInt && b.isInt) {
                r.isInt = true;
                if (b.i == -1) r.i = cast(long)(0UL - cast(ulong)a.i);
                else {
                    long q = a.i / b.i;
                    if ((a.i % b.i != 0) && ((a.i ^ b.i) < 0)) q -= 1;
                    r.i = q;
                }
            } else r.d = floor(a.asFloat / b.asFloat);
            break;
        case BinaryOp.Mod:
            if (b.asFloat == 0) return null;
            if (a.isInt && b.isInt) {
                r.isInt = true;
                if (b.i == -1) r.i = 0;
                else {
                    long m = a.i % b.i;
                    if (m != 0 && (m ^ b.i) < 0) m += b.i;
                    r.i = m;
                }
            } else {
                double x = a.asFloat, y = b.asFloat;
                double m = fmod(x, y);
                if ((m > 0) ? y < 0 : (m < 0 && y > 0)) m += y;
                r.d = m;
            }
            break;
        case BinaryOp.BAnd, BinaryOp.BOr, BinaryOp.BXor, BinaryOp.Shl, BinaryOp.Shr: {
            long x, y;
            if (!toExactInteger(a, x) || !toExactInteger(b, y)) return null;
            r.isInt = true;
            switch (op) {
                case BinaryOp.BAnd: r.i = x & y; break;
                case BinaryOp.BOr: r.i = x | y; break;
                case BinaryOp.BXor: r.i = x ^ y; break;
                case BinaryOp.Shl: r.i = shiftLeft(x, y); break;
                default: r.i = shiftLeft(x, cast(long)(0UL - cast(ulong)y)); break;
            }
            break;
        }
        default:
            return null;
    }
    return numeralExpr(r, loc);
}

private Expr foldUnary(UnaryOp op, Expr operand, SourceLoc loc) {
    Numeral a;
    switch (op) {
        case UnaryOp.Neg:
            if (!numeralOf(operand, a)) return null;
            if (a.isInt) return new LiteralIntExpr(cast(long)(0UL - cast(ulong)a.i), loc);
            a.d = -a.d;
            return numeralExpr(a, loc);
        case UnaryOp.BitNot: {
            long x;
            if (!numeralOf(operand, a) || !toExactInteger(a, x)) return null;
            return new LiteralIntExpr(~x, loc);
        }
        case UnaryOp.Not:
            if (cast(LiteralNilExpr)operand !is null) return new LiteralBoolExpr(true, loc);
            if (auto lb = cast(LiteralBoolExpr)operand) return new LiteralBoolExpr(!lb.value, loc);
            if (numeralOf(operand, a) || cast(LiteralStringExpr)operand !is null) return new LiteralBoolExpr(false, loc);
            return null;
        default:
            return null;
    }
}
