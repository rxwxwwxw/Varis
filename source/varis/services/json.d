/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// A small JSON reader for the catalogs the localization tools keep in the repository. Objects
/// keep the order of their keys. No exceptions: `parseJson` returns false and an error text.
module varis.services.json;

struct JsonValue {
    enum Kind : ubyte {
        null_,
        bool_,
        number,
        string_,
        array,
        object
    }

    Kind kind;
    bool boolean;
    double number;
    string text;
    JsonValue[] items; // array elements, or object values
    string[] keys; // object keys, parallel to `items`

    /// The value of an object member, or null.
    const(JsonValue)* get(string key) const {
        if (kind != Kind.object)
            return null;
        foreach (i, k; keys)
            if (k == key)
                return &items[i];
        return null;
    }

    string stringOr(string key, string fallback = "") const {
        auto v = get(key);
        return v !is null && v.kind == Kind.string_ ? v.text : fallback;
    }

    long integerOr(string key, long fallback = 0) const {
        auto v = get(key);
        return v !is null && v.kind == Kind.number ? cast(long) v.number : fallback;
    }
}

private struct Reader {
    string text;
    size_t at;
    string error;
    int depth;

    bool fail(string message) {
        if (error.length == 0)
            error = message;
        return false;
    }

    void skip() {
        while (at < text.length && (text[at] == ' ' || text[at] == '\t' || text[at] == '\n' || text[at] == '\r'))
            ++at;
    }

    bool literal(string word) {
        if (at + word.length <= text.length && text[at .. at + word.length] == word) {
            at += word.length;
            return true;
        }
        return fail("invalid literal");
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

    bool hex4(out uint value) {
        if (at + 4 > text.length)
            return fail("bad \\u escape");
        value = 0;
        foreach (i; 0 .. 4) {
            auto h = hexValue(text[at + i]);
            if (h < 0)
                return fail("bad \\u escape");
            value = value * 16 + h;
        }
        at += 4;
        return true;
    }

    static void utf8(ref char[] out_, uint c) {
        if (c < 0x80)
            out_ ~= cast(char) c;
        else if (c < 0x800) {
            out_ ~= cast(char)(0xC0 | (c >> 6));
            out_ ~= cast(char)(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            out_ ~= cast(char)(0xE0 | (c >> 12));
            out_ ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
            out_ ~= cast(char)(0x80 | (c & 0x3F));
        } else {
            out_ ~= cast(char)(0xF0 | (c >> 18));
            out_ ~= cast(char)(0x80 | ((c >> 12) & 0x3F));
            out_ ~= cast(char)(0x80 | ((c >> 6) & 0x3F));
            out_ ~= cast(char)(0x80 | (c & 0x3F));
        }
    }

    bool str(out string result) {
        ++at; // opening quote
        char[] buffer;
        while (true) {
            if (at >= text.length)
                return fail("unterminated string");
            char c = text[at++];
            if (c == '"')
                break;
            if (c != '\\') {
                buffer ~= c;
                continue;
            }
            if (at >= text.length)
                return fail("unterminated string");
            char e = text[at++];
            switch (e) {
            case '"':
                buffer ~= '"';
                break;
            case '\\':
                buffer ~= '\\';
                break;
            case '/':
                buffer ~= '/';
                break;
            case 'b':
                buffer ~= '\b';
                break;
            case 'f':
                buffer ~= '\f';
                break;
            case 'n':
                buffer ~= '\n';
                break;
            case 'r':
                buffer ~= '\r';
                break;
            case 't':
                buffer ~= '\t';
                break;
            case 'u': {
                    uint code;
                    if (!hex4(code))
                        return false;
                    if (code >= 0xD800 && code < 0xDC00 && at + 1 < text.length && text[at] == '\\' && text[at + 1] == 'u') {
                        at += 2;
                        uint low;
                        if (!hex4(low))
                            return false;
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                    }
                    utf8(buffer, code);
                    break;
                }
            default:
                return fail("bad escape");
            }
        }
        result = cast(string) buffer;
        return true;
    }

    bool value(out JsonValue v) {
        if (++depth > 64)
            return fail("nested too deeply");
        scope (exit)
            --depth;
        skip();
        if (at >= text.length)
            return fail("unexpected end of input");
        char c = text[at];
        if (c == '{') {
            v.kind = JsonValue.Kind.object;
            ++at;
            skip();
            if (at < text.length && text[at] == '}') {
                ++at;
                return true;
            }
            while (true) {
                skip();
                if (at >= text.length || text[at] != '"')
                    return fail("object key expected");
                string key;
                if (!str(key))
                    return false;
                skip();
                if (at >= text.length || text[at] != ':')
                    return fail("':' expected");
                ++at;
                JsonValue item;
                if (!value(item))
                    return false;
                v.keys ~= key;
                v.items ~= item;
                skip();
                if (at < text.length && text[at] == ',') {
                    ++at;
                    continue;
                }
                if (at < text.length && text[at] == '}') {
                    ++at;
                    return true;
                }
                return fail("',' or '}' expected");
            }
        }
        if (c == '[') {
            v.kind = JsonValue.Kind.array;
            ++at;
            skip();
            if (at < text.length && text[at] == ']') {
                ++at;
                return true;
            }
            while (true) {
                JsonValue item;
                if (!value(item))
                    return false;
                v.items ~= item;
                skip();
                if (at < text.length && text[at] == ',') {
                    ++at;
                    continue;
                }
                if (at < text.length && text[at] == ']') {
                    ++at;
                    return true;
                }
                return fail("',' or ']' expected");
            }
        }
        if (c == '"') {
            v.kind = JsonValue.Kind.string_;
            return str(v.text);
        }
        if (c == 't') {
            v.kind = JsonValue.Kind.bool_;
            v.boolean = true;
            return literal("true");
        }
        if (c == 'f') {
            v.kind = JsonValue.Kind.bool_;
            return literal("false");
        }
        if (c == 'n') {
            v.kind = JsonValue.Kind.null_;
            return literal("null");
        }
        if (c == '-' || (c >= '0' && c <= '9')) {
            import core.stdc.stdlib : strtod;

            size_t end = at;
            while (end < text.length && ((text[end] >= '0' && text[end] <= '9') || text[end] == '-' || text[end] == '+'
                    || text[end] == '.' || text[end] == 'e' || text[end] == 'E'))
                ++end;
            auto copy = (text[at .. end] ~ "\0");
            v.kind = JsonValue.Kind.number;
            v.number = strtod(copy.ptr, null);
            at = end;
            return true;
        }
        return fail("unexpected character");
    }
}

/// Parses `text`. On failure returns false and sets `error`.
bool parseJson(string text, out JsonValue value, out string error) {
    Reader reader;
    reader.text = text;
    // A UTF-8 byte order mark is not part of the document.
    if (text.length >= 3 && text[0] == 0xEF && text[1] == 0xBB && text[2] == 0xBF)
        reader.at = 3;
    if (!reader.value(value)) {
        error = reader.error;
        return false;
    }
    reader.skip();
    if (reader.at != text.length) {
        error = "unexpected text after the document";
        return false;
    }
    return true;
}
