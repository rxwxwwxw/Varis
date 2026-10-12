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
import varis.services.checks;
import varis.services.index;
import varis.services.loadpass;
import varis.services.manifest;
import varis.workbench.server : readFile, listFiles, sortStrings, errorText;

private size_t errorCount(const(Diagnostic)[] items) {
    size_t count;
    foreach (ref d; items)
        if (d.isError)
            ++count;
    return count;
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
struct CheckOptions {
    bool json;
    bool dumpIndex;
    bool noLoad;
    bool analyze;
    int depth = 3;
    int nodes = 100;
}

int checkProject(LuaState state, string[] files, CheckOptions options) {
    bool json = options.json;
    bool dumpIndex = options.dumpIndex;
    auto manifest = loadManifest(".");
    size_t namedFiles = files.length;
    if (files.length == 0)
        files = projectFiles(".", manifest);
    Diagnostic[] problems = manifest.problems.dup;
    ProjectIndex index;
    FileIndex[] partial;
    foreach (file; files) {
        string content;
        if (!readFile(file, content)) {
            problems ~= makeDiagnostic("error", "io", file, 0, 0, 0, 0, "cannot read file");
            continue;
        }
        auto indexed = indexFile(file, content);
        if (!indexed.parsed) {
            // Every syntax error of the file, not only the first. The partial index stays in
            // the project for the services; the symbol lint skips it, being incomplete.
            problems ~= indexed.problems;
            partial ~= indexed;
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
        // The index shows every file, including those that only partly parsed.
        auto whole = index;
        whole.files ~= partial;
        auto text = indexJson(whole);
        fwrite(text.ptr, 1, text.length, stdout);
        return problems.length ? 1 : 0;
    }
    projectChecks(index, problems);
    // The load pass runs the project's entry module (never a session); the analysis pass, on
    // request, explores the manifest's session. Neither runs when files were named, or when
    // a file did not compile: the project is not in a state to load.
    if (!dumpIndex && namedFiles == 0 && manifest.present && manifest.entry.length && !options.noLoad && partial
            .length == 0
            && errorCount(problems) == 0) {
        bool loaded;
        problems ~= loadPass(state, manifest, index, loaded);
        if (loaded && options.analyze)
            problems ~= analysisPass(state, manifest, index, options.depth, options.nodes);
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
