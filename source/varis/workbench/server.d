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
/// request/response HTTP (text bodies, JSON editor requests/replies) and the same requests over a
/// WebSocket (`/ws`), where the server also pushes events such as `stopped`.
///
/// Tools layer: nothing in the runtime imports this module.
module varis.workbench.server;

import core.stdc.stdio;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
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
import varis.narrative.registry : narrativeRegistry;
import varis.services.json : JsonValue, parseJson;

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
    return W.preview(value)
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
        rows[i] = { name = name, type = world and "world" or kind, preview = preview(value), world = world, table = kind == "table", session = W.isSession(value) }
    end
    return encode({ variables = rows, session = W.session ~= nil })
end

function W.relationList(name)
    local list = W.relations(_G[name])
    table.sort(list, function(a, b) return a.name < b.name end)
    return encode({ world = name, relations = list })
end

function W.factPage(name, relation, start, count, derived)
    local rows, total, columns = W.facts(_G[name], relation, start, count, derived)
    for _, row in ipairs(rows) do
        for i = 1, #row do row[i] = W.preview(row[i]) end
    end
    return encode({ world = name, relation = relation, start = start, total = total, columns = columns, rows = rows })
end

-- Story panel: the session registered with story(s).
function story(session)
    W.session = session
    W.presentation = nil
    W.history = {}
    W.lastChanges = nil
    return session
end

function W.present()
    if not W.session then return encode({ session = false }) end
    local p = W.session:present()
    W.presentation = p
    W.history[#W.history + 1] = { kind = "present", turn = W.session:turn() }
    return W.show(p)
end

-- The same presentation in another language (nil: the source language). Language is a view:
-- nothing is presented again, so no random number is drawn and no token is issued.
function W.setLanguage(tag, messages)
    if not W.session then error("no session; call story(session) first") end
    if tag and tag ~= "" then
        if messages then narrative.translate(tag, messages) end
        W.session:set_language(tag)
        W.language = tag
    else
        W.session:set_language(nil)
        W.language = nil
    end
    if W.presentation then
        W.presentation = W.session:render(W.presentation, W.language)
        return W.show(W.presentation)
    end
    return W.present()
end

-- The messages of the current presentation: key, source text, and the text now shown.
function W.messages()
    local p = W.presentation
    if not p then return encode({ language = W.language, messages = {} }) end
    local source = W.session:render(p, nil)
    local rows = {}
    local function add(key, source_text, shown)
        if source_text ~= "" then rows[#rows + 1] = { key = key, source = source_text, shown = shown } end
    end
    if source.scene then
        local beat = source.beats[1]
        if beat.id and beat.text then
            local id = tostring(beat.id):gsub("^:", "")
            add("scene." .. id .. ".text", beat.text, p.beats[1].text)
        end
        return encode({ language = W.language, messages = rows })
    end
    for i, st in ipairs(source.storylets) do
        local shown = p.storylets[i]
        local id = tostring(st.id)
        add(id .. ".title", st.title, shown.title)
        add(id .. ".text", st.text, shown.text)
        for j, c in ipairs(st.choices) do
            local key = id .. "." .. tostring(c.id)
            add(key .. ".title", c.title, shown.choices[j].title)
            add(key .. ".text", c.text, shown.choices[j].text)
        end
    end
    return encode({ language = W.language, messages = rows })
end

function W.show(p)
    if p.scene then
        return '{"session":true,"turn":' .. tostring(W.session:turn()) .. ',"language":' .. encode(W.language) ..
            ',"storylets":[],"sceneView":' .. W.reportJson(p) .. '}'
    end
    local storylets = {}
    for i, st in ipairs(p.storylets) do
        local choices = {}
        for j, c in ipairs(st.choices) do choices[j] = { id = tostring(c.id), title = tostring(c.title) } end
        storylets[i] = { id = tostring(st.id), title = tostring(st.title), text = tostring(st.text), choices = choices }
    end
    return encode({ session = true, turn = W.session:turn(), storylets = storylets, language = W.language })
end

-- Choosing reports what the turn changed: the facts added and removed, per relation.
function W.choose(storylet, choice, deferPresent)
    local p = W.presentation
    if not p then error("present the story first") end
    local st = p.storylets[storylet]
    local c = st and st.choices[choice]
    if not c then error("no such choice") end
    local world = W.session:world()
    local before = W.snapshot(world)
    W.session:choose(c.token)
    W.history[#W.history + 1] = { kind = "choose", turn = W.session:turn(), story = st.instance_key, choice = c.instance_key }
    if W.afterChoose then W.afterChoose(W.session) end
    W.presentation = nil
    local changes = W.changes(before, world)
    for _, change in ipairs(changes) do
        for _, rows in ipairs({ change.added, change.removed }) do
            for _, row in ipairs(rows) do
                for i = 1, #row do row[i] = W.preview(row[i]) end
            end
        end
    end
    W.lastChanges = changes
    if not deferPresent then return W.present() end
end

-- Scene tokens stay on the server. Menu indexes resolve to exact authored ids.
function W.play(id, deferPresent)
    if not W.session then error("no session; call story(session) first") end
    W.session:play(logic.symbol(id))
    W.history[#W.history + 1] = { kind = "play", turn = W.session:turn(), scene = id }
    W.presentation = nil
    if not deferPresent then return W.present() end
end
function W.advance(input, choice, deferPresent)
    local p = W.presentation
    if not p or not p.scene then error("present a scene first") end
    if choice and choice ~= 0 then
        local c = p.beats[1].choices and p.beats[1].choices[choice]
        if not c then error("no such scene menu choice") end
        input = c.id
    end
    local scene, index = tostring(p.scene), p.beat_index
    W.session:advance(p.token, input)
    W.history[#W.history + 1] = { kind = "advance", turn = W.session:turn(), scene = scene, beat = index, input = input }
    W.presentation = nil
    if not deferPresent then return W.present() end
end

-- A manifest-backed project has a reproducible session factory. Replays match stable
-- instance keys, never presentation indexes or tokens from an earlier state.
local function resolve(path)
    if not path or path == "" then return nil end
    local module, name = path:match("^(.*)%.([^.]+)$")
    assert(module, "manifest: expected module.function")
    return require(module)[name]
end
function W.start(entry, factory, afterChoose, seed, records, turn, language, commandLimit)
    require(entry)
    if language and language ~= "" then narrative.source_language(language) end
    local create = assert(resolve(factory), "manifest has no session factory")
    W.afterChoose = resolve(afterChoose)
    story(create(seed))
    W.seed = seed
    s = W.session
    w = s:world()
    if records then
        for index, record in ipairs(records) do
            if record.turn > turn or index > commandLimit then break end
            if record.kind == "present" then
                W.present()
            elseif record.kind == "play" then
                W.play(record.scene, true)
            elseif record.kind == "advance" then
                assert(W.presentation and tostring(W.presentation.scene) == record.scene and W.presentation.beat_index == record.beat,
                    "replay diverged: scene position changed")
                W.advance(record.input, 0, true)
            else
                local found = false
                for i, st in ipairs(W.presentation.storylets) do
                    for j, c in ipairs(st.choices) do
                        if st.instance_key == record.story and c.instance_key == record.choice then
                            W.choose(i, j, true)
                            found = true
                            break
                        end
                    end
                    if found then break end
                end
                assert(found, "replay diverged: choice is no longer available at turn " .. record.turn)
            end
        end
    end
    if not W.presentation then return W.present() end
    return W.show(W.presentation)
end
function W.historyView()
    return encode({ seed = W.seed, turn = W.session and W.session:turn(), commands = W.history or {},
        replayable = W.seed ~= nil })
end

function W.turnChanges()
    return encode({ changes = W.lastChanges or {} })
end

-- Explanations are snapshot views. Choice traces retain their correlated parent instance.
local function traceView(trace)
    local goals = {}
    if trace and trace.goals then
        for i = 1, #trace.goals do
            local g = trace.goals[i]
            goals[i] = { index = g.index, kind = tostring(g.kind), outcome = tostring(g.outcome), before = g.before, after = g.after }
        end
    end
    return { success = trace and trace.success, error = trace and trace.error and tostring(trace.error) or "", goals = goals }
end
function W.why(id)
    if not W.session then error("no session; call story(session) first") end
    local e = narrative.explain(W.session, logic.symbol(id))
    local result = traceView(e.availability)
    result.id, result.kind, result.eligible = id, tostring(e.kind), e.eligible
    result.instances = {}
    for i = 1, #e.instances do
        local inst = e.instances[i]
        local exclusions, choices = {}, {}
        for j = 1, #inst.exclusions do exclusions[j] = tostring(inst.exclusions[j].reason or inst.exclusions[j]) end
        for j = 1, #inst.choices do
            local c = inst.choices[j]
            local trace = traceView(c.availability)
            trace.id, trace.eligible = tostring(c.id), inst.eligible and trace.success
            choices[j] = trace
        end
        result.instances[i] = { key = tostring(inst.instance_key), eligible = inst.eligible, exclusions = exclusions, choices = choices }
    end
    return encode(result)
end

function W.analyze(depth, nodes, steps, objects)
    if not W.session then error("no session; call story(session) first") end
    return W.reportJson(narrative.analyze(W.session, { depth = depth, max_nodes = nodes,
        max_steps = steps, max_objects = objects }))
end

-- Completion for the command window and editor: names reachable from the text before the cursor.
-- "pre" completes globals, keywords and (after a colon) storylet ids and relation names;
-- "a.b.pre" completes the fields of the table a.b. Read-only: it indexes with rawget only.
local keywords = { "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
    "relation", "fact", "retract", "rule", "query", "transaction", "rollback", "storylet", "choice", "action",
    "deck", "when", "effect", "title", "text", "priority", "set", "delete", "adjust", "logic" }
function W.complete(text)
    local symbol = text:match(":([%a_][%w_]*)$")
    local found, seen = {}, {}
    local function add(name, kind)
        if type(name) == "string" and not seen[name] then seen[name] = true; found[#found + 1] = { name = name, kind = kind } end
    end
    local prefix
    if symbol and not text:match("[%w_%]%)]:[%a_][%w_]*$") then
        prefix = symbol
        for _, id in ipairs(W.storyletIds()) do if id:sub(1, #prefix) == prefix then add(id, "storylet") end end
        for name, value in pairs(_G) do
            if type(value) == "userdata" then
                local ok, list = pcall(W.relations, value)
                if ok and list then
                    for _, r in ipairs(list) do if r.name:sub(1, #prefix) == prefix then add(r.name, "relation") end end
                end
            end
        end
    else
        local path, last = text:match("([%a_][%w_%.]*)%.([%w_]*)$")
        if path then
            prefix = last
            local value = _G
            for part in path:gmatch("[^%.]+") do
                value = type(value) == "table" and rawget(value, part) or nil
            end
            if type(value) == "table" then
                for name, field in pairs(value) do
                    if type(name) == "string" and name:sub(1, #prefix) == prefix then add(name, type(field)) end
                end
            end
        else
            prefix = text:match("([%a_][%w_]*)$") or ""
            if prefix ~= "" then
                for name, value in pairs(_G) do
                    if type(name) == "string" and name:sub(1, #prefix) == prefix and name ~= "__workbench" then add(name, type(value)) end
                end
                for _, word in ipairs(keywords) do if word:sub(1, #prefix) == prefix then add(word, "keyword") end end
                for _, r in ipairs(W.worldRelationNames()) do if r:sub(1, #prefix) == prefix then add(r, "relation") end end
            end
        end
    end
    table.sort(found, function(a, b) return a.name < b.name end)
    while #found > 60 do found[#found] = nil end
    return encode({ prefix = prefix or "", items = found })
end

function W.worldRelationNames()
    local names = {}
    for _, value in pairs(_G) do
        if type(value) == "userdata" then
            local ok, list = pcall(W.relations, value)
            if ok and list then for _, r in ipairs(list) do names[#names + 1] = r.name end end
        end
    end
    return names
end

function W.contentList()
    return encode({ storylets = W.storyletIds(), scenes = W.sceneIds() })
end
LUA";

private struct Request {
    string method;
    string path;
    string[string] query;
    string body_;
    string wsKey; // Sec-WebSocket-Key of an upgrade request
}

public string jsonQuote(const(char)[] text) {
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

// ---- WebSocket transport ----------------------------------------------------------------------
//
// One endpoint, `/ws?token=...`. Each text message is a JSON envelope
//   {"id": 1, "method": "GET"|"POST", "path": "/api/eval", "query": {...}, "body": "..."}
// that is served by the same handlers as the HTTP request it names (the connection's token is
// added), and answered with {"id": 1, "status": 200, "body": <JSON, or a string for other types>}.
// The server also pushes events: {"event": "hello"} on connect and {"event": "stopped", "data": ...}
// when the debugger stops, so a client need not hold a request open to learn of it. A request is
// given a virtual connection number (at or above `virtualBase`), which `respond` and
// `closeConnection` route back into the WebSocket, so no handler knows the transport.

private enum virtualBase = 1_000_000;

private struct WebSocketReply {
    int socket;
    string id; // the request's id as JSON text
}

private __gshared WebSocketReply[int] webSocketReplies;
private __gshared int[] webSocketClients;
private __gshared int nextVirtual = virtualBase;
private __gshared Mutex webSocketLock;

private void sendFrame(int socket, const(char)[] payload, ubyte opcode = 1) {
    ubyte[10] head;
    size_t n;
    head[n++] = 0x80 | opcode;
    if (payload.length < 126)
        head[n++] = cast(ubyte) payload.length;
    else if (payload.length < 65536) {
        head[n++] = 126;
        head[n++] = cast(ubyte)(payload.length >> 8);
        head[n++] = cast(ubyte) payload.length;
    } else {
        head[n++] = 127;
        foreach (i; 0 .. 8)
            head[n++] = cast(ubyte)(cast(ulong) payload.length >> (56 - 8 * i));
    }
    webSocketLock.lock();
    scope (exit)
        webSocketLock.unlock();
    if (sendAll(socket, cast(const(char)[]) head[0 .. n]))
        sendAll(socket, payload);
}

private void webSocketRespond(int virtual, int status, string contentType, const(char)[] content) {
    WebSocketReply reply;
    webSocketLock.lock();
    auto found = virtual in webSocketReplies;
    if (found is null) {
        webSocketLock.unlock();
        return;
    }
    reply = *found;
    webSocketLock.unlock();
    char[] message;
    message ~= `{"id":`;
    message ~= reply.id;
    message ~= `,"status":`;
    message ~= numberJson(status);
    message ~= `,"body":`;
    if (contentType.length >= 16 && contentType[0 .. 16] == "application/json" && content.length)
        message ~= content;
    else
        message ~= jsonQuote(content);
    message ~= '}';
    sendFrame(reply.socket, message);
}

/// Closes a real connection, or forgets a virtual one (its answer has been sent).
private void closeConnection(int connection) {
    if (connection >= virtualBase) {
        webSocketLock.lock();
        webSocketReplies.remove(connection);
        webSocketLock.unlock();
    } else
        close(connection);
}

/// Pushes an event to every connected WebSocket client.
private void webSocketBroadcast(string name, const(char)[] data) {
    if (webSocketLock is null)
        return;
    string message = `{"event":` ~ jsonQuote(name) ~ (data.length ? `,"data":` ~ data.idup : "") ~ `}`;
    webSocketLock.lock();
    auto clients = new int[webSocketClients.length];
    clients[] = webSocketClients[];
    webSocketLock.unlock();
    foreach (client; clients)
        sendFrame(client, message);
}

private bool receiveExactly(int socket, ubyte[] into) {
    size_t have;
    while (have < into.length) {
        auto got = recv(socket, into.ptr + have, into.length - have, 0);
        if (got <= 0)
            return false;
        have += got;
    }
    return true;
}

private void webSocketReader(int socket) {
    scope (exit) {
        webSocketLock.lock();
        foreach (i, client; webSocketClients)
            if (client == socket) {
                webSocketClients = webSocketClients[0 .. i] ~ webSocketClients[i + 1 .. $];
                break;
            }
        webSocketLock.unlock();
        close(socket);
    }
    enum maxMessage = 16 * 1024 * 1024;
    char[] message;
    for (;;) {
        ubyte[2] head;
        if (!receiveExactly(socket, head[]))
            return;
        bool fin = (head[0] & 0x80) != 0;
        ubyte opcode = head[0] & 0x0f;
        bool masked = (head[1] & 0x80) != 0;
        ulong length = head[1] & 0x7f;
        if (length == 126) {
            ubyte[2] ext;
            if (!receiveExactly(socket, ext[]))
                return;
            length = (cast(ulong) ext[0] << 8) | ext[1];
        } else if (length == 127) {
            ubyte[8] ext;
            if (!receiveExactly(socket, ext[]))
                return;
            length = 0;
            foreach (b; ext)
                length = (length << 8) | b;
        }
        if (!masked || length > maxMessage || message.length + length > maxMessage)
            return; // clients must mask; refuse oversized messages
        ubyte[4] mask;
        if (!receiveExactly(socket, mask[]))
            return;
        auto payload = new ubyte[cast(size_t) length];
        if (!receiveExactly(socket, payload))
            return;
        foreach (i, ref b; payload)
            b ^= mask[i & 3];
        if (opcode == 8) {
            sendFrame(socket, null, 8);
            return;
        }
        if (opcode == 9) {
            sendFrame(socket, cast(const(char)[]) payload, 10);
            continue;
        }
        if (opcode == 10)
            continue;
        if (opcode != 0 && opcode != 1 && opcode != 2)
            return;
        message ~= cast(const(char)[]) payload;
        if (!fin)
            continue;
        auto text = message.idup;
        message = null;
        webSocketMessage(socket, text);
    }
}

/// One envelope from a client: builds the request it names and queues it for the interpreter.
private void webSocketMessage(int socket, string text) {
    JsonValue envelope;
    string problem;
    string id = "null";
    if (!parseJson(text, envelope, problem) || envelope.kind != JsonValue.Kind.object) {
        sendFrame(socket, `{"id":null,"status":400,"body":{"error":"message must be a JSON object"}}`);
        return;
    }
    if (auto given = envelope.get("id")) {
        if (given.kind == JsonValue.Kind.number)
            id = numberJson(cast(long) given.number);
        else if (given.kind == JsonValue.Kind.string_)
            id = jsonQuote(given.text);
    }
    Request request;
    request.method = envelope.stringOr("method", "GET");
    request.path = envelope.stringOr("path");
    request.body_ = envelope.stringOr("body");
    if (auto query = envelope.get("query"))
        if (query.kind == JsonValue.Kind.object)
            foreach (i, key; query.keys) {
                auto value = query.items[i];
                request.query[key] = value.kind == JsonValue.Kind.string_ ? value.text
                    : value.kind == JsonValue.Kind.number ? numberJson(cast(long) value.number) : "";
            }
    request.query["token"] = debugger.token;
    if (request.path.length == 0 || request.path[0] != '/') {
        sendFrame(socket, `{"id":` ~ id ~ `,"status":400,"body":{"error":"path must start with /"}}`);
        return;
    }
    webSocketLock.lock();
    int virtual = nextVirtual++;
    webSocketReplies[virtual] = WebSocketReply(socket, id);
    webSocketLock.unlock();
    queueRequest(virtual, request);
}

/// Accepts the upgrade: the handshake reply, then a reader thread for the connection.
private void webSocketUpgrade(int connection, string key) {
    import std.digest.sha : sha1Of;
    import std.base64 : Base64;

    auto digest = sha1Of(key ~ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    auto accept = Base64.encode(digest[]);
    string reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        ~ "Sec-WebSocket-Accept: " ~ accept.idup ~ "\r\n\r\n";
    if (!sendAll(connection, reply)) {
        close(connection);
        return;
    }
    webSocketLock.lock();
    webSocketClients ~= connection;
    webSocketLock.unlock();
    sendFrame(connection, `{"event":"hello","protocol":1}`);
    auto thread = new Thread({ webSocketReader(connection); });
    thread.isDaemon = true;
    thread.start();
}

private void respond(int socket, int status, string contentType, const(char)[] content) {
    if (socket >= virtualBase) {
        webSocketRespond(socket, status, contentType, content);
        return;
    }
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
        enum keyName = "sec-websocket-key:";
        if (line.length > keyName.length) {
            bool isKey = true;
            foreach (i, char c; keyName)
                if ((line[i] | 0x20) != c && line[i] != c) {
                    isKey = false;
                    break;
                }
            if (isKey) {
                auto value = line[keyName.length .. $];
                while (value.length && value[0] == ' ')
                    value = value[1 .. $];
                request.wsKey = value.idup;
            }
        }
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

public string errorText(LuaValue errorObject) {
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

public bool readFile(string path, out string content) {
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

public bool writeFile(string path, string content) {
    auto file = fopen((path ~ "\0").ptr, "wb");
    if (file is null)
        return false;
    bool ok = fwrite(content.ptr, 1, content.length, file) == content.length;
    return fclose(file) == 0 && ok;
}

/// Source files of the project, at most three directories deep.
public void listFiles(string directory, string prefix, int depth, ref string[] found) {
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
        } else if (isSourceName(name) || name.length > 3 && name[$ - 3 .. $] == ".md")
            found ~= relative;
    }
}

/// A file the language tools read: `.varis` (the source extension of Varis; owner decision
/// October 13, 2026) or `.lua` (existing projects keep loading).
public bool isSourceName(string name) {
    return (name.length > 6 && name[$ - 6 .. $] == ".varis") || (name.length > 4 && name[$ - 4 .. $] == ".lua");
}

public void sortStrings(string[] items) {
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
private __gshared LuaTable[] inspectedTables;

private string valuePreview(LuaValue value) {
    if (value.isTable)
        return "table (" ~ numberJson(cast(long) value.asTable.count()) ~ " entries)";
    auto text = toLuaString(value);
    return text.length > 120 ? text[0 .. 117] ~ "..." : text;
}

private string tableJson(LuaState state, string name, long reference, long start, long count) {
    auto value = name.length ? state.globals.rawget(LuaValue(name)) : (reference >= 0 && reference < inspectedTables
            .length ? LuaValue(inspectedTables[cast(size_t) reference]) : LuaValue.init);
    if (!value.isTable)
        return `{"error":"table is no longer available"}`;
    start = start < 0 ? 0 : start;
    count = count < 1 ? 100 : (count > 1000 ? 1000 : count);
    auto table = value.asTable;
    LuaValue key, nextKey, item;
    long at;
    string json = `{"total":` ~ numberJson(cast(long) table.count()) ~ `,"rows":[`;
    bool first = true;
    while (table.next(key, nextKey, item)) {
        key = nextKey;
        if (at++ < start)
            continue;
        if (at > start + count)
            break;
        long child = -1;
        if (item.isTable) {
            child = cast(long) inspectedTables.length;
            inspectedTables ~= item.asTable;
        }
        json ~= (first ? "" : ",") ~ `{"key":` ~ jsonQuote(valuePreview(key)) ~ `,"type":` ~ jsonQuote(
                item.typeName())
            ~ `,"preview":` ~ jsonQuote(valuePreview(item)) ~ `,"ref":` ~ numberJson(child) ~ `}`;
        first = false;
    }
    return json ~ `]}`;
}

private string sessionJson(LuaState state) {
    import varis.narrative.session : Session;

    auto value = state.getGlobal("__workbench").asTable.rawget(LuaValue("session"));
    auto session = value.data.tag == TagUserData ? cast(Session) value.asUserData.payload : null;
    if (session is null)
        return `{"error":"no session"}`;
    auto data = session.view();
    string json = `{"turn":` ~ numberJson(cast(long) data.turn) ~ `,"deck":` ~ jsonQuote(
            session.activeDeck()) ~ `,"periods":[`;
    string[] names;
    foreach (name; data.periods.byKey)
        names ~= name;
    sortStrings(names);
    foreach (i, name; names)
        json ~= (i ? "," : "") ~ `{"name":` ~ jsonQuote(name) ~ `,"value":` ~ jsonQuote(
                valuePreview(data.periods[name])) ~ `}`;
    json ~= `],"decks":[`;
    foreach (i, deck; data.decks)
        json ~= (i ? "," : "") ~ `{"name":` ~ jsonQuote(deck.name) ~ `,"drawn":` ~ numberJson(
                cast(long) deck.drawn.length) ~ `}`;
    json ~= `],"completed":[`;
    names = null;
    foreach (name; data.completed.byKey)
        names ~= name;
    sortStrings(names);
    foreach (i, name; names)
        json ~= (i ? "," : "") ~ `{"instance":` ~ jsonQuote(name) ~ `,"turn":` ~ numberJson(
                cast(long) data.completed[name]) ~ `}`;
    return json ~ `]}`;
}

/// Serialize engine-owned immutable reports without indexing author objects or invoking hooks.
private string reportJson(LuaValue value, size_t depth = 0) {
    import varis.narrative.codec : ImmutableRecord, ImmutableSequence;

    if (value.isNil || depth > 64)
        return "null";
    if (value.isString)
        return jsonQuote(value.asString);
    if (value.isSymbol)
        return jsonQuote(value.asSymbol.name);
    if (value.isInteger)
        return numberJson(value.asInteger);
    if (value.isBoolean)
        return value.asBool ? "true" : "false";
    if (value.isFloat)
        return toLuaString(value);
    if (value.data.tag == TagUserData) {
        auto payload = value.asUserData.payload;
        if (auto sequence = cast(ImmutableSequence) payload) {
            string json = "[";
            foreach (i, element; sequence.values)
                json ~= (i ? "," : "") ~ reportJson(element, depth + 1);
            return json ~ "]";
        }
        if (auto record = cast(ImmutableRecord) payload) {
            auto keys = record.fields.keys;
            sortStrings(keys);
            string json = "{";
            foreach (i, key; keys)
                json ~= (i ? "," : "") ~ jsonQuote(key) ~ ":" ~ reportJson(record.fields[key], depth + 1);
            return json ~ "}";
        }
    }
    return "null";
}

private void installNatives(LuaState state) {
    auto table = state.getGlobal("__workbench").asTable;
    table.rawset(LuaValue("reportJson"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                return [LuaValue(reportJson(args.length ? args[0] : LuaValue.init))];
            }, "workbench.reportJson")));
    table.rawset(LuaValue("preview"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                return [LuaValue(valuePreview(args.length ? args[0] : LuaValue.init))];
            }, "workbench.preview")));
    table.rawset(LuaValue("isSession"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                import varis.narrative.session : Session;

                return [
                    LuaValue(args.length && args[0].data.tag == TagUserData && cast(Session) args[0]
                    .asUserData.payload !is null)
                ];
            }, "workbench.isSession")));
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
                if (args.length > 4 && args[4].isTruthy()) {
                    import varis.logic.model : Term, Goal, RelationRef, Rule, RelTuple;
                    import varis.logic.world : collectRuleDependencies;
                    import varis.logic.query : QueryIterator;
                    import varis.fiber : beginReadOnlyEvaluation, endReadOnlyEvaluation;

                    Term[] terms;
                    string[] names;
                    foreach (i; 0 .. relation.arity) {
                        auto name = "column" ~ numberJson(cast(long) i);
                        names ~= name;
                        terms ~= Term.makeVariable(name, cast(int) i);
                    }
                    Relation[size_t] closure;
                    Rule[] rules;
                    collectRuleDependencies(relation, closure, rules);
                    auto reference = new RelationRef(relation.name, relation.arity, "", relation.id);
                    reference.resolvedRelation = relation;
                    auto iterator = new QueryIterator(cast(LuaState) pointer, [
                        Goal.makePositiveAtom(reference, terms)
                    ], names, closure, rules);
                    beginReadOnlyEvaluation();
                    scope (exit)
                        endReadOnlyEvaluation();
                    iterator.next();
                    facts = null;
                    foreach (record; iterator.resultRecords) {
                        LuaValue[] values;
                        foreach (name; names)
                            values ~= record.getBinding(name);
                        facts ~= RelTuple(values);
                    }
                }
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
    table.rawset(LuaValue("sceneIds"), LuaValue(new LuaNativeFunction((void* pointer, LuaValue[] args) {
                auto owner = cast(LuaState) pointer;
                string[] ids;
                foreach (definition; owner.narrativeRegistry.scenes)
                    ids ~= definition.id;
                sortStrings(ids);
                auto list = new LuaTable();
                foreach (i, id; ids)
                    list.rawset(LuaValue(cast(long) i + 1), LuaValue(id));
                return [LuaValue(list)];
            }, "workbench.sceneIds")));
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

// ---------------------------------------------------------------------------------------------
// Connections are accepted on their own thread so that Pause and Stop reach an interpreter that is
// busy running Lua. That thread only reads requests. Pause and Stop it answers itself, touching
// nothing but the flags the executor already polls (`vmInterrupt`, the line hook mask); every other
// request is queued for the interpreter thread, which serves them one at a time as before.

private struct PendingConnection {
    int socket;
    Request request;
}

private __gshared PendingConnection[] pendingConnections;
private __gshared Mutex pendingLock;
private __gshared Condition pendingReady;
// Requests the interpreter thread has taken and not finished (a stopped program keeps its request
// open while serving others, so this can exceed one). Read and written under `pendingLock`, which
// is what makes "is the interpreter busy" and "queue this request" a single decision.
private __gshared int activeRequests;
// Pause and Stop apply to the request running now, or to the next one if they arrive while it is
// still queued. `requestSerial` numbers outermost requests; `stopSerial` is the one flagged.
private __gshared long requestSerial;
private __gshared long topSerial;
private __gshared long stopSerial = -1;

/// Blocks until a request is waiting for the interpreter thread.
private void nextConnection(out int connection, out Request request) {
    pendingLock.lock();
    scope (exit)
        pendingLock.unlock();
    while (pendingConnections.length == 0)
        pendingReady.wait();
    connection = pendingConnections[0].socket;
    request = pendingConnections[0].request;
    pendingConnections = pendingConnections[1 .. $];
    if (activeRequests++ == 0)
        topSerial = ++requestSerial;
}

/// The interpreter thread is done with a request. A Pause or Stop that arrived during a request
/// which never ran Lua must not strike the next one.
private void requestFinished() {
    pendingLock.lock();
    scope (exit)
        pendingLock.unlock();
    if (--activeRequests == 0 && topSerial >= stopSerial) {
        debugger.pauseRequested = false;
        vmInterrupt = false;
    }
}

/// Pause and Stop are answered here, on the accept thread, while the interpreter is busy and not
/// stopped at a breakpoint. They only set flags the executor polls. Any other request, and these two
/// when nothing is running or the program is stopped, go to the interpreter thread.
private bool answeredAsynchronously(ref Request request) {
    import core.atomic : atomicFence;

    auto given = "token" in request.query;
    if (given is null || *given != debugger.token)
        return false;
    bool pause = request.path == "/api/pause";
    if (!pause && request.path != "/api/interrupt")
        return false;
    if ((activeRequests == 0 && pendingConnections.length == 0) || debugger.stopped || debugger.thread is null)
        return false;
    stopSerial = activeRequests > 0 ? topSerial : requestSerial + 1;
    if (pause) {
        debugger.pauseRequested = true;
        debugger.thread.hookFunction = debugger.hook;
        debugger.thread.hookMask = 4;
        atomicFence();
        vmSlowMode = true;
        vmAttention = true;
    } else {
        vmInterrupt = true;
        atomicFence();
        vmAttention = true;
    }
    return true;
}

/// Hands a parsed request to the interpreter thread, or answers a Pause/Stop right here.
private void queueRequest(int connection, Request request) {
    bool answered;
    pendingLock.lock();
    answered = answeredAsynchronously(request);
    if (!answered)
        pendingConnections ~= PendingConnection(connection, request);
    pendingLock.unlock();
    if (answered) {
        respond(connection, 200, "application/json", `{"ok":true,"running":true}`);
        closeConnection(connection);
    } else
        pendingReady.notify();
}

private void acceptLoop() {
    while (true) {
        int connection = accept(debugger.listener, null, null);
        if (connection < 0)
            continue;
        Request request;
        if (!readRequest(connection, request)) {
            close(connection);
            continue;
        }
        if (request.wsKey.length && request.path == "/ws") {
            auto given = "token" in request.query;
            if (given is null || *given != debugger.token) {
                respond(connection, 403, "text/plain", "missing or wrong token\n");
                close(connection);
            } else
                webSocketUpgrade(connection, request.wsKey);
            continue;
        }
        queueRequest(connection, request);
    }
}

private void startAcceptThread() {
    webSocketLock = new Mutex;
    pendingLock = new Mutex;
    pendingReady = new Condition(pendingLock);
    auto thread = new Thread(&acceptLoop);
    thread.isDaemon = true;
    thread.start();
}

// Source-level debugging (WORKBENCH_PLAN.md section 5.2)
//
// Breakpoints and stepping use the executor's per-line slow path (the mechanism behind line hooks):
// while any breakpoint is set or a step is pending, a native line hook runs before each source line
// and decides whether to stop. Stopping answers the request that started the evaluation with
// "stopped", then serves further requests from inside the hook, with every Lua frame still alive,
// until one of them resumes execution. That request receives the evaluation's eventual result.
// Without breakpoints the hook is not installed and code runs on the fast path.

private struct Breakpoint {
    string file;
    long line;
}

private enum StepMode {
    run,
    into,
    over,
    out_
}

private struct Debugger {
    Breakpoint[] breakpoints;
    StepMode step;
    size_t stepDepth;
    bool stopped;
    string stoppedFile;
    long stoppedLine;
    size_t stoppedDepth;
    int resultSocket = -1; // the connection waiting for the running evaluation's outcome
    bool pauseRequested; // set from the accept thread; consumed by the line hook
    LuaThread thread; // the interpreter thread whose hook the accept thread may install
    int listener = -1;
    string token;
    LuaNativeFunction hook;
    bool breakOnError; // stop at an uncaught error, before the stack unwinds
    string stoppedReason; // "" for a breakpoint or step, "error" for an error stop
    string stoppedMessage;
}

private __gshared Debugger debugger;

/// What became of a request's connection.
private enum Disposition {
    done, // answered; the caller closes it
    deferred, // kept open: it will receive the result of the evaluation it resumed
    closed // already answered and closed elsewhere
}

/// "@./content/lamp.lua" and "content/lamp.lua" name the same file.
private string normalizeSource(string source) {
    if (source.length && (source[0] == '@' || source[0] == '='))
        source = source[1 .. $];
    while (source.length > 1 && source[0] == '.' && source[1] == '/')
        source = source[2 .. $];
    return source;
}

/// Index in the call stack of the innermost Lua function (the one the hook fired in), or -1.
private ptrdiff_t innermostLuaFrame(LuaState state) {
    auto frames = state.callStack();
    for (ptrdiff_t i = cast(ptrdiff_t) frames.length - 1; i >= 0; --i)
        if (cast(LuaClosure) frames[i].fn !is null && frames[i].registers !is null)
            return i;
    return -1;
}

private void syncHook(LuaState state) {
    import varis.state : vmAttention, vmSlowMode;

    auto thread = state.mainThread;
    debugger.thread = thread; // a reload replaces the state, and with it the thread
    state.errorStopHook = debugger.breakOnError ? (LuaState s, LuaException e) { errorStop(s, e); } : null;
    bool wanted = debugger.breakpoints.length != 0 || debugger.step != StepMode.run
        || debugger.pauseRequested;
    if (wanted) {
        thread.hookFunction = debugger.hook;
        thread.hookMask = 4; // line events
        vmSlowMode = true;
        vmAttention = true;
    } else if (thread.hookFunction is debugger.hook) {
        thread.hookFunction = null;
        thread.hookMask = 0;
    }
}

private string stoppedJson() {
    char[32] number;
    auto n = snprintf(number.ptr, number.length, "%lld", debugger.stoppedLine);
    string json = `{"stopped":true,"file":` ~ jsonQuote(debugger.stoppedFile) ~ `,"line":` ~ number[0 .. n].idup;
    if (debugger.stoppedReason.length)
        json ~= `,"reason":` ~ jsonQuote(debugger.stoppedReason) ~ `,"message":` ~ jsonQuote(debugger.stoppedMessage);
    return json ~ `}`;
}

/// Reports a stop to the connection waiting for the evaluation, then serves requests with every
/// Lua frame still alive until one of them resumes execution.
private void stopAndServe(LuaState state, string file, long line, size_t depth, string reason, string message) {
    debugger.stopped = true;
    debugger.step = StepMode.run;
    debugger.stoppedFile = file;
    debugger.stoppedLine = line;
    debugger.stoppedDepth = depth;
    debugger.stoppedReason = reason;
    debugger.stoppedMessage = message;
    // The waiting connection learns that execution stopped; whoever resumes gets the result.
    respond(debugger.resultSocket, 200, "application/json", stoppedJson());
    closeConnection(debugger.resultSocket);
    webSocketBroadcast("stopped", stoppedJson());
    debugger.resultSocket = -1;
    while (debugger.stopped) {
        int connection;
        Request request;
        nextConnection(connection, request);
        auto disposition = handle(state, connection, request, debugger.token);
        if (disposition == Disposition.done)
            closeConnection(connection);
        requestFinished();
    }
    debugger.stoppedReason = "";
    debugger.stoppedMessage = "";
    syncHook(state);
}

/// An uncaught error in author code (`state.errorStopHook`): stop where it was raised. Errors a
/// `pcall` or a coroutine boundary will catch, and errors in the workbench's own prelude, do not stop.
private void errorStop(LuaState state, LuaException error) {
    import varis.fiber : currentLuaFiber;

    if (!debugger.breakOnError || debugger.stopped || debugger.resultSocket < 0)
        return;
    auto thread = state.currentThread();
    if (thread is null || thread.errorBoundaries.length != 0 || currentLuaFiber() !is null)
        return;
    auto top = innermostLuaFrame(state);
    if (top < 0)
        return;
    auto frames = state.callStack();
    auto file = normalizeSource((cast(LuaClosure) frames[top].fn).proto.sourceName);
    if (file == "workbench")
        return;
    stopAndServe(state, file, frames[top].line(), cast(size_t) top, "error", errorText(error.errorObject));
}

/// The line hook: decides whether to stop here and, if so, serves requests until resumed.
private LuaValue[] debuggerHook(LuaState state, long line) {
    auto top = innermostLuaFrame(state);
    if (top < 0)
        return null;
    auto frames = state.callStack();
    auto file = normalizeSource((cast(LuaClosure) frames[top].fn).proto.sourceName);
    size_t depth = cast(size_t) top;
    bool stop;
    final switch (debugger.step) {
    case StepMode.run:
        break;
    case StepMode.into:
        stop = true;
        break;
    case StepMode.over:
        stop = depth <= debugger.stepDepth;
        break;
    case StepMode.out_:
        stop = depth < debugger.stepDepth;
        break;
    }
    // A pause waits for author code: the workbench's own prelude is not something to stop in.
    if (debugger.pauseRequested && file != "workbench") {
        debugger.pauseRequested = false;
        stop = true;
    }
    if (!stop)
        foreach (ref breakpoint; debugger.breakpoints)
            if (breakpoint.line == line && breakpoint.file == file) {
                stop = true;
                break;
            }
    if (!stop || debugger.resultSocket < 0)
        return null;
    stopAndServe(state, file, line, depth, "", "");
    return null;
}

private string stackJson(LuaState state) {
    string json = `{"stopped":` ~ (debugger.stopped ? "true" : "false") ~ `,"frames":[`;
    auto frames = state.callStack();
    bool first = true;
    for (ptrdiff_t i = cast(ptrdiff_t) frames.length - 1; i >= 0; --i) {
        auto closure = cast(LuaClosure) frames[i].fn;
        if (closure is null || frames[i].registers is null)
            continue;
        char[32] number;
        auto n = snprintf(number.ptr, number.length, "%d", frames[i].line());
        char[32] index;
        auto m = snprintf(index.ptr, index.length, "%lld", cast(long) i);
        json ~= (first ? "" : ",") ~ `{"frame":` ~ index[0 .. m].idup ~ `,"file":` ~ jsonQuote(
                normalizeSource(closure.proto.sourceName)) ~ `,"line":` ~ number[0 .. n].idup ~ `,"name":` ~ jsonQuote(
                frames[i].name.length ? frames[i].name : (closure.proto.functionName.length ? closure
                .proto.functionName : "?")) ~ `}`;
        first = false;
    }
    return json ~ "]}";
}

private string localsJson(LuaState state, long frameIndex) {
    auto frames = state.callStack();
    if (frameIndex < 0)
        frameIndex = innermostLuaFrame(state);
    if (frameIndex < 0 || frameIndex >= cast(long) frames.length)
        return `{"locals":[]}`;
    string json = `{"locals":[`;
    bool first = true;
    for (long i = 1; i < 250; ++i) {
        LuaValue value;
        auto name = frames[cast(size_t) frameIndex].getLocal(i, value);
        if (name is null)
            break;
        if (name.length && name[0] == '(')
            continue; // temporaries
        auto text = toLuaString(value);
        if (text.length > 120)
            text = text[0 .. 117] ~ "...";
        json ~= (first ? "" : ",") ~ `{"name":` ~ jsonQuote(name) ~ `,"type":` ~ jsonQuote(
                value.typeName()) ~ `,"value":` ~ jsonQuote(
                text) ~ `}`;
        first = false;
    }
    return json ~ "]}";
}

private string numberJson(long value) {
    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}

/// Go to definition: the declarations of the project named `name`, read from the project index
/// (services/index.d), which parses the source files. It finds declarations that have not been
/// loaded, and files that do not parse are skipped.
private string definitionsJson(string name) {
    import varis.services.index : indexFile, FileIndex;

    foreach (char c; name)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
            return `{"definitions":[]}`;
    if (name.length == 0)
        return `{"definitions":[]}`;
    string[] found;
    listFiles(".", "", 0, found);
    sortStrings(found);
    string json = `{"definitions":[`;
    bool first = true;
    foreach (file; found) {
        if (!isSourceName(file))
            continue;
        string content;
        if (!readFile(file, content))
            continue;
        auto indexed = indexFile(file, content);
        foreach (ref d; indexed.declarations) {
            if (d.name != name || d.range.line == 0)
                continue;
            // The declaring line, as the old textual scan reported it.
            string text;
            long number = 1;
            size_t from;
            foreach (i, char c; content) {
                if (number == d.range.line && c == '\n') {
                    text = content[from .. i];
                    break;
                }
                if (c == '\n') {
                    ++number;
                    from = i + 1;
                }
            }
            if (text.length == 0 && number == d.range.line)
                text = content[from .. $];
            size_t at;
            while (at < text.length && (text[at] == ' ' || text[at] == '\t'))
                ++at;
            text = text[at .. $];
            string kind = d.kind == "local-function" ? "local function" : d.kind;
            char[96] numbers;
            auto n = snprintf(numbers.ptr, numbers.length, `"line":%d,"column":%d,"endLine":%d,"endColumn":%d`,
                    d.range.line, d.range.column, d.range.endLine, d.range.endColumn);
            json ~= (first ? "" : ",") ~ `{"file":` ~ jsonQuote(
                    file) ~ `,` ~ numbers[0 .. n].idup ~ `,"kind":` ~ jsonQuote(
                    kind) ~ `,"text":` ~ jsonQuote(text.length > 100 ? text[0 .. 100] : text) ~ `}`;
            first = false;
        }
    }
    return json ~ "]}";
}

/// Editor services share the frontend index used by the language server. Drafts are
/// request-local: inspecting unsaved text never writes a file or executes project code.
private string editorJson(LuaState state, string operation, string body) {
    import varis.services.json : JsonValue, parseJson;
    import varis.services.lang : Workspace;
    import varis.services.index : Range;
    import varis.services.diagnostic : Diagnostic, diagnosticJson, sortDiagnostics;

    JsonValue input;
    string error;
    if (!parseJson(body, input, error) || input.kind != JsonValue.Kind.object)
        return `{"ok":false,"error":"expected an editor request object"}`;
    auto path = input.stringOr("path");
    if (!safePath(path))
        return `{"ok":false,"error":"bad path"}`;
    auto workspace = new Workspace();
    workspace.load();
    auto drafts = input.get("buffers");
    if (drafts !is null && drafts.kind == JsonValue.Kind.object)
        foreach (i, file; drafts.keys) {
            if (!safePath(file) || drafts.items[i].kind != JsonValue.Kind.string_)
                return `{"ok":false,"error":"invalid draft"}`;
            if (isSourceName(file))
                workspace.setContent(file, drafts.items[i].text);
            else
                workspace.contents[file] = drafts.items[i].text;
        }
    auto text = input.get("text");
    if (text !is null && text.kind == JsonValue.Kind.string_) {
        if (isSourceName(path))
            workspace.setContent(path, text.text);
        else
            workspace.contents[path] = text.text;
    }
    int line = cast(int) input.integerOr("line", 1);
    int column = cast(int) input.integerOr("column", 1);
    string rangeJson(Range r) {
        return `{"line":` ~ numberJson(r.line) ~ `,"column":` ~ numberJson(
                r.column)
            ~ `,"endLine":` ~ numberJson(r.endLine) ~ `,"endColumn":` ~ numberJson(r.endColumn) ~ `}`;
    }

    switch (operation) {
    case "complete": {
            string json = `{"items":[`;
            foreach (i, item; workspace.complete(path, line, column))
                json ~= (i ? "," : "") ~ `{"label":` ~ jsonQuote(item.label) ~ `,"kind":` ~ jsonQuote(
                        item.kind)
                    ~ `,"detail":` ~ jsonQuote(item.detail) ~ `}`;
            return json ~ `]}`;
        }
    case "definition": {
            string json = `{"definitions":[`;
            foreach (i, location; workspace.definition(path, line, column))
                json ~= (i ? "," : "") ~ `{"file":` ~ jsonQuote(
                        location.file) ~ `,"range":` ~ rangeJson(location.range) ~ `}`;
            return json ~ `]}`;
        }
    case "hover":
        return `{"text":` ~ jsonQuote(workspace.hover(path, line, column)) ~ `}`;
    case "rename": {
            auto result = workspace.rename(path, line, column, input.stringOr("newName"));
            string json = `{"ok":` ~ (result.ok ? "true" : "false") ~ `,"error":` ~ jsonQuote(
                    result.error) ~ `,"edits":[`;
            foreach (i, edit; result.edits)
                json ~= (i ? "," : "") ~ `{"file":` ~ jsonQuote(edit.file) ~ `,"range":` ~ rangeJson(
                        edit.range)
                    ~ `,"newText":` ~ jsonQuote(edit.newText) ~ `}`;
            json ~= `],"notes":[`;
            foreach (i, note; result.notes)
                json ~= (i ? "," : "") ~ jsonQuote(note);
            json ~= `],"originals":{`;
            string[] originals;
            foreach (edit; result.edits) {
                bool known;
                foreach (file; originals)
                    known = known || file == edit.file;
                if (known)
                    continue;
                string original;
                if (auto draft = edit.file in workspace.contents)
                    original = *draft;
                else
                    readFile(edit.file, original);
                json ~= (originals.length ? "," : "") ~ jsonQuote(edit.file) ~ ":" ~ jsonQuote(original);
                originals ~= edit.file;
            }
            return json ~ `}}`;
        }
    case "check": {
            auto all = workspace.diagnostics();
            foreach (file; workspace.order) {
                auto indexed = workspace.indexes[file];
                if (!indexed.parsed)
                    continue;
                try {
                    state.loadString(workspace.contents[file], "@" ~ file);
                } catch (LuaException failure) {
                    all[file] ~= Diagnostic("compile", "error", file, 0, 0, 0, 0, "", errorText(failure.errorObject));
                    sortDiagnostics(all[file]);
                }
            }
            string json = `{"diagnostics":[`;
            bool first = true;
            foreach (file; workspace.order)
                if (auto list = file in all)
                    foreach (ref diagnostic; *list) {
                        json ~= (first ? "" : ",") ~ diagnosticJson(diagnostic);
                        first = false;
                    }
            return json ~ `]}`;
        }
    default:
        return `{"ok":false,"error":"unknown editor operation"}`;
    }
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

private bool signedNumber(string text, out long result) {
    if (text.length == 0)
        return false;
    bool negative = text[0] == '-';
    if (negative)
        text = text[1 .. $];
    if (text.length == 0)
        return false;
    ulong value;
    ulong limit = cast(ulong) long.max + (negative ? 1UL : 0UL);
    foreach (c; text) {
        if (c < '0' || c > '9' || value > (limit - (c - '0')) / 10)
            return false;
        value = value * 10 + (c - '0');
    }
    result = cast(long)(negative ? 0UL - value : value);
    return true;
}

private long numberOf(string text, long fallback) {
    if (text.length == 0)
        return fallback;
    long value;
    foreach (char c; text) {
        if (c < '0' || c > '9')
            return fallback;
        if (value > (long.max - (c - '0')) / 10)
            return fallback;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// Runs an evaluation whose outcome goes to `socket`, unless a breakpoint stops it first: then the
/// stop is reported on `socket` and the outcome goes to the connection that resumed execution.
private Disposition finishEvaluation(LuaState state, int socket, scope Evaluation delegate() run) {
    if (debugger.resultSocket >= 0 || debugger.stopped) {
        // Evaluating while stopped at a breakpoint: run it plainly, with the line hook quiet
        // (the hook machinery does not re-enter itself).
        respond(socket, 200, "application/json", evaluationJson(run()));
        return Disposition.done;
    }
    debugger.resultSocket = socket;
    syncHook(state);
    auto result = run();
    int target = debugger.resultSocket;
    debugger.resultSocket = -1;
    debugger.step = StepMode.run;
    syncHook(state);
    if (target < 0)
        return Disposition.closed;
    respond(target, 200, "application/json", evaluationJson(result));
    if (target == socket)
        return Disposition.done;
    closeConnection(target);
    return Disposition.closed;
}

/// Story operations use the same suspended-request lifetime as command evaluations, so
/// effect breakpoints retain the open transaction until the user explicitly resumes.
private Disposition finishStory(LuaState state, int socket, string name, LuaValue[] arguments) {
    if (debugger.stopped || debugger.resultSocket >= 0) {
        respond(socket, 200, "application/json", `{"error":"resume the stopped program before changing the story"}`);
        return Disposition.done;
    }
    debugger.resultSocket = socket;
    syncHook(state);
    bool ok;
    string result;
    auto output = captureOutput({ result = callView(state, name, arguments, ok); });
    int target = debugger.resultSocket;
    debugger.resultSocket = -1;
    debugger.step = StepMode.run;
    syncHook(state);
    if (target < 0)
        return Disposition.closed;
    // Preserve the story response shape and any output printed by effects.
    if (result.length && result[$ - 1] == '}')
        result = result[0 .. $ - 1] ~ `,"output":` ~ jsonQuote(output) ~ `}`;
    respond(target, 200, "application/json", result);
    if (target == socket)
        return Disposition.done;
    closeConnection(target);
    return Disposition.closed;
}

/// Build and replay in a fresh state; publish it only when reconstruction succeeds.
private string reloadProject(ref LuaState state, bool replay, long turn, long seed, long commandLimit) {
    import varis.lib : openLibs;
    import varis.services.manifest : loadManifest;
    import varis.services.tier : installTierEnforcement;

    auto manifest = loadManifest(".");
    if (!manifest.present || manifest.entry.length == 0 || manifest.session.length == 0)
        return `{"error":"project.lua must name an entry and a session factory"}`;
    auto previous = state.getGlobal("__workbench").asTable;
    auto records = replay ? previous.rawget(LuaValue("history")) : luaNil();
    if (replay && previous.rawget(LuaValue("seed")).isNil)
        return `{"error":"start a manifest-backed playtest before reloading or rewinding"}`;
    if (replay)
        seed = previous.rawget(LuaValue("seed")).asInteger;
    auto fresh = new LuaState();
    openLibs(fresh);
    installTierEnforcement(fresh, manifest, ".");
    auto setup = evaluate(fresh, prelude, "=workbench");
    if (!setup.ok)
        return `{"error":` ~ jsonQuote(setup.error) ~ `}`;
    installNatives(fresh);
    installStoryNatives(fresh);
    evaluate(fresh, `package.path = "./?.varis;./?/init.varis;./?.lua;./?/init.lua;" .. package.path`, "=workbench");
    bool ok;
    string result;
    auto output = captureOutput({
        result = callView(fresh, "start", [
            LuaValue(manifest.entry), LuaValue(manifest.session),
            LuaValue(manifest.afterChoose), LuaValue(seed), records, LuaValue(turn),
            LuaValue(manifest.language), LuaValue(commandLimit)
        ], ok);
    });
    if (ok && replay) {
        auto language = previous.rawget(LuaValue("language"));
        if (language.isString && language.asString.length) {
            import varis.services.l10n : localeMessages;

            string[string] messages;
            string problem;
            if (!localeMessages(language.asString, messages, problem))
                return `{"error":` ~ jsonQuote(problem) ~ `}`;
            auto pack = new LuaTable();
            foreach (key, text; messages)
                pack.rawset(LuaValue(key), LuaValue(text));
            result = callView(fresh, "setLanguage", [language, LuaValue(pack)], ok);
        }
    }
    if (ok) {
        if (replay) {
            import varis.narrative.session : unwrapSession;

            auto original = unwrapSession(previous.rawget(LuaValue("session"))).world;
            auto restored = unwrapSession(fresh.getGlobal("__workbench").asTable.rawget(LuaValue("session"))).world;
            restored.persistentIdentity = original.persistentIdentity.length ? original.persistentIdentity
                : numberJson(cast(long) original.id);
        }
        state = fresh;
        inspectedTables = null;
        syncHook(state);
    }
    if (result.length && result[$ - 1] == '}')
        result = result[0 .. $ - 1] ~ `,"output":` ~ jsonQuote(output) ~ `}`;
    return result;
}

/// Validate numeric scene inputs independently of the catalog reader's permissive number token.
private bool sceneNumberToken(ref string text) @nogc nothrow {
    bool space(char c) {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n';
    }

    bool digit(char c) {
        return c >= '0' && c <= '9';
    }

    while (text.length && space(text[0]))
        text = text[1 .. $];
    while (text.length && space(text[$ - 1]))
        text = text[0 .. $ - 1];
    size_t at;
    if (at < text.length && text[at] == '-')
        ++at;
    if (at == text.length || !digit(text[at]))
        return false;
    if (text[at] == '0')
        ++at;
    else
        while (at < text.length && digit(text[at]))
            ++at;
    if (at < text.length && text[at] == '.') {
        ++at;
        auto start = at;
        while (at < text.length && digit(text[at]))
            ++at;
        if (at == start)
            return false;
    }
    if (at < text.length && (text[at] == 'e' || text[at] == 'E')) {
        ++at;
        if (at < text.length && (text[at] == '+' || text[at] == '-'))
            ++at;
        auto start = at;
        while (at < text.length && digit(text[at]))
            ++at;
        if (at == start)
            return false;
    }
    return at == text.length;
}

private Disposition handle(ref LuaState state, int socket, ref Request request, string token) {
    auto given = "token" in request.query;
    if (given is null || *given != token) {
        respond(socket, 403, "text/plain", "missing or wrong token; use the address printed by varis serve\n");
        return Disposition.done;
    }
    string parameter(string name) {
        auto value = name in request.query;
        return value is null ? "" : *value;
    }

    bool ok;
    switch (request.path) {
    case "/":
        respond(socket, 200, "text/html; charset=utf-8", workbenchPage);
        return Disposition.done;
    case "/api/editor/complete", "/api/editor/definition", "/api/editor/hover", "/api/editor/rename", "/api/editor/check":
        respond(socket, 200, "application/json", editorJson(state, request.path[12 .. $], request.body_));
        return Disposition.done;
    case "/api/eval":
        return finishEvaluation(state, socket, () => evaluate(state, request.body_, "=command"));
    case "/api/breakonerror":
        if (request.method == "POST") {
            debugger.breakOnError = request.body_.length && request.body_[0] == '1';
            syncHook(state);
        }
        respond(socket, 200, "application/json", `{"breakOnError":` ~ (debugger.breakOnError ? "true" : "false") ~ `}`);
        return Disposition.done;
    case "/api/breakpoints": {
            // Body: one "file:line" per line; replaces the whole set.
            if (request.method == "POST") {
                debugger.breakpoints = null;
                auto text = request.body_;
                while (text.length) {
                    auto end = indexOf(text, "\n");
                    auto entry = end < 0 ? text : text[0 .. end];
                    text = end < 0 ? null : text[end + 1 .. $];
                    ptrdiff_t colon = -1;
                    foreach (i, char c; entry)
                        if (c == ':')
                            colon = i;
                    if (colon > 0) {
                        auto line = numberOf(entry[colon + 1 .. $], 0);
                        if (line > 0)
                            debugger.breakpoints ~= Breakpoint(normalizeSource(entry[0 .. colon].idup), line);
                    }
                }
                syncHook(state);
            }
            string json = `{"breakpoints":[`;
            foreach (i, breakpoint; debugger.breakpoints) {
                char[32] number;
                auto n = snprintf(number.ptr, number.length, "%lld", breakpoint.line);
                json ~= (i ? "," : "") ~ `{"file":` ~ jsonQuote(breakpoint.file) ~ `,"line":` ~ number[0 .. n].idup ~ `}`;
            }
            respond(socket, 200, "application/json", json ~ "]}");
            return Disposition.done;
        }
    case "/api/inspect": {
            import varis.workbench.inspect : inspectExpression;

            LuaValue value;
            string error;
            auto frame = parameter("frame").length ? numberOf(parameter("frame"), -1) : innermostLuaFrame(state);
            bool inspected = debugger.stopped && inspectExpression(state, frame, request.body_, value, error);
            if (!debugger.stopped)
                error = "not stopped";
            Evaluation result;
            result.ok = inspected;
            result.error = error;
            // toLuaString does not invoke __tostring; inspection must never call author code.
            if (inspected)
                result.output = toLuaString(value) ~ "\n";
            respond(socket, 200, "application/json", evaluationJson(result));
            return Disposition.done;
        }
    case "/api/stack":
        respond(socket, 200, "application/json", stackJson(state));
        return Disposition.done;
    case "/api/locals":
        respond(socket, 200, "application/json", localsJson(state, parameter("frame").length ? numberOf(
                parameter("frame"), -1) : -1));
        return Disposition.done;
    case "/api/continue", "/api/step": {
            if (!debugger.stopped) {
                respond(socket, 200, "application/json", `{"stopped":false,"error":"not stopped"}`);
                return Disposition.done;
            }
            auto mode = request.path == "/api/continue" ? "" : parameter("mode");
            debugger.step = mode == "into" ? StepMode.into : mode == "over" ? StepMode.over
                : mode == "out"
                ? StepMode.out_ : StepMode.run;
            debugger.stepDepth = debugger.stoppedDepth;
            debugger.pauseRequested = false;
            debugger.stopped = false;
            debugger.resultSocket = socket; // answered when execution stops again or finishes
            return Disposition.deferred;
        }
    case "/api/pause", "/api/interrupt":
        // Reaching this thread means nothing was running to pause (a running program is answered
        // by the accept thread), or the program is stopped at a breakpoint.
        if (request.path == "/api/interrupt" && debugger.stopped) {
            vmInterrupt = true;
            vmAttention = true;
            debugger.step = StepMode.run;
            debugger.stopped = false;
            debugger.resultSocket = socket; // answered with the interrupted evaluation's error
            return Disposition.deferred;
        }
        respond(socket, 200, "application/json", debugger.stopped ? `{"ok":true,"stopped":true}`
                : `{"ok":false,"error":"nothing is running"}`);
        return Disposition.done;
    case "/api/run": {
            auto path = parameter("path");
            string content;
            if (!safePath(path) || !readFile(path, content)) {
                respond(socket, 404, "application/json", `{"ok":false,"error":"cannot read file"}`);
                return Disposition.done;
            }
            return finishEvaluation(state, socket, () {
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
                return result;
            });
        }
    case "/api/check": {
            // The language services over the project (services/lang.d): every syntax error of
            // the file, and the project-wide checks, with the editor's unsaved text in place of
            // the file's. Compile-time errors the parser does not find come from the compiler.
            import varis.services.lang : Workspace;
            import varis.services.diagnostic : diagnosticJson, Diagnostic;

            auto path = parameter("path");
            string content = request.body_;
            if (request.method != "POST" && (!safePath(path) || !readFile(path, content))) {
                respond(socket, 404, "application/json", `{"problems":[]}`);
                return Disposition.done;
            }
            auto workspace = new Workspace();
            workspace.load();
            workspace.setContent(path, content);
            auto all = workspace.diagnostics();
            Diagnostic[] mine;
            if (auto list = path in all)
                mine = *list;
            bool hasSyntax;
            foreach (ref d; mine)
                if (d.code == "syntax")
                    hasSyntax = true;
            if (!hasSyntax) {
                try {
                    state.loadString(content, "@" ~ path);
                } catch (LuaException failure) {
                    mine ~= Diagnostic("compile", "error", path, 0, 0, 0, 0, "", errorText(failure.errorObject));
                }
            }
            string problems = "[", objects = "[";
            foreach (i, ref d; mine) {
                string text;
                if (d.line > 0)
                    text = numberJson(d.line) ~ (d.column > 0 ? ":" ~ numberJson(d.column) : "") ~ " ";
                text ~= d.severity ~ ": " ~ d.message;
                if (d.suggestion.length)
                    text ~= " (did you mean " ~ d.suggestion ~ "?)";
                text ~= " [" ~ d.code ~ "]";
                problems ~= (i ? "," : "") ~ jsonQuote(text);
                objects ~= (i ? "," : "") ~ diagnosticJson(d);
            }
            respond(socket, 200, "application/json", `{"problems":` ~ problems ~ `],"diagnostics":` ~ objects ~ `]}`);
            return Disposition.done;
        }
    case "/api/start", "/api/reload", "/api/rewind": {
            if (debugger.stopped) {
                respond(socket, 200, "application/json", `{"error":"resume the stopped program before reloading"}`);
                return Disposition.done;
            }
            auto turn = parameter("turn").length ? numberOf(parameter("turn"), -1) : long.max;
            if (turn < 0) {
                respond(socket, 200, "application/json", `{"error":"turn must be nonnegative"}`);
                return Disposition.done;
            }
            long seed = 1;
            if (parameter("seed").length && !signedNumber(parameter("seed"), seed)) {
                respond(socket, 200, "application/json", `{"error":"seed must be an integer"}`);
                return Disposition.done;
            }
            long commandLimit = long.max;
            if (parameter("command").length && (!signedNumber(parameter("command"), commandLimit) || commandLimit < 0)) {
                respond(socket, 200, "application/json", `{"error":"command must be a nonnegative integer"}`);
                return Disposition.done;
            }
            respond(socket, 200, "application/json", reloadProject(state, request.path != "/api/start", turn, seed, commandLimit));
            return Disposition.done;
        }
    case "/api/history":
        respond(socket, 200, "application/json", callView(state, "historyView", [], ok));
        return Disposition.done;
    case "/api/project": {
            import varis.services.manifest : loadManifest, manifestJson;

            auto manifest = loadManifest(".");
            respond(socket, 200, "application/json", manifestJson(manifest));
            return Disposition.done;
        }
    case "/api/workspace":
        respond(socket, 200, "application/json", callView(state, "workspace", [], ok));
        return Disposition.done;
    case "/api/table":
        respond(socket, 200, "application/json", tableJson(state, parameter("name"), numberOf(parameter("ref"), -1),
                numberOf(parameter("start"), 0), numberOf(parameter("count"), 100)));
        return Disposition.done;
    case "/api/session":
        respond(socket, 200, "application/json", sessionJson(state));
        return Disposition.done;
    case "/api/relations":
        respond(socket, 200, "application/json", callView(state, "relationList", [
            LuaValue(parameter("world"))
        ], ok));
        return Disposition.done;
    case "/api/facts":
        respond(socket, 200, "application/json", callView(state, "factPage", [
            LuaValue(parameter("world")), LuaValue(parameter("name")),
            LuaValue(numberOf(parameter("start"), 0)),
            LuaValue(numberOf(parameter("count"), 100)), LuaValue(parameter("derived") == "true")
        ], ok));
        return Disposition.done;
    case "/api/language": {
            // Switch the story panel's language: the catalog's messages are registered as a
            // pack and the current presentation is rendered again, not presented again.
            import varis.services.l10n : localeMessages;

            auto lang = parameter("lang");
            LuaValue[] arguments;
            if (lang.length) {
                string[string] messages;
                string error;
                if (!localeMessages(lang, messages, error)) {
                    respond(socket, 200, "application/json", `{"error":` ~ jsonQuote(error) ~ `}`);
                    return Disposition.done;
                }
                auto pack = new LuaTable();
                foreach (key, text; messages)
                    pack.rawset(LuaValue(key), LuaValue(text));
                arguments = [LuaValue(lang), LuaValue(pack)];
            } else
                arguments = [luaNil()];
            respond(socket, 200, "application/json", callView(state, "setLanguage", arguments, ok));
            return Disposition.done;
        }
    case "/api/messages":
        respond(socket, 200, "application/json", callView(state, "messages", [], ok));
        return Disposition.done;
    case "/api/branches": {
            // Every branch of the plurals and selects of a text, rendered with sample values.
            import varis.services.l10n : branchPreviewJson;

            respond(socket, 200, "application/json", branchPreviewJson(parameter("lang"), request.body_));
            return Disposition.done;
        }
    case "/api/catalog": {
            import varis.services.l10n : catalogEntriesJson;

            respond(socket, 200, "application/json", catalogEntriesJson(parameter("lang")));
            return Disposition.done;
        }
    case "/api/translate": {
            import varis.services.l10n : saveTranslation;

            auto problem = saveTranslation(parameter("lang"), parameter("key"), request.body_);
            respond(socket, 200, "application/json", problem.length ? `{"ok":false,"error":` ~ jsonQuote(
                    problem) ~ `}` : `{"ok":true}`);
            return Disposition.done;
        }
    case "/api/present":
        return finishStory(state, socket, "present", []);
    case "/api/play":
        return finishStory(state, socket, "play", [LuaValue(parameter("id"))]);
    case "/api/advance": {
            import varis.services.json : JsonValue, parseJson;

            LuaValue input;
            if (request.body_.length) {
                JsonValue parsed;
                string error;
                if (!parseJson(request.body_, parsed, error)) {
                    respond(socket, 200, "application/json", `{"error":"scene input must be JSON"}`);
                    return Disposition.done;
                }
                bool valid = true;
                final switch (parsed.kind) {
                case JsonValue.Kind.null_:
                    break;
                case JsonValue.Kind.bool_:
                    input = LuaValue(parsed.boolean);
                    break;
                case JsonValue.Kind.string_:
                    input = LuaValue(parsed.text);
                    break;
                case JsonValue.Kind.number: {
                        long integer;
                        auto numberText = request.body_;
                        if (!sceneNumberToken(numberText) || (!signedNumber(numberText, integer)
                                && !(parsed.number - parsed.number == 0)))
                            valid = false;
                        else if (signedNumber(numberText, integer))
                            input = LuaValue(integer);
                        else
                            input = LuaValue(parsed.number);
                        break;
                    }
                case JsonValue.Kind.object:
                    if (parsed.keys.length == 1 && parsed.keys[0] == "symbol" && parsed.items[0].kind == JsonValue
                            .Kind.string_)
                        input = state.getSymbol(parsed.items[0].text);
                    else
                        valid = false;
                    break;
                case JsonValue.Kind.array:
                    valid = false;
                    break;
                }
                if (!valid) {
                    respond(socket, 200, "application/json", `{"error":"scene input must be a scalar or a symbol object"}`);
                    return Disposition.done;
                }
            }
            return finishStory(state, socket, "advance", [
                input, LuaValue(numberOf(parameter("choice"), 0))
            ]);
        }
    case "/api/choose":
        return finishStory(state, socket, "choose", [
            LuaValue(numberOf(parameter("s"), 0)), LuaValue(numberOf(parameter("c"), 0))
        ]);
    case "/api/changes":
        respond(socket, 200, "application/json", callView(state, "turnChanges", [], ok));
        return Disposition.done;
    case "/api/analyze": {
            if (debugger.stopped) {
                respond(socket, 200, "application/json", `{"error":"resume the stopped program before analysis"}`);
                return Disposition.done;
            }
            string[4] names = ["depth", "max_nodes", "max_steps", "max_objects"];
            long[4] counts = [3, 100, 1_000_000, 200_000];
            LuaValue[] arguments;
            foreach (i, name; names) {
                if (parameter(name).length && !signedNumber(parameter(name), counts[i])) {
                    respond(socket, 200, "application/json", `{"error":` ~ jsonQuote(
                            "analysis option must be an integer: " ~ name) ~ `}`);
                    return Disposition.done;
                }
                arguments ~= LuaValue(counts[i]);
            }
            respond(socket, 200, "application/json", callView(state, "analyze", arguments, ok));
            syncHook(state);
            return Disposition.done;
        }
    case "/api/why":
        respond(socket, 200, "application/json", callView(state, "why", [LuaValue(parameter("id"))], ok));
        return Disposition.done;
    case "/api/definition":
        respond(socket, 200, "application/json", definitionsJson(parameter("name")));
        return Disposition.done;
    case "/api/complete":
        respond(socket, 200, "application/json", callView(state, "complete", [
            LuaValue(request.body_)
        ], ok));
        return Disposition.done;
    case "/api/content":
        respond(socket, 200, "application/json", callView(state, "contentList", [], ok));
        return Disposition.done;
    case "/api/files": {
            string[] found;
            listFiles(".", "", 0, found);
            sortStrings(found);
            string json = `{"files":[`;
            foreach (i, name; found)
                json ~= (i ? "," : "") ~ jsonQuote(name);
            respond(socket, 200, "application/json", json ~ "]}");
            return Disposition.done;
        }
    case "/api/file": {
            auto path = parameter("path");
            if (!safePath(path)) {
                respond(socket, 400, "text/plain", "bad path\n");
                return Disposition.done;
            }
            if (request.method == "POST") {
                respond(socket, writeFile(path, request.body_) ? 200 : 500, "text/plain", "");
                return Disposition.done;
            }
            string content;
            if (!readFile(path, content)) {
                respond(socket, 404, "text/plain", "not found\n");
                return Disposition.done;
            }
            respond(socket, 200, "text/plain; charset=utf-8", content);
            return Disposition.done;
        }
    default:
        respond(socket, 404, "text/plain", "not found\n");
        return Disposition.done;
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
    evaluate(state, `package.path = "./?.varis;./?.lua;" .. package.path`, "=workbench");

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
    debugger.listener = listener;
    debugger.token = token;
    debugger.hook = new LuaNativeFunction((void* pointer, LuaValue[] args) {
        long line = args.length > 1 && args[1].isInteger ? args[1].asInteger : 0;
        return debuggerHook(cast(LuaState) pointer, line);
    }, "workbench.debugger");
    printf("Varis workbench: http://127.0.0.1:%d/?token=%s\n", cast(int) ntohs(address.sin_port), (token ~ "\0").ptr);
    printf("Loopback only. The command window runs code with your permissions; keep the address private.\n");
    fflush(stdout);

    debugger.thread = state.mainThread;
    startAcceptThread();
    while (true) {
        int connection;
        Request request;
        nextConnection(connection, request);
        auto disposition = handle(state, connection, request, token);
        if (disposition == Disposition.done)
            closeConnection(connection);
        requestFinished();
    }
}
