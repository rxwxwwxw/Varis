/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The workbench server behind `varis serve` (WORKBENCH_PLAN.md, milestone 42, first version).
///
/// One thread owns the project's Lua state and answers HTTP requests on the loopback interface,
/// one at a time, so nothing ever touches the state concurrently. Requests carry a token printed
/// at start-up, because the command window runs arbitrary code. This first version speaks plain
/// request/response HTTP (text bodies, JSON replies); server-pushed events and the debugger
/// protocol of the plan are not implemented yet.
///
/// Tools layer: nothing in the runtime imports this module.
module varis.workbench.server;

import core.stdc.stdio;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;
import core.sys.posix.unistd : close, dup, dup2, read, write, chdir;
import core.sys.posix.sys.socket;
import core.sys.posix.netinet.in_;
import core.sys.posix.arpa.inet : htons, ntohs, htonl;

import varis.types;
import varis.table;
import varis.state;
import varis.vm;
import varis.exception : LuaException;
import varis.logic.world : World, Relation, unwrapWorld, visibleRelation;
import varis.workbench.page : workbenchPage;

private enum loopbackAddress = 0x7F000001; // 127.0.0.1

/// Lua side of the workbench: a JSON encoder and the read-only views the panels show. It runs in
/// the project's state and keeps everything in one table, `__workbench`, plus the global `story`.
private immutable string prelude = q"LUA
local W = {}
__workbench = W
local baseline = {}
for name in pairs(_G) do baseline[name] = true end
baseline.story = true

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function quote(text)
    return '"' .. tostring(text):gsub('[%c"\\]', function(c)
        return escapes[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end

local function encode(value, depth)
    depth = depth or 0
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return tostring(value) end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return quote(tostring(value)) end
        return tostring(value)
    end
    if kind == "table" and depth < 8 then
        local n = #value
        local parts = {}
        if n > 0 or next(value) == nil then
            for i = 1, n do parts[i] = encode(value[i], depth + 1) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local byText = {}
        for k in pairs(value) do byText[tostring(k)] = k end
        for i, k in ipairs(keys) do parts[i] = quote(k) .. ":" .. encode(value[byText[k]], depth + 1) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return quote(tostring(value))
end
W.encode = encode

local function preview(value)
    local kind = type(value)
    if kind == "table" then
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return "table (" .. count .. (count == 1 and " entry)" or " entries)")
    end
    local text = tostring(value)
    if #text > 80 then text = text:sub(1, 77) .. "..." end
    return text
end

-- Workspace: the globals the user created, like MATLAB's variable list.
function W.workspace()
    local names = {}
    for name in pairs(_G) do
        if type(name) == "string" and not baseline[name] then names[#names + 1] = name end
    end
    table.sort(names)
    local rows = {}
    for i, name in ipairs(names) do
        local value = _G[name]
        local kind = type(value)
        local world = false
        if kind == "userdata" then
            local ok, list = pcall(W.relations, value)
            world = ok and list ~= nil
        end
        rows[i] = { name = name, type = world and "world" or kind, preview = preview(value), world = world }
    end
    return encode({ variables = rows, session = W.session ~= nil })
end

function W.relationList(name)
    local list = W.relations(_G[name])
    table.sort(list, function(a, b) return a.name < b.name end)
    return encode({ world = name, relations = list })
end

function W.factPage(name, relation, start, count)
    local rows, total, columns = W.facts(_G[name], relation, start, count)
    for _, row in ipairs(rows) do
        for i = 1, #row do row[i] = tostring(row[i]) end
    end
    return encode({ world = name, relation = relation, start = start, total = total, columns = columns, rows = rows })
end

-- Story panel: the session registered with story(s).
function story(session)
    W.session = session
    W.presentation = nil
    return session
end

function W.present()
    if not W.session then return encode({ session = false }) end
    local p = W.session:present()
    W.presentation = p
    local storylets = {}
    for i, st in ipairs(p.storylets) do
        local choices = {}
        for j, c in ipairs(st.choices) do choices[j] = { id = tostring(c.id), title = tostring(c.title) } end
        storylets[i] = { id = tostring(st.id), title = tostring(st.title), text = tostring(st.text), choices = choices }
    end
    return encode({ session = true, turn = W.session:turn(), storylets = storylets })
end

-- Choosing reports what the turn changed: the facts added and removed, per relation.
function W.choose(storylet, choice)
    local p = W.presentation
    if not p then error("present the story first") end
    local st = p.storylets[storylet]
    local c = st and st.choices[choice]
    if not c then error("no such choice") end
    local world = W.session:world()
    local before = W.snapshot(world)
    W.session:choose(c.token)
    W.presentation = nil
    local changes = W.changes(before, world)
    for _, change in ipairs(changes) do
        for _, rows in ipairs({ change.added, change.removed }) do
            for _, row in ipairs(rows) do
                for i = 1, #row do row[i] = tostring(row[i]) end
            end
        end
    end
    W.lastChanges = changes
    return W.present()
end

function W.turnChanges()
    return encode({ changes = W.lastChanges or {} })
end

-- "Why is this storylet (not) showing?": narrative.explain, flattened for display.
function W.why(id)
    if not W.session then error("no session; call story(session) first") end
    local e = narrative.explain(W.session, logic.symbol(id))
    local goals = {}
    local trace = e.availability
    if trace and trace.goals then
        for i = 1, #trace.goals do
            local g = trace.goals[i]
            goals[i] = { index = g.index, kind = tostring(g.kind), outcome = tostring(g.outcome), before = g.before, after = g.after }
        end
    end
    local instances = {}
    for i = 1, #e.instances do
        local inst = e.instances[i]
        local exclusions = {}
        for j = 1, #inst.exclusions do exclusions[j] = tostring(inst.exclusions[j].reason or inst.exclusions[j]) end
        instances[i] = { key = tostring(inst.instance_key), eligible = inst.eligible, exclusions = exclusions }
    end
    return encode({ id = id, kind = tostring(e.kind), eligible = e.eligible, success = trace and trace.success,
        error = trace and trace.error and tostring(trace.error) or "", goals = goals, instances = instances })
end

function W.contentList()
    return encode({ storylets = W.storyletIds() })
end
LUA";

private struct Request {
    string method;
    string path;
    string[string] query;
    string body_;
}

package string jsonQuote(const(char)[] text) {
    char[] result;
    result ~= '"';
    foreach (char c; text) {
        switch (c) {
        case '"':
            result ~= `\"`;
            break;
        case '\\':
            result ~= `\\`;
            break;
        case '\n':
            result ~= `\n`;
            break;
        case '\r':
            result ~= `\r`;
            break;
        case '\t':
            result ~= `\t`;
            break;
        default:
            if (c < 0x20) {
                char[8] buffer;
                auto n = snprintf(buffer.ptr, buffer.length, "\\u%04x", cast(int) c);
                result ~= buffer[0 .. n];
            } else
                result ~= c;
        }
    }
    result ~= '"';
    return cast(string) result;
}

private int hexDigit(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private string percentDecode(const(char)[] text) {
    char[] result;
    for (size_t i = 0; i < text.length; ++i) {
        char c = text[i];
        if (c == '+')
            result ~= ' ';
        else if (c == '%' && i + 2 < text.length + 0 && hexDigit(text[i + 1]) >= 0 && hexDigit(text[i + 2]) >= 0) {
            result ~= cast(char)(hexDigit(text[i + 1]) * 16 + hexDigit(text[i + 2]));
            i += 2;
        } else
            result ~= c;
    }
    return cast(string) result;
}

private ptrdiff_t indexOf(const(char)[] haystack, const(char)[] needle) {
    if (needle.length == 0 || haystack.length < needle.length)
        return -1;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return i;
    return -1;
}

private bool sendAll(int socket, const(char)[] data) {
    while (data.length) {
        auto sent = send(socket, data.ptr, data.length, 0);
        if (sent <= 0)
            return false;
        data = data[sent .. $];
    }
    return true;
}

private void respond(int socket, int status, string contentType, const(char)[] content) {
    char[256] header;
    auto n = snprintf(header.ptr, header.length,
            "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            status, status == 200 ? "OK".ptr : "Error".ptr, (contentType ~ "\0").ptr, content.length);
    if (sendAll(socket, header[0 .. n]))
        sendAll(socket, content);
}

/// Reads one request. Returns false on a malformed or oversized request.
private bool readRequest(int socket, out Request request) {
    enum maxRequest = 16 * 1024 * 1024;
    char[] data;
    char[8192] chunk;
    ptrdiff_t headerEnd = -1;
    while (headerEnd < 0) {
        auto got = recv(socket, chunk.ptr, chunk.length, 0);
        if (got <= 0)
            return false;
        data ~= chunk[0 .. got];
        headerEnd = indexOf(data, "\r\n\r\n");
        if (headerEnd < 0 && data.length > 64 * 1024)
            return false;
    }
    auto head = data[0 .. headerEnd];
    auto lineEnd = indexOf(head, "\r\n");
    auto requestLine = lineEnd < 0 ? head : head[0 .. lineEnd];
    auto firstSpace = indexOf(requestLine, " ");
    if (firstSpace < 0)
        return false;
    request.method = requestLine[0 .. firstSpace].idup;
    auto rest = requestLine[firstSpace + 1 .. $];
    auto secondSpace = indexOf(rest, " ");
    auto target = secondSpace < 0 ? rest : rest[0 .. secondSpace];
    auto mark = indexOf(target, "?");
    request.path = percentDecode(mark < 0 ? target : target[0 .. mark]);
    if (mark >= 0) {
        auto pairs = target[mark + 1 .. $];
        while (pairs.length) {
            auto amp = indexOf(pairs, "&");
            auto pair = amp < 0 ? pairs : pairs[0 .. amp];
            pairs = amp < 0 ? null : pairs[amp + 1 .. $];
            auto eq = indexOf(pair, "=");
            if (eq < 0)
                request.query[percentDecode(pair)] = "";
            else
                request.query[percentDecode(pair[0 .. eq])] = percentDecode(pair[eq + 1 .. $]);
        }
    }
    size_t contentLength;
    auto headers = lineEnd < 0 ? null : head[lineEnd + 2 .. $];
    while (headers.length) {
        auto end = indexOf(headers, "\r\n");
        auto line = end < 0 ? headers : headers[0 .. end];
        headers = end < 0 ? null : headers[end + 2 .. $];
        enum name = "content-length:";
        if (line.length > name.length) {
            bool matches = true;
            foreach (i, char c; name)
                if ((line[i] | 0x20) != c && line[i] != c) {
                    matches = false;
                    break;
                }
            if (matches) {
                contentLength = 0;
                foreach (char c; line[name.length .. $])
                    if (c >= '0' && c <= '9')
                        contentLength = contentLength * 10 + (c - '0');
            }
        }
    }
    if (contentLength > maxRequest)
        return false;
    auto received = data[headerEnd + 4 .. $];
    while (received.length < contentLength) {
        auto got = recv(socket, chunk.ptr, chunk.length, 0);
        if (got <= 0)
            return false;
        received ~= chunk[0 .. got];
    }
    request.body_ = received[0 .. contentLength].idup;
    return true;
}

/// Runs `action` with the process's standard output redirected to a temporary file and returns
/// what was written (everything `print` and `io.write` produce).
private string captureOutput(scope void delegate() action) {
    fflush(null);
    auto capture = tmpfile();
    if (capture is null) {
        action();
        return null;
    }
    int saved = dup(1);
    dup2(fileno(capture), 1);
    scope (exit) {
        fflush(null);
        dup2(saved, 1);
        close(saved);
        fclose(capture);
    }
    action();
    fflush(null);
    rewind(capture);
    char[] output;
    char[4096] chunk;
    while (true) {
        auto got = fread(chunk.ptr, 1, chunk.length, capture);
        if (got == 0)
            break;
        output ~= chunk[0 .. got];
    }
    return cast(string) output;
}

private struct Evaluation {
    bool ok;
    bool incomplete;
    string output;
    string error;
}

package string errorText(LuaValue errorObject) {
    return isString(errorObject) ? errorObject.asString : toLuaString(errorObject);
}

/// The command window: an expression is evaluated and printed, anything else is run as a
/// statement, as in the interactive interpreter.
private Evaluation evaluate(LuaState state, string text, string chunkName) {
    Evaluation result;
    LuaFunction fn;
    try {
        fn = state.loadString("return " ~ text ~ ";", chunkName);
    } catch (LuaException) {
        try {
            fn = state.loadString(text, chunkName);
        } catch (LuaException failure) {
            result.error = errorText(failure.errorObject);
            result.incomplete = result.error.length >= 5 && result.error[$ - 5 .. $] == "<eof>";
            return result;
        }
    }
    result.output = captureOutput({
        try {
            auto values = VM.callValue(state, LuaValue(fn), []);
            if (values.length) {
                // The results live in a buffer the next call reuses: copy them first.
                auto copy = new LuaValue[values.length];
                copy[] = values[];
                VM.callValue(state, state.getGlobal("print"), copy);
            }
            result.ok = true;
        } catch (LuaException failure) {
            result.error = errorText(failure.errorObject);
        } catch (Exception failure) {
            result.error = failure.msg;
        }
    });
    return result;
}

private string evaluationJson(Evaluation e) {
    return `{"ok":` ~ (e.ok ? "true" : "false") ~ `,"incomplete":` ~ (e.incomplete ? "true" : "false") ~ `,"output":` ~ jsonQuote(
            e.output) ~ `,"error":` ~ jsonQuote(e.error) ~ `}`;
}

/// Calls a function of the Lua-side `__workbench` table that returns JSON text.
private string callView(LuaState state, string name, LuaValue[] arguments, out bool ok) {
    try {
        auto table = state.getGlobal("__workbench");
        auto fn = table.isTable ? table.asTable.rawget(LuaValue(name)) : luaNil();
        auto values = VM.callValue(state, fn, arguments);
        ok = true;
        return values.length && isString(values[0]) ? values[0].asString : "null";
    } catch (LuaException failure) {
        return `{"error":` ~ jsonQuote(errorText(failure.errorObject)) ~ `}`;
    } catch (Exception failure) {
        return `{"error":` ~ jsonQuote(failure.msg) ~ `}`;
    }
}

/// A project file path is relative, stays inside the project and names no hidden file.
private bool safePath(string path) {
    if (path.length == 0 || path[0] == '/' || path.length > 512)
        return false;
    if (indexOf(path, "..") >= 0 || indexOf(path, "\\") >= 0 || indexOf(path, "\0") >= 0)
        return false;
    return path[0] != '.' && indexOf(path, "/.") < 0;
}

package bool readFile(string path, out string content) {
    auto file = fopen((path ~ "\0").ptr, "rb");
    if (file is null)
        return false;
    scope (exit)
        fclose(file);
    char[] data;
    char[8192] chunk;
    while (true) {
        auto got = fread(chunk.ptr, 1, chunk.length, file);
        if (got == 0)
            break;
        data ~= chunk[0 .. got];
    }
    content = cast(string) data;
    return true;
}

private bool writeFile(string path, string content) {
    auto file = fopen((path ~ "\0").ptr, "wb");
    if (file is null)
        return false;
    bool ok = fwrite(content.ptr, 1, content.length, file) == content.length;
    return fclose(file) == 0 && ok;
}

/// Source files of the project, at most three directories deep.
package void listFiles(string directory, string prefix, int depth, ref string[] found) {
    import core.sys.posix.dirent : opendir, readdir, closedir, DT_DIR;

    auto handle = opendir((directory ~ "\0").ptr);
    if (handle is null)
        return;
    scope (exit)
        closedir(handle);
    while (true) {
        auto entry = readdir(handle);
        if (entry is null)
            break;
        auto name = entry.d_name[0 .. strlen(entry.d_name.ptr)].idup;
        if (name.length == 0 || name[0] == '.')
            continue;
        auto relative = prefix.length ? prefix ~ "/" ~ name : name;
        if (entry.d_type == DT_DIR) {
            if (depth < 3)
                listFiles(directory ~ "/" ~ name, relative, depth + 1, found);
        } else if (name.length > 4 && (name[$ - 4 .. $] == ".lua" || name[$ - 3 .. $] == ".md"))
            found ~= relative;
    }
}

package void sortStrings(string[] items) {
    foreach (i; 1 .. items.length) {
        auto item = items[i];
        size_t j = i;
        while (j > 0 && items[j - 1] > item) {
            items[j] = items[j - 1];
            --j;
        }
        items[j] = item;
    }
}

/// Read-only helpers the Lua side cannot express: the relations of a world and a page of facts.
private void installNatives(LuaState state) {
    auto table = state.getGlobal("__workbench").asTable;
    table.rawset(LuaValue("relations"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                auto world = args.length ? unwrapWorld(args[0]) : null;
                if (world is null)
                    return [luaNil()];
                auto list = new LuaTable();
                long index;
                foreach (name, relation; world.relations) {
                    auto visible = visibleRelation(relation);
                    auto row = new LuaTable();
                    row.rawset(LuaValue("name"), LuaValue(name));
                    row.rawset(LuaValue("arity"), LuaValue(cast(long) relation.arity));
                    row.rawset(LuaValue("count"), LuaValue(cast(long) visible.factTable().rows.length));
                    row.rawset(LuaValue("derived"), LuaValue(relation.rules.length != 0));
                    row.rawset(LuaValue("keyed"), LuaValue(relation.keyColumns.length != 0));
                    list.rawset(LuaValue(++index), LuaValue(row));
                }
                return [LuaValue(list)];
            }, "workbench.relations")));
    table.rawset(LuaValue("facts"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                auto world = args.length ? unwrapWorld(args[0]) : null;
                if (world is null || args.length < 2 || !isString(args[1]))
                    throw new LuaException("expected a world and a relation name");
                auto relation = world.getRelation(args[1].asString);
                if (relation is null)
                    throw new LuaException("unknown relation '" ~ args[1].asString ~ "'");
                auto facts = visibleRelation(relation).factTable().rows;
                long start = args.length > 2 && args[2].isInteger ? args[2].asInteger : 0;
                long count = args.length > 3 && args[3].isInteger ? args[3].asInteger : 100;
                if (start < 0)
                    start = 0;
                if (count < 0 || count > 1000)
                    count = 1000;
                auto rows = new LuaTable();
                long index;
                for (long i = start; i < cast(long) facts.length && index < count; ++i) {
                    auto row = new LuaTable();
                    foreach (column, value; facts[cast(size_t) i].values)
                        row.rawset(LuaValue(cast(long) column + 1), value.isNil ? LuaValue("nil") : value);
                    rows.rawset(LuaValue(++index), LuaValue(row));
                }
                auto columns = new LuaTable();
                foreach (i; 0 .. relation.arity)
                    columns.rawset(LuaValue(cast(long) i + 1), LuaValue(i < relation.columns.length
                    ? relation.columns[i] : "#" ~ cast(char)('1' + i % 9)));
                return [LuaValue(rows), LuaValue(cast(long) facts.length), LuaValue(columns)];
            }, "workbench.facts")));
}

/// The fact tables of a world at one moment (tables are immutable, so holding them is enough).
private final class WorldSnapshot {
    import varis.logic.store : FactTable;

    FactTable[string] tables;
}

private void installStoryNatives(LuaState state) {
    import varis.logic.store : FactTable;

    auto table = state.getGlobal("__workbench").asTable;
    table.rawset(LuaValue("snapshot"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                auto world = args.length ? unwrapWorld(args[0]) : null;
                if (world is null)
                    throw new LuaException("expected a world");
                auto snapshot = new WorldSnapshot;
                foreach (name, relation; world.relations)
                    snapshot.tables[name] = visibleRelation(relation).factTable();
                return [LuaValue(new LuaUserData(snapshot))];
            }, "workbench.snapshot")));
    table.rawset(LuaValue("changes"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                auto before = args.length > 0 && args[0].typeOf() == LuaType.UserData ? cast(WorldSnapshot) args[0]
                .asUserData.payload : null;
                auto world = args.length > 1 ? unwrapWorld(args[1]) : null;
                if (before is null || world is null)
                    throw new LuaException("expected a snapshot and a world");
                LuaTable rowsOf(FactTable from, FactTable other) {
                    auto rows = new LuaTable();
                    long count;
                    if (from !is null)
                        foreach (ref tuple; from.rows) {
                            if (other !is null && other.contains(tuple.values))
                                continue;
                            auto row = new LuaTable();
                            foreach (column, value; tuple.values)
                                row.rawset(LuaValue(cast(long) column + 1), value.isNil ? LuaValue("nil") : value);
                            rows.rawset(LuaValue(++count), LuaValue(row));
                        }
                    return rows;
                }

                string[] names;
                foreach (name, relation; world.relations)
                    names ~= name;
                sortStrings(names);
                auto list = new LuaTable();
                long index;
                foreach (name; names) {
                    auto now = visibleRelation(world.relations[name]).factTable();
                    auto was = name in before.tables;
                    if (was !is null && *was is now)
                        continue; // an unchanged relation still has the same table
                    auto added = rowsOf(now, was is null ? null : *was);
                    auto removed = rowsOf(was is null ? null : *was, now);
                    if (added.rawget(LuaValue(1L)).isNil && removed.rawget(LuaValue(1L)).isNil)
                        continue;
                    auto entry = new LuaTable();
                    entry.rawset(LuaValue("relation"), LuaValue(name));
                    entry.rawset(LuaValue("added"), LuaValue(added));
                    entry.rawset(LuaValue("removed"), LuaValue(removed));
                    list.rawset(LuaValue(++index), LuaValue(entry));
                }
                return [LuaValue(list)];
            }, "workbench.changes")));
    table.rawset(LuaValue("storyletIds"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                auto owner = cast(LuaState) pointer;
                string[] ids;
                if (owner.narrativeRegistry !is null)
                    foreach (definition; owner.narrativeRegistry.storylets())
                        ids ~= definition.id;
                sortStrings(ids);
                auto list = new LuaTable();
                foreach (i, id; ids)
                    list.rawset(LuaValue(cast(long) i + 1), LuaValue(id));
                return [LuaValue(list)];
            }, "workbench.storyletIds")));
}

private string makeToken() {
    ubyte[16] bytes;
    auto source = fopen("/dev/urandom", "rb");
    if (source !is null) {
        fread(bytes.ptr, 1, bytes.length, source);
        fclose(source);
    }
    char[] text;
    foreach (b; bytes) {
        text ~= "0123456789abcdef"[b >> 4];
        text ~= "0123456789abcdef"[b & 15];
    }
    return cast(string) text;
}

private long numberOf(string text, long fallback) {
    if (text.length == 0)
        return fallback;
    long value;
    foreach (char c; text) {
        if (c < '0' || c > '9')
            return fallback;
        value = value * 10 + (c - '0');
    }
    return value;
}

private void handle(LuaState state, int socket, ref Request request, string token) {
    auto given = "token" in request.query;
    if (given is null || *given != token) {
        respond(socket, 403, "text/plain", "missing or wrong token; use the address printed by varis serve\n");
        return;
    }
    string parameter(string name) {
        auto value = name in request.query;
        return value is null ? "" : *value;
    }

    bool ok;
    switch (request.path) {
    case "/":
        respond(socket, 200, "text/html; charset=utf-8", workbenchPage);
        return;
    case "/api/eval":
        respond(socket, 200, "application/json", evaluationJson(evaluate(state, request.body_, "=command")));
        return;
    case "/api/run": {
            auto path = parameter("path");
            string content;
            if (!safePath(path) || !readFile(path, content)) {
                respond(socket, 404, "application/json", `{"ok":false,"error":"cannot read file"}`);
                return;
            }
            Evaluation result;
            try {
                auto fn = state.loadString(content, "@" ~ path);
                result.output = captureOutput({
                    try {
                        VM.callValue(state, LuaValue(fn), []);
                        result.ok = true;
                    } catch (LuaException failure) {
                        result.error = errorText(failure.errorObject);
                    } catch (Exception failure) {
                        result.error = failure.msg;
                    }
                });
            } catch (LuaException failure) {
                result.error = errorText(failure.errorObject);
            }
            respond(socket, 200, "application/json", evaluationJson(result));
            return;
        }
    case "/api/check": {
            // Syntax check only (the full `varis check` of milestone 30 does not exist yet).
            auto path = parameter("path");
            string content = request.body_;
            if (request.method != "POST" && (!safePath(path) || !readFile(path, content))) {
                respond(socket, 404, "application/json", `{"problems":[]}`);
                return;
            }
            try {
                state.loadString(content, "@" ~ path);
                respond(socket, 200, "application/json", `{"problems":[]}`);
            } catch (LuaException failure) {
                respond(socket, 200, "application/json", `{"problems":[` ~ jsonQuote(
                        errorText(failure.errorObject)) ~ `]}`);
            }
            return;
        }
    case "/api/workspace":
        respond(socket, 200, "application/json", callView(state, "workspace", [], ok));
        return;
    case "/api/relations":
        respond(socket, 200, "application/json", callView(state, "relationList", [
            LuaValue(parameter("world"))
        ], ok));
        return;
    case "/api/facts":
        respond(socket, 200, "application/json", callView(state, "factPage", [
            LuaValue(parameter("world")), LuaValue(parameter("name")),
            LuaValue(numberOf(parameter("start"), 0)),
            LuaValue(numberOf(parameter("count"), 100))
        ], ok));
        return;
    case "/api/present":
        respond(socket, 200, "application/json", callView(state, "present", [], ok));
        return;
    case "/api/choose":
        respond(socket, 200, "application/json", callView(state, "choose", [
            LuaValue(numberOf(parameter("s"), 0)), LuaValue(numberOf(parameter("c"), 0))
        ], ok));
        return;
    case "/api/changes":
        respond(socket, 200, "application/json", callView(state, "turnChanges", [], ok));
        return;
    case "/api/why":
        respond(socket, 200, "application/json", callView(state, "why", [LuaValue(parameter("id"))], ok));
        return;
    case "/api/content":
        respond(socket, 200, "application/json", callView(state, "contentList", [], ok));
        return;
    case "/api/files": {
            string[] found;
            listFiles(".", "", 0, found);
            sortStrings(found);
            string json = `{"files":[`;
            foreach (i, name; found)
                json ~= (i ? "," : "") ~ jsonQuote(name);
            respond(socket, 200, "application/json", json ~ "]}");
            return;
        }
    case "/api/file": {
            auto path = parameter("path");
            if (!safePath(path)) {
                respond(socket, 400, "text/plain", "bad path\n");
                return;
            }
            if (request.method == "POST") {
                respond(socket, writeFile(path, request.body_) ? 200 : 500, "text/plain", "");
                return;
            }
            string content;
            if (!readFile(path, content)) {
                respond(socket, 404, "text/plain", "not found\n");
                return;
            }
            respond(socket, 200, "text/plain; charset=utf-8", content);
            return;
        }
    default:
        respond(socket, 404, "text/plain", "not found\n");
    }
}

/// Serves the workbench for the project in `directory` until the process is interrupted.
/// `port` 0 lets the system choose. Returns a process exit status.
int serveWorkbench(LuaState state, string directory, ushort port) {
    if (directory.length && chdir((directory ~ "\0").ptr) != 0) {
        fprintf(stderr, "varis serve: cannot enter '%s'\n", (directory ~ "\0").ptr);
        return 1;
    }
    try {
        VM.callValue(state, LuaValue(state.loadString(prelude, "=workbench")), []);
    } catch (LuaException failure) {
        fprintf(stderr, "varis serve: %s\n", (errorText(failure.errorObject) ~ "\0").ptr);
        return 1;
    }
    installNatives(state);
    installStoryNatives(state);
    // Project modules resolve from the project directory, as when a game is run from it.
    evaluate(state, `package.path = "./?.lua;" .. package.path`, "=workbench");

    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
        perror("varis serve: socket");
        return 1;
    }
    int enable = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enable, enable.sizeof);
    sockaddr_in address;
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(loopbackAddress);
    if (bind(listener, cast(sockaddr*)&address, address.sizeof) != 0 || listen(listener, 16) != 0) {
        perror("varis serve: bind");
        close(listener);
        return 1;
    }
    socklen_t length = address.sizeof;
    getsockname(listener, cast(sockaddr*)&address, &length);
    auto token = makeToken();
    printf("Varis workbench: http://127.0.0.1:%d/?token=%s\n", cast(int) ntohs(address.sin_port), (token ~ "\0").ptr);
    printf("Loopback only. The command window runs code with your permissions; keep the address private.\n");
    fflush(stdout);

    while (true) {
        int connection = accept(listener, null, null);
        if (connection < 0)
            continue;
        Request request;
        if (readRequest(connection, request))
            handle(state, connection, request, token);
        close(connection);
    }
}
