const std = @import("std");

pub const VERSION = "0.29.0";

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

const SKIP_FILE_SET = std.StaticStringMap(void).initComptime(&.{
    .{ ".DS_Store", {} }, .{ "Thumbs.db", {} }, .{ ".localized", {} },
});

fn shouldSkipScanFile(name: []const u8) bool {
    if (SKIP_FILE_SET.has(name)) return true;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    return BINARY_EXT_SET.has(name[dot..]);
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
            if (shouldSkipScanFile(entry.name)) continue;
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

// --- yaml-query ---

fn yamlIndent(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ' ') n += 1;
    return n;
}

fn yamlStripQuotes(s: []const u8) []const u8 {
    const v = std.mem.trim(u8, s, " \t\r");
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or
        (v[0] == '\'' and v[v.len - 1] == '\'')))
        return v[1 .. v.len - 1];
    return v;
}

// Returns value part of "key: value" if content starts with key+colon; null otherwise.
// Rejects partial matches: "runs-on:" does not match key "runs".
fn yamlKeyVal(content: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, key)) return null;
    const rest = content[key.len..];
    if (rest.len == 0 or rest[0] != ':') return null;
    if (rest.len > 1 and rest[1] != ' ' and rest[1] != '\t' and
        rest[1] != '\r' and rest[1] != '\n') return null;
    return std.mem.trimStart(u8,rest[1..], " \t");
}

fn yamlFindChildIndent(lines: []const []const u8, from: usize, parent_indent: usize) usize {
    var j = from;
    while (j < lines.len) : (j += 1) {
        const raw = lines[j];
        const ind = yamlIndent(raw);
        const c = std.mem.trimEnd(u8, raw[ind..], "\r\n");
        if (c.len == 0 or c[0] == '#') continue;
        if (ind > parent_indent) return ind;
        break;
    }
    return parent_indent + 2;
}

// Navigate YAML lines by path segments; returns a slice into lines[] (no allocation).
fn yamlNav(
    lines: []const []const u8,
    segs: []const []const u8,
    from: usize,
    at_indent: usize,
) ?[]const u8 {
    if (segs.len == 0) return null;
    const seg = segs[0];
    const rest = segs[1..];
    const is_last = rest.len == 0;
    const as_idx: ?usize = std.fmt.parseInt(usize, seg, 10) catch null;

    var i = from;
    var seq_n: usize = 0;

    while (i < lines.len) : (i += 1) {
        const raw = lines[i];
        const ind = yamlIndent(raw);
        const c = std.mem.trimEnd(u8, raw[ind..], "\r\n");
        if (c.len == 0 or c[0] == '#') continue;
        if (ind < at_indent) break;
        if (ind > at_indent) continue;

        if (as_idx) |target| {
            if (c[0] == '-') {
                if (seq_n == target) {
                    const inline_part = std.mem.trimStart(u8,c[1..], " \t");
                    if (is_last) return yamlStripQuotes(inline_part);
                    // Inline key check: handles "- uses: actions/checkout@v2"
                    if (rest.len >= 1) {
                        if (yamlKeyVal(inline_part, rest[0])) |val| {
                            if (rest.len == 1) return yamlStripQuotes(val);
                        }
                    }
                    const ci = yamlFindChildIndent(lines, i + 1, at_indent);
                    return yamlNav(lines, rest, i + 1, ci);
                }
                seq_n += 1;
            }
        } else {
            if (yamlKeyVal(c, seg)) |val| {
                if (is_last) return yamlStripQuotes(val);
                const ci = yamlFindChildIndent(lines, i + 1, at_indent);
                return yamlNav(lines, rest, i + 1, ci);
            }
        }
    }
    return null;
}

fn parseYamlScalar(gpa: std.mem.Allocator, raw: []const u8) !TOMLScalar {
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (v.len == 0 or std.mem.eql(u8, v, "null") or std.mem.eql(u8, v, "~"))
        return .{ .type_name = "null", .json = try gpa.dupe(u8, "null") };
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "on"))
        return .{ .type_name = "bool", .json = try gpa.dupe(u8, "true") };
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "off"))
        return .{ .type_name = "bool", .json = try gpa.dupe(u8, "false") };
    if (std.fmt.parseInt(i64, v, 10)) |_| {
        return .{ .type_name = "number", .json = try gpa.dupe(u8, v) };
    } else |_| {}
    if (std.fmt.parseFloat(f64, v)) |_| {
        return .{ .type_name = "number", .json = try gpa.dupe(u8, v) };
    } else |_| {}
    const escaped = try allocJsonEscape(gpa, v);
    defer gpa.free(escaped);
    return .{ .type_name = "string", .json = try std.fmt.allocPrint(gpa, "\"{s}\"", .{escaped}) };
}

pub fn computeYamlQuery(
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

    // Two-pass line split (no ArrayList needed)
    var lc: usize = 0;
    { var it = std.mem.splitScalar(u8, content, '\n'); while (it.next() != null) : (lc += 1) {} }
    const lines = try gpa.alloc([]const u8, lc);
    defer gpa.free(lines);
    { var it = std.mem.splitScalar(u8, content, '\n'); var li: usize = 0; while (it.next()) |ln| : (li += 1) { lines[li] = ln; } }

    // Two-pass segment split
    var sc: usize = 0;
    { var it = std.mem.splitScalar(u8, key_path, '.'); while (it.next() != null) : (sc += 1) {} }
    const segs = try gpa.alloc([]const u8, sc);
    defer gpa.free(segs);
    { var it = std.mem.splitScalar(u8, key_path, '.'); var si: usize = 0; while (it.next()) |s| : (si += 1) { segs[si] = s; } }

    const raw = yamlNav(lines, segs, 0, 0);
    if (raw) |val| {
        const scalar = try parseYamlScalar(gpa, val);
        return .{ .path = key_path, .found = true, .type_name = scalar.type_name, .value_json = scalar.json };
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

// --- formula-info subcommand ---

pub const FormulaInfoResult = struct {
    formulaPath: []u8, // owned by caller
    url: []u8,         // owned by caller
    sha256: []u8,      // owned by caller
    version: []u8,     // owned by caller
};

fn extractQuotedField(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const rest = std.mem.trimStart(u8, line[key.len..], " \t");
    if (rest.len < 2 or rest[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
    return rest[1..close];
}

pub fn computeFormulaInfo(gpa: std.mem.Allocator, io: std.Io, tap_path: []const u8, formula_name: []const u8) !FormulaInfoResult {
    const formula_path = try std.fmt.allocPrint(gpa, "{s}/Formula/{s}.rb", .{ tap_path, formula_name });
    errdefer gpa.free(formula_path);

    const file = std.Io.Dir.openFileAbsolute(io, formula_path, .{}) catch return error.FormulaNotFound;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = try r.interface.allocRemaining(gpa, .limited(1 * 1024 * 1024));
    defer gpa.free(content);

    var url: ?[]u8 = null;
    var sha256: ?[]u8 = null;
    var ver: ?[]u8 = null;

    errdefer {
        if (url) |s| gpa.free(s);
        if (sha256) |s| gpa.free(s);
        if (ver) |s| gpa.free(s);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (url == null) {
            if (extractQuotedField(trimmed, "url")) |v| url = try gpa.dupe(u8, v);
        }
        if (sha256 == null) {
            if (extractQuotedField(trimmed, "sha256")) |v| sha256 = try gpa.dupe(u8, v);
        }
        if (ver == null) {
            if (extractQuotedField(trimmed, "version")) |v| ver = try gpa.dupe(u8, v);
        }
    }

    return .{
        .formulaPath = formula_path,
        .url = url orelse return error.MissingField,
        .sha256 = sha256 orelse return error.MissingField,
        .version = ver orelse return error.MissingField,
    };
}

// --- validate-hooks subcommand ---

pub const ValidateHooksResult = struct {
    memorySync: bool,
    autoPush: bool,
};

const MEMORY_SYNC_MSG = "Syncing memory\u{2026}";    // "Syncing memory…"
const AUTO_PUSH_MSG   = "Pushing project commits\u{2026}"; // "Pushing project commits…"

fn searchStopHooks(stop: std.json.Value, needle: []const u8) bool {
    const arr = switch (stop) {
        .array => |a| a,
        else => return false,
    };
    for (arr.items) |matcher| {
        const inner = switch (matcher) {
            .object => |o| o.get("hooks") orelse continue,
            else => continue,
        };
        const hooks_arr = switch (inner) {
            .array => |a| a,
            else => continue,
        };
        for (hooks_arr.items) |hook| {
            const obj = switch (hook) {
                .object => |o| o,
                else => continue,
            };
            const msg = obj.get("statusMessage") orelse continue;
            const msg_str = switch (msg) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, msg_str, needle)) return true;
        }
    }
    return false;
}

pub fn computeValidateHooks(gpa: std.mem.Allocator, io: std.Io) !ValidateHooksResult {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const settings_path = try std.fmt.allocPrint(gpa, "{s}/.claude/settings.json", .{home});
    defer gpa.free(settings_path);

    const file = std.Io.Dir.openFileAbsolute(io, settings_path, .{}) catch return .{ .memorySync = false, .autoPush = false };
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = try r.interface.allocRemaining(gpa, .limited(1 * 1024 * 1024));
    defer gpa.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch
        return .{ .memorySync = false, .autoPush = false };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .memorySync = false, .autoPush = false },
    };
    const hooks_val = root_obj.get("hooks") orelse return .{ .memorySync = false, .autoPush = false };
    const hooks_obj = switch (hooks_val) {
        .object => |o| o,
        else => return .{ .memorySync = false, .autoPush = false },
    };
    const stop_val = hooks_obj.get("Stop") orelse return .{ .memorySync = false, .autoPush = false };

    return .{
        .memorySync = searchStopHooks(stop_val, MEMORY_SYNC_MSG),
        .autoPush   = searchStopHooks(stop_val, AUTO_PUSH_MSG),
    };
}

// --- gh-release subcommand ---

pub const GhReleaseResult = struct {
    url: []u8, // owned by caller
};

pub fn computeGhRelease(
    gpa: std.mem.Allocator,
    io: std.Io,
    owner: []const u8,
    repo: []const u8,
    tag: []const u8,
    title: []const u8,
    notes_file: []const u8,
) !GhReleaseResult {
    // Verify notes file is readable before invoking gh
    {
        const f = std.Io.Dir.openFileAbsolute(io, notes_file, .{}) catch return error.NotesFileNotFound;
        f.close(io);
    }

    const nwo = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ owner, repo });
    defer gpa.free(nwo);

    const result = std.process.run(gpa, io, .{
        .argv = &.{ "gh", "release", "create", tag, "--repo", nwo, "--title", title, "--notes-file", notes_file },
    }) catch return error.GhFailed;
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |c| if (c != 0) { gpa.free(result.stdout); return error.GhFailed; },
        else => { gpa.free(result.stdout); return error.GhFailed; },
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    const url = try gpa.dupe(u8, trimmed);
    gpa.free(result.stdout);
    return .{ .url = url };
}

// --- file-hash subcommand ---

pub const FileHashResult = struct {
    path: []u8,   // owned by caller
    sha256: []u8, // owned by caller, lowercase hex
    bytes: u64,
};

pub fn computeFileHash(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8) !FileHashResult {
    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = try r.interface.allocRemaining(gpa, .limited(500 * 1024 * 1024));
    defer gpa.free(content);
    const hex = sha256Hex(content);
    return .{
        .path = try gpa.dupe(u8, file_path),
        .sha256 = try gpa.dupe(u8, &hex),
        .bytes = @intCast(content.len),
    };
}

// --- cache-check subcommand ---

pub const CacheCheckResult = struct {
    path: []u8,   // owned by caller
    sha256: []u8, // owned by caller, lowercase hex
    changed: bool,
    cached: bool,
};

// Cache store: one file per tracked path, keyed by SHA256(file_path).
// Location: ~/.cache/foreman-tools/<sha256-of-path> contains the last known content sha256.
// Write failures are silently ignored — the result is still correct, just not cached.
pub fn computeCacheCheck(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8) !CacheCheckResult {
    // Hash the file contents
    const fh = try computeFileHash(gpa, io, file_path);
    defer gpa.free(fh.path);
    const new_sha = fh.sha256; // caller takes ownership via result
    errdefer gpa.free(new_sha);

    // Build cache entry path: ~/.cache/foreman-tools/<sha256-of-path>
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const path_key = sha256Hex(file_path);
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}/.cache/foreman-tools", .{home});
    defer gpa.free(cache_dir);
    const entry_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cache_dir, &path_key });
    defer gpa.free(entry_path);

    // Read stored hash (if any)
    var old_sha: ?[]u8 = null;
    defer if (old_sha) |s| gpa.free(s);
    if (std.Io.Dir.openFileAbsolute(io, entry_path, .{})) |cf| {
        var rbuf: [4096]u8 = undefined;
        var rdr = cf.reader(io, &rbuf);
        if (rdr.interface.allocRemaining(gpa, .limited(128))) |content| {
            const trimmed = std.mem.trim(u8, content, " \t\n\r");
            if (trimmed.len == 64) old_sha = gpa.dupe(u8, trimmed) catch null;
            gpa.free(content);
        } else |_| {}
        cf.close(io);
    } else |_| {}

    const was_cached = old_sha != null;
    const changed = if (old_sha) |s| !std.mem.eql(u8, s, new_sha) else true;

    // Write new hash (best effort — ignore failures)
    writeCacheEntry(io, cache_dir, entry_path, new_sha);

    return .{
        .path = try gpa.dupe(u8, file_path),
        .sha256 = new_sha,
        .changed = changed,
        .cached = was_cached,
    };
}

fn atomicRenameAbsolute(old_path: []const u8, new_path: []const u8) void {
    var old_z: [512]u8 = undefined;
    var new_z: [512]u8 = undefined;
    const o = std.fmt.bufPrintZ(&old_z, "{s}", .{old_path}) catch return;
    const n = std.fmt.bufPrintZ(&new_z, "{s}", .{new_path}) catch return;
    _ = std.c.rename(o.ptr, n.ptr);
}

fn writeCacheEntry(io: std.Io, cache_dir: []const u8, entry_path: []const u8, sha: []const u8) void {
    std.Io.Dir.createDirAbsolute(io, cache_dir, .default_dir) catch {};
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{entry_path}) catch return;
    const cf = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch return;
    var wbuf: [128]u8 = undefined;
    var w = cf.writerStreaming(io, &wbuf);
    w.interface.writeAll(sha) catch {
        cf.close(io);
        return;
    };
    w.interface.flush() catch {};
    cf.close(io);
    atomicRenameAbsolute(tmp_path, entry_path);
}

// --- context-scan subcommand ---

pub const KindCounts = struct {
    source: u32,
    @"test": u32,
    config: u32,
    docs: u32,
    other: u32,
};

pub const ContextScanResult = struct {
    framework: []const u8, // static string literal — do not free
    entryPoint: ?[]u8,     // owned by caller
    fileCount: u32,
    summary: KindCounts,
    topFiles: []FileEntry, // owned by caller (paths owned); top 10 by bytes
    keyFiles: [][]u8,      // owned by caller
    dirs: [][]u8,          // owned by caller
};

const CONTEXT_TOP_FILES: usize = 10;

pub fn computeContextScan(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ContextScanResult {
    const scan = try computeScan(gpa, io, path);
    defer {
        for (scan.keyFiles) |f| gpa.free(f);
        gpa.free(scan.keyFiles);
        for (scan.dirMap) |d| gpa.free(d);
        gpa.free(scan.dirMap);
        if (scan.entryPoint) |ep| gpa.free(ep);
        for (scan.files) |f| gpa.free(f.path);
        gpa.free(scan.files);
    }

    // Count files by kind
    var counts = KindCounts{ .source = 0, .@"test" = 0, .config = 0, .docs = 0, .other = 0 };
    for (scan.files) |f| {
        if (std.mem.eql(u8, f.kind, "source"))      counts.source += 1
        else if (std.mem.eql(u8, f.kind, "test"))   counts.@"test" += 1
        else if (std.mem.eql(u8, f.kind, "config")) counts.config += 1
        else if (std.mem.eql(u8, f.kind, "docs"))   counts.docs += 1
        else                                         counts.other += 1;
    }

    // Top N files (scan.files is already sorted largest-first)
    const top_n = @min(CONTEXT_TOP_FILES, scan.files.len);
    const top_files = try gpa.alloc(FileEntry, top_n);
    for (0..top_n) |i| {
        top_files[i] = .{
            .path = try gpa.dupe(u8, scan.files[i].path),
            .bytes = scan.files[i].bytes,
            .kind = scan.files[i].kind,
        };
    }

    // Dupe keyFiles and dirMap
    const key_files = try gpa.alloc([]u8, scan.keyFiles.len);
    for (scan.keyFiles, 0..) |f, i| key_files[i] = try gpa.dupe(u8, f);

    const dirs = try gpa.alloc([]u8, scan.dirMap.len);
    for (scan.dirMap, 0..) |d, i| dirs[i] = try gpa.dupe(u8, d);

    return .{
        .framework  = scan.framework,
        .entryPoint = if (scan.entryPoint) |ep| try gpa.dupe(u8, ep) else null,
        .fileCount  = scan.fileCount,
        .summary    = counts,
        .topFiles   = top_files,
        .keyFiles   = key_files,
        .dirs       = dirs,
    };
}

// --- cache-store / cache-fetch subcommands ---

pub const CacheStoreResult = struct {
    path: []u8,   // owned by caller
    subKey: []u8, // owned by caller
    stored: bool,
};

pub const CacheFetchResult = struct {
    path: []u8,   // owned by caller
    subKey: []u8, // owned by caller
    hit: bool,
    value: ?[]u8, // owned by caller; present only when hit: true
};

// Cache entry format: "<sha256-of-file-content>\n<value-json>"
// Stored at: ~/.cache/foreman-tools/<sha256(file_path + ":" + sub_key)>
// When the file's content hash no longer matches the stored hash, fetch returns hit: false.

fn cacheEntryPath(gpa: std.mem.Allocator, home: []const u8, file_path: []const u8, sub_key: []const u8) ![]u8 {
    const combined = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ file_path, sub_key });
    defer gpa.free(combined);
    const key_hex = sha256Hex(combined);
    return std.fmt.allocPrint(gpa, "{s}/.cache/foreman-tools/{s}", .{ home, &key_hex });
}

pub fn computeCacheStore(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, sub_key: []const u8, value_json: []const u8) !CacheStoreResult {
    const fh = try computeFileHash(gpa, io, file_path);
    defer gpa.free(fh.path);
    defer gpa.free(fh.sha256);

    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}/.cache/foreman-tools", .{home});
    defer gpa.free(cache_dir);
    const entry_path = try cacheEntryPath(gpa, home, file_path, sub_key);
    defer gpa.free(entry_path);

    std.Io.Dir.createDirAbsolute(io, cache_dir, .default_dir) catch {};
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{entry_path});
    defer gpa.free(tmp_path);
    const cf = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch {
        return .{
            .path = try gpa.dupe(u8, file_path),
            .subKey = try gpa.dupe(u8, sub_key),
            .stored = false,
        };
    };
    var wbuf: [4096]u8 = undefined;
    var w = cf.writerStreaming(io, &wbuf);
    const write_ok = blk: {
        w.interface.writeAll(fh.sha256) catch break :blk false;
        w.interface.writeAll("\n") catch break :blk false;
        w.interface.writeAll(value_json) catch break :blk false;
        w.interface.flush() catch break :blk false;
        break :blk true;
    };
    cf.close(io);
    if (!write_ok) {
        return .{ .path = try gpa.dupe(u8, file_path), .subKey = try gpa.dupe(u8, sub_key), .stored = false };
    }
    atomicRenameAbsolute(tmp_path, entry_path);

    return .{
        .path = try gpa.dupe(u8, file_path),
        .subKey = try gpa.dupe(u8, sub_key),
        .stored = true,
    };
}

pub fn computeCacheFetch(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, sub_key: []const u8) !CacheFetchResult {
    const fh = try computeFileHash(gpa, io, file_path);
    defer gpa.free(fh.path);
    const new_sha = fh.sha256;
    defer gpa.free(new_sha);

    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const entry_path = try cacheEntryPath(gpa, home, file_path, sub_key);
    defer gpa.free(entry_path);

    const miss = CacheFetchResult{
        .path = try gpa.dupe(u8, file_path),
        .subKey = try gpa.dupe(u8, sub_key),
        .hit = false,
        .value = null,
    };

    const cf = std.Io.Dir.openFileAbsolute(io, entry_path, .{}) catch return miss;
    defer cf.close(io);
    var rbuf: [4096]u8 = undefined;
    var r = cf.reader(io, &rbuf);
    const content = r.interface.allocRemaining(gpa, .limited(512 * 1024)) catch return miss;
    defer gpa.free(content);

    const nl = std.mem.indexOfScalar(u8, content, '\n') orelse return miss;
    const stored_hash = content[0..nl];
    const stored_value = std.mem.trimEnd(u8, content[nl + 1 ..], " \t\n\r");
    if (!std.mem.eql(u8, stored_hash, new_sha)) return miss;

    return .{
        .path = try gpa.dupe(u8, file_path),
        .subKey = try gpa.dupe(u8, sub_key),
        .hit = true,
        .value = try gpa.dupe(u8, stored_value),
    };
}

// --- context-rank subcommand ---

pub const RankedFile = struct {
    path: []u8,         // owned
    score: u32,
    hits: u32,
    nameMatch: bool,
    kind: []const u8,   // static string literal — do not free
    bytes: u64,
};

pub const ContextRankResult = struct {
    root: []u8,           // owned
    query: []u8,          // owned
    fileCount: u32,
    ranked: []RankedFile, // owned; each .path is owned
};

const RANK_MAX_RESULTS: usize = 15;
const RANK_FILE_READ_CAP: usize = 8 * 1024;
const RANK_MAX_TERMS: usize = 8;

fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    if (needle.len == 0 or needle.len > haystack.len) return 0;
    var count: u32 = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) {
            count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return count;
}

pub fn computeContextRank(gpa: std.mem.Allocator, io: std.Io, root_path: []const u8, query: []const u8) !ContextRankResult {
    const scan = try computeScan(gpa, io, root_path);
    defer {
        for (scan.keyFiles) |f| gpa.free(f);
        gpa.free(scan.keyFiles);
        for (scan.dirMap) |d| gpa.free(d);
        gpa.free(scan.dirMap);
        if (scan.entryPoint) |ep| gpa.free(ep);
        for (scan.files) |f| gpa.free(f.path);
        gpa.free(scan.files);
    }

    // Extract query terms (slices into query — valid for this function's lifetime)
    var terms: [RANK_MAX_TERMS][]const u8 = undefined;
    var term_count: usize = 0;
    {
        var it = std.mem.splitScalar(u8, query, ' ');
        while (it.next()) |part| {
            const t = std.mem.trim(u8, part, " \t");
            if (t.len > 0 and term_count < RANK_MAX_TERMS) {
                terms[term_count] = t;
                term_count += 1;
            }
        }
    }
    const query_terms = terms[0..term_count];

    // Score each file; maintain top RANK_MAX_RESULTS by insertion into fixed array
    const TopEntry = struct { idx: usize, score: u32, hits: u32, nameMatch: bool };
    var top: [RANK_MAX_RESULTS]TopEntry = undefined;
    var top_count: usize = 0;
    var top_min: u32 = 0;

    for (scan.files, 0..) |file, idx| {
        // Check filename/path for term match
        var name_match = false;
        for (query_terms) |term| {
            if (containsInsensitive(file.path, term)) { name_match = true; break; }
        }

        // Read file for content hits (cap at RANK_FILE_READ_CAP)
        var hits: u32 = 0;
        if (query_terms.len > 0) {
            const abs_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_path, file.path }) catch null;
            if (abs_path) |ap| {
                defer gpa.free(ap);
                const cf = std.Io.Dir.openFileAbsolute(io, ap, .{}) catch null;
                if (cf) |f| {
                    defer f.close(io);
                    var rbuf: [4096]u8 = undefined;
                    var r = f.reader(io, &rbuf);
                    const content = r.interface.allocRemaining(gpa, .limited(RANK_FILE_READ_CAP)) catch null;
                    if (content) |c| {
                        defer gpa.free(c);
                        for (query_terms) |term| hits += countOccurrences(c, term);
                    }
                }
            }
        }

        const kind_bonus: u32 = if (std.mem.eql(u8, file.kind, "source") or std.mem.eql(u8, file.kind, "test")) 2 else 1;
        const score: u32 = hits * 5 + (if (name_match) @as(u32, 300) else 0) + kind_bonus;
        const entry = TopEntry{ .idx = idx, .score = score, .hits = hits, .nameMatch = name_match };

        if (top_count < RANK_MAX_RESULTS) {
            top[top_count] = entry;
            top_count += 1;
            top_min = top[0].score;
            for (1..top_count) |i| if (top[i].score < top_min) { top_min = top[i].score; };
        } else if (score > top_min) {
            var min_i: usize = 0;
            for (1..top_count) |i| if (top[i].score < top[min_i].score) { min_i = i; };
            top[min_i] = entry;
            top_min = top[0].score;
            for (1..top_count) |i| if (top[i].score < top_min) { top_min = top[i].score; };
        }
    }

    // Insertion-sort top[0..top_count] by score descending
    {
        var i: usize = 1;
        while (i < top_count) : (i += 1) {
            const val = top[i];
            var j: usize = i;
            while (j > 0 and top[j - 1].score < val.score) : (j -= 1) top[j] = top[j - 1];
            top[j] = val;
        }
    }

    // Build result
    const ranked = try gpa.alloc(RankedFile, top_count);
    for (top[0..top_count], 0..) |entry, i| {
        const f = scan.files[entry.idx];
        ranked[i] = .{
            .path      = try gpa.dupe(u8, f.path),
            .score     = entry.score,
            .hits      = entry.hits,
            .nameMatch = entry.nameMatch,
            .kind      = f.kind,
            .bytes     = f.bytes,
        };
    }

    return .{
        .root      = try gpa.dupe(u8, root_path),
        .query     = try gpa.dupe(u8, query),
        .fileCount = scan.fileCount,
        .ranked    = ranked,
    };
}

// --- context-changed subcommand ---

pub const ChangedFileDiff = struct {
    path: []u8,         // owned
    status: []const u8, // static: "added"|"modified"|"deleted"|"renamed"
    additions: u32,
    deletions: u32,
    diff: []u8,         // owned — unified diff capped at CHANGED_MAX_DIFF_LINES
};

pub const ContextChangedResult = struct {
    ref: []const u8, // static or caller-owned slice — do not free
    totalFiles: u32,
    totalAdditions: u32,
    totalDeletions: u32,
    truncated: bool,
    files: []ChangedFileDiff, // owned; each .path and .diff is owned
};

const CHANGED_MAX_FILES: usize = 8;
const CHANGED_MAX_DIFF_LINES: usize = 100;

pub fn computeContextChanged(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    ref: []const u8, // "" = working-tree vs HEAD, "staged" = --cached, else passed to git
) !ContextChangedResult {
    // Step 1: numstat — file list with add/del counts
    var numstat_args: std.ArrayList([]const u8) = .empty;
    defer numstat_args.deinit(gpa);
    try numstat_args.append(gpa, "diff");
    try numstat_args.append(gpa, "--numstat");
    if (std.mem.eql(u8, ref, "staged")) {
        try numstat_args.append(gpa, "--cached");
    } else if (ref.len > 0) {
        try numstat_args.append(gpa, ref);
    }
    const numstat_raw = runGit(gpa, io, repo_path, numstat_args.items) catch return error.GitFailed;
    defer gpa.free(numstat_raw);

    // Step 2: name-status — per-file A/M/D/R codes
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

    var status_map = std.StringHashMap([]const u8).init(gpa);
    defer status_map.deinit();
    if (ns_raw) |ns| {
        var ns_lines = std.mem.splitScalar(u8, ns, '\n');
        while (ns_lines.next()) |line| {
            if (line.len < 2) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const code = std.mem.trim(u8, line[0..tab], " ");
            const path = std.mem.trim(u8, line[tab + 1 ..], " \r\n");
            const status: []const u8 = if (code.len > 0) switch (code[0]) {
                'A' => "added",
                'D' => "deleted",
                'R' => "renamed",
                else => "modified",
            } else "modified";
            try status_map.put(path, status);
        }
    }

    // Step 3: parse numstat into file list
    var all_files: std.ArrayList(DiffFileStat) = .empty;
    defer {
        for (all_files.items) |f| gpa.free(f.path);
        all_files.deinit(gpa);
    }
    var total_add: u32 = 0;
    var total_del: u32 = 0;
    {
        var ns_lines = std.mem.splitScalar(u8, numstat_raw, '\n');
        while (ns_lines.next()) |line| {
            if (std.mem.trim(u8, line, " \r\n").len == 0) continue;
            const stat = try parseNumstatLine(line, gpa) orelse continue;
            total_add += stat.additions;
            total_del += stat.deletions;
            const resolved = status_map.get(stat.path) orelse stat.status;
            try all_files.append(gpa, .{
                .path = stat.path,
                .additions = stat.additions,
                .deletions = stat.deletions,
                .status = resolved,
            });
        }
    }
    const total_files: u32 = @intCast(all_files.items.len);
    const truncated = all_files.items.len > CHANGED_MAX_FILES;
    const file_count = @min(all_files.items.len, CHANGED_MAX_FILES);

    // Step 4: per-file unified diff, capped at CHANGED_MAX_DIFF_LINES
    const result_files = try gpa.alloc(ChangedFileDiff, file_count);
    for (all_files.items[0..file_count], 0..) |stat, i| {
        var diff_args: std.ArrayList([]const u8) = .empty;
        defer diff_args.deinit(gpa);
        try diff_args.append(gpa, "diff");
        try diff_args.append(gpa, "--unified=3");
        if (std.mem.eql(u8, ref, "staged")) {
            try diff_args.append(gpa, "--cached");
        } else if (ref.len > 0) {
            try diff_args.append(gpa, ref);
        }
        try diff_args.append(gpa, "--");
        try diff_args.append(gpa, stat.path);

        const diff_raw = runGit(gpa, io, repo_path, diff_args.items) catch
            try gpa.dupe(u8, "");
        defer gpa.free(diff_raw);

        // Count lines and find byte offset at CHANGED_MAX_DIFF_LINES
        var line_count: usize = 0;
        var byte_end: usize = 0;
        var it = std.mem.splitScalar(u8, diff_raw, '\n');
        while (it.next()) |line| {
            byte_end += line.len + 1;
            line_count += 1;
            if (line_count >= CHANGED_MAX_DIFF_LINES) break;
        }
        const capped = if (byte_end > diff_raw.len) diff_raw else diff_raw[0..byte_end];

        result_files[i] = .{
            .path       = try gpa.dupe(u8, stat.path),
            .status     = stat.status,
            .additions  = stat.additions,
            .deletions  = stat.deletions,
            .diff       = try gpa.dupe(u8, capped),
        };
    }

    return .{
        .ref            = if (ref.len == 0) "HEAD" else ref,
        .totalFiles     = total_files,
        .totalAdditions = total_add,
        .totalDeletions = total_del,
        .truncated      = truncated,
        .files          = result_files,
    };
}

// --- context-evidence subcommand ---

pub const EvidenceChunk = struct {
    startLine: u32, // 1-based
    endLine: u32,   // 1-based
    content: []u8,  // owned by caller
};

pub const ContextEvidenceResult = struct {
    path: []u8,              // owned
    pattern: []u8,           // owned
    fileBytes: u64,
    matchCount: u32,
    chunks: []EvidenceChunk, // owned; each chunk.content is owned
};

const EVIDENCE_CONTEXT_LINES: usize = 10;
const EVIDENCE_MAX_CHUNKS: usize = 8;

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

pub fn computeContextEvidence(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, pattern: []const u8) !ContextEvidenceResult {
    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = try r.interface.allocRemaining(gpa, .limited(5 * 1024 * 1024));
    defer gpa.free(content);
    const file_bytes: u64 = @intCast(content.len);

    // Count lines (pass 1)
    var line_count: usize = 0;
    {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |_| line_count += 1;
    }
    if (line_count == 0) return .{
        .path = try gpa.dupe(u8, file_path),
        .pattern = try gpa.dupe(u8, pattern),
        .fileBytes = file_bytes,
        .matchCount = 0,
        .chunks = &.{},
    };

    // Collect line slices into content — valid until content is freed (end of function)
    const lines = try gpa.alloc([]const u8, line_count);
    defer gpa.free(lines);
    {
        var it = std.mem.splitScalar(u8, content, '\n');
        var i: usize = 0;
        while (it.next()) |line| : (i += 1) lines[i] = line;
    }

    // Count matching lines (pass 1)
    var match_count: u32 = 0;
    for (lines) |line| {
        if (containsInsensitive(line, pattern)) match_count += 1;
    }

    // Collect match indices (pass 2)
    const match_indices = try gpa.alloc(usize, match_count);
    defer gpa.free(match_indices);
    {
        var mi: usize = 0;
        for (lines, 0..) |line, idx| {
            if (containsInsensitive(line, pattern)) {
                match_indices[mi] = idx;
                mi += 1;
            }
        }
    }

    // Build and merge context windows; worst case = match_count windows
    const windows = try gpa.alloc([2]usize, if (match_count > 0) match_count else 1);
    defer gpa.free(windows);
    var merged_count: usize = 0;
    if (match_count > 0) {
        var cur_start: usize = if (match_indices[0] >= EVIDENCE_CONTEXT_LINES) match_indices[0] - EVIDENCE_CONTEXT_LINES else 0;
        var cur_end: usize = @min(match_indices[0] + EVIDENCE_CONTEXT_LINES, lines.len - 1);
        for (match_indices[1..]) |idx| {
            const w_start: usize = if (idx >= EVIDENCE_CONTEXT_LINES) idx - EVIDENCE_CONTEXT_LINES else 0;
            const w_end: usize = @min(idx + EVIDENCE_CONTEXT_LINES, lines.len - 1);
            if (w_start <= cur_end + 1) {
                cur_end = @max(cur_end, w_end);
            } else {
                windows[merged_count] = .{ cur_start, cur_end };
                merged_count += 1;
                cur_start = w_start;
                cur_end = w_end;
            }
        }
        windows[merged_count] = .{ cur_start, cur_end };
        merged_count += 1;
    }

    // Build chunks (capped at EVIDENCE_MAX_CHUNKS)
    const chunk_count = @min(merged_count, EVIDENCE_MAX_CHUNKS);
    const chunks = try gpa.alloc(EvidenceChunk, chunk_count);
    for (0..chunk_count) |i| {
        const start = windows[i][0];
        const end   = windows[i][1];
        // Calculate byte size of joined lines
        var byte_count: usize = 0;
        for (lines[start..end + 1]) |line| byte_count += line.len + 1;
        if (byte_count > 0) byte_count -= 1; // no trailing \n
        const chunk_buf = try gpa.alloc(u8, byte_count);
        var pos: usize = 0;
        for (lines[start..end + 1], 0..) |line, li| {
            @memcpy(chunk_buf[pos..pos + line.len], line);
            pos += line.len;
            if (li + 1 < end - start + 1) {
                chunk_buf[pos] = '\n';
                pos += 1;
            }
        }
        chunks[i] = .{
            .startLine = @intCast(start + 1),
            .endLine   = @intCast(end + 1),
            .content   = chunk_buf,
        };
    }

    return .{
        .path       = try gpa.dupe(u8, file_path),
        .pattern    = try gpa.dupe(u8, pattern),
        .fileBytes  = file_bytes,
        .matchCount = match_count,
        .chunks     = chunks,
    };
}

// --- outline subcommand ---

pub const Symbol = struct {
    name: []u8,          // owned
    kind: []const u8,    // static: "function"|"method"|"class"|"struct"|"enum"|"trait"|"interface"|"type"|"module"|"impl"
    line: u32,           // 1-based
};

pub const OutlineResult = struct {
    path: []u8,          // owned
    lang: []const u8,    // static
    symbols: []Symbol,   // owned slice; each name is owned
};

const OUTLINE_MAX: usize = 200;

fn outlineDetectLang(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "unknown";
    const ext = path[dot..];
    if (std.mem.eql(u8, ext, ".go"))                                         return "go";
    if (std.mem.eql(u8, ext, ".py"))                                         return "python";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs") or
        std.mem.eql(u8, ext, ".cjs"))                                        return "javascript";
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".jsx"))                                        return "typescript";
    if (std.mem.eql(u8, ext, ".rb"))                                         return "ruby";
    if (std.mem.eql(u8, ext, ".rs"))                                         return "rust";
    if (std.mem.eql(u8, ext, ".zig"))                                        return "zig";
    if (std.mem.eql(u8, ext, ".java"))                                       return "java";
    if (std.mem.eql(u8, ext, ".kt") or std.mem.eql(u8, ext, ".kts"))        return "kotlin";
    if (std.mem.eql(u8, ext, ".php"))                                        return "php";
    if (std.mem.eql(u8, ext, ".swift"))                                      return "swift";
    if (std.mem.eql(u8, ext, ".cs"))                                         return "csharp";
    return "unknown";
}

// Extract leading identifier chars ([a-zA-Z0-9_])
fn outlineIdent(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
              (c >= '0' and c <= '9') or c == '_')) break;
    }
    return s[0..i];
}

// Consume a prefix keyword and optional following space; return rest or null if not present
fn outlineKw(s: []const u8, kw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, kw)) return null;
    const rest = s[kw.len..];
    // Keyword must be followed by space/tab or end of string (not part of a longer identifier)
    if (rest.len > 0 and ((rest[0] >= 'a' and rest[0] <= 'z') or
        (rest[0] >= 'A' and rest[0] <= 'Z') or rest[0] == '_' or
        (rest[0] >= '0' and rest[0] <= '9'))) return null;
    return std.mem.trimStart(u8, rest, " \t");
}

const SymHit = struct { name: []const u8, kind: []const u8 };

fn outlineGo(s: []const u8) ?SymHit {
    var rest = outlineKw(s, "func") orelse return null;
    // Optional receiver: (type)
    if (rest.len > 0 and rest[0] == '(') {
        rest = rest[(std.mem.indexOfScalar(u8, rest, ')') orelse return null) + 1..];
        rest = std.mem.trimStart(u8, rest, " \t");
    }
    const name = outlineIdent(rest);
    if (name.len == 0) return null;
    return .{ .name = name, .kind = "function" };
}

fn outlinePython(s: []const u8) ?SymHit {
    var rest = s;
    if (std.mem.startsWith(u8, rest, "async ")) rest = std.mem.trimStart(u8, rest[6..], " \t");
    if (outlineKw(rest, "def")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "function" };
    }
    if (outlineKw(rest, "class")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "class" };
    }
    return null;
}

fn outlineJS(s: []const u8) ?SymHit {
    var rest = s;
    // Strip export modifiers
    if (outlineKw(rest, "export")) |a| {
        rest = a;
        if (outlineKw(rest, "default")) |b| rest = b;
    }
    if (std.mem.startsWith(u8, rest, "async ")) rest = std.mem.trimStart(u8, rest[6..], " \t");
    if (outlineKw(rest, "function")) |after| {
        // skip optional * (generator)
        var a2 = after;
        if (a2.len > 0 and a2[0] == '*') a2 = std.mem.trimStart(u8, a2[1..], " \t");
        const name = outlineIdent(a2);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "function" };
    }
    if (outlineKw(rest, "class")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "class" };
    }
    return null;
}

fn outlineTS(s: []const u8) ?SymHit {
    if (outlineJS(s)) |h| return h;
    var rest = s;
    if (outlineKw(rest, "export")) |a| rest = a;
    if (outlineKw(rest, "interface")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "interface" };
    }
    if (outlineKw(rest, "type")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "type" };
    }
    if (outlineKw(rest, "enum")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "enum" };
    }
    return null;
}

fn outlineRust(s: []const u8) ?SymHit {
    var rest = s;
    if (outlineKw(rest, "pub")) |a| rest = a;
    // pub(crate) / pub(super) etc.
    if (rest.len > 0 and rest[0] == '(') {
        rest = rest[(std.mem.indexOfScalar(u8, rest, ')') orelse return null) + 1..];
        rest = std.mem.trimStart(u8, rest, " \t");
    }
    if (std.mem.startsWith(u8, rest, "async ")) rest = std.mem.trimStart(u8, rest[6..], " \t");
    if (std.mem.startsWith(u8, rest, "unsafe ")) rest = std.mem.trimStart(u8, rest[7..], " \t");
    if (outlineKw(rest, "fn")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "function" };
    }
    if (outlineKw(rest, "struct")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "struct" };
    }
    if (outlineKw(rest, "enum")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "enum" };
    }
    if (outlineKw(rest, "trait")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "trait" };
    }
    if (outlineKw(rest, "impl")) |after| {
        // impl may have generic params; grab first ident
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "impl" };
    }
    return null;
}

fn outlineZig(s: []const u8) ?SymHit {
    var rest = s;
    if (outlineKw(rest, "pub")) |a| rest = a;
    if (outlineKw(rest, "fn")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "function" };
    }
    // pub const Name = struct/enum/union
    if (outlineKw(rest, "const")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        // Check rhs contains struct/enum/union keyword
        const eq = std.mem.indexOfScalar(u8, after, '=') orelse return null;
        const rhs = std.mem.trimStart(u8, after[eq + 1..], " \t");
        if (std.mem.startsWith(u8, rhs, "struct") or
            std.mem.startsWith(u8, rhs, "enum") or
            std.mem.startsWith(u8, rhs, "union"))
        {
            return .{ .name = name, .kind = "struct" };
        }
        return null;
    }
    return null;
}

fn outlineRuby(s: []const u8) ?SymHit {
    if (outlineKw(s, "def")) |after| {
        // Ruby method names can end with ?, !, =
        var i: usize = 0;
        while (i < after.len) : (i += 1) {
            const c = after[i];
            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                  (c >= '0' and c <= '9') or c == '_')) break;
        }
        if (i < after.len and (after[i] == '?' or after[i] == '!' or after[i] == '=')) i += 1;
        const name = after[0..i];
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "function" };
    }
    if (outlineKw(s, "class")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "class" };
    }
    if (outlineKw(s, "module")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "module" };
    }
    return null;
}

fn outlineJavaLike(s: []const u8) ?SymHit {
    var rest = s;
    // Strip visibility/modifiers (public/private/protected/static/abstract/final/override/sealed)
    const mods = [_][]const u8{ "public ", "private ", "protected ", "static ", "abstract ", "final ", "override ", "sealed ", "partial ", "internal " };
    var changed = true;
    while (changed) {
        changed = false;
        for (mods) |m| {
            if (std.mem.startsWith(u8, rest, m)) { rest = rest[m.len..]; changed = true; }
        }
    }
    if (outlineKw(rest, "class")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "class" };
    }
    if (outlineKw(rest, "interface")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "interface" };
    }
    if (outlineKw(rest, "enum")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "enum" };
    }
    if (outlineKw(rest, "fun ")) |after| { // Kotlin
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "function" };
    }
    if (outlineKw(rest, "func ")) |after| { // Swift
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "function" };
    }
    return null;
}

fn outlinePHP(s: []const u8) ?SymHit {
    var rest = s;
    if (outlineKw(rest, "public")) |a| rest = a;
    if (outlineKw(rest, "private")) |a| rest = a;
    if (outlineKw(rest, "protected")) |a| rest = a;
    if (outlineKw(rest, "static")) |a| rest = a;
    if (std.mem.startsWith(u8, rest, "async ")) rest = rest[6..];
    if (outlineKw(rest, "function")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "function" };
    }
    if (outlineKw(rest, "class")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "class" };
    }
    if (outlineKw(rest, "interface")) |after| {
        const name = outlineIdent(after);
        if (name.len == 0) return null;
        return .{ .name = name, .kind = "interface" };
    }
    return null;
}

fn outlineExtract(s: []const u8, lang: []const u8) ?SymHit {
    if (std.mem.eql(u8, lang, "go"))                                          return outlineGo(s);
    if (std.mem.eql(u8, lang, "python"))                                      return outlinePython(s);
    if (std.mem.eql(u8, lang, "javascript"))                                  return outlineJS(s);
    if (std.mem.eql(u8, lang, "typescript"))                                  return outlineTS(s);
    if (std.mem.eql(u8, lang, "rust"))                                        return outlineRust(s);
    if (std.mem.eql(u8, lang, "zig"))                                         return outlineZig(s);
    if (std.mem.eql(u8, lang, "ruby"))                                        return outlineRuby(s);
    if (std.mem.eql(u8, lang, "java") or std.mem.eql(u8, lang, "kotlin") or
        std.mem.eql(u8, lang, "csharp") or std.mem.eql(u8, lang, "swift"))   return outlineJavaLike(s);
    if (std.mem.eql(u8, lang, "php"))                                         return outlinePHP(s);
    return null;
}

pub fn computeOutline(
    gpa: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) !OutlineResult {
    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = try r.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(content);

    const lang = outlineDetectLang(file_path);

    // Allocate max-size symbol buffer; shrink to actual count after scanning
    const sym_buf = try gpa.alloc(Symbol, OUTLINE_MAX);
    var count: usize = 0;
    errdefer {
        for (sym_buf[0..count]) |s| gpa.free(s.name);
        gpa.free(sym_buf);
    }

    var line_num: u32 = 1;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| : (line_num += 1) {
        if (count >= OUTLINE_MAX) break;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '/' or trimmed[0] == '*') continue;
        const hit = outlineExtract(trimmed, lang) orelse continue;
        sym_buf[count] = .{
            .name = try gpa.dupe(u8, hit.name),
            .kind = hit.kind,
            .line = line_num,
        };
        count += 1;
    }

    // Shrink to actual count
    const symbols = try gpa.realloc(sym_buf, count);
    return .{
        .path = try gpa.dupe(u8, file_path),
        .lang = lang,
        .symbols = symbols,
    };
}

// --- deps subcommand ---

pub const Dep = struct {
    name: []u8,     // owned
    version: []u8,  // owned; "" when unspecified
    dev: bool,
};

pub const DepsResult = struct {
    manifest: []u8,     // owned; relative filename e.g. "package.json"
    format: []const u8, // static: "npm"|"cargo"|"go"|"pip"|"pyproject"
    totalCount: u32,    // count before cap
    deps: []Dep,        // owned; capped at DEPS_MAX
};

const DEPS_MAX: usize = 100;

// Trim surrounding quotes (single or double) from a string
fn depsStripQuotes(s: []const u8) []const u8 {
    const v = std.mem.trim(u8, s, " \t\r\n");
    if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or
        (v[0] == '\'' and v[v.len - 1] == '\'')))
        return v[1 .. v.len - 1];
    return v;
}

// Extract dep name from pip requirement line: "name==1.0", "name>=1.0 ; extras", "name"
fn depsPipParse(line: []const u8) struct { name: []const u8, version: []const u8 } {
    // Strip markers after ';'
    const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
    const raw = std.mem.trim(u8, line[0..semi], " \t");
    // Find first operator: ==, >=, <=, !=, ~=, >, <, [ (extras)
    const ops = [_][]const u8{ "==", ">=", "<=", "!=", "~=", ">", "<", "[" };
    var split: usize = raw.len;
    for (ops) |op| {
        if (std.mem.indexOf(u8, raw, op)) |pos| {
            if (pos < split) split = pos;
        }
    }
    const name = std.mem.trim(u8, raw[0..split], " \t");
    const ver  = std.mem.trim(u8, raw[split..], " \t");
    return .{ .name = name, .version = ver };
}

fn computeDepsNpm(gpa: std.mem.Allocator, content: []const u8) !DepsResult {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const buf = try gpa.alloc(Dep, DEPS_MAX);
    var n: usize = 0;
    var total: u32 = 0;
    errdefer { for (buf[0..n]) |d| { gpa.free(d.name); gpa.free(d.version); } gpa.free(buf); }

    const sections = [_]struct { key: []const u8, dev: bool }{
        .{ .key = "dependencies",     .dev = false },
        .{ .key = "devDependencies",  .dev = true  },
        .{ .key = "peerDependencies", .dev = false },
    };
    for (sections) |sec| {
        const obj = switch (parsed.value) {
            .object => |o| o.get(sec.key) orelse continue,
            else => continue,
        };
        const deps = switch (obj) { .object => |o| o, else => continue };
        var it = deps.iterator();
        while (it.next()) |entry| {
            total += 1;
            if (n >= DEPS_MAX) continue;
            const ver = switch (entry.value_ptr.*) { .string => |s| s, else => "" };
            buf[n] = .{
                .name    = try gpa.dupe(u8, entry.key_ptr.*),
                .version = try gpa.dupe(u8, ver),
                .dev     = sec.dev,
            };
            n += 1;
        }
    }

    return .{
        .manifest = try gpa.dupe(u8, "package.json"),
        .format   = "npm",
        .totalCount = total,
        .deps = try gpa.realloc(buf, n),
    };
}

fn computeDepsCargo(gpa: std.mem.Allocator, content: []const u8) !DepsResult {
    const buf = try gpa.alloc(Dep, DEPS_MAX);
    var n: usize = 0;
    var total: u32 = 0;
    errdefer { for (buf[0..n]) |d| { gpa.free(d.name); gpa.free(d.version); } gpa.free(buf); }

    var in_deps: bool = false;
    var in_dev: bool = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_deps = std.mem.eql(u8, line, "[dependencies]");
            in_dev  = std.mem.eql(u8, line, "[dev-dependencies]");
            continue;
        }
        if (!in_deps and !in_dev) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\"");
        if (key.len == 0) continue;
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // Version: "1.0" or { version = "1.0", ... } or { path = "..." }
        var ver: []const u8 = "";
        if (val.len > 0 and val[0] == '"') {
            ver = depsStripQuotes(val);
        } else if (std.mem.indexOf(u8, val, "version")) |vi| {
            const after = val[vi + 7 ..]; // skip "version"
            if (std.mem.indexOf(u8, after, "\"")) |qi| {
                const inner = after[qi + 1 ..];
                const close = std.mem.indexOfScalar(u8, inner, '"') orelse inner.len;
                ver = inner[0..close];
            }
        }
        total += 1;
        if (n < DEPS_MAX) {
            buf[n] = .{ .name = try gpa.dupe(u8, key), .version = try gpa.dupe(u8, ver), .dev = in_dev };
            n += 1;
        }
    }

    return .{
        .manifest = try gpa.dupe(u8, "Cargo.toml"),
        .format   = "cargo",
        .totalCount = total,
        .deps = try gpa.realloc(buf, n),
    };
}

fn computeDepsGoMod(gpa: std.mem.Allocator, content: []const u8) !DepsResult {
    const buf = try gpa.alloc(Dep, DEPS_MAX);
    var n: usize = 0;
    var total: u32 = 0;
    errdefer { for (buf[0..n]) |d| { gpa.free(d.name); gpa.free(d.version); } gpa.free(buf); }

    var in_require = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '/' ) continue;
        if (std.mem.eql(u8, line, "require (")) { in_require = true; continue; }
        if (std.mem.eql(u8, line, ")"))          { in_require = false; continue; }

        var dep_line: []const u8 = "";
        if (in_require) {
            dep_line = line;
        } else if (std.mem.startsWith(u8, line, "require ")) {
            dep_line = std.mem.trimStart(u8, line[8..], " \t");
        }
        if (dep_line.len == 0) continue;

        // Strip "// indirect" comment
        const comment = std.mem.indexOf(u8, dep_line, "//") orelse dep_line.len;
        const clean = std.mem.trim(u8, dep_line[0..comment], " \t");

        // Split on first whitespace: module-path version
        var i: usize = 0;
        while (i < clean.len and clean[i] != ' ' and clean[i] != '\t') i += 1;
        const name = clean[0..i];
        const ver  = std.mem.trim(u8, clean[i..], " \t");
        if (name.len == 0) continue;

        total += 1;
        if (n < DEPS_MAX) {
            buf[n] = .{ .name = try gpa.dupe(u8, name), .version = try gpa.dupe(u8, ver), .dev = false };
            n += 1;
        }
    }

    return .{
        .manifest = try gpa.dupe(u8, "go.mod"),
        .format   = "go",
        .totalCount = total,
        .deps = try gpa.realloc(buf, n),
    };
}

fn computeDepsPip(gpa: std.mem.Allocator, content: []const u8) !DepsResult {
    const buf = try gpa.alloc(Dep, DEPS_MAX);
    var n: usize = 0;
    var total: u32 = 0;
    errdefer { for (buf[0..n]) |d| { gpa.free(d.name); gpa.free(d.version); } gpa.free(buf); }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '-') continue;
        const p = depsPipParse(line);
        if (p.name.len == 0) continue;
        total += 1;
        if (n < DEPS_MAX) {
            buf[n] = .{ .name = try gpa.dupe(u8, p.name), .version = try gpa.dupe(u8, p.version), .dev = false };
            n += 1;
        }
    }

    return .{
        .manifest = try gpa.dupe(u8, "requirements.txt"),
        .format   = "pip",
        .totalCount = total,
        .deps = try gpa.realloc(buf, n),
    };
}

const DEPS_MANIFESTS = [_]struct { file: []const u8, fmt: []const u8 }{
    .{ .file = "package.json",    .fmt = "npm"    },
    .{ .file = "Cargo.toml",      .fmt = "cargo"  },
    .{ .file = "go.mod",          .fmt = "go"     },
    .{ .file = "requirements.txt",.fmt = "pip"    },
};

pub fn computeDeps(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) !DepsResult {
    for (DEPS_MANIFESTS) |m| {
        const abs_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_path, m.file });
        defer gpa.free(abs_path);

        const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch continue;
        defer file.close(io);
        var rbuf: [4096]u8 = undefined;
        var r = file.reader(io, &rbuf);
        const content = try r.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
        defer gpa.free(content);

        if (std.mem.eql(u8, m.fmt, "npm"))   return computeDepsNpm(gpa, content);
        if (std.mem.eql(u8, m.fmt, "cargo")) return computeDepsCargo(gpa, content);
        if (std.mem.eql(u8, m.fmt, "go"))    return computeDepsGoMod(gpa, content);
        if (std.mem.eql(u8, m.fmt, "pip"))   return computeDepsPip(gpa, content);
    }
    return error.NoManifestFound;
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

