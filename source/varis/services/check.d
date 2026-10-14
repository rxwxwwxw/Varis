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
import varis.services.tier;
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
    string locale; // `--locale L` or `all`: also check the translations
    string require; // `--require reviewed` or `draft`
    bool listSymbols; // `--symbols`: print the symbols no declaration names, as a `symbols` list
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
    // The content tier: files the manifest lists as `content` (default list, ROADMAP decision 1).
    if (manifest.present && manifest.content.length)
        foreach (file; expandPatterns(".", manifest.content)) {
            string text;
            if (readFile(file, text))
                problems ~= checkTier(file, text);
        }
    if (options.listSymbols) {
        bool[string] named;
        foreach (ref f; index.files)
            foreach (ref d; f.declarations)
                if (d.name.length)
                    named[d.name] = true;
        string[] free;
        bool[string] seen;
        foreach (ref f; index.files)
            foreach (ref r; f.references)
                if (r.kind == "symbol" && r.role != "engine" && r.name !in named && r.name !in seen) {
                    seen[r.name] = true;
                    free ~= r.name;
                }
        sortStrings(free);
        string text = "symbols = {\n";
        foreach (name; free)
            text ~= "    \"" ~ name ~ "\",\n";
        text ~= "},\n";
        fwrite(text.ptr, 1, text.length, stdout);
        return 0;
    }
    if (dumpIndex) {
        // The index shows every file, including those that only partly parsed.
        auto whole = index;
        whole.files ~= partial;
        auto text = indexJson(whole);
        fwrite(text.ptr, 1, text.length, stdout);
        return problems.length ? 1 : 0;
    }
    projectChecks(index, problems, manifest.symbols, manifest.declaresSymbols);
    pluralChecks(index, manifest.language.length ? manifest.language : "en", problems);
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
    if (options.locale.length && !dumpIndex) {
        import varis.services.catalog : buildSourceCatalog;
        import varis.services.l10n : checkLocale, LocaleCoverage;

        Diagnostic[] catalogProblems;
        auto source = buildSourceCatalog(index, manifest, catalogProblems);
        string[] tags = options.locale == "all" ? manifest.locales.dup : [options.locale];
        foreach (tag; tags) {
            LocaleCoverage coverage;
            problems ~= checkLocale(source, tag, coverage);

            string req = options.require;
            double minCov = 1.0;
            bool enforce = options.require.length > 0;
            if (auto pol = tag in manifest.localePolicies) {
                enforce = true;
                minCov = pol.minCoverage;
                if (!options.require.length)
                    req = pol.requireStatus;
            }
            if (enforce && coverage.total > 0) {
                double currentCov = 0.0;
                if (req == "draft")
                    currentCov = cast(double)(coverage.reviewed + coverage.draft) / cast(double) coverage.total;
                else
                    currentCov = cast(double) coverage.reviewed / cast(double) coverage.total;
                if (currentCov < minCov - 0.000001) {
                    problems ~= makeDiagnostic("error", "locale-policy", "l10n/" ~ tag ~ ".json", 0, 0, 0, 0,
                            tag ~ ": release policy requires " ~ (req == "draft" ? "draft" : "reviewed") ~
                            " coverage >= " ~ jsonNumber(cast(long)(
                                minCov * 100)) ~ "% (current: " ~
                            jsonNumber(cast(long)(currentCov * 100)) ~ "%)");
                }
            }
        }
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
