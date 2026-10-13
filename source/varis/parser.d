/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.parser;

import varis.types : LuaValue;

import varis.ast;
import varis.lexer;
import varis.relterms : CompareOp;
import varis.exception : LuaException, shortSourceName;
import std.format : format;
import std.conv : to;

class Parser {
    Lexer lexer;
    Token current;
    Token previous;
    string sourceName;
    Token[] lookahead;
    bool inDeclarative = false;

    /// A syntax error found in recovery mode (tools): its message as the normal mode would
    /// raise it, and where it was found (line 0 when the error carried no token).
    static struct Problem {
        string message;
        int line;
        int column;
        int endLine;
        int endColumn;
    }

    /// Recovery mode is for tools (`varis check`, the language services): a syntax error is
    /// recorded in `problems`, the parser skips to the next statement or definition boundary
    /// and goes on, and `parse` returns a partial tree. The default mode raises the first
    /// error exactly as before; `load`, `require` and their error text never use recovery.
    bool recover;
    Problem[] problems;
    private bool abandoned; // too many errors: stop
    private enum maxProblems = 100;

    this(string source, string sourceName = "=stdin", bool recover = false) {
        varargContext = [true];
        activeLocals = [0];
        functionStartLines = [0];
        this.sourceName = sourceName;
        this.recover = recover;
        this.lexer = new Lexer(source, sourceName);
        if (!recover)
            advance();
        else
            while (!tryAdvance() && lexer.cursor < source.length) {
            }
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

    private string formatSourceName() const {
        return shortSourceName(sourceName);
    }

    private string formatNear(Token tok) const {
        if (tok.type == TokenType.EOF || tok.text == "<eof>") {
            return "<eof>";
        }
        if (tok.type == TokenType.Invalid) {
            ubyte code = cast(ubyte) tok.text[0];
            if (code >= 32 && code < 127)
                return "'" ~ tok.text ~ "'";
            return "'<\\" ~ code.to!string ~ ">'";
        }
        return "'" ~ (tok.raw.length ? tok.raw : tok.text) ~ "'";
    }

    /// check_match: closes a construct, mentioning where it was opened when on another line.
    private void checkMatch(TokenType what, string whatText, string whoText, int whereLine) {
        if (check(what)) {
            advance();
            return;
        }
        if (whereLine == current.loc.line)
            syntaxError(whatText ~ " expected", current);
        else
            syntaxError(whatText ~ " expected (to close " ~ whoText ~ " at line " ~ whereLine.to!string ~ ")", current);
    }

    private void syntaxErrorNoNear(string msg, int line) {
        throw new LuaException(LuaValue(format("%s:%d: %s", formatSourceName(), line, msg)));
    }

    private bool[] varargContext;
    private int nestingLevel;
    private int[] activeLocals; // active local variables per function being parsed
    private int[] functionStartLines; // line where each function being parsed starts

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

    /// The token a syntax error was reported at; tools read it to give the error a range.
    /// Recording it changes nothing the error says.
    Token errorToken;
    bool hasErrorToken;

    private void syntaxError(string msg, Token tok) {
        errorToken = tok;
        hasErrorToken = true;
        throw new LuaException(LuaValue(format("%s:%d: %s near %s", formatSourceName(), tok.loc.line, msg, formatNear(
                tok))));
    }

    private Token consume(TokenType type, string message) {
        if (check(type)) {
            advance();
            return previous;
        }
        syntaxError(message, current);
        return current;
    }

    // -------------------------------------------------------------------------
    // Error recovery (tool mode only)
    // -------------------------------------------------------------------------

    private void note(LuaException failure) {
        Problem problem;
        if (failure.errorObject.isString)
            problem.message = failure.errorObject.asString;
        else
            problem.message = "syntax error";
        if (hasErrorToken) {
            problem.line = errorToken.loc.line;
            problem.column = errorToken.loc.column;
            problem.endLine = errorToken.endLine;
            problem.endColumn = errorToken.endColumn;
            hasErrorToken = false;
        } else {
            // A lexical error: the message begins "chunk:LINE:".
            auto text = problem.message;
            foreach (i; 0 .. text.length)
                if (text[i] == ':') {
                    int line;
                    size_t j = i + 1;
                    while (j < text.length && text[j] >= '0' && text[j] <= '9')
                        line = line * 10 + (text[j++] - '0');
                    if (j > i + 1 && j < text.length && text[j] == ':')
                        problem.line = line;
                    break;
                }
        }
        // Several enclosing definitions fail at the same token (`end` expected at the end of the
        // file): the first message stands.
        if (problems.length && problems[$ - 1].line == problem.line && problems[$ - 1].column == problem.column
                && problem.line > 0)
            return;
        problems ~= problem;
        if (problems.length >= maxProblems)
            abandoned = true;
    }

    /// `advance` that records a lexical error instead of raising it, and always makes progress.
    private bool tryAdvance() {
        auto before = lexer.cursor;
        try {
            advance();
            return true;
        } catch (LuaException failure) {
            note(failure);
            if (lexer.cursor <= before)
                lexer.cursor = before + 1;
            return false;
        }
    }

    /// Is the current token the first of its line, and does it start a statement or definition?
    private bool atBoundary() {
        if (check(TokenType.EOF))
            return true;
        if (previous.endLine >= current.loc.line && previous.type != TokenType.EOF)
            return false;
        switch (current.type) {
        case TokenType.KwLocal:
        case TokenType.KwFunction:
        case TokenType.KwIf:
        case TokenType.KwFor:
        case TokenType.KwWhile:
        case TokenType.KwRepeat:
        case TokenType.KwDo:
        case TokenType.KwReturn:
        case TokenType.KwBreak:
        case TokenType.KwGoto:
            return true;
        case TokenType.Identifier:
            switch (current.text) {
            case "storylet":
            case "scene":
            case "character":
            case "action":
            case "procedure":
            case "deck":
            case "relation":
            case "rule":
            case "fact":
            case "retract":
            case "symbols":
            case "transaction":
            case "rollback":
            case "set":
            case "delete":
            case "adjust":
                return true;
            default:
                break;
            }
            try {
                auto next = peekToken(0).type;
                return next == TokenType.LParen || next == TokenType.Dot || next == TokenType.Colon || next == TokenType
                    .Equal
                    || next == TokenType.Comma;
            } catch (LuaException) {
                return false;
            }
        default:
            return false;
        }
    }

    /// After an error: move to the next token that can start a statement.
    private void synchronize(SourceLoc statementStart) {
        if (current.loc.line == statementStart.line && current.loc.column == statementStart.column && !check(
                TokenType.EOF))
            tryAdvance(); // nothing was consumed: make progress
        while (!abandoned && !check(TokenType.EOF) && !atBoundary())
            tryAdvance();
    }

    /// Runs one statement parse; on an error records it and resynchronizes. Returns null then.
    private Stmt guardedStatement(bool isReturn) {
        auto start = current.loc;
        auto savedVararg = varargContext.length;
        auto savedLocals = activeLocals.length;
        auto savedStarts = functionStartLines.length;
        auto savedNesting = nestingLevel;
        auto savedDeclarative = inDeclarative;
        try {
            return isReturn ? parseReturnStmt() : parseStatement();
        } catch (LuaException failure) {
            note(failure);
            varargContext.length = savedVararg;
            activeLocals.length = savedLocals;
            functionStartLines.length = savedStarts;
            nestingLevel = savedNesting;
            inDeclarative = savedDeclarative;
            synchronize(start);
            return null;
        }
    }

    private BlockStmt parseChunkRecovering() {
        auto loc = current.loc;
        Stmt[] all;
        while (true) {
            all ~= parseBlock().statements;
            if (isAtEnd() || abandoned)
                break;
            // A stray `end`, or statements after `return`: skip it and go on. After an earlier
            // error it is nearly always that error's consequence, so only a first one is reported.
            if (problems.length > 0) {
                tryAdvance();
                continue;
            }
            Problem problem;
            problem.message = format("%s:%d: %s near %s", formatSourceName(), current.loc.line, "<eof> expected",
                    formatNear(current));
            problem.line = current.loc.line;
            problem.column = current.loc.column;
            problem.endLine = current.endLine;
            problem.endColumn = current.endColumn;
            problems ~= problem;
            if (problems.length >= maxProblems)
                break;
            tryAdvance();
        }
        auto block = new BlockStmt(all, loc);
        block.endLine = previous.loc.line > 0 ? previous.loc.line : 1;
        return block;
    }

    /// Parse top-level chunk into BlockStmt
    BlockStmt parse() {
        if (recover)
            return parseChunkRecovering();
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
        scope (exit)
            activeLocals[$ - 1] = savedLocals;

        while (!isAtEnd() && !isBlockEnd() && !abandoned) {
            if (recover) {
                auto guarded = guardedStatement(check(TokenType.KwReturn));
                if (guarded !is null) {
                    stmts ~= guarded;
                    if (as!ReturnStmt(guarded) !is null)
                        break;
                }
                continue;
            }
            if (check(TokenType.KwReturn)) {
                stmts ~= parseReturnStmt();
                break; // In Lua, return is the last statement in a block
            }
            auto stmt = parseStatement();
            if (stmt !is null) {
                stmts ~= stmt;
            }
            // a readable scene also registers the scenes and procedures it generates
            stmts ~= pendingStmts;
            pendingStmts.length = 0;
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
        auto stmt = parseStatementInner();
        if (stmt !is null && previous.endLine > 0)
            stmt.end = SourceLoc(previous.endLine, previous.endColumn);
        return stmt;
    }

    private Stmt parseStatementInner() {
        enterLevel();
        scope (exit)
            --nestingLevel;
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
            if (check(TokenType.Identifier) && current.text == "relation" && peekToken(0)
                    .type == TokenType.Identifier && peekToken(1).type == TokenType.LParen) {
                return parseLocalRelationDeclStmt(loc);
            }
            return parseLocalDecl(loc);
        }

        // `scene name() ... end`: the readable form (milestone 29), lowered to beat tables.
        if (check(TokenType.Identifier) && current.text == "scene" && peekToken(0)
                .type == TokenType.Identifier &&
                peekToken(1).type == TokenType.LParen)
            return parseReadableScene(loc);
        // Scene/character declarations lower to registration calls, keeping the words contextual.
        if (check(TokenType.Identifier) && (current.text == "scene" || current.text == "character") &&
                peekToken(0).type == TokenType.Identifier && peekToken(1).type == TokenType.LBrace) {
            auto kind = current.text;
            advance();
            auto name = consume(TokenType.Identifier, "content identifier expected");
            consume(TokenType.LBrace, "content body expected");
            auto body = parseTableConstructor(loc);
            auto identifier = new SymbolLiteralExpr(name.text, name.loc);
            identifier.end = SourceLoc(name.endLine, name.endColumn);
            auto call = new CallExpr(new FieldExpr(new VariableExpr("narrative", loc), kind, loc), [
                identifier, body
            ], loc);
            call.end = SourceLoc(previous.endLine, previous.endColumn);
            return new CallStmt(call, loc);
        }
        // Declarative Statements (Phase 6)
        if (check(TokenType.Identifier)) {
            if ((current.text == "storylet" || current.text == "action" || current.text == "procedure") && peekToken(0)
                    .type == TokenType.Identifier && peekToken(1).type == TokenType.LParen)
                return parseNarrativeDefinition(current.text, loc);
            if (current.text == "deck" && peekToken(0).type == TokenType.Colon && peekToken(1)
                    .type == TokenType.Identifier && peekToken(2).type == TokenType.LBrace) {
                advance();
                advance();
                auto nameToken = consume(TokenType.Identifier, "deck symbol expected");
                consume(TokenType.LBrace, "deck configuration expected");
                auto deck = new NarrativeDeckStmt(nameToken.text, parseTableConstructor(loc), loc);
                deck.nameLoc = nameToken.loc;
                deck.nameEnd = SourceLoc(nameToken.endLine, nameToken.endColumn);
                return deck;
            }
            if (current.text == "transaction" && (peekToken(0).type == TokenType.KwDo || isWorldBlockStmt("transaction"))) {
                advance();
                Expr world;
                if (match(TokenType.LParen)) {
                    world = parseExpr();
                    consume(TokenType.RParen, "')' expected after transaction world");
                }
                consume(TokenType.KwDo, "'do' expected");
                auto body = parseBlock();
                consume(TokenType.KwEnd, "'end' expected after transaction");
                return new TransactionStmt(world, body, loc);
            }
            if (current.text == "rollback" && peekToken(0).type != TokenType.Equal && peekToken(0)
                    .type != TokenType.LParen && peekToken(0).type != TokenType.Dot && peekToken(0)
                    .type != TokenType.Colon && peekToken(0).type != TokenType.Comma && peekToken(0)
                    .type != TokenType.LBracket && peekToken(0).type != TokenType.String && peekToken(0).type != TokenType
                    .LBrace) {
                advance();
                return new RollbackStmt(loc);
            }
            if ((current.text == "set" || current.text == "delete" || current.text == "adjust") && peekToken(0).type == TokenType
                    .Identifier)
                return parseUpdateStmt(loc);
            if (current.text == "fact" && peekToken(0).type == TokenType.Identifier) {
                return parseFactStmt(loc);
            }
            // `var gold = 0`: a story variable, sugar for `narrative.var(:gold, 0)`. Two names in
            // a row are not Lua, so the contextual word cannot change an existing program.
            if (current.text == "var" && peekToken(0).type == TokenType.Identifier && peekToken(1)
                    .type == TokenType.Equal) {
                advance();
                auto name = current.text;
                advance();
                advance();
                auto value = parseExpr();
                auto callee = new FieldExpr(new VariableExpr("narrative", loc), "var", loc);
                return new CallStmt(new CallExpr(callee, [new SymbolLiteralExpr(name, loc), value], loc), loc);
            }
            if (current.text == "retract" && peekToken(0).type == TokenType.Identifier) {
                return parseRetractStmt(loc);
            }
            if (current.text == "symbols" && peekToken(0).type == TokenType.Identifier) {
                advance();
                auto declaration = new SymbolsDeclStmt(loc);
                do {
                    auto name = consume(TokenType.Identifier, "symbol name expected");
                    declaration.names ~= name.text;
                    declaration.nameLocs ~= name.loc;
                    declaration.nameEnds ~= SourceLoc(name.endLine, name.endColumn);
                }
                while (match(TokenType.Comma));
                return declaration;
            }
            if (current.text == "relation" && peekToken(0).type == TokenType.Identifier && peekToken(1)
                    .type == TokenType.LParen) {
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
        scope (exit)
            activeLocals[$ - 1] = savedLocals;
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
            auto localToken = consume(TokenType.Identifier, "<name> expected");
            auto name = localToken.text;
            declareLocals();
            auto def = parseFunctionDef(loc);
            auto localDecl = new FunctionDeclStmt(new VariableExpr(name, loc), def, true, name, loc);
            localDecl.nameLoc = localToken.loc;
            localDecl.nameEnd = SourceLoc(localToken.endLine, localToken.endColumn);
            return localDecl;
        }

        // Global / Member function: Name {'.' Name} [':' Name]
        auto nameToken = consume(TokenType.Identifier, "<name> expected");
        Expr target = new VariableExpr(nameToken.text, nameToken.loc);
        bool isMethod = false;
        auto lastName = nameToken;

        while (match(TokenType.Dot)) {
            auto field = consume(TokenType.Identifier, "<name> expected").text;
            target = new FieldExpr(target, field, previous.loc);
            lastName = previous;
        }

        if (match(TokenType.Colon)) {
            auto method = consume(TokenType.Identifier, "<name> expected").text;
            target = new FieldExpr(target, method, previous.loc);
            isMethod = true;
            lastName = previous;
        }

        auto def = parseFunctionDef(loc, isMethod);
        auto declaration = new FunctionDeclStmt(target, def, false, "", loc);
        declaration.nameLoc = lastName.loc;
        declaration.nameEnd = SourceLoc(lastName.endLine, lastName.endColumn);
        return declaration;
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
        foreach (attr; attributes)
            if (attr == "close") {
                if (hasClose)
                    syntaxErrorNoNear("multiple to-be-closed variables in local list", previous.loc.line);
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
            if (attr != "const" && attr != "close")
                syntaxErrorNoNear("unknown attribute '" ~ attr ~ "'", previous.loc.line);
            attribute = attr;
        }
        return name;
    }

    private Stmt parseExprOrAssignStmt() {
        auto loc = current.loc;
        auto expr = parsePrefixExpr();

        // Check if this is a function call statement
        if (as!CallExpr(expr) !is null || as!MethodCallExpr(expr) !is null) {
            if (!check(TokenType.Comma) && !check(TokenType.Equal)) {
                return new CallStmt(expr, loc);
            }
        }

        // Otherwise, it must be an assignment: varlist '=' explist
        bool isVariable(Expr e) {
            return !e.parenthesized && (as!VariableExpr(e) !is null || as!IndexExpr(e) !is null || as!FieldExpr(e) !is null);
        }

        if (!check(TokenType.Comma) && !check(TokenType.Equal))
            syntaxError("syntax error", current);
        if (!isVariable(expr))
            syntaxError("syntax error", current);
        Expr[] targets = [expr];
        while (match(TokenType.Comma)) {
            if (targets.length + nestingLevel > 195)
                syntaxError("too many C levels (limit is 200)", current);
            auto target = parsePrefixExpr();
            if (!isVariable(target))
                syntaxError("syntax error", current);
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
        scope (exit)
            expressionDepth--;
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
            info = OpInfo(BinaryOp.Or, 1, 1);
            return true;
        case TokenType.KwAnd:
            info = OpInfo(BinaryOp.And, 2, 2);
            return true;
        case TokenType.Less:
            info = OpInfo(BinaryOp.Lt, 3, 3);
            return true;
        case TokenType.Greater:
            info = OpInfo(BinaryOp.Gt, 3, 3);
            return true;
        case TokenType.LessEqual:
            info = OpInfo(BinaryOp.Le, 3, 3);
            return true;
        case TokenType.GreaterEqual:
            info = OpInfo(BinaryOp.Ge, 3, 3);
            return true;
        case TokenType.TildeEqual:
            info = OpInfo(BinaryOp.Ne, 3, 3);
            return true;
        case TokenType.DoubleEqual:
            info = OpInfo(BinaryOp.Eq, 3, 3);
            return true;
        case TokenType.Pipe:
            info = OpInfo(BinaryOp.BOr, 4, 4);
            return true;
        case TokenType.Tilde:
            info = OpInfo(BinaryOp.BXor, 5, 5);
            return true;
        case TokenType.Ampersand:
            info = OpInfo(BinaryOp.BAnd, 6, 6);
            return true;
        case TokenType.DoubleLess:
            info = OpInfo(BinaryOp.Shl, 7, 7);
            return true;
        case TokenType.DoubleGreater:
            info = OpInfo(BinaryOp.Shr, 7, 7);
            return true;
        case TokenType.DoubleDot: // Right-associative
            info = OpInfo(BinaryOp.Concat, 9, 8);
            return true;
        case TokenType.Plus:
            info = OpInfo(BinaryOp.Add, 10, 10);
            return true;
        case TokenType.Minus:
            info = OpInfo(BinaryOp.Sub, 10, 10);
            return true;
        case TokenType.Star:
            info = OpInfo(BinaryOp.Mul, 11, 11);
            return true;
        case TokenType.Slash:
            info = OpInfo(BinaryOp.Div, 11, 11);
            return true;
        case TokenType.DoubleSlash:
            info = OpInfo(BinaryOp.IDiv, 11, 11);
            return true;
        case TokenType.Percent:
            info = OpInfo(BinaryOp.Mod, 11, 11);
            return true;
        case TokenType.Caret: // Right-associative
            info = OpInfo(BinaryOp.Pow, 14, 13);
            return true;
        default:
            return false;
        }
    }

    private Expr parseBinaryExpr(int minPrec) {
        enterLevel();
        scope (exit)
            --nestingLevel;
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
        if (match(TokenType.Minus))
            op = UnaryOp.Neg;
        else if (match(TokenType.KwNot))
            op = UnaryOp.Not;
        else if (match(TokenType.Hash))
            op = UnaryOp.Len;
        else if (match(TokenType.Tilde))
            op = UnaryOp.BitNot;
        else
            unary = false;
        if (unary) {
            auto operand = parseBinaryExpr(12);
            auto folded = foldUnary(op, operand, loc);
            auto expression = folded !is null ? folded : new UnaryExpr(op, operand, loc);
            expression.lastTokenLine = previous.loc.line;
            return expression;
        }

        auto primary = parsePrimaryExpr();
        if (primary.lastTokenLine == 0)
            primary.lastTokenLine = previous.loc.line;
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
            auto literal = new LiteralStringExpr(previous.text, loc);
            literal.end = SourceLoc(previous.endLine, previous.endColumn);
            return literal;
        }
        if (match(TokenType.TripleDot)) {
            if (!varargContext[$ - 1])
                syntaxError("cannot use '...' outside a vararg function", previous);
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
            auto symbol = new SymbolLiteralExpr(name, loc);
            symbol.end = SourceLoc(previous.endLine, previous.endColumn);
            return symbol;
        }

        if (check(TokenType.Identifier) && current.text == "query") {
            if (peekToken(0).type == TokenType.Identifier || peekToken(0).type == TokenType.LBrace) {
                advance(); // consume "query"
                return parseQueryExpr(loc);
            }
        }

        // `exists { goals }`: whether the query has a match; binds nothing outside it.
        if (check(TokenType.Identifier) && current.text == "exists" && peekToken(0).type == TokenType.LBrace) {
            advance();
            auto query = parseQueryExpr(loc);
            auto first = new CallExpr(query, [], loc);
            return new BinaryExpr(BinaryOp.Ne, first, new LiteralNilExpr(loc), loc);
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
        if (!aggregateExpressionMode || expressionDepth > aggregateExpressionDepth)
            return true;
        if (peekToken(0).type != TokenType.Identifier)
            return false;
        size_t end = 1;
        auto opening = peekToken(end).type;
        if (opening == TokenType.LParen || opening == TokenType.LBrace) {
            auto closing = opening == TokenType.LParen ? TokenType.RParen : TokenType.RBrace;
            int depth = 1;
            while (depth) {
                auto token = peekToken(++end).type;
                if (token == TokenType.EOF)
                    return false;
                if (token == opening)
                    depth++;
                if (token == closing)
                    depth--;
            }
        } else if (opening != TokenType.String)
            return false;
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
            expr.end = SourceLoc(previous.endLine, previous.endColumn);
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
            } else if (isMethodSuffix() && check(TokenType.Colon) && (!inDeclarative || (peekToken(0)
                    .type == TokenType.Identifier &&
                    (peekToken(1).type == TokenType.LParen || peekToken(1).type == TokenType.LBrace || peekToken(1)
                    .type == TokenType.String)))) {
                advance();
                auto method = consume(TokenType.Identifier, "<name> expected").text;
                int nameLine = previous.loc.line;
                int argsLine = current.loc.line;
                Expr[] args = parseArgs();
                auto methodCall = new MethodCallExpr(expr, method, args, suffixLoc);
                methodCall.nameLine = nameLine;
                methodCall.argsLine = argsLine;
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
            auto literal = new LiteralStringExpr(previous.text, loc);
            literal.end = SourceLoc(previous.endLine, previous.endColumn);
            return [literal];
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
        scope (exit) {
            varargContext.length--;
            activeLocals.length--;
            functionStartLines.length--;
        }

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
        auto reference = parts.length == 1 ? new AstRelRef([], parts[0], loc) : new AstRelRef(parts[0 .. $ - 1],
                parts[$ - 1], loc);
        reference.end = SourceLoc(previous.endLine, previous.endColumn);
        return reference;
    }

    private Stmt parseFactStmt(SourceLoc loc) {
        advance(); // consume "fact"
        auto relRef = parseRelRef();
        consume(TokenType.LParen, "'(' expected after relation name in fact");
        Expr[] args;
        if (!check(TokenType.RParen)) {
            while (true) {
                args ~= parseExpr();
                if (!match(TokenType.Comma))
                    break;
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
                if (!match(TokenType.Comma))
                    break;
                if (check(TokenType.RParen)) {
                    syntaxError("trailing comma not permitted in retract arguments", previous);
                }
            }
        }
        consume(TokenType.RParen, "')' expected to close retract arguments");
        return new RetractStmt(relRef, args, loc);
    }

    private AstGoal[] parseWhenClause(string keyword = "when") {
        auto when = consume(TokenType.Identifier, "'" ~ keyword ~ "' expected");
        if (when.text != keyword)
            syntaxError("'" ~ keyword ~ "' expected", when);
        consume(TokenType.LBrace, "'{' expected after " ~ keyword);
        AstGoal[] goals;
        do {
            goals ~= parseGoal();
            if (!match(TokenType.Comma))
                break;
        }
        while (true);
        consume(TokenType.RBrace, "'}' expected after availability goals");
        return goals;
    }

    private NarrativeDefinitionStmt parseNarrativeDefinition(string kind, SourceLoc loc) {
        advance();
        auto nameToken = consume(TokenType.Identifier, "content identifier expected");
        string name = nameToken.text;
        auto definition = new NarrativeDefinitionStmt(kind, name, loc);
        definition.nameLoc = nameToken.loc;
        definition.nameEnd = SourceLoc(nameToken.endLine, nameToken.endColumn);
        if (kind != "choice" || check(TokenType.LParen)) {
            consume(TokenType.LParen, "'(' expected after content identifier");
            if (!check(TokenType.RParen))
                do {
                consume(TokenType.Question, "logic parameter expected");
                string parameter = consume(TokenType.Identifier, "parameter name expected").text;
                if (parameter == "_")
                    syntaxError("anonymous content parameter is prohibited", previous);
                definition.parameters ~= parameter;
                if (!match(TokenType.Comma))
                    break;
            }
            while (true);
            consume(TokenType.RParen, "')' expected after parameters");
        }
        if (kind == "procedure") {
            if (check(TokenType.Identifier) && current.text == "when")
                syntaxError("a procedure has no availability: it runs when a scene beat names it", current);
        } else if (kind != "choice" || (check(TokenType.Identifier) && current.text == "when"))
            definition.goals = parseWhenClause();
        bool[string] fields;
        while (check(TokenType.Identifier)) {
            string field = current.text;
            if (field == "choice" || field == "effect")
                break;
            if (field == "expose" && kind != "procedure") {
                advance();
                do {
                    consume(TokenType.Question, "logic variable expected after 'expose'");
                    auto exposedName = consume(TokenType.Identifier, "variable name expected after 'expose ?'").text;
                    if (exposedName == "_")
                        syntaxError("anonymous variable cannot be exposed", previous);
                    definition.exposed ~= exposedName;
                }
                while (match(TokenType.Comma));
                continue;
            }
            if (kind == "choice" && field == "require") {
                if (definition.requireGoals.length)
                    syntaxError("duplicate content field 'require'", current);
                definition.requireGoals = parseWhenClause("require");
                continue;
            }
            bool allowed = kind != "action" && (field == "title" || field == "text");
            if (kind == "choice" && (field == "because" || field == "leads"))
                allowed = true;
            if (kind == "storylet")
                allowed = allowed || field == "deck" || field == "priority" || field == "weight" || field == "cooldown" || field == "repeatable" || field == "sticky" || field == "order";
            if (kind == "procedure")
                allowed = false;
            if (kind == "action")
                allowed = field == "phase" || field == "priority" || field == "once_per";
            if (!allowed)
                syntaxError("invalid " ~ kind ~ " field '" ~ field ~ "'", current);
            if (field in fields)
                syntaxError("duplicate content field '" ~ field ~ "'", current);
            fields[field] = true;
            advance();
            definition.fieldNames ~= field;
            if (field == "title" || field == "text" || field == "because") {
                auto value = consume(TokenType.String, "template string literal expected");
                auto literal = new LiteralStringExpr(value.text, value.loc);
                literal.end = SourceLoc(value.endLine, value.endColumn);
                definition.fieldValues ~= literal;
            } else
                definition.fieldValues ~= parseExpr();
        }
        if (kind == "storylet") {
            while (check(TokenType.Identifier) && current.text == "choice") {
                definition.choices ~= parseNarrativeDefinition("choice", current.loc);
                definition.choices[$ - 1].end = SourceLoc(previous.endLine, previous.endColumn);
            }
            if (!definition.choices.length)
                syntaxError("storylet requires at least one choice", current);
        } else {
            auto effect = consume(TokenType.Identifier, "'effect' expected");
            if (effect.text != "effect")
                syntaxError("'effect' expected", effect);
            consume(TokenType.KwDo, "'do' expected after effect");
            definition.effect = parseBlock();
            consume(TokenType.KwEnd, "'end' expected after effect");
        }
        consume(TokenType.KwEnd, "'end' expected after " ~ kind);
        return definition;
    }

    // --- readable scenes (milestone 29) ------------------------------------------------------
    // `scene name() ... end` lowers to `narrative.scene(:name, {beats})`, plus generated scenes
    // for menu options, conditional branches and their continuations, and generated procedures
    // for `effect using … do … end`. Nothing here is new to the engine except the `branch` beat.

    private Stmt[] pendingStmts;

    private TableField sceneField(string key, Expr value, SourceLoc loc) {
        return TableField(new LiteralStringExpr(key, loc), value);
    }

    private Expr sceneSymbol(string name, SourceLoc loc) {
        return new SymbolLiteralExpr(name, loc);
    }

    private Expr sceneBeat(string kind, TableField[] rest, SourceLoc loc) {
        // `return` is a Lua keyword, so the beat of that name is spelled as a string
        Expr kindValue = kind == "return" ? cast(Expr) new LiteralStringExpr(kind, loc) : sceneSymbol(kind, loc);
        return new TableConstructorExpr([sceneField("kind", kindValue, loc)] ~ rest, loc);
    }

    private bool sceneWord(string word) const {
        return check(TokenType.Identifier) && current.text == word;
    }

    private Token sceneName(string what) {
        return consume(TokenType.Identifier, what ~ " expected");
    }

    private Stmt parseReadableScene(SourceLoc loc) {
        advance();
        auto nameToken = consume(TokenType.Identifier, "scene name expected");
        consume(TokenType.LParen, "'(' expected after scene name");
        if (!check(TokenType.RParen))
            syntaxError("a scene takes no parameters: give locals a value with 'set' or 'input'", current);
        consume(TokenType.RParen, "')' expected after scene name");
        auto build = new SceneBuilder(nameToken.text);
        auto cur = build.open(nameToken.text);
        parseSceneBody(build, cur);
        if (!check(TokenType.KwEnd))
            syntaxError("'end' expected to close scene '" ~ nameToken.text ~ "'", current);
        advance();
        Stmt first;
        foreach (i, segment; build.segments) {
            TableField[] items;
            foreach (beat; segment.beats)
                items ~= TableField(null, beat);
            auto body = new TableConstructorExpr(items, loc);
            auto callee = new FieldExpr(new VariableExpr("narrative", loc), "scene", loc);
            auto call = new CallExpr(callee, [sceneSymbol(segment.name, nameToken.loc), body], loc);
            call.end = SourceLoc(previous.endLine, previous.endColumn);
            Stmt stmt = new CallStmt(call, loc);
            if (i == 0)
                first = stmt;
            else
                pendingStmts ~= stmt;
        }
        foreach (procedure; build.procedures)
            pendingStmts ~= procedure;
        return first;
    }

    private void parseSceneBody(SceneBuilder build, ref SceneSegment cur) {
        while (!isAtEnd() && !abandoned) {
            if (check(TokenType.KwEnd) || check(TokenType.KwElse) || check(TokenType.KwElseIf) || sceneWord("option"))
                return;
            parseSceneStatement(build, cur);
        }
    }

    /// `id name "text"`: the explicit, scene-scoped text id and the wording.
    private void parseSceneText(SceneBuilder build, ref TableField[] fields, SourceLoc loc) {
        if (!sceneWord("id"))
            syntaxError("a line needs an id: write 'id <name> \"text\"'", current);
        advance();
        auto name = sceneName("line id").text;
        auto full = build.root ~ "." ~ name;
        if (full in build.ids)
            syntaxError("duplicate line id '" ~ name ~ "' in scene '" ~ build.root ~ "'", previous);
        build.ids[full] = true;
        auto text = consume(TokenType.String, "text expected after the line id");
        auto literal = new LiteralStringExpr(text.text, text.loc);
        literal.end = SourceLoc(text.endLine, text.endColumn);
        fields ~= sceneField("id", new LiteralStringExpr(full, loc), loc);
        fields ~= sceneField("text", literal, loc);
    }

    /// `with a = v, b = w`: returns the pairs as a table, or null when there is no clause.
    private TableField[] parseSceneWith(SourceLoc loc, string[] allowed = null) {
        TableField[] pairs;
        if (!sceneWord("with"))
            return pairs;
        advance();
        do {
            auto key = sceneName("name");
            if (allowed.length) {
                bool known;
                foreach (a; allowed)
                    known = known || a == key.text;
                if (!known)
                    syntaxError("'" ~ key.text ~ "' is not accepted here", key);
            }
            consume(TokenType.Equal, "'=' expected");
            pairs ~= sceneField(key.text, parseExpr(), key.loc);
        }
        while (match(TokenType.Comma));
        return pairs;
    }

    private void parseSceneStatement(SceneBuilder build, ref SceneSegment cur) {
        auto loc = current.loc;
        if (check(TokenType.KwReturn)) {
            advance();
            cur.beats ~= sceneBeat("return", null, loc);
            return;
        }
        if (check(TokenType.KwIf)) {
            advance();
            auto cont = build.fresh("then");
            auto join = build.open(cont);
            parseSceneIfTail(build, cur, cont);
            if (!check(TokenType.KwEnd))
                syntaxError("'end' expected to close 'if'", current);
            advance();
            cur.beats ~= sceneBeat("jump", [sceneField("target", sceneSymbol(cont, loc), loc)], loc);
            cur = join;
            return;
        }
        if (!check(TokenType.Identifier))
            syntaxError("scene statement expected", current);
        auto word = current.text;
        advance();
        TableField[] fields;
        switch (word) {
        case "say":
            auto character = sceneName("character");
            fields ~= sceneField("character", sceneSymbol(character.text, character.loc), loc);
            auto attributes = parseSceneWith(loc);
            if (attributes.length)
                fields ~= sceneField("attributes", new TableConstructorExpr(attributes, loc), loc);
            parseSceneText(build, fields, loc);
            cur.beats ~= sceneBeat("say", fields, loc);
            return;
        case "narrate":
            parseSceneText(build, fields, loc);
            cur.beats ~= sceneBeat("narration", fields, loc);
            return;
        case "show":
            auto character = sceneName("character");
            fields ~= sceneField("character", sceneSymbol(character.text, character.loc), loc);
            if (!sceneWord("at"))
                syntaxError("'at' expected: show <character> at :slot", current);
            advance();
            fields ~= sceneField("slot", parseExpr(), loc);
            auto attributes = parseSceneWith(loc);
            if (attributes.length)
                fields ~= sceneField("attributes", new TableConstructorExpr(attributes, loc), loc);
            cur.beats ~= sceneBeat("show", fields, loc);
            return;
        case "hide":
            auto character = sceneName("character");
            cur.beats ~= sceneBeat("hide", [
                sceneField("character", sceneSymbol(character.text, character.loc), loc)
            ], loc);
            return;
        case "background":
            cur.beats ~= sceneBeat("background", [sceneField("tag", parseExpr(), loc)], loc);
            return;
        case "audio":
            auto channel = sceneName("audio channel");
            fields ~= sceneField("channel", sceneSymbol(channel.text, channel.loc), loc);
            if (sceneWord("off"))
                advance();
            else
                fields ~= sceneField("tag", parseExpr(), loc);
            cur.beats ~= sceneBeat("audio", fields, loc);
            return;
        case "pause":
        case "transition":
        case "screen":
        case "picture":
            consume(TokenType.LBrace, "'{' expected: " ~ word ~ " { … }");
            auto table = parseTableConstructor(loc);
            cur.beats ~= sceneBeat(word, table.fields, loc);
            return;
        case "input":
            auto local = sceneName("local name");
            fields ~= sceneField("local", new LiteralStringExpr(local.text, local.loc), loc);
            parseSceneText(build, fields, loc);
            fields ~= parseSceneWith(loc, ["default", "min_length", "max_length", "min", "max"]);
            cur.beats ~= sceneBeat("input", fields, loc);
            return;
        case "set":
            auto local = sceneName("local name");
            consume(TokenType.Equal, "'=' expected");
            cur.beats ~= sceneBeat("set", [
                sceneField("local", new LiteralStringExpr(local.text, local.loc), loc),
                sceneField("value", parseExpr(), loc)
            ], loc);
            return;
        case "jump":
        case "call":
            auto target = sceneName("scene name");
            cur.beats ~= sceneBeat(word, [
                sceneField("target", sceneSymbol(target.text, target.loc), loc)
            ], loc);
            return;
        case "ended":
            cur.beats ~= sceneBeat("ended", null, loc);
            return;
        case "effect":
            parseSceneEffect(build, cur, loc);
            return;
        case "menu":
            parseSceneMenu(build, cur, loc);
            return;
        default:
            syntaxError("unknown scene statement '" ~ word ~ "'", previous);
        }
    }

    private void parseSceneIfTail(SceneBuilder build, ref SceneSegment cur, string cont) {
        auto loc = previous.loc;
        auto local = sceneName("local name");
        TokenType op = current.type;
        string text;
        switch (op) {
        case TokenType.DoubleEqual:
            text = "==";
            break;
        case TokenType.TildeEqual:
            text = "~=";
            break;
        case TokenType.Less:
            text = "<";
            break;
        case TokenType.LessEqual:
            text = "<=";
            break;
        case TokenType.Greater:
            text = ">";
            break;
        case TokenType.GreaterEqual:
            text = ">=";
            break;
        default:
            syntaxError("a scene condition compares a local with a value: if <local> == <value> then", current);
        }
        advance();
        auto value = parseExpr();
        consume(TokenType.KwThen, "'then' expected");
        auto thenSegment = build.open(build.fresh("if"));
        cur.beats ~= sceneBeat("branch", [
            sceneField("local", new LiteralStringExpr(local.text, local.loc), loc),
            sceneField("op", new LiteralStringExpr(text, loc), loc),
            sceneField("value", value, loc),
            sceneField("target", sceneSymbol(thenSegment.name, loc), loc)
        ], loc);
        parseSceneBody(build, thenSegment);
        thenSegment.beats ~= sceneBeat("jump", [sceneField("target", sceneSymbol(cont, loc), loc)], loc);
        if (match(TokenType.KwElseIf)) {
            parseSceneIfTail(build, cur, cont);
        } else if (match(TokenType.KwElse)) {
            parseSceneBody(build, cur);
        }
    }

    private void parseSceneMenu(SceneBuilder build, ref SceneSegment cur, SourceLoc loc) {
        auto contName = build.fresh("menu");
        auto join = build.open(contName);
        Expr[] choices;
        while (sceneWord("option")) {
            auto optionLoc = current.loc;
            advance();
            auto id = sceneName("option id");
            auto labelId = build.root ~ "." ~ id.text;
            if (labelId in build.labelIds)
                syntaxError("duplicate option id '" ~ id.text ~ "' in scene '" ~ build.root ~ "'", id);
            build.labelIds[labelId] = true;
            auto label = consume(TokenType.String, "option text expected");
            consume(TokenType.KwDo, "'do' expected after the option text");
            auto segment = build.open(build.fresh("option"));
            auto target = segment.name;
            parseSceneBody(build, segment);
            consume(TokenType.KwEnd, "'end' expected to close the option");
            segment.beats ~= sceneBeat("jump", [
                sceneField("target", sceneSymbol(contName, optionLoc), optionLoc)
            ], optionLoc);
            auto text = new LiteralStringExpr(label.text, label.loc);
            text.end = SourceLoc(label.endLine, label.endColumn);
            choices ~= new TableConstructorExpr([
                sceneField("id", new LiteralStringExpr(id.text, id.loc), optionLoc),
                sceneField("text", text, optionLoc),
                sceneField("label_id", new LiteralStringExpr(labelId, optionLoc), optionLoc),
                sceneField("target", sceneSymbol(target, optionLoc), optionLoc)
            ], optionLoc);
        }
        if (!choices.length)
            syntaxError("a menu needs at least one 'option <id> \"text\" do … end'", current);
        consume(TokenType.KwEnd, "'end' expected to close 'menu'");
        TableField[] items;
        foreach (choice; choices)
            items ~= TableField(null, choice);
        cur.beats ~= sceneBeat("menu", [
            sceneField("choices", new TableConstructorExpr(items, loc), loc)
        ], loc);
        cur = join;
    }

    private void parseSceneEffect(SceneBuilder build, ref SceneSegment cur, SourceLoc loc) {
        TableField[] fields, args, locals;
        if (sceneWord("using")) {
            advance();
            string[] names;
            do {
                names ~= sceneName("local name").text;
            }
            while (match(TokenType.Comma));
            consume(TokenType.KwDo, "'do' expected after 'effect using …'");
            auto name = build.fresh("effect");
            auto procedure = new NarrativeDefinitionStmt("procedure", name, loc);
            procedure.nameLoc = loc;
            procedure.nameEnd = loc;
            procedure.parameters = names;
            procedure.effect = parseBlock();
            consume(TokenType.KwEnd, "'end' expected after effect");
            procedure.end = SourceLoc(previous.endLine, previous.endColumn);
            build.procedures ~= procedure;
            fields ~= sceneField("name", sceneSymbol(name, loc), loc);
            foreach (n; names)
                locals ~= sceneField(n, new LiteralStringExpr(n, loc), loc);
        } else {
            auto name = sceneName("procedure name");
            fields ~= sceneField("name", sceneSymbol(name.text, name.loc), loc);
            consume(TokenType.LParen, "'(' expected after the procedure name");
            if (!check(TokenType.RParen))
                do {
                auto key = sceneName("parameter name");
                consume(TokenType.Equal, "'=' expected: effect name(parameter = local or value)");
                auto next = peekToken(0).type;
                if (check(TokenType.Identifier) && (next == TokenType.Comma || next == TokenType.RParen)) {
                    locals ~= sceneField(key.text, new LiteralStringExpr(current.text, current.loc), key.loc);
                    advance();
                } else
                    args ~= sceneField(key.text, parseExpr(), key.loc);
            }
            while (match(TokenType.Comma));
            consume(TokenType.RParen, "')' expected after the arguments");
        }
        if (args.length)
            fields ~= sceneField("args", new TableConstructorExpr(args, loc), loc);
        if (locals.length)
            fields ~= sceneField("locals", new TableConstructorExpr(locals, loc), loc);
        cur.beats ~= sceneBeat("effect", fields, loc);
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
                if (!match(TokenType.Comma))
                    break;
                if (check(TokenType.RParen))
                    syntaxError("trailing comma in update", current);
            }
            while (true);
        }
        consume(TokenType.RParen, "')' expected after update arguments");
        Expr delta;
        if (operation == "adjust") {
            auto by = consume(TokenType.Identifier, "'by' expected after adjust key");
            if (by.text != "by")
                syntaxError("'by' expected after adjust key", by);
            delta = parseExpr();
        }
        auto update = new UpdateStmt(operation, reference, args, delta, loc);
        // `clamp` is contextual: a modifier only when it ends the statement on the same line.
        if (operation == "adjust" && check(TokenType.Identifier) && current.text == "clamp"
                && current.loc.line == previous.endLine) {
            auto after = peekToken(0).type;
            if (after != TokenType.LParen && after != TokenType.Equal && after != TokenType.Dot
                    && after != TokenType.Colon && after != TokenType.Comma && after != TokenType.LBracket
                    && after != TokenType.String && after != TokenType.LBrace) {
                advance();
                update.clamp = true;
            }
        }
        return update;
    }

    private Stmt parseRelationDeclStmt(SourceLoc loc) {
        advance();
        auto nameToken = consume(TokenType.Identifier, "relation name expected");
        auto name = nameToken.text;
        consume(TokenType.LParen, "'(' expected after relation name");
        if (check(TokenType.Integer)) {
            auto intTok = current;
            advance();
            consume(TokenType.RParen, "')' expected after relation arity");
            auto declaration = new RelationDeclStmt(name, cast(int) intTok.intValue, loc);
            declaration.nameLoc = nameToken.loc;
            declaration.nameEnd = SourceLoc(nameToken.endLine, nameToken.endColumn);
            return declaration;
        }
        string[] columns;
        if (!check(TokenType.RParen)) {
            do {
                columns ~= consume(TokenType.Identifier, "column name expected").text;
                if (!match(TokenType.Comma))
                    break;
            }
            while (true);
        }
        consume(TokenType.RParen, "')' expected after column names");
        string[] keys;
        if (check(TokenType.Identifier) && current.text == "key" && peekToken(0).type == TokenType.LParen) {
            advance();
            advance();
            do {
                keys ~= consume(TokenType.Identifier, "key column expected").text;
                if (!match(TokenType.Comma))
                    break;
            }
            while (true);
            consume(TokenType.RParen, "')' expected after keys");
        }
        auto declaration = new RelationDeclStmt(name, cast(int) columns.length, loc);
        declaration.columns = columns;
        declaration.keys = keys;
        declaration.named = true;
        declaration.nameLoc = nameToken.loc;
        declaration.nameEnd = SourceLoc(nameToken.endLine, nameToken.endColumn);
        return declaration;
    }

    private Stmt parseLocalRelationDeclStmt(SourceLoc loc) {
        advance(); // consume "relation"
        auto nameToken = consume(TokenType.Identifier, "relation name expected");
        auto name = nameToken.text;
        consume(TokenType.LParen, "'(' expected after relation name");
        auto intTok = consume(TokenType.Integer, "integer arity expected");
        consume(TokenType.RParen, "')' expected after relation arity");
        auto declaration = new LocalRelationDeclStmt(name, cast(int) intTok.intValue, loc);
        declaration.nameLoc = nameToken.loc;
        declaration.nameEnd = SourceLoc(nameToken.endLine, nameToken.endColumn);
        return declaration;
    }

    private bool isWorldBlockStmt(string keyword = "logic") {
        if (!check(TokenType.Identifier) || current.text != keyword)
            return false;
        if (peekToken(0).type != TokenType.LParen)
            return false;
        size_t k = 1;
        int parenDepth = 1;
        while (parenDepth > 0) {
            auto tok = peekToken(k++);
            if (tok.type == TokenType.EOF)
                return false;
            if (tok.type == TokenType.LParen)
                parenDepth++;
            else if (tok.type == TokenType.RParen)
                parenDepth--;
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
                if (!match(TokenType.Comma))
                    break;
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
        scope (exit)
            inDeclarative = saved;
        return parseExpr();
    }

    private bool isGoalStart() {
        if (check(TokenType.KwNot))
            return true;
        if (check(TokenType.Question))
            return true;
        if (check(TokenType.Identifier))
            return true;
        if (check(TokenType.Colon) || check(TokenType.Integer) || check(TokenType.Float) || check(TokenType.String) || check(
                TokenType.LParen))
            return true;
        return false;
    }

    /// At a `(`: whether its group has an `or` at its own nesting level.
    private bool parenthesizedOr() {
        int depth = 1;
        for (size_t i = 0;; ++i) {
            auto type = peekToken(i).type;
            if (type == TokenType.EOF)
                return false;
            if (type == TokenType.LParen || type == TokenType.LBrace || type == TokenType.LBracket)
                depth++;
            else if (type == TokenType.RParen || type == TokenType.RBrace || type == TokenType.RBracket) {
                depth--;
                if (depth == 0)
                    return false;
            } else if (type == TokenType.KwOr && depth == 1)
                return true;
        }
    }

    private bool aggregateExpressionMode;
    private size_t aggregateExpressionDepth;

    private AstGoal parseGoal() {
        auto goal = parseGoalInner();
        goal.end = SourceLoc(previous.endLine, previous.endColumn);
        return goal;
    }

    private AstGoal parseGoalInner() {
        auto loc = current.loc;
        // Computed binding: `?name := expression`. The expression is evaluated once per candidate
        // from variables grounded earlier; it is the aggregate form with no goals and the
        // operator "value" (so it is ordered with the aggregates, in written order).
        if (check(TokenType.Question) && peekToken(0).type == TokenType.Identifier && peekToken(1)
                .type == TokenType.Colon && peekToken(2).type == TokenType.Equal) {
            advance();
            string result = consume(TokenType.Identifier, "computed binding variable expected").text;
            if (result == "_")
                syntaxError("anonymous computed binding is prohibited", previous);
            advance(); // ':'
            advance(); // '='
            bool saved = inDeclarative;
            inDeclarative = true;
            bool previousMode = aggregateExpressionMode;
            aggregateExpressionMode = true;
            auto previousDepth = aggregateExpressionDepth;
            aggregateExpressionDepth = expressionDepth + 1;
            auto expression = parseExpr();
            aggregateExpressionDepth = previousDepth;
            aggregateExpressionMode = previousMode;
            inDeclarative = saved;
            return new AstAggregateGoal(result, "value", expression, null, loc);
        }
        // Alternatives: `(?a > 3 or ?b == :open)`. One filter that passes when any alternative
        // is true, tried left to right; a parenthesized group of comparisons is ordinary guard
        // syntax with `or`, so it is read as `where(...)`.
        if (check(TokenType.LParen) && parenthesizedOr()) {
            advance();
            bool saved = inDeclarative;
            inDeclarative = true;
            scope (exit)
                inDeclarative = saved;
            auto alternatives = parseExpr();
            consume(TokenType.RParen, "')' expected after alternatives");
            return new AstGuardGoal(alternatives, loc);
        }
        if (check(TokenType.Question) && peekToken(0).type == TokenType.Identifier && peekToken(1)
                .type == TokenType.Equal) {
            advance();
            string result = consume(TokenType.Identifier, "aggregate result variable expected").text;
            if (result == "_")
                syntaxError("anonymous aggregate result is prohibited", previous);
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
                if (!match(TokenType.Comma))
                    break;
            }
            while (true);
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
                    if (!match(TokenType.Comma))
                        break;
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
            scope (exit)
                inDeclarative = saved;
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
                    if (!match(TokenType.Comma))
                        break;
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
        if (match(TokenType.DoubleEqual))
            return CompareOp.Eq;
        if (match(TokenType.TildeEqual))
            return CompareOp.Neq;
        if (match(TokenType.Less))
            return CompareOp.Lt;
        if (match(TokenType.LessEqual))
            return CompareOp.Le;
        if (match(TokenType.Greater))
            return CompareOp.Gt;
        if (match(TokenType.GreaterEqual))
            return CompareOp.Ge;
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
            if (auto atomGoal = as!AstRelAtomGoal(g)) {
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
    double asFloat() const {
        return isInt ? cast(double) i : d;
    }
}

private bool numeralOf(Expr e, out Numeral n) {
    if (auto li = as!LiteralIntExpr(e)) {
        n.isInt = true;
        n.i = li.value;
        return true;
    }
    if (auto lf = as!LiteralFloatExpr(e)) {
        n.isInt = false;
        n.d = lf.value;
        return true;
    }
    return false;
}

private bool toExactInteger(Numeral n, out long result) {
    import varis.types : floatToInteger;

    if (n.isInt) {
        result = n.i;
        return true;
    }
    return floatToInteger(n.d, result);
}

private Expr numeralExpr(Numeral n, SourceLoc loc) {
    import std.math : isNaN;

    if (n.isInt)
        return new LiteralIntExpr(n.i, loc);
    if (isNaN(n.d) || n.d == 0)
        return null; // folds neither NaN nor 0.0 (-0.0 problems)
    return new LiteralFloatExpr(n.d, loc);
}

private long shiftLeft(long x, long y) {
    if (y <= -64 || y >= 64)
        return 0;
    if (y >= 0)
        return cast(long)(cast(ulong) x << y);
    return cast(long)(cast(ulong) x >> -y);
}

private Expr foldBinary(BinaryOp op, Expr left, Expr right, SourceLoc loc) {
    import core.stdc.math : pow, fmod;
    import std.math : floor;

    Numeral a, b;
    if (!numeralOf(left, a) || !numeralOf(right, b))
        return null;
    Numeral r;
    switch (op) {
    case BinaryOp.Add, BinaryOp.Sub, BinaryOp.Mul:
        if (a.isInt && b.isInt) {
            r.isInt = true;
            ulong x = cast(ulong) a.i, y = cast(ulong) b.i;
            r.i = cast(long)(op == BinaryOp.Add ? x + y : op == BinaryOp.Sub ? x - y : x * y);
        } else {
            double x = a.asFloat, y = b.asFloat;
            r.d = op == BinaryOp.Add ? x + y : op == BinaryOp.Sub ? x - y : x * y;
        }
        break;
    case BinaryOp.Div:
        if (b.asFloat == 0)
            return null;
        r.d = a.asFloat / b.asFloat;
        break;
    case BinaryOp.Pow:
        r.d = pow(a.asFloat, b.asFloat);
        break;
    case BinaryOp.IDiv:
        if (b.asFloat == 0)
            return null;
        if (a.isInt && b.isInt) {
            r.isInt = true;
            if (b.i == -1)
                r.i = cast(long)(0UL - cast(ulong) a.i);
            else {
                long q = a.i / b.i;
                if ((a.i % b.i != 0) && ((a.i ^ b.i) < 0))
                    q -= 1;
                r.i = q;
            }
        } else
            r.d = floor(a.asFloat / b.asFloat);
        break;
    case BinaryOp.Mod:
        if (b.asFloat == 0)
            return null;
        if (a.isInt && b.isInt) {
            r.isInt = true;
            if (b.i == -1)
                r.i = 0;
            else {
                long m = a.i % b.i;
                if (m != 0 && (m ^ b.i) < 0)
                    m += b.i;
                r.i = m;
            }
        } else {
            double x = a.asFloat, y = b.asFloat;
            double m = fmod(x, y);
            if ((m > 0) ? y < 0 : (m < 0 && y > 0))
                m += y;
            r.d = m;
        }
        break;
    case BinaryOp.BAnd, BinaryOp.BOr, BinaryOp.BXor, BinaryOp.Shl, BinaryOp.Shr: {
            long x, y;
            if (!toExactInteger(a, x) || !toExactInteger(b, y))
                return null;
            r.isInt = true;
            switch (op) {
            case BinaryOp.BAnd:
                r.i = x & y;
                break;
            case BinaryOp.BOr:
                r.i = x | y;
                break;
            case BinaryOp.BXor:
                r.i = x ^ y;
                break;
            case BinaryOp.Shl:
                r.i = shiftLeft(x, y);
                break;
            default:
                r.i = shiftLeft(x, cast(long)(0UL - cast(ulong) y));
                break;
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
        if (!numeralOf(operand, a))
            return null;
        if (a.isInt)
            return new LiteralIntExpr(cast(long)(0UL - cast(ulong) a.i), loc);
        a.d = -a.d;
        return numeralExpr(a, loc);
    case UnaryOp.BitNot: {
            long x;
            if (!numeralOf(operand, a) || !toExactInteger(a, x))
                return null;
            return new LiteralIntExpr(~x, loc);
        }
    case UnaryOp.Not:
        if (as!LiteralNilExpr(operand) !is null)
            return new LiteralBoolExpr(true, loc);
        if (auto lb = as!LiteralBoolExpr(operand))
            return new LiteralBoolExpr(!lb.value, loc);
        if (numeralOf(operand, a) || as!LiteralStringExpr(operand) !is null)
            return new LiteralBoolExpr(false, loc);
        return null;
    default:
        return null;
    }
}

/// One generated scene while a readable scene is being lowered.
private final class SceneSegment {
    string name;
    Expr[] beats;
}

/// Names and collects the scenes and procedures one readable scene lowers to.
private final class SceneBuilder {
    string root;
    SceneSegment[] segments;
    NarrativeDefinitionStmt[] procedures;
    bool[string] ids, labelIds;
    int counter;

    this(string root) {
        this.root = root;
    }

    string fresh(string what) {
        return root ~ "__" ~ what ~ (++counter).to!string;
    }

    SceneSegment open(string name) {
        auto segment = new SceneSegment;
        segment.name = name;
        segments ~= segment;
        return segment;
    }
}
