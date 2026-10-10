/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

/// Coroutine library: a port of lcorolib.c on top of D fibers.
module dlua.lib.coroutine;

import dlua.types;
import dlua.table;
import dlua.state;
import dlua.fiber;
import dlua.logic.world : isNoYieldScope, isReadOnlyEvaluation, isNotificationDispatch;
import dlua.exception : LuaException;
import dlua.lib.auxlib;
import core.thread : Fiber;

private enum maxResumeDepth = 195;

private LuaThread checkThread(LuaState L, LuaValue[] a, int n) {
    if (n <= a.length && a[n - 1].typeOf() == LuaType.Thread) return a[n - 1].match!((LuaThread t) => t, _ => null);
    typeError(L, a, n, "thread");
    assert(0);
}

/// Runs `th` until it yields or finishes. Returns false (with the error object in `error`) on failure.
private bool resumeThread(LuaState L, LuaThread th, LuaValue[] args, out LuaValue[] results, out LuaValue error, out bool ranAndFailed) {
    ranAndFailed = false;
    auto fib = cast(DluaFiber)th.fiber;
    string failure;
    if (fib is null || fib.state == Fiber.State.TERM || th.status == "dead") failure = "cannot resume dead coroutine";
    else if (th.status != "suspended") failure = "cannot resume non-suspended coroutine";
    if (failure !is null) { error = LuaValue(failure); return false; }
    auto resumer = L.currentThread();
    if (resumer !is null && resumer.cCalls >= 200 - 5) { error = LuaValue("C stack overflow"); return false; }

    auto parent = L.currentThread();
    string parentStatus = parent is null ? "" : parent.status;
    if (parent !is null) parent.status = "normal";
    fib.resumeArgs = args;
    th.status = "running";
    th.cCalls = parent is null ? 1 : parent.cCalls + 1;
    ++L.resumeDepth;
    scope(exit) {
        --L.resumeDepth;
        if (parent !is null) parent.status = parentStatus;
    }
    fib.call();

    if (fib.hasError || fib.state == Fiber.State.TERM) {
        th.status = "dead";
        if (fib.hasError) { error = fib.errorObject; ranAndFailed = true; return false; }
        results = fib.returnResults;
        return true;
    }
    th.status = "suspended";
    results = fib.yieldResults;
    return true;
}

private LuaThread newThread(LuaState L, LuaFunction fn) {
    auto th = new LuaThread(fn);
    auto parent = L.currentThread();
    if (parent !is null) {
        th.hookMask = parent.hookMask; th.hookCount = parent.hookCount; th.hookRemaining = parent.hookCount;
    }
    auto fib = new DluaFiber(fn, cast(void*)L);
    th.fiber = fib;
    fib.thread = th;
    th.status = "suspended";
    return th;
}

void openCoroutineLib(LuaState state) {
    auto coroLib = new LuaTable();

    coroLib.register("create", (LuaState L, LuaValue[] a) {
        if (a.length < 1 || !isFunction(a[0])) typeError(L, a, 1, "function");
        return [LuaValue(newThread(L, a[0].match!((LuaFunction f) => f, _ => null)))];
    });

    coroLib.register("resume", (LuaState L, LuaValue[] a) {
        auto th = checkThread(L, a, 1);
        LuaValue[] results;
        LuaValue error;
        bool ranAndFailed;
        if (!resumeThread(L, th, a.length > 1 ? a[1 .. $] : [], results, error, ranAndFailed)) return [LuaValue(false), error];
        return [LuaValue(true)] ~ results;
    });

    coroLib.register("yield", (LuaState L, LuaValue[] a) {
        auto currentFib = cast(DluaFiber)Fiber.getThis();
        if (currentFib is null) throw new LuaException("attempt to yield from outside a coroutine");
        if (!currentFib.isYieldAllowed) throw new LuaException("attempt to yield across a C-call boundary");
        currentFib.yieldExecution(a);
        return currentFib.resumeArgs;
    });

    coroLib.register("status", (LuaState L, LuaValue[] a) {
        auto th = checkThread(L, a, 1);
        auto current = L.currentThread();
        if (th is current) return [LuaValue("running")];
        return [LuaValue(th.status == "running" ? "normal" : th.status)];
    });

    coroLib.register("close", (LuaState L, LuaValue[] a) {
        auto thread = checkThread(L, a, 1);
        auto fiber = cast(DluaFiber)thread.fiber;
        auto current = L.currentThread();
        if (thread.status == "running" || thread.status == "normal" || thread is current) {
            string kind = thread is current ? "running" : "normal";
            throw new LuaException("cannot close a " ~ kind ~ " coroutine");
        }
        if (current !is null && current.cCalls >= 195) return [LuaValue(false), LuaValue("C stack overflow")];
        if (fiber is null) return [LuaValue(true)];
        thread.cCalls = current is null ? 1 : current.cCalls + 1;
        return fiber.closeThread();
    });

    coroLib.register("running", (LuaState L, LuaValue[] a) {
        auto current = cast(DluaFiber)Fiber.getThis();
        return [LuaValue(L.currentThread()), LuaValue(current is null)];
    });

    coroLib.register("isyieldable", (LuaState L, LuaValue[] a) {
        auto current = cast(DluaFiber)Fiber.getThis();
        auto target = current;
        if (a.length >= 1) {
            auto th = checkThread(L, a, 1);
            target = cast(DluaFiber)th.fiber;
            if (th is L.mainThread) target = null;
        }
        bool allowed = target !is null && target.isYieldAllowed;
        if (target is current) allowed = allowed && !isNoYieldScope() && !isReadOnlyEvaluation() && !isNotificationDispatch();
        return [LuaValue(allowed)];
    });

    coroLib.register("wrap", (LuaState L, LuaValue[] a) {
        if (a.length < 1 || !isFunction(a[0])) typeError(L, a, 1, "function");
        auto th = newThread(L, a[0].match!((LuaFunction f) => f, _ => null));
        auto fib = cast(DluaFiber)th.fiber;
        auto wrapFn = new LuaNativeFunction((void* st, LuaValue[] callArgs) {
            auto S = cast(LuaState)st;
            LuaValue[] results;
            LuaValue error;
            bool ranAndFailed;
            if (!resumeThread(S, th, callArgs, results, error, ranAndFailed)) {
                // A coroutine that failed while running is closed; string errors get position information.
                if (ranAndFailed && fib !is null) { auto closed = fib.closeThread(); if (closed.length > 1) error = closed[1]; }
                if (isString(error)) error = LuaValue(S.locationPrefix(1) ~ toLuaString(error));
                auto failure = new LuaException(error);
                failure.needsLocation = false;
                throw failure;
            }
            return results;
        }, "wrap_fn");
        return [LuaValue(wrapFn)];
    });

    state.setGlobal("coroutine", LuaValue(coroLib));
}
