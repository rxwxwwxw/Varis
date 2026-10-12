/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The load and analysis passes of `varis check` (AUTHORING_TOOLS_PLAN §3.5, stage A4). They run
/// the project's own entry module in a fresh state, up to the seal of the content, and report
/// what the engine's validation says with the source location of the definition. They never
/// create a session, except the analysis pass, which creates one through the manifest's
/// `session` function and only explores it (the original is not changed).
module varis.services.loadpass;

import varis.exception : LuaException;
import varis.state;
import varis.types;
import varis.vm : VM;
import varis.services.diagnostic;
import varis.services.index;
import varis.services.manifest;
import varis.workbench.server : errorText;

/// "file:12: message" -> file, 12, message. The line is 0 when the text has no location.
private void splitLocation(string text, out string file, out int line, out string message) {
    message = text;
    size_t colon;
    while (colon < text.length && text[colon] != ':')
        ++colon;
    if (colon == 0 || colon >= text.length)
        return;
    size_t at = colon + 1;
    int number;
    size_t digits;
    while (at < text.length && text[at] >= '0' && text[at] <= '9') {
        number = number * 10 + (text[at++] - '0');
        ++digits;
    }
    if (digits == 0 || at >= text.length || text[at] != ':')
        return;
    ++at;
    while (at < text.length && text[at] == ' ')
        ++at;
    file = text[0 .. colon];
    if (file.length > 2 && file[0] == '.' && file[1] == '/')
        file = file[2 .. $];
    line = number;
    message = text[at .. $];
}

private const(Declaration)* findDefinition(ref const ProjectIndex index, string kind, string id, string owner) {
    foreach (ref f; index.files)
        foreach (ref d; f.declarations)
            if (d.kind == kind && d.name == id && d.owner == owner)
                return &d;
    return null;
}

/// Runs the manifest's entry module. Returns the diagnostics; `ok` is false when it failed.
Diagnostic[] loadPass(LuaState state, ref const Manifest manifest, ref const ProjectIndex index, out bool ok) {
    Diagnostic[] found;
    ok = false;
    {
        auto quiet = QuietOutput(true);
        try {
            auto setup = state.loadString(`package.path = "./?.lua;./?/init.lua;" .. package.path`, "=check");
            VM.callValue(state, LuaValue(setup), []);
            VM.callValue(state, state.getGlobal("require"), [LuaValue(manifest.entry)]);
            ok = true;
        } catch (LuaException failure) {
            string file, message;
            int line;
            splitLocation(errorText(failure.errorObject), file, line, message);
            auto d = makeDiagnostic("error", "load", file.length ? file : manifest.entry, line, line > 0 ? 1 : 0, 0, 0, message);
            // A definition the engine rejected: point at it, and name it.
            if (failure.contentId.length) {
                auto definition = findDefinition(index, failure.contentKind, failure.contentId, failure.contentOwner);
                if (definition !is null) {
                    d.file = definition.file;
                    d.line = definition.range.line;
                    d.column = definition.range.column;
                    d.endLine = definition.range.endLine;
                    d.endColumn = definition.range.endColumn;
                    d.subject = definition.subject;
                }
            }
            found ~= d;
        } catch (Exception failure) {
            found ~= makeDiagnostic("error", "load", manifest.entry, 0, 0, 0, 0, "the entry module failed to load");
        }
    }
    return found;
}

/// Explores the session the manifest names and reports storylets that bounded exploration never
/// reaches. Bounded non-reachability is a hint, not a proof (docs: narrative.analyze), so these
/// are warnings and the message says what was explored.
Diagnostic[] analysisPass(LuaState state, ref const Manifest manifest, ref const ProjectIndex index, int depth, int nodes) {
    Diagnostic[] found;
    size_t dot = manifest.session.length;
    foreach_reverse (i, c; manifest.session)
        if (c == '.') {
            dot = i;
            break;
        }
    if (manifest.session.length == 0 || dot >= manifest.session.length) {
        found ~= makeDiagnostic("error", "analysis", manifest.path, 0, 0, 0, 0,
                "--analyze needs `session = \"module.function\"` in the project manifest");
        return found;
    }
    auto moduleName = manifest.session[0 .. dot];
    auto functionName = manifest.session[dot + 1 .. $];
    enum helper = `
local module, name, depth, nodes = ...
local session = require(module)[name](1)
local report = narrative.analyze(session, { depth = depth, max_nodes = nodes })
local names = {}
for i = 1, #report.unreachable_content do
    names[#names + 1] = logic.symbolname(report.unreachable_content[i].id)
end
return report.complete, report.nodes, report.depth_reached, names`;
    LuaValue[] result;
    {
        auto quiet = QuietOutput(true);
        try {
            auto fn = state.loadString(helper, "=analysis");
            result = VM.callValue(state, LuaValue(fn), [
                LuaValue(moduleName), LuaValue(functionName), LuaValue(cast(long) depth),
                LuaValue(cast(long) nodes)
            ]);
        } catch (LuaException failure) {
            string file, message;
            int line;
            splitLocation(errorText(failure.errorObject), file, line, message);
            found ~= makeDiagnostic("error", "analysis", file.length ? file : manifest.path, line, line > 0 ? 1 : 0, 0, 0,
                    "analysis failed: " ~ message);
            return found;
        }
    }
    if (result.length < 4 || !result[3].isTable)
        return found;
    bool complete = result[0].isTruthy;
    string scope_ = "explored " ~ numberText(result[1].isInteger ? result[1].asInteger
            : 0) ~ " node(s) to depth "
        ~ numberText(result[2].isInteger ? result[2].asInteger
                : 0) ~ " of " ~ numberText(depth);
    auto names = result[3].asTable;
    foreach (i; 1 .. names.rawLen() + 1) {
        auto value = names.rawget(LuaValue(cast(long) i));
        if (!value.isString)
            continue;
        auto id = value.asString;
        auto definition = findDefinition(index, "storylet", id, "");
        string file = definition !is null ? definition.file : manifest.path;
        Range range = definition !is null ? definition.range : Range.init;
        auto d = makeDiagnostic("warning", "unreachable", file, range.line, range.column, range.endLine, range.endColumn,
                "storylet " ~ id ~ " was not reached by bounded exploration (" ~ scope_ ~ "); this is not a proof that it can never appear",
                "storylet " ~ id);
        found ~= d;
    }
    if (!complete)
        found ~= makeDiagnostic("note", "analysis-incomplete", manifest.path, 0, 0, 0, 0,
                "the analysis is incomplete (a bound was exhausted or an operation was blocked): " ~ scope_);
    return found;
}

private string numberText(long value) {
    import core.stdc.stdio : snprintf;

    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}
