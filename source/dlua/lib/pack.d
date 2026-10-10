/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/
module dlua.lib.pack;

// Port of the format and byte algorithms in Lua 5.4 lstrlib.c.
import dlua.types;
import dlua.exception : LuaException;
import dlua.vm : VM;
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
        if (size < 1 || size > 16)
            throw new LuaException(format("integral size (%d) out of limits [1,16]", size));
        return size;
    }

    Part option() {
        if (position >= text.length || text[position] == '\0')
            throw new LuaException("invalid next option for option 'X'");
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
            if (size < 0)
                throw new LuaException("missing size for format option 'c'");
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
            throw new LuaException(format("invalid format option '%c'", option));
        }
        return Part(Kind.none);
    }

    bool next(size_t total, out Part part) {
        if (position >= text.length || text[position] == '\0')
            return false;
        part = option();
        int alignment = part.size;
        if (part.kind == Kind.alignment) {
            auto next = option();
            if (next.kind == Kind.fixedString || next.size == 0)
                throw new LuaException("invalid next option for option 'X'");
            alignment = next.size;
        }
        if (alignment > 1 && part.kind != Kind.fixedString) {
            if (alignment > maxAlign)
                alignment = maxAlign;
            if ((alignment & (alignment - 1)) != 0)
                throw new LuaException("format asks for alignment not power of 2");
            part.padding = (alignment - (total & (alignment - 1))) & (alignment - 1);
        }
        return true;
    }
}

private string stringArg(LuaValue[] args, size_t index) {
    if (index >= args.length || (!isString(args[index]) && !isNumber(args[index])))
        throw new LuaException("string expected");
    return toLuaString(args[index]);
}

private LuaValue numberArg(LuaValue[] args, size_t index) {
    LuaValue number;
    if (index >= args.length || !VM.toCoercedNumber(args[index], number))
        throw new LuaException("number expected");
    return number;
}

private long integerArg(LuaValue[] args, size_t index) {
    auto number = numberArg(args, index);
    if (isInteger(number))
        return number.match!((long value) => value, _ => 0L);
    long value;
    if (!floatToInteger(number.match!((double value) => value, _ => double.nan), value))
        throw new LuaException("number has no integer representation");
    return value;
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

private long getInteger(string data, size_t position, int size, bool little, bool signed_) {
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
                throw new LuaException(format("%d-byte integer does not fit into Lua Integer", size));
    }
    return cast(long) value;
}

private union SingleBits {
    float number;
    uint bits;
}

private union DoubleBits {
    double number;
    ulong bits;
}

LuaValue[] packValues(LuaValue[] args) {
    auto parser = Format(stringArg(args, 0));
    char[] output;
    Part part;
    size_t argument = 1;
    while (parser.next(output.length, part)) {
        pad(output, part.padding);
        final switch (part.kind) {
        case Kind.signedInt:
        case Kind.unsignedInt:
            long integer = integerArg(args, argument++);
            if (part.size < 8) {
                if (part.kind == Kind.signedInt) {
                    long limit = 1L << (part.size * 8 - 1);
                    if (integer < -limit || integer >= limit)
                        throw new LuaException("integer overflow");
                } else if (cast(ulong) integer >= (1UL << (part.size * 8)))
                    throw new LuaException("unsigned overflow");
            }
            putInteger(output, cast(ulong) integer, part.size, parser.little, part.kind == Kind.signedInt && integer < 0);
            break;
        case Kind.single:
        case Kind.double_:
            auto number = numberArg(args, argument++);
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
            string value = stringArg(args, argument++);
            if (value.length > part.size)
                throw new LuaException("string longer than given size");
            output ~= value;
            pad(output, part.size - value.length);
            break;
        case Kind.string_:
            string value = stringArg(args, argument++);
            if (part.size < size_t.sizeof && value.length >= (1UL << (part.size * 8)))
                throw new LuaException("string length does not fit in given size");
            putInteger(output, value.length, part.size, parser.little);
            output ~= value;
            break;
        case Kind.zeroString:
            string value = stringArg(args, argument++);
            if (value.indexOf('\0') >= 0)
                throw new LuaException("string contains zeros");
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
    return [LuaValue(cast(string) output)];
}

LuaValue[] packedSize(LuaValue[] args) {
    auto parser = Format(stringArg(args, 0));
    size_t total;
    Part part;
    while (parser.next(total, part)) {
        if (part.kind == Kind.string_ || part.kind == Kind.zeroString)
            throw new LuaException("variable-length format");
        size_t size = part.size + part.padding;
        if (size > int.max || total > int.max - size)
            throw new LuaException("format result too large");
        total += size;
    }
    return [LuaValue(cast(long) total)];
}

LuaValue[] unpackValues(LuaValue[] args) {
    auto parser = Format(stringArg(args, 0));
    string data = stringArg(args, 1);
    long initial = args.length > 2 && !isNil(args[2]) ? integerArg(args, 2) : 1;
    if (initial < 0)
        initial = initial < -cast(long) data.length ? 1 : cast(long) data.length + initial + 1;
    if (initial == 0)
        initial = 1;
    size_t position = cast(size_t)(initial - 1);
    if (position > data.length)
        throw new LuaException("initial position out of string");
    LuaValue[] output;
    Part part;
    while (parser.next(position, part)) {
        if (part.padding + part.size > data.length - position)
            throw new LuaException("data string too short");
        position += part.padding;
        final switch (part.kind) {
        case Kind.signedInt:
        case Kind.unsignedInt:
            output ~= LuaValue(getInteger(data, position, part.size, parser.little, part.kind == Kind.signedInt));
            break;
        case Kind.single:
            SingleBits bits;
            bits.bits = cast(uint) getInteger(data, position, 4, parser.little, false);
            output ~= LuaValue(cast(double) bits.number);
            break;
        case Kind.double_:
            DoubleBits bits;
            bits.bits = cast(ulong) getInteger(data, position, 8, parser.little, false);
            output ~= LuaValue(bits.number);
            break;
        case Kind.fixedString:
            output ~= LuaValue(data[position .. position + part.size]);
            break;
        case Kind.string_:
            ulong length = cast(ulong) getInteger(data, position, part.size, parser.little, false);
            if (length > data.length - position - part.size)
                throw new LuaException("data string too short");
            output ~= LuaValue(data[position + part.size .. position + part.size + cast(size_t) length]);
            position += length;
            break;
        case Kind.zeroString:
            auto end = data[position .. $].indexOf('\0');
            if (end < 0)
                throw new LuaException("unfinished string for format 'z'");
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
    output ~= LuaValue(cast(long) position + 1);
    return output;
}
