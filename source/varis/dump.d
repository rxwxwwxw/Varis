/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Binary chunk serialization (string.dump / load of binary chunks).
///
/// The format is private to varis: it follows the shape of Lua 5.4 precompiled
/// chunks (signature, version, format, conversion data) but stores varis's own
/// instruction layout.
module varis.dump;

import varis.types;
import varis.state;
import varis.opcode;
import varis.vm : LuaClosure, UpValue;
import varis.exception : LuaException;

private enum string signature = "\x1bLua";
private enum ubyte versionByte = 0x54;
private enum ubyte formatByte = 0;
private enum string varisBody = "dLu2"; // marks varis's private body encoding (v2: per-instruction live registers)
private enum string luacData = "\x19\x93\r\n\x1a\n";
private enum long luacInt = 0x5678;
private enum double luacNum = 370.5;
private __gshared long luacIntValue = luacInt;

private struct Writer {
    char[] output;
    bool strip;

    void byte_(ubyte b) {
        output ~= cast(char) b;
    }

    void varint(ulong n) {
        while (n >= 0x80) {
            byte_(cast(ubyte)(n | 0x80));
            n >>= 7;
        }
        byte_(cast(ubyte) n);
    }

    void integer(long n) {
        varint(cast(ulong)((n << 1) ^ (n >> 63)));
    }

    void raw(const(char)[] s) {
        output ~= s;
    }

    void text(string s) {
        varint(s.length);
        raw(s);
    }

    void number(double d) {
        raw((cast(char*)&d)[0 .. 8]);
    }
}

private void dumpConstant(ref Writer w, LuaValue v) {
    if (isNil(v))
        w.byte_(0);
    else if (v.typeOf() == LuaType.Boolean)
        w.byte_(isTruthy(v) ? 2 : 1);
    else if (isInteger(v)) {
        w.byte_(3);
        w.integer(v.match!((long i) => i, _ => 0L));
    } else if (isFloat(v)) {
        w.byte_(4);
        w.number(v.match!((double d) => d, _ => 0.0));
    } else if (isString(v)) {
        w.byte_(5);
        w.text(v.match!((string s) => s, _ => ""));
    } else
        throw new LuaException("unable to dump given function");
}

private void dumpProto(ref Writer w, Prototype p, string parentSource) {
    if (p.ruleTemplates.length || p.queryTemplates.length || p.relationSchemas.length || p.contentTemplates.length)
        throw new LuaException("unable to dump given function");
    w.text(w.strip || p.sourceName == parentSource ? "" : p.sourceName);
    w.integer(p.lineDefined);
    w.integer(p.lastLineDefined);
    w.varint(p.numParams);
    w.byte_(p.isVararg ? 1 : 0);
    w.varint(p.maxStackSize);
    w.text(w.strip ? "" : p.functionName);
    // code
    w.varint(p.code.length);
    foreach (instr; p.code) {
        w.varint(cast(ulong) instr.op);
        w.integer(instr.a);
        w.integer(instr.b);
        w.integer(instr.c);
        w.integer(instr.sBx);
        w.integer(w.strip ? 0 : instr.line);
        w.byte_(cast(ubyte)((instr.bIsK ? 1 : 0) | (instr.cIsK ? 2 : 0) | (instr.aIsK ? 4 : 0)));
    }
    // Live-register bound per instruction (0 = unknown): the collector clears dead temporaries with it,
    // so loaded chunks must carry it or stale registers would keep objects alive.
    foreach (i; 0 .. p.code.length) {
        immutable live = i < p.liveTop.length ? p.liveTop[i] : int.max;
        w.varint(live == int.max ? 0 : cast(ulong) live + 1);
    }
    w.varint(p.constants.length);
    foreach (k; p.constants)
        dumpConstant(w, k);
    w.varint(p.upvalues.length);
    foreach (u; p.upvalues) {
        w.text(w.strip ? "" : u.name);
        w.byte_(u.inStack ? 1 : 0);
        w.integer(u.index);
    }
    if (w.strip) {
        w.varint(0);
        w.varint(0);
        w.varint(0);
    } else {
        w.varint(p.debugLocals.length);
        foreach (l; p.debugLocals) {
            w.text(l.name);
            w.integer(l.register);
            w.integer(l.startPC);
            w.integer(l.endPC);
            w.integer(l.depth);
            w.byte_(l.readOnly ? 1 : 0);
        }
        w.varint(p.callNames.length);
        foreach (pc, name; p.callNames) {
            w.integer(pc);
            w.text(name.name);
            w.text(name.kind);
        }
        w.varint(p.callWorlds.length);
        foreach (pc, world; p.callWorlds) {
            w.integer(pc);
            w.integer(world);
        }
    }
    w.varint(p.subPrototypes.length);
    foreach (sub; p.subPrototypes)
        dumpProto(w, sub, p.sourceName);
}

string dumpFunction(LuaState state, LuaValue fn, bool strip) {
    auto closure = fn.match!((LuaFunction f) => cast(LuaClosure) f, _ => null);
    if (closure is null)
        throw new LuaException("unable to dump given function");
    Writer w;
    w.strip = strip;
    w.raw(signature);
    w.byte_(versionByte);
    w.byte_(formatByte);
    w.raw(luacData);
    w.byte_(4); // sizeof(Instruction) in C Lua
    w.byte_(8); // sizeof(long)
    w.byte_(8); // sizeof(double)
    w.raw((cast(char*)&luacIntValue)[0 .. 8]);
    w.number(luacNum);
    w.raw(varisBody);
    w.byte_(cast(ubyte) closure.proto.upvalues.length);
    dumpProto(w, closure.proto, strip ? "=?" : "");
    // the main prototype always carries its source
    return cast(string) w.output;
}

private struct Reader {
    string data;
    size_t pos;
    string name;

    LuaException error(string why) {
        return new LuaException(name ~ ": bad binary format (" ~ why ~ ")");
    }

    ubyte byte_() {
        if (pos >= data.length)
            throw error("truncated chunk");
        return cast(ubyte) data[pos++];
    }

    ulong varint() {
        ulong result;
        int shift;
        while (true) {
            ubyte b = byte_();
            result |= cast(ulong)(b & 0x7f) << shift;
            if (!(b & 0x80))
                break;
            shift += 7;
            if (shift > 63)
                throw error("integer overflow");
        }
        return result;
    }

    long integer() {
        ulong z = varint();
        return cast(long)((z >> 1) ^ (0UL - (z & 1)));
    }

    int smallInt() {
        long v = integer();
        if (v < int.min || v > int.max)
            throw error("integer overflow");
        return cast(int) v;
    }

    size_t count() {
        auto n = varint();
        if (n > data.length * 8 + 1024)
            throw error("corrupted chunk");
        return cast(size_t) n;
    }

    string text() {
        auto n = varint();
        if (n > data.length - pos)
            throw error("truncated chunk");
        auto s = data[pos .. pos + cast(size_t) n];
        pos += cast(size_t) n;
        return s.idup;
    }

    double number() {
        if (data.length - pos < 8)
            throw error("truncated chunk");
        double d;
        (cast(char*)&d)[0 .. 8] = data[pos .. pos + 8];
        pos += 8;
        return d;
    }

    void expect(string s, string why) {
        if (data.length - pos < s.length)
            throw error("truncated chunk");
        if (data[pos .. pos + s.length] != s)
            throw error(why);
        pos += s.length;
    }
}

private LuaValue undumpConstant(ref Reader r) {
    switch (r.byte_()) {
    case 0:
        return luaNil();
    case 1:
        return LuaValue(false);
    case 2:
        return LuaValue(true);
    case 3:
        return LuaValue(r.integer());
    case 4:
        return LuaValue(r.number());
    case 5:
        return LuaValue(r.text());
    default:
        throw r.error("corrupted chunk");
    }
}

private Prototype undumpProto(ref Reader r, string parentSource, int depth) {
    if (depth > 200)
        throw r.error("too many nested functions");
    auto p = new Prototype();
    auto source = r.text();
    p.sourceName = source.length ? source : parentSource;
    p.lineDefined = r.smallInt();
    p.lastLineDefined = r.smallInt();
    p.numParams = cast(int) r.varint();
    p.isVararg = r.byte_() != 0;
    p.maxStackSize = cast(int) r.varint();
    p.functionName = r.text();
    auto ncode = r.count();
    p.code.length = ncode;
    foreach (ref instr; p.code) {
        auto op = r.varint();
        if (op > cast(ulong) OpCode.MakeQuery)
            throw r.error("corrupted chunk");
        instr.op = cast(OpCode) op;
        instr.a = r.smallInt();
        instr.b = r.smallInt();
        instr.c = r.smallInt();
        instr.sBx = r.smallInt();
        instr.line = r.smallInt();
        auto flags = r.byte_();
        instr.bIsK = (flags & 1) != 0;
        instr.cIsK = (flags & 2) != 0;
        instr.aIsK = (flags & 4) != 0;
    }
    p.liveTop = new int[ncode];
    foreach (ref live; p.liveTop) {
        auto v = r.varint();
        live = v == 0 ? int.max : cast(int)(v - 1);
    }
    auto nk = r.count();
    foreach (i; 0 .. nk)
        p.constants ~= undumpConstant(r);
    auto nup = r.count();
    foreach (i; 0 .. nup) {
        UpvalDesc u;
        u.name = r.text();
        u.inStack = r.byte_() != 0;
        u.index = r.smallInt();
        p.upvalues ~= u;
    }
    auto nlocals = r.count();
    foreach (i; 0 .. nlocals) {
        DebugLocal l;
        l.name = r.text();
        l.register = r.smallInt();
        l.startPC = r.smallInt();
        l.endPC = r.smallInt();
        l.depth = r.smallInt();
        l.readOnly = r.byte_() != 0;
        p.debugLocals ~= l;
    }
    auto ncallnames = r.count();
    foreach (i; 0 .. ncallnames) {
        auto pc = r.smallInt();
        CallName n;
        n.name = r.text();
        n.kind = r.text();
        p.callNames[pc] = n;
    }
    auto ncallworlds = r.count();
    foreach (i; 0 .. ncallworlds) {
        auto pc = r.smallInt();
        p.callWorlds[pc] = r.smallInt();
    }
    auto nsub = r.count();
    foreach (i; 0 .. nsub)
        p.subPrototypes ~= undumpProto(r, p.sourceName, depth + 1);
    return p;
}

LuaFunction undumpFunction(LuaState state, string data, string chunkName) {
    Reader r;
    r.data = data;
    r.name = chunkName.length && (chunkName[0] == '@' || chunkName[0] == '=') ? chunkName[1 .. $] : chunkName.length && chunkName[0] == '\x1b' ? "binary string" : chunkName;
    r.expect(signature, "not a binary chunk");
    if (r.byte_() != versionByte)
        throw r.error("version mismatch");
    if (r.byte_() != formatByte)
        throw r.error("format mismatch");
    r.expect(luacData, "corrupted chunk");
    if (r.byte_() != 4)
        throw r.error("Instruction size mismatch");
    if (r.byte_() != 8)
        throw r.error("lua_Integer size mismatch");
    if (r.byte_() != 8)
        throw r.error("lua_Number size mismatch");
    if (r.data.length - r.pos < 8)
        throw r.error("truncated chunk");
    long storedInt;
    (cast(char*)&storedInt)[0 .. 8] = r.data[r.pos .. r.pos + 8];
    r.pos += 8;
    if (storedInt != luacInt)
        throw r.error("integer format mismatch");
    if (r.number() != luacNum)
        throw r.error("float format mismatch");
    r.expect(varisBody, "incompatible binary body (not produced by varis)");
    auto nupvalues = r.byte_();
    auto proto = undumpProto(r, chunkName.length && (chunkName[0] == '@' || chunkName[0] == '=') ? chunkName : "=?", 0);
    if (proto.upvalues.length != nupvalues)
        throw r.error("corrupted chunk");
    if (r.pos != data.length)
        throw r.error("corrupted chunk");
    UpValue[] upvalues;
    foreach (i; 0 .. proto.upvalues.length) {
        auto up = new UpValue(null, -1);
        up.isClosed = true;
        if (i == 0)
            up.closedVal = LuaValue(state.globals);
        upvalues ~= up;
    }
    return new LuaClosure(proto, upvalues);
}
