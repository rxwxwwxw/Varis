/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

/// Input/output library: a port of liolib.c on top of C stdio.
module dlua.lib.io;

import dlua.types;
import dlua.table;
import dlua.state;
import dlua.vm;
import dlua.exception : LuaException;
import dlua.lib.auxlib;
import std.conv : to;
import std.string : toStringz, fromStringz;
import core.stdc.stdio;
import core.stdc.errno : errno;
import core.stdc.string : strerror;

private enum CloseKind { none, file, popen, standard }

/// Payload of a file handle userdata (luaL_Stream).
class LStream {
    FILE* f;
    CloseKind kind = CloseKind.none; // none = closed handle

    bool closed() const { return kind == CloseKind.none; }

    ~this() {
        if (kind == CloseKind.file && f !is null) fclose(f);
        else if (kind == CloseKind.popen && f !is null) {
            import core.sys.posix.stdio : pclose;
            pclose(f);
        }
        kind = CloseKind.none;
    }
}

private LuaTable fileMeta;

private LStream testStream(LuaState L, LuaValue v) {
    if (v.typeOf() != LuaType.UserData) return null;
    auto u = v.match!((LuaUserData u) => u, _ => null);
    if (u is null || u.metatable !is fileMeta) return null;
    return cast(LStream)u.payload;
}

private LStream checkStream(LuaState L, LuaValue[] a, int n) {
    if (n <= a.length) if (auto p = testStream(L, a[n - 1])) return p;
    typeError(L, a, n, "FILE*");
    assert(0);
}

private FILE* toFile(LuaState L, LuaValue[] a, int n = 1) {
    auto p = checkStream(L, a, n);
    if (p.closed) throw new LuaException("attempt to use a closed file");
    return p.f;
}

private LuaValue newStream(FILE* f, CloseKind kind) {
    auto stream = new LStream();
    stream.f = f; stream.kind = kind;
    return LuaValue(new LuaUserData(stream, fileMeta));
}

/// luaL_fileresult
private LuaValue[] fileResult(bool ok, string filename = null) {
    int en = errno;
    if (ok) return [LuaValue(true)];
    string message = (cast(string)strerror(en).fromStringz).idup;
    if (filename !is null) message = filename ~ ": " ~ message;
    return [luaNil(), LuaValue(message), LuaValue(cast(long)en)];
}

private LuaValue[] execResult(int status) {
    import core.sys.posix.sys.wait : WIFEXITED, WEXITSTATUS, WIFSIGNALED, WTERMSIG;
    if (status != 0 && errno != 0) return fileResult(false);
    string what = "exit";
    if (status == -1) return fileResult(false);
    if (WIFEXITED(status)) status = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) { status = WTERMSIG(status); what = "signal"; }
    if (what == "exit" && status == 0) return [LuaValue(true), LuaValue(what), LuaValue(cast(long)status)];
    return [luaNil(), LuaValue(what), LuaValue(cast(long)status)];
}

private LuaValue[] closeStream(LuaState L, LuaValue handle) {
    auto p = handle.match!((LuaUserData u) => cast(LStream)u.payload, _ => null);
    auto kind = p.kind;
    p.kind = CloseKind.none;
    final switch (kind) {
        case CloseKind.file:
            errno = 0;
            return fileResult(fclose(p.f) == 0);
        case CloseKind.popen: {
            import core.sys.posix.stdio : pclose;
            errno = 0;
            return execResult(pclose(p.f));
        }
        case CloseKind.standard:
            p.kind = CloseKind.standard; // keep the file open
            return [luaNil(), LuaValue("cannot close standard file")];
        case CloseKind.none:
            return [];
    }
}

private bool checkMode(string mode) {
    if (mode.length == 0 || !("rwa".indexOfChar(mode[0]) >= 0)) return false;
    size_t i = 1;
    if (i < mode.length && mode[i] == '+') ++i;
    while (i < mode.length) { if (mode[i] != 'b') return false; ++i; }
    return true;
}

private ptrdiff_t indexOfChar(string s, char c) {
    foreach (i, ch; s) if (ch == c) return i;
    return -1;
}

private FILE* getIoFile(LuaState L, string key, string what) {
    auto v = L.registry.rawget(LuaValue(key));
    auto p = testStream(L, v);
    if (p is null || p.closed) throw new LuaException("default " ~ what ~ " file is closed");
    return p.f;
}

// --- reading ---------------------------------------------------------------

private struct NumberReader {
    FILE* f;
    int c;
    int n;
    char[201] buff;

    bool nextc() {
        if (n >= 200) { buff[0] = 0; return false; }
        buff[n++] = cast(char)c;
        c = getc(f);
        return true;
    }
    bool test2(string set) {
        if (c == set[0] || c == set[1]) return nextc();
        return false;
    }
    int readDigits(bool hex) {
        int count = 0;
        while ((hex ? isXDigit(c) : isDigit(c)) && nextc()) ++count;
        return count;
    }
}

private bool isDigit(int c) { return c >= '0' && c <= '9'; }
private bool isXDigit(int c) { return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
private bool isSpace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

private bool readNumber(FILE* f, out LuaValue result) {
    import core.stdc.locale : localeconv;
    NumberReader rn;
    rn.f = f;
    int count = 0;
    bool hex = false;
    char point = localeconv().decimal_point[0];
    string decp = [point, '.'].idup;
    do { rn.c = getc(f); } while (isSpace(rn.c));
    rn.test2("-+");
    if (rn.test2("00")) {
        if (rn.test2("xX")) hex = true; else count = 1;
    }
    count += rn.readDigits(hex);
    if (rn.test2(decp)) count += rn.readDigits(hex);
    if (count > 0 && rn.test2(hex ? "pP" : "eE")) {
        rn.test2("-+");
        rn.readDigits(false);
    }
    ungetc(rn.c, f);
    string text = rn.buff[0 .. rn.n].idup;
    return parseLuaNumber(text, result);
}

private bool readLine(FILE* f, bool chop, out string line) {
    import std.array : appender;
    auto b = appender!(char[])();
    int c;
    while ((c = getc(f)) != EOF && c != '\n') b.put(cast(char)c);
    if (!chop && c == '\n') b.put('\n');
    line = cast(string)b.data;
    return c == '\n' || line.length > 0;
}

private string readAll(FILE* f) {
    import std.array : appender;
    auto b = appender!(char[])();
    char[4096] block;
    while (true) {
        auto nr = fread(block.ptr, 1, block.length, f);
        b.put(block[0 .. nr]);
        if (nr < block.length) break;
    }
    return cast(string)b.data;
}

private LuaValue[] gRead(LuaState L, FILE* f, LuaValue[] a, int first) {
    int nargs = cast(int)a.length - (first - 1);
    LuaValue[] results;
    clearerr(f);
    errno = 0;
    bool success = true;
    if (nargs == 0) {
        string line;
        success = readLine(f, true, line);
        results ~= success ? LuaValue(line) : luaNil();
    } else {
        for (int n = first; nargs-- > 0 && success; ++n) {
            if (a[n - 1].typeOf() == LuaType.Number) {
                size_t l = cast(size_t)checkInteger(L, a, n);
                if (l == 0) {
                    int c = getc(f);
                    ungetc(c, f);
                    success = c != EOF;
                    results ~= LuaValue("");
                } else {
                    auto buffer = new char[l];
                    auto nr = fread(buffer.ptr, 1, l, f);
                    success = nr > 0;
                    results ~= LuaValue(cast(string)buffer[0 .. nr].idup);
                }
            } else {
                string p = checkString(L, a, n);
                if (p.length && p[0] == '*') p = p[1 .. $];
                char kind = p.length ? p[0] : '\0';
                switch (kind) {
                    case 'n': {
                        LuaValue number;
                        success = readNumber(f, number);
                        results ~= success ? number : luaNil();
                        break;
                    }
                    case 'l': case 'L': {
                        string line;
                        success = readLine(f, kind == 'l', line);
                        results ~= LuaValue(line);
                        break;
                    }
                    case 'a':
                        results ~= LuaValue(readAll(f));
                        success = true;
                        break;
                    default:
                        throw new ArgError(n, "invalid format");
                }
            }
        }
    }
    if (ferror(f)) return fileResult(false);
    if (!success) results[$ - 1] = luaNil();
    return results;
}

private LuaValue[] gWrite(LuaState L, FILE* f, LuaValue[] a, int arg, LuaValue self) {
    bool status = true;
    errno = 0;
    for (; arg <= a.length; ++arg) {
        auto v = a[arg - 1];
        if (isInteger(v)) {
            status = status && fprintf(f, "%lld", v.match!((long i) => i, _ => 0L)) > 0;
        } else if (isFloat(v)) {
            status = status && fprintf(f, "%.14g", v.match!((double d) => d, _ => 0.0)) > 0;
        } else {
            string s = checkString(L, a, arg);
            status = status && fwrite(s.ptr, 1, s.length, f) == s.length;
        }
    }
    if (status) return [self];
    return fileResult(false);
}

private LuaValue[] linesIterator(LuaState L, LuaValue file, LuaValue[] formats, bool toClose) {
    auto fn = new LuaNativeFunction((void* sp, LuaValue[] ignored) {
        auto S = cast(LuaState)sp;
        auto p = testStream(S, file);
        if (p.closed) throw new LuaException("file is already closed");
        auto results = gRead(S, p.f, [file] ~ formats, 2);
        if (results.length && isTruthy(results[0])) return results;
        if (results.length > 1) throw new LuaException(toLuaString(results[1]));
        if (toClose) closeStream(S, file);
        return cast(LuaValue[])[];
    }, "lines_iterator");
    return [LuaValue(fn)];
}

private LuaValue openOrFail(LuaState L, string fname, string mode) {
    FILE* f = fopen(fname.toStringz, mode.toStringz);
    if (f is null) {
        string message = (cast(string)strerror(errno).fromStringz).idup;
        throw new LuaException("cannot open file '" ~ fname ~ "' (" ~ message ~ ")");
    }
    return newStream(f, CloseKind.file);
}

private LuaValue[] gIoFile(LuaState L, LuaValue[] a, string key, string mode) {
    if (!isNoneOrNil(a, 1)) {
        if (isString(a[0])) {
            L.registry.rawset(LuaValue(key), openOrFail(L, a[0].match!((string s) => s, _ => ""), mode));
        } else {
            toFile(L, a, 1);
            L.registry.rawset(LuaValue(key), a[0]);
        }
    }
    return [L.registry.rawget(LuaValue(key))];
}

void openIoLib(LuaState state) {
    auto ioTable = new LuaTable();
    auto methods = new LuaTable();
    fileMeta = new LuaTable();
    state.registry.rawset(LuaValue("FILE*"), LuaValue(fileMeta));

    // --- methods -------------------------------------------------------------
    methods.register("close", (LuaState L, LuaValue[] a) {
        toFile(L, a);
        return closeStream(L, a[0]);
    });
    methods.register("flush", (LuaState L, LuaValue[] a) {
        auto f = toFile(L, a);
        errno = 0;
        return fileResult(fflush(f) == 0);
    });
    methods.register("read", (LuaState L, LuaValue[] a) => gRead(L, toFile(L, a), a, 2));
    methods.register("write", (LuaState L, LuaValue[] a) => gWrite(L, toFile(L, a), a, 2, a[0]));
    methods.register("lines", (LuaState L, LuaValue[] a) {
        toFile(L, a);
        return linesIterator(L, a[0], a[1 .. $], false);
    });
    methods.register("seek", (LuaState L, LuaValue[] a) {
        import core.stdc.stdio : fseek, ftell;
        static immutable names = ["set", "cur", "end"];
        auto f = toFile(L, a);
        int op = checkOption(L, a, 2, "cur", names);
        long p3 = optInteger(L, a, 3, 0);
        static immutable modes = [SEEK_SET, SEEK_CUR, SEEK_END];
        errno = 0;
        if (fseek(f, cast(c_long)p3, modes[op]) != 0) return fileResult(false);
        return [LuaValue(cast(long)ftell(f))];
    });
    methods.register("setvbuf", (LuaState L, LuaValue[] a) {
        static immutable names = ["no", "full", "line"];
        auto f = toFile(L, a);
        int op = checkOption(L, a, 2, null, names);
        long sz = optInteger(L, a, 3, 1024);
        static immutable modes = [_IONBF, _IOFBF, _IOLBF];
        errno = 0;
        return fileResult(setvbuf(f, null, modes[op], cast(size_t)sz) == 0);
    });

    auto closeIfOpen = delegate LuaValue[] (LuaState L, LuaValue[] a) {
        auto p = checkStream(L, a, 1);
        if (!p.closed && p.f !is null) closeStream(L, a[0]);
        return cast(LuaValue[])[];
    };
    fileMeta.rawset(LuaValue("__index"), LuaValue(methods));
    fileMeta.rawset(LuaValue("__name"), LuaValue("FILE*"));
    fileMeta.register("__gc", closeIfOpen);
    fileMeta.register("__close", closeIfOpen);
    fileMeta.register("__tostring", (LuaState L, LuaValue[] a) {
        auto p = checkStream(L, a, 1);
        if (p.closed) return [LuaValue("file (closed)")];
        return [LuaValue("file (0x" ~ (cast(size_t)p.f).to!string(16) ~ ")")];
    });

    // --- io functions --------------------------------------------------------
    ioTable.register("close", (LuaState L, LuaValue[] a) {
        if (a.length == 0) a = [L.registry.rawget(LuaValue("_IO_output"))];
        toFile(L, a);
        return closeStream(L, a[0]);
    });
    ioTable.register("flush", (LuaState L, LuaValue[] a) {
        auto f = getIoFile(L, "_IO_output", "output");
        errno = 0;
        return fileResult(fflush(f) == 0);
    });
    ioTable.register("input", (LuaState L, LuaValue[] a) => gIoFile(L, a, "_IO_input", "r"));
    ioTable.register("output", (LuaState L, LuaValue[] a) => gIoFile(L, a, "_IO_output", "w"));
    ioTable.register("open", (LuaState L, LuaValue[] a) {
        string filename = checkString(L, a, 1);
        string mode = optString(L, a, 2, "r");
        if (!checkMode(mode)) throw new ArgError(2, "invalid mode");
        errno = 0;
        FILE* f = fopen(filename.toStringz, mode.toStringz);
        if (f is null) return fileResult(false, filename);
        return [newStream(f, CloseKind.file)];
    });
    ioTable.register("popen", (LuaState L, LuaValue[] a) {
        import core.sys.posix.stdio : popen;
        string command = checkString(L, a, 1);
        string mode = optString(L, a, 2, "r");
        if (!(mode == "r" || mode == "w")) throw new ArgError(2, "invalid mode");
        errno = 0;
        fflush(null);
        FILE* f = popen(command.toStringz, mode.toStringz);
        if (f is null) return fileResult(false, command);
        return [newStream(f, CloseKind.popen)];
    });
    ioTable.register("tmpfile", (LuaState L, LuaValue[] a) {
        errno = 0;
        FILE* f = tmpfile();
        if (f is null) return fileResult(false);
        return [newStream(f, CloseKind.file)];
    });
    ioTable.register("type", (LuaState L, LuaValue[] a) {
        checkAny(a, 1);
        auto p = testStream(L, a[0]);
        if (p is null) return [luaNil()];
        return [LuaValue(p.closed ? "closed file" : "file")];
    });
    ioTable.register("read", (LuaState L, LuaValue[] a) => gRead(L, getIoFile(L, "_IO_input", "input"), [luaNil()] ~ a, 2));
    ioTable.register("write", (LuaState L, LuaValue[] a) {
        auto f = getIoFile(L, "_IO_output", "output");
        return gWrite(L, f, a, 1, L.registry.rawget(LuaValue("_IO_output")));
    });
    ioTable.register("lines", (LuaState L, LuaValue[] a) {
        if (isNoneOrNil(a, 1)) {
            auto input = L.registry.rawget(LuaValue("_IO_input"));
            auto p = testStream(L, input);
            if (p is null || p.closed) throw new LuaException("default input file is closed");
            return linesIterator(L, input, a.length > 1 ? a[1 .. $] : [], false);
        }
        string filename = checkString(L, a, 1);
        if (a.length > 251) throw new ArgError(252, "too many arguments");
        auto file = openOrFail(L, filename, "r");
        auto iterator = linesIterator(L, file, a[1 .. $], true);
        return [iterator[0], luaNil(), luaNil(), file];
    });

    // --- standard files ------------------------------------------------------
    auto stdinValue = newStream(stdin, CloseKind.standard);
    auto stdoutValue = newStream(stdout, CloseKind.standard);
    auto stderrValue = newStream(stderr, CloseKind.standard);
    ioTable.rawset(LuaValue("stdin"), stdinValue);
    ioTable.rawset(LuaValue("stdout"), stdoutValue);
    ioTable.rawset(LuaValue("stderr"), stderrValue);
    state.registry.rawset(LuaValue("_IO_input"), stdinValue);
    state.registry.rawset(LuaValue("_IO_output"), stdoutValue);

    state.setGlobal("io", LuaValue(ioTable));
}

import core.stdc.config : c_long;
