/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

/// Operating system facilities: a port of loslib.c.
module dlua.lib.os;

import dlua.types;
import dlua.table;
import dlua.state;
import dlua.exception : LuaException, ExitRequest;
import dlua.lib.auxlib;
import core.stdc.stdio : remove, rename;
import core.stdc.stdlib : exit, getenv, system;
import core.stdc.time;
import core.sys.posix.time : gmtime_r, localtime_r;
import core.stdc.errno : errno;
import core.stdc.string : strerror;
import core.stdc.locale : setlocale, LC_ALL, LC_COLLATE, LC_CTYPE, LC_MONETARY, LC_NUMERIC, LC_TIME;
import std.string : toStringz, fromStringz;

private immutable string strftimeOptions =
    "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%" ~ "||" ~ "EcECExEXEyEY" ~ "OdOeOHOIOmOMOSOuOUOVOwOWOy";

private LuaValue[] fileResult(bool ok, string filename = null) {
    int en = errno;
    if (ok) return [LuaValue(true)];
    string message = (cast(string)strerror(en).fromStringz).idup;
    if (filename !is null) message = filename ~ ": " ~ message;
    return [luaNil(), LuaValue(message), LuaValue(cast(long)en)];
}

private void setField(LuaTable t, string key, long value, int delta) {
    t.rawset(LuaValue(key), LuaValue(value + delta));
}

private void setAllFields(LuaTable t, ref tm stm) {
    setField(t, "year", stm.tm_year, 1900);
    setField(t, "month", stm.tm_mon, 1);
    setField(t, "day", stm.tm_mday, 0);
    setField(t, "hour", stm.tm_hour, 0);
    setField(t, "min", stm.tm_min, 0);
    setField(t, "sec", stm.tm_sec, 0);
    setField(t, "yday", stm.tm_yday, 1);
    setField(t, "wday", stm.tm_wday, 1);
    if (stm.tm_isdst >= 0) t.rawset(LuaValue("isdst"), LuaValue(stm.tm_isdst != 0));
}

private int getField(LuaTable t, string key, int d, int delta) {
    auto v = t.rawget(LuaValue(key));
    long res;
    if (!toIntegerArg(v, res)) {
        if (!isNil(v)) throw new LuaException("field '" ~ key ~ "' is not an integer");
        if (d < 0) throw new LuaException("field '" ~ key ~ "' missing in date table");
        res = d;
    } else {
        if (!(res >= 0 ? res - delta <= int.max : int.min + delta <= res))
            throw new LuaException("field '" ~ key ~ "' is out-of-bound");
        res -= delta;
    }
    return cast(int)res;
}

private time_t checkTime(LuaState L, LuaValue[] a, int n) {
    return cast(time_t)checkInteger(L, a, n);
}

void openOsLib(LuaState state) {
    auto osTable = new LuaTable();

    osTable.register("clock", (LuaState L, LuaValue[] a) => [LuaValue(cast(double)clock() / CLOCKS_PER_SEC)]);

    osTable.register("date", (LuaState L, LuaValue[] a) {
        string s = optString(L, a, 1, "%c");
        time_t t = isNoneOrNil(a, 2) ? time(null) : checkTime(L, a, 2);
        bool utc = s.length && s[0] == '!';
        if (utc) s = s[1 .. $];
        tm stm;
        tm* result = utc ? gmtime_r(&t, &stm) : localtime_r(&t, &stm);
        if (result is null) throw new LuaException("date result cannot be represented in this installation");
        if (s == "*t") {
            auto table = new LuaTable();
            setAllFields(table, stm);
            return [LuaValue(table)];
        }
        string output;
        size_t i = 0;
        while (i < s.length) {
            if (s[i] != '%') { output ~= s[i++]; continue; }
            ++i;
            // checkoption
            string conv = s[i .. $];
            string found;
            size_t oplen = 1;
            size_t o = 0;
            while (o < strftimeOptions.length && oplen <= conv.length) {
                if (strftimeOptions[o] == '|') { ++oplen; o += oplen; }
                else if (strftimeOptions[o .. o + oplen] == conv[0 .. oplen]) { found = conv[0 .. oplen]; break; }
                else o += oplen;
            }
            if (found is null) throw new ArgError(1, "invalid conversion specifier '%" ~ conv ~ "'");
            i += found.length;
            char[256] buffer;
            auto len = strftime(buffer.ptr, buffer.length, ("%" ~ found).toStringz, &stm);
            output ~= buffer[0 .. len];
        }
        return [LuaValue(output)];
    });

    osTable.register("time", (LuaState L, LuaValue[] a) {
        time_t t;
        if (isNoneOrNil(a, 1)) t = time(null);
        else {
            auto table = checkTable(L, a, 1);
            tm ts;
            ts.tm_year = getField(table, "year", -1, 1900);
            ts.tm_mon = getField(table, "month", -1, 1);
            ts.tm_mday = getField(table, "day", -1, 0);
            ts.tm_hour = getField(table, "hour", 12, 0);
            ts.tm_min = getField(table, "min", 0, 0);
            ts.tm_sec = getField(table, "sec", 0, 0);
            auto dst = table.rawget(LuaValue("isdst"));
            ts.tm_isdst = isNil(dst) ? -1 : (isTruthy(dst) ? 1 : 0);
            t = mktime(&ts);
            setAllFields(table, ts);
        }
        if (t == cast(time_t)-1) throw new LuaException("time result cannot be represented in this installation");
        return [LuaValue(cast(long)t)];
    });

    osTable.register("difftime", (LuaState L, LuaValue[] a) {
        time_t t1 = checkTime(L, a, 1);
        time_t t2 = checkTime(L, a, 2);
        return [LuaValue(difftime(t1, t2))];
    });

    osTable.register("getenv", (LuaState L, LuaValue[] a) {
        auto value = getenv(checkString(L, a, 1).toStringz);
        if (value is null) return [luaNil()];
        return [LuaValue((cast(string)value.fromStringz).idup)];
    });

    osTable.register("execute", (LuaState L, LuaValue[] a) {
        import core.sys.posix.sys.wait : WIFEXITED, WEXITSTATUS, WIFSIGNALED, WTERMSIG;
        import core.stdc.stdio : fflush;
        string cmd = optString(L, a, 1, null);
        errno = 0;
        fflush(null);
        int stat = system(cmd is null ? null : cmd.toStringz);
        if (cmd is null) return [LuaValue(stat != 0)];
        if (stat != 0 && errno != 0) return fileResult(false);
        string what = "exit";
        if (WIFEXITED(stat)) stat = WEXITSTATUS(stat);
        else if (WIFSIGNALED(stat)) { stat = WTERMSIG(stat); what = "signal"; }
        if (what == "exit" && stat == 0) return [LuaValue(true), LuaValue(what), LuaValue(cast(long)stat)];
        return [luaNil(), LuaValue(what), LuaValue(cast(long)stat)];
    });

    osTable.register("remove", (LuaState L, LuaValue[] a) {
        string filename = checkString(L, a, 1);
        errno = 0;
        return fileResult(remove(filename.toStringz) == 0, filename);
    });

    osTable.register("rename", (LuaState L, LuaValue[] a) {
        string from = checkString(L, a, 1);
        string to = checkString(L, a, 2);
        errno = 0;
        return fileResult(rename(from.toStringz, to.toStringz) == 0);
    });

    osTable.register("tmpname", (LuaState L, LuaValue[] a) {
        import core.sys.posix.stdlib : mkstemp;
        import core.sys.posix.unistd : close;
        char[] pattern = "/tmp/lua_XXXXXX\0".dup;
        int fd = mkstemp(pattern.ptr);
        if (fd == -1) throw new LuaException("unable to generate a unique filename");
        close(fd);
        return [LuaValue(pattern[0 .. $ - 1].idup)];
    });

    osTable.register("setlocale", (LuaState L, LuaValue[] a) {
        static immutable names = ["all", "collate", "ctype", "monetary", "numeric", "time"];
        static immutable cats = [LC_ALL, LC_COLLATE, LC_CTYPE, LC_MONETARY, LC_NUMERIC, LC_TIME];
        string locale = optString(L, a, 1, null);
        int op = checkOption(L, a, 2, "all", names);
        auto res = setlocale(cats[op], locale is null ? null : locale.toStringz);
        if (res is null) return [luaNil()];
        return [LuaValue((cast(string)res.fromStringz).idup)];
    });

    osTable.register("exit", (LuaState L, LuaValue[] a) {
        import core.stdc.stdio : fflush;
        int status;
        if (a.length && isBoolean(a[0])) status = isTruthy(a[0]) ? 0 : 1;
        else status = cast(int)optInteger(L, a, 1, 0);
        if (a.length > 1 && isTruthy(a[1])) throw new ExitRequest(status);
        fflush(null);
        exit(status);
        return cast(LuaValue[])[];
    });

    state.setGlobal("os", LuaValue(osTable));
}
