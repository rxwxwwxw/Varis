/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Stand-alone interpreter: a port of lua.c.
module varis.cli;

import varis;
import varis.vm : VM;
import varis.exception : ExitRequest;
import varis.lib.base : readWholeFile, skipFilePrefix, loadChunk, tostringValue;
import core.stdc.stdio : fputs, fwrite, fflush, stdout, stderr, stdin, fgets;
import core.stdc.stdlib : getenv;
import core.thread : Fiber;
import std.string : toStringz, fromStringz, indexOf;

private string progname = "varis";
enum versionString = "Lua 5.4.9  Copyright (C) 1994-2026 Lua.org, PUC-Rio";

private void writeErr(string s) {
    fwrite(s.ptr, 1, s.length, stderr);
    fflush(stderr);
}

private void writeOut(string s) {
    fwrite(s.ptr, 1, s.length, stdout);
}

private void printUsage(string badoption) {
    writeErr(progname ~ ": ");
    if (badoption.length > 1 && (badoption[1] == 'e' || badoption[1] == 'l'))
        writeErr("'" ~ badoption ~ "' needs argument\n");
    else
        writeErr("unrecognized option '" ~ badoption ~ "'\n");
    writeErr("usage: " ~ progname ~ " [options] [script [args]]\n" ~
            "Available options are:\n" ~
            "  -e stat   execute string 'stat'\n" ~
            "  -i        enter interactive mode after executing 'script'\n" ~
            "  -l mod    require library 'mod' into global 'mod'\n" ~
            "  -l g=mod  require library 'mod' into global 'g'\n" ~
            "  -v        show version information\n" ~
            "  -E        ignore environment variables\n" ~
            "  -W        turn warnings on\n" ~
            "  --        stop handling options\n" ~
            "  -         stop handling options and execute stdin\n");
}

private void lMessage(string pname, string msg) {
    if (pname !is null)
        writeErr(pname ~ ": ");
    writeErr(msg ~ "\n");
}

/// Outcome of a protected call.
private struct CallResult {
    bool ok;
    LuaValue[] values;
    LuaValue error;
}

private string messageText(LuaValue error) {
    if (isString(error) || isNumber(error))
        return toLuaString(error);
    return null;
}

/// The message handler used to run all chunks: appends a traceback.
private LuaValue messageHandler(LuaState state, LuaValue error) {
    string msg = messageText(error);
    if (msg is null) {
        auto mt = state.getMetatable(error);
        if (mt !is null && isFunction(mt.rawget(LuaValue("__tostring")))) {
            auto produced = VM.callValue(state, mt.rawget(LuaValue("__tostring")), [error]);
            if (produced.length && isString(produced[0]))
                return produced[0];
        }
        msg = "(error object is a " ~ typeName(error) ~ " value)";
    }
    auto debugTable = state.getGlobal("debug");
    if (isTable(debugTable)) {
        auto traceback = debugTable.match!((LuaTable t) => t, _ => null).rawget(LuaValue("traceback"));
        if (isFunction(traceback)) {
            try {
                auto result = VM.callValue(state, traceback, [LuaValue(msg), LuaValue(2L)]);
                if (result.length)
                    return result[0];
            } catch (LuaException) {
            }
        }
    }
    return LuaValue(msg);
}

/// The precise heap collector ignores stale non-pointer words in heap blocks; the
/// conservative collector retained unrelated objects often enough to defeat weak-table tests.
extern (C) __gshared string[] rt_options = ["gcopt=gc:precise heapSizeFactor:4"];

extern (C) private void interruptHandler(int signum) nothrow @nogc {
    import core.stdc.signal : signal, SIGINT, SIG_DFL;
    import varis.vm : vmInterrupt;
    import varis.state : vmAttention;

    signal(SIGINT, SIG_DFL); // a second Ctrl-C terminates the process
    vmInterrupt = true;
    vmAttention = true;
}

private CallResult docall(LuaState state, LuaValue fn, LuaValue[] args) {
    import core.stdc.signal : signal, SIGINT, SIG_DFL;

    signal(SIGINT, &interruptHandler);
    scope (exit)
        signal(SIGINT, SIG_DFL);
    auto thread = state.currentThread();
    auto handler = new LuaNativeFunction((void* sp, LuaValue[] a) {
        return [messageHandler(state, a.length ? a[0] : luaNil())];
    }, "msghandler");
    // The interpreter itself runs Lua code from a C function (visible in tracebacks as "[C]: in ?").
    auto entryFrame = new LuaNativeFunction((void* sp, LuaValue[] a) => cast(LuaValue[])[], "?");
    state.pushCall(entryFrame, "[C]", -1);
    scope (exit)
        state.popCall();
    if (thread !is null)
        thread.pushBoundary(true, LuaValue(handler));
    scope (exit)
        if (thread !is null)
            thread.popBoundary();
    try {
        return CallResult(true, VM.callValue(state, fn, args), luaNil());
    } catch (LuaException error) {
        state.dispatchError(error);
        return CallResult(false, [], error.errorObject);
    } catch (Exception failure) {
        auto error = new LuaException(LuaValue(failure.msg));
        state.dispatchError(error);
        return CallResult(false, [], error.errorObject);
    }
}

private bool report(CallResult result) {
    if (!result.ok) {
        string msg = messageText(result.error);
        if (msg is null)
            msg = "(error message not a string)";
        lMessage(progname, msg);
    }
    return result.ok;
}

/// Loads a file (or stdin when `name` is null). Returns the function or sets `error`.
private LuaFunction loadFile(LuaState state, string name, out string error) {
    string content, readError;
    string chunkName;
    if (name is null) {
        import std.array : appender;

        auto all = appender!(char[])();
        char[4096] buffer;
        while (fgets(buffer.ptr, cast(int) buffer.length, stdin) !is null) {
            auto line = fromStringz(buffer.ptr);
            all.put(line);
        }
        content = cast(string) all.data;
        chunkName = "=stdin";
    } else {
        if (!readWholeFile(name, content, readError)) {
            error = "cannot open " ~ name ~ ": " ~ readError;
            return null;
        }
        chunkName = "@" ~ name;
    }
    try {
        return loadChunk(state, skipFilePrefix(content), chunkName, "bt");
    } catch (LuaException failure) {
        error = toLuaString(failure.errorObject);
        return null;
    }
}

private bool dofile(LuaState state, string name) {
    string error;
    auto fn = loadFile(state, name, error);
    if (fn is null) {
        lMessage(progname, error);
        return false;
    }
    return report(docall(state, LuaValue(fn), []));
}

private bool dostring(LuaState state, string code, string name) {
    try {
        auto fn = state.loadString(code, name);
        return report(docall(state, LuaValue(fn), []));
    } catch (LuaException failure) {
        lMessage(progname, toLuaString(failure.errorObject));
        return false;
    }
}

private bool dolibrary(LuaState state, string globname) {
    string modname;
    string suffixCut;
    auto eq = globname.indexOf('=');
    if (eq < 0) {
        modname = globname;
        auto dash = modname.indexOf('-');
        if (dash >= 0)
            suffixCut = globname[0 .. dash];
    } else {
        modname = globname[eq + 1 .. $];
        globname = globname[0 .. eq];
    }
    auto result = docall(state, state.getGlobal("require"), [LuaValue(modname)]);
    if (result.ok) {
        state.setGlobal(suffixCut !is null ? suffixCut : globname, result.values.length ? result.values[0] : luaNil());
    }
    return report(result);
}

private enum : int {
    hasError = 1,
    hasI = 2,
    hasV = 4,
    hasE_ = 8,
    hasEnvFlag = 16
}

/// Mirrors collectargs: returns the mask, and the script index through `first`.
private int collectArgs(string[] argv, out int first) {
    int args = 0;
    if (argv.length == 0) {
        first = -1;
        return 0;
    }
    if (argv[0].length)
        progname = argv[0];
    for (int i = 1; i < argv.length; i++) {
        first = i;
        auto a = argv[i];
        if (a.length == 0 || a[0] != '-')
            return args;
        char c = a.length > 1 ? a[1] : '\0';
        switch (c) {
        case '-':
            if (a.length > 2)
                return hasError;
            first = (i + 1 < argv.length) ? i + 1 : 0;
            return args;
        case '\0':
            return args;
        case 'E':
            if (a.length > 2)
                return hasError;
            args |= hasEnvFlag;
            break;
        case 'W':
            if (a.length > 2)
                return hasError;
            break;
        case 'i':
            args |= hasI;
            goto case 'v';
        case 'v':
            if (a.length > 2)
                return hasError;
            args |= hasV;
            break;
        case 'e':
            args |= hasE_;
            goto case 'l';
        case 'l':
            if (a.length == 2) {
                i++;
                if (i >= argv.length || (argv[i].length && argv[i][0] == '-'))
                    return hasError;
            }
            break;
        default:
            return hasError;
        }
    }
    first = 0;
    return args;
}

private bool runArgs(LuaState state, string[] argv, int n) {
    for (int i = 1; i < n; i++) {
        char option = argv[i][1];
        switch (option) {
        case 'e', 'l': {
                string extra = argv[i][2 .. $];
                if (extra.length == 0)
                    extra = argv[++i];
                bool ok = option == 'e' ? dostring(state, extra, "=(command line)") : dolibrary(state, extra);
                if (!ok)
                    return false;
                break;
            }
        case 'W':
            VM.callValue(state, state.getGlobal("warn"), [LuaValue("@on")]);
            break;
        default:
            break;
        }
    }
    return true;
}

private bool handleLuaInit(LuaState state) {
    string name = "=LUA_INIT_5_4";
    auto init = getenv("LUA_INIT_5_4");
    if (init is null) {
        name = "=LUA_INIT";
        init = getenv("LUA_INIT");
    }
    if (init is null)
        return true;
    string text = fromStringz(init).idup;
    if (text.length && text[0] == '@')
        return dofile(state, text[1 .. $]);
    return dostring(state, text, name);
}

private LuaValue[] pushArgs(LuaState state) {
    auto argValue = state.getGlobal("arg");
    if (!isTable(argValue))
        throw new LuaException("'arg' is not a table");
    auto t = argValue.match!((LuaTable x) => x, _ => null);
    auto n = t.rawLen();
    LuaValue[] result;
    foreach (i; 1 .. n + 1)
        result ~= t.rawgetInt(i);
    return result;
}

private bool handleScript(LuaState state, string[] argv, int script) {
    string fname = argv[script];
    if (fname == "-" && !(script > 0 && argv[script - 1] == "--"))
        fname = null;
    string error;
    auto fn = loadFile(state, fname, error);
    if (fn is null) {
        lMessage(progname, error);
        return false;
    }
    return report(docall(state, LuaValue(fn), pushArgs(state)));
}

// --- REPL --------------------------------------------------------------------

private bool stdinIsTty() {
    import core.sys.posix.unistd : isatty;

    return isatty(0) != 0;
}

private string getPrompt(LuaState state, bool firstline) {
    auto v = state.getGlobal(firstline ? "_PROMPT" : "_PROMPT2");
    if (isNil(v))
        return firstline ? "> " : ">> ";
    return tostringValue(state, v);
}

private bool pushLine(LuaState state, bool firstline, out string line) {
    auto prompt = getPrompt(state, firstline);
    fputs(prompt.toStringz, stdout);
    fflush(stdout);
    char[512] buffer;
    string collected;
    while (true) {
        if (fgets(buffer.ptr, cast(int) buffer.length, stdin) is null) {
            if (collected.length == 0)
                return false;
            break;
        }
        auto piece = fromStringz(buffer.ptr);
        collected ~= piece;
        if (piece.length && piece[$ - 1] == '\n')
            break;
    }
    if (collected.length && collected[$ - 1] == '\n')
        collected = collected[0 .. $ - 1];
    // Like a readline-enabled build, show the input when stdin is not a terminal.
    if (!stdinIsTty()) {
        writeOut(collected ~ "\n");
        fflush(stdout);
    }
    if (firstline && collected.length && collected[0] == '=')
        line = "return " ~ collected[1 .. $];
    else
        line = collected.idup;
    return true;
}

private bool incomplete(string message) {
    return message.length >= 5 && message[$ - 5 .. $] == "<eof>";
}

private void doREPL(LuaState state) {
    auto oldname = progname;
    progname = null;
    while (true) {
        string line;
        if (!pushLine(state, true, line))
            break;
        LuaFunction fn;
        string error;
        try {
            fn = state.loadString("return " ~ line ~ ";", "=stdin");
        } catch (LuaException) {
            while (true) {
                try {
                    fn = state.loadString(line, "=stdin");
                    break;
                } catch (LuaException failure) {
                    auto msg = toLuaString(failure.errorObject);
                    string more;
                    if (!incomplete(msg) || !pushLine(state, false, more)) {
                        error = msg;
                        break;
                    }
                    line ~= "\n" ~ more;
                }
            }
        }
        if (fn is null) {
            lMessage(null, error);
            continue;
        }
        auto result = docall(state, LuaValue(fn), []);
        if (result.ok) {
            if (result.values.length) {
                auto printResult = docall(state, state.getGlobal("print"), result.values);
                if (!printResult.ok)
                    lMessage(progname, "error calling 'print' (" ~ toLuaString(printResult.error) ~ ")");
            }
        } else {
            report(result);
        }
    }
    writeOut("\n");
    fflush(stdout);
    progname = oldname;
}

int main(string[] argv) {
    // Lua errors are D exceptions used for control flow; capturing a native backtrace for each
    // would cost far more than the throw itself (and grows with stack depth).
    import core.runtime : Runtime;

    Runtime.traceHandler = null;
    LuaState state;
    int result;
    // The interpreter runs on a fiber with a very large stack: Lua code can recurse far deeper
    // than the operating system's thread stack allows.
    enum mainStackBytes = 4096UL * 1024 * 1024;
    auto mainFiber = new Fiber({
        size_t marker;
        mainStackLimit = cast(size_t)&marker - mainStackBytes + 1024 * 1024;
        mainSoftLimit = cast(size_t)&marker - mainStackBytes + 32UL * 1024 * 1024;
        try {
            result = runMain(argv, state);
        } catch (ExitRequest request) {
            // os.exit(code, true): pending to-be-closed variables are already closed.
            result = request.status;
            if (state !is null) {
                try {
                    state.close();
                } catch (ExitRequest again) {
                    result = again.status;
                }
            }
            fflush(stdout);
        }
    }, mainStackBytes);
    mainFiber.call();
    return result;
}

private size_t mainStackLimit;
private size_t mainSoftLimit;

private int runMain(string[] argv, ref LuaState state) {
    int script;
    int args = collectArgs(argv, script);
    int optlim = script > 0 ? script : cast(int) argv.length;
    if (args == hasError) {
        printUsage(argv[script]);
        return 1;
    }
    state = new LuaState();
    state.mainThread.nativeStackLimit = mainStackLimit;
    state.mainThread.nativeSoftLimit = mainSoftLimit;
    if (args & hasV) {
        writeOut(versionString ~ "\n");
        fflush(stdout);
    }
    if (args & hasEnvFlag)
        state.registry.rawset(LuaValue("LUA_NOENV"), LuaValue(true));
    openLibs(state);
    // lua.c switches the collector to generational mode at startup.
    {
        auto collect = state.globals.rawget(LuaValue("collectgarbage"));
        if (isFunction(collect)) {
            try {
                VM.callValue(state, collect, [LuaValue("generational")]);
            } catch (LuaException) {
            }
        }
    }

    // 'arg' table: script name at index 0, interpreter and options at negative indices.
    {
        auto argTable = new LuaTable();
        long scriptIndex = script;
        foreach (i, a; argv)
            argTable.rawset(LuaValue(cast(long) i - scriptIndex), LuaValue(a));
        state.setGlobal("arg", LuaValue(argTable));
    }

    bool ok = true;
    if (!(args & hasEnvFlag))
        ok = handleLuaInit(state);
    if (ok)
        ok = runArgs(state, argv, optlim);
    if (ok && script > 0)
        ok = handleScript(state, argv, script);
    if (ok) {
        if (args & hasI)
            doREPL(state);
        else if (script < 1 && !(args & (hasE_ | hasV))) {
            if (stdinIsTty()) {
                writeOut(versionString ~ "\n");
                doREPL(state);
            } else
                ok = dofile(state, null);
        }
    }
    state.close();
    fflush(stdout);
    return ok ? 0 : 1;
}
