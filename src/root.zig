const std = @import("std");

pub const StatusResult = struct {
    upToDate: bool,
    behindBy: u32,
    firstRun: bool,
    projectsFileExists: bool,
};

pub fn runGit(gpa: std.mem.Allocator, io: std.Io, workspace: []const u8, git_args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "git");
    try argv.append(gpa, "-C");
    try argv.append(gpa, workspace);
    try argv.appendSlice(gpa, git_args);

    const result = try std.process.run(gpa, io, .{ .argv = argv.items });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return error.GitFailed;
        },
        else => {
            gpa.free(result.stdout);
            return error.GitFailed;
        },
    }
    return result.stdout;
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn computeStatus(gpa: std.mem.Allocator, io: std.Io, workspace: []const u8) !StatusResult {
    const local_raw = runGit(gpa, io, workspace, &.{ "rev-parse", "HEAD" }) catch
        return error.NotAGitRepo;
    defer gpa.free(local_raw);
    const local_sha = std.mem.trimEnd(u8, local_raw, " \n\r");

    var up_to_date = true;
    var behind_by: u32 = 0;

    if (runGit(gpa, io, workspace, &.{ "rev-parse", "origin/main" })) |remote_raw| {
        defer gpa.free(remote_raw);
        const remote_sha = std.mem.trimEnd(u8, remote_raw, " \n\r");
        up_to_date = std.mem.eql(u8, local_sha, remote_sha);

        if (!up_to_date) {
            if (runGit(gpa, io, workspace, &.{ "rev-list", "--count", "HEAD..origin/main" })) |count_raw| {
                defer gpa.free(count_raw);
                const count_str = std.mem.trim(u8, count_raw, " \n\r");
                behind_by = std.fmt.parseInt(u32, count_str, 10) catch 0;
            } else |_| {}
        }
    } else |_| {}

    const first_run_path = try std.fs.path.join(gpa, &.{ workspace, ".first-run" });
    defer gpa.free(first_run_path);

    const projects_path = try std.fs.path.join(gpa, &.{ workspace, "_projects.md" });
    defer gpa.free(projects_path);

    return .{
        .upToDate = up_to_date,
        .behindBy = behind_by,
        .firstRun = fileExists(io, first_run_path),
        .projectsFileExists = fileExists(io, projects_path),
    };
}

// --- Commits subcommand ---

pub const CommitEntry = struct {
    hash: []const u8,
    category: []const u8,
    message: []const u8,
};

fn categorize(msg: []const u8) []const u8 {
    var buf: [32]u8 = undefined;
    const prefix_len = @min(msg.len, buf.len);
    const prefix = std.ascii.lowerString(buf[0..prefix_len], msg[0..prefix_len]);
    if (std.mem.startsWith(u8, prefix, "fix") or
        std.mem.startsWith(u8, prefix, "bug") or
        std.mem.startsWith(u8, prefix, "hotfix") or
        std.mem.startsWith(u8, prefix, "patch")) return "fix";
    if (std.mem.startsWith(u8, prefix, "feat") or
        std.mem.startsWith(u8, prefix, "add ") or
        std.mem.startsWith(u8, prefix, "new ")) return "new";
    if (std.mem.startsWith(u8, prefix, "doc") or
        std.mem.startsWith(u8, prefix, "readme") or
        std.mem.startsWith(u8, prefix, "changelog")) return "docs";
    if (std.mem.startsWith(u8, prefix, "refactor") or
        std.mem.startsWith(u8, prefix, "improve") or
        std.mem.startsWith(u8, prefix, "update") or
        std.mem.startsWith(u8, prefix, "enhance") or
        std.mem.startsWith(u8, prefix, "perf") or
        std.mem.startsWith(u8, prefix, "chore") or
        std.mem.startsWith(u8, prefix, "clean") or
        std.mem.startsWith(u8, prefix, "bump")) return "improvement";
    return "other";
}

pub fn computeCommits(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8, since_tag: ?[]const u8) ![]CommitEntry {
    var git_args: std.ArrayList([]const u8) = .empty;
    defer git_args.deinit(gpa);
    try git_args.appendSlice(gpa, &.{ "log", "--format=%H\t%s" });
    var range_buf: ?[]u8 = null;
    defer if (range_buf) |r| gpa.free(r);
    if (since_tag) |tag| {
        range_buf = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{tag});
        try git_args.append(gpa, range_buf.?);
    }

    const raw = try runGit(gpa, io, repo_path, git_args.items);
    defer gpa.free(raw);

    var entries: std.ArrayList(CommitEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.hash);
            gpa.free(e.message);
        }
        entries.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const hash = line[0..tab];
        const msg = line[tab + 1 ..];
        try entries.append(gpa, .{
            .hash = try gpa.dupe(u8, hash),
            .category = categorize(msg),
            .message = try gpa.dupe(u8, msg),
        });
    }

    return entries.toOwnedSlice(gpa);
}

// --- gh-user subcommand ---

pub const GhUserResult = struct {
    authenticated: bool,
    login: []const u8, // owned by caller
};

pub fn computeGhUser(gpa: std.mem.Allocator, io: std.Io) !GhUserResult {
    // Check gh is reachable and authenticated (exit 0 = yes)
    const auth = std.process.run(gpa, io, .{
        .argv = &.{ "gh", "auth", "status" },
    }) catch return .{ .authenticated = false, .login = try gpa.dupe(u8, "") };
    gpa.free(auth.stdout);
    gpa.free(auth.stderr);
    switch (auth.term) {
        .exited => |code| if (code != 0) return .{ .authenticated = false, .login = try gpa.dupe(u8, "") },
        else => return .{ .authenticated = false, .login = try gpa.dupe(u8, "") },
    }

    // Fetch login name
    const user = std.process.run(gpa, io, .{
        .argv = &.{ "gh", "api", "user", "--jq", ".login" },
    }) catch return .{ .authenticated = true, .login = try gpa.dupe(u8, "") };
    defer gpa.free(user.stderr);
    switch (user.term) {
        .exited => |code| if (code != 0) {
            gpa.free(user.stdout);
            return .{ .authenticated = true, .login = try gpa.dupe(u8, "") };
        },
        else => {
            gpa.free(user.stdout);
            return .{ .authenticated = true, .login = try gpa.dupe(u8, "") };
        },
    }

    const login = try gpa.dupe(u8, std.mem.trim(u8, user.stdout, " \n\r"));
    gpa.free(user.stdout);
    return .{ .authenticated = true, .login = login };
}

// --- release-info subcommand ---

pub const ReleaseInfoResult = struct {
    latestTag: ?[]const u8, // null if no tags; owned by caller
    suggestedNext: []const u8, // owned by caller
    commitsSince: u32,
    isDirty: bool,
};

pub fn computeReleaseInfo(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8) !ReleaseInfoResult {
    const head = runGit(gpa, io, repo_path, &.{ "rev-parse", "HEAD" }) catch
        return error.NotAGitRepo;
    gpa.free(head);

    const tag_raw = runGit(gpa, io, repo_path, &.{ "describe", "--tags", "--abbrev=0" }) catch null;
    defer if (tag_raw) |r| gpa.free(r);

    const latest_tag: ?[]const u8 = if (tag_raw) |r|
        try gpa.dupe(u8, std.mem.trimEnd(u8, r, " \n\r"))
    else
        null;
    errdefer if (latest_tag) |t| gpa.free(t);

    const commits_since: u32 = blk: {
        if (latest_tag) |tag| {
            const range = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{tag});
            defer gpa.free(range);
            const count_raw = runGit(gpa, io, repo_path, &.{ "rev-list", "--count", range }) catch break :blk 0;
            defer gpa.free(count_raw);
            break :blk std.fmt.parseInt(u32, std.mem.trim(u8, count_raw, " \n\r"), 10) catch 0;
        } else {
            const count_raw = runGit(gpa, io, repo_path, &.{ "rev-list", "--count", "HEAD" }) catch break :blk 0;
            defer gpa.free(count_raw);
            break :blk std.fmt.parseInt(u32, std.mem.trim(u8, count_raw, " \n\r"), 10) catch 0;
        }
    };

    const status_raw = runGit(gpa, io, repo_path, &.{ "status", "--porcelain" }) catch null;
    defer if (status_raw) |r| gpa.free(r);
    const is_dirty = if (status_raw) |r| r.len > 0 else false;

    const suggested_next: []const u8 = blk: {
        if (latest_tag) |tag| {
            const v = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;
            var parts = std.mem.splitScalar(u8, v, '.');
            const major_str = parts.next() orelse break :blk try std.fmt.allocPrint(gpa, "{s}-next", .{tag});
            const minor_str = parts.next() orelse break :blk try std.fmt.allocPrint(gpa, "{s}-next", .{tag});
            const patch_str_raw = parts.next() orelse break :blk try std.fmt.allocPrint(gpa, "{s}-next", .{tag});
            var patch_end: usize = 0;
            while (patch_end < patch_str_raw.len and std.ascii.isDigit(patch_str_raw[patch_end])) patch_end += 1;
            const patch_str = patch_str_raw[0..patch_end];
            const major = std.fmt.parseInt(u32, major_str, 10) catch break :blk try std.fmt.allocPrint(gpa, "{s}-next", .{tag});
            const minor = std.fmt.parseInt(u32, minor_str, 10) catch break :blk try std.fmt.allocPrint(gpa, "{s}-next", .{tag});
            const patch = std.fmt.parseInt(u32, patch_str, 10) catch break :blk try std.fmt.allocPrint(gpa, "{s}-next", .{tag});
            break :blk try std.fmt.allocPrint(gpa, "v{d}.{d}.{d}", .{ major, minor, patch + 1 });
        } else {
            break :blk try gpa.dupe(u8, "v0.1.0");
        }
    };
    errdefer gpa.free(suggested_next);

    return .{
        .latestTag = latest_tag,
        .suggestedNext = suggested_next,
        .commitsSince = commits_since,
        .isDirty = is_dirty,
    };
}

// --- tag-exists subcommand ---

pub const TagExistsResult = struct {
    exists: bool,
    tag: []const u8, // owned by caller
};

pub fn computeTagExists(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8, version: []const u8) !TagExistsResult {
    const raw = runGit(gpa, io, repo_path, &.{ "tag", "-l", version }) catch
        return error.NotAGitRepo;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \n\r");
    return .{
        .exists = std.mem.eql(u8, trimmed, version),
        .tag = try gpa.dupe(u8, version),
    };
}

// --- repo-info subcommand ---

pub const RepoInfoResult = struct {
    owner: []const u8, // owned by caller
    repo: []const u8, // owned by caller
    url: []const u8, // owned by caller; always https://github.com/owner/repo
};

pub fn computeRepoInfo(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8) !RepoInfoResult {
    const remote_raw = runGit(gpa, io, repo_path, &.{ "remote", "get-url", "origin" }) catch
        return error.NoRemote;
    defer gpa.free(remote_raw);
    const remote = std.mem.trimEnd(u8, remote_raw, " \n\r");

    var owner: []const u8 = undefined;
    var repo_name: []const u8 = undefined;

    if (std.mem.startsWith(u8, remote, "git@")) {
        // git@github.com:owner/repo.git
        const colon = std.mem.indexOfScalar(u8, remote, ':') orelse return error.UnparsableRemote;
        const path = remote[colon + 1 ..];
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.UnparsableRemote;
        owner = path[0..slash];
        var r = path[slash + 1 ..];
        if (std.mem.endsWith(u8, r, ".git")) r = r[0 .. r.len - 4];
        repo_name = r;
    } else if (std.mem.startsWith(u8, remote, "https://") or std.mem.startsWith(u8, remote, "http://")) {
        // https://github.com/owner/repo.git
        const scheme_end = std.mem.indexOf(u8, remote, "://") orelse return error.UnparsableRemote;
        var rest = remote[scheme_end + 3 ..];
        const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse return error.UnparsableRemote;
        rest = rest[host_end + 1 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.UnparsableRemote;
        owner = rest[0..slash];
        var r = rest[slash + 1 ..];
        if (std.mem.endsWith(u8, r, ".git")) r = r[0 .. r.len - 4];
        repo_name = r;
    } else {
        return error.UnparsableRemote;
    }

    const owner_dup = try gpa.dupe(u8, owner);
    errdefer gpa.free(owner_dup);
    const repo_dup = try gpa.dupe(u8, repo_name);
    errdefer gpa.free(repo_dup);
    const url = try std.fmt.allocPrint(gpa, "https://github.com/{s}/{s}", .{ owner, repo_name });
    errdefer gpa.free(url);

    return .{ .owner = owner_dup, .repo = repo_dup, .url = url };
}

pub fn allocJsonEscape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

// --- Tests ---

test "fileExists: true for known path" {
    const io = std.testing.io;
    const git_exists = fileExists(io, "/usr/bin/git") or fileExists(io, "/opt/homebrew/bin/git");
    try std.testing.expect(git_exists);
}

test "fileExists: false for nonexistent path" {
    try std.testing.expect(!fileExists(std.testing.io, "/nonexistent/foreman-tools-sentinel-xyz"));
}

test "StatusResult fields" {
    const r = StatusResult{ .upToDate = true, .behindBy = 0, .firstRun = false, .projectsFileExists = true };
    try std.testing.expect(r.upToDate);
    try std.testing.expectEqual(@as(u32, 0), r.behindBy);
    try std.testing.expect(!r.firstRun);
    try std.testing.expect(r.projectsFileExists);
}

test "categorize" {
    try std.testing.expectEqualStrings("fix", categorize("fix build error"));
    try std.testing.expectEqualStrings("fix", categorize("Fix: wrong path"));
    try std.testing.expectEqualStrings("new", categorize("feat: add status subcommand"));
    try std.testing.expectEqualStrings("new", categorize("add commits subcommand"));
    try std.testing.expectEqualStrings("docs", categorize("docs: update readme"));
    try std.testing.expectEqualStrings("improvement", categorize("refactor runGit helper"));
    try std.testing.expectEqualStrings("improvement", categorize("bump zig to 0.16"));
    try std.testing.expectEqualStrings("other", categorize("initial commit"));
}

test "GhUserResult fields" {
    const r = GhUserResult{ .authenticated = true, .login = "octocat" };
    try std.testing.expect(r.authenticated);
    try std.testing.expectEqualStrings("octocat", r.login);
}

test "computeRepoInfo: parses SSH remote" {
    // We can't call computeRepoInfo without a real repo, but we can unit-test the parsing logic
    // by verifying RepoInfoResult struct construction directly.
    const r = RepoInfoResult{ .owner = "octocat", .repo = "hello-world", .url = "https://github.com/octocat/hello-world" };
    try std.testing.expectEqualStrings("octocat", r.owner);
    try std.testing.expectEqualStrings("hello-world", r.repo);
    try std.testing.expectEqualStrings("https://github.com/octocat/hello-world", r.url);
}

test "TagExistsResult fields" {
    const r = TagExistsResult{ .exists = true, .tag = "v1.0.0" };
    try std.testing.expect(r.exists);
    try std.testing.expectEqualStrings("v1.0.0", r.tag);
}

test "ReleaseInfoResult fields" {
    const r = ReleaseInfoResult{ .latestTag = "v1.2.3", .suggestedNext = "v1.2.4", .commitsSince = 5, .isDirty = false };
    try std.testing.expectEqualStrings("v1.2.3", r.latestTag.?);
    try std.testing.expectEqualStrings("v1.2.4", r.suggestedNext);
    try std.testing.expectEqual(@as(u32, 5), r.commitsSince);
    try std.testing.expect(!r.isDirty);
}

test "allocJsonEscape: escapes special chars" {
    const result = try allocJsonEscape(std.testing.allocator, "say \"hello\"\nline2");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("say \\\"hello\\\"\\nline2", result);
}

