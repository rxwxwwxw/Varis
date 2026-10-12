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
import varis.services.diagnostic;
import varis.services.index;
import varis.services.manifest;
import varis.workbench.server : readFile, listFiles, sortStrings, errorText;

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
int checkProject(LuaState state, string[] files, bool json, bool dumpIndex = false) {
    auto manifest = loadManifest(".");
    if (files.length == 0)
        files = projectFiles(".", manifest);
    Diagnostic[] problems = manifest.problems.dup;
    ProjectIndex index;
    foreach (file; files) {
        string content;
        if (!readFile(file, content)) {
            problems ~= makeDiagnostic("error", "io", file, 0, 0, 0, 0, "cannot read file");
            continue;
        }
        auto indexed = indexFile(file, content);
        if (!indexed.parsed) {
            problems ~= indexed.problems;
            continue;
        }
        // The compiler finds errors the parser does not (labels, attributes, limits).
        if (content.length > 1 && content[0] == '#')
            content = "--" ~ content[2 .. $];
        try {
            state.loadString(content, "@" ~ file);
            index.files ~= indexed;
        } catch (LuaException failure) {
            problems ~= diagnose(file, errorText(failure.errorObject));
        }
    }
    if (dumpIndex) {
        auto text = indexJson(index);
        fwrite(text.ptr, 1, text.length, stdout);
        return problems.length ? 1 : 0;
    }
    // A symbol that appears once cannot connect two things: nothing else mentions it.
    struct SymbolUse {
        string file;
        Range range;
        size_t count;
    }

    SymbolUse[string] symbolUses;
    bool[string] identifiers;
    foreach (ref f; index.files) {
        foreach (name, _; f.identifiers)
            identifiers[name] = true;
        foreach (ref r; f.references) {
            if (r.kind != "symbol" || r.role == "engine")
                continue;
            if (auto known = r.name in symbolUses)
                known.count++;
            else
                symbolUses[r.name] = SymbolUse(r.file, r.range, 1);
        }
    }
    // Display text built by code cannot be extracted for translation.
    foreach (ref f; index.files)
        foreach (ref m; f.messages)
            if (m.computed)
                problems ~= makeDiagnostic("warning", "computed-text", m.file, m.range.line, m.range.column, m.range.endLine,
                        m.range.endColumn, "display text built by code cannot be extracted for translation", m.owner);
    string[] once;
    foreach (name, use; symbolUses)
        if (use.count == 1 && name !in identifiers)
            once ~= name;
    sortStrings(once);
    foreach (name; once) {
        auto use = symbolUses[name];
        problems ~= makeDiagnostic("warning", "symbol-once", use.file, use.range.line, use.range.column, use.range.endLine,
                use.range.endColumn, "symbol :" ~ name ~ " appears only here; is it misspelled?", "symbol :" ~ name);
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
