/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The one diagnostic record of the authoring tools (AUTHORING_TOOLS_PLAN §3.4): the command line,
/// the workbench problems list, the language server and the localization checker all report
/// problems in this shape.
module varis.services.diagnostic;

import core.stdc.stdio;
import core.sys.posix.fcntl : open, O_WRONLY;
import core.sys.posix.unistd : dup, dup2, close;

import varis.workbench.server : jsonQuote;

/// A second location that explains a diagnostic (the other declaration of a duplicate id).
struct Related {
    string file;
    int line;
    int column;
    string message;
}

/// Columns are 1-based byte columns; `endLine` and `endColumn` are just past the last byte.
/// A range is zero when the tool could not determine it. `line` 0 means the problem has no place.
struct Diagnostic {
    string code; // stable short word, never reused for another meaning
    string severity = "error"; // "error", "warning" or "note"; only errors fail a check
    string file;
    int line;
    int column;
    int endLine;
    int endColumn;
    string subject; // what the writer would call it: "storylet topic_key", "field title"
    string message; // one sentence that names the subject
    string suggestion; // the nearest known name, when one is close
    Related[] related;

    bool isError() const {
        return severity == "error";
    }
}

/// Builds a record at a start position with an optional end.
Diagnostic makeDiagnostic(string severity, string code, string file, int line, int column, int endLine, int endColumn,
        string message, string subject = null, string suggestion = null) {
    Diagnostic result;
    result.severity = severity;
    result.code = code;
    result.file = file;
    result.line = line;
    result.column = column;
    result.endLine = endLine;
    result.endColumn = endColumn;
    result.message = message;
    result.subject = subject;
    result.suggestion = suggestion;
    return result;
}

/// Stable order: file, then position, then code, so output and golden files do not depend on
/// the order in which a tool found things.
void sortDiagnostics(Diagnostic[] items) {
    static bool before(ref const Diagnostic a, ref const Diagnostic b) {
        if (a.file != b.file)
            return a.file < b.file;
        if (a.line != b.line)
            return a.line < b.line;
        if (a.column != b.column)
            return a.column < b.column;
        if (a.code != b.code)
            return a.code < b.code;
        return a.message < b.message;
    }

    foreach (i; 1 .. items.length) {
        auto item = items[i];
        size_t j = i;
        while (j > 0 && before(item, items[j - 1])) {
            items[j] = items[j - 1];
            --j;
        }
        items[j] = item;
    }
}

private string number(long value) {
    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}

/// One JSON object. The first five fields are the ones `varis check --json` has always had.
string diagnosticJson(ref const Diagnostic d) {
    string text = `{"file":` ~ jsonQuote(d.file) ~ `,"line":` ~ number(
            d.line) ~ `,"severity":` ~ jsonQuote(
            d.severity) ~ `,"code":` ~ jsonQuote(
            d.code) ~ `,"message":` ~ jsonQuote(d.message);
    text ~= `,"column":` ~ number(d.column) ~ `,"endLine":` ~ number(d.endLine) ~ `,"endColumn":` ~ number(d.endColumn);
    if (d.subject.length)
        text ~= `,"subject":` ~ jsonQuote(d.subject);
    if (d.suggestion.length)
        text ~= `,"suggestion":` ~ jsonQuote(d.suggestion);
    if (d.related.length) {
        text ~= `,"related":[`;
        foreach (i, r; d.related)
            text ~= (i ? "," : "") ~ `{"file":` ~ jsonQuote(r.file) ~ `,"line":` ~ number(
                    r.line) ~ `,"column":` ~ number(
                    r.column) ~ `,"message":` ~ jsonQuote(r.message) ~ `}`;
        text ~= `]`;
    }
    return text ~ `}`;
}

/// `file:line:column: severity: message [code]`, the shape editors and CI parsers know.
string diagnosticText(ref const Diagnostic d) {
    string where = d.file;
    if (d.line > 0) {
        where ~= ":" ~ number(d.line);
        if (d.column > 0)
            where ~= ":" ~ number(d.column);
    }
    string text = where ~ ": " ~ d.severity ~ ": " ~ d.message;
    if (d.suggestion.length)
        text ~= " (did you mean " ~ d.suggestion ~ "?)";
    text ~= " [" ~ d.code ~ "]";
    foreach (r; d.related)
        text ~= "\n    " ~ r.file ~ ":" ~ number(r.line) ~ ": " ~ r.message;
    return text;
}

/// Project code may print; the checker's own output must stay clean (it may be JSON).
struct QuietOutput {
    int saved = -1;

    this(bool enable) {
        if (!enable)
            return;
        fflush(stdout);
        saved = dup(1);
        auto sink = open("/dev/null", O_WRONLY);
        if (sink >= 0) {
            dup2(sink, 1);
            close(sink);
        }
    }

    ~this() {
        if (saved >= 0) {
            fflush(stdout);
            dup2(saved, 1);
            close(saved);
        }
    }
}
