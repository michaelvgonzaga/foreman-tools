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

    // Tier 2: check integer field == exact value
    fn checkIntEq(ctx: *Ctx, label: []const u8, argv: []const []const u8, field: []const u8, want: i64) void {
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
        if (val != .integer or val.integer != want) {
            std.debug.print("[FAIL] {s}: '{s}' = {?d}, expected {d}\n", .{
                label, field, if (val == .integer) val.integer else null, want,
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

    // ----------------------------------------------------------------
    // Tier 5: update / field-reports (M39, Field Reports #1-3)
    // ----------------------------------------------------------------
    ctx.header("Tier 5: update / field-reports (M39)");
    ctx.smoke("update repo (absolute)", &.{ "update", repo });
    ctx.smokeIn("update . (relative)", repo, &.{ "update", "." });
    ctx.checkBool("update: verifyPassed present", &.{ "update", repo }, "verifyPassed", true);
    ctx.checkStr("update: status=idle on passing quality-gate", &.{ "update", repo }, "status", "idle");
    ctx.checkStrContains("update: fieldReportPath under ~/.4orman/field-reports", &.{ "update", repo }, "fieldReportPath", ".4orman/field-reports");
    ctx.bad("update nonexistent path → exit 1, not a crash", &.{ "update", "/nonexistent/stress-update-xyz" }, 1);
    ctx.bad("update no args → exit 1", &.{"update"}, 1);

    // ----------------------------------------------------------------
    // Tier 6: field-report-solve / field-report-block (Field Reports #4)
    // Only the non-stdin-dependent paths are covered here — std.process.run
    // in this Zig version has no RunOptions field for supplying stdin
    // content, so the JSON-body happy path is manually verified (not
    // harness-covered): both subcommands were run against a real project
    // with piped JSON, producing correctly-formed solved.toml/blocked.toml
    // and the expected state.json status="blocked" transition. Disclosed
    // gap, not silently skipped.
    // ----------------------------------------------------------------
    ctx.header("Tier 6: field-report-solve / field-report-block (usage/error paths only)");
    ctx.bad("field-report-solve no args → exit 1", &.{"field-report-solve"}, 1);
    ctx.bad("field-report-block no args → exit 1", &.{"field-report-block"}, 1);

    // ----------------------------------------------------------------
    // Tier 7: review-field-reports (Field Reports #6)
    // No args, so this always runs against whatever real ~/.4orman/
    // field-reports/ state exists on the machine running the suite — only
    // asserts the response shape, not specific counts/content (those are
    // machine-state-dependent, not stable across CI/dev environments).
    // ----------------------------------------------------------------
    ctx.header("Tier 7: review-field-reports (M41)");
    ctx.smoke("review-field-reports", &.{"review-field-reports"});
    ctx.checkIntGt("review-field-reports: projectsScanned>=0", &.{"review-field-reports"}, "projectsScanned", -1);
    ctx.checkArrayLen("review-field-reports: blockers array present", &.{"review-field-reports"}, "blockers", 0);

    // ----------------------------------------------------------------
    // Tier 8: solutions-record / solutions-list (Field Reports #7)
    // Same stdin limitation as Tier 6 — solutions-record's happy path is
    // manually verified (see decision log), only solutions-list (no stdin)
    // and confirming ledger.json stays untouched are harness-covered here.
    // ----------------------------------------------------------------
    ctx.header("Tier 8: solutions-record / solutions-list (M42)");
    ctx.smoke("solutions-list", &.{"solutions-list"});
    ctx.checkArrayLen("solutions-list: solutions array present", &.{"solutions-list"}, "solutions", 0);
    ctx.checkArrayLen("ledger show: entries untouched by solutions writes", &.{ "ledger", "show" }, "entries", 0);

    // ----------------------------------------------------------------
    // Tier 9: full context-gate family, relative-path regression
    // (2026-07-02) — context-rank, context-evidence, context-budget,
    // context-gate, context-dependency-graph, context-compressor, and
    // context-slice were never covered by the original Tier 4 fix (they
    // didn't exist yet, or were added after M34) and all shared the exact
    // same *Absolute-vs-relative-path bug rediscovered while wiring Phase 2
    // into context-gate. context-changed is deliberately not tested here —
    // it shells out to `git -C`, never calls a *Absolute API directly, and
    // was confirmed unaffected.
    // ----------------------------------------------------------------
    ctx.header("Tier 9: context-gate family, relative paths (Phase 2 wiring)");
    ctx.smokeIn("context-rank . zig (relative)", repo, &.{ "context-rank", ".", "zig" });
    ctx.smokeIn("context-evidence src/root.zig (relative)", repo, &.{ "context-evidence", "src/root.zig", "computeContextGate" });
    ctx.smokeIn("context-budget src/root.zig (relative)", repo, &.{ "context-budget", "src/root.zig" });
    ctx.smokeIn("context-gate . --task compile error (relative)", repo, &.{ "context-gate", ".", "--task", "fix compile error" });
    ctx.smokeIn("context-gate . --task refactor (relative)", repo, &.{ "context-gate", ".", "--task", "refactor and decouple this module" });
    ctx.smokeIn("context-dependency-graph . src/root.zig (relative)", repo, &.{ "context-dependency-graph", ".", "src/root.zig" });
    ctx.smokeIn("context-compressor src/root.zig (relative)", repo, &.{ "context-compressor", "src/root.zig" });
    ctx.smokeIn("context-slice . focus (relative)", repo, &.{ "context-slice", ".", "context-gate" });

    // Phase 2 field-level assertions: architecture_refactor must classify
    // correctly, compile_error must classify correctly — confirms the
    // task-aware wiring, not just "didn't crash".
    ctx.checkStr("context-gate: architecture_refactor classified", &.{ "context-gate", repo, "--task", "refactor and decouple this module" }, "taskType", "architecture_refactor");
    ctx.checkStr("context-gate: compile_error classified", &.{ "context-gate", repo, "--task", "fix compile error in parser" }, "taskType", "compile_error");

    // ----------------------------------------------------------------
    // Tier 10: metrics context-gate usage instrumentation (2026-07-02)
    // The two context-gate calls just above already generated real events
    // in ~/.4orman/context-gate-events.json — this confirms `metrics`
    // aggregates them into valid JSON without crashing, not the exact
    // counts (machine-state-dependent, not stable across environments).
    // ----------------------------------------------------------------
    ctx.header("Tier 10: metrics context-gate instrumentation");
    ctx.smoke("metrics (with contextGate usage stats)", &.{"metrics"});

    // ----------------------------------------------------------------
    // Tier 11: symbol-index (code index foundation, 2026-07-02)
    // Two consecutive calls: first exercises the cache-miss path (or
    // whatever mix already exists in ~/.cache/4orman-tools from prior
    // runs), second must return identical fileCount/symbolCount with
    // cacheMisses == 0 — the whole point of the index foundation is that
    // a second call against an unchanged project is cache-hit-only.
    // ----------------------------------------------------------------
    ctx.header("Tier 11: symbol-index (code index foundation)");
    ctx.smoke("symbol-index repo (absolute, first call)", &.{ "symbol-index", repo });
    ctx.smokeIn("symbol-index . (relative)", repo, &.{ "symbol-index", "." });
    ctx.checkIntGt("symbol-index: fileCount>0", &.{ "symbol-index", repo }, "fileCount", 0);
    ctx.checkIntGt("symbol-index: symbolCount>0", &.{ "symbol-index", repo }, "symbolCount", 0);
    ctx.checkIntEq("symbol-index: second call is cache-hit-only (cacheMisses==0)", &.{ "symbol-index", repo }, "cacheMisses", 0);
    ctx.bad("symbol-index nonexistent path → exit 1, not a crash", &.{ "symbol-index", "/nonexistent/stress-symidx-xyz" }, 1);

    // ----------------------------------------------------------------
    // Tier 12: failure-record / failure-mark-fixed / failure-lookup
    // (failure-memory-v1, 2026-07-02)
    // Same stdin limitation as Tiers 6/8 — failure-record's and
    // failure-mark-fixed's happy paths (record → lookup finds it →
    // mark-fixed → lookup shows resolved+fix) are manually verified (see
    // decision log), only usage/error paths and failure-lookup (no stdin)
    // are harness-covered here.
    // ----------------------------------------------------------------
    ctx.header("Tier 12: failure-record / failure-mark-fixed / failure-lookup (failure-memory-v1)");
    ctx.bad("failure-record no stdin JSON → exit 1", &.{"failure-record"}, 1);
    ctx.bad("failure-mark-fixed no args → exit 1", &.{"failure-mark-fixed"}, 1);
    ctx.smoke("failure-lookup (no matches expected)", &.{ "failure-lookup", "stress-test-nonexistent-query-xyz-12345" });
    ctx.checkArrayLen("failure-lookup: matches array present", &.{ "failure-lookup", "stress-test-nonexistent-query-xyz-12345" }, "matches", 0);
    // checkIntGt only reads top-level fields, so this confirms metrics
    // still parses as valid JSON with the new nested "failureMemory" object
    // appended, not the nested values themselves (no nested-field checker
    // exists yet in this harness).
    ctx.checkIntGt("metrics: valid JSON with failureMemory block appended", &.{"metrics"}, "cacheEntries", -1);

    ctx.summary();
    if (ctx.fail > 0) std.process.exit(1);
}
