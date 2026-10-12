/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// `varis lsp`: the language services (services/lang.d) over the Language Server Protocol on
/// standard input and output, for editors other than the workbench. Full-document
/// synchronization; diagnostics are pushed whenever a document changes. Nothing is executed.
module varis.services.lsp;

import core.stdc.stdio;
import core.stdc.stdlib : exit;
import core.sys.posix.unistd : chdir;

import varis.services.diagnostic;
import varis.services.index : Range;
import varis.services.json;
import varis.services.lang;
import varis.workbench.server : jsonQuote;

private string numberText(long value) {
    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}

// --- UTF-16 columns -------------------------------------------------------------------

/// A 1-based byte column in `line` as a 0-based UTF-16 code unit offset.
int byteToUtf16(string line, int byteColumn) {
    int units;
    size_t i;
    size_t limit = byteColumn > 0 ? byteColumn - 1 : 0;
    if (limit > line.length)
        limit = line.length;
    while (i < limit) {
        ubyte c = line[i];
        size_t length = c < 0x80 ? 1 : (c < 0xE0 ? 2 : (c < 0xF0 ? 3 : 4));
        units += length == 4 ? 2 : 1;
        i += length;
    }
    return units;
}

/// A 0-based UTF-16 offset in `line` as a 1-based byte column.
int utf16ToByte(string line, int units) {
    int count;
    size_t i;
    while (i < line.length && count < units) {
        ubyte c = line[i];
        size_t length = c < 0x80 ? 1 : (c < 0xE0 ? 2 : (c < 0xF0 ? 3 : 4));
        count += length == 4 ? 2 : 1;
        i += length;
    }
    return cast(int) i + 1;
}

private final class Server {
    Workspace workspace;
    string root;
    bool shutdownRequested;
    string[string] published; // path -> last diagnostics JSON

    // --- transport -----------------------------------------------------------------

    static bool readMessage(out string body_) {
        long length = -1;
        while (true) {
            char[512] header;
            if (fgets(header.ptr, header.length, stdin) is null)
                return false;
            size_t n;
            while (n < header.length && header[n] != 0)
                ++n;
            auto text = header[0 .. n];
            if (text.length <= 2 && (text.length == 0 || text[0] == '\r' || text[0] == '\n'))
                break; // the empty line ends the headers
            enum key = "Content-Length:";
            if (text.length > key.length && text[0 .. key.length] == key) {
                length = 0;
                foreach (c; text[key.length .. $])
                    if (c >= '0' && c <= '9')
                        length = length * 10 + (c - '0');
            }
        }
        if (length < 0)
            return false;
        auto buffer = new char[](cast(size_t) length);
        size_t got;
        while (got < buffer.length) {
            auto n = fread(buffer.ptr + got, 1, buffer.length - got, stdin);
            if (n == 0)
                return false;
            got += n;
        }
        body_ = cast(string) buffer;
        return true;
    }

    static void send(string payload) {
        auto header = "Content-Length: " ~ numberText(payload.length) ~ "\r\n\r\n";
        fwrite(header.ptr, 1, header.length, stdout);
        fwrite(payload.ptr, 1, payload.length, stdout);
        fflush(stdout);
    }

    static void respond(string id, string result) {
        send(`{"jsonrpc":"2.0","id":` ~ id ~ `,"result":` ~ result ~ `}`);
    }

    static void fail(string id, int code, string message) {
        send(`{"jsonrpc":"2.0","id":` ~ id ~ `,"error":{"code":` ~ numberText(
                code) ~ `,"message":` ~ jsonQuote(message) ~ `}}`);
    }

    // --- paths and positions ----------------------------------------------------------

    static string percentDecode(string text) {
        char[] result;
        for (size_t i = 0; i < text.length; ++i) {
            if (text[i] == '%' && i + 2 < text.length) {
                int hi = hexValue(text[i + 1]), lo = hexValue(text[i + 2]);
                if (hi >= 0 && lo >= 0) {
                    result ~= cast(char)(hi * 16 + lo);
                    i += 2;
                    continue;
                }
            }
            result ~= text[i];
        }
        return cast(string) result;
    }

    static int hexValue(char c) {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    static string percentEncode(string text) {
        static immutable hex = "0123456789ABCDEF";
        char[] result;
        foreach (char c; text) {
            bool plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '-'
                || c == '_' || c == '.' || c == '~';
            if (plain)
                result ~= c;
            else {
                result ~= '%';
                result ~= hex[(cast(ubyte) c) >> 4];
                result ~= hex[(cast(ubyte) c) & 15];
            }
        }
        return cast(string) result;
    }

    /// A document URI as a path relative to the project root; null when it lies outside it.
    string pathOf(string uri) {
        enum scheme = "file://";
        if (uri.length < scheme.length || uri[0 .. scheme.length] != scheme)
            return null;
        auto path = percentDecode(uri[scheme.length .. $]);
        if (root.length && path.length > root.length && path[0 .. root.length] == root && path[root.length] == '/')
            return path[root.length + 1 .. $];
        return null;
    }

    string uriOf(string path) {
        return "file://" ~ percentEncode(root ~ "/" ~ path);
    }

    string lineOf(string path, int line) {
        auto found = path in workspace.contents;
        string fromDisk;
        if (found is null) {
            // A file outside the project index (a catalog): read what is on disk.
            import varis.workbench.server : readFile;

            if (!readFile(path, fromDisk))
                return "";
            found = &fromDisk;
        }
        auto text = found;
        int current = 1;
        size_t start;
        foreach (i, char c; *text) {
            if (c == '\n') {
                if (current == line)
                    return (*text)[start .. i];
                ++current;
                start = i + 1;
            }
        }
        return current == line ? (*text)[start .. $] : "";
    }

    string positionJson(string path, int line, int byteColumn) {
        auto character = byteToUtf16(lineOf(path, line), byteColumn);
        return `{"line":` ~ numberText(line > 0 ? line - 1 : 0) ~ `,"character":` ~ numberText(character) ~ `}`;
    }

    string rangeJson(string path, Range r) {
        int endLine = r.endLine > 0 ? r.endLine : r.line;
        int endColumn = r.endLine > 0 ? r.endColumn : r.column + 1;
        return `{"start":` ~ positionJson(path, r.line, r.column) ~ `,"end":` ~ positionJson(path, endLine, endColumn) ~ `}`;
    }

    string locationJson(Location l) {
        return `{"uri":` ~ jsonQuote(uriOf(l.file)) ~ `,"range":` ~ rangeJson(l.file, l.range) ~ `}`;
    }

    // --- diagnostics --------------------------------------------------------------------

    void publishDiagnostics() {
        auto all = workspace.diagnostics();
        foreach (path, list; all) {
            string json = "[";
            foreach (i, ref d; list) {
                Range r = Range(d.line > 0 ? d.line : 1, d.column > 0 ? d.column : 1, d.endLine, d.endColumn);
                string message = d.message;
                if (d.suggestion.length)
                    message ~= " (did you mean " ~ d.suggestion ~ "?)";
                int severity = d.severity == "error" ? 1 : (d.severity == "warning" ? 2 : 3);
                json ~= (i ? "," : "") ~ `{"range":` ~ rangeJson(path, r) ~ `,"severity":` ~ numberText(
                        severity) ~ `,"code":` ~ jsonQuote(
                        d.code) ~ `,"source":"varis","message":` ~ jsonQuote(message);
                if (d.related.length) {
                    json ~= `,"relatedInformation":[`;
                    foreach (j, ref rel; d.related)
                        json ~= (j ? "," : "") ~ `{"location":{"uri":` ~ jsonQuote(uriOf(
                                rel.file)) ~ `,"range":` ~ rangeJson(rel.file,
                                Range(rel.line, rel.column > 0 ? rel.column : 1, rel.line, rel.column > 0 ? rel.column + 1 : 2))
                            ~ `},"message":` ~ jsonQuote(rel.message) ~ `}`;
                    json ~= "]";
                }
                json ~= "}";
            }
            json ~= "]";
            if (auto last = path in published)
                if (*last == json)
                    continue;
            published[path] = json;
            send(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":` ~ jsonQuote(
                    uriOf(path))
                    ~ `,"diagnostics":` ~ json ~ `}}`);
        }
    }

    // --- requests -----------------------------------------------------------------------

    static int completionKind(string kind) {
        switch (kind) {
        case "storylet":
        case "action":
            return 7;
        case "relation":
        case "local-relation":
        case "deck":
            return 22;
        case "quality":
            return 6;
        case "keyword":
            return 14;
        case "symbol":
        case "name":
            return 20;
        case "function":
        case "local-function":
            return 3;
        default:
            return 1;
        }
    }

    static int symbolKind(string kind) {
        switch (kind) {
        case "storylet":
        case "action":
            return 5;
        case "choice":
            return 6;
        case "relation":
        case "local-relation":
        case "rule":
            return 23;
        case "function":
        case "local-function":
            return 12;
        case "quality":
            return 13;
        case "deck":
            return 3;
        default:
            return 15;
        }
    }

    bool position(const(JsonValue)* params, out string path, out int line, out int column) {
        auto document = params.get("textDocument");
        auto where = params.get("position");
        if (document is null || where is null)
            return false;
        path = pathOf(document.stringOr("uri"));
        if (path is null || !workspace.has(path))
            return false;
        line = cast(int) where.integerOr("line") + 1;
        column = utf16ToByte(lineOf(path, line), cast(int) where.integerOr("character"));
        return true;
    }

    void handle(ref const JsonValue message) {
        auto method = message.stringOr("method");
        auto idValue = message.get("id");
        string id;
        if (idValue !is null) {
            if (idValue.kind == JsonValue.Kind.string_)
                id = jsonQuote(idValue.text);
            else
                id = numberText(cast(long) idValue.number);
        }
        auto params = message.get("params");
        JsonValue empty;
        if (params is null)
            params = &empty;
        switch (method) {
        case "initialize": {
                string rootUri = params.stringOr("rootUri");
                if (rootUri.length > 7 && rootUri[0 .. 7] == "file://")
                    root = percentDecode(rootUri[7 .. $]);
                else
                    root = params.stringOr("rootPath");
                if (root.length > 1 && root[$ - 1] == '/')
                    root = root[0 .. $ - 1];
                if (root.length && chdir((root ~ "\0").ptr) != 0)
                    root = "";
                if (root.length == 0) {
                    import core.sys.posix.unistd : getcwd;

                    char[1024] buffer;
                    if (getcwd(buffer.ptr, buffer.length) !is null) {
                        size_t n;
                        while (buffer[n] != 0)
                            ++n;
                        root = buffer[0 .. n].idup;
                    }
                }
                workspace = new Workspace();
                workspace.load();
                respond(id, `{"capabilities":{"textDocumentSync":1,"completionProvider":{"triggerCharacters":[":","."]},`
                        ~ `"definitionProvider":true,"referencesProvider":true,"hoverProvider":true,`
                        ~ `"documentSymbolProvider":true,"renameProvider":true},"serverInfo":{"name":"varis"}}`);
                break;
            }
        case "initialized":
            publishDiagnostics();
            break;
        case "shutdown":
            shutdownRequested = true;
            respond(id, "null");
            break;
        case "exit":
            exit(shutdownRequested ? 0 : 1);
            break;
        case "textDocument/didOpen": {
                auto document = params.get("textDocument");
                if (document is null)
                    break;
                auto path = pathOf(document.stringOr("uri"));
                if (path !is null && isSourcePath(path)) {
                    workspace.setContent(path, document.stringOr("text"));
                    publishDiagnostics();
                }
                break;
            }
        case "textDocument/didChange": {
                auto document = params.get("textDocument");
                auto changes = params.get("contentChanges");
                if (document is null || changes is null || changes.items.length == 0)
                    break;
                auto path = pathOf(document.stringOr("uri"));
                if (path !is null && isSourcePath(path)) {
                    // Full synchronization: the last change holds the whole text.
                    workspace.setContent(path, changes.items[$ - 1].stringOr("text"));
                    publishDiagnostics();
                }
                break;
            }
        case "textDocument/didClose": {
                auto document = params.get("textDocument");
                if (document is null)
                    break;
                auto path = pathOf(document.stringOr("uri"));
                if (path !is null) {
                    // The editor no longer holds it: the file on disk is the truth again.
                    string text;
                    import varis.workbench.server : readFile;

                    if (readFile(path, text))
                        workspace.setContent(path, text);
                    else
                        workspace.remove(path);
                    publishDiagnostics();
                }
                break;
            }
        case "textDocument/completion": {
                string path;
                int line, column;
                if (!position(params, path, line, column)) {
                    respond(id, "[]");
                    break;
                }
                string json = "[";
                foreach (i, ref item; workspace.complete(path, line, column))
                    json ~= (i ? "," : "") ~ `{"label":` ~ jsonQuote(item.label) ~ `,"kind":` ~ numberText(
                            completionKind(item.kind))
                        ~ `,"detail":` ~ jsonQuote(item.detail.length ? item.detail : item.kind) ~ `}`;
                respond(id, json ~ "]");
                break;
            }
        case "textDocument/definition": {
                string path;
                int line, column;
                if (!position(params, path, line, column)) {
                    respond(id, "[]");
                    break;
                }
                string json = "[";
                foreach (i, l; workspace.definition(path, line, column))
                    json ~= (i ? "," : "") ~ locationJson(l);
                respond(id, json ~ "]");
                break;
            }
        case "textDocument/references": {
                string path;
                int line, column;
                if (!position(params, path, line, column)) {
                    respond(id, "[]");
                    break;
                }
                bool declaration = true;
                if (auto context = params.get("context"))
                    if (auto flag = context.get("includeDeclaration"))
                        declaration = flag.boolean;
                string json = "[";
                foreach (i, l; workspace.references(path, line, column, declaration))
                    json ~= (i ? "," : "") ~ locationJson(l);
                respond(id, json ~ "]");
                break;
            }
        case "textDocument/hover": {
                string path;
                int line, column;
                if (!position(params, path, line, column)) {
                    respond(id, "null");
                    break;
                }
                auto text = workspace.hover(path, line, column);
                if (text.length == 0)
                    respond(id, "null");
                else
                    respond(id, `{"contents":{"kind":"markdown","value":` ~ jsonQuote("```\n" ~ text ~ "\n```") ~ `}}`);
                break;
            }
        case "textDocument/documentSymbol": {
                auto document = params.get("textDocument");
                auto path = document is null ? null : pathOf(document.stringOr("uri"));
                if (path is null || !workspace.has(path)) {
                    respond(id, "[]");
                    break;
                }
                string json = "[";
                foreach (i, ref item; workspace.outline(path))
                    json ~= (i ? "," : "") ~ `{"name":` ~ jsonQuote(item.name) ~ `,"kind":` ~ numberText(
                            symbolKind(item.kind))
                        ~ `,"containerName":` ~ jsonQuote(
                                item.container) ~ `,"location":{"uri":` ~ jsonQuote(
                                uriOf(path))
                        ~ `,"range":` ~ rangeJson(path, item.extent) ~ `}}`;
                respond(id, json ~ "]");
                break;
            }
        case "textDocument/rename": {
                string path;
                int line, column;
                if (!position(params, path, line, column)) {
                    fail(id, -32602, "no such document");
                    break;
                }
                auto result = workspace.rename(path, line, column, params.stringOr("newName"));
                if (!result.ok) {
                    fail(id, -32602, result.error);
                    break;
                }
                string json = `{"changes":{`;
                string[] files;
                foreach (ref e; result.edits) {
                    bool known;
                    foreach (f; files)
                        if (f == e.file)
                            known = true;
                    if (!known)
                        files ~= e.file;
                }
                foreach (fi, file; files) {
                    json ~= (fi ? "," : "") ~ jsonQuote(uriOf(file)) ~ `:[`;
                    bool first = true;
                    foreach (ref e; result.edits)
                        if (e.file == file) {
                            // A catalog file is not in the workspace; its text is read for the columns.
                            json ~= (first ? "" : ",") ~ `{"range":` ~ rangeJson(file, e.range) ~ `,"newText":` ~ jsonQuote(
                                    e.newText) ~ `}`;
                            first = false;
                        }
                    json ~= "]";
                }
                respond(id, json ~ "}}");
                break;
            }
        default:
            if (id.length)
                fail(id, -32601, "method not found: " ~ method);
        }
    }

    static bool isSourcePath(string path) {
        return path.length > 4 && path[$ - 4 .. $] == ".lua";
    }
}

/// Runs the server until `exit`. Returns the process exit status.
int lspMain() {
    auto server = new Server();
    while (true) {
        string body_;
        if (!Server.readMessage(body_))
            return server.shutdownRequested ? 0 : 1;
        JsonValue message;
        string error;
        if (!parseJson(body_, message, error)) {
            Server.send(`{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":` ~ jsonQuote(error) ~ `}}`);
            continue;
        }
        server.handle(message);
    }
}
