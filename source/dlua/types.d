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

    /// Full Lua-compliant raw equality
    bool opEquals(ref const LuaValue rhs) const {
        return opEquals(cast(LuaValue)rhs);
    }

    bool opEquals(LuaValue rhs) const {
        auto mutableThis = cast(LuaValue)this;

        // Numbers: integer and float can equal each other (1 == 1.0)
        if (mutableThis.isNumber() && rhs.isNumber()) {
            if (mutableThis.isInteger() && rhs.isInteger()) {
                return mutableThis.match!((long a) => a, _ => 0L) == rhs.match!((long b) => b, _ => 0L);
            }
            if (mutableThis.isInteger() && rhs.isFloat()) {
                double rd = rhs.match!((double d) => d, _ => 0.0);
                long ri;
                if (floatToInteger(rd, ri)) {
                    return mutableThis.match!((long a) => a, _ => 0L) == ri;
                }
                return false;
            }
            if (mutableThis.isFloat() && rhs.isInteger()) {
                double ld = mutableThis.match!((double d) => d, _ => 0.0);
                long li;
                if (floatToInteger(ld, li)) {
                    return li == rhs.match!((long b) => b, _ => 0L);
                }
                return false;
            }
            double da = mutableThis.match!((double d) => d, _ => 0.0);
            double db = rhs.match!((double d) => d, _ => 0.0);
            if (isNaN(da) || isNaN(db)) return false;
            return da == db;
        }

        // Types must match for equality
        if (mutableThis.typeOf() != rhs.typeOf()) return false;

        return sumtypeMatch!(
            (Nil _) => true,
            (bool va) => va == sumtypeMatch!((bool vb) => vb, _ => false)(cast()rhs.data),
            (string sa) => sa == sumtypeMatch!((string sb) => sb, _ => "")(cast()rhs.data),
            (Symbol sa) => sa == sumtypeMatch!((Symbol sb) => sb, _ => Symbol.init)(cast()rhs.data),
            (LuaTable ta) => ta is sumtypeMatch!((LuaTable tb) => tb, _ => null)(cast()rhs.data),
            (LuaFunction fa) => fa is sumtypeMatch!((LuaFunction fb) => fb, _ => null)(cast()rhs.data),
            (LuaUserData ua) => ua is sumtypeMatch!((LuaUserData ub) => ub, _ => null)(cast()rhs.data),
            (LightUserData la) => la.ptr == sumtypeMatch!((LightUserData lb) => lb.ptr, _ => null)(cast()rhs.data),
            (LuaThread tha) => tha is sumtypeMatch!((LuaThread thb) => thb, _ => null)(cast()rhs.data),
            _ => false
        )(cast()mutableThis.data);
    }

    /// Hash implementation compatible with Lua normalization (1 == 1.0)
    size_t toHash() const nothrow @trusted {
        auto mutableThis = cast(LuaValue)this;
        return sumtypeMatch!(
            (Nil _) => cast(size_t)0,
            (bool b) => cast(size_t)(b ? 1231 : 1237),
            (long i) => cast(size_t)i,
            (double d) {
                long i;
                if (floatToInteger(d, i)) {
                    return cast(size_t)i;
                }
                return typeid(double).getHash(&d);
            },
            (string s) => typeid(string).getHash(&s),
            (Symbol s) => s.toHash(),
            (LuaTable t) => cast(size_t)cast(void*)t,
            (LuaFunction f) => cast(size_t)cast(void*)f,
            (LuaUserData u) => cast(size_t)cast(void*)u,
            (LightUserData l) => cast(size_t)l.ptr,
            (LuaThread th) => cast(size_t)cast(void*)th
        )(cast()mutableThis.data);
    }

    string toString() const {
        return toLuaString(this);
    }

    LuaType typeOf() const {
        return sumtypeMatch!(
            (Nil _) => LuaType.Nil,
            (bool _) => LuaType.Boolean,
            (long _) => LuaType.Number,
            (double _) => LuaType.Number,
            (string _) => LuaType.String,
            (Symbol _) => LuaType.Symbol,
            (LuaTable _) => LuaType.Table,
            (LuaFunction _) => LuaType.Function,
            (LuaUserData _) => LuaType.UserData,
            (LightUserData _) => LuaType.LightUserData,
            (LuaThread _) => LuaType.Thread
        )(cast()data);
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

    bool isTruthy() const {
        return sumtypeMatch!(
            (Nil _) => false,
            (bool b) => b,
            _ => true
        )(cast()data);
    }

    bool isNil() const {
        return sumtypeMatch!(
            (Nil _) => true,
            _ => false
        )(cast()data);
    }

    bool isSymbol() const {
        return sumtypeMatch!(
            (Symbol _) => true,
            _ => false
        )(cast()data);
    }

    bool isBoolean() const {
        return sumtypeMatch!(
            (bool _) => true,
            _ => false
        )(cast()data);
    }

    bool isNumber() const {
        return sumtypeMatch!(
            (bool _) => false,
            (long _) => true,
            (double _) => true,
            _ => false
        )(cast()data);
    }

    bool isInteger() const {
        return sumtypeMatch!(
            (bool _) => false,
            (long _) => true,
            _ => false
        )(cast()data);
    }

    bool isFloat() const {
        return sumtypeMatch!(
            (bool _) => false,
            (long _) => false,
            (double _) => true,
            _ => false
        )(cast()data);
    }

    bool isString() const {
        return sumtypeMatch!(
            (string _) => true,
            _ => false
        )(cast()data);
    }

    bool isTable() const {
        return sumtypeMatch!(
            (LuaTable t) => t !is null,
            _ => false
        )(cast()data);
    }

    bool isFunction() const {
        return sumtypeMatch!(
            (LuaFunction f) => f !is null,
            _ => false
        )(cast()data);
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
LuaType typeOf(LuaValue val) { return val.typeOf(); }
string typeName(LuaValue val) { return val.typeName(); }
bool isTruthy(LuaValue val) { return val.isTruthy(); }
bool isNil(LuaValue val) { return val.isNil(); }
bool isBoolean(LuaValue val) { return val.isBoolean(); }
bool isNumber(LuaValue val) { return val.isNumber(); }
bool isInteger(LuaValue val) { return val.isInteger(); }
bool isFloat(LuaValue val) { return val.isFloat(); }
bool isString(LuaValue val) { return val.isString(); }
bool isSymbol(LuaValue val) { return val.isSymbol(); }
bool isTable(LuaValue val) { return val.isTable(); }
bool isFunction(LuaValue val) { return val.isFunction(); }

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
LuaValue normalizeKey(LuaValue key) {
    if (key.isFloat()) {
        double d = key.match!((double v) => v, _ => 0.0);
        long i;
        if (floatToInteger(d, i)) return LuaValue(i);
    }
    return key;
}

/// Check mathematical equality according to Lua 5.4 rules
bool luaRawEqual(LuaValue a, LuaValue b) {
    return a.opEquals(b);
}

/// Exact mixed integer/float ordering without rounding integers through double.
bool luaNumberLess(LuaValue left, LuaValue right) {
    if (isInteger(left) && isInteger(right))
        return left.match!((long n) => n, _ => 0L) < right.match!((long n) => n, _ => 0L);
    if (isFloat(left) && isFloat(right))
        return left.match!((double n) => n, _ => 0.0) < right.match!((double n) => n, _ => 0.0);
    bool integerFirst = isInteger(left);
    long integer = (integerFirst ? left : right).match!((long n) => n, _ => 0L);
    double number = (integerFirst ? right : left).match!((double n) => n, _ => 0.0);
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
    return val.match!(
        (Nil _) => "nil",
        (bool b) => b ? "true" : "false",
        (long i) => i.to!string,
        (double d) => luaFloatToString(d),
        (string s) => s,
        (Symbol s) {
            if (isValidLuaIdentifier(s.name)) {
                return ":" ~ s.name;
            }
            return ":\"" ~ escapeLuaString(s.name) ~ "\"";
        },
        (LuaTable t) => format("table: 0x%x", cast(size_t)cast(void*)t),
        (LuaFunction f) => format("function: 0x%x", cast(size_t)cast(void*)f),
        (LuaUserData u) => format("userdata: 0x%x", cast(size_t)cast(void*)u),
        (LightUserData l) => format("userdata: %s", l.ptr),
        (LuaThread th) => format("thread: 0x%x", cast(size_t)cast(void*)th)
    );
}

/// Abstract base class for callable Lua functions
class LuaFunction {
    string name;

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
        this.fn = fn;
        this.nonYielding = nonYielding;
    }

    override LuaValue[] call(void* state, LuaValue[] args) {
        import dlua.fiber : DluaFiber;
        import core.thread : Fiber;
        auto fiber = cast(DluaFiber)Fiber.getThis();
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
    ErrorBoundary[] errorBoundaries;
    LuaFunction hookFunction;
    int hookMask;
    int hookCount;
    int hookRemaining;
    bool hookActive;
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
