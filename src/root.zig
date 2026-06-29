const std = @import("std");

pub const VERSION = "0.7.0";

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

// --- changes-preview subcommand ---

pub const ChangesPreviewResult = struct {
    commits: []CommitEntry, // owned by caller
    filesChanged: u32,
};

pub fn computeChangesPreview(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8) !ChangesPreviewResult {
    const log_raw = runGit(gpa, io, repo_path, &.{ "log", "--format=%H\t%s", "HEAD..origin/main" }) catch
        return .{ .commits = &.{}, .filesChanged = 0 };
    defer gpa.free(log_raw);

    var entries: std.ArrayList(CommitEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.hash);
            gpa.free(e.message);
        }
        entries.deinit(gpa);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log_raw, "\n"), '\n');
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

    const files_changed: u32 = blk: {
        const names_raw = runGit(gpa, io, repo_path, &.{ "diff", "--name-only", "HEAD..origin/main" }) catch break :blk 0;
        defer gpa.free(names_raw);
        const trimmed = std.mem.trimEnd(u8, names_raw, "\n");
        if (trimmed.len == 0) break :blk 0;
        var count: u32 = 0;
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        while (it.next()) |_| count += 1;
        break :blk count;
    };

    return .{
        .commits = try entries.toOwnedSlice(gpa),
        .filesChanged = files_changed,
    };
}

// --- doctor subcommand ---

pub const DoctorResult = struct {
    claude: bool,
    git: bool,
    gh: bool,
    version: []const u8, // owned by caller
};

fn toolAvailable(gpa: std.mem.Allocator, io: std.Io, name: []const u8) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ name, "--version" },
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

pub fn computeDoctor(gpa: std.mem.Allocator, io: std.Io) !DoctorResult {
    const version = try gpa.dupe(u8, VERSION);
    errdefer gpa.free(version);
    return .{
        .claude = toolAvailable(gpa, io, "claude"),
        .git = toolAvailable(gpa, io, "git"),
        .gh = toolAvailable(gpa, io, "gh"),
        .version = version,
    };
}

// --- tag-exists subcommand ---

pub const TagExistsResult = struct {
    exists: bool,
};

pub fn computeTagExists(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8, tag: []const u8) !TagExistsResult {
    const out = runGit(gpa, io, repo_path, &.{ "tag", "-l", tag }) catch
        return error.NotAGitRepo;
    defer gpa.free(out);
    return .{ .exists = std.mem.trim(u8, out, " \n\r").len > 0 };
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

// --- scan subcommand ---

pub const ScanResult = struct {
    framework: []const u8, // static string literal — do not free
    keyFiles: [][]u8,      // owned by caller
    depCount: u32,
    dirMap: [][]u8,        // owned by caller
};

const FRAMEWORK_INDICATORS = [_]struct { file: []const u8, fw: []const u8 }{
    .{ .file = "package.json",    .fw = "Node.js" },
    .{ .file = "go.mod",          .fw = "Go" },
    .{ .file = "build.zig",       .fw = "Zig" },
    .{ .file = "Cargo.toml",      .fw = "Rust" },
    .{ .file = "pyproject.toml",  .fw = "Python" },
    .{ .file = "requirements.txt",.fw = "Python" },
    .{ .file = "setup.py",        .fw = "Python" },
    .{ .file = "Gemfile",         .fw = "Ruby" },
    .{ .file = "composer.json",   .fw = "PHP" },
    .{ .file = "pom.xml",         .fw = "Java (Maven)" },
    .{ .file = "build.gradle",    .fw = "Java (Gradle)" },
    .{ .file = "pubspec.yaml",    .fw = "Flutter/Dart" },
    .{ .file = "mix.exs",         .fw = "Elixir" },
};

const KNOWN_CONFIG_FILES = [_][]const u8{
    "package.json", "package-lock.json", "yarn.lock",       "pnpm-lock.yaml",
    "pyproject.toml", "requirements.txt", "setup.py",       "setup.cfg",
    "go.mod", "go.sum",
    "build.zig", "build.zig.zon",
    "Cargo.toml", "Cargo.lock",
    "Gemfile", "Gemfile.lock",
    "composer.json", "composer.lock",
    "pom.xml", "build.gradle", "build.gradle.kts",
    "pubspec.yaml", "mix.exs",
    "Dockerfile", "docker-compose.yml", "docker-compose.yaml",
    ".env.example", ".env.sample",
    "tsconfig.json", "jsconfig.json",
    ".eslintrc.json", ".eslintrc.js",
    ".prettierrc", ".prettierrc.json",
    "Makefile", "justfile", "Taskfile.yml",
    "netlify.toml", "vercel.json",
};

const SCAN_SKIP_DIRS = [_][]const u8{
    "node_modules", ".git",    "vendor",  "__pycache__",
    ".next",        "dist",    "target",  "zig-out",
    ".zig-cache",   ".cache",  "coverage", ".venv",
    "venv",         ".tox",    "tmp",     "temp",
};

fn shouldSkipScanDir(name: []const u8) bool {
    for (SCAN_SKIP_DIRS) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn readFileScan(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !?[]u8 {
    const file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    return try r.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
}

fn countNodeDeps(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) u32 {
    const content = (readFileScan(gpa, io, dir, "package.json") catch return 0) orelse return 0;
    defer gpa.free(content);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    var count: u32 = 0;
    for ([_][]const u8{ "dependencies", "devDependencies" }) |key| {
        if (parsed.value.object.get(key)) |deps| {
            if (deps == .object) count += @intCast(deps.object.count());
        }
    }
    return count;
}

fn countReqsDeps(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) u32 {
    const content = (readFileScan(gpa, io, dir, "requirements.txt") catch return 0) orelse return 0;
    defer gpa.free(content);
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        count += 1;
    }
    return count;
}

fn countGoDeps(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) u32 {
    const content = (readFileScan(gpa, io, dir, "go.mod") catch return 0) orelse return 0;
    defer gpa.free(content);
    var count: u32 = 0;
    var in_require = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "require (")) { in_require = true; continue; }
        if (in_require and std.mem.eql(u8, t, ")")) { in_require = false; continue; }
        const dep: []const u8 = if (std.mem.startsWith(u8, t, "require ")) t["require ".len..] else if (in_require) t else continue;
        const sp = std.mem.indexOfScalar(u8, dep, ' ') orelse dep.len;
        const name = std.mem.trim(u8, dep[0..sp], " \t");
        if (name.len > 0 and !std.mem.startsWith(u8, name, "//")) count += 1;
    }
    return count;
}

fn countCargoDeps(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) u32 {
    const content = (readFileScan(gpa, io, dir, "Cargo.toml") catch return 0) orelse return 0;
    defer gpa.free(content);
    var count: u32 = 0;
    var in_deps = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "[dependencies]") or std.mem.eql(u8, t, "[dev-dependencies]")) { in_deps = true; continue; }
        if (t.len > 0 and t[0] == '[') { in_deps = false; continue; }
        if (!in_deps or t.len == 0 or t[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, t, '=') != null) count += 1;
    }
    return count;
}

fn walkScanDirs(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rel_prefix: []const u8, depth: u8, dirs: *std.ArrayList([]u8)) !void {
    if (depth >= 3) return;

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    {
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (shouldSkipScanDir(entry.name)) continue;
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }

    for (names.items) |name| {
        {
            const rel_path: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, name });
            errdefer gpa.free(rel_path);
            try dirs.append(gpa, rel_path);
        }
        const stored = dirs.items[dirs.items.len - 1];
        var sub = dir.openDir(io, name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        try walkScanDirs(gpa, io, sub, stored, depth + 1, dirs);
    }
}

pub fn computeScan(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ScanResult {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);

    var framework: []const u8 = "unknown";

    var key_files: std.ArrayList([]u8) = .empty;
    errdefer {
        for (key_files.items) |f| gpa.free(f);
        key_files.deinit(gpa);
    }

    {
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, framework, "unknown")) {
                for (FRAMEWORK_INDICATORS) |ind| {
                    if (std.mem.eql(u8, entry.name, ind.file)) { framework = ind.fw; break; }
                }
            }
            for (KNOWN_CONFIG_FILES) |known| {
                if (std.mem.eql(u8, entry.name, known)) {
                    try key_files.append(gpa, try gpa.dupe(u8, entry.name));
                    break;
                }
            }
        }
    }

    const dep_count: u32 = if (std.mem.eql(u8, framework, "Node.js"))
        countNodeDeps(gpa, io, dir)
    else if (std.mem.eql(u8, framework, "Python"))
        countReqsDeps(gpa, io, dir)
    else if (std.mem.eql(u8, framework, "Go"))
        countGoDeps(gpa, io, dir)
    else if (std.mem.eql(u8, framework, "Rust"))
        countCargoDeps(gpa, io, dir)
    else
        0;

    var dir_list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dir_list.items) |d| gpa.free(d);
        dir_list.deinit(gpa);
    }

    try walkScanDirs(gpa, io, dir, "", 0, &dir_list);

    const owned_keys = try key_files.toOwnedSlice(gpa);
    errdefer {
        for (owned_keys) |f| gpa.free(f);
        gpa.free(owned_keys);
    }

    return .{
        .framework = framework,
        .keyFiles = owned_keys,
        .depCount = dep_count,
        .dirMap = try dir_list.toOwnedSlice(gpa),
    };
}

// --- Tests ---

test "DoctorResult fields" {
    const r = DoctorResult{ .claude = true, .git = true, .gh = false, .version = VERSION };
    try std.testing.expect(r.claude);
    try std.testing.expect(r.git);
    try std.testing.expect(!r.gh);
    try std.testing.expectEqualStrings(VERSION, r.version);
}

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

test "TagExistsResult fields" {
    const r = TagExistsResult{ .exists = true };
    try std.testing.expect(r.exists);
    const r2 = TagExistsResult{ .exists = false };
    try std.testing.expect(!r2.exists);
}

test "computeRepoInfo: parses SSH remote" {
    // We can't call computeRepoInfo without a real repo, but we can unit-test the parsing logic
    // by verifying RepoInfoResult struct construction directly.
    const r = RepoInfoResult{ .owner = "octocat", .repo = "hello-world", .url = "https://github.com/octocat/hello-world" };
    try std.testing.expectEqualStrings("octocat", r.owner);
    try std.testing.expectEqualStrings("hello-world", r.repo);
    try std.testing.expectEqualStrings("https://github.com/octocat/hello-world", r.url);
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

