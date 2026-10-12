/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The writer's workflow commands (AUTHORING_TOOLS_PLAN stage A6): `varis play`, a text playtest of
/// the project, and `varis test`, author tests. Both run the project's own code (the entry module
/// and the session function named in the manifest) in a fresh state; the Lua side of each is the
/// source below, which a writer can read and copy.
module varis.services.play;

import core.stdc.stdio;

import varis.exception : LuaException;
import varis.state;
import varis.types;
import varis.vm : VM;
import varis.services.diagnostic;
import varis.services.index : indexFile;
import varis.services.l10n : localeMessages;
import varis.services.manifest;
import varis.workbench.server : errorText, jsonQuote, readFile;

private void say(string text) {
    fwrite(text.ptr, 1, text.length, stdout);
}

private void warn(string text) {
    fwrite(text.ptr, 1, text.length, stderr);
}

/// Hands the manifest to the Lua side as the global `__varis_project`.
private void installConfig(LuaState state, ref const Manifest manifest, long seed, string locale = null, bool keys = false) {
    auto table = new LuaTable();
    void set(string key, string value) {
        if (value.length)
            table.rawset(LuaValue(key), LuaValue(value));
    }

    set("id", manifest.id);
    set("language", manifest.language);
    set("entry", manifest.entry);
    set("session", manifest.session);
    set("after_choose", manifest.afterChoose);
    set("finished", manifest.finished);
    set("load", manifest.load);
    table.rawset(LuaValue("seed"), LuaValue(seed));
    if (locale.length) {
        table.rawset(LuaValue("locale"), LuaValue(locale));
        string[string] messages;
        string error;
        auto pack = new LuaTable();
        if (localeMessages(locale, messages, error)) {
            foreach (key, text; messages)
                pack.rawset(LuaValue(key), LuaValue(text));
        } else
            table.rawset(LuaValue("locale_error"), LuaValue(error));
        state.setGlobal("__varis_translations", LuaValue(pack));
    }
    if (keys)
        table.rawset(LuaValue("keys"), LuaValue(true));
    // The parameters of each storylet, read from the source: a presentation's bindings are an
    // immutable record that cannot be enumerated.
    auto parameters = new LuaTable();
    foreach (path; projectFiles(".", manifest)) {
        string content;
        if (!readFile(path, content))
            continue;
        auto indexed = indexFile(path, content);
        foreach (ref d; indexed.declarations)
            if (d.kind == "storylet" && d.parameters.length) {
                auto names = new LuaTable();
                foreach (i, name; d.parameters)
                    names.rawset(LuaValue(cast(long) i + 1), LuaValue(name));
                parameters.rawset(LuaValue(d.name), LuaValue(names));
            }
    }
    table.rawset(LuaValue("parameters"), LuaValue(parameters));
    state.setGlobal("__varis_project", LuaValue(table));
    // Project modules resolve from the project directory, as when a game is run from it.
    auto path = state.loadString(`package.path = "./?.lua;./?/init.lua;" .. package.path`, "=varis");
    VM.callValue(state, LuaValue(path), []);
}

// -----------------------------------------------------------------------------
// varis play
// -----------------------------------------------------------------------------

private enum playSource = q"LUA
-- varis play: a text front end for any project whose manifest names a session function.
local cfg = __varis_project

local function resolve(path)
    if not path then return nil end
    local module, name = path:match("^(.*)%.([^.]+)$")
    assert(module, "manifest: expected \"module.function\", got " .. path)
    return require(module)[name]
end

require(cfg.entry)
local language = cfg.locale
if language then
    if cfg.locale_error then
        print("language " .. language .. ": " .. cfg.locale_error)
        language = nil
    else
        local ok, err = pcall(narrative.translate, language, __varis_translations)
        if not ok then print(tostring(err)); language = nil end
    end
end
local new_session = assert(resolve(cfg.session), "the manifest has no usable `session`")
local after_choose, finished, loader = resolve(cfg.after_choose), resolve(cfg.finished), resolve(cfg.load)

local function name_of(value)
    if type(value) == "string" then return value end
    local ok, text = pcall(logic.symbolname, value)
    if ok then return text end
    return narrative.display(value)
end

-- A choice is written as `storylet choice key=value,...` so that a recorded game can be
-- replayed without tokens.
local function describe_bindings(bindings, names)
    local parts = {}
    for _, k in ipairs(names) do parts[#parts + 1] = k .. "=" .. name_of(bindings[k]) end
    return table.concat(parts, ",")
end

local function binding_names(story)
    -- Bindings are an immutable record; the storylet's parameters come from the project source.
    return cfg.parameters[name_of(story.id)] or {}
end

local seed, input_path, record_path = cfg.seed or 1, nil, nil
local script = {}
for i = 1, #(arg or {}) do
    local a = arg[i]
    if a == "--seed" then seed = tonumber(arg[i + 1]) or seed
    elseif a == "--replay" then input_path = arg[i + 1]
    elseif a == "--record" then record_path = arg[i + 1] end
end
if input_path then
    local f = assert(io.open(input_path, "r"))
    for line in f:lines() do if line ~= "" and line:sub(1, 1) ~= "#" then script[#script + 1] = line end end
    f:close()
end
local record = record_path and assert(io.open(record_path, "w")) or nil
if record then record:write("# varis play --seed " .. seed .. "\n") end

local session = new_session(seed)
if language then session:set_language(language) end
local last_seq = 0
local function show_events()
    local new = {}
    logic (session:world()) do
        for e in query narrative_event(?seq, ?turn, ?kind, ?args) do
            if e.seq > last_seq then new[#new + 1] = e end
        end
    end
    table.sort(new, function(a, b) return a.seq < b.seq end)
    for _, e in ipairs(new) do
        local args = {}
        for i = 1, #e.args do args[#args + 1] = narrative.display(e.args[i]) end
        print("  [" .. name_of(e.kind) .. (#args > 0 and (" " .. table.concat(args, ", ")) or "") .. "]")
        last_seq = e.seq
    end
end

local function why(id)
    local sym = symbol(id)
    local ok, e = pcall(narrative.explain, session, sym)
    if not ok then print("  no storylet or action named " .. id); return end
    if e.eligible then
        print("  " .. id .. " is available (" .. #e.instances .. " instance(s)).")
    else
        print("  " .. id .. " is not available:")
        local goals = e.availability.goals
        for i = 1, #goals do
            local g = goals[i]
            local what = g.relation and (g.relation .. "(...)") or g.kind
            print(string.format("    goal %d %s: %s (%d -> %d)", g.index, what, g.outcome, g.before, g.after))
        end
    end
    for n = 1, #e.instances do
        local instance = e.instances[n]
        for i = 1, #instance.exclusions do print("    excluded: " .. tostring(instance.exclusions[i].reason)) end
    end
end

local function take(menu, spec)
    local number = tonumber(spec)
    if number then return menu[number] end
    local story, choice, rest = spec:match("^(%S+)%s+(%S+)%s*(.*)$")
    for _, m in ipairs(menu) do
        if name_of(m.story.id) == story and name_of(m.choice.id) == choice
            and (rest == "" or rest == describe_bindings(m.story.bindings, binding_names(m.story))) then
            return m
        end
    end
end

local presentation
local over = false
while not over do
    if not presentation then
        local ok, result = pcall(session.present, session)
        if not ok then print("error: " .. tostring(result)); break end
        presentation = result
    end
    show_events()
    local menu = {}
    for _, story in ipairs(presentation.storylets) do
        local story_id = name_of(story.id)
        print("\n" .. (cfg.keys and ("[" .. story_id .. ".title] ") or "") .. story.title)
        if story.text ~= "" then print((cfg.keys and ("[" .. story_id .. ".text] ") or "") .. story.text) end
        for _, c in ipairs(story.choices) do
            menu[#menu + 1] = { story = story, choice = c }
            print(string.format("  %d) %s%s", #menu,
                cfg.keys and ("[" .. story_id .. "." .. name_of(c.id) .. ".title] ") or "",
                c.title ~= "" and c.title or "Continue"))
        end
    end
    if #menu == 0 then print("\nNothing more can happen."); break end
    local line
    if input_path then
        line = table.remove(script, 1)
        if not line then break end
        print("> " .. line)
    else
        io.write("\n> (number, why NAME, save [FILE], load [FILE], quit) ")
        line = io.read("l")
    end
    if not line or line == "quit" or line == "q" then break end
    local command, argument = line:match("^(%S+)%s*(.*)$")
    if command == "why" and argument ~= "" then
        why(argument)
    elseif command == "save" then
        local f = assert(io.open(argument ~= "" and argument or "varis.sav", "w"))
        f:write(session:save()); f:close()
        print("  saved")
    elseif command == "load" then
        if not loader then
            print("  the manifest has no `load` function")
        else
            local f = io.open(argument ~= "" and argument or "varis.sav", "r")
            if not f then print("  no such save") else
                local text = f:read("a"); f:close()
                local ok, restored = pcall(loader, text)
                if ok then
                    session = restored; presentation = nil; last_seq = 0
                    if language then session:set_language(language) end
                    logic (session:world()) do
                        for e in query narrative_event(?seq, ?turn, ?kind, ?args) do
                            if e.seq > last_seq then last_seq = e.seq end
                        end
                    end
                    print("  loaded")
                else print("  could not load: " .. tostring(restored)) end
            end
        end
    else
        local m = take(menu, line)
        if not m then
            print("  (a number from 1 to " .. #menu .. ", why NAME, save, load or quit)")
        else
            local names = binding_names(m.story)
            local ok, err = pcall(session.choose, session, m.choice.token)
            if not ok then
                print("  (" .. tostring(err) .. ")")
            else
                if record then
                    record:write(name_of(m.story.id) .. " " .. name_of(m.choice.id)
                        .. (#names > 0 and (" " .. describe_bindings(m.story.bindings, names)) or "") .. "\n")
                end
                presentation = nil
                if after_choose then after_choose(session) end
                narrative.flush(session:world())
                if finished and finished(session) then show_events(); print("\n*** THE END ***"); over = true end
            end
        end
    end
end
if record then record:close() end
LUA";

/// `varis play [--seed N] [--replay FILE] [--record FILE]`: a text playtest. Returns an exit status.
int playMain(LuaState state, string[] args) {
    auto manifest = loadManifest(".");
    if (!manifest.present || manifest.entry.length == 0 || manifest.session.length == 0) {
        warn("varis play needs project.lua with `entry` and `session` (module.function)\n");
        return 2;
    }
    long seed = 1;
    string locale;
    bool keys;
    foreach (i, a; args) {
        if (a == "--locale" && i + 1 < args.length)
            locale = args[i + 1];
        else if (a == "--keys")
            keys = true;
    }
    auto argTable = new LuaTable();
    long position = 1;
    foreach (a; args)
        argTable.rawset(LuaValue(position++), LuaValue(a));
    state.setGlobal("arg", LuaValue(argTable));
    try {
        installConfig(state, manifest, seed, locale, keys);
        auto fn = state.loadString(playSource, "=varis play");
        VM.callValue(state, LuaValue(fn), []);
    } catch (LuaException failure) {
        warn("varis play: " ~ errorText(failure.errorObject) ~ "\n");
        return 1;
    }
    return 0;
}

// -----------------------------------------------------------------------------
// varis test
// -----------------------------------------------------------------------------

private enum testSource = q"LUA
-- The `test` library for author tests (AUTHORING_TOOLS_PLAN §5).
local cfg = __varis_project
local T = {}
T.__index = T
test = {}

local function resolve(path)
    if not path then return nil end
    local module, name = path:match("^(.*)%.([^.]+)$")
    assert(module, "manifest: expected \"module.function\", got " .. path)
    return require(module)[name]
end

local booted
local function boot()
    if booted then return end
    booted = true
    require(cfg.entry)
    if cfg.locale then
        assert(not cfg.locale_error, "language " .. cfg.locale .. ": " .. tostring(cfg.locale_error))
        narrative.translate(cfg.locale, __varis_translations)
    end
end

local function name_of(value)
    if type(value) == "string" then return value end
    local ok, text = pcall(logic.symbolname, value)
    if ok then return text end
    return narrative.display(value)
end

local function show(value)
    return name_of(value)
end

function test.play(options)
    boot()
    local new_session = assert(resolve(cfg.session), "the manifest has no usable `session`")
    local seed = (options and options.seed) or cfg.seed or 1
    local self = setmetatable({ seed = seed }, T)
    self.session = new_session(seed)
    local language = (options and options.locale) or cfg.locale
    if language then self.session:set_language(language) end
    self.after_choose = resolve(cfg.after_choose)
    self.finished = resolve(cfg.finished)
    self.loader = resolve(cfg.load)
    return self
end

function T:world() return self.session:world() end

function T:present()
    if not self._presentation then self._presentation = self.session:present() end
    return self._presentation
end

local function matches(story, id, bindings)
    if name_of(story.id) ~= name_of(id) then return false end
    if bindings then
        for k, v in pairs(bindings) do
            if story.bindings[k] ~= v then return false end
        end
    end
    return true
end

-- Why a storylet is not on offer, in words, for a failing test.
function T:why(id)
    local ok, e = pcall(narrative.explain, self.session, symbol(name_of(id)))
    if not ok then return "there is no storylet or action named " .. name_of(id) end
    local lines = {}
    if e.eligible then
        lines[#lines + 1] = name_of(id) .. " is available, but not with these bindings"
    else
        lines[#lines + 1] = name_of(id) .. " is not available:"
        local goals = e.availability.goals
        for i = 1, #goals do
            local g = goals[i]
            if g.outcome ~= "success" then
                lines[#lines + 1] = string.format("  goal %d %s: %s", g.index, g.relation and (g.relation .. "(...)") or g.kind, g.outcome)
                break
            end
        end
    end
    for n = 1, #e.instances do
        local instance = e.instances[n]
        for i = 1, #instance.exclusions do
            lines[#lines + 1] = "  excluded: " .. tostring(instance.exclusions[i].reason)
        end
    end
    return table.concat(lines, "\n")
end

function T:shown(id, bindings)
    for _, story in ipairs(self:present().storylets) do
        if matches(story, id, bindings) then return story end
    end
end

function T:expect_shown(id, bindings)
    if not self:shown(id, bindings) then
        error("expected " .. name_of(id) .. " to be shown\n" .. self:why(id), 2)
    end
end

function T:expect_hidden(id, bindings)
    if self:shown(id, bindings) then
        error("expected " .. name_of(id) .. " not to be shown", 2)
    end
end

function T:choose(story_id, choice_id, bindings)
    local story = self:shown(story_id, bindings)
    if not story then
        error("cannot choose " .. name_of(story_id) .. "/" .. name_of(choice_id) .. ": it is not shown\n" .. self:why(story_id), 2)
    end
    for _, c in ipairs(story.choices) do
        if name_of(c.id) == name_of(choice_id) then
            self.session:choose(c.token)
            self._presentation = nil
            if self.after_choose then self.after_choose(self.session) end
            narrative.flush(self.session:world())
            return self
        end
    end
    error("storylet " .. name_of(story_id) .. " has no choice offered named " .. name_of(choice_id), 2)
end

local function holds(self, source)
    local chunk, err = load("local w = ...; local r; logic (w) do r = (query " .. source .. ")() end; return r ~= nil")
    if not chunk then error("cannot read the goal `" .. source .. "`: " .. tostring(err), 3) end
    return chunk(self.session:world())
end

function T:expect_fact(source)
    if not holds(self, source) then error("expected `" .. source .. "` to hold", 2) end
end

function T:expect_no_fact(source)
    if holds(self, source) then error("expected `" .. source .. "` not to hold", 2) end
end

function T:expect_quality(entity, name, value)
    local actual = quality.get(entity, name, self.session:world())
    if actual ~= value then
        error(string.format("expected quality %s of %s to be %s, but it is %s", show(name), show(entity), tostring(value), tostring(actual)), 2)
    end
end

function T:save() return self.session:save() end

function T:load(text)
    assert(self.loader, "the manifest has no `load` function")
    self.session = self.loader(text)
    self._presentation = nil
    return self
end

function T:is_over()
    return self.finished and self.finished(self.session) or false
end

local cases = {}
function test.case(name, fn) cases[#cases + 1] = { name = name, fn = fn } end

-- Runs one test file; returns a list of { name, ok, message }.
function __varis_run_test(path)
    local results = {}
    local chunk, err = loadfile(path)
    if not chunk then return { { name = path, ok = false, message = tostring(err) } } end
    local ok, failure = pcall(chunk)
    if not ok then
        results[#results + 1] = { name = path, ok = false, message = tostring(failure) }
    elseif #cases == 0 then
        results[#results + 1] = { name = path, ok = true, message = "" }
    end
    for _, case in ipairs(cases) do
        local passed, message = pcall(case.fn)
        results[#results + 1] = { name = case.name, ok = passed, message = passed and "" or tostring(message) }
    end
    return results
end
LUA";

private struct TestFailure {
    string file;
    string name;
    string message;
}

/// `varis test [--json] [files...]`: runs author tests, each file in a fresh state. Returns 0 when
/// every test passed, 1 when one failed.
int testMain(LuaState delegate() makeState, string[] args) {
    bool json;
    string locale;
    string[] files;
    for (size_t i = 0; i < args.length; ++i) {
        auto a = args[i];
        if (a == "--json")
            json = true;
        else if (a == "--locale" && i + 1 < args.length)
            locale = args[++i];
        else if (a.length && a[0] == '-') {
            warn("usage: varis test [--json] [--locale L] [files...]\n");
            return 2;
        } else
            files ~= a;
    }
    auto manifest = loadManifest(".");
    if (!manifest.present || manifest.entry.length == 0 || manifest.session.length == 0) {
        warn("varis test needs project.lua with `entry` and `session` (module.function)\n");
        return 2;
    }
    if (files.length == 0) {
        if (manifest.tests.length == 0) {
            warn("name test files, or list them as `tests = { \"tests/*.lua\" }` in project.lua\n");
            return 2;
        }
        files = expandPatterns(".", manifest.tests);
    }
    Diagnostic[] problems;
    size_t passed;
    foreach (file; files) {
        auto state = makeState();
        string content;
        if (!readFile(file, content)) {
            problems ~= makeDiagnostic("error", "io", file, 0, 0, 0, 0, "cannot read file");
            continue;
        }
        // The game may print (achievements, say); the results are what this command reports.
        auto quiet = QuietOutput(true);
        try {
            installConfig(state, manifest, 1, locale);
            VM.callValue(state, LuaValue(state.loadString(testSource, "=varis test")), []);
            auto runner = state.getGlobal("__varis_run_test");
            auto results = VM.callValue(state, runner, [LuaValue(file)]);
            if (results.length == 0 || !results[0].isTable)
                continue;
            auto list = results[0].asTable;
            foreach (i; 1 .. list.rawLen() + 1) {
                auto entry = list.rawget(LuaValue(cast(long) i));
                if (!entry.isTable)
                    continue;
                auto record = entry.asTable;
                bool ok = record.rawget(LuaValue("ok")).isTruthy;
                auto name = record.rawget(LuaValue("name"));
                auto message = record.rawget(LuaValue("message"));
                if (ok) {
                    ++passed;
                    continue;
                }
                string text = message.isString ? message.asString : "test failed";
                auto d = makeDiagnostic("error", "test", file, 0, 0, 0, 0, text,
                        name.isString ? "test " ~ name.asString : "test " ~ file);
                // "file:12: message": the failing line of the test.
                size_t colon;
                while (colon < text.length && text[colon] != ':')
                    ++colon;
                if (colon + 1 < text.length && text[0 .. colon] == file) {
                    size_t at = colon + 1;
                    int line;
                    while (at < text.length && text[at] >= '0' && text[at] <= '9')
                        line = line * 10 + (text[at++] - '0');
                    if (at < text.length && text[at] == ':' && line > 0) {
                        d.line = line;
                        d.column = 1;
                        ++at;
                        while (at < text.length && text[at] == ' ')
                            ++at;
                        d.message = text[at .. $];
                    }
                }
                problems ~= d;
            }
        } catch (LuaException failure) {
            problems ~= makeDiagnostic("error", "test", file, 0, 0, 0, 0, errorText(failure.errorObject));
        }
    }
    if (json) {
        string text = `{"files":` ~ numberText(files.length) ~ `,"passed":` ~ numberText(passed) ~ `,"problems":[`;
        foreach (i, ref d; problems)
            text ~= (i ? "," : "") ~ diagnosticJson(d);
        say(text ~ "]}\n");
    } else {
        foreach (ref d; problems)
            say(diagnosticText(d) ~ "\n");
        say(numberText(passed) ~ " test(s) passed, " ~ numberText(problems.length) ~ " failed\n");
    }
    return problems.length ? 1 : 0;
}

private string numberText(long value) {
    char[24] buffer;
    auto n = snprintf(buffer.ptr, buffer.length, "%lld", value);
    return buffer[0 .. n].idup;
}
