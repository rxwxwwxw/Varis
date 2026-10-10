/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.types;

import std.sumtype : sumtypeMatch = match, SumType;
import std.format : format;
import std.conv : to;
import std.math : isNaN, floor;
import std.traits : isIntegral, isFloatingPoint;

public import dlua.table;

/// Represents Lua's nil type
struct Nil {
    bool opEquals(Nil) const @safe pure nothrow {
        return true;
    }

    size_t toHash() const @safe pure nothrow {
        return 0;
    }

    string toString() const @safe pure nothrow {
        return "nil";
    }
}

/// Light userdata (raw pointer)
struct LightUserData {
    void* ptr;

    bool opEquals(LightUserData o) const @safe pure nothrow {
        return ptr == o.ptr;
    }

    size_t toHash() const @safe pure nothrow {
        return cast(size_t)ptr;
    }

    string toString() const @safe pure nothrow {
        return "userdata";
    }
}

/// Lua type tags
enum LuaType {
    Nil = 0,
    Boolean,
    LightUserData,
    Number,
    String,
    Symbol,
    Table,
    Function,
    UserData,
    Thread
}

/// Represents an interned symbol
struct Symbol {
    string name;

    bool opEquals(Symbol o) const @safe pure nothrow {
        return name == o.name;
    }

    size_t toHash() const @safe pure nothrow {
        return hashOf(name) ^ 0x9e3779b9;
    }

    string toString() const @safe pure {
        return ":" ~ name;
    }
}

/// Internal sumtype payload
alias LuaSumType = SumType!(
    Nil,
    bool,
    long,
    double,
    string,
    Symbol,
    LuaTable,
    LuaFunction,
    LuaUserData,
    LightUserData,
    LuaThread
);

/// Try to convert a float to an integer if it represents an exact integer value
bool floatToInteger(double d, out long i) @safe pure nothrow {
    if (isNaN(d)) return false;
    if (d < -9223372036854775808.0 || d >= 9223372036854775808.0) return false;
    long candidate = cast(long)d;
    if (cast(double)candidate == d) {
        i = candidate;
        return true;
    }
    return false;
}

enum TagNil = 0;
enum TagBool = 1;
enum TagLong = 2;
enum TagDouble = 3;
enum TagString = 4;
enum TagSymbol = 5;
enum TagTable = 6;
enum TagFunction = 7;
enum TagUserData = 8;
enum TagLightUserData = 9;
enum TagThread = 10;

pragma(inline, true)
private ref inout(T) getVal(T, size_t tid)(return auto ref inout(LuaSumType) st) @trusted nothrow {
    return *cast(inout(T)*)&st;
}

/// The central struct representing all Lua values, wrapping LuaSumType
struct LuaValue {
    LuaSumType data;

    this(Nil val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(bool val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(long val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(int val) @safe pure nothrow {
        data = LuaSumType(cast(long)val);
    }

    this(double val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(string val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(Symbol val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(LuaTable val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(LuaFunction val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(LuaUserData val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(LightUserData val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    this(LuaThread val) @safe pure nothrow {
        data = LuaSumType(val);
    }

    /// Plain bitwise assignment. Every payload is a value type or a GC reference without a
    /// destructor, so SumType's generic (match-based) assignment adds nothing but overhead.
    pragma(inline, true)
    void opAssign(LuaValue rhs) @trusted nothrow @nogc {
        import core.stdc.string : memcpy;
        memcpy(cast(void*)&this, cast(const(void)*)&rhs, LuaValue.sizeof);
    }

    /// Full Lua-compliant raw equality
    pragma(inline, true)
    bool opEquals(ref const LuaValue rhs) const {
        return opEquals(cast(LuaValue)rhs);
    }

    pragma(inline, true)
    bool opEquals(LuaValue rhs) const {
        auto tidA = data.typeIndex;
        auto tidB = rhs.data.typeIndex;

        if (tidA == tidB) {
            switch (tidA) {
                case TagNil:
                    return true;
                case TagBool:
                    return getVal!(bool, TagBool)(data) == getVal!(bool, TagBool)(rhs.data);
                case TagLong:
                    return getVal!(long, TagLong)(data) == getVal!(long, TagLong)(rhs.data);
                case TagDouble: {
                    double da = getVal!(double, TagDouble)(data);
                    double db = getVal!(double, TagDouble)(rhs.data);
                    if (isNaN(da) || isNaN(db)) return false;
                    return da == db;
                }
                case TagString:
                    return getVal!(string, TagString)(data) == getVal!(string, TagString)(rhs.data);
                case TagSymbol:
                    return getVal!(Symbol, TagSymbol)(data) == getVal!(Symbol, TagSymbol)(rhs.data);
                case TagTable:
                    return getVal!(LuaTable, TagTable)(data) is getVal!(LuaTable, TagTable)(rhs.data);
                case TagFunction:
                    return getVal!(LuaFunction, TagFunction)(data) is getVal!(LuaFunction, TagFunction)(rhs.data);
                case TagUserData:
                    return getVal!(LuaUserData, TagUserData)(data) is getVal!(LuaUserData, TagUserData)(rhs.data);
                case TagLightUserData:
                    return getVal!(LightUserData, TagLightUserData)(data).ptr == getVal!(LightUserData, TagLightUserData)(rhs.data).ptr;
                case TagThread:
                    return getVal!(LuaThread, TagThread)(data) is getVal!(LuaThread, TagThread)(rhs.data);
                default:
                    return false;
            }
        }

        // Numbers: integer and float can equal each other (1 == 1.0)
        if (tidA == TagLong && tidB == TagDouble) {
            double rd = getVal!(double, TagDouble)(rhs.data);
            long ri;
            if (floatToInteger(rd, ri)) {
                return getVal!(long, TagLong)(data) == ri;
            }
            return false;
        }
        if (tidA == TagDouble && tidB == TagLong) {
            double ld = getVal!(double, TagDouble)(data);
            long li;
            if (floatToInteger(ld, li)) {
                return li == getVal!(long, TagLong)(rhs.data);
            }
            return false;
        }

        return false;
    }

    /// Hash implementation compatible with Lua normalization (1 == 1.0)
    pragma(inline, true)
    size_t toHash() const nothrow @trusted {
        switch (data.typeIndex) {
            case TagNil:
                return 0;
            case TagBool:
                return getVal!(bool, TagBool)(data) ? 1231 : 1237;
            case TagLong:
                return cast(size_t)getVal!(long, TagLong)(data);
            case TagDouble: {
                double d = getVal!(double, TagDouble)(data);
                long i;
                if (floatToInteger(d, i)) {
                    return cast(size_t)i;
                }
                return hashOf(d);
            }
            case TagString:
                return hashOf(getVal!(string, TagString)(data));
            case TagSymbol:
                return getVal!(Symbol, TagSymbol)(data).toHash();
            case TagTable:
                return cast(size_t)cast(void*)getVal!(LuaTable, TagTable)(data);
            case TagFunction:
                return cast(size_t)cast(void*)getVal!(LuaFunction, TagFunction)(data);
            case TagUserData:
                return cast(size_t)cast(void*)getVal!(LuaUserData, TagUserData)(data);
            case TagLightUserData:
                return cast(size_t)getVal!(LightUserData, TagLightUserData)(data).ptr;
            case TagThread:
                return cast(size_t)cast(void*)getVal!(LuaThread, TagThread)(data);
            default:
                return 0;
        }
    }

    string toString() const {
        return toLuaString(this);
    }

    pragma(inline, true)
    LuaType typeOf() const nothrow @safe {
        switch (data.typeIndex) {
            case TagNil: return LuaType.Nil;
            case TagBool: return LuaType.Boolean;
            case TagLong: case TagDouble: return LuaType.Number;
            case TagString: return LuaType.String;
            case TagSymbol: return LuaType.Symbol;
            case TagTable: return LuaType.Table;
            case TagFunction: return LuaType.Function;
            case TagUserData: return LuaType.UserData;
            case TagLightUserData: return LuaType.LightUserData;
            case TagThread: return LuaType.Thread;
            default: return LuaType.Nil;
        }
    }

    string typeName() const {
        final switch (typeOf()) {
            case LuaType.Nil: return "nil";
            case LuaType.Boolean: return "boolean";
            case LuaType.Number: return "number";
            case LuaType.String: return "string";
            case LuaType.Symbol: return "symbol";
            case LuaType.Table: return "table";
            case LuaType.Function: return "function";
            case LuaType.UserData: return "userdata";
            case LuaType.LightUserData: return "userdata";
            case LuaType.Thread: return "thread";
        }
    }

    pragma(inline, true)
    bool isTruthy() const nothrow @safe {
        auto tid = data.typeIndex;
        if (tid == TagNil) return false;
        if (tid == TagBool) return getVal!(bool, TagBool)(data);
        return true;
    }

    pragma(inline, true)
    bool isNil() const nothrow @safe { return data.typeIndex == TagNil; }

    pragma(inline, true)
    bool isSymbol() const nothrow @safe { return data.typeIndex == TagSymbol; }

    pragma(inline, true)
    bool isBoolean() const nothrow @safe { return data.typeIndex == TagBool; }

    pragma(inline, true)
    bool isNumber() const nothrow @safe {
        auto tid = data.typeIndex;
        return tid == TagLong || tid == TagDouble;
    }

    pragma(inline, true)
    bool isInteger() const nothrow @safe { return data.typeIndex == TagLong; }

    pragma(inline, true)
    bool isFloat() const nothrow @safe { return data.typeIndex == TagDouble; }

    pragma(inline, true)
    bool isString() const nothrow @safe { return data.typeIndex == TagString; }

    pragma(inline, true)
    bool isTable() const nothrow @safe {
        return data.typeIndex == TagTable && getVal!(LuaTable, TagTable)(data) !is null;
    }

    pragma(inline, true)
    bool isFunction() const nothrow @safe {
        return data.typeIndex == TagFunction && getVal!(LuaFunction, TagFunction)(data) !is null;
    }

    pragma(inline, true)
    long asInteger() const nothrow @trusted {
        return getVal!(long, TagLong)(data);
    }

    pragma(inline, true)
    double asFloat() const nothrow @trusted {
        return getVal!(double, TagDouble)(data);
    }

    pragma(inline, true)
    string asString() const nothrow @trusted {
        return getVal!(string, TagString)(data);
    }

    pragma(inline, true)
    LuaTable asTable() const nothrow @trusted {
        return cast(LuaTable)getVal!(LuaTable, TagTable)(data);
    }

    pragma(inline, true)
    LuaFunction asFunction() const nothrow @trusted {
        return cast(LuaFunction)getVal!(LuaFunction, TagFunction)(data);
    }

    pragma(inline, true)
    bool asBool() const nothrow @trusted {
        return getVal!(bool, TagBool)(data);
    }

    pragma(inline, true)
    Symbol asSymbol() const nothrow @trusted {
        return getVal!(Symbol, TagSymbol)(data);
    }

    pragma(inline, true)
    LuaUserData asUserData() const nothrow @trusted {
        return cast(LuaUserData)getVal!(LuaUserData, TagUserData)(data);
    }

    pragma(inline, true)
    LightUserData asLightUserData() const nothrow @trusted {
        return cast(LightUserData)getVal!(LightUserData, TagLightUserData)(data);
    }

    pragma(inline, true)
    LuaThread asThread() const nothrow @trusted {
        return cast(LuaThread)getVal!(LuaThread, TagThread)(data);
    }
}

/// Free function UFCS pattern matching for LuaValue
auto match(Handlers...)(auto ref LuaValue val) {
    return sumtypeMatch!Handlers(cast()val.data);
}

/// Helper constructor functions
LuaValue luaNil() @safe pure nothrow {
    return LuaValue(Nil());
}

LuaValue luaValue(bool b) @safe pure nothrow {
    return LuaValue(b);
}

LuaValue luaValue(long i) @safe pure nothrow {
    return LuaValue(i);
}

LuaValue luaValue(double d) @safe pure nothrow {
    return LuaValue(d);
}

LuaValue luaValue(string s) @safe pure nothrow {
    return LuaValue(s);
}

LuaValue luaValue(Symbol s) @safe pure nothrow {
    return LuaValue(s);
}

LuaValue luaValue(LuaTable t) @safe pure nothrow {
    return LuaValue(t);
}

LuaValue luaValue(LuaFunction f) @safe pure nothrow {
    return LuaValue(f);
}

LuaValue luaValue(LuaUserData u) @safe pure nothrow {
    return LuaValue(u);
}

LuaValue luaValue(LightUserData l) @safe pure nothrow {
    return LuaValue(l);
}

LuaValue luaValue(LuaThread th) @safe pure nothrow {
    return LuaValue(th);
}

/// Free function helpers forwarding to LuaValue methods
pragma(inline, true) LuaType typeOf(LuaValue val) { return val.typeOf(); }
pragma(inline, true) string typeName(LuaValue val) { return val.typeName(); }
pragma(inline, true) bool isTruthy(LuaValue val) { return val.isTruthy(); }
pragma(inline, true) bool isNil(LuaValue val) { return val.isNil(); }
pragma(inline, true) bool isBoolean(LuaValue val) { return val.isBoolean(); }
pragma(inline, true) bool isNumber(LuaValue val) { return val.isNumber(); }
pragma(inline, true) bool isInteger(LuaValue val) { return val.isInteger(); }
pragma(inline, true) bool isFloat(LuaValue val) { return val.isFloat(); }
pragma(inline, true) bool isString(LuaValue val) { return val.isString(); }
pragma(inline, true) bool isSymbol(LuaValue val) { return val.isSymbol(); }
pragma(inline, true) bool isTable(LuaValue val) { return val.isTable(); }
pragma(inline, true) bool isFunction(LuaValue val) { return val.isFunction(); }

/// Check if string is a valid Lua identifier
bool isValidLuaIdentifier(string s) @safe pure nothrow {
    if (s.length == 0) return false;
    import std.ascii : isAlpha, isAlphaNum;
    if (s[0] != '_' && !isAlpha(s[0])) return false;
    foreach (c; s[1 .. $]) {
        if (c != '_' && !isAlphaNum(c)) return false;
    }
    return true;
}

/// Escape string for quoted representation in toLuaString
string escapeLuaString(string s) @safe pure {
    import std.array : appender;
    import std.format : formattedWrite;
    auto app = appender!string();
    foreach (char c; s) {
        switch (c) {
            case '\"': app.put(`\"`); break;
            case '\\': app.put(`\\`); break;
            case '\a': app.put(`\a`); break;
            case '\b': app.put(`\b`); break;
            case '\f': app.put(`\f`); break;
            case '\n': app.put(`\n`); break;
            case '\r': app.put(`\r`); break;
            case '\t': app.put(`\t`); break;
            case '\v': app.put(`\v`); break;
            default:
                if (c < 32 || c >= 127) {
                    formattedWrite(app, `\%03d`, cast(ubyte)c);
                } else {
                    app.put(c);
                }
                break;
        }
    }
    return app.data;
}

/// Normalize number keys: if a float equals an integer, convert it to long
pragma(inline, true)
LuaValue normalizeKey(LuaValue key) {
    if (key.isFloat()) {
        double d = key.asFloat;
        long i;
        if (floatToInteger(d, i)) return LuaValue(i);
    }
    return key;
}

/// Check mathematical equality according to Lua 5.4 rules
pragma(inline, true)
bool luaRawEqual(LuaValue a, LuaValue b) {
    return a.opEquals(b);
}

/// Exact mixed integer/float ordering without rounding integers through double.
bool luaNumberLess(LuaValue left, LuaValue right) {
    if (left.isInteger && right.isInteger)
        return left.asInteger < right.asInteger;
    if (left.isFloat && right.isFloat)
        return left.asFloat < right.asFloat;
    bool integerFirst = left.isInteger;
    long integer = integerFirst ? left.asInteger : right.asInteger;
    double number = integerFirst ? right.asFloat : left.asFloat;
    if (isNaN(number)) return false;
    if (number >= 0x1p63) return integerFirst;
    if (number < -0x1p63) return !integerFirst;
    long truncated = cast(long)number;
    if (integer != truncated) return integerFirst ? integer < truncated : truncated < integer;
    return integerFirst ? cast(double)truncated < number : number < cast(double)truncated;
}

bool luaNumberLessEqual(LuaValue left, LuaValue right) {
    return luaRawEqual(left, right) || luaNumberLess(left, right);
}

/// Parse Lua numerals with integer/float syntax, hex wrapping and full consumption.
bool parseLuaNumber(string input, out LuaValue number) {
    import std.ascii : isWhite, isDigit;
    import std.string : toStringz;
    import core.stdc.stdlib : strtod;
    size_t first, last = input.length;
    while (first < last && isWhite(input[first])) ++first;
    while (last > first && isWhite(input[last - 1])) --last;
    auto text = input[first .. last];
    if (!text.length) return false;
    size_t index;
    bool negative;
    if (text[index] == '+' || text[index] == '-') {
        negative = text[index] == '-';
        if (++index == text.length) return false;
    }
    if (!isDigit(text[index]) && text[index] != '.') return false;
    bool hexadecimal = text.length - index >= 2 && text[index] == '0' &&
        (text[index + 1] == 'x' || text[index + 1] == 'X');
    size_t digits = index + (hexadecimal ? 2 : 0);
    ulong value;
    bool integral = digits < text.length;
    ulong limit = negative ? 1UL << 63 : cast(ulong)long.max;
    for (size_t position = digits; integral && position < text.length; ++position) {
        char ch = text[position];
        int digit = ch >= '0' && ch <= '9' ? ch - '0' :
            hexadecimal && ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 :
            hexadecimal && ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1;
        if (digit < 0) { integral = false; break; }
        if (hexadecimal) value = value * 16 + digit; // Lua wraps hex integers.
        else {
            if (value > (limit - digit) / 10) { integral = false; break; }
            value = value * 10 + digit;
        }
    }
    if (integral) {
        number = LuaValue(cast(long)(negative ? 0UL - value : value));
        return true;
    }
    auto ctext = text.toStringz;
    immutable(char)* end;
    double floating = strtod(ctext, &end);
    if (end == ctext || end - ctext != text.length) {
        import core.stdc.locale : localeconv;
        import std.array : replace;
        char decimalPoint = localeconv().decimal_point[0];
        if (decimalPoint == '.') return false;
        auto localized = text.replace(".", [decimalPoint]);
        ctext = localized.toStringz;
        floating = strtod(ctext, &end);
        if (end == ctext || end - ctext != localized.length) return false;
    }
    number = LuaValue(floating);
    return true;
}

/// String representation for Lua values
/// Formats a float like lua_Number2str ("%.14g") plus a ".0" suffix when it reads as an integer.
string luaFloatToString(double d) {
    import core.stdc.stdio : snprintf;
    char[64] buffer;
    auto length = snprintf(buffer.ptr, buffer.length, "%.14g", d);
    string text = buffer[0 .. length].idup;
    foreach (ch; text) if (!(ch == '-' || (ch >= '0' && ch <= '9'))) return text;
    return text ~ ".0";
}

string toLuaString(LuaValue val) {
    switch (val.data.typeIndex) {
        case TagNil: return "nil";
        case TagBool: return val.asBool ? "true" : "false";
        case TagLong: return val.asInteger.to!string;
        case TagDouble: return luaFloatToString(val.asFloat);
        case TagString: return val.asString;
        case TagSymbol: {
            auto s = val.asSymbol;
            if (isValidLuaIdentifier(s.name)) {
                return ":" ~ s.name;
            }
            return ":\"" ~ escapeLuaString(s.name) ~ "\"";
        }
        case TagTable: return format("table: 0x%x", cast(size_t)cast(void*)val.asTable);
        case TagFunction: return format("function: 0x%x", cast(size_t)cast(void*)val.asFunction);
        case TagUserData: return format("userdata: 0x%x", cast(size_t)cast(void*)val.asUserData);
        case TagLightUserData: return format("userdata: %s", val.asLightUserData.ptr);
        case TagThread: return format("thread: 0x%x", cast(size_t)cast(void*)val.asThread);
        default: return "nil";
    }
}

/// Abstract base class for callable Lua functions
class LuaFunction {
    string name;
    /// True exactly for `LuaClosure` instances; lets the VM downcast without a checked cast.
    bool isLuaClosure;
    /// True for `LuaNativeFunction` and its subclasses.
    bool isNativeFunction;
    /// True for natives that neither keep nor modify their argument array, so a call may pass a
    /// view of the caller's registers instead of a copy.
    bool borrowsArgs;
    /// Optional allocation-free entry point (see dlua.lib.fastcall); null for most functions.
    int function(void* state, LuaValue[] registers, int base, int numArgs) fastCall;

    this(string name = "") {
        this.name = name;
    }

    abstract LuaValue[] call(void* state, LuaValue[] args);
}

/// Native D function callable from Lua
class LuaNativeFunction : LuaFunction {
    alias NativeDelegate = LuaValue[] delegate(void* state, LuaValue[] args);
    NativeDelegate fn;
    bool nonYielding;
    LuaValue[] debugUpvalues; // C closures expose their upvalues (named "") to debug.getupvalue
    bool analysisSafeToCopy; // Only for engine factories with no captured live objects.

    this(NativeDelegate fn, string name = "", bool nonYielding = false) {
        super(name);
        this.isNativeFunction = true;
        this.fn = fn;
        this.nonYielding = nonYielding;
    }

    override LuaValue[] call(void* state, LuaValue[] args) {
        import dlua.fiber : DluaFiber, currentLuaFiber;
        import core.thread : Fiber;
        auto fiber = currentLuaFiber();
        bool previous = fiber !is null && fiber.isYieldAllowed;
        if (fiber !is null && nonYielding) fiber.isYieldAllowed = false;
        scope(exit) if (fiber !is null && nonYielding) fiber.isYieldAllowed = previous && !fiber.closing;
        return fn(state, args);
    }
}

/// Userdata holding arbitrary D objects with an optional metatable
class LuaUserData {
    Object payload;
    void* rawPayload;
    LuaTable metatable;
    LuaValue[] userValues; // indexed user values (debug.setuservalue)

    this(Object obj, LuaTable mt = null) {
        this.payload = obj;
        this.metatable = mt;
    }

    this(void* raw, LuaTable mt = null) {
        this.rawPayload = raw;
        this.metatable = mt;
    }
}

class ErrorBoundary {
    LuaValue handler;
    bool handlesErrors;
    bool active;
    this(bool handlesErrors, LuaValue handler = LuaValue.init) { this.handlesErrors = handlesErrors; this.handler = handler; }
}

/// Thread / Coroutine representation
class LuaThread {
    LuaFunction entryFunction;
    LuaTable environment;
    string status; // "suspended", "running", "normal", "dead"
    Object fiber;
    int closeDepth;
    ErrorBoundary[] errorBoundaries;   // the active boundaries: a prefix of boundaryStore
    private ErrorBoundary[] boundaryStore;

    /// Enters a protected call. Boundary objects are reused, so a pcall allocates none.
    ErrorBoundary pushBoundary(bool handlesErrors, LuaValue handler = LuaValue.init) {
        size_t depth = errorBoundaries.length;
        if (depth == boundaryStore.length) boundaryStore.length = depth * 2 + 8;
        auto boundary = boundaryStore[depth];
        if (boundary is null) boundary = boundaryStore[depth] = new ErrorBoundary(handlesErrors, handler);
        else { boundary.handlesErrors = handlesErrors; boundary.handler = handler; boundary.active = false; }
        errorBoundaries = boundaryStore[0 .. depth + 1];
        return boundary;
    }

    void popBoundary() {
        size_t depth = errorBoundaries.length - 1;
        boundaryStore[depth].handler = LuaValue.init;
        errorBoundaries = boundaryStore[0 .. depth];
    }
    LuaFunction hookFunction;
    int hookMask;
    int hookCount;
    int hookRemaining;
    bool hookActive;
    // Bounded reusable register buffers, indexed by active VM depth. Active
    // buffers are removed from the cache and returned only after upvalue close.
    LuaValue[][] registerBuffers;
    // Bump-allocated registers of the native executor's frames (see VM.executeFrame).
    LuaValue[] valueStack;
    size_t valueTop;
    size_t registerDepth;
    // Reusable return value buffers per VM call depth
    LuaValue[][] returnBuffers;
    // Arguments of a pending proper tail call, consumed by the callee's prologue.
    LuaValue[] tailBuffer;
    // Parked caller frames of Lua → Lua calls run inline by VM.executeFrame (SavedFrame objects).
    Object[] inlineFrames;
    size_t inlineTop;
    // The pending proper tail call itself (see VM.runTailCalls); `tailWorld` is a logic.world.World.
    LuaValue tailCallee;
    LuaValue[] tailArguments;
    Object tailWorld;
    int cCalls;               // nested VM re-entries from native code (emulates nCcalls)
    size_t stackSlots;        // Lua stack slots in use (emulates LUAI_MAXSTACK)
    bool overflowed;          // a stack overflow error is being handled
    size_t nativeStackLimit;  // lowest usable native stack address (0 = unchecked)
    size_t nativeSoftLimit;   // raises "stack overflow" here; the rest is reserved for error handling

    this(LuaFunction entry = null) {
        this.entryFunction = entry;
        this.status = "suspended";
    }
}
