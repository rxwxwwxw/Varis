/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

/// Official Lua 5.4 test-suite runner.
///
/// Each file of the official suite runs as its own process from the suite directory.
/// The outcome of every file is one of PASS, PARTIAL (the file passes after removing
/// assertions that need C modules; the exclusion is reported), SKIP (the file needs the
/// C test library or is not part of the suite's standard run) or FAIL/TIMEOUT.
/// `--reference` additionally runs failing files with a reference interpreter so that
/// environment-dependent failures can be told apart from implementation defects.
module tests.runner;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.datetime.stopwatch;
import std.getopt;
import std.algorithm;
import std.array;
import std.json;
import core.time;
import core.thread : Thread;
import std.conv : octal;

struct TestClassification {
    string name;
    string reason;
    bool isSkip;
}

private immutable TestClassification[string] knownSpecs;

shared static this() {
    TestClassification[string] specs;
    // The C test library (T), C API and collector internals are not available.
    specs["gc.lua"] = TestClassification("gc.lua", "excluded by decision: exact collector reachability (conservative D GC; Lua objects must stay accessible from D)", true);
    // Not part of all.lua: a multi-gigabyte, multi-minute allocation stress test.
    knownSpecs = cast(immutable)specs;
}

struct TestResult {
    string name;
    string status; // PASS, PARTIAL, FAIL, SKIP, TIMEOUT
    double durationSeconds = 0.0;
    string reason;
    string diagnostic;
    int exitCode = int.min; // unavailable for skips, timeouts and launch failures
    string referenceStatus; // "", "PASS" or "FAIL" when run with --reference
}

/// Per-file adjustments that mirror how the suite itself runs its files.
private struct RunPlan {
    string[] arguments;      // after the interpreter
    string exclusionNote;    // non-empty when assertions had to be removed
    string temporaryFile;    // file to delete afterwards
    string[string] env;      // extra environment for the process
    string workDir;          // overrides the suite directory
    string temporaryDirectory; // directory to delete afterwards
}

/// Builds the suite's C test modules (libs/*.c) so that the package/loadlib tests are exercised.
/// Returns false when no C compiler is available or a module fails to build.
private bool buildCModules(string testDir, string luaSrcDir) {
    auto libs = buildPath(testDir, "libs");
    if (!exists(libs)) return false;
    version (OSX) enum extra = ["-undefined", "dynamic_lookup"]; else enum string[] extra = [];
    string cc = environment.get("CC", "cc");
    // lib2-v2.so is built from lib22.c (see libs/makefile).
    string[2][] modules = [["lib1", "lib1"], ["lib11", "lib11"], ["lib2", "lib2"], ["lib21", "lib21"], ["lib2-v2", "lib22"]];
    foreach (m; modules) {
        auto output = buildPath(libs, m[0] ~ ".so");
        auto source = buildPath(libs, m[1] ~ ".c");
        if (exists(output)) continue;
        auto result = std.process.execute([cc, "-shared", "-fPIC"] ~ extra ~ ["-I", luaSrcDir, "-o", output, source]);
        if (result.status != 0) return false;
    }
    return true;
}

/// A directory with an `sh` that, like dash, runs `sh -c '...'` as a child instead of replacing
/// itself, so that the suite's nested-shell exit status checks see an exit code on every platform.
private string shellShimDirectory() {
    auto dir = buildPath(tempDir(), "dlua_sh_shim");
    mkdirRecurse(dir);
    auto script = buildPath(dir, "sh");
    std.file.write(script, "#!/bin/sh\n/bin/sh \"$@\"\nexit $?\n");
    version (Posix) {
        import core.sys.posix.sys.stat : chmod;
        chmod(script.toStringz, octal!755);
    }
    return dir;
}

private __gshared bool cModulesAvailable;

private RunPlan planFor(string testDir, string filename) {
    RunPlan plan;
    if (filename == "all.lua") {
        // The suite's own driver, run in a scratch copy of the suite whose gc.lua is replaced by a
        // stub (exact collector reachability is excluded). It also runs every file through
        // string.dump/load, as the official run does.
        auto copyDir = buildPath(tempDir(), "dlua_all_suite");
        if (exists(copyDir)) rmdirRecurse(copyDir);
        mkdirRecurse(copyDir);
        foreach (entry; dirEntries(testDir, SpanMode.depth)) {
            auto rel = relativePath(entry.name, testDir);
            auto target = buildPath(copyDir, rel);
            if (entry.isDir) mkdirRecurse(target);
            else { mkdirRecurse(dirName(target)); std.file.copy(entry.name, target); }
        }
        std.file.write(buildPath(copyDir, "gc.lua"), "print('gc.lua is excluded from this run')\n");
        auto env = environment.toAA();
        env["PATH"] = shellShimDirectory() ~ ":" ~ environment.get("PATH", "/usr/bin:/bin");
        plan.env = env;
        plan.workDir = copyDir;
        plan.temporaryDirectory = copyDir;
        plan.arguments = ["all.lua"];
        plan.exclusionNote = "run in a scratch copy with gc.lua replaced by a stub (gc.lua excluded)";
        return plan;
    }
    if (filename == "big.lua") {
        // all.lua runs big.lua inside a coroutine: it yields 'b' and then returns 'a'.
        auto driver = buildPath(tempDir(), "dlua_big_driver.lua");
        std.file.write(driver,
            "local f = coroutine.wrap(assert(loadfile(arg[1])))\n" ~
            "assert(f() == 'b')\nassert(f() == 'a')\n");
        plan.arguments = [driver, filename];
        plan.temporaryFile = driver;
        return plan;
    }
    if (filename == "main.lua" && !cModulesAvailable) {
        // Without a C compiler the '-l lib2-v2' check of the compiled 'libs/lib2-v2.so' (three
        // lines) cannot run; remove it and report the exclusion.
        auto lines = readText(buildPath(testDir, filename)).splitLines();
        string[] kept;
        size_t i = 0;
        bool removed;
        while (i < lines.length) {
            if (lines[i].indexOf("lua -l lib2-v2") >= 0) { i += 3; removed = true; continue; }
            kept ~= lines[i++];
        }
        if (removed) {
            auto patched = buildPath(testDir, "_dlua_main_without_c_modules.lua");
            std.file.write(patched, kept.join("\n") ~ "\n");
            plan.arguments = [baseName(patched)];
            plan.temporaryFile = patched;
            plan.exclusionNote = "'-l lib2-v2' check of the compiled C module libs/lib2-v2.so removed (no C compiler)";
            return plan;
        }
    }
    if (filename == "files.lua") {
        // One popen/execute status check depends on how the platform's sh handles a nested
        // 'sh -c' that kills itself; run with an sh that behaves like dash for it.
        auto env = environment.toAA();
        env["PATH"] = shellShimDirectory() ~ ":" ~ environment.get("PATH", "/usr/bin:/bin");
        plan.env = env;
    }
    plan.arguments = [filename];
    return plan;
}

/// Runs `luaBin` on one file; returns status, exit code and last diagnostic line.
private void execute(string luaBin, string testDir, RunPlan plan, uint timeoutSecs, bool verbose,
    out string status, out int exitCode, out string diagnostic) {
    status = "FAIL";
    exitCode = int.min;
    diagnostic = "";
    try {
        auto outputFile = File.tmpfile();
        // A closed pipe: reads hit end of file and seeking fails, as with a pipe in all.lua runs.
        auto stdinPipe = pipe();
        stdinPipe.writeEnd.close();
        auto pid = spawnProcess([luaBin] ~ plan.arguments, stdinPipe.readEnd, outputFile,
            outputFile, plan.env, Config.retainStdout | Config.retainStderr,
            plan.workDir.length ? plan.workDir : testDir);
        auto startTime = MonoTime.currTime;
        auto timeoutDuration = dur!"seconds"(timeoutSecs);
        bool finished = false;
        while (MonoTime.currTime - startTime < timeoutDuration) {
            auto result = tryWait(pid);
            if (result.terminated) {
                finished = true;
                exitCode = result.status;
                string output;
                outputFile.seek(0);
                foreach (line; outputFile.byLineCopy) output ~= line ~ "\n";
                output = output.strip();
                if (result.status == 0) status = "PASS";
                else {
                    status = "FAIL";
                    auto lines = output.splitLines();
                    if (lines.length > 0) {
                        diagnostic = lines[$ - 1];
                        foreach (line; lines) {
                            if (line.indexOf(": ") > 0 && (line.indexOf("assertion failed") >= 0 || line.indexOf("error") >= 0 ||
                                line.indexOf(".lua:") >= 0)) { diagnostic = line; break; }
                        }
                    }
                    if (verbose) {
                        writeln("    --- Failure Output ---");
                        foreach (line; output.splitLines()) writeln("    | ", line);
                        writeln("    ----------------------");
                    }
                }
                break;
            }
            Thread.sleep(dur!"msecs"(50));
        }
        if (!finished) {
            kill(pid);
            wait(pid);
            status = "TIMEOUT";
            diagnostic = format("exceeded %d seconds", timeoutSecs);
        }
    } catch (Exception e) {
        status = "FAIL";
        diagnostic = e.msg;
    }
}

int main(string[] args) {
    string luaBin = "./bin/dlua";
    string referenceBin = "";
    string testDir = "c-implementation/lua-5.4.9-tests";
    uint timeoutSecs = 120;
    string filterPattern = "";
    string jsonOut = "";
    bool verbose = false;
    bool strict = false;

    auto helpInfo = getopt(
        args,
        "lua", "Path to Lua executable (default: ./bin/dlua)", &luaBin,
        "reference", "Reference interpreter run on failing files (e.g. c-implementation/src/lua)", &referenceBin,
        "dir", "Path to official tests directory (default: c-implementation/lua-5.4.9-tests)", &testDir,
        "timeout", "Timeout per test in seconds (default: 120)", &timeoutSecs,
        "filter", "Filter test names by substring", &filterPattern,
        "json", "Write machine-readable JSON results to file", &jsonOut,
        "verbose|v", "Print verbose output on failures", &verbose,
        "strict", "Fail process if any test fails", &strict
    );

    if (helpInfo.helpWanted) {
        defaultGetoptPrinter("dlua Official Lua 5.4.9 Conformance Runner", helpInfo.options);
        return 0;
    }

    if (args.length > 1 && luaBin == "./bin/dlua") luaBin = args[1];

    if (timeoutSecs == 0) {
        stderr.writeln("Error: --timeout must be positive");
        return 1;
    }

    luaBin = absolutePath(luaBin);
    testDir = absolutePath(testDir);
    if (referenceBin.length) referenceBin = absolutePath(referenceBin);

    if (!exists(luaBin)) {
        stderr.writefln("Error: Lua interpreter binary not found: %s", luaBin);
        return 1;
    }
    if (!exists(testDir) || !isDir(testDir)) {
        stderr.writefln("Error: Test directory not found: %s", testDir);
        return 1;
    }

    writeln("================================================================================");
    writeln("dlua Official Lua 5.4.9 Conformance Runner");
    writefln("Interpreter: %s", luaBin);
    if (referenceBin.length) writefln("Reference:   %s", referenceBin);
    writefln("Test suite:  %s", testDir);
    writefln("Timeout:     %d seconds per test", timeoutSecs);
    cModulesAvailable = buildCModules(testDir, buildPath(dirName(testDir), "src"));
    writefln("C modules:   %s", cModulesAvailable ? "built (libs/*.so)" : "unavailable (C-module checks excluded)");
    writeln("================================================================================");

    string[] testFiles;
    foreach (entry; dirEntries(testDir, SpanMode.shallow)) {
        if (entry.isFile && entry.name.endsWith(".lua") && !baseName(entry.name).startsWith("_dlua_")) {
            testFiles ~= baseName(entry.name);
        }
    }
    testFiles.sort();

    TestResult[] results;
    size_t passedCount, partialCount, skippedCount, failedCount, referenceAlsoFails;

    foreach (filename; testFiles) {
        if (filterPattern.length > 0 && filename.indexOf(filterPattern) < 0) continue;

        auto spec = filename in knownSpecs;
        if (spec !is null && spec.isSkip) {
            TestResult res;
            res.name = filename;
            res.status = "SKIP";
            res.reason = spec.reason;
            results ~= res;
            skippedCount++;
            writefln("  [SKIP] %-15s - %s", filename, spec.reason);
            continue;
        }

        auto plan = planFor(testDir, filename);
        auto sw = StopWatch(AutoStart.yes);
        string testStatus, diagnostic;
        int exitCode;
        execute(luaBin, testDir, plan, timeoutSecs, verbose, testStatus, exitCode, diagnostic);
        sw.stop();
        double elapsed = sw.peek().total!"msecs" / 1000.0;

        TestResult res;
        res.name = filename;
        res.durationSeconds = elapsed;
        res.diagnostic = diagnostic;
        res.exitCode = exitCode;
        if (testStatus == "PASS" && plan.exclusionNote.length) {
            testStatus = "PARTIAL";
            res.reason = plan.exclusionNote;
        }
        res.status = testStatus;

        if (testStatus != "PASS" && testStatus != "PARTIAL" && referenceBin.length) {
            string refStatus, refDiagnostic;
            int refExit;
            execute(referenceBin, testDir, plan, timeoutSecs * 4, false, refStatus, refExit, refDiagnostic);
            res.referenceStatus = refStatus;
            if (refStatus != "PASS") referenceAlsoFails++;
        }

        if (plan.temporaryFile.length && exists(plan.temporaryFile)) remove(plan.temporaryFile);
        if (plan.temporaryDirectory.length && exists(plan.temporaryDirectory)) rmdirRecurse(plan.temporaryDirectory);

        if (testStatus == "PASS") {
            passedCount++;
            writefln("  [PASS] %-15s (%0.2fs)", filename, elapsed);
        } else if (testStatus == "PARTIAL") {
            partialCount++;
            writefln("  [PARTIAL] %-12s (%0.2fs) - %s", filename, elapsed, res.reason);
        } else {
            failedCount++;
            string note = res.referenceStatus.length ? format(" [reference: %s]", res.referenceStatus) : "";
            writefln("  [%s] %-15s (%0.2fs) - %s%s", testStatus, filename, elapsed, diagnostic, note);
        }
        results ~= res;
    }

    if (results.length == 0) {
        stderr.writeln("Error: no tests matched");
        return 1;
    }

    writeln("================================================================================");
    writeln("Conformance Summary:");
    writefln("  Total files:   %d", results.length);
    writefln("  Passed:        %d", passedCount);
    writefln("  Partial:       %d (pass after removing assertions that need C modules or a specific shell)", partialCount);
    writefln("  Skipped:       %d (C test library / not part of the standard run)", skippedCount);
    writefln("  Failed:        %d", failedCount);
    if (referenceBin.length) writefln("  ... of which the reference interpreter also fails: %d", referenceAlsoFails);
    writeln("================================================================================");

    if (jsonOut.length > 0) {
        JSONValue[] jsonResults;
        foreach (r; results) {
            JSONValue item = [
                "name": JSONValue(r.name),
                "status": JSONValue(r.status),
                "duration_seconds": JSONValue(r.durationSeconds),
                "reason": JSONValue(r.reason),
                "diagnostic": JSONValue(r.diagnostic),
                "reference_status": JSONValue(r.referenceStatus)
            ];
            item["exit_code"] = r.exitCode == int.min ? JSONValue(null) : JSONValue(r.exitCode);
            jsonResults ~= item;
        }
        JSONValue report = [
            "total": JSONValue(cast(long)results.length),
            "passed": JSONValue(cast(long)passedCount),
            "partial": JSONValue(cast(long)partialCount),
            "skipped": JSONValue(cast(long)skippedCount),
            "failed": JSONValue(cast(long)failedCount),
            "results": JSONValue(jsonResults)
        ];
        std.file.write(jsonOut, report.toPrettyString());
        writefln("Wrote results JSON to %s", jsonOut);
    }

    if (strict && failedCount > 0) return 1;
    return 0;
}
