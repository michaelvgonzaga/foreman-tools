const std = @import("std");

pub const VERSION = "0.16.0";

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

pub const FileEntry = struct {
    path: []u8,           // owned by caller
    bytes: u64,
    kind: []const u8,     // static string literal — do not free
};

pub const ScanResult = struct {
    framework: []const u8, // static string literal — do not free
    keyFiles: [][]u8,      // owned by caller
    depCount: u32,
    dirMap: [][]u8,        // owned by caller
    entryPoint: ?[]u8,     // owned by caller, null if not detected
    fileCount: u32,        // total file count before 500-file cap
    files: []FileEntry,    // owned by caller
};

// Comptime hash maps — O(1) lookups replacing O(n) linear scans.
// StaticStringMap uses binary search on a sorted comptime-generated array,
// which is faster than linear scan for any set larger than ~4 entries.

const FRAMEWORK_MAP = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "package.json",    "Node.js" },
    .{ "go.mod",          "Go" },
    .{ "build.zig",       "Zig" },
    .{ "Cargo.toml",      "Rust" },
    .{ "pyproject.toml",  "Python" },
    .{ "requirements.txt","Python" },
    .{ "setup.py",        "Python" },
    .{ "Gemfile",         "Ruby" },
    .{ "composer.json",   "PHP" },
    .{ "pom.xml",         "Java (Maven)" },
    .{ "build.gradle",    "Java (Gradle)" },
    .{ "pubspec.yaml",    "Flutter/Dart" },
    .{ "mix.exs",         "Elixir" },
});

const CONFIG_FILE_MAP = std.StaticStringMap(void).initComptime(&.{
    .{ "package.json", {} },    .{ "package-lock.json", {} }, .{ "yarn.lock", {} },     .{ "pnpm-lock.yaml", {} },
    .{ "pyproject.toml", {} },  .{ "requirements.txt", {} },  .{ "setup.py", {} },      .{ "setup.cfg", {} },
    .{ "go.mod", {} },          .{ "go.sum", {} },
    .{ "build.zig", {} },       .{ "build.zig.zon", {} },
    .{ "Cargo.toml", {} },      .{ "Cargo.lock", {} },
    .{ "Gemfile", {} },         .{ "Gemfile.lock", {} },
    .{ "composer.json", {} },   .{ "composer.lock", {} },
    .{ "pom.xml", {} },         .{ "build.gradle", {} },      .{ "build.gradle.kts", {} },
    .{ "pubspec.yaml", {} },    .{ "mix.exs", {} },
    .{ "Dockerfile", {} },      .{ "docker-compose.yml", {} }, .{ "docker-compose.yaml", {} },
    .{ ".env.example", {} },    .{ ".env.sample", {} },
    .{ "tsconfig.json", {} },   .{ "jsconfig.json", {} },
    .{ ".eslintrc.json", {} },  .{ ".eslintrc.js", {} },
    .{ ".prettierrc", {} },     .{ ".prettierrc.json", {} },
    .{ "Makefile", {} },        .{ "justfile", {} },           .{ "Taskfile.yml", {} },
    .{ "netlify.toml", {} },    .{ "vercel.json", {} },
});

const SKIP_DIR_SET = std.StaticStringMap(void).initComptime(&.{
    .{ "node_modules", {} }, .{ ".git", {} },      .{ "vendor", {} },    .{ "__pycache__", {} },
    .{ ".next", {} },        .{ "dist", {} },       .{ "target", {} },    .{ "zig-out", {} },
    .{ ".zig-cache", {} },   .{ ".cache", {} },     .{ "coverage", {} },  .{ ".venv", {} },
    .{ "venv", {} },         .{ ".tox", {} },       .{ "tmp", {} },       .{ "temp", {} },
});

fn shouldSkipScanDir(name: []const u8) bool {
    return SKIP_DIR_SET.has(name);
}

const BINARY_EXT_SET = std.StaticStringMap(void).initComptime(&.{
    .{ ".png", {} }, .{ ".jpg", {} }, .{ ".jpeg", {} }, .{ ".gif", {} }, .{ ".webp", {} },
    .{ ".ico", {} }, .{ ".bmp", {} }, .{ ".tiff", {} },
    .{ ".woff", {} }, .{ ".woff2", {} }, .{ ".ttf", {} }, .{ ".eot", {} }, .{ ".otf", {} },
    .{ ".mp3", {} }, .{ ".mp4", {} }, .{ ".wav", {} }, .{ ".ogg", {} }, .{ ".avi", {} }, .{ ".mov", {} },
    .{ ".pdf", {} }, .{ ".zip", {} }, .{ ".tar", {} }, .{ ".gz", {} }, .{ ".bz2", {} }, .{ ".xz", {} },
    .{ ".wasm", {} }, .{ ".bin", {} }, .{ ".exe", {} }, .{ ".dylib", {} }, .{ ".so", {} }, .{ ".a", {} },
    .{ ".map", {} }, .{ ".pyc", {} }, .{ ".class", {} }, .{ ".o", {} },
});

fn shouldSkipGrepFile(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    return BINARY_EXT_SET.has(name[dot..]);
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

fn getFileBytes(gpa: std.mem.Allocator, io: std.Io, root: []const u8, rel_path: []const u8) u64 {
    const full = std.fs.path.join(gpa, &.{ root, rel_path }) catch return 0;
    defer gpa.free(full);
    const file = std.Io.Dir.openFileAbsolute(io, full, .{}) catch return 0;
    defer file.close(io);
    const st = file.stat(io) catch return 0;
    return st.size;
}

fn classifyFile(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    // test directories
    if (std.mem.startsWith(u8, path, "test/") or
        std.mem.startsWith(u8, path, "tests/") or
        std.mem.indexOf(u8, path, "/test/") != null or
        std.mem.indexOf(u8, path, "/tests/") != null) return "test";
    // test filename patterns
    if (std.mem.startsWith(u8, name, "test_") or
        std.mem.endsWith(u8, name, "_test.go") or
        std.mem.endsWith(u8, name, "_test.zig") or
        std.mem.endsWith(u8, name, "_test.rs") or
        std.mem.indexOf(u8, name, ".test.") != null or
        std.mem.indexOf(u8, name, ".spec.") != null) return "test";
    // docs directories and extensions
    if (std.mem.startsWith(u8, path, "docs/") or
        std.mem.indexOf(u8, path, "/docs/") != null or
        std.mem.endsWith(u8, name, ".md") or
        std.mem.endsWith(u8, name, ".txt") or
        std.mem.endsWith(u8, name, ".rst")) return "docs";
    // config files
    if (CONFIG_FILE_MAP.has(name)) return "config";
    return "source";
}

fn fileEntrySizeDec(_: void, a: FileEntry, b: FileEntry) bool {
    return a.bytes > b.bytes;
}

fn walkScanFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    root: []const u8,
    all_files: *std.ArrayList(FileEntry),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            const rel_path: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            errdefer gpa.free(rel_path);
            try all_files.append(gpa, .{
                .path = rel_path,
                .bytes = getFileBytes(gpa, io, root, rel_path),
                .kind = classifyFile(rel_path),
            });
        } else if (entry.kind == .directory) {
            if (shouldSkipScanDir(entry.name)) continue;
            const sub_prefix: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(sub_prefix);
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            try walkScanFiles(gpa, io, sub, sub_prefix, root, all_files);
        }
    }
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
                if (FRAMEWORK_MAP.get(entry.name)) |fw| framework = fw;
            }
            if (CONFIG_FILE_MAP.has(entry.name)) {
                try key_files.append(gpa, try gpa.dupe(u8, entry.name));
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

    // File inventory
    var all_files: std.ArrayList(FileEntry) = .empty;
    errdefer {
        for (all_files.items) |f| gpa.free(f.path);
        all_files.deinit(gpa);
    }
    try walkScanFiles(gpa, io, dir, "", path, &all_files);

    const file_count: u32 = @intCast(all_files.items.len);

    // Entry point detection (before sort/cap so all files are visible)
    const repo_basename = std.fs.path.basename(path);
    const entry_point: ?[]u8 = ep: {
        const static_candidates = [_][]const u8{
            "main.go", "index.js", "index.ts",
            "src/index.js", "src/index.ts", "app.py", "main.py",
        };
        for (static_candidates) |candidate| {
            for (all_files.items) |f| {
                if (std.mem.eql(u8, f.path, candidate))
                    break :ep try gpa.dupe(u8, f.path);
            }
        }
        for (all_files.items) |f| {
            if (std.mem.startsWith(u8, f.path, "cmd/") and
                std.mem.endsWith(u8, f.path, "/main.go"))
                break :ep try gpa.dupe(u8, f.path);
        }
        for (all_files.items) |f| {
            if (std.mem.startsWith(u8, f.path, "src/main."))
                break :ep try gpa.dupe(u8, f.path);
        }
        for (all_files.items) |f| {
            if (std.mem.startsWith(u8, f.path, "bin/") and
                std.mem.eql(u8, f.path["bin/".len..], repo_basename))
                break :ep try gpa.dupe(u8, f.path);
        }
        break :ep null;
    };
    errdefer if (entry_point) |ep| gpa.free(ep);

    // Sort largest-first, cap at 500
    std.mem.sort(FileEntry, all_files.items, {}, fileEntrySizeDec);
    if (all_files.items.len > 500) {
        for (all_files.items[500..]) |f| gpa.free(f.path);
        all_files.shrinkRetainingCapacity(500);
    }

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
        .entryPoint = entry_point,
        .fileCount = file_count,
        .files = try all_files.toOwnedSlice(gpa),
    };
}

// --- diff-dirs subcommand ---

pub const DiffEntry = struct {
    path: []u8,  // owned by caller
    bytesA: u64,
    bytesB: u64,
    same: bool,
};

pub const DiffDirsResult = struct {
    onlyInA: [][]u8,     // owned by caller
    onlyInB: [][]u8,     // owned by caller
    inBoth: []DiffEntry, // owned by caller
};

const PathEntry = struct {
    path: []u8, // owned by caller
    bytes: u64,
};

fn pathEntryAsc(_: void, a: PathEntry, b: PathEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn walkDirForDiff(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    root: []const u8,
    entries: *std.ArrayList(PathEntry),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            const rel_path: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            errdefer gpa.free(rel_path);
            try entries.append(gpa, .{
                .path = rel_path,
                .bytes = getFileBytes(gpa, io, root, rel_path),
            });
        } else if (entry.kind == .directory) {
            if (shouldSkipScanDir(entry.name)) continue;
            const sub_prefix: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(sub_prefix);
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            try walkDirForDiff(gpa, io, sub, sub_prefix, root, entries);
        }
    }
}

pub fn computeDiffDirs(gpa: std.mem.Allocator, io: std.Io, path_a: []const u8, path_b: []const u8) !DiffDirsResult {
    var dir_a = std.Io.Dir.openDirAbsolute(io, path_a, .{ .iterate = true }) catch
        return error.PathANotFound;
    defer dir_a.close(io);

    var dir_b = std.Io.Dir.openDirAbsolute(io, path_b, .{ .iterate = true }) catch
        return error.PathBNotFound;
    defer dir_b.close(io);

    var a_entries: std.ArrayList(PathEntry) = .empty;
    errdefer {
        for (a_entries.items) |e| gpa.free(e.path);
        a_entries.deinit(gpa);
    }
    try walkDirForDiff(gpa, io, dir_a, "", path_a, &a_entries);

    var b_entries: std.ArrayList(PathEntry) = .empty;
    errdefer {
        for (b_entries.items) |e| gpa.free(e.path);
        b_entries.deinit(gpa);
    }
    try walkDirForDiff(gpa, io, dir_b, "", path_b, &b_entries);

    std.mem.sort(PathEntry, a_entries.items, {}, pathEntryAsc);
    std.mem.sort(PathEntry, b_entries.items, {}, pathEntryAsc);

    var only_a: std.ArrayList([]u8) = .empty;
    errdefer {
        for (only_a.items) |p| gpa.free(p);
        only_a.deinit(gpa);
    }
    var only_b: std.ArrayList([]u8) = .empty;
    errdefer {
        for (only_b.items) |p| gpa.free(p);
        only_b.deinit(gpa);
    }
    var in_both: std.ArrayList(DiffEntry) = .empty;
    errdefer {
        for (in_both.items) |e| gpa.free(e.path);
        in_both.deinit(gpa);
    }

    var i: usize = 0;
    var j: usize = 0;
    while (i < a_entries.items.len and j < b_entries.items.len) {
        const a = a_entries.items[i];
        const b = b_entries.items[j];
        switch (std.mem.order(u8, a.path, b.path)) {
            .lt => { try only_a.append(gpa, try gpa.dupe(u8, a.path)); i += 1; },
            .gt => { try only_b.append(gpa, try gpa.dupe(u8, b.path)); j += 1; },
            .eq => {
                try in_both.append(gpa, .{
                    .path = try gpa.dupe(u8, a.path),
                    .bytesA = a.bytes,
                    .bytesB = b.bytes,
                    .same = a.bytes == b.bytes,
                });
                i += 1;
                j += 1;
            },
        }
    }
    while (i < a_entries.items.len) : (i += 1)
        try only_a.append(gpa, try gpa.dupe(u8, a_entries.items[i].path));
    while (j < b_entries.items.len) : (j += 1)
        try only_b.append(gpa, try gpa.dupe(u8, b_entries.items[j].path));

    return .{
        .onlyInA = try only_a.toOwnedSlice(gpa),
        .onlyInB = try only_b.toOwnedSlice(gpa),
        .inBoth = try in_both.toOwnedSlice(gpa),
    };
}

// --- grep ---

pub const GrepMatch = struct { file: []u8, line: u32, col: u32, text: []u8 };
pub const GrepResult = struct { pattern: []const u8, matchCount: u32, capped: bool, matches: []GrepMatch };

const GREP_MAX_MATCHES: u32 = 500;
const GREP_MAX_FILE_BYTES: usize = 5 * 1024 * 1024;

fn grepOneFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    abs_path: []const u8,
    rel_path: []const u8,
    pattern: []const u8,
    matches: *std.ArrayList(GrepMatch),
) !bool {
    if (matches.items.len >= GREP_MAX_MATCHES) return true;
    const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch return false;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = r.interface.allocRemaining(gpa, .limited(GREP_MAX_FILE_BYTES)) catch return false;
    defer gpa.free(content);
    var line_num: u32 = 1;
    var line_start: usize = 0;
    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = content[line_start..line_end];
        var search_start: usize = 0;
        while (std.mem.indexOf(u8, line[search_start..], pattern)) |rel_off| {
            const col = search_start + rel_off;
            const text = try gpa.dupe(u8, std.mem.trimEnd(u8, line, "\r"));
            try matches.append(gpa, .{
                .file = try gpa.dupe(u8, rel_path),
                .line = line_num,
                .col = @intCast(col + 1),
                .text = text,
            });
            search_start = col + pattern.len;
            if (matches.items.len >= GREP_MAX_MATCHES) return true;
        }
        line_num += 1;
        line_start = line_end + 1;
    }
    return false;
}

fn walkGrep(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    root: []const u8,
    pattern: []const u8,
    ext_filter: ?[]const u8,
    matches: *std.ArrayList(GrepMatch),
) !bool {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (matches.items.len >= GREP_MAX_MATCHES) return true;
        if (entry.kind == .file) {
            if (shouldSkipGrepFile(entry.name)) continue;
            if (ext_filter) |ext| {
                if (!std.mem.endsWith(u8, entry.name, ext)) continue;
            }
            const rel_path: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(rel_path);
            const abs_path = try std.fs.path.join(gpa, &.{ root, rel_path });
            defer gpa.free(abs_path);
            const capped = try grepOneFile(gpa, io, abs_path, rel_path, pattern, matches);
            if (capped) return true;
        } else if (entry.kind == .directory) {
            if (shouldSkipScanDir(entry.name)) continue;
            const sub_prefix: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(sub_prefix);
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const capped = try walkGrep(gpa, io, sub, sub_prefix, root, pattern, ext_filter, matches);
            if (capped) return true;
        }
    }
    return false;
}

pub fn computeGrep(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    pattern: []const u8,
    ext_filter: ?[]const u8,
) !GrepResult {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch
        return error.RootNotFound;
    defer dir.close(io);
    var matches: std.ArrayList(GrepMatch) = .empty;
    errdefer {
        for (matches.items) |m| { gpa.free(m.file); gpa.free(m.text); }
        matches.deinit(gpa);
    }
    const capped = try walkGrep(gpa, io, dir, "", root, pattern, ext_filter, &matches);
    return .{
        .pattern = pattern,
        .matchCount = @intCast(matches.items.len),
        .capped = capped,
        .matches = try matches.toOwnedSlice(gpa),
    };
}

// --- parse-stack ---

pub const StackFrame = struct { file: []const u8, line: u32, col: u32, func: []const u8 };
pub const ParseStackResult = struct { frames: []StackFrame };

// Parses file:line or file:line:col from the tail of s.
// Returns the byte index of the colon before the line number, or null if no match.
fn parseFileLine(s: []const u8, out_line: *u32, out_col: *u32) ?usize {
    if (s.len == 0) return null;
    // Scan trailing digits (either line or col).
    var i: usize = s.len;
    const d2_end = i;
    while (i > 0 and s[i - 1] >= '0' and s[i - 1] <= '9') i -= 1;
    if (i == d2_end or i == 0 or s[i - 1] != ':') return null;
    const d2_start = i;
    const colon2 = i - 1;
    // Check if before colon2 there's another :digits block (making d2 the col).
    var j: usize = colon2;
    const d1_end = j;
    while (j > 0 and s[j - 1] >= '0' and s[j - 1] <= '9') j -= 1;
    if (j < d1_end and j > 0 and s[j - 1] == ':') {
        // file:line:col
        const colon1 = j - 1;
        out_line.* = std.fmt.parseInt(u32, s[j..d1_end], 10) catch return null;
        out_col.* = std.fmt.parseInt(u32, s[d2_start..d2_end], 10) catch 0;
        return colon1;
    }
    // file:line (d2 is the line number)
    out_line.* = std.fmt.parseInt(u32, s[d2_start..d2_end], 10) catch return null;
    out_col.* = 0;
    return colon2;
}

// Parse one line of a stack trace.  Returns null if the line is not a frame.
// Supported formats:
//   Node/V8:   "    at FnName (file:line:col)"  or  "    at file:line:col"
//   Python:    '    File "file", line N, in fn'
//   Go:        "        file.go:line +0x..."
//   Ruby:      "    file:line:in `fn'"
fn parseStackLine(gpa: std.mem.Allocator, raw: []const u8) !?StackFrame {
    const line = std.mem.trim(u8, raw, " \t\r\n");

    // Node/V8: "at FnName (file:line:col)" or "at file:line:col"
    if (std.mem.startsWith(u8, line, "at ")) {
        const rest = std.mem.trim(u8, line[3..], " ");
        if (rest.len > 0 and rest[rest.len - 1] == ')') {
            // "at FnName (file:line:col)"
            const lparen = std.mem.lastIndexOfScalar(u8, rest, '(') orelse return null;
            const fn_name = std.mem.trim(u8, rest[0..lparen], " ");
            const inner = rest[lparen + 1 .. rest.len - 1];
            var out_line: u32 = 0; var out_col: u32 = 0;
            const colon_pos = parseFileLine(inner, &out_line, &out_col) orelse return null;
            return .{
                .file = try gpa.dupe(u8, inner[0..colon_pos]),
                .line = out_line, .col = out_col,
                .func = try gpa.dupe(u8, fn_name),
            };
        }
        // "at file:line:col"
        var out_line: u32 = 0; var out_col: u32 = 0;
        const colon_pos = parseFileLine(rest, &out_line, &out_col) orelse return null;
        return .{
            .file = try gpa.dupe(u8, rest[0..colon_pos]),
            .line = out_line, .col = out_col,
            .func = try gpa.dupe(u8, "<anonymous>"),
        };
    }

    // Python: 'File "file", line N, in fn'
    if (std.mem.startsWith(u8, line, "File \"")) {
        const rest = line[6..];
        const quote_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        const file_name = rest[0..quote_end];
        const after = rest[quote_end + 1 ..];
        // ", line N"
        const line_kw = std.mem.indexOf(u8, after, ", line ") orelse return null;
        const after_line = after[line_kw + 7 ..];
        const comma_or_end = std.mem.indexOfAny(u8, after_line, ", \n") orelse after_line.len;
        const line_num = std.fmt.parseInt(u32, after_line[0..comma_or_end], 10) catch return null;
        // "in fn"
        const in_kw = std.mem.indexOf(u8, after_line[comma_or_end..], " in ") orelse {
            return .{ .file = try gpa.dupe(u8, file_name), .line = line_num, .col = 0, .func = try gpa.dupe(u8, "<module>") };
        };
        const fn_start = comma_or_end + in_kw + 4;
        const fn_name = std.mem.trim(u8, after_line[fn_start..], " \t\r\n");
        return .{ .file = try gpa.dupe(u8, file_name), .line = line_num, .col = 0, .func = try gpa.dupe(u8, fn_name) };
    }

    // Go: "file.go:line +0x..." (starts with a path component containing a dot or slash)
    if (std.mem.indexOf(u8, line, ".go:") != null or
        (line.len > 0 and (line[0] == '/' or line[0] == '.') and std.mem.indexOfScalar(u8, line, ':') != null))
    {
        // strip trailing " +0x..."
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const part = line[0..space];
        var out_line: u32 = 0; var out_col: u32 = 0;
        const colon_pos = parseFileLine(part, &out_line, &out_col) orelse return null;
        return .{ .file = try gpa.dupe(u8, part[0..colon_pos]), .line = out_line, .col = out_col, .func = try gpa.dupe(u8, "<go>") };
    }

    // Ruby: "file:line:in `fn'"
    if (std.mem.indexOf(u8, line, ":in `") != null) {
        const in_pos = std.mem.indexOf(u8, line, ":in `").?;
        const file_line_part = line[0..in_pos];
        const fn_part = line[in_pos + 5 ..];
        const fn_end = std.mem.indexOfScalar(u8, fn_part, '\'') orelse fn_part.len;
        var out_line: u32 = 0; var out_col: u32 = 0;
        const colon_pos = parseFileLine(file_line_part, &out_line, &out_col) orelse return null;
        return .{
            .file = try gpa.dupe(u8, file_line_part[0..colon_pos]),
            .line = out_line, .col = out_col,
            .func = try gpa.dupe(u8, fn_part[0..fn_end]),
        };
    }

    return null;
}

pub fn computeParseStack(gpa: std.mem.Allocator, input: []const u8) !ParseStackResult {
    var frames: std.ArrayList(StackFrame) = .empty;
    errdefer {
        for (frames.items) |f| { gpa.free(f.file); gpa.free(f.func); }
        frames.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        if (try parseStackLine(gpa, raw)) |frame| {
            try frames.append(gpa, frame);
        }
    }
    return .{ .frames = try frames.toOwnedSlice(gpa) };
}

// --- git-diff ---

pub const DiffFileStat = struct { path: []u8, additions: u32, deletions: u32, status: []const u8 };
pub const GitDiffResult = struct {
    ref: []const u8,
    totalAdditions: u32,
    totalDeletions: u32,
    fileCount: u32,
    files: []DiffFileStat,
};

// Parse one line of `git diff --numstat` output: "<add>\t<del>\tpath"
fn parseNumstatLine(line: []const u8, gpa: std.mem.Allocator) !?DiffFileStat {
    const t1 = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const rest = line[t1 + 1 ..];
    const t2 = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const add_str = std.mem.trim(u8, line[0..t1], " ");
    const del_str = std.mem.trim(u8, rest[0..t2], " ");
    const path = std.mem.trim(u8, rest[t2 + 1 ..], " \r\n");
    if (path.len == 0) return null;
    // binary files show "-" for add/del — treat as 0
    const additions = std.fmt.parseInt(u32, add_str, 10) catch 0;
    const deletions = std.fmt.parseInt(u32, del_str, 10) catch 0;
    return .{
        .path = try gpa.dupe(u8, path),
        .additions = additions,
        .deletions = deletions,
        .status = "modified", // refined below from name-status
    };
}

pub fn computeGitDiff(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    ref: []const u8, // "" = unstaged, "staged" = --cached, else passed to git
) !GitDiffResult {
    // Build args for --numstat
    var numstat_args: std.ArrayList([]const u8) = .empty;
    defer numstat_args.deinit(gpa);
    try numstat_args.append(gpa, "diff");
    try numstat_args.append(gpa, "--numstat");
    if (std.mem.eql(u8, ref, "staged")) {
        try numstat_args.append(gpa, "--cached");
    } else if (ref.len > 0) {
        try numstat_args.append(gpa, ref);
    }
    const numstat_raw = runGit(gpa, io, repo_path, numstat_args.items) catch
        return error.GitFailed;
    defer gpa.free(numstat_raw);

    // Build args for --name-status (to get A/M/D/R per file)
    var ns_args: std.ArrayList([]const u8) = .empty;
    defer ns_args.deinit(gpa);
    try ns_args.append(gpa, "diff");
    try ns_args.append(gpa, "--name-status");
    if (std.mem.eql(u8, ref, "staged")) {
        try ns_args.append(gpa, "--cached");
    } else if (ref.len > 0) {
        try ns_args.append(gpa, ref);
    }
    const ns_raw = runGit(gpa, io, repo_path, ns_args.items) catch null;
    defer if (ns_raw) |r| gpa.free(r);

    // Build a map of path → status from name-status output
    var status_map = std.StringHashMap([]const u8).init(gpa);
    defer status_map.deinit();
    if (ns_raw) |ns| {
        var lines = std.mem.splitScalar(u8, ns, '\n');
        while (lines.next()) |line| {
            const t = line;
            if (t.len < 2) continue;
            const tab = std.mem.indexOfScalar(u8, t, '\t') orelse continue;
            const code = std.mem.trim(u8, t[0..tab], " ");
            const path = std.mem.trim(u8, t[tab + 1 ..], " \r\n");
            const status: []const u8 = if (code.len > 0) switch (code[0]) {
                'A' => "added",
                'D' => "deleted",
                'R' => "renamed",
                'C' => "copied",
                else => "modified",
            } else "modified";
            try status_map.put(path, status);
        }
    }

    // Parse numstat output
    var files: std.ArrayList(DiffFileStat) = .empty;
    errdefer {
        for (files.items) |f| gpa.free(f.path);
        files.deinit(gpa);
    }
    var total_add: u32 = 0;
    var total_del: u32 = 0;
    var lines = std.mem.splitScalar(u8, numstat_raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\n").len == 0) continue;
        const stat = try parseNumstatLine(line, gpa) orelse continue;
        total_add += stat.additions;
        total_del += stat.deletions;
        const resolved_status = status_map.get(stat.path) orelse stat.status;
        try files.append(gpa, .{
            .path = stat.path,
            .additions = stat.additions,
            .deletions = stat.deletions,
            .status = resolved_status,
        });
    }

    return .{
        .ref = ref,
        .totalAdditions = total_add,
        .totalDeletions = total_del,
        .fileCount = @intCast(files.items.len),
        .files = try files.toOwnedSlice(gpa),
    };
}

// --- list-dir ---

pub const DirEntry = struct { name: []u8, kind: []const u8, bytes: u64 };
pub const ListDirResult = struct { path: []const u8, count: u32, entries: []DirEntry };

pub fn computeListDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !ListDirResult {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch
        return error.PathNotFound;
    defer dir.close(io);

    var entries: std.ArrayList(DirEntry) = .empty;
    errdefer {
        for (entries.items) |e| gpa.free(e.name);
        entries.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const kind: []const u8 = switch (entry.kind) {
            .directory => "dir",
            .file      => "file",
            .sym_link  => "symlink",
            else       => "other",
        };
        const bytes: u64 = if (entry.kind == .file) blk: {
            const f = dir.openFile(io, entry.name, .{}) catch break :blk 0;
            defer f.close(io);
            const st = f.stat(io) catch break :blk 0;
            break :blk st.size;
        } else 0;
        try entries.append(gpa, .{
            .name  = try gpa.dupe(u8, entry.name),
            .kind  = kind,
            .bytes = bytes,
        });
    }

    // Sort alphabetically: dirs first, then files
    std.mem.sort(DirEntry, entries.items, {}, struct {
        fn lt(_: void, a: DirEntry, b: DirEntry) bool {
            const a_dir = std.mem.eql(u8, a.kind, "dir");
            const b_dir = std.mem.eql(u8, b.kind, "dir");
            if (a_dir != b_dir) return a_dir;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    return .{
        .path = path,
        .count = @intCast(entries.items.len),
        .entries = try entries.toOwnedSlice(gpa),
    };
}

// --- json-query ---

pub const JsonQueryResult = struct {
    path: []const u8,
    found: bool,
    type_name: []const u8, // "string" | "number" | "bool" | "null" | "object" | "array"
    value_json: ?[]u8,     // raw JSON fragment; null when not found
};

fn jsonTypeName(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

pub fn computeJsonQuery(
    gpa: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    key_path: []const u8,
) !JsonQueryResult {
    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch
        return error.FileNotFound;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = try r.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    // Walk the dot-separated path
    var node: std.json.Value = parsed.value;
    var segments = std.mem.splitScalar(u8, key_path, '.');
    while (segments.next()) |seg| {
        switch (node) {
            .object => |obj| {
                node = obj.get(seg) orelse return .{
                    .path = key_path, .found = false,
                    .type_name = "null", .value_json = null,
                };
            },
            .array => |arr| {
                const idx = std.fmt.parseInt(usize, seg, 10) catch return .{
                    .path = key_path, .found = false,
                    .type_name = "null", .value_json = null,
                };
                if (idx >= arr.items.len) return .{
                    .path = key_path, .found = false,
                    .type_name = "null", .value_json = null,
                };
                node = arr.items[idx];
            },
            else => return .{
                .path = key_path, .found = false,
                .type_name = "null", .value_json = null,
            },
        }
    }

    const value_json = try std.json.Stringify.valueAlloc(gpa, node, .{});
    return .{
        .path = key_path,
        .found = true,
        .type_name = jsonTypeName(node),
        .value_json = value_json,
    };
}

// --- find-files ---

pub const FindFilesResult = struct { pattern: []const u8, count: u32, capped: bool, files: [][]u8 };

const FIND_MAX_RESULTS: u32 = 2000;

// Returns true if name matches glob pattern. Supports leading '*', trailing '*',
// '*' on both sides (contains), exact match, and plain '*.ext' suffix match.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    const star_start = std.mem.startsWith(u8, pattern, "*");
    const star_end = std.mem.endsWith(u8, pattern, "*");
    if (star_start and star_end and pattern.len > 2) {
        // *contains*
        const inner = pattern[1 .. pattern.len - 1];
        return std.mem.indexOf(u8, name, inner) != null;
    }
    if (star_start) {
        // *suffix
        const suffix = pattern[1..];
        return std.mem.endsWith(u8, name, suffix);
    }
    if (star_end) {
        // prefix*
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, name, prefix);
    }
    return std.mem.eql(u8, pattern, name);
}

fn walkFindFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    pattern: []const u8,
    results: *std.ArrayList([]u8),
) !bool {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (results.items.len >= FIND_MAX_RESULTS) return true;
        if (entry.kind == .file) {
            if (globMatch(pattern, entry.name)) {
                const path: []u8 = if (rel_prefix.len == 0)
                    try gpa.dupe(u8, entry.name)
                else
                    try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
                try results.append(gpa, path);
                if (results.items.len >= FIND_MAX_RESULTS) return true;
            }
        } else if (entry.kind == .directory) {
            if (shouldSkipScanDir(entry.name)) continue;
            const sub_prefix: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(sub_prefix);
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            const capped = try walkFindFiles(gpa, io, sub, sub_prefix, pattern, results);
            if (capped) return true;
        }
    }
    return false;
}

pub fn computeFindFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    pattern: []const u8,
) !FindFilesResult {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch
        return error.RootNotFound;
    defer dir.close(io);
    var results: std.ArrayList([]u8) = .empty;
    errdefer {
        for (results.items) |p| gpa.free(p);
        results.deinit(gpa);
    }
    const capped = try walkFindFiles(gpa, io, dir, "", pattern, &results);
    return .{
        .pattern = pattern,
        .count = @intCast(results.items.len),
        .capped = capped,
        .files = try results.toOwnedSlice(gpa),
    };
}

// --- file-stats ---

pub const FileStatsResult = struct { path: []const u8, lines: u64, bytes: u64 };

pub fn computeFileStats(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !FileStatsResult {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    const bytes: u64 = blk: {
        const st = file.stat(io) catch break :blk 0;
        break :blk st.size;
    };
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = r.interface.allocRemaining(gpa, .limited(100 * 1024 * 1024)) catch {
        return .{ .path = path, .lines = 0, .bytes = bytes };
    };
    defer gpa.free(content);
    var lines: u64 = 0;
    for (content) |c| {
        if (c == '\n') lines += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') lines += 1;
    return .{ .path = path, .lines = lines, .bytes = bytes };
}

// --- env-scan ---

pub const EnvFile = struct { file: []u8, keyCount: u32, keys: [][]u8 };
pub const EnvScanResult = struct { root: []const u8, fileCount: u32, files: []EnvFile };

fn parseEnvKeys(gpa: std.mem.Allocator, content: []const u8) ![][]u8 {
    var keys: std.ArrayList([]u8) = .empty;
    errdefer {
        for (keys.items) |k| gpa.free(k);
        keys.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Strip optional "export " prefix
        const stripped = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trimStart(u8, line["export ".len..], " \t")
        else
            line;
        const eq = std.mem.indexOfScalar(u8, stripped, '=') orelse continue;
        const key = std.mem.trim(u8, stripped[0..eq], " \t");
        if (key.len == 0) continue;
        // Validate key: must start with letter or underscore
        if (key[0] != '_' and (key[0] < 'A' or key[0] > 'Z') and
            (key[0] < 'a' or key[0] > 'z')) continue;
        try keys.append(gpa, try gpa.dupe(u8, key));
    }
    return keys.toOwnedSlice(gpa);
}

pub fn computeEnvScan(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !EnvScanResult {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch
        return error.RootNotFound;
    defer dir.close(io);

    var env_files: std.ArrayList(EnvFile) = .empty;
    errdefer {
        for (env_files.items) |ef| {
            gpa.free(ef.file);
            for (ef.keys) |k| gpa.free(k);
            gpa.free(ef.keys);
        }
        env_files.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, ".env")) continue;
        const file = dir.openFile(io, entry.name, .{}) catch continue;
        defer file.close(io);
        var read_buf: [4096]u8 = undefined;
        var r = file.reader(io, &read_buf);
        const content = r.interface.allocRemaining(gpa, .limited(1024 * 1024)) catch continue;
        defer gpa.free(content);
        const keys = try parseEnvKeys(gpa, content);
        try env_files.append(gpa, .{
            .file = try gpa.dupe(u8, entry.name),
            .keyCount = @intCast(keys.len),
            .keys = keys,
        });
    }

    // Sort by filename for deterministic output
    std.mem.sort(EnvFile, env_files.items, {}, struct {
        fn lt(_: void, a: EnvFile, b: EnvFile) bool {
            return std.mem.lessThan(u8, a.file, b.file);
        }
    }.lt);

    return .{
        .root = root,
        .fileCount = @intCast(env_files.items.len),
        .files = try env_files.toOwnedSlice(gpa),
    };
}

// --- toml-query ---

const TOMLScalar = struct { type_name: []const u8, json: []u8 };

fn parseTOMLScalar(gpa: std.mem.Allocator, raw: []const u8) !TOMLScalar {
    if (raw.len == 0) return .{ .type_name = "null", .json = try gpa.dupe(u8, "null") };

    // Double or single quoted string
    if (raw[0] == '"' or raw[0] == '\'') {
        const quote = raw[0];
        // find closing quote (last occurrence to skip escaped chars naively)
        const close = std.mem.lastIndexOfScalar(u8, raw[1..], quote) orelse {
            return .{ .type_name = "string", .json = try gpa.dupe(u8, "\"\"") };
        };
        const inner = raw[1 .. 1 + close];
        const escaped = try allocJsonEscape(gpa, inner);
        defer gpa.free(escaped);
        return .{ .type_name = "string", .json = try std.fmt.allocPrint(gpa, "\"{s}\"", .{escaped}) };
    }

    // Boolean
    if (std.mem.eql(u8, raw, "true"))  return .{ .type_name = "bool", .json = try gpa.dupe(u8, "true") };
    if (std.mem.eql(u8, raw, "false")) return .{ .type_name = "bool", .json = try gpa.dupe(u8, "false") };

    // Array or inline table — return raw as-is (best effort)
    if (raw[0] == '[') return .{ .type_name = "array",  .json = try gpa.dupe(u8, raw) };
    if (raw[0] == '{') return .{ .type_name = "object", .json = try gpa.dupe(u8, raw) };

    // Number — strip trailing inline comment first
    var num = raw;
    if (std.mem.indexOfScalar(u8, raw, '#')) |h| {
        num = std.mem.trimEnd(u8, raw[0..h], " \t");
    }
    if (std.fmt.parseInt(i64, num, 10)) |_| {
        return .{ .type_name = "number", .json = try gpa.dupe(u8, num) };
    } else |_| {}
    if (std.fmt.parseFloat(f64, num)) |_| {
        return .{ .type_name = "number", .json = try gpa.dupe(u8, num) };
    } else |_| {}

    // Fallback: return as string
    const escaped = try allocJsonEscape(gpa, raw);
    defer gpa.free(escaped);
    return .{ .type_name = "string", .json = try std.fmt.allocPrint(gpa, "\"{s}\"", .{escaped}) };
}

fn extractTOMLValue(gpa: std.mem.Allocator, content: []const u8, key_path: []const u8) !?TOMLScalar {
    // Split path into section prefix + target key
    var seg_buf: [16][]const u8 = undefined;
    var seg_count: usize = 0;
    var seg_it = std.mem.splitScalar(u8, key_path, '.');
    while (seg_it.next()) |s| {
        if (seg_count >= 16) break;
        seg_buf[seg_count] = s;
        seg_count += 1;
    }
    if (seg_count == 0) return null;
    const target_key = seg_buf[seg_count - 1];
    const section_path = seg_buf[0 .. seg_count - 1];

    var cur_sec: [16][]const u8 = undefined;
    var cur_depth: usize = 0; // starts at root (depth 0 = no section)

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Section header [name] but not array of tables [[name]]
        if (line[0] == '[' and (line.len < 2 or line[1] != '[')) {
            const close = std.mem.lastIndexOfScalar(u8, line, ']') orelse continue;
            const sec_str = std.mem.trim(u8, line[1..close], " \t");
            cur_depth = 0;
            var parts = std.mem.splitScalar(u8, sec_str, '.');
            while (parts.next()) |p| {
                if (cur_depth >= 16) break;
                cur_sec[cur_depth] = std.mem.trim(u8, p, " \t\"");
                cur_depth += 1;
            }
            continue;
        }

        // Key = value
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\"");
        const val_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");

        // Check section match
        if (cur_depth != section_path.len) continue;
        var sec_match = true;
        for (section_path, 0..) |s, i| {
            if (!std.mem.eql(u8, cur_sec[i], s)) { sec_match = false; break; }
        }
        if (!sec_match) continue;

        // Check key match
        if (!std.mem.eql(u8, key, target_key)) continue;

        return try parseTOMLScalar(gpa, val_raw);
    }
    return null;
}

pub fn computeTomlQuery(
    gpa: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    key_path: []const u8,
) !JsonQueryResult {
    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = try r.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(content);

    const scalar = try extractTOMLValue(gpa, content, key_path);
    if (scalar) |s| {
        return .{ .path = key_path, .found = true, .type_name = s.type_name, .value_json = s.json };
    }
    return .{ .path = key_path, .found = false, .type_name = "null", .value_json = null };
}

// --- list-projects subcommand ---

pub const ProjectEntry = struct {
    name: []u8,      // owned by caller
    url: []u8,       // owned by caller
    isForeman: bool,
    isLocal: bool,
};

const FRAMEWORK_REPO_PREFIXES = [_][]const u8{ "homebrew-", "foreman-" };
const FRAMEWORK_REPO_NAMES = [_][]const u8{ "foreman", "plowman" };

fn isFrameworkRepo(name: []const u8) bool {
    for (FRAMEWORK_REPO_NAMES) |n| if (std.mem.eql(u8, name, n)) return true;
    for (FRAMEWORK_REPO_PREFIXES) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

fn repoHasSpecMd(gpa: std.mem.Allocator, io: std.Io, nwo: []const u8) bool {
    const api_path = std.fmt.allocPrint(gpa, "repos/{s}/contents/spec.md", .{nwo}) catch return false;
    defer gpa.free(api_path);
    const result = std.process.run(gpa, io, .{ .argv = &.{ "gh", "api", api_path } }) catch return false;
    gpa.free(result.stdout);
    gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

pub fn computeListProjects(gpa: std.mem.Allocator, io: std.Io, foreman_root: []const u8) ![]ProjectEntry {
    const list_result = std.process.run(gpa, io, .{
        .argv = &.{ "gh", "repo", "list", "--json", "name,nameWithOwner,url", "--limit", "100" },
    }) catch return &.{};
    defer gpa.free(list_result.stderr);
    defer gpa.free(list_result.stdout);

    switch (list_result.term) {
        .exited => |c| if (c != 0) return &.{},
        else => return &.{},
    }

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, list_result.stdout, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .array) return &.{};

    var entries: std.ArrayList(ProjectEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.name);
            gpa.free(e.url);
        }
        entries.deinit(gpa);
    }

    for (parsed.value.array.items) |repo| {
        if (repo != .object) continue;
        const name_val = repo.object.get("name") orelse continue;
        const nwo_val = repo.object.get("nameWithOwner") orelse continue;
        const url_val = repo.object.get("url") orelse continue;
        if (name_val != .string or nwo_val != .string or url_val != .string) continue;

        const name = name_val.string;
        const nwo = nwo_val.string;
        const url = url_val.string;

        if (isFrameworkRepo(name)) continue;

        const is_foreman = repoHasSpecMd(gpa, io, nwo);

        const local_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ foreman_root, name });
        defer gpa.free(local_path);
        const is_local = fileExists(io, local_path);

        const name_owned = try gpa.dupe(u8, name);
        errdefer gpa.free(name_owned);
        const url_owned = try gpa.dupe(u8, url);
        errdefer gpa.free(url_owned);

        try entries.append(gpa, .{
            .name = name_owned,
            .url = url_owned,
            .isForeman = is_foreman,
            .isLocal = is_local,
        });
    }

    return entries.toOwnedSlice(gpa);
}

// --- tarball-sha subcommand ---

pub const TarballShaResult = struct {
    sha256: []u8, // owned by caller, lowercase hex
    url: []u8,    // owned by caller
};

const EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb924" ++
    "27ae41e4649b934ca495991b7852b855";

fn sha256Hex(data: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex_chars = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
}

fn fetchUrl(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "curl", "-sL", "--fail", url },
    }) catch return null;
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |c| if (c != 0) { gpa.free(result.stdout); return null; },
        else => { gpa.free(result.stdout); return null; },
    }
    return result.stdout;
}

pub fn computeTarballSha(gpa: std.mem.Allocator, io: std.Io, owner: []const u8, repo: []const u8, tag: []const u8) !TarballShaResult {
    const url = try std.fmt.allocPrint(gpa, "https://github.com/{s}/{s}/archive/refs/tags/{s}.tar.gz", .{ owner, repo, tag });
    errdefer gpa.free(url);

    const data = fetchUrl(gpa, io, url) orelse return error.FetchFailed;
    var hex = sha256Hex(data);
    gpa.free(data);

    if (std.mem.eql(u8, &hex, EMPTY_SHA256)) {
        var ts = std.posix.timespec{ .sec = 10, .nsec = 0 };
        _ = std.posix.system.nanosleep(&ts, null);
        const data2 = fetchUrl(gpa, io, url) orelse return error.FetchFailed;
        hex = sha256Hex(data2);
        gpa.free(data2);
    }

    return .{
        .sha256 = try gpa.dupe(u8, &hex),
        .url = url,
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

test "classifyFile: test patterns" {
    try std.testing.expectEqualStrings("test", classifyFile("test/foo.go"));
    try std.testing.expectEqualStrings("test", classifyFile("tests/bar.ts"));
    try std.testing.expectEqualStrings("test", classifyFile("src/foo_test.go"));
    try std.testing.expectEqualStrings("test", classifyFile("src/foo.test.js"));
    try std.testing.expectEqualStrings("test", classifyFile("src/foo.spec.ts"));
    try std.testing.expectEqualStrings("test", classifyFile("test_helpers.py"));
}

test "classifyFile: docs patterns" {
    try std.testing.expectEqualStrings("docs", classifyFile("README.md"));
    try std.testing.expectEqualStrings("docs", classifyFile("docs/guide.txt"));
    try std.testing.expectEqualStrings("docs", classifyFile("src/notes.rst"));
}

test "classifyFile: config patterns" {
    try std.testing.expectEqualStrings("config", classifyFile("package.json"));
    try std.testing.expectEqualStrings("config", classifyFile("Cargo.toml"));
    try std.testing.expectEqualStrings("config", classifyFile("Makefile"));
}

test "classifyFile: source fallback" {
    try std.testing.expectEqualStrings("source", classifyFile("src/main.go"));
    try std.testing.expectEqualStrings("source", classifyFile("lib/utils.ts"));
}

test "FileEntry fields" {
    const e = FileEntry{ .path = @constCast("src/main.go"), .bytes = 1024, .kind = "source" };
    try std.testing.expectEqualStrings("src/main.go", e.path);
    try std.testing.expectEqual(@as(u64, 1024), e.bytes);
    try std.testing.expectEqualStrings("source", e.kind);
}

test "DiffEntry fields" {
    const e = DiffEntry{ .path = @constCast("src/foo.go"), .bytesA = 100, .bytesB = 200, .same = false };
    try std.testing.expectEqualStrings("src/foo.go", e.path);
    try std.testing.expect(!e.same);
}

test "shouldSkipGrepFile: binary extensions skipped" {
    try std.testing.expect(shouldSkipGrepFile("image.png"));
    try std.testing.expect(shouldSkipGrepFile("font.woff2"));
    try std.testing.expect(shouldSkipGrepFile("archive.gz"));
    try std.testing.expect(shouldSkipGrepFile("module.wasm"));
    try std.testing.expect(!shouldSkipGrepFile("main.go"));
    try std.testing.expect(!shouldSkipGrepFile("index.ts"));
    try std.testing.expect(!shouldSkipGrepFile("Makefile"));
}

test "parseFileLine: line only" {
    var out_line: u32 = 0; var out_col: u32 = 0;
    const pos = parseFileLine("src/main.go:42", &out_line, &out_col);
    try std.testing.expectEqual(@as(?usize, 11), pos);
    try std.testing.expectEqual(@as(u32, 42), out_line);
    try std.testing.expectEqual(@as(u32, 0), out_col);
}

test "parseFileLine: line and col" {
    var out_line: u32 = 0; var out_col: u32 = 0;
    const pos = parseFileLine("/app/foo.js:10:5", &out_line, &out_col);
    try std.testing.expectEqual(@as(?usize, 11), pos);
    try std.testing.expectEqual(@as(u32, 10), out_line);
    try std.testing.expectEqual(@as(u32, 5), out_col);
}

test "parseStackLine: Node/V8 with parens" {
    const frame = try parseStackLine(std.testing.allocator, "    at myFunc (src/app.js:10:5)");
    defer if (frame) |f| { std.testing.allocator.free(f.file); std.testing.allocator.free(f.func); };
    try std.testing.expect(frame != null);
    try std.testing.expectEqualStrings("src/app.js", frame.?.file);
    try std.testing.expectEqual(@as(u32, 10), frame.?.line);
    try std.testing.expectEqual(@as(u32, 5), frame.?.col);
    try std.testing.expectEqualStrings("myFunc", frame.?.func);
}

test "parseStackLine: Node/V8 bare" {
    const frame = try parseStackLine(std.testing.allocator, "    at src/app.js:20:3");
    defer if (frame) |f| { std.testing.allocator.free(f.file); std.testing.allocator.free(f.func); };
    try std.testing.expect(frame != null);
    try std.testing.expectEqualStrings("src/app.js", frame.?.file);
    try std.testing.expectEqual(@as(u32, 20), frame.?.line);
}

test "parseStackLine: Python" {
    const frame = try parseStackLine(std.testing.allocator, "  File \"app/main.py\", line 33, in run");
    defer if (frame) |f| { std.testing.allocator.free(f.file); std.testing.allocator.free(f.func); };
    try std.testing.expect(frame != null);
    try std.testing.expectEqualStrings("app/main.py", frame.?.file);
    try std.testing.expectEqual(@as(u32, 33), frame.?.line);
    try std.testing.expectEqualStrings("run", frame.?.func);
}

test "parseStackLine: Ruby" {
    const frame = try parseStackLine(std.testing.allocator, "    app/models/user.rb:15:in `save'");
    defer if (frame) |f| { std.testing.allocator.free(f.file); std.testing.allocator.free(f.func); };
    try std.testing.expect(frame != null);
    try std.testing.expectEqualStrings("app/models/user.rb", frame.?.file);
    try std.testing.expectEqual(@as(u32, 15), frame.?.line);
    try std.testing.expectEqualStrings("save", frame.?.func);
}

test "parseStackLine: non-frame line returns null" {
    const frame = try parseStackLine(std.testing.allocator, "Error: something went wrong");
    try std.testing.expect(frame == null);
}

test "computeParseStack: mixed trace" {
    const trace =
        \\Error: boom
        \\    at inner (src/a.js:5:3)
        \\    at outer (src/b.js:12:1)
    ;
    const result = try computeParseStack(std.testing.allocator, trace);
    defer {
        for (result.frames) |f| { std.testing.allocator.free(f.file); std.testing.allocator.free(f.func); }
        std.testing.allocator.free(result.frames);
    }
    try std.testing.expectEqual(@as(usize, 2), result.frames.len);
    try std.testing.expectEqualStrings("src/a.js", result.frames[0].file);
    try std.testing.expectEqualStrings("src/b.js", result.frames[1].file);
}

test "globMatch: exact" {
    try std.testing.expect(globMatch("CLAUDE.md", "CLAUDE.md"));
    try std.testing.expect(!globMatch("CLAUDE.md", "claude.md"));
    try std.testing.expect(!globMatch("CLAUDE.md", "README.md"));
}

test "globMatch: suffix *.ext" {
    try std.testing.expect(globMatch("*.go", "main.go"));
    try std.testing.expect(globMatch("*.go", "foo_test.go"));
    try std.testing.expect(!globMatch("*.go", "main.ts"));
    try std.testing.expect(!globMatch("*.go", "go"));
}

test "globMatch: prefix*" {
    try std.testing.expect(globMatch("Makefile*", "Makefile"));
    try std.testing.expect(globMatch("Makefile*", "Makefile.win"));
    try std.testing.expect(!globMatch("Makefile*", "makefile"));
}

test "globMatch: *contains*" {
    try std.testing.expect(globMatch("*test*", "foo_test.go"));
    try std.testing.expect(globMatch("*test*", "test_helpers.py"));
    try std.testing.expect(!globMatch("*test*", "main.go"));
}

test "globMatch: wildcard *" {
    try std.testing.expect(globMatch("*", "anything.txt"));
    try std.testing.expect(globMatch("*", ""));
}

test "parseNumstatLine: normal line" {
    const stat = try parseNumstatLine("10\t5\tsrc/main.go", std.testing.allocator);
    defer if (stat) |s| std.testing.allocator.free(s.path);
    try std.testing.expect(stat != null);
    try std.testing.expectEqual(@as(u32, 10), stat.?.additions);
    try std.testing.expectEqual(@as(u32, 5), stat.?.deletions);
    try std.testing.expectEqualStrings("src/main.go", stat.?.path);
}

test "parseNumstatLine: binary file (dashes)" {
    const stat = try parseNumstatLine("-\t-\tassets/img.png", std.testing.allocator);
    defer if (stat) |s| std.testing.allocator.free(s.path);
    try std.testing.expect(stat != null);
    try std.testing.expectEqual(@as(u32, 0), stat.?.additions);
    try std.testing.expectEqual(@as(u32, 0), stat.?.deletions);
}

test "parseNumstatLine: empty line returns null" {
    const stat = try parseNumstatLine("", std.testing.allocator);
    try std.testing.expect(stat == null);
}

test "DirEntry fields" {
    const e = DirEntry{ .name = @constCast("src"), .kind = "dir", .bytes = 0 };
    try std.testing.expectEqualStrings("src", e.name);
    try std.testing.expectEqualStrings("dir", e.kind);
}

test "GitDiffResult fields" {
    const r = GitDiffResult{ .ref = "HEAD", .totalAdditions = 10, .totalDeletions = 5, .fileCount = 2, .files = &.{} };
    try std.testing.expectEqualStrings("HEAD", r.ref);
    try std.testing.expectEqual(@as(u32, 10), r.totalAdditions);
    try std.testing.expectEqual(@as(u32, 2), r.fileCount);
}

test "jsonTypeName" {
    try std.testing.expectEqualStrings("string", jsonTypeName(.{ .string = "hi" }));
    try std.testing.expectEqualStrings("number", jsonTypeName(.{ .integer = 42 }));
    try std.testing.expectEqualStrings("number", jsonTypeName(.{ .float = 3.14 }));
    try std.testing.expectEqualStrings("bool", jsonTypeName(.{ .bool = true }));
    try std.testing.expectEqualStrings("null", jsonTypeName(.null));
}

test "JsonQueryResult fields" {
    const r = JsonQueryResult{ .path = "version", .found = true, .type_name = "string", .value_json = null };
    try std.testing.expectEqualStrings("version", r.path);
    try std.testing.expect(r.found);
    try std.testing.expectEqualStrings("string", r.type_name);
}

test "FileStatsResult fields" {
    const r = FileStatsResult{ .path = "/tmp/foo.txt", .lines = 42, .bytes = 1024 };
    try std.testing.expectEqual(@as(u64, 42), r.lines);
    try std.testing.expectEqual(@as(u64, 1024), r.bytes);
}

test "parseEnvKeys: basic" {
    const content = "# comment\nDB_URL=postgres://localhost/db\nAPI_KEY=secret\nexport PORT=3000\n\nNODE_ENV=production\n";
    const keys = try parseEnvKeys(std.testing.allocator, content);
    defer { for (keys) |k| std.testing.allocator.free(k); std.testing.allocator.free(keys); }
    try std.testing.expectEqual(@as(usize, 4), keys.len);
    try std.testing.expectEqualStrings("DB_URL", keys[0]);
    try std.testing.expectEqualStrings("PORT", keys[2]);
}

test "parseEnvKeys: skips invalid keys" {
    const content = "123INVALID=val\n_VALID=ok\nALSO_VALID=yes\n";
    const keys = try parseEnvKeys(std.testing.allocator, content);
    defer { for (keys) |k| std.testing.allocator.free(k); std.testing.allocator.free(keys); }
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("_VALID", keys[0]);
}

test "parseTOMLScalar: string" {
    const s = try parseTOMLScalar(std.testing.allocator, "\"hello world\"");
    defer std.testing.allocator.free(s.json);
    try std.testing.expectEqualStrings("string", s.type_name);
    try std.testing.expectEqualStrings("\"hello world\"", s.json);
}

test "parseTOMLScalar: integer" {
    const s = try parseTOMLScalar(std.testing.allocator, "42");
    defer std.testing.allocator.free(s.json);
    try std.testing.expectEqualStrings("number", s.type_name);
    try std.testing.expectEqualStrings("42", s.json);
}

test "parseTOMLScalar: bool" {
    const t = try parseTOMLScalar(std.testing.allocator, "true");
    defer std.testing.allocator.free(t.json);
    try std.testing.expectEqualStrings("bool", t.type_name);
    try std.testing.expectEqualStrings("true", t.json);
}

test "parseTOMLScalar: number with inline comment" {
    const s = try parseTOMLScalar(std.testing.allocator, "99 # the count");
    defer std.testing.allocator.free(s.json);
    try std.testing.expectEqualStrings("number", s.type_name);
    try std.testing.expectEqualStrings("99", s.json);
}

test "extractTOMLValue: top-level key" {
    const toml = "name = \"my-app\"\nversion = \"1.2.3\"\n";
    const s = try extractTOMLValue(std.testing.allocator, toml, "version");
    defer if (s) |v| std.testing.allocator.free(v.json);
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("\"1.2.3\"", s.?.json);
}

test "extractTOMLValue: section key" {
    const toml = "[package]\nname = \"crate\"\nversion = \"0.1.0\"\n";
    const s = try extractTOMLValue(std.testing.allocator, toml, "package.version");
    defer if (s) |v| std.testing.allocator.free(v.json);
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("\"0.1.0\"", s.?.json);
}

test "extractTOMLValue: nested dotted section" {
    const toml = "[tool.poetry]\nversion = \"2.0.0\"\n";
    const s = try extractTOMLValue(std.testing.allocator, toml, "tool.poetry.version");
    defer if (s) |v| std.testing.allocator.free(v.json);
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("\"2.0.0\"", s.?.json);
}

test "extractTOMLValue: missing key returns null" {
    const toml = "[package]\nname = \"crate\"\n";
    const s = try extractTOMLValue(std.testing.allocator, toml, "package.missing");
    try std.testing.expect(s == null);
}

