/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.lib.string;

import varis.types;
import varis.table;
import varis.state;
import varis.vm;
import varis.pattern;
import varis.lib.pack : packValues, packedSize, unpackValues;
import varis.lib.auxlib;
import varis.lib.base : tostringValue;
import varis.exception : LuaException;
import std.array : appender;
import std.conv : to;
import core.stdc.stdio : snprintf;
import std.string : toStringz;

private size_t posRelatI(long pos, size_t len) {
    if (pos > 0)
        return cast(size_t) pos;
    if (pos == 0)
        return 1;
    if (pos < -cast(long) len)
        return 1;
    return len + cast(size_t) pos + 1;
}

private bool getEndPos(LuaState L, LuaValue[] a, int arg, long def, size_t len, out size_t result) {
    long pos;
    if (!argOptInteger(L, a, arg, def, pos))
        return false;
    if (pos > cast(long) len)
        result = len;
    else if (pos >= 0)
        result = cast(size_t) pos;
    else if (pos < -cast(long) len)
        result = 0;
    else
        result = len + cast(size_t) pos + 1;
    return true;
}

private bool failText(LuaState L, string message) {
    raise(L, new LuaException(message));
    return false;
}

private bool hasSpecials(string pattern) {
    foreach (c; pattern) {
        switch (c) {
        case '^', '$', '*', '+', '?', '.', '(', ')', '[', ']', '%', '-':
            return true;
        default:
            break;
        }
    }
    return false;
}

private bool oneCapture(LuaState L, ref MatchState ms, int i, size_t s, ptrdiff_t e, out LuaValue result) {
    if (i >= ms.level) {
        if (i != 0)
            return failText(L, "invalid capture index %" ~ (i + 1).to!string);
        result = LuaValue(ms.src[s .. cast(size_t) e]);
        return true;
    }
    auto cap = ms.capture[i];
    if (cap.len == CAP_UNFINISHED)
        return failText(L, "unfinished capture");
    if (cap.len == CAP_POSITION)
        result = LuaValue(cast(long)(cap.init + 1));
    else
        result = LuaValue(ms.src[cast(size_t) cap.init .. cast(size_t)(cap.init + cap.len)]);
    return true;
}

private bool pushCaptures(LuaState L, ref MatchState ms, bool hasWhole, size_t s, ptrdiff_t e, ref LuaValue[] result) {
    int n = (ms.level == 0 && hasWhole) ? 1 : ms.level;
    foreach (i; 0 .. n) {
        LuaValue v;
        if (!oneCapture(L, ms, i, s, e, v))
            return false;
        result ~= v;
    }
    return true;
}

private LuaValue[] strFindAux(LuaState L, LuaValue[] a, bool find) {
    string s, p;
    long initArg;
    if (!argString(L, a, 1, s) || !argString(L, a, 2, p) || !argOptInteger(L, a, 3, 1, initArg))
        return null;
    size_t init = posRelatI(initArg, s.length) - 1;
    if (init > s.length)
        return [luaNil()];
    if (find && (a.length > 3 && isTruthy(a[3]) || !hasSpecials(p))) {
        if (p.length == 0)
            return [LuaValue(cast(long)(init + 1)), LuaValue(cast(long) init)];
        import std.string : indexOf, CaseSensitive;

        auto idx = s[init .. $].indexOf(p, CaseSensitive.yes);
        if (idx >= 0)
            return [LuaValue(cast(long)(init + idx + 1)), LuaValue(cast(long)(init + idx + p.length))];
        return [luaNil()];
    }
    bool anchor = p.length && p[0] == '^';
    string pat = anchor ? p[1 .. $] : p;
    size_t s1 = init;
    do {
        auto ms = MatchState(s, pat);
        auto res = Pattern.matchLoop(ms, s1, 0);
        if (res != -1) {
            LuaValue[] result;
            if (find)
                result = [LuaValue(cast(long)(s1 + 1)), LuaValue(cast(long) res)];
            if (!pushCaptures(L, ms, !find, s1, res, result))
                return null;
            return result;
        }
        ++s1;
    }
    while (s1 <= s.length && !anchor);
    return [luaNil()];
}

/// Returns -1 after reporting an error, else 1 when the replacement was used and 0 when the match was kept.
private int addValue(LuaState L, ref MatchState ms, ref typeof(appender!string()) b, size_t s, ptrdiff_t e, LuaValue repl, int arg) {
    LuaValue value;
    if (isFunction(repl)) {
        LuaValue[] captures;
        if (!pushCaptures(L, ms, true, s, e, captures))
            return -1;
        auto results = VM.callValue(L, repl, captures);
        value = results.length ? results[0] : luaNil();
    } else if (isTable(repl)) {
        LuaValue key;
        if (!oneCapture(L, ms, 0, s, e, key))
            return -1;
        value = VM.getTable(L, repl, key);
    } else {
        string r = toLuaString(repl);
        size_t i = 0;
        while (i < r.length) {
            if (r[i] != '%') {
                b.put(r[i++]);
                continue;
            }
            ++i;
            if (i >= r.length)
                return failText(L, "invalid use of '%' in replacement string") ? 1 : -1;
            char c = r[i++];
            if (c == '%')
                b.put('%');
            else if (c == '0')
                b.put(ms.src[s .. cast(size_t) e]);
            else if (c >= '1' && c <= '9') {
                LuaValue cap;
                if (!oneCapture(L, ms, c - '1', s, e, cap))
                    return -1;
                b.put(toLuaString(cap));
            } else
                return failText(L, "invalid use of '%' in replacement string") ? 1 : -1;
        }
        return 1;
    }
    if (!isTruthy(value)) {
        b.put(ms.src[s .. cast(size_t) e]);
        return 0;
    }
    if (!isString(value) && !isNumber(value))
        return failText(L, "invalid replacement value (a " ~ objectTypeName(L, value) ~ ")") ? 1 : -1;
    b.put(toLuaString(value));
    return 1;
}

private LuaValue[] strGsub(LuaState L, LuaValue[] a) {
    string src, p;
    if (!argString(L, a, 1, src) || !argString(L, a, 2, p))
        return null;
    if (a.length < 3 || !(isNumber(a[2]) || isString(a[2]) || isTable(a[2]) || isFunction(a[2]))) {
        typeFail(L, a, 3, "string/function/table");
        return null;
    }
    auto repl = a[2];
    long maxS;
    if (!argOptInteger(L, a, 4, cast(long) src.length + 1, maxS))
        return null;
    bool anchor = p.length && p[0] == '^';
    string pat = anchor ? p[1 .. $] : p;
    size_t pos = 0;
    ptrdiff_t lastMatch = -1;
    long n = 0;
    bool changed = false;
    auto b = appender!string();
    // One match state for the whole call (its capture array is large); text between matches is
    // copied in runs, from `flushed`.
    auto ms = MatchState(src, pat);
    size_t flushed = 0;
    while (n < maxS) {
        ms.level = 0;
        ms.matchdepth = 200;
        auto e = Pattern.matchLoop(ms, pos, 0);
        if (e != -1 && e != lastMatch) {
            ++n;
            if (flushed < pos)
                b.put(src[flushed .. pos]);
            int used = addValue(L, ms, b, pos, e, repl, 3);
            if (used < 0)
                return null;
            changed = used > 0 || changed;
            pos = lastMatch = flushed = cast(size_t) e;
            // addValue copies the original text when the replacement is kept.
        } else if (pos < src.length) {
            ++pos;
        } else
            break;
        if (anchor)
            break;
    }
    if (!changed)
        return [LuaValue(src), LuaValue(n)];
    if (flushed < src.length)
        b.put(src[flushed .. $]);
    return [LuaValue(b.data), LuaValue(n)];
}

private string quoteString(string s) {
    auto b = appender!string();
    b.put('"');
    foreach (i, c; s) {
        if (c == '"' || c == '\\' || c == '\n') {
            b.put('\\');
            b.put(c);
        } else if (c < 32 || c == 127) {
            bool nextDigit = i + 1 < s.length && s[i + 1] >= '0' && s[i + 1] <= '9';
            char[16] buffer;
            auto len = snprintf(buffer.ptr, buffer.length, nextDigit ? "\\%03d" : "\\%d", cast(int) c);
            b.put(buffer[0 .. len]);
        } else
            b.put(c);
    }
    b.put('"');
    return b.data;
}

private string formatDouble(string form, double value) {
    char[512] stack;
    auto zform = form.toStringz;
    auto len = snprintf(stack.ptr, stack.length, zform, value);
    if (len < stack.length)
        return stack[0 .. len].idup;
    auto heap = new char[len + 1];
    snprintf(heap.ptr, heap.length, zform, value);
    return heap[0 .. len].idup;
}

private string quoteFloat(double n) {
    import std.math : isNaN, isInfinity;

    if (n == double.infinity)
        return "1e9999";
    if (n == -double.infinity)
        return "-1e9999";
    if (isNaN(n))
        return "(0/0)";
    auto text = formatDouble("%a", n);
    if (indexOfChar(text, '.') < 0) {
        import core.stdc.locale : localeconv;

        char point = localeconv().decimal_point[0];
        auto at = indexOfChar(text, point);
        if (at >= 0 && point != '.')
            text = text[0 .. at] ~ "." ~ text[at + 1 .. $];
    }
    return text;
}

private bool checkFormat(LuaState L, string form, string flags, bool precision) {
    size_t i = 1;
    while (i < form.length && flags.indexOfChar(form[i]) >= 0)
        ++i;
    if (i < form.length && form[i] != '0') {
        if (i < form.length && isDigitChar(form[i])) {
            ++i;
            if (i < form.length && isDigitChar(form[i]))
                ++i;
        }
        if (i < form.length && form[i] == '.' && precision) {
            ++i;
            if (i < form.length && isDigitChar(form[i])) {
                ++i;
                if (i < form.length && isDigitChar(form[i]))
                    ++i;
            }
        }
    }
    if (i >= form.length || !isAlphaChar(form[i]))
        return failText(L, "invalid conversion specification: '" ~ form ~ "'");
    return true;
}

private bool isDigitChar(char c) {
    return c >= '0' && c <= '9';
}

private bool isAlphaChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

private ptrdiff_t indexOfChar(string s, char c) {
    foreach (i, ch; s)
        if (ch == c)
            return i;
    return -1;
}

private string lenmod(string form, string mod) {
    return form[0 .. $ - 1] ~ mod ~ form[$ - 1];
}

private string formatInteger(string form, long n) {
    char[512] buffer;
    auto len = snprintf(buffer.ptr, buffer.length, form.toStringz, n);
    return buffer[0 .. len].idup;
}

private LuaValue[] strFormat(LuaState L, LuaValue[] a) {
    string fmt;
    if (!argString(L, a, 1, fmt))
        return null;
    int arg = 1;
    auto b = appender!string();
    size_t i = 0;
    while (i < fmt.length) {
        if (fmt[i] != '%') {
            b.put(fmt[i++]);
            continue;
        }
        ++i;
        if (i < fmt.length && fmt[i] == '%') {
            b.put('%');
            ++i;
            continue;
        }
        if (++arg > a.length)
            return argFail(L, arg, "no value");
        // getformat
        size_t len = 0;
        while (i + len < fmt.length && "-+#0 123456789.".indexOfChar(fmt[i + len]) >= 0)
            ++len;
        ++len;
        if (len >= 22)
            return failText(L, "invalid format (too long)") ? null : null;
        string spec = i + len <= fmt.length ? fmt[i .. i + len] : fmt[i .. $];
        string form = "%" ~ spec;
        i += spec.length;
        char conv = spec.length ? spec[$ - 1] : '\0';
        if (i + 0 > fmt.length || spec.length != len) { /* ran past the end */
            failText(L, "invalid conversion '" ~ form ~ "' to 'format'");
            return null;
        }
        switch (conv) {
        case 'c':
            long c;
            if (!checkFormat(L, form, "-", false) || !argInteger(L, a, arg, c))
                return null;
            b.put(cformatChar(form, cast(int) c));
            break;
        case 'd', 'i', 'u', 'o', 'x', 'X': {
                string flags = (conv == 'd' || conv == 'i') ? "-+0 " : conv == 'u' ? "-0" : "-#0";
                long n;
                if (!argInteger(L, a, arg, n) || !checkFormat(L, form, flags, true))
                    return null;
                b.put(formatInteger(lenmod(form, "ll"), n));
                break;
            }
        case 'a', 'A':
            double x;
            if (!checkFormat(L, form, "-+#0 ", true) || !argNumber(L, a, arg, x))
                return null;
            b.put(formatDouble(form, x));
            break;
        case 'f', 'e', 'E', 'g', 'G': {
                double n;
                if (!argNumber(L, a, arg, n) || !checkFormat(L, form, "-+#0 ", true))
                    return null;
                b.put(formatDouble(form, n));
                break;
            }
        case 'p': {
                if (!checkFormat(L, form, "-", false))
                    return null;
                void* ptr = pointerOf(a[arg - 1]);
                if (ptr is null) {
                    form = form[0 .. $ - 1] ~ "s";
                    b.put(cformatString(form, "(null)"));
                } else {
                    b.put(cformatString(form[0 .. $ - 1] ~ "s", "0x" ~ (cast(size_t) ptr).to!string(16)));
                }
                break;
            }
        case 'q': {
                if (form.length != 2) {
                    failText(L, "specifier '%q' cannot have modifiers");
                    return null;
                }
                auto v = a[arg - 1];
                if (isString(v))
                    b.put(quoteString(v.match!((string s) => s, _ => "")));
                else if (isInteger(v)) {
                    long n = v.match!((long x) => x, _ => 0L);
                    b.put(n == long.min ? "0x8000000000000000" : n.to!string);
                } else if (isFloat(v)) {
                    double d = v.match!((double x) => x, _ => 0.0);
                    long asInt;
                    b.put(quoteFloat(d));
                } else if (isNil(v) || isBoolean(v))
                    b.put(toLuaString(v));
                else
                    return argFail(L, arg, "value has no literal form");
                break;
            }
        case 's': {
                string s = tostringValue(L, a[arg - 1]);
                if (form.length == 2)
                    b.put(s);
                else {
                    import std.string : indexOf;

                    if (s.indexOf('\0') >= 0)
                        return argFail(L, arg, "string contains zeros");
                    if (!checkFormat(L, form, "-", true))
                        return null;
                    if (form.indexOfChar('.') < 0 && s.length >= 100)
                        b.put(s);
                    else
                        b.put(cformatString(form, s));
                }
                break;
            }
        default:
            failText(L, "invalid conversion '" ~ form ~ "' to 'format'");
            return null;
        }
    }
    return [LuaValue(b.data)];
}

private string cformatChar(string form, int c) {
    char[512] buffer;
    auto len = snprintf(buffer.ptr, buffer.length, form.toStringz, c);
    return buffer[0 .. len].idup;
}

private string cformatString(string form, string s) {
    char[] buffer = new char[s.length + 512];
    auto len = snprintf(buffer.ptr, buffer.length, form.toStringz, s.toStringz);
    return buffer[0 .. len].idup;
}

/// Short strings are interned in C Lua, so equal short strings share an address.
private void* internedStringAddress(string s) {
    if (s.length > 40)
        return cast(void*) s.ptr;
    ulong h = 14695981039346656037UL;
    foreach (c; s) {
        h ^= cast(ubyte) c;
        h *= 1099511628211UL;
    }
    return cast(void*)(0x100000000000UL | ((h & 0xFFFFFFFFFFUL) << 4));
}

private void* pointerOf(LuaValue v) {
    return v.match!(
            (LuaTable t) => cast(void*) t,
            (LuaFunction f) => cast(void*) f,
            (LuaUserData u) => cast(void*) u,
            (LightUserData l) => l.ptr,
            (LuaThread th) => cast(void*) th,
            (string s) => internedStringAddress(s),
            _ => cast(void*) null
    );
}

void openStringLib(LuaState state) {
    auto strTable = new LuaTable();

    strTable.register("pack", (LuaState L, LuaValue[] a) => packValues(L, a));
    strTable.register("packsize", (LuaState L, LuaValue[] a) => packedSize(L, a));
    strTable.register("unpack", (LuaState L, LuaValue[] a) => unpackValues(L, a));

    strTable.register("len", (LuaState L, LuaValue[] a) {
        string s;
        if (!argString(L, a, 1, s))
            return null;
        return [LuaValue(cast(long) s.length)];
    });

    strTable.register("sub", (LuaState L, LuaValue[] a) {
        string s;
        long first;
        size_t end;
        if (!argString(L, a, 1, s) || !argInteger(L, a, 2, first) || !getEndPos(L, a, 3, -1, s.length, end))
            return null;
        size_t start = posRelatI(first, s.length);
        if (start > end)
            return [LuaValue("")];
        return [LuaValue(s[start - 1 .. end])];
    });

    strTable.register("reverse", (LuaState L, LuaValue[] a) {
        string s;
        if (!argString(L, a, 1, s))
            return null;
        auto buffer = new char[s.length];
        foreach (i, c; s)
            buffer[s.length - 1 - i] = c;
        return [LuaValue(cast(string) buffer)];
    });

    strTable.register("lower", (LuaState L, LuaValue[] a) {
        string s;
        if (!argString(L, a, 1, s))
            return null;
        auto buffer = s.dup;
        foreach (ref c; buffer)
            if (c >= 'A' && c <= 'Z')
                c += 32;
        return [LuaValue(cast(string) buffer)];
    });

    strTable.register("upper", (LuaState L, LuaValue[] a) {
        string s;
        if (!argString(L, a, 1, s))
            return null;
        auto buffer = s.dup;
        foreach (ref c; buffer)
            if (c >= 'a' && c <= 'z')
                c -= 32;
        return [LuaValue(cast(string) buffer)];
    });

    strTable.register("rep", (LuaState L, LuaValue[] a) {
        string s, sep;
        long n;
        if (!argString(L, a, 1, s) || !argInteger(L, a, 2, n) || !argOptString(L, a, 3, "", sep))
            return null;
        if (n <= 0)
            return [LuaValue("")];
        size_t unit = s.length + sep.length;
        if (unit < s.length || (unit != 0 && cast(ulong) n > cast(ulong) int.max / unit)) {
            failText(L, "resulting string too large");
            return null;
        }
        size_t total = unit * cast(size_t) n - sep.length;
        if (total > 0x7fffffff * 16UL) {
            failText(L, "not enough memory");
            return null;
        }
        auto buffer = new char[total];
        size_t pos = 0;
        foreach (k; 0 .. n) {
            buffer[pos .. pos + s.length] = s[];
            pos += s.length;
            if (k + 1 < n) {
                buffer[pos .. pos + sep.length] = sep[];
                pos += sep.length;
            }
        }
        return [LuaValue(cast(string) buffer)];
    });

    strTable.register("byte", (LuaState L, LuaValue[] a) {
        string s;
        long pi;
        size_t pose;
        if (!argString(L, a, 1, s) || !argOptInteger(L, a, 2, 1, pi) || !getEndPos(L, a, 3, pi, s.length, pose))
            return null;
        size_t posi = posRelatI(pi, s.length);
        if (posi > pose)
            return cast(LuaValue[])[];
        if (pose - posi >= int.max) {
            failText(L, "string slice too long");
            return null;
        }
        LuaValue[] result;
        foreach (k; posi - 1 .. pose)
            result ~= LuaValue(cast(long) cast(ubyte) s[k]);
        return result;
    });

    strTable.register("char", (LuaState L, LuaValue[] a) {
        auto buffer = new char[a.length];
        foreach (i; 0 .. a.length) {
            long c;
            if (!argInteger(L, a, cast(int) i + 1, c))
                return null;
            if (cast(ulong) c > 255)
                return argFail(L, cast(int) i + 1, "value out of range");
            buffer[i] = cast(char) c;
        }
        return [LuaValue(cast(string) buffer)];
    });

    strTable.register("find", (LuaState L, LuaValue[] a) => strFindAux(L, a, true));
    strTable.register("match", (LuaState L, LuaValue[] a) => strFindAux(L, a, false));

    strTable.register("gmatch", (LuaState L, LuaValue[] a) {
        string s, p;
        long initArg;
        if (!argString(L, a, 1, s) || !argString(L, a, 2, p) || !argOptInteger(L, a, 3, 1, initArg))
            return null;
        size_t init = posRelatI(initArg, s.length) - 1;
        if (init > s.length)
            init = s.length + 1;
        size_t position = init;
        ptrdiff_t lastMatch = -1;
        auto iterator = new LuaNativeFunction((void* st, LuaValue[] ignored) {
            for (; position <= s.length; ++position) {
                auto ms = MatchState(s, p);
                auto e = Pattern.matchLoop(ms, position, 0);
                if (e != -1 && e != lastMatch) {
                    size_t start = position;
                    position = lastMatch = e;
                    LuaValue[] result;
                    if (!pushCaptures(cast(LuaState) st, ms, true, start, e, result))
                        return null;
                    return result;
                }
            }
            return cast(LuaValue[])[];
        }, "gmatch_iterator");
        iterator.debugUpvalues = [LuaValue(s), LuaValue(p), LuaValue(cast(long) init)];
        return [LuaValue(iterator)];
    });

    strTable.register("gsub", (LuaState L, LuaValue[] a) => strGsub(L, a), true);
    strTable.register("format", (LuaState L, LuaValue[] a) => strFormat(L, a));

    strTable.register("dump", (LuaState L, LuaValue[] a) {
        import varis.dump : dumpFunction;

        if (a.length < 1 || !isFunction(a[0])) {
            typeFail(L, a, 1, "function");
            return null;
        }
        bool strip = a.length > 1 && isTruthy(a[1]);
        return [LuaValue(dumpFunction(L, a[0], strip))];
    });

    // String functions read their arguments and neither keep nor modify the argument array, so a
    // call passes a view of the caller's registers instead of a copy (one allocation less).
    LuaValue key, value;
    for (auto more = strTable.next(luaNil(), key, value); more; more = strTable.next(key, key, value))
        if (value.isFunction && value.asFunction.isNativeFunction)
            value.asFunction.borrowsArgs = true;

    // Set string metatable with __index = string table
    auto strMeta = new LuaTable();
    strMeta.rawset(LuaValue("__index"), LuaValue(strTable));
    state.stringMetatable = strMeta;

    state.setGlobal("string", LuaValue(strTable));
}
