/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Cross-save data: seen lines, unlocked endings, achievements, gallery entries. A profile
/// belongs to the host, not to a session: it is never part of a session save, its content
/// identity or its replay log, and a new game does not reset it. Reads are refused while a
/// transaction, a read-only evaluation or an analysis is running, so no content decision can
/// depend on it and replay stays deterministic; writes made by an effect take hold only
/// after the effect commits.
module varis.narrative.profile;

import varis.types;
import varis.exception : LuaException;
import varis.narrative.codec;
import std.algorithm : sort;
import std.json;

enum profileFormat = "varis-profile-1";

final class Profile {
    LuaValue[string] values;

    string[] keys() {
        auto result = values.keys;
        result.sort;
        return result;
    }

    string save() {
        JSONValue[string] encoded;
        foreach (name, value; values)
            encoded[name] = encodeValue(value, "profile." ~ name);
        return JSONValue([
            "format": JSONValue(profileFormat),
            "values": JSONValue(encoded)
        ]).toString();
    }

    /// Replaces the contents; the old contents stay when the text is invalid.
    void load(string text) {
        LuaValue[string] staged;
        try {
            auto input = parseJSON(text);
            if (input["format"].str != profileFormat)
                throw new LuaException("incompatible profile format");
            foreach (name, value; input["values"].object) {
                if (!name.length)
                    throw new LuaException("invalid profile key");
                staged[name] = decodeValue(value);
            }
        } catch (LuaException error) {
            throw error;
        } catch (Exception error) {
            throw new LuaException("invalid profile: " ~ error.msg);
        }
        values = staged;
    }
}
