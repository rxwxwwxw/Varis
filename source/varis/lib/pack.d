/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/
module varis.lib.pack;

// Port of the format and byte algorithms in Lua 5.4 lstrlib.c.
import varis.types;
import varis.state : LuaState, raise;
import varis.exception : LuaException;
import varis.vm : VM;
import core.stdc.config : c_long;
import std.format : format;
import std.string : indexOf;

private enum Kind {
    signedInt,
    unsignedInt,
    single,
    double_,
    fixedString,
    string_,
    zeroString,
    padding,
    alignment,
    none
}

private struct Part {
    Kind kind;
    int size;
    size_t padding;
}

private union NativeAlignment {
    double number;
    void* pointer;
    c_long integer;
    long luaInteger;
}

private enum nativeLittle = (() { version (LittleEndian)
            return true; else
            return false; })();

private struct Format {
    string text;
    size_t position;
    bool little = nativeLittle;
    int maxAlign = 1;
    /// Set by the parser (and left set) when the format is invalid; the caller reports it.
    string error;

    private bool fail(string message) {
        if (error is null)
            error = message;
        return false;
    }

    int numeral(int fallback) {
        if (position >= text.length || text[position] < '0' || text[position] > '9')
            return fallback;
        int result;
        do {
            result = result * 10 + text[position++] - '0';
        }
        while (position < text.length && text[position] >= '0' && text[position] <= '9' && result <= (int.max - 9) / 10);
        return result;
    }

    int integerSize(int fallback) {
        int size = numeral(fallback);
        if (size < 1 || size > 16) {
            fail(format("integral size (%d) out of limits [1,16]", size));
            return 1;
        }
        return size;
    }

    Part option() {
        if (position >= text.length || text[position] == '\0') {
            fail("invalid next option for option 'X'");
            return Part(Kind.none);
        }
        char option = text[position++];
        switch (option) {
        case 'b':
            return Part(Kind.signedInt, 1);
        case 'B':
            return Part(Kind.unsignedInt, 1);
        case 'h':
            return Part(Kind.signedInt, short.sizeof);
        case 'H':
            return Part(Kind.unsignedInt, ushort.sizeof);
        case 'l':
            return Part(Kind.signedInt, c_long.sizeof);
        case 'L':
            return Part(Kind.unsignedInt, c_long.sizeof);
        case 'j':
            return Part(Kind.signedInt, long.sizeof);
        case 'J':
            return Part(Kind.unsignedInt, ulong.sizeof);
        case 'T':
            return Part(Kind.unsignedInt, size_t.sizeof);
        case 'f':
            return Part(Kind.single, float.sizeof);
        case 'd':
        case 'n':
            return Part(Kind.double_, double.sizeof);
        case 'i':
            return Part(Kind.signedInt, integerSize(int.sizeof));
        case 'I':
            return Part(Kind.unsignedInt, integerSize(uint.sizeof));
        case 's':
            return Part(Kind.string_, integerSize(size_t.sizeof));
        case 'c':
            int size = numeral(-1);
            if (size < 0) {
                fail("missing size for format option 'c'");
                return Part(Kind.none);
            }
            return Part(Kind.fixedString, size);
        case 'z':
            return Part(Kind.zeroString);
        case 'x':
            return Part(Kind.padding, 1);
        case 'X':
            return Part(Kind.alignment);
        case '<':
            little = true;
            break;
        case '>':
            little = false;
            break;
        case '=':
            little = nativeLittle;
            break;
        case '!':
            maxAlign = integerSize(NativeAlignment.alignof);
            break;
        case ' ':
            break;
        default:
            fail(format("invalid format option '%c'", option));
        }
        return Part(Kind.none);
    }

    bool next(size_t total, out Part part) {
        if (position >= text.length || text[position] == '\0')
            return false;
        part = option();
        if (error !is null)
            return true;
        int alignment = part.size;
        if (part.kind == Kind.alignment) {
            auto next = option();
            if (error !is null)
                return true;
            if (next.kind == Kind.fixedString || next.size == 0) {
                fail("invalid next option for option 'X'");
                return true;
            }
            alignment = next.size;
        }
        if (alignment > 1 && part.kind != Kind.fixedString) {
            if (alignment > maxAlign)
                alignment = maxAlign;
            if ((alignment & (alignment - 1)) != 0) {
                fail("format asks for alignment not power of 2");
                return true;
            }
            part.padding = (alignment - (total & (alignment - 1))) & (alignment - 1);
        }
        return true;
    }
}

private bool failText(LuaState L, string message) {
    raise(L, new LuaException(message));
    return false;
}

private bool stringArg(LuaState L, LuaValue[] args, size_t index, out string result) {
    if (index >= args.length || (!isString(args[index]) && !isNumber(args[index])))
        return failText(L, "string expected");
    result = toLuaString(args[index]);
    return true;
}

private bool numberArg(LuaState L, LuaValue[] args, size_t index, out LuaValue number) {
    if (index >= args.length || !VM.toCoercedNumber(args[index], number))
        return failText(L, "number expected");
    return true;
}

private bool integerArg(LuaState L, LuaValue[] args, size_t index, out long value) {
    LuaValue number;
    if (!numberArg(L, args, index, number))
        return false;
    if (isInteger(number)) {
        value = number.match!((long v) => v, _ => 0L);
        return true;
    }
    if (!floatToInteger(number.match!((double v) => v, _ => double.nan), value))
        return failText(L, "number has no integer representation");
    return true;
}

private void pad(ref char[] output, size_t count) {
    auto start = output.length;
    output.length += count;
    output[start .. $] = '\0';
}

private void putInteger(ref char[] output, ulong value, int size, bool little, bool negative = false) {
    size_t start = output.length;
    output.length += size;
    for (int i = 0; i < size; ++i) {
        ubyte byte_ = i < 8 ? cast(ubyte)(value >> (8 * i)) : negative ? 0xff : 0;
        output[start + (little ? i : size - i - 1)] = cast(char) byte_;
    }
}

/// Returns false (nothing read) when a wide integer does not fit a Lua integer.
private bool getInteger(string data, size_t position, int size, bool little, bool signed_, out long result) {
    ulong value;
    int limit = size < 8 ? size : 8;
    for (int i = limit - 1; i >= 0; --i)
        value = (value << 8) | cast(ubyte) data[position + (little ? i : size - i - 1)];
    if (size < 8 && signed_) {
        ulong mask = 1UL << (size * 8 - 1);
        value = (value ^ mask) - mask;
    } else if (size > 8) {
        ubyte extension = signed_ && cast(long) value < 0 ? 0xff : 0;
        for (int i = 8; i < size; ++i)
            if (cast(ubyte) data[position + (little ? i : size - i - 1)] != extension)
                return false;
    }
    result = cast(long) value;
    return true;
}

private union SingleBits {
    float number;
    uint bits;
}

private union DoubleBits {
    double number;
    ulong bits;
}

LuaValue[] packValues(LuaState L, LuaValue[] args) {
    string fmt;
    if (!stringArg(L, args, 0, fmt))
        return null;
    auto parser = Format(fmt);
    char[] output;
    Part part;
    size_t argument = 1;
    while (parser.next(output.length, part)) {
        if (parser.error !is null) {
            failText(L, parser.error);
            return null;
        }
        pad(output, part.padding);
        final switch (part.kind) {
        case Kind.signedInt:
        case Kind.unsignedInt:
            long integer;
            if (!integerArg(L, args, argument++, integer))
                return null;
            if (part.size < 8) {
                if (part.kind == Kind.signedInt) {
                    long limit = 1L << (part.size * 8 - 1);
                    if (integer < -limit || integer >= limit) {
                        failText(L, "integer overflow");
                        return null;
                    }
                } else if (cast(ulong) integer >= (1UL << (part.size * 8))) {
                    failText(L, "unsigned overflow");
                    return null;
                }
            }
            putInteger(output, cast(ulong) integer, part.size, parser.little, part.kind == Kind.signedInt && integer < 0);
            break;
        case Kind.single:
        case Kind.double_:
            LuaValue number;
            if (!numberArg(L, args, argument++, number))
                return null;
            double value = number.match!((long integer) => cast(double) integer, (double value) => value, _ => 0.0);
            if (part.kind == Kind.single) {
                SingleBits bits;
                bits.number = cast(float) value;
                putInteger(output, bits.bits, 4, parser.little);
            } else {
                DoubleBits bits;
                bits.number = value;
                putInteger(output, bits.bits, 8, parser.little);
            }
            break;
        case Kind.fixedString:
            string value;
            if (!stringArg(L, args, argument++, value))
                return null;
            if (value.length > part.size) {
                failText(L, "string longer than given size");
                return null;
            }
            output ~= value;
            pad(output, part.size - value.length);
            break;
        case Kind.string_:
            string value;
            if (!stringArg(L, args, argument++, value))
                return null;
            if (part.size < size_t.sizeof && value.length >= (1UL << (part.size * 8))) {
                failText(L, "string length does not fit in given size");
                return null;
            }
            putInteger(output, value.length, part.size, parser.little);
            output ~= value;
            break;
        case Kind.zeroString:
            string value;
            if (!stringArg(L, args, argument++, value))
                return null;
            if (value.indexOf('\0') >= 0) {
                failText(L, "string contains zeros");
                return null;
            }
            output ~= value;
            output ~= '\0';
            break;
        case Kind.padding:
            output ~= '\0';
            break;
        case Kind.alignment:
        case Kind.none:
            break;
        }
    }
    if (parser.error !is null) {
        failText(L, parser.error);
        return null;
    }
    return [LuaValue(cast(string) output)];
}

LuaValue[] packedSize(LuaState L, LuaValue[] args) {
    string fmt;
    if (!stringArg(L, args, 0, fmt))
        return null;
    auto parser = Format(fmt);
    size_t total;
    Part part;
    while (parser.next(total, part)) {
        if (parser.error !is null) {
            failText(L, parser.error);
            return null;
        }
        if (part.kind == Kind.string_ || part.kind == Kind.zeroString) {
            failText(L, "variable-length format");
            return null;
        }
        size_t size = part.size + part.padding;
        if (size > int.max || total > int.max - size) {
            failText(L, "format result too large");
            return null;
        }
        total += size;
    }
    if (parser.error !is null) {
        failText(L, parser.error);
        return null;
    }
    return [LuaValue(cast(long) total)];
}

LuaValue[] unpackValues(LuaState L, LuaValue[] args) {
    string fmt, data;
    if (!stringArg(L, args, 0, fmt) || !stringArg(L, args, 1, data))
        return null;
    auto parser = Format(fmt);
    long initial = 1;
    if (args.length > 2 && !isNil(args[2]) && !integerArg(L, args, 2, initial))
        return null;
    if (initial < 0)
        initial = initial < -cast(long) data.length ? 1 : cast(long) data.length + initial + 1;
    if (initial == 0)
        initial = 1;
    size_t position = cast(size_t)(initial - 1);
    if (position > data.length) {
        failText(L, "initial position out of string");
        return null;
    }
    LuaValue[] output;
    Part part;
    long integer;
    while (parser.next(position, part)) {
        if (parser.error !is null) {
            failText(L, parser.error);
            return null;
        }
        if (part.padding + part.size > data.length - position) {
            failText(L, "data string too short");
            return null;
        }
        position += part.padding;
        final switch (part.kind) {
        case Kind.signedInt:
        case Kind.unsignedInt:
            if (!getInteger(data, position, part.size, parser.little, part.kind == Kind.signedInt, integer)) {
                failText(L, format("%d-byte integer does not fit into Lua Integer", part.size));
                return null;
            }
            output ~= LuaValue(integer);
            break;
        case Kind.single:
            SingleBits bits;
            getInteger(data, position, 4, parser.little, false, integer);
            bits.bits = cast(uint) integer;
            output ~= LuaValue(cast(double) bits.number);
            break;
        case Kind.double_:
            DoubleBits bits;
            getInteger(data, position, 8, parser.little, false, integer);
            bits.bits = cast(ulong) integer;
            output ~= LuaValue(bits.number);
            break;
        case Kind.fixedString:
            output ~= LuaValue(data[position .. position + part.size]);
            break;
        case Kind.string_:
            if (!getInteger(data, position, part.size, parser.little, false, integer)) {
                failText(L, format("%d-byte integer does not fit into Lua Integer", part.size));
                return null;
            }
            ulong length = cast(ulong) integer;
            if (length > data.length - position - part.size) {
                failText(L, "data string too short");
                return null;
            }
            output ~= LuaValue(data[position + part.size .. position + part.size + cast(size_t) length]);
            position += length;
            break;
        case Kind.zeroString:
            auto end = data[position .. $].indexOf('\0');
            if (end < 0) {
                failText(L, "unfinished string for format 'z'");
                return null;
            }
            output ~= LuaValue(data[position .. position + end]);
            position += end + 1;
            break;
        case Kind.padding:
        case Kind.alignment:
        case Kind.none:
            break;
        }
        position += part.size;
    }
    if (parser.error !is null) {
        failText(L, parser.error);
        return null;
    }
    output ~= LuaValue(cast(long) position + 1);
    return output;
}
