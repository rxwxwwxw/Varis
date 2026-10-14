/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Coroutine library: a port of lcorolib.c on top of D fibers.
module varis.lib.coroutine;

import varis.types;
import varis.table;
import varis.state;
import varis.fiber;
import varis.fiber : isNoYieldScope, isReadOnlyEvaluation, isNotificationDispatch;
import varis.exception : LuaException;
import varis.lib.auxlib;
import core.thread : Fiber;

private enum maxResumeDepth = 195;

private bool argThread(LuaState L, LuaValue[] a, int n, out LuaThread result) {
    if (n <= a.length && a[n - 1].typeOf() == LuaType.Thread) {
        result = a[n - 1].match!((LuaThread t) => t, _ => null);
        return true;
    }
    return typeFail(L, a, n, "thread");
}

/// Runs `th` until it yields or finishes. Returns false (with the error object in `error`) on failure.
private bool resumeThread(LuaState L, LuaThread th, LuaValue[] args, out LuaValue[] results, out LuaValue error, out bool ranAndFailed) {
    ranAndFailed = false;
    auto fib = th.fiber is null ? null : cast(VarisFiber) cast(void*) th.fiber; // unchecked: only VarisFibers are stored
    string failure;
    if (fib is null || fib.state == Fiber.State.TERM || th.status == "dead")
        failure = "cannot resume dead coroutine";
    else if (th.status != "suspended")
        failure = "cannot resume non-suspended coroutine";
    if (failure !is null) {
        error = LuaValue(failure);
        return false;
    }
    auto resumer = L.currentThread();
    if (resumer !is null && resumer.cCalls >= 200 - 5) {
        error = LuaValue("C stack overflow");
        return false;
    }

    auto parent = L.currentThread();
    string parentStatus = parent is null ? "" : parent.status;
    if (parent !is null)
        parent.status = "normal";
    // Arguments may be a view of the resumer's registers: the first resume turns them into the
    // coroutine function's parameters (and varargs), which outlive the resumer's frame state.
    fib.resumeArgs = fib.started ? args : args.dup;
    th.status = "running";
    th.cCalls = parent is null ? 1 : parent.cCalls + 1;
    ++L.resumeDepth;
    scope (exit) {
        --L.resumeDepth;
        if (parent !is null)
            parent.status = parentStatus;
    }
    callFiber(fib);

    if (fib.exitSignal !is null) {
        // `os.exit(code, true)` ran in the coroutine: it ends it and goes on in the resumer.
        th.status = "dead";
        L.raisedError = fib.exitSignal;
        fib.exitSignal = null;
        return false;
    }
    if (fib.hasError || fib.state == Fiber.State.TERM) {
        th.status = "dead";
        if (fib.hasError) {
            error = fib.errorObject;
            ranAndFailed = true;
            return false;
        }
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
        th.hookMask = parent.hookMask;
        th.hookCount = parent.hookCount;
        th.hookRemaining = parent.hookCount;
        {
            import varis.state : syncThreadHook;

            syncThreadHook(th);
        }
    }
    auto fib = new VarisFiber(fn, cast(void*) L);
    th.fiber = fib;
    fib.thread = th;
    th.status = "suspended";
    return th;
}

/// The function `coroutine.wrap` returns; keeps its coroutine reachable for `fastWrapCall`.
private final class WrapFunction : LuaNativeFunction {
    LuaThread thread;
    VarisFiber fiber;
    /// A resume the fast path ran and that failed: the generic call that follows reports it.
    bool failurePending;
    LuaException pendingExit;
    LuaValue pendingError;
    bool pendingRanAndFailed;
    this(NativeDelegate fn, string name) {
        super(fn, name);
    }
}

/// Raises the error of a failed `wrap` resume: a coroutine that failed while running is closed,
/// and string errors get position information.
private LuaException wrapFailure(LuaState S, LuaThread th, VarisFiber fib, LuaValue error, bool ranAndFailed) {
    if (ranAndFailed && fib !is null) {
        auto closed = fib.closeThread();
        if (fib.exitSignal !is null) {
            // a close handler exited: that is the failure
            auto exit = fib.exitSignal;
            fib.exitSignal = null;
            return exit;
        }
        if (closed.length > 1)
            error = closed[1];
    }
    if (isString(error))
        error = LuaValue(S.locationPrefix(1) ~ toLuaString(error));
    auto failure = new LuaException(error);
    failure.needsLocation = false;
    return failure;
}

/// Allocation-free call of a wrap function from the interpreter: resumes a started, suspended
/// coroutine with a view of the argument registers and writes the yielded values into place.
/// Anything unusual (first resume, dead coroutine, deep C stack, results that do not fit the
/// register array) takes the generic path, which has identical behaviour.
private int fastWrapCall(void* sp, LuaValue[] r, int base, int n) {
    auto w = cast(WrapFunction) cast(void*) r[base].asFunction;
    auto S = cast(LuaState) sp;
    auto th = w.thread;
    auto fib = w.fiber;
    if (fib is null || !fib.started || fib.state == Fiber.State.TERM || th.status != "suspended")
        return -1;
    auto resumer = S.currentThread();
    if (resumer !is null && resumer.cCalls >= 200 - 5)
        return -1;
    LuaValue[] results;
    LuaValue error;
    bool ranAndFailed;
    if (!resumeThread(S, th, r[base + 1 .. base + 1 + n], results, error, ranAndFailed)) {
        // The coroutine ran (and failed). Decline: the generic call that follows takes the failure
        // from the function and reports it from a native frame, as it always did.
        if (S.raisedError !is null) {
            // An exit: the generic call that follows passes it on.
            w.pendingExit = S.takeRaised();
            return -1;
        }
        w.failurePending = true;
        w.pendingError = error;
        w.pendingRanAndFailed = ranAndFailed;
        return -1;
    }
    if (base + results.length > r.length) {
        S.stashedResults = results;
        return -2 - cast(int) results.length;
    }
    foreach (i, ref value; results)
        r[base + i] = value;
    return cast(int) results.length;
}

void openCoroutineLib(LuaState state) {
    auto coroLib = new LuaTable();

    coroLib.register("create", (LuaState L, LuaValue[] a) {
        if (a.length < 1 || !isFunction(a[0])) {
            typeFail(L, a, 1, "function");
            return null;
        }
        return [LuaValue(newThread(L, a[0].match!((LuaFunction f) => f, _ => null)))];
    });

    coroLib.register("resume", (LuaState L, LuaValue[] a) {
        LuaThread th;
        if (!argThread(L, a, 1, th))
            return null;
        LuaValue[] results;
        LuaValue error;
        bool ranAndFailed;
        if (!resumeThread(L, th, a.length > 1 ? a[1 .. $] : [], results, error, ranAndFailed)) {
            if (L.raisedError !is null)
                return null; // an exit passes through
            return [LuaValue(false), error];
        }
        auto all = new LuaValue[results.length + 1];
        all[0] = LuaValue(true);
        all[1 .. $] = results[];
        return all;
    });

    coroLib.register("yield", (LuaState L, LuaValue[] a) {
        auto currentFib = currentLuaFiber();
        if (currentFib is null)
            return raise(L, new LuaException("attempt to yield from outside a coroutine"));
        if (!currentFib.isYieldAllowed)
            return raise(L, new LuaException("attempt to yield across a C-call boundary"));
        if (!currentFib.yieldExecution(a))
            return raise(L, new LuaException("attempt to yield across a C-call boundary"));
        if (currentFib.closing)
            return raise(L, new CloseSignal()); // the coroutine is being closed: unwind its frames
        return currentFib.resumeArgs;
    });

    coroLib.register("status", (LuaState L, LuaValue[] a) {
        LuaThread th;
        if (!argThread(L, a, 1, th))
            return null;
        auto current = L.currentThread();
        if (th is current)
            return [LuaValue("running")];
        return [LuaValue(th.status == "running" ? "normal" : th.status)];
    });

    coroLib.register("close", (LuaState L, LuaValue[] a) {
        LuaThread thread;
        if (!argThread(L, a, 1, thread))
            return null;
        auto fiber = cast(VarisFiber) thread.fiber;
        auto current = L.currentThread();
        if (thread.status == "running" || thread.status == "normal" || thread is current) {
            string kind = thread is current ? "running" : "normal";
            return raise(L, new LuaException("cannot close a " ~ kind ~ " coroutine"));
        }
        if (current !is null && current.cCalls >= 195)
            return [LuaValue(false), LuaValue("C stack overflow")];
        if (fiber is null)
            return [LuaValue(true)];
        thread.cCalls = current is null ? 1 : current.cCalls + 1;
        auto closed = fiber.closeThread();
        if (fiber.exitSignal !is null) {
            auto exit = fiber.exitSignal;
            fiber.exitSignal = null;
            return raise(L, exit); // a close handler called os.exit(code, true)
        }
        return closed;
    });

    coroLib.register("running", (LuaState L, LuaValue[] a) {
        auto current = currentLuaFiber();
        return [LuaValue(L.currentThread()), LuaValue(current is null)];
    });

    coroLib.register("isyieldable", (LuaState L, LuaValue[] a) {
        auto current = currentLuaFiber();
        auto target = current;
        if (a.length >= 1) {
            LuaThread th;
            if (!argThread(L, a, 1, th))
                return null;
            target = cast(VarisFiber) th.fiber;
            if (th is L.mainThread)
                target = null;
        }
        bool allowed = target !is null && target.isYieldAllowed;
        if (target is current)
            allowed = allowed && !isNoYieldScope() && !isReadOnlyEvaluation() && !isNotificationDispatch();
        return [LuaValue(allowed)];
    });

    coroLib.register("wrap", (LuaState L, LuaValue[] a) {
        if (a.length < 1 || !isFunction(a[0])) {
            typeFail(L, a, 1, "function");
            return null;
        }
        auto th = newThread(L, a[0].match!((LuaFunction f) => f, _ => null));
        auto fib = cast(VarisFiber) th.fiber;
        WrapFunction wrapFn;
        wrapFn = new WrapFunction((void* st, LuaValue[] callArgs) {
            auto S = cast(LuaState) st;
            if (wrapFn.pendingExit !is null) {
                auto exit = wrapFn.pendingExit;
                wrapFn.pendingExit = null;
                return raise(S, exit);
            }
            if (wrapFn.failurePending) {
                wrapFn.failurePending = false;
                auto pending = wrapFn.pendingError;
                wrapFn.pendingError = luaNil();
                return raise(S, wrapFailure(S, th, fib, pending, wrapFn.pendingRanAndFailed));
            }
            LuaValue[] results;
            LuaValue error;
            bool ranAndFailed;
            if (!resumeThread(S, th, callArgs, results, error, ranAndFailed)) {
                if (S.raisedError !is null)
                    return null; // an exit passes through
                return raise(S, wrapFailure(S, th, fib, error, ranAndFailed));
            }
            return results;
        }, "wrap_fn");
        wrapFn.thread = th;
        wrapFn.fiber = fib;
        wrapFn.fastCall = &fastWrapCall;
        wrapFn.borrowsArgs = true;
        return [LuaValue(wrapFn)];
    });

    // These natives consume (or copy) their arguments before the caller's registers can change.
    foreach (name; ["resume", "yield"]) {
        auto native = coroLib.rawget(LuaValue(name));
        if (native.isFunction)
            native.asFunction.borrowsArgs = true;
    }

    state.setGlobal("coroutine", LuaValue(coroLib));
}
