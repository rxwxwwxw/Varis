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
/// This version finds syntax and compile-time errors only. The checks the milestone also calls
/// for (unknown relations and symbols, unreachable storylets, the content tier) need the project
/// to be loaded and are not implemented yet.
module varis.workbench.check;

import core.stdc.stdio;

import varis.state;
import varis.exception : LuaException;
import varis.workbench.server : jsonQuote, readFile, listFiles, sortStrings, errorText;

private struct Diagnostic {
    string file;
    long line; // 0 when the message carries no line
    string code;
    string message;
}

/// Splits "chunk:12: message" as produced by the compiler for a chunk named "@file".
private Diagnostic diagnose(string file, string text) {
    Diagnostic result;
    result.file = file;
    result.code = "syntax";
    result.message = text;
    if (text.length > file.length + 1 && text[0 .. file.length] == file && text[file.length] == ':') {
        size_t at = file.length + 1;
        long line;
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

/// Checks the given files, or every `.lua` file under the current directory when none is given.
/// Prints one line per problem (or JSON with `json`) and returns the process exit status:
/// 0 when nothing was found, 1 otherwise.
int checkProject(LuaState state, string[] files, bool json) {
    if (files.length == 0) {
        string[] found;
        listFiles(".", "", 0, found);
        foreach (name; found)
            if (name.length > 4 && name[$ - 4 .. $] == ".lua")
                files ~= name;
        sortStrings(files);
    }
    Diagnostic[] problems;
    foreach (file; files) {
        string content;
        if (!readFile(file, content)) {
            problems ~= Diagnostic(file, 0, "io", "cannot read file");
            continue;
        }
        // A leading "#!" line is not part of the program.
        if (content.length > 1 && content[0] == '#') {
            content = "--" ~ content[2 .. $];
        }
        try {
            state.loadString(content, "@" ~ file);
        } catch (LuaException failure) {
            problems ~= diagnose(file, errorText(failure.errorObject));
        }
    }
    if (json) {
        string text = `{"files":` ~ jsonNumber(files.length) ~ `,"problems":[`;
        foreach (i, problem; problems)
            text ~= (i ? "," : "") ~ `{"file":` ~ jsonQuote(problem.file) ~ `,"line":` ~ jsonNumber(
                    problem.line) ~ `,"code":` ~ jsonQuote(problem.code) ~ `,"message":` ~ jsonQuote(
                    problem.message) ~ `}`;
        text ~= "]}\n";
        fwrite(text.ptr, 1, text.length, stdout);
    } else {
        foreach (problem; problems) {
            if (problem.line)
                printf("%s:%lld: %s [%s]\n", (problem.file ~ "\0").ptr, problem.line, (problem.message ~ "\0").ptr,
                        (problem.code ~ "\0").ptr);
            else
                printf("%s: %s [%s]\n", (problem.file ~ "\0").ptr, (problem.message ~ "\0").ptr, (problem.code ~ "\0")
                        .ptr);
        }
        printf("%zu file(s) checked, %zu problem(s)\n", files.length, problems.length);
    }
    fflush(stdout);
    return problems.length ? 1 : 0;
}

private string jsonNumber(long value) {
    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}
