/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// `varis check` (ROADMAP milestone 30, first version): compiles every source file of a project
/// without running any of it and reports what does not compile, with file and line.
///
/// This version finds syntax and compile-time errors with a range, reads the project manifest
/// (`project.lua`, services/manifest.d) and warns about symbols written only once
/// in the whole project and never as a plain name (`:keepr` next to many `:keeper`s is almost
/// always a typo, and a typo in a symbol makes a storylet silently never appear). The other checks the milestone calls for
/// (unknown relations, unreachable storylets, the content tier) need the project to be loaded
/// and are not implemented yet.
module varis.services.check;

import core.stdc.stdio;

import varis.state;
import varis.exception : LuaException;
import varis.lexer : Lexer, Token, TokenType;
import varis.parser : Parser;
import varis.services.diagnostic;
import varis.services.manifest;
import varis.workbench.server : readFile, listFiles, sortStrings, errorText;

private struct SymbolUse {
    string file;
    int line;
    int column;
    int endLine;
    int endColumn;
    size_t count;
}

/// Records every `:name` symbol of a file that compiled. A colon starts a symbol unless it follows
/// something a method call can follow (a name, a closing bracket or a string).
private void collectSymbols(string file, string content, ref SymbolUse[string] uses, ref bool[string] identifiers) {
    try {
        auto lexer = new Lexer(content, "@" ~ file);
        auto previous = TokenType.EOF;
        while (true) {
            auto token = lexer.nextToken();
            if (token.type == TokenType.EOF)
                break;
            if (token.type == TokenType.Colon && previous != TokenType.Identifier && previous != TokenType.RParen
                    && previous != TokenType.RBracket && previous != TokenType.RBrace && previous != TokenType.String) {
                auto name = lexer.nextToken();
                if (name.type == TokenType.Identifier) {
                    if (auto known = name.text in uses)
                        known.count++;
                    else
                        uses[name.text] = SymbolUse(file, token.loc.line, token.loc.column, name.endLine, name
                                .endColumn, 1);
                }
                previous = name.type;
                if (name.type == TokenType.EOF)
                    break;
                continue;
            }
            // A plain name also counts as a mention: `storylet lamp` declares what `:lamp` refers to.
            if (token.type == TokenType.Identifier)
                identifiers[token.text] = true;
            previous = token.type;
        }
    } catch (Exception) {
        // The file compiled, so the lexer does not fail here; if it does, skip the lint.
    }
}

/// Splits "chunk:12: message" as produced by the parser and compiler for a chunk named "@file".
private Diagnostic diagnose(string file, string text) {
    auto result = makeDiagnostic("error", "syntax", file, 0, 0, 0, 0, text);
    if (text.length > file.length + 1 && text[0 .. file.length] == file && text[file.length] == ':') {
        size_t at = file.length + 1;
        int line;
        while (at < text.length && text[at] >= '0' && text[at] <= '9')
            line = line * 10 + (text[at++] - '0');
        if (at < text.length && text[at] == ':') {
            result.line = line;
            ++at;
            while (at < text.length && text[at] == ' ')
                ++at;
            result.message = text[at .. $];
        }
    }
    return result;
}

/// Checks the given files; with none given, the files the project manifest lists, or every `.lua`
/// file under the current directory when there is no manifest.
/// Prints one line per problem (or JSON with `json`) and returns the process exit status:
/// 1 when a file does not compile, 0 otherwise (warnings do not fail the check).
int checkProject(LuaState state, string[] files, bool json) {
    auto manifest = loadManifest(".");
    if (files.length == 0) {
        if (manifest.present && (manifest.content.length || manifest.scripts.length || manifest.tests.length))
            files = expandPatterns(".", manifest.content ~ manifest.scripts ~ manifest.tests);
        else {
            string[] found;
            listFiles(".", "", 0, found);
            foreach (name; found)
                if (name.length > 4 && name[$ - 4 .. $] == ".lua")
                    files ~= name;
            sortStrings(files);
        }
        // The manifest is read, never executed; its own problems are reported above.
        string[] kept;
        foreach (name; files)
            if (!(manifest.present && name == manifest.path))
                kept ~= name;
        files = kept;
    }
    Diagnostic[] problems = manifest.problems.dup;
    SymbolUse[string] symbolUses;
    bool[string] identifiers;
    foreach (file; files) {
        string content;
        if (!readFile(file, content)) {
            problems ~= makeDiagnostic("error", "io", file, 0, 0, 0, 0, "cannot read file");
            continue;
        }
        // A leading "#!" line is not part of the program.
        if (content.length > 1 && content[0] == '#') {
            content = "--" ~ content[2 .. $];
        }
        // Parse first, to know where a syntax error is; then compile for the errors the
        // compiler finds. Compiling parses again, which costs little against what it finds.
        auto parser = new Parser(content, "@" ~ file);
        bool parsed;
        try {
            parser.parse();
            parsed = true;
        } catch (LuaException failure) {
            auto d = diagnose(file, errorText(failure.errorObject));
            if (parser.hasErrorToken) {
                auto at = parser.errorToken;
                d.line = at.loc.line;
                d.column = at.loc.column;
                d.endLine = at.endLine;
                d.endColumn = at.endColumn;
            }
            problems ~= d;
        }
        if (!parsed)
            continue;
        try {
            state.loadString(content, "@" ~ file);
            collectSymbols(file, content, symbolUses, identifiers);
        } catch (LuaException failure) {
            problems ~= diagnose(file, errorText(failure.errorObject));
        }
    }
    // A symbol that appears once cannot connect two things: nothing else mentions it.
    string[] once;
    foreach (name, use; symbolUses)
        if (use.count == 1 && name !in identifiers)
            once ~= name;
    sortStrings(once);
    foreach (name; once) {
        auto use = symbolUses[name];
        problems ~= makeDiagnostic("warning", "symbol-once", use.file, use.line, use.column, use.endLine, use
                .endColumn,
                "symbol :" ~ name ~ " appears only here; is it misspelled?", "symbol :" ~ name);
    }
    sortDiagnostics(problems);
    size_t errors;
    foreach (problem; problems)
        if (problem.isError)
            ++errors;
    if (json) {
        string text = `{"files":` ~ jsonNumber(files.length) ~ `,"problems":[`;
        foreach (i, problem; problems)
            text ~= (i ? "," : "") ~ diagnosticJson(problem);
        text ~= "]}\n";
        fwrite(text.ptr, 1, text.length, stdout);
    } else {
        foreach (problem; problems) {
            auto line = diagnosticText(problem) ~ "\n";
            fwrite(line.ptr, 1, line.length, stdout);
        }
        printf("%zu file(s) checked, %zu error(s), %zu warning(s)\n", files.length, errors, problems.length - errors);
    }
    fflush(stdout);
    return errors ? 1 : 0; // warnings do not fail the check
}

private string jsonNumber(long value) {
    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}
