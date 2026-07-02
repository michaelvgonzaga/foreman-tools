const std = @import("std");

const RunResult = struct { stdout: []u8, stderr: []u8, exit: i32 };

fn writeStressScript(io: std.Io, abs_path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, abs_path, .{});
    defer file.close(io);
    var buf: [512]u8 = undefined;
    var w = file.writerStreaming(io, &buf);
    try w.interface.writeAll(content);
    try w.interface.flush();
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    binary: []const u8,
    repo: []const u8,
    pass: u32 = 0,
    fail: u32 = 0,

    fn run(ctx: *Ctx, argv: []const []const u8) !RunResult {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(ctx.gpa);
        try full.append(ctx.gpa, ctx.binary);
        for (argv) |a| try full.append(ctx.gpa, a);
        const r = try std.process.run(ctx.gpa, ctx.io, .{ .argv = full.items });
        return .{
            .stdout = r.stdout,
            .stderr = r.stderr,
            .exit = switch (r.term) {
                .exited => |c| c,
                else => -1,
            },
        };
    }

    // Same as run, but executes with the given cwd — needed to exercise
    // relative-path args ("." etc.) the way a real user actually invokes
    // this tool. `run` above always passes absolute paths, which is exactly
    // why the 2026-07-02 *Absolute-API-vs-relative-path bug shipped
    // undetected — no test ever ran a subcommand from inside a project dir.
    fn runIn(ctx: *Ctx, cwd: []const u8, argv: []const []const u8) !RunResult {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(ctx.gpa);
        try full.append(ctx.gpa, ctx.binary);
        for (argv) |a| try full.append(ctx.gpa, a);
        const r = try std.process.run(ctx.gpa, ctx.io, .{ .argv = full.items, .cwd = .{ .path = cwd } });
        return .{
            .stdout = r.stdout,
            .stderr = r.stderr,
            .exit = switch (r.term) {
                .exited => |c| c,
                else => -1,
            },
        };
    }

    // Tier 4: relative-path regression — expect exit 0 + valid JSON, same as smoke
    fn smokeIn(ctx: *Ctx, label: []const u8, cwd: []const u8, argv: []const []const u8) void {
        const r = ctx.runIn(cwd, argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stderr);
        defer ctx.gpa.free(r.stdout);
        if (r.exit != 0) {
            std.debug.print("[FAIL] {s}: exit {d} (expected 0) stderr={s}\n", .{ label, r.exit, r.stderr });
            ctx.fail += 1;
            return;
        }
        const parsed = ctx.parseJson(label, r.stdout) orelse return;
        parsed.deinit();
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    // Tier 4: relative-path regression — expect a clean exit code, not a crash
    // (crash = process killed by signal, term != .exited, caught by `else => -1`)
    fn badIn(ctx: *Ctx, label: []const u8, cwd: []const u8, argv: []const []const u8, want_exit: i32) void {
        const r = ctx.runIn(cwd, argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stdout);
        defer ctx.gpa.free(r.stderr);
        if (r.exit != want_exit) {
            std.debug.print("[FAIL] {s}: exit {d} (expected {d})\n", .{ label, r.exit, want_exit });
            ctx.fail += 1;
            return;
        }
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    fn parseJson(ctx: *Ctx, label: []const u8, stdout: []const u8) ?std.json.Parsed(std.json.Value) {
        const trimmed = std.mem.trim(u8, stdout, " \t\n\r");
        return std.json.parseFromSlice(std.json.Value, ctx.gpa, trimmed, .{}) catch {
            std.debug.print("[FAIL] {s}: invalid JSON output\n", .{label});
            ctx.fail += 1;
            return null;
        };
    }

    // Tier 1: exit 0 + valid JSON
    fn smoke(ctx: *Ctx, label: []const u8, argv: []const []const u8) void {
        const r = ctx.run(argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stderr);
        defer ctx.gpa.free(r.stdout);
        if (r.exit != 0) {
            std.debug.print("[FAIL] {s}: exit {d} (expected 0)\n", .{ label, r.exit });
            ctx.fail += 1;
            return;
        }
        const parsed = ctx.parseJson(label, r.stdout) orelse return;
        parsed.deinit();
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    // Tier 3: expect specific exit code (usually 1 for bad inputs)
    fn bad(ctx: *Ctx, label: []const u8, argv: []const []const u8, want_exit: i32) void {
        const r = ctx.run(argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stdout);
        defer ctx.gpa.free(r.stderr);
        if (r.exit != want_exit) {
            std.debug.print("[FAIL] {s}: exit {d} (expected {d})\n", .{ label, r.exit, want_exit });
            ctx.fail += 1;
            return;
        }
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    // Tier 2: check bool field in JSON object
    fn checkBool(ctx: *Ctx, label: []const u8, argv: []const []const u8, field: []const u8, want: bool) void {
        const r = ctx.run(argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stderr);
        defer ctx.gpa.free(r.stdout);
        if (r.exit != 0) {
            std.debug.print("[FAIL] {s}: exit {d}\n", .{ label, r.exit });
            ctx.fail += 1;
            return;
        }
        const parsed = ctx.parseJson(label, r.stdout) orelse return;
        defer parsed.deinit();
        if (parsed.value != .object) {
            std.debug.print("[FAIL] {s}: not a JSON object\n", .{label});
            ctx.fail += 1;
            return;
        }
        const val = parsed.value.object.get(field) orelse {
            std.debug.print("[FAIL] {s}: missing field '{s}'\n", .{ label, field });
            ctx.fail += 1;
            return;
        };
        if (val != .bool or val.bool != want) {
            std.debug.print("[FAIL] {s}: '{s}' = {?}, expected {}\n", .{ label, field, if (val == .bool) val.bool else null, want });
            ctx.fail += 1;
            return;
        }
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    // Tier 2: check string field equals expected
    fn checkStr(ctx: *Ctx, label: []const u8, argv: []const []const u8, field: []const u8, want: []const u8) void {
        const r = ctx.run(argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stderr);
        defer ctx.gpa.free(r.stdout);
        if (r.exit != 0) {
            std.debug.print("[FAIL] {s}: exit {d}\n", .{ label, r.exit });
            ctx.fail += 1;
            return;
        }
        const parsed = ctx.parseJson(label, r.stdout) orelse return;
        defer parsed.deinit();
        if (parsed.value != .object) {
            std.debug.print("[FAIL] {s}: not a JSON object\n", .{label});
            ctx.fail += 1;
            return;
        }
        const val = parsed.value.object.get(field) orelse {
            std.debug.print("[FAIL] {s}: missing field '{s}'\n", .{ label, field });
            ctx.fail += 1;
            return;
        };
        if (val != .string or !std.mem.eql(u8, val.string, want)) {
            std.debug.print("[FAIL] {s}: '{s}' = '{s}', want '{s}'\n", .{
                label, field, if (val == .string) val.string else "(not string)", want,
            });
            ctx.fail += 1;
            return;
        }
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    // Tier 2: check string field contains needle
    fn checkStrContains(ctx: *Ctx, label: []const u8, argv: []const []const u8, field: []const u8, needle: []const u8) void {
        const r = ctx.run(argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stderr);
        defer ctx.gpa.free(r.stdout);
        if (r.exit != 0) {
            std.debug.print("[FAIL] {s}: exit {d}\n", .{ label, r.exit });
            ctx.fail += 1;
            return;
        }
        const parsed = ctx.parseJson(label, r.stdout) orelse return;
        defer parsed.deinit();
        if (parsed.value != .object) {
            std.debug.print("[FAIL] {s}: not a JSON object\n", .{label});
            ctx.fail += 1;
            return;
        }
        const val = parsed.value.object.get(field) orelse {
            std.debug.print("[FAIL] {s}: missing field '{s}'\n", .{ label, field });
            ctx.fail += 1;
            return;
        };
        if (val != .string or std.mem.indexOf(u8, val.string, needle) == null) {
            std.debug.print("[FAIL] {s}: '{s}' = '{s}' does not contain '{s}'\n", .{
                label, field, if (val == .string) val.string else "(not string)", needle,
            });
            ctx.fail += 1;
            return;
        }
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    // Tier 2: check integer field > threshold
    fn checkIntGt(ctx: *Ctx, label: []const u8, argv: []const []const u8, field: []const u8, threshold: i64) void {
        const r = ctx.run(argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stderr);
        defer ctx.gpa.free(r.stdout);
        if (r.exit != 0) {
            std.debug.print("[FAIL] {s}: exit {d}\n", .{ label, r.exit });
            ctx.fail += 1;
            return;
        }
        const parsed = ctx.parseJson(label, r.stdout) orelse return;
        defer parsed.deinit();
        if (parsed.value != .object) {
            std.debug.print("[FAIL] {s}: not a JSON object\n", .{label});
            ctx.fail += 1;
            return;
        }
        const val = parsed.value.object.get(field) orelse {
            std.debug.print("[FAIL] {s}: missing field '{s}'\n", .{ label, field });
            ctx.fail += 1;
            return;
        };
        if (val != .integer or val.integer <= threshold) {
            std.debug.print("[FAIL] {s}: '{s}' = {?d}, expected > {d}\n", .{
                label, field, if (val == .integer) val.integer else null, threshold,
            });
            ctx.fail += 1;
            return;
        }
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    // Tier 2: check array field in object has >= min_len items
    fn checkArrayLen(ctx: *Ctx, label: []const u8, argv: []const []const u8, field: []const u8, min_len: usize) void {
        const r = ctx.run(argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stderr);
        defer ctx.gpa.free(r.stdout);
        if (r.exit != 0) {
            std.debug.print("[FAIL] {s}: exit {d}\n", .{ label, r.exit });
            ctx.fail += 1;
            return;
        }
        const parsed = ctx.parseJson(label, r.stdout) orelse return;
        defer parsed.deinit();
        if (parsed.value != .object) {
            std.debug.print("[FAIL] {s}: not a JSON object\n", .{label});
            ctx.fail += 1;
            return;
        }
        const val = parsed.value.object.get(field) orelse {
            std.debug.print("[FAIL] {s}: missing field '{s}'\n", .{ label, field });
            ctx.fail += 1;
            return;
        };
        if (val != .array or val.array.items.len < min_len) {
            std.debug.print("[FAIL] {s}: '{s}'.len = {d}, expected >= {d}\n", .{
                label, field, if (val == .array) val.array.items.len else 0, min_len,
            });
            ctx.fail += 1;
            return;
        }
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    // Tier 2: check string field has exact length
    fn checkStrLen(ctx: *Ctx, label: []const u8, argv: []const []const u8, field: []const u8, want_len: usize) void {
        const r = ctx.run(argv) catch |e| {
            std.debug.print("[FAIL] {s}: spawn error {s}\n", .{ label, @errorName(e) });
            ctx.fail += 1;
            return;
        };
        defer ctx.gpa.free(r.stderr);
        defer ctx.gpa.free(r.stdout);
        if (r.exit != 0) {
            std.debug.print("[FAIL] {s}: exit {d}\n", .{ label, r.exit });
            ctx.fail += 1;
            return;
        }
        const parsed = ctx.parseJson(label, r.stdout) orelse return;
        defer parsed.deinit();
        if (parsed.value != .object) {
            std.debug.print("[FAIL] {s}: not a JSON object\n", .{label});
            ctx.fail += 1;
            return;
        }
        const val = parsed.value.object.get(field) orelse {
            std.debug.print("[FAIL] {s}: missing field '{s}'\n", .{ label, field });
            ctx.fail += 1;
            return;
        };
        if (val != .string or val.string.len != want_len) {
            std.debug.print("[FAIL] {s}: '{s}' len={d}, expected {d}\n", .{
                label, field, if (val == .string) val.string.len else 0, want_len,
            });
            ctx.fail += 1;
            return;
        }
        std.debug.print("[PASS] {s}\n", .{label});
        ctx.pass += 1;
    }

    fn header(_: *Ctx, title: []const u8) void {
        std.debug.print("\n=== {s} ===\n", .{title});
    }

    fn summary(ctx: *Ctx) void {
        const total = ctx.pass + ctx.fail;
        if (ctx.fail == 0) {
            std.debug.print("\n[PASS] {d}/{d} — all tests passed\n", .{ ctx.pass, total });
        } else {
            std.debug.print("\n[FAIL] {d}/{d} passed, {d} failed\n", .{ ctx.pass, total, ctx.fail });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3) {
        const stderr = std.Io.File.stderr();
        var buf: [128]u8 = undefined;
        var w = stderr.writerStreaming(io, &buf);
        try w.interface.print("usage: foreman-stress <binary> <repo-root>\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    }

    const binary = args[1];
    const repo = args[2];
    const root_zig = try std.fs.path.join(gpa, &.{ repo, "src", "root.zig" });
    defer gpa.free(root_zig);

    var ctx = Ctx{ .gpa = gpa, .io = io, .binary = binary, .repo = repo };

    // ----------------------------------------------------------------
    // Tier 1: Smoke — every subcommand gets a valid invocation
    // Expected: exit 0 + valid JSON output
    // ----------------------------------------------------------------
    ctx.header("Tier 1: Smoke (exit 0 + valid JSON)");
    ctx.smoke("doctor", &.{"doctor"});
    ctx.smoke("registry", &.{"registry"});
    ctx.smoke("metrics", &.{"metrics"});
    ctx.smoke("gh-user", &.{"gh-user"});
    ctx.smoke("repo-info", &.{ "repo-info", repo });
    ctx.smoke("release-info", &.{ "release-info", repo });
    ctx.smoke("capability-check git status", &.{ "capability-check", "git", "status" });
    ctx.smoke("capability-promote ls -la", &.{ "capability-promote", "ls", "-la" });
    ctx.smoke("sandbox-check git status", &.{ "sandbox-check", "git", "status" });
    ctx.smoke("route list changed files", &.{ "route", "list", "changed", "files" });
    ctx.smoke("ant default (24h)", &.{ "ant", repo });
    ctx.smoke("ant --since 0 (all time)", &.{ "ant", repo, "--since", "0" });
    ctx.smoke("scan", &.{ "scan", repo });
    ctx.smoke("context-scan", &.{ "context-scan", repo });
    ctx.smoke("list-dir", &.{ "list-dir", repo });
    ctx.smoke("find-files *.zig", &.{ "find-files", repo, "*.zig" });
    ctx.smoke("outline root.zig", &.{ "outline", root_zig });
    ctx.smoke("file-stats root.zig", &.{ "file-stats", root_zig });
    ctx.smoke("file-hash root.zig", &.{ "file-hash", root_zig });
    ctx.smoke("env-scan", &.{ "env-scan", repo });
    ctx.smoke("git-cache", &.{ "git-cache", repo });
    ctx.smoke("git-diff", &.{ "git-diff", repo });
    ctx.smoke("commits", &.{ "commits", repo });
    ctx.smoke("context-changed", &.{ "context-changed", repo });
    ctx.smoke("delta-context", &.{ "delta-context", repo });
    ctx.bad("deps no-manifest repo → exit 1", &.{ "deps", repo }, 1);
    ctx.smoke("status", &.{ "status", repo });
    ctx.smoke("build", &.{ "build", repo });
    ctx.smoke("run-tests", &.{ "run-tests", repo });

    // ----------------------------------------------------------------
    // Tier 2: Real data — specific field values asserted
    // Expected: fields match known properties of this repo
    // ----------------------------------------------------------------
    ctx.header("Tier 2: Real data (field-level assertions)");
    ctx.checkIntGt("ant since=0 total>0", &.{ "ant", repo, "--since", "0" }, "total", 0);
    ctx.checkArrayLen("registry >=55 subcommands", &.{"registry"}, "subcommands", 55);
    ctx.checkStrContains("scan framework contains Zig", &.{ "scan", repo }, "framework", "Zig");
    ctx.checkBool("capability-check ant: available=true", &.{ "capability-check", "ant" }, "available", true);
    ctx.checkBool("capability-check xyzzy9q2r: available=false", &.{ "capability-check", "xyzzy9q2r" }, "available", false);
    ctx.checkStr("sandbox-check sudo rm: severity=blocked", &.{ "sandbox-check", "sudo", "rm", "-rf", "/" }, "severity", "blocked");
    ctx.checkBool("sandbox-check sudo rm: allowed=false", &.{ "sandbox-check", "sudo", "rm", "-rf", "/" }, "allowed", false);
    ctx.checkStr("sandbox-check git status: severity=safe", &.{ "sandbox-check", "git", "status" }, "severity", "safe");
    ctx.checkBool("sandbox-check git status: allowed=true", &.{ "sandbox-check", "git", "status" }, "allowed", true);
    ctx.checkArrayLen("outline root.zig >=100 symbols", &.{ "outline", root_zig }, "symbols", 100);
    ctx.checkStrLen("file-hash sha256=64 chars", &.{ "file-hash", root_zig }, "sha256", 64);
    ctx.checkStr("git-cache branch=main", &.{ "git-cache", repo }, "branch", "main");

    // ----------------------------------------------------------------
    // Tier 3: Adversarial — bad inputs must exit cleanly (never crash)
    // ----------------------------------------------------------------
    ctx.header("Tier 3: Adversarial (bad inputs → exit 1 or graceful exit 0)");
    ctx.bad("no args → exit 1", &.{}, 1);
    ctx.bad("unknown subcommand → exit 1", &.{"xyzzy-not-a-command"}, 1);
    ctx.bad("ant no path → exit 1", &.{"ant"}, 1);
    ctx.bad("scan nonexistent → exit 1", &.{ "scan", "/nonexistent/stress-test-xyz" }, 1);
    ctx.bad("outline nonexistent → exit 1", &.{ "outline", "/nonexistent/stress-test.zig" }, 1);
    ctx.bad("capability-promote no cmd → exit 1", &.{"capability-promote"}, 1);
    ctx.bad("capability-check no query → exit 1", &.{"capability-check"}, 1);
    ctx.bad("json-query nonexistent → exit 1", &.{ "json-query", "/nonexistent/stress.json", "foo" }, 1);
    ctx.bad("file-hash nonexistent → exit 1", &.{ "file-hash", "/nonexistent/stress.txt" }, 1);
    ctx.bad("file-stats nonexistent → exit 1", &.{ "file-stats", "/nonexistent/stress.txt" }, 1);
    // Edge inputs that should still succeed (exit 0 + valid JSON)
    ctx.smoke("ant future --since (total=0)", &.{ "ant", repo, "--since", "9999999999999" });
    ctx.smoke("ant non-numeric --since (falls back)", &.{ "ant", repo, "--since", "notanumber" });
    ctx.smoke("capability-check empty string", &.{ "capability-check", "" });
    ctx.smoke("capability-promote complex pipe cmd", &.{ "capability-promote", "grep -r 'pattern' . | sort | uniq -c | sort -rn | head -20" });
    ctx.smoke("sandbox-check empty cmd", &.{ "sandbox-check", "" });

    // ----------------------------------------------------------------
    // Tier 1 (continued): worker-list + worker-run smoke
    // ----------------------------------------------------------------
    ctx.header("Tier 1 (continued): worker-run / worker-list");
    ctx.smoke("worker-list", &.{"worker-list"});

    // Write temp test scripts (direct file creation — no subprocess needed)
    const py_script = "/tmp/ft-stress-worker.py";
    const js_script = "/tmp/ft-stress-worker.js";
    const sh_script = "/tmp/ft-stress-worker.sh";
    const sh_fail = "/tmp/ft-stress-worker-fail.sh";
    writeStressScript(io, py_script, "print(42)\n") catch {};
    writeStressScript(io, js_script, "console.log(42)\n") catch {};
    writeStressScript(io, sh_script, "echo 42\n") catch {};
    writeStressScript(io, sh_fail, "exit 7\n") catch {};

    ctx.smoke("worker-run python", &.{ "worker-run", "python", py_script });
    ctx.smoke("worker-run py (alias)", &.{ "worker-run", "py", py_script });
    ctx.smoke("worker-run node", &.{ "worker-run", "node", js_script });
    ctx.smoke("worker-run bash", &.{ "worker-run", "bash", sh_script });
    ctx.smoke("worker-run sh (alias)", &.{ "worker-run", "sh", sh_script });

    // Tier 2: worker-run field assertions
    ctx.checkStr("worker-run python: interpreter=python3", &.{ "worker-run", "python", py_script }, "interpreter", "python3");
    ctx.checkStr("worker-run python: lang=python", &.{ "worker-run", "python", py_script }, "lang", "python");
    ctx.checkStr("worker-run node: lang=node", &.{ "worker-run", "node", js_script }, "lang", "node");
    ctx.checkStr("worker-run bash stdout=42", &.{ "worker-run", "bash", sh_script }, "stdout", "42\n");
    ctx.checkBool("worker-run bash: timed_out=false", &.{ "worker-run", "bash", sh_script }, "timed_out", false);
    ctx.checkBool("worker-run bash: truncated=false", &.{ "worker-run", "bash", sh_script }, "truncated", false);
    ctx.checkIntGt("worker-list count>=11", &.{"worker-list"}, "count", 10);
    ctx.checkArrayLen("worker-list workers>=11", &.{"worker-list"}, "workers", 11);
    // Script exits non-zero → still exit 0 from foreman-tools (exit_code field carries the value)
    ctx.checkBool("worker-run failing script: truncated=false", &.{ "worker-run", "bash", sh_fail }, "truncated", false);

    // Tier 3: worker-run adversarial
    ctx.bad("worker-run no args → exit 1", &.{"worker-run"}, 1);
    ctx.bad("worker-run unknown lang → exit 1", &.{ "worker-run", "cobol", sh_script }, 1);
    ctx.bad("worker-run missing script arg → exit 1", &.{ "worker-run", "bash" }, 1);

    // ----------------------------------------------------------------
    // Module 20 M1: context-slice + state-merge
    // ----------------------------------------------------------------
    ctx.header("Module 20 M1: context-slice / state-merge");

    // Tier 1: smoke
    ctx.smoke("context-slice repo focus=worker", &.{ "context-slice", repo, "worker" });
    ctx.smoke("context-slice repo focus=cache", &.{ "context-slice", repo, "cache" });

    // Tier 2: field assertions
    ctx.checkStr("context-slice focus field", &.{ "context-slice", repo, "plugin" }, "focus", "plugin");
    ctx.checkStrContains("context-slice path field", &.{ "context-slice", repo, "plugin" }, "path", repo);
    ctx.checkIntGt("context-slice fileCount>=0", &.{ "context-slice", repo, "zig" }, "fileCount", -1);
    ctx.checkArrayLen("context-slice files array present", &.{ "context-slice", repo, "cache" }, "files", 0);

    // state-merge: write two JSON files and merge them
    const sm_file1 = "/tmp/ft-stress-sm1.json";
    const sm_file2 = "/tmp/ft-stress-sm2.json";
    writeStressScript(io, sm_file1, "{\"findings\": [\"bug1\"], \"score\": 5}\n") catch {};
    writeStressScript(io, sm_file2, "{\"findings\": [\"bug2\"], \"extra\": \"yes\"}\n") catch {};

    ctx.smoke("state-merge two valid files", &.{ "state-merge", sm_file1, sm_file2 });
    ctx.checkStrContains("state-merge has extra key", &.{ "state-merge", sm_file1, sm_file2 }, "extra", "yes");
    ctx.checkArrayLen("state-merge findings concatenated (>=2)", &.{ "state-merge", sm_file1, sm_file2 }, "findings", 2);

    // Tier 3: adversarial
    ctx.bad("context-slice no args → exit 1", &.{"context-slice"}, 1);
    ctx.bad("context-slice nonexistent path → exit 1", &.{ "context-slice", "/nonexistent/stress-xyz", "query" }, 1);
    ctx.bad("state-merge no args → exit 1", &.{"state-merge"}, 1);
    ctx.bad("state-merge nonexistent file → exit 1", &.{ "state-merge", "/nonexistent/a.json", sm_file2 }, 1);
    ctx.bad("state-merge bad JSON → exit 1", &.{ "state-merge", sh_script, sm_file2 }, 1);

    // ----------------------------------------------------------------
    // Tier 4: Relative-path regression (2026-07-02)
    // Every *Absolute std.Io.Dir API is UB on a relative path — confirmed
    // as allocator corruption (panic: reached unreachable code), not a
    // clean error, on `4orman-tools build .` and 10 other subcommands.
    // Fixed via root.resolveAbsolutePath wired into main.zig before each
    // compute* call. This tier exercises "." the way a real invocation
    // from inside a project directory actually looks.
    // ----------------------------------------------------------------
    ctx.header("Tier 4: Relative-path regression (path args as \".\")");
    ctx.smokeIn("scan . (relative)", repo, &.{ "scan", "." });
    ctx.smokeIn("context-scan . (relative)", repo, &.{ "context-scan", "." });
    ctx.smokeIn("outline src/root.zig (relative file)", repo, &.{ "outline", "src/root.zig" });
    ctx.smokeIn("env-inspect . (relative)", repo, &.{ "env-inspect", "." });
    ctx.smokeIn("secret-scan . (relative)", repo, &.{ "secret-scan", "." });
    ctx.smokeIn("build . (relative)", repo, &.{ "build", "." });
    ctx.smokeIn("run-tests . (relative)", repo, &.{ "run-tests", "." });
    ctx.smokeIn("quality-gate . (relative)", repo, &.{ "quality-gate", "." });
    ctx.smokeIn("prod-ready . (relative)", repo, &.{ "prod-ready", "." });
    ctx.smokeIn("report . (relative)", repo, &.{ "report", "." });
    ctx.badIn("deps . (relative, no manifest) → exit 1, not a crash", repo, &.{ "deps", "." }, 1);

    ctx.summary();
    if (ctx.fail > 0) std.process.exit(1);
}
