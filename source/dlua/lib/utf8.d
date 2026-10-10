/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.lib.utf8;

import dlua.types;
import dlua.table;
import dlua.state;
import dlua.vm : VM;
import dlua.exception : LuaException;

// Ported from Lua 5.4 lutf8lib.c. Positions and validation are byte based;
// Lua's lax mode and char accept extended UTF-8 through 0x7fffffff.
private bool continuation(string source, size_t index) {
    return index < source.length && (cast(ubyte)source[index] & 0xc0) == 0x80;
}

private long integerArgument(LuaValue[] args, size_t index, long fallback, bool optional = true) {
    if (optional && (index >= args.length || isNil(args[index]))) return fallback;
    LuaValue number;
    if (index >= args.length || !VM.toCoercedNumber(args[index], number))
        throw new LuaException("number expected");
    if (isInteger(number)) return number.match!((long value) => value, _ => 0L);
    long value;
    if (!floatToInteger(number.match!((double value) => value, _ => double.nan), value))
        throw new LuaException("number has no integer representation");
    return value;
}

private string stringArgument(LuaValue[] args) {
    if (!args.length || (!isString(args[0]) && !isNumber(args[0])))
        throw new LuaException("string expected");
    return toLuaString(args[0]);
}

private long relative(long position, size_t length) {
    if (position >= 0) return position;
    if (position < -cast(long)length) return 0;
    return cast(long)length + position + 1;
}

private bool decodeCode(string source, size_t index, bool strict, out uint code, out size_t next) {
    if (index >= source.length) return false;
    uint first = cast(ubyte)source[index];
    if (first < 0x80) { code = first; next = index + 1; return true; }
    if (first < 0xc2 || first >= 0xfe) return false;
    int length = first < 0xe0 ? 2 : first < 0xf0 ? 3 : first < 0xf8 ? 4 : first < 0xfc ? 5 : 6;
    if (source.length - index < length) return false;
    code = first & ((1u << (7 - length)) - 1);
    for (int offset = 1; offset < length; ++offset) {
        if (!continuation(source, index + offset)) return false;
        code = (code << 6) | (cast(ubyte)source[index + offset] & 0x3f);
    }
    immutable uint[7] minimum = [0, 0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000];
    if (code < minimum[length] || code > 0x7fffffff) return false;
    if (strict && (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff))) return false;
    next = index + length;
    return true;
}

void openUtf8Lib(LuaState state) {
    auto library = new LuaTable();
    library.rawset(LuaValue("charpattern"), LuaValue("[\0-\x7F\xC2-\xFD][\x80-\xBF]*"));
    library.rawset(LuaValue("char"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
        char[] result;
        foreach (index, arg; args) {
            long value = integerArgument(args, index, 0, false);
            if (value < 0 || value > 0x7fffffff) throw new LuaException("value out of range");
            uint code = cast(uint)value;
            if (code < 0x80) { result ~= cast(char)code; continue; }
            char[6] buffer;
            int start = 6;
            uint mask = 0x3f;
            do {
                buffer[--start] = cast(char)(0x80 | (code & 0x3f));
                code >>= 6;
                mask >>= 1;
            } while (code > mask);
            buffer[--start] = cast(char)((~mask << 1) | code);
            result ~= buffer[start .. $];
        }
        return [LuaValue(cast(string)result)];
    }, "utf8_char")));

    library.rawset(LuaValue("len"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
        string source = stringArgument(args);
        long first = relative(integerArgument(args, 1, 1), source.length);
        long last = relative(integerArgument(args, 2, -1), source.length);
        if (first < 1 || first - 1 > source.length) throw new LuaException("initial position out of bounds");
        if (last > source.length) throw new LuaException("final position out of bounds");
        bool strict = args.length < 4 || !isTruthy(args[3]);
        size_t index = cast(size_t)(first - 1);
        long count;
        while (cast(long)index < last) {
            uint code; size_t next;
            if (!decodeCode(source, index, strict, code, next)) return [luaNil(), LuaValue(cast(long)index + 1)];
            index = next; ++count;
        }
        return [LuaValue(count)];
    }, "utf8_len")));

    library.rawset(LuaValue("codepoint"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
        string source = stringArgument(args);
        long first = relative(integerArgument(args, 1, 1), source.length);
        long last = relative(integerArgument(args, 2, first), source.length);
        if (first < 1 || last > source.length) throw new LuaException("out of bounds");
        bool strict = args.length < 4 || !isTruthy(args[3]);
        LuaValue[] result;
        size_t index = cast(size_t)(first - 1);
        while (cast(long)index < last) {
            uint code; size_t next;
            if (!decodeCode(source, index, strict, code, next)) throw new LuaException("invalid UTF-8 code");
            result ~= LuaValue(cast(long)code); index = next;
        }
        return result;
    }, "utf8_codepoint")));

    library.rawset(LuaValue("offset"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
        string source = stringArgument(args);
        long n = integerArgument(args, 1, 0, false);
        long position = relative(integerArgument(args, 2, n >= 0 ? 1 : cast(long)source.length + 1), source.length);
        if (position < 1 || position - 1 > source.length) throw new LuaException("position out of bounds");
        size_t index = cast(size_t)(position - 1);
        if (n == 0) {
            while (index > 0 && continuation(source, index)) --index;
        } else {
            if (continuation(source, index)) throw new LuaException("initial position is a continuation byte");
            if (n < 0) {
                while (n < 0 && index > 0) {
                    do { --index; } while (index > 0 && continuation(source, index));
                    ++n;
                }
            } else {
                --n;
                while (n > 0 && index < source.length) {
                    do { ++index; } while (continuation(source, index));
                    --n;
                }
            }
        }
        return [n == 0 ? LuaValue(cast(long)index + 1) : luaNil()];
    }, "utf8_offset")));

    LuaValue iterator(bool strict) {
        return LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
            string source = stringArgument(args);
            long control = integerArgument(args, 1, 0);
            if (control < 0 || cast(ulong)control >= source.length) return cast(LuaValue[])[];
            size_t index = cast(size_t)control;
            while (continuation(source, index)) ++index;
            if (index >= source.length) return cast(LuaValue[])[];
            uint code; size_t next;
            if (!decodeCode(source, index, strict, code, next) || continuation(source, next))
                throw new LuaException("invalid UTF-8 code");
            return [LuaValue(cast(long)index + 1), LuaValue(cast(long)code)];
        }, "utf8_codes_iterator"));
    }
    auto strictIterator = iterator(true);
    auto laxIterator = iterator(false);
    library.rawset(LuaValue("codes"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
        string source = stringArgument(args);
        if (continuation(source, 0)) throw new LuaException("invalid UTF-8 code");
        return [args.length > 1 && isTruthy(args[1]) ? laxIterator : strictIterator, args[0], LuaValue(0L)];
    }, "utf8_codes")));
    state.setGlobal("utf8", LuaValue(library));
}
