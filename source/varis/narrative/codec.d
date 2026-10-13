/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.codec;

import varis.types;
import varis.table;
import varis.exception : LuaException;
import std.conv : to;
import std.format : format;
import std.math : isFinite;
import std.algorithm : sort;
import std.json;

class ImmutableSequence {
    LuaValue[] values;
    this(LuaValue[] values) {
        this.values = values.dup;
    }
}

class ImmutableRecord {
    LuaValue[string] fields;
    /// Canonical save text of this record, made on the first save that writes it (a record and
    /// everything a save accepts inside it are immutable, so the text cannot go stale).
    string savedText;
    this(LuaValue[string] fields) {
        this.fields = fields.dup;
    }
}

LuaValue immutableSequence(LuaValue[] values) {
    return wrapImmutable(new ImmutableSequence(values));
}

LuaValue immutableRecord(LuaValue[string] fields) {
    return wrapImmutable(new ImmutableRecord(fields));
}

LuaValue wrapImmutable(Object payload) {
    auto mt = new LuaTable();
    mt.rawset(LuaValue("__metatable"), LuaValue("immutable narrative value"));
    mt.rawset(LuaValue("__newindex"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                throw new LuaException("cannot modify immutable narrative value");
                return cast(LuaValue[])[];
            })));
    mt.rawset(LuaValue("__index"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                if (args.length < 2)
                    return [luaNil()];
                if (auto sequence = cast(ImmutableSequence) payload) {
                    if (isInteger(args[1])) {
                        long index = args[1].match!((long n) => n, _ => 0L);
                        if (index >= 1 && index <= sequence.values.length)
                            return [sequence.values[index - 1]];
                    }
                    if (luaRawEqual(args[1], LuaValue("length")))
                        return [LuaValue(cast(long) sequence.values.length)];
                }
                if (auto record = cast(ImmutableRecord) payload) {
                    if (isString(args[1]))
                        return [record.fields.get(args[1].match!((string k) => k, _ => ""), luaNil())];
                }
                return [luaNil()];
            })));
    mt.rawset(LuaValue("__len"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                auto sequence = cast(ImmutableSequence) payload;
                if (sequence is null)
                    throw new LuaException("record has no sequence length");
                return [LuaValue(cast(long) sequence.values.length)];
            })));
    return LuaValue(new LuaUserData(payload, mt));
}

private string bytesToHex(string value) {
    static immutable digits = "0123456789abcdef";
    char[] result;
    result.length = value.length * 2;
    foreach (i, byteValue; cast(const(ubyte)[]) value) {
        result[2 * i] = digits[byteValue >> 4];
        result[2 * i + 1] = digits[byteValue & 15];
    }
    return cast(string) result;
}

private string hexToBytes(string value) {
    if (value.length % 2)
        throw new LuaException("invalid hexadecimal save value");
    char[] result;
    foreach (i; 0 .. value.length / 2) {
        int digit(char c) {
            if (c >= '0' && c <= '9')
                return c - '0';
            if (c >= 'a' && c <= 'f')
                return c - 'a' + 10;
            throw new LuaException("invalid hexadecimal save value");
        }

        result ~= cast(char)((digit(value[i * 2]) << 4) | digit(value[i * 2 + 1]));
    }
    return cast(string) result;
}

/// Scalar identity follows relational numeric equality and is byte-safe.
string canonicalScalar(LuaValue value) {
    if (isNil(value))
        return "n";
    if (isBoolean(value))
        return value.match!((bool b) => b ? "b1" : "b0", _ => "");
    if (isInteger(value))
        return "i" ~ value.match!((long n) => n.to!string, _ => "");
    if (isFloat(value)) {
        double number = value.match!((double n) => n, _ => 0.0);
        if (!isFinite(number))
            throw new LuaException("nonfinite narrative instance/save value");
        long integral;
        if (floatToInteger(number, integral))
            return "i" ~ integral.to!string;
        union Bits {
            double number;
            ulong bits;
        }

        Bits bits;
        bits.number = number;
        return "f" ~ format("%016x", bits.bits);
    }
    if (isString(value))
        return "s" ~ bytesToHex(value.match!((string s) => s, _ => ""));
    if (isSymbol(value))
        return "y" ~ bytesToHex(value.match!((Symbol s) => s.name, _ => ""));
    throw new LuaException("nonserializable narrative instance value: " ~ typeName(value));
}

string canonicalBindings(LuaValue[] values) {
    string result;
    foreach (value; values) {
        string encoded = canonicalScalar(value);
        result ~= encoded.length.to!string ~ ":" ~ encoded;
    }
    return result;
}

/// Canonical nested values used for named once-per periods.
string canonicalPersisted(LuaValue value) {
    auto userdata = value.match!((LuaUserData u) => u, _ => null);
    if (userdata !is null) {
        if (auto sequence = cast(ImmutableSequence) userdata.payload) {
            string result = "q";
            foreach (element; sequence.values) {
                auto encoded = canonicalPersisted(element);
                result ~= encoded.length.to!string ~ ":" ~ encoded;
            }
            return result;
        }
        if (auto record = cast(ImmutableRecord) userdata.payload) {
            string result = "r";
            auto names = record.fields.keys;
            names.sort;
            foreach (name; names) {
                auto key = canonicalScalar(LuaValue(name));
                auto encoded = canonicalPersisted(record.fields[name]);
                result ~= key.length.to!string ~ ":" ~ key ~ encoded.length.to!string ~ ":" ~ encoded;
            }
            return result;
        }
    }
    return canonicalScalar(value);
}

/// A tagged JSON representation preserves integers, binary data, symbols and nil.
JSONValue encodeValue(LuaValue value, string path = "value") {
    if (isFloat(value)) {
        union Bits {
            double number;
            ulong bits;
        }

        Bits bits;
        bits.number = value.match!((double number) => number, _ => 0.0);
        if (!isFinite(bits.number))
            throw new LuaException("nonfinite save value at " ~ path);
        return JSONValue("f" ~ format("%016x", bits.bits));
    }
    if (isNil(value) || isBoolean(value) || isInteger(value) || isFloat(value) || isString(value) || isSymbol(value))
        return JSONValue(canonicalScalar(value));
    auto userdata = value.match!((LuaUserData u) => u, _ => null);
    if (userdata !is null) {
        if (auto sequence = cast(ImmutableSequence) userdata.payload) {
            JSONValue[] values;
            foreach (i, element; sequence.values)
                values ~= encodeValue(element, path ~ "[" ~ i.to!string ~ "]");
            return JSONValue(["sequence": JSONValue(values)]);
        }
        if (auto record = cast(ImmutableRecord) userdata.payload) {
            JSONValue[string] fields;
            foreach (key, element; record.fields)
                fields[bytesToHex(key)] = encodeValue(element, path ~ "." ~ key);
            return JSONValue(["record": JSONValue(fields)]);
        }
    }
    throw new LuaException("unsupported save value at " ~ path ~ ": " ~ typeName(value));
}

/// Writes exactly the canonical JSON text of `encodeValue(value)` (object members in sorted
/// order) without building the JSON tree. Returns false, having possibly written part of it,
/// for a value `encodeValue` would reject; the caller then takes the ordinary path, which
/// raises the error with its path.
bool writeEncodedText(Sink)(ref Sink sink, LuaValue value) {
    static immutable digits = "0123456789abcdef";
    void hex(string prefix, string bytes) {
        sink.put('"');
        sink.put(prefix);
        foreach (b; cast(const(ubyte)[]) bytes) {
            sink.put(digits[b >> 4]);
            sink.put(digits[b & 15]);
        }
        sink.put('"');
    }

    if (isFloat(value)) {
        union Bits {
            double number;
            ulong bits;
        }

        Bits bits;
        bits.number = value.asFloat;
        if (!isFinite(bits.number))
            return false;
        char[18] text = void;
        text[0] = '"';
        text[1] = 'f';
        foreach (i; 0 .. 16)
            text[2 + i] = digits[(bits.bits >> (60 - 4 * i)) & 15];
        sink.put(text[]);
        sink.put('"');
        return true;
    }
    if (isNil(value)) {
        sink.put(`"n"`);
        return true;
    }
    if (isBoolean(value)) {
        sink.put(value.isTruthy() ? `"b1"` : `"b0"`);
        return true;
    }
    if (isInteger(value)) {
        sink.put(`"i`);
        sink.put(value.asInteger.to!string);
        sink.put('"');
        return true;
    }
    if (isString(value)) {
        hex("s", value.asString);
        return true;
    }
    if (isSymbol(value)) {
        hex("y", value.match!((Symbol symbol) => symbol.name, _ => ""));
        return true;
    }
    if (value.typeOf() != LuaType.UserData)
        return false;
    auto payload = value.asUserData.payload;
    if (auto sequence = cast(ImmutableSequence) payload) {
        sink.put(`{"sequence":[`);
        foreach (i, element; sequence.values) {
            if (i)
                sink.put(',');
            if (!writeEncodedText(sink, element))
                return false;
        }
        sink.put("]}");
        return true;
    }
    if (auto record = cast(ImmutableRecord) payload) {
        // Member names are the hexadecimal of the field names, which sorts as the names do.
        auto names = record.fields.keys;
        names.sort;
        sink.put(`{"record":{`);
        foreach (i, name; names) {
            if (i)
                sink.put(',');
            hex("", name);
            sink.put(':');
            if (!writeEncodedText(sink, record.fields[name]))
                return false;
        }
        sink.put("}}");
        return true;
    }
    return false;
}

LuaValue decodeValue(JSONValue encoded) {
    if (encoded.type == JSONType.object) {
        if (auto sequence = "sequence" in encoded.object) {
            LuaValue[] values;
            foreach (element; sequence.array)
                values ~= decodeValue(element);
            return immutableSequence(values);
        }
        if (auto record = "record" in encoded.object) {
            LuaValue[string] fields;
            foreach (key, element; record.object)
                fields[hexToBytes(key)] = decodeValue(element);
            return immutableRecord(fields);
        }
        throw new LuaException("invalid immutable save value");
    }
    string value = encoded.str;
    if (value.length == 0)
        throw new LuaException("invalid scalar save value");
    switch (value[0]) {
    case 'n':
        if (value == "n")
            return luaNil();
        break;
    case 'b':
        if (value == "b0" || value == "b1")
            return LuaValue(value == "b1");
        break;
    case 'i':
        return LuaValue(value[1 .. $].to!long);
    case 'f':
        if (value.length != 17)
            break;
        union Bits {
            double number;
            ulong bits;
        }

        Bits bits;
        bits.bits = value[1 .. $].to!ulong(16);
        if (!isFinite(bits.number))
            break;
        return LuaValue(bits.number);
    case 's':
        return LuaValue(hexToBytes(value[1 .. $]));
    case 'y':
        return LuaValue(Symbol(hexToBytes(value[1 .. $])));
    default:
        break;
    }
    throw new LuaException("invalid scalar save value");
}
