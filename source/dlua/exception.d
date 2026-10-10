/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.exception;

import dlua.types;
import std.conv : to;

string shortSourceName(string source) {
    import std.string : indexOf;
    auto nul = source.indexOf('\0');
    if (nul >= 0) source = source[0 .. nul];
    if (source.length && source[0] == '=') return source[1 .. source.length > 60 ? 60 : $];
    if (source.length && source[0] == '@') return source.length <= 60 ? source[1 .. $] : "..." ~ source[$ - 56 .. $];
    auto newline = source.indexOf('\n');
    bool truncated = source.length >= 45 || newline >= 0;
    if (newline >= 0) source = source[0 .. newline];
    if (source.length > 45) source = source[0 .. 45];
    return "[string \"" ~ source ~ (truncated ? "..." : "") ~ "\"]";
}

/// Exception thrown by error() or runtime failures in dlua
class LuaException : Exception {
    LuaValue errorObject;
    int errorLine;
    string errorSource;
    bool needsLocation;
    Object processedBy;
    /// Operand (1 or 2) whose variable name should be appended to the message by the executing frame.
    int culprit;
    /// Innermost native function that raised this error (kept in the traceback of a failed coroutine).
    LuaFunction originFunction;
    string originName, originKind;

    void locate(string source, int line) {
        if (!needsLocation) return;
        needsLocation = false;
        if (line <= 0) return;
        errorSource = source; errorLine = line;
        errorObject = LuaValue(shortSourceName(source) ~ ":" ~ line.to!string ~ ": " ~ toLuaString(errorObject));
        msg = toLuaString(errorObject);
    }

    /// Locates an error raised by Lua code; code without line information reports line -1.
    void locateLua(string source, int line) {
        if (!needsLocation) return;
        if (line <= 0) {
            needsLocation = false;
            errorSource = source; errorLine = -1;
            errorObject = LuaValue(shortSourceName(source) ~ ":-1: " ~ toLuaString(errorObject));
            msg = toLuaString(errorObject);
            return;
        }
        locate(source, line);
    }

    this(string message, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) {
        super(message, file, line, nextInChain);
        this.errorObject = LuaValue(message);
        this.needsLocation = true;
        this.errorLine = cast(int)line;
    }

    this(LuaValue errObj, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) {
        super(toLuaString(errObj), file, line, nextInChain);
        this.errorObject = errObj;
        this.errorLine = cast(int)line;
    }

    this(LuaValue errObj, string source, int line, string file = __FILE__, size_t dLine = __LINE__, Throwable nextInChain = null) {
        super(source ~ ":" ~ line.to!string ~ ": " ~ toLuaString(errObj), file, dLine, nextInChain);
        this.errorObject = errObj;
        this.errorSource = source;
        this.errorLine = line;
    }
}

/// Raised by os.exit(code, true): unwinds the stack (closing pending to-be-closed
/// variables) and lets the host close the state. Not an Exception on purpose, so
/// that pcall and friends cannot swallow it.
class ExitRequest : Error {
    int status;
    this(int status) {
        super("exit requested");
        this.status = status;
    }
}
