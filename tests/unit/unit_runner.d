/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Per-test runner for the D unit groups: `mixin UnitMain;` in a test module replaces druntime's
/// default module runner, so one failing test no longer hides the rest and each test is reported
/// as a machine-readable line the suite driver turns into its own result.
module tests.unit.unit_runner;

mixin template UnitMain() {
    shared static this() {
        import core.runtime : Runtime;

        // Suppress druntime's all-or-nothing run; main below runs each unittest individually.
        Runtime.moduleUnitTester = () => true;
    }

    int main(string[] args) {
        import core.time : MonoTime;
        import std.stdio : stderr, writefln;

        string only = args.length > 1 ? args[1] : "";
        size_t failed, ran;
        static foreach (t; __traits(getUnitTests, __traits(parent, main))) {
            {
                enum name = __traits(getAttributes, t)[0];
                if (only.length == 0 || only == name) {
                    ran++;
                    immutable start = MonoTime.currTime;
                    try {
                        t();
                        writefln("[UNIT PASS] %s %.3f", name, (MonoTime.currTime - start).total!"usecs" / 1e6);
                    } catch (Throwable e) {
                        failed++;
                        writefln("[UNIT FAIL] %s %.3f", name, (MonoTime.currTime - start).total!"usecs" / 1e6);
                        stderr.writefln("  %s: %s (%s:%s)", name, e.msg, e.file, e.line);
                    }
                }
            }
        }
        writefln("[UNIT SUMMARY] %s run, %s failed", ran, failed);
        return failed || ran == 0 ? 1 : 0;
    }
}
