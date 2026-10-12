/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The project index (AUTHORING_TOOLS_PLAN §3.3): what a project declares, what it refers to and
/// what display text it holds, read from the AST of every file **without running anything**. It
/// is the one description the checker, go to definition, completion, rename and the localization
/// extractor read.
///
/// The index is stored per file and merged, so editing one file re-indexes one file. Tables:
/// declarations, references, messages. Things written as library calls and not as syntax
/// (`quality.define(:coins, {label = "Coins"})`, `narrative.name(:keeper, "the keeper")`) are
/// indexed when their arguments are literals; otherwise the declaration is marked `computed`.
module varis.services.index;

import varis.ast;
import varis.exception : LuaException;
import varis.lexer : Lexer, Token, TokenType;
import varis.parser : Parser;
import varis.services.diagnostic;
import varis.workbench.server : jsonQuote;

/// A source range: 1-based line and byte column, end just past the last byte. Line 0: unknown.
struct Range {
    int line;
    int column;
    int endLine;
    int endColumn;
}

private Range rangeOf(SourceLoc start, SourceLoc end) {
    return Range(start.line, start.column, end.line, end.column);
}

/// kinds: storylet, choice, action, deck, relation, local-relation, rule, quality, name,
/// function, local-function, label.
struct Declaration {
    string kind;
    string name;
    string owner; // a choice's storylet
    string file;
    Range range; // the name as written
    Range extent; // the whole definition, when the parser recorded it
    int arity = -1; // relations and rules
    string[] columns;
    string[] keys;
    string[] parameters; // storylets, choices and actions
    string deck; // a storylet's deck
    bool computed; // written as a call with arguments that are not literals
    string detail; // a short description for hover, built from what was written

    /// What the writer calls it: `storylet lamp`, `choice lamp.light`.
    string subject() const {
        return kind ~ " " ~ (owner.length ? owner ~ "." : "") ~ name;
    }
}

/// kinds: relation, symbol, deck, quality, placeholder. `role` of a relation reference: read,
/// negated, assert, retract, update (a rule head is a declaration, not a reference). A symbol that
/// is a value of an engine field (`phase`, `once_per`) has role `engine`: the engine defines it.
struct Reference {
    string kind;
    string name;
    string qualifier; // a world path in front of a relation name
    string role;
    int arity = -1;
    string file;
    Range range;
    string inside; // the declaration it sits in (`subject` form); empty at file level
}

/// One piece of display text. `key` is derived from authored names (localization plan §3.1).
struct Message {
    string key; // `lamp.title`, `lamp.light.title`, `quality.oil.label`, `name.keeper`
    string field; // title, text, label, name
    string owner; // subject of the declaration it belongs to
    string file;
    Range range; // the string literal, delimiters included
    string text; // the source text, escapes decoded
    string[] placeholders; // `{name}` in order of appearance
    string[] conditionRelations; // relations read by `{#if query ...}`
    int variantOptions; // `{#variant}` alternatives
    int conditions; // `{#if}` count
    string when; // the owning definition's `when` clause as source text
    bool computed; // the text is not a string literal, so it cannot be extracted
}

struct FileIndex {
    string path;
    ulong hash;
    bool parsed;
    Diagnostic[] problems;
    Declaration[] declarations;
    Reference[] references;
    Message[] messages;
    bool[string] identifiers; // every plain name the file mentions
}

struct ProjectIndex {
    FileIndex[] files;
}

private ulong fnv1a(string text) {
    ulong h = 14695981039346656037UL;
    foreach (char c; text) {
        h ^= cast(ubyte) c;
        h *= 1099511628211UL;
    }
    return h;
}

// -----------------------------------------------------------------------------
// Template scan: positions inside a string literal
// -----------------------------------------------------------------------------

/// Where each byte of a literal's raw source lies in the file.
private struct RawMap {
    string raw;
    int startLine;
    int startColumn;

    /// Position of `index` bytes into the raw text.
    SourceLoc at(size_t index) const {
        int line = startLine;
        int column = startColumn;
        foreach (i; 0 .. index) {
            if (raw[i] == '\n') {
                ++line;
                column = 1;
            } else
                ++column;
        }
        return SourceLoc(line, column);
    }
}

private bool isNameChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

private string stripText(string s) {
    size_t a, b = s.length;
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n' || s[a] == '\r'))
        ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\n' || s[b - 1] == '\r'))
        --b;
    return s[a .. b];
}

private struct TemplateScan {
    string[] placeholders;
    Reference[] references; // placeholders and relations read by conditions
    string[] conditionRelations;
    int variantOptions;
    int conditions;
}

/// Scans the interior of a literal for template tags. `raw` is the literal as written, with its
/// delimiters; positions come from `map`. Escapes are not decoded: tags contain none.
private TemplateScan scanTemplate(string raw, int line, int column, string file, string inside) {
    TemplateScan result;
    auto map = RawMap(raw, line, column);
    size_t i, n = raw.length;
    // Skip the opening delimiter.
    if (n >= 2 && (raw[0] == '"' || raw[0] == '\'')) {
        i = 1;
        --n;
    } else if (n >= 4 && raw[0] == '[') {
        size_t eq = 1;
        while (eq < n && raw[eq] == '=')
            ++eq;
        if (eq < n && raw[eq] == '[') {
            i = eq + 1;
            n -= eq + 1; // the closing `]=*]` has the same length
            if (i < raw.length && raw[i] == '\n')
                ++i;
            else if (i + 1 < raw.length && raw[i] == '\r' && raw[i + 1] == '\n')
                i += 2;
        }
    }
    while (i < n) {
        if (raw[i] == '{' && i + 1 < n && raw[i + 1] == '{') {
            i += 2;
            continue;
        }
        if (raw[i] == '}' && i + 1 < n && raw[i + 1] == '}') {
            i += 2;
            continue;
        }
        if (raw[i] != '{') {
            ++i;
            continue;
        }
        size_t open = i + 1;
        size_t j = open;
        int braces;
        while (j < n) {
            char c = raw[j];
            if (c == '"' || c == '\'') {
                char quote = c;
                ++j;
                while (j < n && raw[j] != quote) {
                    if (raw[j] == '\\' && j + 1 < n)
                        ++j;
                    ++j;
                }
                if (j >= n)
                    break;
                ++j;
                continue;
            }
            if (c == '{')
                ++braces;
            else if (c == '}' && braces == 0)
                break;
            else if (c == '}')
                --braces;
            ++j;
        }
        if (j >= n)
            break; // unterminated: the runtime reports it
        auto tag = raw[open .. j];
        i = j + 1;
        auto text = stripText(tag);
        if (text.length == 0)
            continue;
        // Offset of the stripped text inside the raw literal.
        size_t offset = open;
        while (offset < j && (raw[offset] == ' ' || raw[offset] == '\t' || raw[offset] == '\n' || raw[offset] == '\r'))
            ++offset;
        if (text[0] == '#') {
            if (text.length > 4 && text[0 .. 4] == "#if ") {
                ++result.conditions;
                auto condition = text[4 .. $];
                size_t condOffset = offset + 4;
                // Relations the condition reads: a name followed by `(`.
                try {
                    auto lexer = new Lexer(condition, "=template");
                    Token previousToken;
                    bool havePrevious;
                    while (true) {
                        auto token = lexer.nextToken();
                        if (token.type == TokenType.EOF)
                            break;
                        if (havePrevious && previousToken.type == TokenType.Identifier && token.type == TokenType
                                .LParen
                                && previousToken.text != "query") {
                            auto at = map.at(condOffset + cast(size_t)(previousToken.raw.ptr - condition.ptr));
                            Reference reference;
                            reference.kind = "relation";
                            reference.role = "read";
                            reference.name = previousToken.text;
                            reference.file = file;
                            reference.inside = inside;
                            reference.range = Range(at.line, at.column, at.line, cast(int)(
                                    at.column + previousToken.raw.length));
                            // Arity: top-level commas of the argument list.
                            int depth = 1, terms;
                            bool any;
                            auto probe = new Lexer(condition[cast(size_t)(token.raw.ptr - condition.ptr) + 1 .. $], "=template");
                            while (depth > 0) {
                                auto inner = probe.nextToken();
                                if (inner.type == TokenType.EOF)
                                    break;
                                if (inner.type == TokenType.LParen || inner.type == TokenType.LBrace
                                        || inner.type == TokenType.LBracket)
                                    ++depth;
                                else if (inner.type == TokenType.RParen || inner.type == TokenType.RBrace
                                        || inner.type == TokenType.RBracket) {
                                    --depth;
                                    if (depth == 0)
                                        break;
                                } else if (inner.type == TokenType.Comma && depth == 1)
                                    ++terms;
                                any = any || depth >= 1;
                            }
                            reference.arity = any ? terms + 1 : 0;
                            result.references ~= reference;
                            bool seen;
                            foreach (name; result.conditionRelations)
                                if (name == reference.name)
                                    seen = true;
                            if (!seen)
                                result.conditionRelations ~= reference.name;
                        }
                        previousToken = token;
                        havePrevious = true;
                    }
                } catch (Exception) {
                    // The runtime reports a malformed condition when the content registers.
                }
            } else if (text == "#variants") {
                // The group's options are counted at their `#variant` tags.
            } else if (text.length >= 8 && text[0 .. 8] == "#variant")
                ++result.variantOptions;
            continue;
        }
        if (text[0] == '/')
            continue;
        bool plain = true;
        foreach (char c; text)
            if (!isNameChar(c))
                plain = false;
        if (!plain)
            continue;
        result.placeholders ~= text;
        auto at = map.at(offset);
        Reference reference;
        reference.kind = "placeholder";
        reference.name = text;
        reference.file = file;
        reference.inside = inside;
        reference.range = Range(at.line, at.column, at.line, cast(int)(at.column + text.length));
        result.references ~= reference;
    }
    return result;
}

/// The placeholders (`{name}`) of a template text, in order. For translations, which are not
/// string literals in a source file.
string[] templatePlaceholders(string text) {
    return scanTemplate("\"" ~ text ~ "\"", 1, 1, "", "").placeholders;
}

// -----------------------------------------------------------------------------
// The walker
// -----------------------------------------------------------------------------

private final class Builder {
    FileIndex* file;
    string content;
    size_t[] lineStarts;
    string inside; // subject of the declaration being walked
    string whenText; // `when` of the definition being walked
    string[string] unused;

    this(FileIndex* file, string content) {
        this.file = file;
        this.content = content;
        lineStarts = [0];
        foreach (i, char c; content)
            if (c == '\n')
                lineStarts ~= i + 1;
    }

    /// The source text between two positions, or null when out of range.
    string slice(SourceLoc start, SourceLoc end) {
        if (start.line < 1 || end.line < start.line || end.line > lineStarts.length)
            return null;
        size_t a = lineStarts[start.line - 1] + start.column - 1;
        size_t b = lineStarts[end.line - 1] + end.column - 1;
        if (a > b || b > content.length)
            return null;
        return content[a .. b];
    }

    void mention(string name) {
        if (name.length)
            file.identifiers[name] = true;
    }

    void declare(Declaration d) {
        d.file = file.path;
        file.declarations ~= d;
    }

    void refer(string kind, string name, string role, int arity, Range range, string qualifier = null) {
        Reference r;
        r.kind = kind;
        r.name = name;
        r.role = role;
        r.arity = arity;
        r.file = file.path;
        r.range = range;
        r.inside = inside;
        r.qualifier = qualifier;
        file.references ~= r;
    }

    // --- statements -------------------------------------------------------------

    void block(BlockStmt b) {
        if (b is null)
            return;
        foreach (s; b.statements)
            stmt(s);
    }

    void stmt(Stmt s) {
        if (s is null)
            return;
        if (auto n = as!NarrativeDefinitionStmt(s))
            return definition(n, null);
        if (auto n = as!NarrativeDeckStmt(s)) {
            Declaration d;
            d.kind = "deck";
            d.name = n.name;
            d.range = rangeOf(n.nameLoc, n.nameEnd);
            d.extent = rangeOf(n.loc, n.end);
            declare(d);
            mention(n.name);
            expr(n.options);
            return;
        }
        if (auto n = as!RelationDeclStmt(s)) {
            Declaration d;
            d.kind = "relation";
            d.name = n.name;
            d.arity = n.arity;
            d.columns = n.columns;
            d.keys = n.keys;
            d.range = rangeOf(n.nameLoc, n.nameEnd);
            d.extent = rangeOf(n.loc, n.end);
            d.detail = "relation " ~ n.name ~ "(";
            if (n.columns.length) {
                foreach (i, column; n.columns)
                    d.detail ~= (i ? ", " : "") ~ column;
                d.detail ~= ")";
                if (n.keys.length) {
                    d.detail ~= " key(";
                    foreach (i, key; n.keys)
                        d.detail ~= (i ? ", " : "") ~ key;
                    d.detail ~= ")";
                }
            } else
                d.detail ~= numberText(n.arity) ~ ")";
            declare(d);
            mention(n.name);
            return;
        }
        if (auto n = as!LocalRelationDeclStmt(s)) {
            Declaration d;
            d.kind = "local-relation";
            d.name = n.name;
            d.arity = n.arity;
            d.range = rangeOf(n.nameLoc, n.nameEnd);
            d.extent = rangeOf(n.loc, n.end);
            declare(d);
            mention(n.name);
            return;
        }
        if (auto n = as!RuleDeclStmt(s)) {
            Declaration d;
            d.kind = "rule";
            d.name = n.headRel.name;
            d.arity = cast(int) n.headArgs.length;
            d.range = rangeOf(n.headRel.loc, n.headRel.end);
            d.extent = rangeOf(n.loc, n.end);
            declare(d);
            mention(n.headRel.name);
            auto saved = inside;
            inside = d.subject;
            foreach (a; n.headArgs)
                expr(a);
            goals(n.goals);
            inside = saved;
            return;
        }
        if (auto n = as!FactStmt(s))
            return relationUse(n.relRef, n.args, "assert", null);
        if (auto n = as!RetractStmt(s))
            return relationUse(n.relRef, n.args, "retract", null);
        if (auto n = as!UpdateStmt(s)) {
            relationUse(n.relRef, n.args, "update", null);
            expr(n.delta);
            return;
        }
        if (auto n = as!FunctionDeclStmt(s)) {
            Declaration d;
            d.kind = n.isLocal ? "local-function" : "function";
            if (n.isLocal)
                d.name = n.localName;
            else if (auto f = as!FieldExpr(n.target))
                d.name = f.field;
            else if (auto v = as!VariableExpr(n.target))
                d.name = v.name;
            d.range = rangeOf(n.nameLoc, n.nameEnd);
            d.extent = rangeOf(n.loc, n.end);
            d.parameters = n.def.params;
            d.detail = "function " ~ d.name ~ "(";
            foreach (i, p; n.def.params)
                d.detail ~= (i ? ", " : "") ~ p;
            d.detail ~= ")";
            declare(d);
            mention(d.name);
            if (!n.isLocal)
                expr(n.target);
            foreach (p; n.def.params)
                mention(p);
            block(n.def.body);
            return;
        }
        if (auto n = as!LabelStmt(s)) {
            Declaration d;
            d.kind = "label";
            d.name = n.label;
            d.range = rangeOf(n.loc, n.end);
            declare(d);
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
            foreach (name; n.names)
                mention(name);
            foreach (e; n.values)
                expr(e);
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
            mention(n.varName);
            expr(n.start);
            expr(n.limit);
            expr(n.step);
            return block(n.body);
        }
        if (auto n = as!ForGenericStmt(s)) {
            foreach (name; n.varNames)
                mention(name);
            foreach (e; n.iterators)
                expr(e);
            return block(n.body);
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

    void relationUse(AstRelRef ref_, Expr[] args, string role, string unusedParam) {
        string qualifier;
        foreach (i, part; ref_.worldPath)
            qualifier ~= (i ? "." : "") ~ part;
        mention(ref_.name);
        refer("relation", ref_.name, role, cast(int) args.length, rangeOf(ref_.loc, ref_.end), qualifier);
        if (ref_.name == "quality" && args.length >= 2)
            if (auto symbol = as!SymbolLiteralExpr(args[1]))
                refer("quality", symbol.name, role, -1, rangeOf(symbol.loc, symbol.end));
        foreach (a; args)
            expr(a);
    }

    void goals(AstGoal[] list) {
        foreach (g; list)
            goal(g);
    }

    void goal(AstGoal g) {
        if (auto n = as!AstRelAtomGoal(g))
            return relationUse(n.relRef, n.terms, n.isNegated ? "negated" : "read", null);
        if (auto n = as!AstComparisonGoal(g)) {
            expr(n.left);
            return expr(n.right);
        }
        if (auto n = as!AstAggregateGoal(g)) {
            expr(n.expression);
            return goals(n.goals);
        }
        if (auto n = as!AstGuardGoal(g))
            return expr(n.expr);
    }

    // --- definitions ------------------------------------------------------------

    void definition(NarrativeDefinitionStmt n, string owner) {
        Declaration d;
        d.kind = n.kind;
        d.name = n.name;
        d.owner = owner;
        d.range = rangeOf(n.nameLoc, n.nameEnd);
        d.extent = rangeOf(n.loc, n.end);
        d.parameters = n.parameters;
        foreach (i, field; n.fieldNames)
            if (field == "deck")
                if (auto symbol = as!SymbolLiteralExpr(n.fieldValues[i]))
                    d.deck = symbol.name;
        d.detail = n.kind ~ " " ~ n.name ~ "(";
        foreach (i, p; n.parameters)
            d.detail ~= (i ? ", ?" : "?") ~ p;
        d.detail ~= ")";
        if (n.goals.length) {
            auto whenSource = slice(n.goals[0].loc, n.goals[$ - 1].end);
            if (whenSource !is null)
                d.detail ~= "\nwhen { " ~ whenSource ~ " }";
        }
        if (d.deck.length)
            d.detail ~= "\ndeck :" ~ d.deck;
        foreach (i, field; n.fieldNames)
            if (field == "title")
                if (auto literal = as!LiteralStringExpr(n.fieldValues[i]))
                    d.detail ~= "\ntitle \"" ~ literal.value ~ "\"";
        declare(d);
        mention(n.name);
        foreach (p; n.parameters)
            mention(p);
        auto savedInside = inside;
        auto savedWhen = whenText;
        inside = d.subject;
        whenText = null;
        if (n.goals.length)
            whenText = slice(n.goals[0].loc, n.goals[$ - 1].end);
        goals(n.goals);
        foreach (i, field; n.fieldNames) {
            auto value = n.fieldValues[i];
            if (field == "title" || field == "text")
                message(d, field, value);
            else if (field == "deck") {
                if (auto symbol = as!SymbolLiteralExpr(value)) {
                    refer("deck", symbol.name, "read", -1, rangeOf(symbol.loc, symbol.end));
                } else
                    expr(value);
            } else if (field == "phase" || field == "once_per") {
                // Engine vocabulary: the engine, not the project, defines these words.
                if (auto symbol = as!SymbolLiteralExpr(value))
                    refer("symbol", symbol.name, "engine", -1, rangeOf(symbol.loc, symbol.end));
                else
                    expr(value);
            } else
                expr(value);
        }
        foreach (choice; n.choices)
            definition(choice, n.name);
        block(n.effect);
        inside = savedInside;
        whenText = savedWhen;
    }

    void message(ref Declaration d, string field, Expr value) {
        Message m;
        m.field = field;
        m.owner = d.subject;
        m.file = file.path;
        m.key = (d.owner.length ? d.owner ~ "." : "") ~ d.name ~ "." ~ field;
        m.when = whenText;
        auto literal = as!LiteralStringExpr(value);
        if (literal is null) {
            m.computed = true;
            m.range = rangeOf(value.loc, value.end);
            file.messages ~= m;
            expr(value);
            return;
        }
        m.text = literal.value;
        m.range = rangeOf(literal.loc, literal.end);
        auto raw = slice(literal.loc, literal.end);
        if (raw !is null) {
            auto scan = scanTemplate(raw, literal.loc.line, literal.loc.column, file.path, d.subject);
            m.placeholders = scan.placeholders;
            m.conditionRelations = scan.conditionRelations;
            m.variantOptions = scan.variantOptions;
            m.conditions = scan.conditions;
            file.references ~= scan.references;
        }
        file.messages ~= m;
    }

    // --- expressions ------------------------------------------------------------

    void expr(Expr e) {
        if (e is null)
            return;
        if (auto n = as!SymbolLiteralExpr(e)) {
            refer("symbol", n.name, "read", -1, rangeOf(n.loc, n.end));
            return;
        }
        if (auto n = as!VariableExpr(e))
            return mention(n.name);
        if (auto n = as!FieldExpr(e)) {
            mention(n.field);
            return expr(n.table);
        }
        if (auto n = as!IndexExpr(e)) {
            expr(n.table);
            return expr(n.key);
        }
        if (auto n = as!CallExpr(e))
            return call(n);
        if (auto n = as!MethodCallExpr(e)) {
            mention(n.method);
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
                if (auto key = as!LiteralStringExpr(field.key))
                    mention(key.value);
                else
                    expr(field.key);
                expr(field.value);
            }
            return;
        }
        if (auto n = as!FunctionDefExpr(e)) {
            foreach (p; n.params)
                mention(p);
            return block(n.body);
        }
        if (auto n = as!QueryExpr(e))
            return goals(n.goals);
    }

    /// `quality.define(:name, {label = "..."})` and `narrative.name(:symbol, "text")`.
    void call(CallExpr n) {
        auto callee = as!FieldExpr(n.callee);
        auto library = callee is null ? null : as!VariableExpr(callee.table);
        if (library !is null && library.name == "quality" && callee.field == "define" && n.args.length >= 1)
            return qualityDefine(n);
        if (library !is null && library.name == "narrative" && callee.field == "name" && n.args.length >= 2)
            return narrativeName(n);
        expr(n.callee);
        foreach (a; n.args)
            expr(a);
    }

    void qualityDefine(CallExpr n) {
        auto symbol = as!SymbolLiteralExpr(n.args[0]);
        Declaration d;
        d.kind = "quality";
        d.extent = rangeOf(n.loc, n.end);
        if (symbol is null) {
            d.computed = true;
            d.range = rangeOf(n.args[0].loc, n.args[0].end);
            declare(d);
            foreach (a; n.args)
                expr(a);
            return;
        }
        d.name = symbol.name;
        d.range = rangeOf(symbol.loc, symbol.end);
        d.detail = "quality :" ~ symbol.name;
        if (n.args.length >= 2)
            if (auto described = as!TableConstructorExpr(n.args[1]))
                foreach (field; described.fields) {
                    auto key = as!LiteralStringExpr(field.key);
                    if (key is null)
                        continue;
                    string shown;
                    if (auto v = as!LiteralIntExpr(field.value))
                        shown = numberText(v.value);
                    else if (auto u = as!UnaryExpr(field.value)) {
                        if (auto v = as!LiteralIntExpr(u.expr))
                            shown = "-" ~ numberText(v.value);
                    } else if (auto b = as!LiteralBoolExpr(field.value))
                        shown = b.value ? "true" : "false";
                    else if (auto text = as!LiteralStringExpr(field.value))
                        shown = "\"" ~ text.value ~ "\"";
                    if (shown.length)
                        d.detail ~= "\n" ~ key.value ~ " = " ~ shown;
                }
        declare(d);
        if (n.args.length < 2)
            return;
        auto options = as!TableConstructorExpr(n.args[1]);
        if (options is null) {
            expr(n.args[1]);
            return;
        }
        foreach (field; options.fields) {
            auto key = as!LiteralStringExpr(field.key);
            if (key !is null && key.value == "label") {
                auto saved = inside;
                inside = d.subject;
                Message m;
                m.field = "label";
                m.owner = d.subject;
                m.file = file.path;
                m.key = "quality." ~ d.name ~ ".label";
                if (auto literal = as!LiteralStringExpr(field.value)) {
                    m.text = literal.value;
                    m.range = rangeOf(literal.loc, literal.end);
                } else {
                    m.computed = true;
                    m.range = rangeOf(field.value.loc, field.value.end);
                    expr(field.value);
                }
                file.messages ~= m;
                inside = saved;
            } else
                expr(field.value);
        }
    }

    void narrativeName(CallExpr n) {
        auto symbol = as!SymbolLiteralExpr(n.args[0]);
        auto literal = as!LiteralStringExpr(n.args[1]);
        Declaration d;
        d.kind = "name";
        d.extent = rangeOf(n.loc, n.end);
        if (symbol is null || literal is null) {
            // `for sym, label in pairs {...} do narrative.name(sym, label) end`: not statically known.
            d.computed = true;
            d.range = rangeOf(n.args[0].loc, n.args[0].end);
            declare(d);
            Message m;
            m.field = "name";
            m.owner = "name";
            m.file = file.path;
            m.computed = true;
            m.range = rangeOf(n.args[1].loc, n.args[1].end);
            file.messages ~= m;
            foreach (a; n.args)
                expr(a);
            return;
        }
        d.name = symbol.name;
        d.range = rangeOf(symbol.loc, symbol.end);
        declare(d);
        Message m;
        m.field = "name";
        m.owner = d.subject;
        m.file = file.path;
        m.key = "name." ~ symbol.name;
        m.text = literal.value;
        m.range = rangeOf(literal.loc, literal.end);
        file.messages ~= m;
    }
}

/// Strips "chunk:LINE: " from a parser message.
private string messageText(string path, string text) {
    auto prefix = "@" ~ path;
    // The parser names the chunk without its "@"; keep only what follows the line number.
    size_t at;
    int colons;
    while (at < text.length && colons < 2) {
        if (text[at] == ':')
            ++colons;
        ++at;
    }
    while (at < text.length && text[at] == ' ')
        ++at;
    return colons == 2 ? text[at .. $] : text;
}

/// Indexes one file. A file with syntax errors yields the index of what did parse (the parser
/// recovers at statement and definition boundaries), `parsed` false, and one problem per error.
FileIndex indexFile(string path, string content) {
    FileIndex result;
    result.path = path;
    result.hash = fnv1a(content);
    // A leading "#!" line is not part of the program.
    string source = content;
    if (source.length > 1 && source[0] == '#')
        source = "--" ~ source[2 .. $];
    auto parser = new Parser(source, "@" ~ path, true);
    BlockStmt block;
    try {
        block = parser.parse();
    } catch (LuaException failure) {
        parser.problems ~= Parser.Problem("syntax error", 0, 0, 0, 0);
    }
    foreach (ref problem; parser.problems)
        result.problems ~= makeDiagnostic("error", "syntax", path, problem.line, problem.column, problem.endLine,
                problem.endColumn, messageText(path, problem.message));
    result.parsed = parser.problems.length == 0;
    if (block !is null) {
        auto builder = new Builder(&result, source);
        builder.block(block);
    }
    return result;
}

/// Declarations of a project of one kind and name.
const(Declaration)[] findDeclarations(ref const ProjectIndex index, string name) {
    const(Declaration)[] found;
    foreach (ref f; index.files)
        foreach (ref d; f.declarations)
            if (d.name == name)
                found ~= d;
    return found;
}

// -----------------------------------------------------------------------------
// Dump
// -----------------------------------------------------------------------------

private string numberText(long v) {
    import core.stdc.stdio : snprintf;

    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", v);
    return buffer[0 .. n].idup;
}

private string num(long v) {
    import core.stdc.stdio : snprintf;

    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", v);
    return buffer[0 .. n].idup;
}

private string rangeJson(Range r) {
    return `"line":` ~ num(r.line) ~ `,"column":` ~ num(r.column) ~ `,"endLine":` ~ num(
            r.endLine) ~ `,"endColumn":` ~ num(r.endColumn);
}

private string listJson(const(string)[] items) {
    string text = "[";
    foreach (i, item; items)
        text ~= (i ? "," : "") ~ jsonQuote(item);
    return text ~ "]";
}

/// The index as JSON, one object per table row, in file order. Deterministic: this is the golden
/// file of stage A1 (`varis check --index`).
string indexJson(ref const ProjectIndex index) {
    string files, declarations, references, messages;
    foreach (ref f; index.files) {
        files ~= (files.length ? ",\n" : "") ~ `  {"path":` ~ jsonQuote(f.path) ~ `,"parsed":` ~ (f.parsed ? "true"
                : "false")
            ~ `,"problems":` ~ num(f.problems.length) ~ `}`;
        foreach (ref d; f.declarations) {
            declarations ~= (declarations.length ? ",\n" : "") ~ `  {"kind":` ~ jsonQuote(
                    d.kind) ~ `,"name":` ~ jsonQuote(
                    d.name) ~ `,"file":` ~ jsonQuote(d.file) ~ `,` ~ rangeJson(d.range);
            if (d.owner.length)
                declarations ~= `,"owner":` ~ jsonQuote(d.owner);
            if (d.arity >= 0)
                declarations ~= `,"arity":` ~ num(d.arity);
            if (d.columns.length)
                declarations ~= `,"columns":` ~ listJson(d.columns);
            if (d.keys.length)
                declarations ~= `,"keys":` ~ listJson(d.keys);
            if (d.parameters.length)
                declarations ~= `,"parameters":` ~ listJson(d.parameters);
            if (d.deck.length)
                declarations ~= `,"deck":` ~ jsonQuote(d.deck);
            if (d.computed)
                declarations ~= `,"computed":true`;
            declarations ~= `}`;
        }
        foreach (ref r; f.references) {
            references ~= (references.length ? ",\n" : "") ~ `  {"kind":` ~ jsonQuote(
                    r.kind) ~ `,"name":` ~ jsonQuote(
                    r.name) ~ `,"role":` ~ jsonQuote(
                    r.role) ~ `,"file":` ~ jsonQuote(r.file) ~ `,` ~ rangeJson(r.range);
            if (r.qualifier.length)
                references ~= `,"qualifier":` ~ jsonQuote(r.qualifier);
            if (r.arity >= 0)
                references ~= `,"arity":` ~ num(r.arity);
            if (r.inside.length)
                references ~= `,"inside":` ~ jsonQuote(r.inside);
            references ~= `}`;
        }
        foreach (ref m; f.messages) {
            messages ~= (messages.length ? ",\n" : "") ~ `  {"key":` ~ jsonQuote(m.key) ~ `,"field":` ~ jsonQuote(
                    m.field) ~ `,"owner":` ~ jsonQuote(m.owner) ~ `,"file":` ~ jsonQuote(
                    m.file) ~ `,` ~ rangeJson(m.range)
                ~ `,"text":` ~ jsonQuote(m.text);
            if (m.placeholders.length)
                messages ~= `,"placeholders":` ~ listJson(m.placeholders);
            if (m.conditionRelations.length)
                messages ~= `,"conditionRelations":` ~ listJson(m.conditionRelations);
            if (m.conditions)
                messages ~= `,"conditions":` ~ num(m.conditions);
            if (m.variantOptions)
                messages ~= `,"variantOptions":` ~ num(m.variantOptions);
            if (m.when.length)
                messages ~= `,"when":` ~ jsonQuote(m.when);
            if (m.computed)
                messages ~= `,"computed":true`;
            messages ~= `}`;
        }
    }
    return "{\"files\":[\n" ~ files ~ "\n],\n\"declarations\":[\n" ~ declarations ~ "\n],\n\"references\":[\n" ~ references
        ~ "\n],\n\"messages\":[\n" ~ messages ~ "\n]}\n";
}
