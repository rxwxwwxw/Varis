/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The project manifest (AUTHORING_TOOLS_PLAN §3.2): `project.lua`, one table of literals that
/// says what a project is. It is read with the Varis parser and **never executed**, so it needs no
/// new parser and cannot do anything.
module varis.services.manifest;

import varis.ast;
import varis.exception : LuaException;
import varis.parser : Parser;
import varis.services.diagnostic;
import varis.workbench.server : jsonQuote, readFile, listFiles, sortStrings, isSourceName;

enum manifestName = "project.lua";
/// The manifest may instead be written in the Varis source extension; it wins when both exist.
enum manifestNameVaris = "project.varis";

struct Manifest {
    bool present;
    string path; // the manifest file, relative to the project root
    string id; // package id; qualifies message keys
    string language; // source language of the display text
    string entry; // module that loads and seals the content
    string session; // "module.function": function(seed) -> session
    string afterChoose; // "module.function": function(session), the host's step after a choice
    // The battle bridge (TOWER_DEFENSE_PLAN.md §5.1): "module.function" names, resolved like afterChoose.
    string battleRequest, battleSetup, battleSync, battleResult;
    string finished; // "module.function": function(session) -> boolean
    string load; // "module.function": function(saveText) -> session
    string[] content; // file patterns held to the content tier
    string[] scripts; // file patterns of engine scripts
    string[] locales; // translations kept in this repository
    string[] tests; // file patterns of author tests
    string[] symbols; // declared symbols (entities, flags, event kinds); opt-in strictness
    bool declaresSymbols; // the manifest has a `symbols` list
    Diagnostic[] problems;
}

private struct StringList {
    string[] items;
    bool ok;
}

private StringList literalStrings(Expr value) {
    StringList result;
    if (auto single = as!LiteralStringExpr(value)) {
        result.items = [single.value];
        result.ok = true;
        return result;
    }
    if (auto table = as!TableConstructorExpr(value)) {
        result.ok = true;
        foreach (field; table.fields) {
            auto item = as!LiteralStringExpr(field.value);
            if (field.key !is null || item is null) {
                result.ok = false;
                break;
            }
            result.items ~= item.value;
        }
    }
    return result;
}

private void record(ref Manifest manifest, string severity, string code, Expr at, string message) {
    auto d = makeDiagnostic(severity, code, manifest.path, at is null ? 0 : at.loc.line, at is null ? 0 : at.loc.column,
            at is null ? 0 : at.end.line, at is null ? 0 : at.end.column, message, "project manifest");
    manifest.problems ~= d;
}

/// Reads `<directory>/project.lua` when it exists. A missing manifest is not a problem: every
/// tool then behaves as it did before manifests existed.
Manifest loadManifest(string directory) {
    Manifest manifest;
    manifest.path = manifestName;
    string content;
    string prefix = directory.length && directory != "." ? directory ~ "/" : "";
    string full = prefix ~ manifestNameVaris;
    string resolved;
    if (readFile(full, content, resolved) && resolved == full)
        manifest.path = manifestNameVaris;
    else {
        full = prefix ~ manifestName;
        if (readFile(full, content, resolved))
            manifest.path = (prefix.length && resolved.length >= prefix.length && resolved[0 .. prefix.length] == prefix) ? resolved[prefix
                .length .. $] : resolved;
        else
            return manifest;
    }
    manifest.present = true;
    auto parser = new Parser(content, "@" ~ manifest.path);
    BlockStmt block = parser.parse();
    if (block is null) {
        int line = parser.hasErrorToken ? parser.errorToken.loc.line : 0;
        manifest.problems ~= makeDiagnostic("error", "manifest", manifest.path, line,
                parser.hasErrorToken ? parser.errorToken.loc.column : 0, line,
                parser.hasErrorToken ? parser.errorToken.endColumn : 0,
                "the project manifest does not parse", "project manifest");
        return manifest;
    }
    ReturnStmt returned;
    if (block.statements.length == 1)
        returned = as!ReturnStmt(block.statements[0]);
    TableConstructorExpr table;
    if (returned !is null && returned.values.length == 1)
        table = as!TableConstructorExpr(returned.values[0]);
    if (table is null) {
        manifest.record("error", "manifest", null, "the project manifest must be `return { ... }`, a single table of literals");
        return manifest;
    }
    foreach (field; table.fields) {
        auto key = as!LiteralStringExpr(field.key);
        if (key is null) {
            manifest.record("error", "manifest", field.value, "manifest entries must be `name = value`");
            continue;
        }
        auto list = literalStrings(field.value);
        if (!list.ok) {
            manifest.record("error", "manifest", field.value, "manifest field `" ~ key.value ~ "` must be a string or a list of strings");
            continue;
        }
        bool single = as!LiteralStringExpr(field.value) !is null;
        switch (key.value) {
        case "id":
        case "language":
        case "entry":
        case "session":
        case "after_choose":
        case "battle_request":
        case "battle_setup":
        case "battle_sync":
        case "battle_result":
        case "finished":
        case "load":
            if (!single) {
                manifest.record("error", "manifest", field.value, "manifest field `" ~ key.value ~ "` must be one string");
                break;
            }
            if (key.value == "id")
                manifest.id = list.items[0];
            else if (key.value == "language")
                manifest.language = list.items[0];
            else if (key.value == "entry")
                manifest.entry = list.items[0];
            else if (key.value == "session")
                manifest.session = list.items[0];
            else if (key.value == "after_choose")
                manifest.afterChoose = list.items[0];
            else if (key.value == "finished")
                manifest.finished = list.items[0];
            else if (key.value == "battle_request")
                manifest.battleRequest = list.items[0];
            else if (key.value == "battle_setup")
                manifest.battleSetup = list.items[0];
            else if (key.value == "battle_sync")
                manifest.battleSync = list.items[0];
            else if (key.value == "battle_result")
                manifest.battleResult = list.items[0];
            else
                manifest.load = list.items[0];
            break;
        case "content":
            manifest.content = list.items;
            break;
        case "scripts":
            manifest.scripts = list.items;
            break;
        case "locales":
            manifest.locales = list.items;
            break;
        case "tests":
            manifest.tests = list.items;
            break;
        case "symbols":
            manifest.symbols = list.items;
            manifest.declaresSymbols = true;
            break;
        default:
            manifest.record("warning", "manifest-key", field.value, "unknown manifest field `" ~ key.value ~ "`");
        }
    }
    return manifest;
}

/// Whether `path` (relative to the project) is a content-tier file: a `content` pattern of the
/// manifest matches it. A pattern written with `.lua` also covers the same name with `.varis` (and
/// the reverse), so renaming files to the Varis extension needs no manifest edit.
bool isContentFile(ref const Manifest manifest, string path) {
    foreach (pattern; manifest.content)
        if (sourceGlobMatch(pattern, path))
            return true;
    return false;
}

/// `globMatch`, where a pattern ending in `.lua` also matches the `.varis` file of that name (and
/// the reverse).
bool sourceGlobMatch(string pattern, string path) {
    if (globMatch(pattern, path))
        return true;
    if (pattern.length > 4 && pattern[$ - 4 .. $] == ".lua" && globMatch(pattern[0 .. $ - 4] ~ ".varis", path))
        return true;
    if (pattern.length > 6 && pattern[$ - 6 .. $] == ".varis" && globMatch(pattern[0 .. $ - 6] ~ ".lua", path))
        return true;
    return false;
}

/// `*` matches within one path segment, `**` across segments, `?` one byte.
bool globMatch(string pattern, string path) {
    return globAt(pattern, 0, path, 0);
}

private bool globAt(string p, size_t i, string s, size_t j) {
    while (i < p.length) {
        if (p[i] == '*') {
            bool deep = i + 1 < p.length && p[i + 1] == '*';
            size_t next = i + (deep ? 2 : 1);
            if (deep && next < p.length && p[next] == '/')
                if (globAt(p, next + 1, s, j))
                    return true; // `**/` also matches nothing
            for (size_t k = j; k <= s.length; ++k) {
                if (globAt(p, next, s, k))
                    return true;
                if (k < s.length && s[k] == '/' && !deep)
                    break;
            }
            return false;
        }
        if (j >= s.length)
            return false;
        if (p[i] != '?' && p[i] != s[j])
            return false;
        ++i;
        ++j;
    }
    return j == s.length;
}

/// Files under `directory` that match any pattern, sorted. Only `.lua` files are considered
/// until the source extension is decided (ROADMAP open decision 2).
string[] expandPatterns(string directory, const(string)[] patterns) {
    string[] found;
    listFiles(directory.length ? directory : ".", "", 0, found);
    string[] result;
    foreach (name; found) {
        if (!isSourceName(name))
            continue;
        foreach (pattern; patterns)
            if (sourceGlobMatch(pattern, name)) {
                result ~= name;
                break;
            }
    }
    sortStrings(result);
    return result;
}

private string stringArrayJson(const(string)[] items) {
    string text = "[";
    foreach (i, item; items)
        text ~= (i ? "," : "") ~ jsonQuote(item);
    return text ~ "]";
}

/// The manifest and its problems as JSON, for the workbench (`/api/project`).
string manifestJson(ref const Manifest manifest) {
    string text = `{"present":` ~ (manifest.present ? "true" : "false") ~ `,"path":` ~ jsonQuote(
            manifest.path)
        ~ `,"id":` ~ jsonQuote(manifest.id) ~ `,"language":` ~ jsonQuote(
                manifest.language) ~ `,"entry":` ~ jsonQuote(
                manifest.entry) ~ `,"session":` ~ jsonQuote(
                manifest.session) ~ `,"content":` ~ stringArrayJson(manifest.content)
        ~ `,"scripts":` ~ stringArrayJson(
                manifest.scripts) ~ `,"tests":` ~ stringArrayJson(
                manifest.tests)
        ~ `,"locales":` ~ stringArrayJson(
                manifest.locales) ~ `,"after_choose":` ~ jsonQuote(manifest.afterChoose)
        ~ `,"finished":` ~ jsonQuote(manifest.finished) ~ `,"load":` ~ jsonQuote(manifest.load) ~ `,"problems":[`;
    foreach (i, problem; manifest.problems)
        text ~= (i ? "," : "") ~ diagnosticJson(problem);
    return text ~ "]}";
}

/// The files a project tool reads: those the manifest lists, or every `.lua` file under the
/// directory when there is no manifest or it lists none. The manifest itself is not included.
string[] projectFiles(string directory, ref const Manifest manifest) {
    string[] files;
    if (manifest.present && (manifest.content.length || manifest.scripts.length || manifest.tests.length))
        files = expandPatterns(directory, manifest.content ~ manifest.scripts ~ manifest.tests);
    else {
        string[] found;
        listFiles(directory.length ? directory : ".", "", 0, found);
        foreach (name; found)
            if (isSourceName(name))
                files ~= name;
        sortStrings(files);
    }
    string[] kept;
    foreach (name; files)
        if (!(manifest.present && name == manifest.path))
            kept ~= name;
    return kept;
}
