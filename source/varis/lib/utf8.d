/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.lib.utf8;

import varis.types;
import varis.table;
import varis.state;
import varis.vm : VM;
import varis.exception : LuaException;

// Ported from Lua 5.4 lutf8lib.c. Positions and validation are byte based;
// Lua's lax mode and char accept extended UTF-8 through 0x7fffffff.
private bool continuation(string source, size_t index) {
    return index < source.length && (cast(ubyte) source[index] & 0xc0) == 0x80;
}

private bool fail(void* s, string message) {
    raise(cast(LuaState) s, new LuaException(message));
    return false;
}

private bool integerArgument(void* s, LuaValue[] args, size_t index, long fallback, bool optional, out long result) {
    if (optional && (index >= args.length || isNil(args[index]))) {
        result = fallback;
        return true;
    }
    LuaValue number;
    if (index >= args.length || !VM.toCoercedNumber(args[index], number))
        return fail(s, "number expected");
    if (isInteger(number)) {
        result = number.match!((long value) => value, _ => 0L);
        return true;
    }
    if (!floatToInteger(number.match!((double value) => value, _ => double.nan), result))
        return fail(s, "number has no integer representation");
    return true;
}

private bool stringArgument(void* s, LuaValue[] args, out string result) {
    if (!args.length || (!isString(args[0]) && !isNumber(args[0])))
        return fail(s, "string expected");
    result = toLuaString(args[0]);
    return true;
}

private long relative(long position, size_t length) {
    if (position >= 0)
        return position;
    if (position < -cast(long) length)
        return 0;
    return cast(long) length + position + 1;
}

private bool decodeCode(string source, size_t index, bool strict, out uint code, out size_t next) {
    if (index >= source.length)
        return false;
    uint first = cast(ubyte) source[index];
    if (first < 0x80) {
        code = first;
        next = index + 1;
        return true;
    }
    if (first < 0xc2 || first >= 0xfe)
        return false;
    int length = first < 0xe0 ? 2 : first < 0xf0 ? 3 : first < 0xf8 ? 4 : first < 0xfc ? 5 : 6;
    if (source.length - index < length)
        return false;
    code = first & ((1u << (7 - length)) - 1);
    for (int offset = 1; offset < length; ++offset) {
        if (!continuation(source, index + offset))
            return false;
        code = (code << 6) | (cast(ubyte) source[index + offset] & 0x3f);
    }
    immutable uint[7] minimum = [0, 0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000];
    if (code < minimum[length] || code > 0x7fffffff)
        return false;
    if (strict && (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)))
        return false;
    next = index + length;
    return true;
}

void openUtf8Lib(LuaState state) {
    auto library = new LuaTable();
    library.rawset(LuaValue("charpattern"), LuaValue("[\0-\x7F\xC2-\xFD][\x80-\xBF]*"));
    library.rawset(LuaValue("char"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                char[] result;
                foreach (index, arg; args) {
                    long value;
                    if (!integerArgument(s, args, index, 0, false, value))
                        return null;
                    if (value < 0 || value > 0x7fffffff) {
                        fail(s, "value out of range");
                        return null;
                    }
                    uint code = cast(uint) value;
                    if (code < 0x80) {
                        result ~= cast(char) code;
                        continue;
                    }
                    char[6] buffer;
                    int start = 6;
                    uint mask = 0x3f;
                    do {
                        buffer[--start] = cast(char)(0x80 | (code & 0x3f));
                        code >>= 6;
                        mask >>= 1;
                    }
                    while (code > mask);
                    buffer[--start] = cast(char)((~mask << 1) | code);
                    result ~= buffer[start .. $];
                }
                return [LuaValue(cast(string) result)];
            }, "utf8_char")));

    library.rawset(LuaValue("len"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                string source;
                long first, last;
                if (!stringArgument(s, args, source) || !integerArgument(s, args, 1, 1, true, first))
                    return null;
                first = relative(first, source.length);
                if (!integerArgument(s, args, 2, -1, true, last))
                    return null;
                last = relative(last, source.length);
                if (first < 1 || first - 1 > source.length) {
                    fail(s, "initial position out of bounds");
                    return null;
                }
                if (last > source.length) {
                    fail(s, "final position out of bounds");
                    return null;
                }
                bool strict = args.length < 4 || !isTruthy(args[3]);
                size_t index = cast(size_t)(first - 1);
                long count;
                while (cast(long) index < last) {
                    uint code;
                    size_t next;
                    if (!decodeCode(source, index, strict, code, next))
                        return [luaNil(), LuaValue(cast(long) index + 1)];
                    index = next;
                    ++count;
                }
                return [LuaValue(count)];
            }, "utf8_len")));

    library.rawset(LuaValue("codepoint"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                string source;
                long first, last;
                if (!stringArgument(s, args, source) || !integerArgument(s, args, 1, 1, true, first))
                    return null;
                first = relative(first, source.length);
                if (!integerArgument(s, args, 2, first, true, last))
                    return null;
                last = relative(last, source.length);
                if (first < 1 || last > source.length) {
                    fail(s, "out of bounds");
                    return null;
                }
                bool strict = args.length < 4 || !isTruthy(args[3]);
                LuaValue[] result;
                size_t index = cast(size_t)(first - 1);
                while (cast(long) index < last) {
                    uint code;
                    size_t next;
                    if (!decodeCode(source, index, strict, code, next)) {
                        fail(s, "invalid UTF-8 code");
                        return null;
                    }
                    result ~= LuaValue(cast(long) code);
                    index = next;
                }
                return result;
            }, "utf8_codepoint")));

    library.rawset(LuaValue("offset"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                string source;
                long n, position;
                if (!stringArgument(s, args, source) || !integerArgument(s, args, 1, 0, false, n)
                    || !integerArgument(s, args, 2, n >= 0 ? 1 : cast(long) source.length + 1, true, position))
                    return null;
                position = relative(position, source.length);
                if (position < 1 || position - 1 > source.length) {
                    fail(s, "position out of bounds");
                    return null;
                }
                size_t index = cast(size_t)(position - 1);
                if (n == 0) {
                    while (index > 0 && continuation(source, index))
                        --index;
                } else {
                    if (continuation(source, index)) {
                        fail(s, "initial position is a continuation byte");
                        return null;
                    }
                    if (n < 0) {
                        while (n < 0 && index > 0) {
                            do {
                                --index;
                            }
                            while (index > 0 && continuation(source, index));
                            ++n;
                        }
                    } else {
                        --n;
                        while (n > 0 && index < source.length) {
                            do {
                                ++index;
                            }
                            while (continuation(source, index));
                            --n;
                        }
                    }
                }
                return [n == 0 ? LuaValue(cast(long) index + 1) : luaNil()];
            }, "utf8_offset")));

    LuaValue iterator(bool strict) {
        return LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                string source;
                long control;
                if (!stringArgument(s, args, source) || !integerArgument(s, args, 1, 0, true, control))
                    return null;
                if (control < 0 || cast(ulong) control >= source.length)
                    return cast(LuaValue[])[];
                size_t index = cast(size_t) control;
                while (continuation(source, index))
                    ++index;
                if (index >= source.length)
                    return cast(LuaValue[])[];
                uint code;
                size_t next;
                if (!decodeCode(source, index, strict, code, next) || continuation(source, next)) {
                    fail(s, "invalid UTF-8 code");
                    return null;
                }
                return [LuaValue(cast(long) index + 1), LuaValue(cast(long) code)];
            }, "utf8_codes_iterator"));
    }

    auto strictIterator = iterator(true);
    auto laxIterator = iterator(false);
    library.rawset(LuaValue("codes"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                string source;
                if (!stringArgument(s, args, source))
                    return null;
                if (continuation(source, 0)) {
                    fail(s, "invalid UTF-8 code");
                    return null;
                }
                return [
                    args.length > 1 && isTruthy(args[1]) ? laxIterator : strictIterator, args[0],
                    LuaValue(0L)
                ];
            }, "utf8_codes")));
    state.setGlobal("utf8", LuaValue(library));
}
