const std = @import("std");

pub const VERSION = "0.54.0";

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

// --- compat-check subcommand ---

fn extractVersionFromLine(line: []const u8) []const u8 {
    const l = if (line.len > 0 and (line[0] == 'v' or line[0] == 'V')) line[1..] else line;
    var it = std.mem.splitScalar(u8, l, ' ');
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] >= '0' and tok[0] <= '9') return tok;
    }
    return l;
}

fn getToolVersionAlloc(gpa: std.mem.Allocator, io: std.Io, tool: []const u8) ![]u8 {
    if (std.mem.eql(u8, tool, "foreman_tools")) return gpa.dupe(u8, VERSION);
    const flag = if (std.mem.eql(u8, tool, "zig")) "version" else "--version";
    const r = std.process.run(gpa, io, .{ .argv = &.{ tool, flag } }) catch return gpa.dupe(u8, "");
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    switch (r.term) {
        .exited => |c| if (c != 0) return gpa.dupe(u8, ""),
        else => return gpa.dupe(u8, ""),
    }
    const raw = std.mem.trim(u8, r.stdout, " \t\n\r");
    const first_nl = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    return gpa.dupe(u8, extractVersionFromLine(raw[0..first_nl]));
}

// Returns a slice into content (not owned). Empty string if not found.
fn parseBaselineField(content: []const u8, field: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (field.len + 3 > 60) continue;
        var key_buf: [64]u8 = undefined;
        key_buf[0] = '"';
        for (field, 0..) |c, j| key_buf[1 + j] = c;
        key_buf[1 + field.len] = '"';
        key_buf[2 + field.len] = ':';
        const key = key_buf[0 .. 3 + field.len];
        const pos = std.mem.indexOf(u8, trimmed, key) orelse continue;
        var rest = std.mem.trimStart(u8, trimmed[pos + key.len ..], " \t");
        if (rest.len == 0 or rest[0] != '"') continue;
        rest = rest[1..];
        const end_q = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        return rest[0..end_q];
    }
    return "";
}

fn buildRollbackCmd(gpa: std.mem.Allocator, tool: []const u8, was: []const u8) ![]u8 {
    if (std.mem.eql(u8, tool, "zig")) {
        const dot = std.mem.lastIndexOfScalar(u8, was, '.') orelse was.len;
        return std.fmt.allocPrint(gpa, "brew uninstall zig && brew install zig@{s}", .{was[0..dot]});
    }
    if (std.mem.eql(u8, tool, "foreman_tools")) {
        return gpa.dupe(u8, "brew uninstall foreman-tools && brew install michaelvgonzaga/foreman/foreman-tools");
    }
    if (std.mem.eql(u8, tool, "node")) {
        const dot = std.mem.indexOfScalar(u8, was, '.') orelse was.len;
        return std.fmt.allocPrint(gpa, "brew uninstall node && brew install node@{s}", .{was[0..dot]});
    }
    if (std.mem.eql(u8, tool, "python3")) {
        const dot2 = std.mem.lastIndexOfScalar(u8, was, '.') orelse was.len;
        return std.fmt.allocPrint(gpa, "brew uninstall python3 && brew install python@{s}", .{was[0..dot2]});
    }
    if (std.mem.eql(u8, tool, "gh")) {
        return gpa.dupe(u8, "# gh updates are generally safe; check: brew info gh");
    }
    if (std.mem.eql(u8, tool, "git")) {
        return gpa.dupe(u8, "# git updates are generally safe; check: brew info git");
    }
    if (std.mem.eql(u8, tool, "brew")) {
        return gpa.dupe(u8, "export HOMEBREW_NO_AUTO_UPDATE=1  # prevents future Homebrew auto-updates");
    }
    return gpa.dupe(u8, "# no rollback command known");
}

fn toolRisk(tool: []const u8) []const u8 {
    if (std.mem.eql(u8, tool, "zig")) return "high";
    if (std.mem.eql(u8, tool, "foreman_tools")) return "high";
    if (std.mem.eql(u8, tool, "node")) return "medium";
    if (std.mem.eql(u8, tool, "python3")) return "medium";
    return "low";
}

pub const COMPAT_TOOLS = [_][]const u8{ "foreman_tools", "zig", "git", "gh", "brew", "node", "python3" };

pub const DriftedTool = struct {
    tool:     []u8,
    was:      []u8,
    now:      []u8,
    risk:     []const u8,
    rollback: []u8,
};

pub const CompatCheckResult = struct {
    ok:           bool,
    baseline_age: []u8,
    drifted:      []DriftedTool,
    advice:       []u8,
};

pub const CompatBaselineResult = struct {
    recorded: bool,
    path:     []u8,
    versions: [COMPAT_TOOLS.len][]u8,
};

fn currentIsoTimestamp(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const r = std.process.run(gpa, io, .{
        .argv = &.{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" },
    }) catch return gpa.dupe(u8, "unknown");
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    return gpa.dupe(u8, std.mem.trim(u8, r.stdout, " \t\n\r"));
}

pub fn computeCompatBaseline(gpa: std.mem.Allocator, io: std.Io) !CompatBaselineResult {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/.foreman", .{home});
    defer gpa.free(dir_path);
    std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch {};

    const baseline_path = try std.fmt.allocPrint(gpa, "{s}/compat-baseline.json", .{dir_path});
    errdefer gpa.free(baseline_path);

    var versions: [COMPAT_TOOLS.len][]u8 = undefined;
    var n_filled: usize = 0;
    errdefer {
        for (versions[0..n_filled]) |v| {
            gpa.free(v);
        }
    }
    for (COMPAT_TOOLS, 0..) |tool, i| {
        versions[i] = getToolVersionAlloc(gpa, io, tool) catch try gpa.dupe(u8, "");
        n_filled = i + 1;
    }

    const ts = currentIsoTimestamp(gpa, io) catch try gpa.dupe(u8, "unknown");
    defer gpa.free(ts);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{baseline_path});
    defer gpa.free(tmp_path);

    var recorded = false;
    write_blk: {
        const f = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch break :write_blk;
        var wbuf: [4096]u8 = undefined;
        var w = f.writerStreaming(io, &wbuf);
        var write_ok = true;
        w.interface.writeAll("{\n  \"recorded_at\": \"") catch { write_ok = false; };
        w.interface.writeAll(ts) catch { write_ok = false; };
        w.interface.writeAll("\",\n  \"tools\": {\n") catch { write_ok = false; };
        for (COMPAT_TOOLS, 0..) |tool, i| {
            if (i > 0) w.interface.writeAll(",\n") catch { write_ok = false; };
            w.interface.print("    \"{s}\": \"{s}\"", .{ tool, versions[i] }) catch { write_ok = false; };
        }
        w.interface.writeAll("\n  }\n}\n") catch { write_ok = false; };
        w.interface.flush() catch { write_ok = false; };
        f.close(io);
        if (write_ok) {
            atomicRenameAbsolute(tmp_path, baseline_path);
            recorded = true;
        }
    }

    return .{
        .recorded = recorded,
        .path = baseline_path,
        .versions = versions,
    };
}

pub fn computeCompatCheck(gpa: std.mem.Allocator, io: std.Io) !CompatCheckResult {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const baseline_path = try std.fmt.allocPrint(gpa, "{s}/.foreman/compat-baseline.json", .{home});
    defer gpa.free(baseline_path);

    const baseline_content: []u8 = blk: {
        const f = std.Io.Dir.openFileAbsolute(io, baseline_path, .{}) catch {
            const age = try gpa.dupe(u8, "none");
            errdefer gpa.free(age);
            const advice = try gpa.dupe(u8, "No baseline recorded. Run: foreman-tools compat-check --baseline");
            errdefer gpa.free(advice);
            const drifted = try gpa.alloc(DriftedTool, 0);
            return .{ .ok = false, .baseline_age = age, .drifted = drifted, .advice = advice };
        };
        defer f.close(io);
        var rbuf: [4096]u8 = undefined;
        var r = f.reader(io, &rbuf);
        break :blk try r.interface.allocRemaining(gpa, .limited(64 * 1024));
    };
    defer gpa.free(baseline_content);

    const recorded_at = parseBaselineField(baseline_content, "recorded_at");
    const baseline_age = try gpa.dupe(u8,
        if (recorded_at.len >= 10) recorded_at[0..10]
        else if (recorded_at.len > 0) recorded_at
        else "unknown");
    errdefer gpa.free(baseline_age);

    var drifted_buf: [COMPAT_TOOLS.len]DriftedTool = undefined;
    var drifted_count: usize = 0;
    var has_high = false;

    for (COMPAT_TOOLS) |tool| {
        const was_str = parseBaselineField(baseline_content, tool);
        if (was_str.len == 0) continue;

        const now_str = try getToolVersionAlloc(gpa, io, tool);
        if (std.mem.eql(u8, was_str, now_str)) {
            gpa.free(now_str);
            continue;
        }

        const risk = toolRisk(tool);
        if (std.mem.eql(u8, risk, "high")) has_high = true;

        drifted_buf[drifted_count] = .{
            .tool     = try gpa.dupe(u8, tool),
            .was      = try gpa.dupe(u8, was_str),
            .now      = now_str,
            .risk     = risk,
            .rollback = try buildRollbackCmd(gpa, tool, was_str),
        };
        drifted_count += 1;
    }

    const drifted = try gpa.alloc(DriftedTool, drifted_count);
    errdefer gpa.free(drifted);
    for (drifted_buf[0..drifted_count], 0..) |d, i| drifted[i] = d;

    const advice: []u8 = if (drifted_count == 0)
        try gpa.dupe(u8, "")
    else blk: {
        const intro: []const u8 = if (has_high)
            "STOP: High-risk tool drift detected. Roll back before proceeding:"
        else
            "Warning: Tool versions changed since baseline:";
        var acc = try gpa.dupe(u8, intro);
        for (drifted) |d| {
            const piece = try std.fmt.allocPrint(gpa,
                " {s} {s}->{s} ({s} risk): {s}.", .{ d.tool, d.was, d.now, d.risk, d.rollback });
            const joined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ acc, piece });
            gpa.free(piece);
            gpa.free(acc);
            acc = joined;
        }
        break :blk acc;
    };

    return .{
        .ok           = drifted_count == 0,
        .baseline_age = baseline_age,
        .drifted      = drifted,
        .advice       = advice,
    };
}

// --- run-tests subcommand ---

const MAX_TEST_FAILURES: usize = 50;

pub const TestFailure = struct {
    file:     []u8,
    line:     u32,
    @"test":  []u8,
    message:  []u8,
};

pub const RunTestsResult = struct {
    framework:   []const u8,
    command:     []u8,
    success:     bool,
    passed:      u32,
    failed:      u32,
    skipped:     u32,
    duration_ms: u64,
    failures:    []TestFailure,
    truncated:   bool,
};

fn detectTestFramework(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    // jest/vitest: package.json
    const pkg = try std.fmt.allocPrint(gpa, "{s}/package.json", .{path});
    defer gpa.free(pkg);
    if (std.Io.Dir.openFileAbsolute(io, pkg, .{})) |f| {
        var rbuf: [4096]u8 = undefined;
        var r = f.reader(io, &rbuf);
        const c = r.interface.allocRemaining(gpa, .limited(128 * 1024)) catch { f.close(io); return null; };
        f.close(io);
        defer gpa.free(c);
        if (std.mem.indexOf(u8, c, "\"vitest\"") != null) return "vitest";
        if (std.mem.indexOf(u8, c, "\"jest\"") != null) return "jest";
    } else |_| {}

    // pytest: pytest.ini, conftest.py, or pyproject.toml with "pytest"
    const pytest_files = [_][]const u8{ "pytest.ini", "conftest.py" };
    for (pytest_files) |pf| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, pf });
        defer gpa.free(p);
        if (fileExists(io, p)) return "pytest";
    }
    const ppt = try std.fmt.allocPrint(gpa, "{s}/pyproject.toml", .{path});
    defer gpa.free(ppt);
    if (std.Io.Dir.openFileAbsolute(io, ppt, .{})) |f| {
        var rbuf: [4096]u8 = undefined;
        var r = f.reader(io, &rbuf);
        const c = r.interface.allocRemaining(gpa, .limited(64 * 1024)) catch { f.close(io); return null; };
        f.close(io);
        defer gpa.free(c);
        if (std.mem.indexOf(u8, c, "pytest") != null) return "pytest";
    } else |_| {}

    // go test
    const gomod = try std.fmt.allocPrint(gpa, "{s}/go.mod", .{path});
    defer gpa.free(gomod);
    if (fileExists(io, gomod)) return "go";

    // cargo test
    const cargo_toml = try std.fmt.allocPrint(gpa, "{s}/Cargo.toml", .{path});
    defer gpa.free(cargo_toml);
    if (fileExists(io, cargo_toml)) return "cargo";

    // zig build test
    const build_zig = try std.fmt.allocPrint(gpa, "{s}/build.zig", .{path});
    defer gpa.free(build_zig);
    if (fileExists(io, build_zig)) return "zig";

    return null;
}

fn appendTestFailure(
    gpa: std.mem.Allocator,
    buf: []TestFailure,
    n: *usize,
    truncated: *bool,
    file: []const u8,
    line: u32,
    name: []const u8,
    msg: []const u8,
) void {
    if (n.* >= MAX_TEST_FAILURES) { truncated.* = true; return; }
    buf[n.*] = .{
        .file    = gpa.dupe(u8, file) catch return,
        .line    = line,
        .@"test" = gpa.dupe(u8, name) catch return,
        .message = gpa.dupe(u8, msg)  catch return,
    };
    n.* += 1;
}

// Returns the first run of digits in s as a u32.
fn firstUintIn(s: []const u8) u32 {
    var i: usize = 0;
    while (i < s.len and (s[i] < '0' or s[i] > '9')) i += 1;
    if (i >= s.len) return 0;
    var acc: u32 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) acc = acc * 10 + (s[i] - '0');
    return acc;
}

// Returns the integer immediately before `marker` in s (e.g. "5" before " passed").
fn uintBefore(s: []const u8, marker: []const u8) u32 {
    const pos = std.mem.indexOf(u8, s, marker) orelse return 0;
    var end = pos;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    var start = end;
    while (start > 0 and s[start - 1] >= '0' and s[start - 1] <= '9') start -= 1;
    if (start == end) return 0;
    return std.fmt.parseInt(u32, s[start..end], 10) catch 0;
}

fn parseZigOutput(
    gpa: std.mem.Allocator,
    output: []const u8,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    buf: []TestFailure,
    n: *usize,
    truncated: *bool,
) void {
    _ = skipped;
    var lines = std.mem.splitScalar(u8, output, '\n');
    var pending_name: [256]u8 = undefined;
    var pending_len: usize = 0;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        // "All N tests passed."
        if (std.mem.startsWith(u8, t, "All ") and std.mem.indexOf(u8, t, " tests passed") != null) {
            passed.* = firstUintIn(t[4..]);
            failed.* = 0;
            continue;
        }
        // "N passed; M failed."
        if (std.mem.indexOf(u8, t, " passed") != null and std.mem.indexOf(u8, t, " failed") != null and
            std.mem.indexOf(u8, t, "Test [") == null) {
            passed.* = firstUintIn(t);
            failed.* = uintBefore(t, " failed");
            continue;
        }
        // "Test [n/total] name... PASS/ok/FAIL"
        if (std.mem.startsWith(u8, t, "Test [")) {
            const dots = std.mem.lastIndexOf(u8, t, "...") orelse continue;
            const status = std.mem.trim(u8, t[dots + 3..], " \t");
            const brk = std.mem.indexOf(u8, t, "] ") orelse continue;
            const name = t[brk + 2 .. dots];
            if (std.mem.startsWith(u8, status, "FAIL") or std.mem.startsWith(u8, status, "fail")) {
                const cl = @min(name.len, 255);
                @memcpy(pending_name[0..cl], name[0..cl]);
                pending_len = cl;
            } else {
                pending_len = 0;
            }
            continue;
        }
        // File ref after a FAIL: "path/file.zig:line:col: ..."
        if (pending_len > 0 and std.mem.indexOf(u8, t, ".zig:") != null) {
            const c1 = std.mem.indexOf(u8, t, ":") orelse t.len;
            const file = t[0..c1];
            const rest = if (c1 + 1 < t.len) t[c1 + 1..] else "";
            const c2 = std.mem.indexOf(u8, rest, ":") orelse rest.len;
            const ln = std.fmt.parseInt(u32, rest[0..c2], 10) catch 0;
            appendTestFailure(gpa, buf, n, truncated, file, ln, pending_name[0..pending_len], t);
            pending_len = 0;
        }
    }
}

fn parseCargoOutput(
    gpa: std.mem.Allocator,
    output: []const u8,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    buf: []TestFailure,
    n: *usize,
    truncated: *bool,
) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var pending_name: [256]u8 = undefined;
    var pending_len: usize = 0;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        // "test result: ok. N passed; M failed; K ignored"
        if (std.mem.startsWith(u8, t, "test result:")) {
            if (std.mem.indexOf(u8, t, "passed") != null) passed.* += firstUintIn(t[12..]);
            if (std.mem.indexOf(u8, t, "ignored") != null) skipped.* += uintBefore(t, " ignored");
            if (std.mem.indexOf(u8, t, "FAILED") != null) failed.* += uintBefore(t, " failed");
            continue;
        }
        // "test name ... FAILED"
        if (std.mem.startsWith(u8, t, "test ") and std.mem.endsWith(u8, t, "FAILED")) {
            const dots = std.mem.lastIndexOf(u8, t, " ... ") orelse t.len;
            const name = t[5..dots];
            const cl = @min(name.len, 255);
            @memcpy(pending_name[0..cl], name[0..cl]);
            pending_len = cl;
            continue;
        }
        // "thread '...' panicked at '...', src/lib.rs:N:M"
        if (pending_len > 0 and std.mem.indexOf(u8, t, "panicked at") != null) {
            var file: []const u8 = "";
            var ln: u32 = 0;
            const rs_pos  = std.mem.indexOf(u8, t, ".rs:");
            const zig_pos = std.mem.indexOf(u8, t, ".zig:");
            const ext_pos = rs_pos orelse zig_pos;
            if (ext_pos) |ep| {
                const el: usize = if (rs_pos != null) 3 else 4;
                var start = ep;
                while (start > 0 and t[start - 1] != ' ' and t[start - 1] != '\'' and t[start - 1] != '"') start -= 1;
                file = t[start..ep + el];
                const after = t[ep + el..];
                if (after.len > 0 and after[0] == ':') {
                    const c2 = std.mem.indexOf(u8, after[1..], ":") orelse after.len - 1;
                    ln = std.fmt.parseInt(u32, after[1..c2 + 1], 10) catch 0;
                }
            }
            appendTestFailure(gpa, buf, n, truncated, file, ln, pending_name[0..pending_len], t);
            pending_len = 0;
        }
    }
}

fn parseGoOutput(
    gpa: std.mem.Allocator,
    output: []const u8,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    buf: []TestFailure,
    n: *usize,
    truncated: *bool,
) void {
    _ = skipped;
    var lines = std.mem.splitScalar(u8, output, '\n');
    var pending_name: [256]u8 = undefined;
    var pending_len: usize = 0;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "--- PASS:")) {
            passed.* += 1;
            pending_len = 0;
        } else if (std.mem.startsWith(u8, t, "--- FAIL:")) {
            failed.* += 1;
            const rest = t[9..];
            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            const name = std.mem.trim(u8, rest[0..sp], " \t");
            const cl = @min(name.len, 255);
            @memcpy(pending_name[0..cl], name[0..cl]);
            pending_len = cl;
        } else if (pending_len > 0 and (std.mem.indexOf(u8, t, ".go:") != null or
            std.mem.indexOf(u8, t, "_test.go:") != null)) {
            const c1 = std.mem.indexOf(u8, t, ":") orelse t.len;
            const file = t[0..c1];
            const rest2 = if (c1 + 1 < t.len) t[c1 + 1..] else "";
            const c2 = std.mem.indexOf(u8, rest2, ":") orelse rest2.len;
            const ln = std.fmt.parseInt(u32, rest2[0..c2], 10) catch 0;
            const msg = if (c2 + 1 < rest2.len) std.mem.trim(u8, rest2[c2 + 1..], " \t") else "";
            appendTestFailure(gpa, buf, n, truncated, file, ln, pending_name[0..pending_len], msg);
            pending_len = 0;
        }
    }
}

fn parsePytestOutput(
    gpa: std.mem.Allocator,
    output: []const u8,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    buf: []TestFailure,
    n: *usize,
    truncated: *bool,
) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var pass_line: u32 = 0;
    var fail_line: u32 = 0;
    var skip_line: u32 = 0;
    var got_summary = false;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "PASSED ")) {
            pass_line += 1;
        } else if (std.mem.startsWith(u8, t, "FAILED ")) {
            fail_line += 1;
            const rest = t[7..];
            const dash = std.mem.indexOf(u8, rest, " - ") orelse rest.len;
            const test_ref = rest[0..dash];
            const msg = if (dash + 3 < rest.len) rest[dash + 3..] else "";
            const dcolon = std.mem.indexOf(u8, test_ref, "::") orelse test_ref.len;
            const file = test_ref[0..dcolon];
            const name = if (dcolon + 2 < test_ref.len) test_ref[dcolon + 2..] else test_ref;
            appendTestFailure(gpa, buf, n, truncated, file, 0, name, msg);
        } else if (std.mem.startsWith(u8, t, "SKIPPED ") or std.mem.startsWith(u8, t, "XFAIL ")) {
            skip_line += 1;
        } else if (std.mem.indexOf(u8, t, " passed") != null and std.mem.indexOf(u8, t, " in ") != null) {
            got_summary = true;
            if (std.mem.indexOf(u8, t, "failed") != null) {
                failed.* = firstUintIn(t);
                passed.* = uintBefore(t, " passed");
            } else {
                passed.* = firstUintIn(t);
            }
            if (std.mem.indexOf(u8, t, "skipped") != null) skipped.* = uintBefore(t, " skipped");
        }
    }
    if (!got_summary) {
        passed.*  = pass_line;
        failed.*  = fail_line;
        skipped.* = skip_line;
    }
}

fn parseJestOutput(
    output: []const u8,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        // "Tests:       1 failed, 10 passed, 11 total"
        if (std.mem.startsWith(u8, t, "Tests:")) {
            const rest = t[6..];
            if (std.mem.indexOf(u8, rest, "failed") != null) failed.* = firstUintIn(rest);
            if (std.mem.indexOf(u8, rest, "passed") != null) passed.* = uintBefore(rest, " passed");
            const sk_marker: ?[]const u8 =
                if (std.mem.indexOf(u8, rest, " skipped") != null) " skipped"
                else if (std.mem.indexOf(u8, rest, " pending") != null) " pending"
                else null;
            if (sk_marker) |m| skipped.* = uintBefore(rest, m);
        }
    }
}

pub fn computeRunTests(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !RunTestsResult {
    const fw = try detectTestFramework(gpa, io, path) orelse return error.NoTestFramework;

    const fw_argv: []const []const u8 = if (std.mem.eql(u8, fw, "jest"))
        &.{ "env", "-C", path, "npx", "jest" }
    else if (std.mem.eql(u8, fw, "vitest"))
        &.{ "env", "-C", path, "npx", "vitest", "run" }
    else if (std.mem.eql(u8, fw, "pytest"))
        &.{ "env", "-C", path, "python3", "-m", "pytest", "--tb=short", "-q" }
    else if (std.mem.eql(u8, fw, "go"))
        &.{ "env", "-C", path, "go", "test", "./..." }
    else if (std.mem.eql(u8, fw, "cargo"))
        &.{ "env", "-C", path, "cargo", "test" }
    else // zig
        &.{ "env", "-C", path, "zig", "build", "test" };

    const command: []u8 = if (std.mem.eql(u8, fw, "jest"))
        try gpa.dupe(u8, "npx jest")
    else if (std.mem.eql(u8, fw, "vitest"))
        try gpa.dupe(u8, "npx vitest run")
    else if (std.mem.eql(u8, fw, "pytest"))
        try gpa.dupe(u8, "python3 -m pytest --tb=short -q")
    else if (std.mem.eql(u8, fw, "go"))
        try gpa.dupe(u8, "go test ./...")
    else if (std.mem.eql(u8, fw, "cargo"))
        try gpa.dupe(u8, "cargo test")
    else
        try gpa.dupe(u8, "zig build test");
    errdefer gpa.free(command);

    var ts_start: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_start);

    const r = std.process.run(gpa, io, .{ .argv = fw_argv }) catch {
        const failures = try gpa.alloc(TestFailure, 0);
        return RunTestsResult{
            .framework   = fw,
            .command     = command,
            .success     = false,
            .passed      = 0,
            .failed      = 1,
            .skipped     = 0,
            .duration_ms = 0,
            .failures    = failures,
            .truncated   = false,
        };
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    var ts_end: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_end);
    const duration_ms: u64 = blk: {
        const start_ms = @as(u64, @intCast(ts_start.sec)) * 1000 + @as(u64, @intCast(ts_start.nsec)) / 1_000_000;
        const end_ms   = @as(u64, @intCast(ts_end.sec))   * 1000 + @as(u64, @intCast(ts_end.nsec))   / 1_000_000;
        break :blk if (end_ms > start_ms) end_ms - start_ms else 0;
    };

    const success = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };

    const combined = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ r.stdout, r.stderr });
    defer gpa.free(combined);

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;
    var fbuf: [MAX_TEST_FAILURES]TestFailure = undefined;
    var fn_count: usize = 0;
    var truncated = false;

    if (std.mem.eql(u8, fw, "zig")) {
        parseZigOutput(gpa, combined, &passed, &failed, &skipped, &fbuf, &fn_count, &truncated);
    } else if (std.mem.eql(u8, fw, "cargo")) {
        parseCargoOutput(gpa, combined, &passed, &failed, &skipped, &fbuf, &fn_count, &truncated);
    } else if (std.mem.eql(u8, fw, "go")) {
        parseGoOutput(gpa, combined, &passed, &failed, &skipped, &fbuf, &fn_count, &truncated);
    } else if (std.mem.eql(u8, fw, "pytest")) {
        parsePytestOutput(gpa, combined, &passed, &failed, &skipped, &fbuf, &fn_count, &truncated);
    } else {
        parseJestOutput(combined, &passed, &failed, &skipped);
    }

    if (passed == 0 and failed == 0 and !success) failed = 1;

    const failures = try gpa.alloc(TestFailure, fn_count);
    for (fbuf[0..fn_count], 0..) |f, i| failures[i] = f;

    return .{
        .framework   = fw,
        .command     = command,
        .success     = success,
        .passed      = passed,
        .failed      = failed,
        .skipped     = skipped,
        .duration_ms = duration_ms,
        .failures    = failures,
        .truncated   = truncated,
    };
}

// --- env-inspect subcommand ---

pub const LangEntry = struct {
    name:    []const u8,
    version: []u8,
    present: bool,
};

pub const PmEntry = struct {
    name:    []const u8,
    version: []u8,
    present: bool,
};

pub const EnvInspectResult = struct {
    languages:       []LangEntry,
    packageManagers: []PmEntry,
    missing:         [][]u8,
    envVars:         [][]u8,
};

// Finds the first N.N[.N...] pattern in output (handles v/V prefix, go1.X.Y, etc.)
fn extractVersionStr(output: []const u8) []const u8 {
    var i: usize = 0;
    while (i < output.len) {
        const c = output[i];
        const sv = (c == 'v' or c == 'V') and i + 1 < output.len and
            output[i + 1] >= '0' and output[i + 1] <= '9';
        const sd = c >= '0' and c <= '9';
        if (sv or sd) {
            const begin = if (sv) i + 1 else i;
            var j = begin;
            while (j < output.len and (output[j] >= '0' and output[j] <= '9' or output[j] == '.')) j += 1;
            const found = output[begin..j];
            if (std.mem.indexOfScalar(u8, found, '.') != null and found.len >= 3) return found;
        }
        i += 1;
    }
    return "";
}

fn dirExists(io: std.Io, path: []const u8) bool {
    const d = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

const BinaryInfo = struct { present: bool, version: []u8 };

fn checkBinary(gpa: std.mem.Allocator, io: std.Io, binary: []const u8, flag: []const u8) !BinaryInfo {
    const r = std.process.run(gpa, io, .{ .argv = &.{ binary, flag } }) catch {
        return BinaryInfo{ .present = false, .version = try gpa.dupe(u8, "") };
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const combined = try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.stdout, r.stderr });
    defer gpa.free(combined);
    return BinaryInfo{ .present = true, .version = try gpa.dupe(u8, extractVersionStr(combined)) };
}

pub fn computeEnvInspect(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !EnvInspectResult {
    var lang_buf: [7]LangEntry = undefined;
    var n_lang: usize = 0;
    var pm_buf: [6]PmEntry = undefined;
    var n_pm: usize = 0;
    var miss_buf: [20][]u8 = undefined;
    var n_miss: usize = 0;

    // --- Language detection (manifest-gated) ---

    // Go
    {
        const m = try std.fmt.allocPrint(gpa, "{s}/go.mod", .{path});
        defer gpa.free(m);
        if (fileExists(io, m)) {
            const info = try checkBinary(gpa, io, "go", "version");
            lang_buf[n_lang] = .{ .name = "go", .version = info.version, .present = info.present };
            n_lang += 1;
            if (!info.present) { miss_buf[n_miss] = try gpa.dupe(u8, "go runtime"); n_miss += 1; }
        }
    }

    // Python
    {
        const has = blk: {
            const p1 = try std.fmt.allocPrint(gpa, "{s}/requirements.txt", .{path}); defer gpa.free(p1);
            if (fileExists(io, p1)) break :blk true;
            const p2 = try std.fmt.allocPrint(gpa, "{s}/pyproject.toml", .{path}); defer gpa.free(p2);
            if (fileExists(io, p2)) break :blk true;
            const p3 = try std.fmt.allocPrint(gpa, "{s}/setup.py", .{path}); defer gpa.free(p3);
            break :blk fileExists(io, p3);
        };
        if (has) {
            const info = try checkBinary(gpa, io, "python3", "--version");
            lang_buf[n_lang] = .{ .name = "python", .version = info.version, .present = info.present };
            n_lang += 1;
            if (!info.present) {
                miss_buf[n_miss] = try gpa.dupe(u8, "python3 runtime"); n_miss += 1;
            } else {
                const v1 = try std.fmt.allocPrint(gpa, "{s}/.venv", .{path}); defer gpa.free(v1);
                const v2 = try std.fmt.allocPrint(gpa, "{s}/venv", .{path});  defer gpa.free(v2);
                if (!dirExists(io, v1) and !dirExists(io, v2)) {
                    miss_buf[n_miss] = try gpa.dupe(u8, ".venv (run: python3 -m venv .venv && pip install -r requirements.txt)");
                    n_miss += 1;
                }
            }
        }
    }

    // Node
    {
        const m = try std.fmt.allocPrint(gpa, "{s}/package.json", .{path}); defer gpa.free(m);
        if (fileExists(io, m)) {
            const info = try checkBinary(gpa, io, "node", "--version");
            lang_buf[n_lang] = .{ .name = "node", .version = info.version, .present = info.present };
            n_lang += 1;
            if (!info.present) {
                miss_buf[n_miss] = try gpa.dupe(u8, "node runtime"); n_miss += 1;
            } else {
                const nm = try std.fmt.allocPrint(gpa, "{s}/node_modules", .{path}); defer gpa.free(nm);
                if (!dirExists(io, nm)) {
                    miss_buf[n_miss] = try gpa.dupe(u8, "node_modules (run: npm install)"); n_miss += 1;
                }
            }
        }
    }

    // Rust
    {
        const m = try std.fmt.allocPrint(gpa, "{s}/Cargo.toml", .{path}); defer gpa.free(m);
        if (fileExists(io, m)) {
            const info = try checkBinary(gpa, io, "rustc", "--version");
            lang_buf[n_lang] = .{ .name = "rust", .version = info.version, .present = info.present };
            n_lang += 1;
            if (!info.present) { miss_buf[n_miss] = try gpa.dupe(u8, "rust runtime (rustup)"); n_miss += 1; }
        }
    }

    // Zig
    {
        const m = try std.fmt.allocPrint(gpa, "{s}/build.zig", .{path}); defer gpa.free(m);
        if (fileExists(io, m)) {
            const info = try checkBinary(gpa, io, "zig", "version");
            lang_buf[n_lang] = .{ .name = "zig", .version = info.version, .present = info.present };
            n_lang += 1;
            if (!info.present) { miss_buf[n_miss] = try gpa.dupe(u8, "zig runtime"); n_miss += 1; }
        }
    }

    // Ruby
    {
        const m = try std.fmt.allocPrint(gpa, "{s}/Gemfile", .{path}); defer gpa.free(m);
        if (fileExists(io, m)) {
            const info = try checkBinary(gpa, io, "ruby", "--version");
            lang_buf[n_lang] = .{ .name = "ruby", .version = info.version, .present = info.present };
            n_lang += 1;
            if (!info.present) {
                miss_buf[n_miss] = try gpa.dupe(u8, "ruby runtime"); n_miss += 1;
            } else {
                const vb = try std.fmt.allocPrint(gpa, "{s}/vendor/bundle", .{path}); defer gpa.free(vb);
                if (!dirExists(io, vb)) {
                    miss_buf[n_miss] = try gpa.dupe(u8, "vendor/bundle (run: bundle install)"); n_miss += 1;
                }
            }
        }
    }

    // Java
    {
        const has = blk: {
            const p1 = try std.fmt.allocPrint(gpa, "{s}/pom.xml", .{path});       defer gpa.free(p1);
            if (fileExists(io, p1)) break :blk true;
            const p2 = try std.fmt.allocPrint(gpa, "{s}/build.gradle", .{path});  defer gpa.free(p2);
            break :blk fileExists(io, p2);
        };
        if (has) {
            const info = try checkBinary(gpa, io, "java", "--version");
            lang_buf[n_lang] = .{ .name = "java", .version = info.version, .present = info.present };
            n_lang += 1;
            if (!info.present) { miss_buf[n_miss] = try gpa.dupe(u8, "java runtime"); n_miss += 1; }
        }
    }

    // --- Package managers (always checked) ---

    const pm_specs = [_]struct { name: []const u8, bin: []const u8, flag: []const u8 }{
        .{ .name = "npm",   .bin = "npm",   .flag = "--version" },
        .{ .name = "pip",   .bin = "pip3",  .flag = "--version" },
        .{ .name = "cargo", .bin = "cargo", .flag = "--version" },
        .{ .name = "brew",  .bin = "brew",  .flag = "--version" },
        .{ .name = "yarn",  .bin = "yarn",  .flag = "--version" },
        .{ .name = "pnpm",  .bin = "pnpm",  .flag = "--version" },
    };
    for (pm_specs) |s| {
        const info = try checkBinary(gpa, io, s.bin, s.flag);
        pm_buf[n_pm] = .{ .name = s.name, .version = info.version, .present = info.present };
        n_pm += 1;
    }

    // --- Env vars from .env* files ---

    var env_keys: std.ArrayList([]u8) = .empty;
    errdefer { for (env_keys.items) |k| gpa.free(k); env_keys.deinit(gpa); }

    if (computeEnvScan(gpa, io, path)) |er| {
        defer {
            for (er.files) |ef| {
                gpa.free(ef.file);
                for (ef.keys) |k| gpa.free(k);
                gpa.free(ef.keys);
            }
            gpa.free(er.files);
        }
        for (er.files) |ef| {
            for (ef.keys) |k| try env_keys.append(gpa, try gpa.dupe(u8, k));
        }
    } else |_| {}

    // --- Allocate final slices ---

    const languages = try gpa.alloc(LangEntry, n_lang);
    for (lang_buf[0..n_lang], 0..) |l, i| languages[i] = l;
    const packageManagers = try gpa.alloc(PmEntry, n_pm);
    for (pm_buf[0..n_pm], 0..) |p, i| packageManagers[i] = p;
    const missing = try gpa.alloc([]u8, n_miss);
    for (miss_buf[0..n_miss], 0..) |m, i| missing[i] = m;
    const envVars = try env_keys.toOwnedSlice(gpa);

    return .{
        .languages       = languages,
        .packageManagers = packageManagers,
        .missing         = missing,
        .envVars         = envVars,
    };
}

// --- build subcommand ---

const MAX_BUILD_ERRORS: usize = 50;
const MAX_BUILD_WARNINGS: usize = 20;

pub const BuildError = struct {
    file:     []u8,
    line:     u32,
    col:      u32,
    message:  []u8,
    severity: []const u8,
};

pub const BuildWarning = struct {
    file:    []u8,
    line:    u32,
    col:     u32,
    message: []u8,
};

pub const BuildResult = struct {
    tool:        []const u8,
    command:     []u8,
    success:     bool,
    errors:      []BuildError,
    warnings:    []BuildWarning,
    duration_ms: u64,
    truncated:   bool,
};

fn appendBuildError(
    gpa: std.mem.Allocator,
    buf: []BuildError,
    n: *usize,
    truncated: *bool,
    file: []const u8,
    line: u32,
    col: u32,
    msg: []const u8,
    sev: []const u8,
) void {
    if (n.* >= buf.len) { truncated.* = true; return; }
    buf[n.*] = .{
        .file     = gpa.dupe(u8, file) catch return,
        .line     = line,
        .col      = col,
        .message  = gpa.dupe(u8, msg) catch return,
        .severity = sev,
    };
    n.* += 1;
}

fn appendBuildWarning(
    gpa: std.mem.Allocator,
    buf: []BuildWarning,
    n: *usize,
    truncated: *bool,
    file: []const u8,
    line: u32,
    col: u32,
    msg: []const u8,
) void {
    if (n.* >= buf.len) { truncated.* = true; return; }
    buf[n.*] = .{
        .file    = gpa.dupe(u8, file) catch return,
        .line    = line,
        .col     = col,
        .message = gpa.dupe(u8, msg) catch return,
    };
    n.* += 1;
}

fn detectBuildTool(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const cargo_toml = try std.fmt.allocPrint(gpa, "{s}/Cargo.toml", .{path});
    defer gpa.free(cargo_toml);
    if (fileExists(io, cargo_toml)) return "cargo";

    const build_zig = try std.fmt.allocPrint(gpa, "{s}/build.zig", .{path});
    defer gpa.free(build_zig);
    if (fileExists(io, build_zig)) return "zig";

    const gomod = try std.fmt.allocPrint(gpa, "{s}/go.mod", .{path});
    defer gpa.free(gomod);
    if (fileExists(io, gomod)) return "go";

    const pkg = try std.fmt.allocPrint(gpa, "{s}/package.json", .{path});
    defer gpa.free(pkg);
    if (std.Io.Dir.openFileAbsolute(io, pkg, .{})) |f| {
        var rbuf: [4096]u8 = undefined;
        var r = f.reader(io, &rbuf);
        const c = r.interface.allocRemaining(gpa, .limited(64 * 1024)) catch { f.close(io); return null; };
        f.close(io);
        defer gpa.free(c);
        if (std.mem.indexOf(u8, c, "\"scripts\"") != null and
            std.mem.indexOf(u8, c, "\"build\"") != null) return "npm";
    } else |_| {}

    const makefile = try std.fmt.allocPrint(gpa, "{s}/Makefile", .{path});
    defer gpa.free(makefile);
    if (fileExists(io, makefile)) return "make";

    return null;
}

// Cargo build output: state machine pairing "error[Exx]: msg" with " --> file:N:M".
fn parseCargoBuildOutput(
    gpa: std.mem.Allocator,
    output: []const u8,
    errbuf: []BuildError,
    n_err: *usize,
    warnbuf: []BuildWarning,
    n_warn: *usize,
    truncated: *bool,
) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var pmsg: [512]u8 = undefined;
    var pmsg_len: usize = 0;
    var psev: []const u8 = "";

    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "error[") or std.mem.startsWith(u8, t, "error: ")) {
            const colon = std.mem.indexOf(u8, t, ": ") orelse t.len;
            const msg = if (colon + 2 < t.len) t[colon + 2..] else t;
            const cl = @min(msg.len, pmsg.len);
            @memcpy(pmsg[0..cl], msg[0..cl]);
            pmsg_len = cl;
            psev = "error";
        } else if (std.mem.startsWith(u8, t, "warning[") or std.mem.startsWith(u8, t, "warning: ")) {
            const colon = std.mem.indexOf(u8, t, ": ") orelse t.len;
            const msg = if (colon + 2 < t.len) t[colon + 2..] else t;
            const cl = @min(msg.len, pmsg.len);
            @memcpy(pmsg[0..cl], msg[0..cl]);
            pmsg_len = cl;
            psev = "warning";
        } else if (pmsg_len > 0 and std.mem.startsWith(u8, t, "--> ")) {
            const loc = t[4..];
            const c2_opt = std.mem.lastIndexOf(u8, loc, ":");
            if (c2_opt == null) { pmsg_len = 0; psev = ""; continue; }
            const c2 = c2_opt.?;
            const c1_opt = std.mem.lastIndexOf(u8, loc[0..c2], ":");
            const file: []const u8 = if (c1_opt) |c1| loc[0..c1] else loc[0..c2];
            const ln_s: []const u8 = if (c1_opt) |c1| loc[c1 + 1..c2] else loc[c2 + 1..];
            const col_s: []const u8 = if (c1_opt != null) loc[c2 + 1..] else "";
            const ln = std.fmt.parseInt(u32, ln_s, 10) catch 0;
            const col_num = std.fmt.parseInt(u32, col_s, 10) catch 0;
            if (std.mem.eql(u8, psev, "error")) {
                appendBuildError(gpa, errbuf, n_err, truncated, file, ln, col_num, pmsg[0..pmsg_len], "error");
            } else {
                appendBuildWarning(gpa, warnbuf, n_warn, truncated, file, ln, col_num, pmsg[0..pmsg_len]);
            }
            pmsg_len = 0;
            psev = "";
        }
    }
}

// Zig/gcc/clang build output: "path:N:M: error: message" or "path:N: error: message".
fn parseZigBuildOutput(
    gpa: std.mem.Allocator,
    output: []const u8,
    errbuf: []BuildError,
    n_err: *usize,
    warnbuf: []BuildWarning,
    n_warn: *usize,
    truncated: *bool,
) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        const is_err = std.mem.indexOf(u8, t, ": error: ") != null;
        const is_warn = std.mem.indexOf(u8, t, ": warning: ") != null;
        if (!is_err and !is_warn) continue;
        const sev_marker: []const u8 = if (is_err) ": error: " else ": warning: ";
        const sev_pos = std.mem.indexOf(u8, t, sev_marker) orelse continue;
        const loc = t[0..sev_pos];
        const c2_opt = std.mem.lastIndexOf(u8, loc, ":");
        if (c2_opt == null) continue;
        const c2 = c2_opt.?;
        const c1_opt = std.mem.lastIndexOf(u8, loc[0..c2], ":");
        const file: []const u8 = if (c1_opt) |c1| loc[0..c1] else loc[0..c2];
        if (file.len == 0) continue;
        const ln_s: []const u8 = if (c1_opt) |c1| loc[c1 + 1..c2] else loc[c2 + 1..];
        const col_s: []const u8 = if (c1_opt != null) loc[c2 + 1..] else "";
        const ln = std.fmt.parseInt(u32, ln_s, 10) catch 0;
        const col_num = std.fmt.parseInt(u32, col_s, 10) catch 0;
        const msg = t[sev_pos + sev_marker.len..];
        if (is_err) {
            appendBuildError(gpa, errbuf, n_err, truncated, file, ln, col_num, msg, "error");
        } else {
            appendBuildWarning(gpa, warnbuf, n_warn, truncated, file, ln, col_num, msg);
        }
    }
}

// Go build output: "./file.go:N:M: message".
fn parseGoBuildOutput(
    gpa: std.mem.Allocator,
    output: []const u8,
    errbuf: []BuildError,
    n_err: *usize,
    truncated: *bool,
) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, t, ".go:") == null) continue;
        if (!std.mem.startsWith(u8, t, "./") and !std.mem.startsWith(u8, t, "/")) continue;
        const c1 = std.mem.indexOf(u8, t, ":") orelse continue;
        const file = t[0..c1];
        const rest1 = if (c1 + 1 < t.len) t[c1 + 1..] else continue;
        const c2 = std.mem.indexOf(u8, rest1, ":") orelse continue;
        const ln = std.fmt.parseInt(u32, rest1[0..c2], 10) catch continue;
        const rest2 = if (c2 + 1 < rest1.len) rest1[c2 + 1..] else continue;
        const c3_opt = std.mem.indexOf(u8, rest2, ":");
        const col_num: u32 = if (c3_opt) |c3| std.fmt.parseInt(u32, rest2[0..c3], 10) catch 0 else 0;
        const msg_raw: []const u8 = if (c3_opt) |c3| (if (c3 + 1 < rest2.len) rest2[c3 + 1..] else rest2) else rest2;
        const msg = std.mem.trim(u8, msg_raw, " \t");
        appendBuildError(gpa, errbuf, n_err, truncated, file, ln, col_num, msg, "error");
    }
}

// TypeScript compiler output: "file.ts(N,M): error TSXXXX: message".
fn parseTscOutput(
    gpa: std.mem.Allocator,
    output: []const u8,
    errbuf: []BuildError,
    n_err: *usize,
    warnbuf: []BuildWarning,
    n_warn: *usize,
    truncated: *bool,
) void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        const is_err = std.mem.indexOf(u8, t, "): error ") != null;
        const is_warn = std.mem.indexOf(u8, t, "): warning ") != null;
        if (!is_err and !is_warn) continue;
        const paren = std.mem.indexOf(u8, t, "(") orelse continue;
        const file = t[0..paren];
        if (!std.mem.endsWith(u8, file, ".ts") and
            !std.mem.endsWith(u8, file, ".tsx") and
            !std.mem.endsWith(u8, file, ".js")) continue;
        const inner_start = paren + 1;
        const close_off = std.mem.indexOf(u8, t[inner_start..], ")") orelse continue;
        const coords = t[inner_start .. inner_start + close_off];
        const comma = std.mem.indexOf(u8, coords, ",") orelse coords.len;
        const ln = std.fmt.parseInt(u32, coords[0..comma], 10) catch 0;
        const col_num: u32 = if (comma + 1 < coords.len) std.fmt.parseInt(u32, coords[comma + 1..], 10) catch 0 else 0;
        const sev_marker: []const u8 = if (is_err) "): error " else "): warning ";
        const sev_pos = std.mem.indexOf(u8, t, sev_marker) orelse continue;
        const msg = t[sev_pos + sev_marker.len..];
        if (is_err) {
            appendBuildError(gpa, errbuf, n_err, truncated, file, ln, col_num, msg, "error");
        } else {
            appendBuildWarning(gpa, warnbuf, n_warn, truncated, file, ln, col_num, msg);
        }
    }
}

pub fn computeBuild(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !BuildResult {
    const tool = try detectBuildTool(gpa, io, path) orelse return error.NoBuildSystem;

    const argv: []const []const u8 = if (std.mem.eql(u8, tool, "cargo"))
        &.{ "env", "-C", path, "cargo", "build" }
    else if (std.mem.eql(u8, tool, "zig"))
        &.{ "env", "-C", path, "zig", "build" }
    else if (std.mem.eql(u8, tool, "go"))
        &.{ "env", "-C", path, "go", "build", "./..." }
    else if (std.mem.eql(u8, tool, "npm"))
        &.{ "env", "-C", path, "npm", "run", "build" }
    else
        &.{ "env", "-C", path, "make" };

    const command: []u8 = if (std.mem.eql(u8, tool, "cargo"))
        try gpa.dupe(u8, "cargo build")
    else if (std.mem.eql(u8, tool, "zig"))
        try gpa.dupe(u8, "zig build")
    else if (std.mem.eql(u8, tool, "go"))
        try gpa.dupe(u8, "go build ./...")
    else if (std.mem.eql(u8, tool, "npm"))
        try gpa.dupe(u8, "npm run build")
    else
        try gpa.dupe(u8, "make");
    errdefer gpa.free(command);

    var ts_start: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_start);

    const r = std.process.run(gpa, io, .{ .argv = argv }) catch {
        const errors = try gpa.alloc(BuildError, 0);
        const warnings = try gpa.alloc(BuildWarning, 0);
        return BuildResult{
            .tool        = tool,
            .command     = command,
            .success     = false,
            .errors      = errors,
            .warnings    = warnings,
            .duration_ms = 0,
            .truncated   = false,
        };
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);

    var ts_end: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_end);
    const duration_ms: u64 = blk: {
        const start_ms = @as(u64, @intCast(ts_start.sec)) * 1000 + @as(u64, @intCast(ts_start.nsec)) / 1_000_000;
        const end_ms   = @as(u64, @intCast(ts_end.sec))   * 1000 + @as(u64, @intCast(ts_end.nsec))   / 1_000_000;
        break :blk if (end_ms > start_ms) end_ms - start_ms else 0;
    };

    const success = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };

    const combined = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ r.stdout, r.stderr });
    defer gpa.free(combined);

    var errbuf: [MAX_BUILD_ERRORS]BuildError = undefined;
    var warnbuf: [MAX_BUILD_WARNINGS]BuildWarning = undefined;
    var n_err: usize = 0;
    var n_warn: usize = 0;
    var truncated: bool = false;

    if (std.mem.eql(u8, tool, "cargo")) {
        parseCargoBuildOutput(gpa, combined, errbuf[0..], &n_err, warnbuf[0..], &n_warn, &truncated);
    } else if (std.mem.eql(u8, tool, "zig") or std.mem.eql(u8, tool, "make")) {
        parseZigBuildOutput(gpa, combined, errbuf[0..], &n_err, warnbuf[0..], &n_warn, &truncated);
    } else if (std.mem.eql(u8, tool, "go")) {
        parseGoBuildOutput(gpa, combined, errbuf[0..], &n_err, &truncated);
    } else {
        parseTscOutput(gpa, combined, errbuf[0..], &n_err, warnbuf[0..], &n_warn, &truncated);
    }

    const errors = try gpa.alloc(BuildError, n_err);
    for (errbuf[0..n_err], 0..) |e, i| errors[i] = e;
    const warnings = try gpa.alloc(BuildWarning, n_warn);
    for (warnbuf[0..n_warn], 0..) |w, i| warnings[i] = w;

    return .{
        .tool        = tool,
        .command     = command,
        .success     = success,
        .errors      = errors,
        .warnings    = warnings,
        .duration_ms = duration_ms,
        .truncated   = truncated,
    };
}

// --- symbol-find subcommand ---

const SYMBOL_FIND_MAX_REFS: usize = 100;
const SYMBOL_FIND_MAX_FILE_BYTES: usize = 5 * 1024 * 1024;

pub const SymbolRef = struct { file: []u8, line: u32 };

pub const SymbolFindResult = struct {
    symbol:     []const u8,
    kind:       []const u8,
    definition: ?SymbolRef,
    references: []SymbolRef,
    capped:     bool,
};

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
           (c >= '0' and c <= '9') or c == '_';
}

fn wholeWordPos(line: []const u8, name: []const u8) ?usize {
    if (name.len == 0) return null;
    var start: usize = 0;
    while (start + name.len <= line.len) {
        const rel = std.mem.indexOf(u8, line[start..], name) orelse return null;
        const pos = start + rel;
        const before_ok = pos == 0 or !isWordChar(line[pos - 1]);
        const after_ok  = pos + name.len >= line.len or !isWordChar(line[pos + name.len]);
        if (before_ok and after_ok) return pos;
        start = pos + 1;
    }
    return null;
}

// Returns true if `kw` appears in `line` at a word boundary, immediately
// followed (after optional " \t*&") by `name` at a word boundary.
fn kwdMatch(line: []const u8, kw: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i + kw.len <= line.len) : (i += 1) {
        if (!std.mem.eql(u8, line[i .. i + kw.len], kw)) continue;
        if (i > 0 and isWordChar(line[i - 1])) continue;
        const after = std.mem.trimStart(u8, line[i + kw.len..], " \t*&");
        if (std.mem.startsWith(u8, after, name) and
            (after.len == name.len or !isWordChar(after[name.len]))) return true;
    }
    return false;
}

fn declarationKind(line: []const u8, name: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == 0) return null;
    if (std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#") or
        std.mem.startsWith(u8, t, "*") or std.mem.startsWith(u8, t, "--")) return null;

    if (kwdMatch(t, "fn ", name) or kwdMatch(t, "def ", name) or
        kwdMatch(t, "function ", name) or kwdMatch(t, "func ", name) or
        kwdMatch(t, "fun ", name) or kwdMatch(t, "proc ", name) or
        kwdMatch(t, "method ", name) or kwdMatch(t, "sub ", name)) return "function";

    if (kwdMatch(t, "class ", name) or kwdMatch(t, "struct ", name) or
        kwdMatch(t, "trait ", name) or kwdMatch(t, "interface ", name) or
        kwdMatch(t, "enum ", name) or kwdMatch(t, "protocol ", name) or
        kwdMatch(t, "module ", name)) return "type";

    if (kwdMatch(t, "type ", name)) return "type";

    if (kwdMatch(t, "const ", name) or kwdMatch(t, "var ", name) or
        kwdMatch(t, "let ", name) or kwdMatch(t, "val ", name)) return "constant";

    return null;
}

fn scanFileForSymbol(
    gpa: std.mem.Allocator,
    io: std.Io,
    abs_path: []const u8,
    rel_path: []const u8,
    name: []const u8,
    def: *?SymbolRef,
    def_kind: *[]const u8,
    refs: *std.ArrayList(SymbolRef),
    capped: *bool,
) !void {
    const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch return;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = r.interface.allocRemaining(gpa, .limited(SYMBOL_FIND_MAX_FILE_BYTES)) catch return;
    defer gpa.free(content);
    // Skip binary files (Mach-O, ELF, fat binary)
    if (content.len >= 4 and (
        std.mem.eql(u8, content[0..4], "\xcf\xfa\xed\xfe") or
        std.mem.eql(u8, content[0..4], "\xfe\xed\xfa\xcf") or
        std.mem.eql(u8, content[0..4], "\xca\xfe\xba\xbe") or
        std.mem.eql(u8, content[0..4], "\x7fELF"))) return;

    var line_num: u32 = 1;
    var line_start: usize = 0;
    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = content[line_start..line_end];

        if (wholeWordPos(line, name) != null) {
            if (declarationKind(line, name)) |kind| {
                if (def.* == null) {
                    def.* = .{ .file = try gpa.dupe(u8, rel_path), .line = line_num };
                    def_kind.* = kind;
                }
                // definition line is not added to refs
            } else if (refs.items.len < SYMBOL_FIND_MAX_REFS) {
                try refs.append(gpa, .{ .file = try gpa.dupe(u8, rel_path), .line = line_num });
            } else {
                capped.* = true;
            }
        }

        line_num += 1;
        line_start = line_end + 1;
    }
}

fn walkSymbolFind(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    root: []const u8,
    name: []const u8,
    def: *?SymbolRef,
    def_kind: *[]const u8,
    refs: *std.ArrayList(SymbolRef),
    capped: *bool,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            if (shouldSkipGrepFile(entry.name)) continue;
            const rel_path: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(rel_path);
            const abs_path = try std.fs.path.join(gpa, &.{ root, rel_path });
            defer gpa.free(abs_path);
            try scanFileForSymbol(gpa, io, abs_path, rel_path, name, def, def_kind, refs, capped);
        } else if (entry.kind == .directory) {
            if (shouldSkipScanDir(entry.name)) continue;
            const sub_prefix: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(sub_prefix);
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            try walkSymbolFind(gpa, io, sub, sub_prefix, root, name, def, def_kind, refs, capped);
        }
    }
}

pub fn computeSymbolFind(gpa: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) !SymbolFindResult {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch
        return error.RootNotFound;
    defer dir.close(io);

    var def: ?SymbolRef = null;
    var def_kind: []const u8 = "unknown";
    var refs: std.ArrayList(SymbolRef) = .empty;
    errdefer {
        if (def) |d| gpa.free(d.file);
        for (refs.items) |rf| gpa.free(rf.file);
        refs.deinit(gpa);
    }
    var capped = false;

    try walkSymbolFind(gpa, io, dir, "", root, name, &def, &def_kind, &refs, &capped);

    return .{
        .symbol     = name,
        .kind       = def_kind,
        .definition = def,
        .references = try refs.toOwnedSlice(gpa),
        .capped     = capped,
    };
}

// --- secret-scan subcommand ---

const SECRET_SCAN_MAX_FINDINGS: usize = 200;
const SECRET_SCAN_MAX_FILE_BYTES: usize = 5 * 1024 * 1024;

pub const SecretFinding = struct { file: []u8, line: u32, pattern: []const u8, severity: []const u8 };
pub const SecretScanResult = struct { findings: []SecretFinding, truncated: bool };

const SecretPatternMode = enum { prefix, assignment_key };
const SecretPatternDef = struct {
    needle: []const u8,
    name: []const u8,
    severity: []const u8,
    mode: SecretPatternMode,
};

const SECRET_PATTERNS = [_]SecretPatternDef{
    // Specific token prefixes (high-confidence, case-sensitive)
    .{ .needle = "sk_live_",                             .name = "stripe-secret-key",          .severity = "high",   .mode = .prefix },
    .{ .needle = "sk_test_",                             .name = "stripe-test-key",             .severity = "medium", .mode = .prefix },
    .{ .needle = "AKIA",                                 .name = "aws-access-key-id",           .severity = "high",   .mode = .prefix },
    .{ .needle = "ghp_",                                 .name = "github-pat",                  .severity = "high",   .mode = .prefix },
    .{ .needle = "gho_",                                 .name = "github-oauth-token",          .severity = "high",   .mode = .prefix },
    .{ .needle = "ghs_",                                 .name = "github-server-token",         .severity = "high",   .mode = .prefix },
    .{ .needle = "github_pat_",                          .name = "github-fine-grained-pat",     .severity = "high",   .mode = .prefix },
    .{ .needle = "glpat-",                               .name = "gitlab-pat",                  .severity = "high",   .mode = .prefix },
    .{ .needle = "xoxb-",                                .name = "slack-bot-token",             .severity = "high",   .mode = .prefix },
    .{ .needle = "xoxp-",                                .name = "slack-user-token",            .severity = "high",   .mode = .prefix },
    .{ .needle = "-----BEGIN RSA PRIVATE KEY-----",      .name = "rsa-private-key",            .severity = "high",   .mode = .prefix },
    .{ .needle = "-----BEGIN OPENSSH PRIVATE KEY-----",  .name = "ssh-private-key",            .severity = "high",   .mode = .prefix },
    .{ .needle = "-----BEGIN EC PRIVATE KEY-----",       .name = "ec-private-key",             .severity = "high",   .mode = .prefix },
    .{ .needle = "-----BEGIN PGP PRIVATE KEY BLOCK-----",.name = "pgp-private-key",            .severity = "high",   .mode = .prefix },
    .{ .needle = "AIza",                                 .name = "google-api-key",              .severity = "high",   .mode = .prefix },
    .{ .needle = "ya29.",                                .name = "google-oauth-token",          .severity = "high",   .mode = .prefix },
    // Assignment-key patterns: needle found in variable name + real value after = or :
    .{ .needle = "password",     .name = "hardcoded-password",    .severity = "high",   .mode = .assignment_key },
    .{ .needle = "passwd",       .name = "hardcoded-password",    .severity = "high",   .mode = .assignment_key },
    .{ .needle = "api_secret",   .name = "hardcoded-api-secret",  .severity = "high",   .mode = .assignment_key },
    .{ .needle = "api_key",      .name = "hardcoded-api-key",     .severity = "medium", .mode = .assignment_key },
    .{ .needle = "apikey",       .name = "hardcoded-api-key",     .severity = "medium", .mode = .assignment_key },
    .{ .needle = "secret_key",   .name = "hardcoded-secret-key",  .severity = "medium", .mode = .assignment_key },
    .{ .needle = "secret",       .name = "hardcoded-secret",      .severity = "medium", .mode = .assignment_key },
    .{ .needle = "access_token", .name = "hardcoded-token",       .severity = "medium", .mode = .assignment_key },
    .{ .needle = "auth_token",   .name = "hardcoded-token",       .severity = "medium", .mode = .assignment_key },
    .{ .needle = "private_key",  .name = "hardcoded-private-key", .severity = "medium", .mode = .assignment_key },
};

fn secretScanIsCommentLine(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, t, "//") or
        std.mem.startsWith(u8, t, "#") or
        std.mem.startsWith(u8, t, "*") or
        std.mem.startsWith(u8, t, "--") or
        std.mem.startsWith(u8, t, "/*") or
        std.mem.startsWith(u8, t, "<!--");
}

fn secretScanIsExampleFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".example") or
        std.mem.endsWith(u8, name, ".sample") or
        std.mem.endsWith(u8, name, ".template") or
        std.mem.endsWith(u8, name, ".dist");
}

fn secretScanCaseInsensitiveContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
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

fn secretScanPrefixContinuationLen(line: []const u8, pos: usize, needle_len: usize) usize {
    var count: usize = 0;
    var i = pos + needle_len;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/' or
            c == '+' or c == '.' or c == '@' or c == '=') {
            count += 1;
        } else break;
    }
    return count;
}

fn secretScanFindAssignmentSep(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '=') {
            if (i + 1 < line.len and line[i + 1] == '=') { i += 1; continue; }
            if (i > 0 and (line[i - 1] == '!' or line[i - 1] == '<' or line[i - 1] == '>')) continue;
            return i;
        }
    }
    // YAML colon: not :: and not ://
    if (std.mem.indexOfScalar(u8, line, ':')) |cp| {
        if (cp + 1 < line.len and line[cp + 1] != ':' and line[cp + 1] != '/') return cp;
    }
    return null;
}

fn secretScanExtractValue(line: []const u8, sep_pos: usize) []const u8 {
    if (sep_pos + 1 >= line.len) return "";
    const after = std.mem.trimStart(u8, line[sep_pos + 1 ..], " \t");
    const trimmed = std.mem.trimEnd(u8, after, " \t;,\r");
    if (trimmed.len >= 2) {
        const q = trimmed[0];
        if ((q == '"' or q == '\'' or q == '`') and trimmed[trimmed.len - 1] == q)
            return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

fn secretScanIsCleanKey(key: []const u8) bool {
    for (key) |c| {
        if (c == '(' or c == ')' or c == '{' or c == '}' or c == ';') return false;
    }
    return true;
}

fn secretScanIsPlaceholder(val: []const u8) bool {
    if (val.len < 6) return true;
    if (val[0] == '{' or val[0] == '[' or val[0] == '(' or val[0] == '$' or
        val[0] == '.' or std.ascii.isDigit(val[0])) return true;
    const env_prefixes = [_][]const u8{ "os.", "ENV[", "env.", "process.", "config.", "settings.", "getenv", "std." };
    for (env_prefixes) |ep| { if (std.mem.startsWith(u8, val, ep)) return true; }
    const null_literals = [_][]const u8{ "None", "null", "undefined", "true", "false", "True", "False", "NULL", "nil" };
    for (null_literals) |nl| { if (std.mem.eql(u8, val, nl)) return true; }
    const type_decls = [_][]const u8{ "struct", "enum", "union", "fn ", "interface", "class", "impl", "type " };
    for (type_decls) |td| { if (std.mem.startsWith(u8, val, td)) return true; }
    if (val.len >= 4) {
        const first = val[0];
        var all_same = true;
        for (val) |c| { if (c != first) { all_same = false; break; } }
        if (all_same) return true;
    }
    var buf: [64]u8 = undefined;
    const check_len = @min(val.len, 64);
    for (val[0..check_len], 0..) |c, idx| buf[idx] = std.ascii.toLower(c);
    const lower = buf[0..check_len];
    const placeholder_pfx = [_][]const u8{
        "your", "my_api", "example", "placeholder", "replace", "changeme",
        "change_me", "put_", "insert_", "enter_", "add_", "dummy",
        "fake", "sample", "test_", "not_real", "xxxxxxxxx", "12345678",
    };
    for (placeholder_pfx) |ph| { if (std.mem.startsWith(u8, lower, ph)) return true; }
    return false;
}

fn scanFileForSecrets(
    gpa: std.mem.Allocator,
    io: std.Io,
    abs_path: []const u8,
    rel_path: []const u8,
    findings: *std.ArrayList(SecretFinding),
    truncated: *bool,
) !void {
    const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch return;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = r.interface.allocRemaining(gpa, .limited(SECRET_SCAN_MAX_FILE_BYTES)) catch return;
    defer gpa.free(content);
    if (content.len >= 4 and (
        std.mem.eql(u8, content[0..4], "\xcf\xfa\xed\xfe") or
        std.mem.eql(u8, content[0..4], "\xfe\xed\xfa\xcf") or
        std.mem.eql(u8, content[0..4], "\xca\xfe\xba\xbe") or
        std.mem.eql(u8, content[0..4], "\x7fELF"))) return;

    var line_num: u32 = 1;
    var line_start: usize = 0;
    var last_flagged: u32 = 0;
    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = content[line_start..line_end];
        if (line_num != last_flagged and !secretScanIsCommentLine(line)) {
            for (SECRET_PATTERNS) |pat| {
                if (findings.items.len >= SECRET_SCAN_MAX_FINDINGS) { truncated.* = true; return; }
                var matched = false;
                switch (pat.mode) {
                    .prefix => {
                        if (std.mem.indexOf(u8, line, pat.needle)) |pos| {
                            if (secretScanPrefixContinuationLen(line, pos, pat.needle.len) >= 8)
                                matched = true;
                        }
                    },
                    .assignment_key => {
                        if (secretScanFindAssignmentSep(line)) |sep_pos| {
                            const key = line[0..sep_pos];
                            if (secretScanIsCleanKey(key) and secretScanCaseInsensitiveContains(key, pat.needle)) {
                                const val = secretScanExtractValue(line, sep_pos);
                                if (!secretScanIsPlaceholder(val)) matched = true;
                            }
                        }
                    },
                }
                if (matched) {
                    try findings.append(gpa, .{
                        .file     = try gpa.dupe(u8, rel_path),
                        .line     = line_num,
                        .pattern  = pat.name,
                        .severity = pat.severity,
                    });
                    last_flagged = line_num;
                    break;
                }
            }
        }
        line_num += 1;
        line_start = line_end + 1;
    }
}

fn walkSecretScan(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    root: []const u8,
    findings: *std.ArrayList(SecretFinding),
    truncated: *bool,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (findings.items.len >= SECRET_SCAN_MAX_FINDINGS) { truncated.* = true; return; }
        if (entry.kind == .file) {
            if (shouldSkipGrepFile(entry.name)) continue;
            if (secretScanIsExampleFile(entry.name)) continue;
            const rel_path: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(rel_path);
            const abs_path = try std.fs.path.join(gpa, &.{ root, rel_path });
            defer gpa.free(abs_path);
            try scanFileForSecrets(gpa, io, abs_path, rel_path, findings, truncated);
        } else if (entry.kind == .directory) {
            if (shouldSkipScanDir(entry.name)) continue;
            const sub_prefix: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(sub_prefix);
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            try walkSecretScan(gpa, io, sub, sub_prefix, root, findings, truncated);
        }
    }
}

pub fn computeSecretScan(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !SecretScanResult {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch
        return error.RootNotFound;
    defer dir.close(io);
    var findings: std.ArrayList(SecretFinding) = .empty;
    errdefer {
        for (findings.items) |f| gpa.free(f.file);
        findings.deinit(gpa);
    }
    var truncated = false;
    try walkSecretScan(gpa, io, dir, "", root, &findings, &truncated);
    return .{ .findings = try findings.toOwnedSlice(gpa), .truncated = truncated };
}

// --- device-scan subcommand ---

pub const DeviceScanHardware = struct { cpu: []u8, cores: u32, ram_gb: u32, os: []const u8, arch: []u8 };
pub const DeviceScanOptimal = struct { zig_build_flags: []const u8 };
pub const DeviceScanTool = struct { name: []const u8, version: []u8, present: bool };
pub const DeviceScanResult = struct {
    profile_id: []u8,
    hardware: DeviceScanHardware,
    tools: []DeviceScanTool,
    optimal: DeviceScanOptimal,
    shell: []u8,
    scanned_at: u64,
    path: []u8,
};

fn runSysctlN(gpa: std.mem.Allocator, io: std.Io, key: []const u8) ![]u8 {
    const argv = [_][]const u8{ "sysctl", "-n", key };
    const result = std.process.run(gpa, io, .{ .argv = &argv }) catch
        return try gpa.dupe(u8, "");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return try gpa.dupe(u8, std.mem.trimEnd(u8, result.stdout, " \t\r\n"));
}

fn deviceScanSlugify(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = try gpa.alloc(u8, s.len);
    var out: usize = 0;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            buf[out] = std.ascii.toLower(c);
            out += 1;
        } else if (c == ' ' or c == '-' or c == '_') {
            if (out > 0 and buf[out - 1] != '_') {
                buf[out] = '_';
                out += 1;
            }
        }
    }
    // strip trailing underscore
    while (out > 0 and buf[out - 1] == '_') out -= 1;
    const result = try gpa.dupe(u8, buf[0..out]);
    gpa.free(buf);
    return result;
}

fn deviceScanZigFlags(cpu: []const u8) []const u8 {
    if (std.mem.indexOf(u8, cpu, "M1") != null) return "-Dcpu=apple_m1";
    if (std.mem.indexOf(u8, cpu, "M2") != null) return "-Dcpu=apple_m2";
    if (std.mem.indexOf(u8, cpu, "M3") != null) return "-Dcpu=apple_m3";
    if (std.mem.indexOf(u8, cpu, "M4") != null) return "-Dcpu=apple_m4";
    if (std.mem.indexOf(u8, cpu, "M5") != null) return "-Dcpu=apple_m5";
    return "-Doptimize=ReleaseSafe";
}

pub fn computeDeviceScan(gpa: std.mem.Allocator, io: std.Io) !DeviceScanResult {
    // Hardware
    const cpu_raw = try runSysctlN(gpa, io, "machdep.cpu.brand_string");
    const cores_raw = try runSysctlN(gpa, io, "hw.physicalcpu");
    const mem_raw = try runSysctlN(gpa, io, "hw.memsize");
    defer gpa.free(cpu_raw);
    defer gpa.free(cores_raw);
    defer gpa.free(mem_raw);

    const cores = std.fmt.parseInt(u32, cores_raw, 10) catch 0;
    const mem_bytes = std.fmt.parseInt(u64, mem_raw, 10) catch 0;
    const ram_gb: u32 = @intCast(mem_bytes / (1024 * 1024 * 1024));

    const arch_result = std.process.run(gpa, io, .{ .argv = &[_][]const u8{ "uname", "-m" } }) catch null;
    const arch_raw = if (arch_result) |r| blk: {
        defer gpa.free(r.stderr);
        break :blk r.stdout;
    } else try gpa.dupe(u8, "arm64");
    const arch = try gpa.dupe(u8, std.mem.trimEnd(u8, arch_raw, " \t\r\n"));
    if (arch_result != null) gpa.free(arch_raw);

    const cpu = try gpa.dupe(u8, cpu_raw);

    // Shell
    const shell_ptr = std.c.getenv("SHELL") orelse null;
    const shell_full: []u8 = if (shell_ptr) |p|
        try gpa.dupe(u8, std.mem.sliceTo(p, 0))
    else
        try gpa.dupe(u8, "unknown");
    // basename of shell path
    const shell = if (std.mem.lastIndexOfScalar(u8, shell_full, '/')) |sl|
        try gpa.dupe(u8, shell_full[sl + 1 ..])
    else
        shell_full;
    if (std.mem.lastIndexOfScalar(u8, shell_full, '/') != null) gpa.free(shell_full);

    // Tools
    const tool_specs = [_]struct { name: []const u8, flag: []const u8 }{
        .{ .name = "foreman_tools", .flag = "doctor" },
        .{ .name = "zig",           .flag = "version" },
        .{ .name = "git",           .flag = "--version" },
        .{ .name = "gh",            .flag = "--version" },
        .{ .name = "node",          .flag = "--version" },
        .{ .name = "python3",       .flag = "--version" },
        .{ .name = "brew",          .flag = "--version" },
    };
    const tool_bin_names = [_][]const u8{ "foreman-tools", "zig", "git", "gh", "node", "python3", "brew" };

    var tools_list = try gpa.alloc(DeviceScanTool, tool_specs.len);
    for (tool_specs, 0..) |spec, i| {
        const info = try checkBinary(gpa, io, tool_bin_names[i], spec.flag);
        tools_list[i] = .{ .name = spec.name, .version = info.version, .present = info.present };
    }

    // Optimal settings
    const zig_flags = deviceScanZigFlags(cpu);

    // Profile ID
    const cpu_slug = try deviceScanSlugify(gpa, cpu);
    defer gpa.free(cpu_slug);
    const profile_id = try std.fmt.allocPrint(gpa, "{s}_{d}gb_{s}", .{ cpu_slug, ram_gb, arch });

    // Timestamp (REALTIME seconds)
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const scanned_at: u64 = @intCast(ts.sec);

    // Write profile to ~/.foreman/profile.json
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const foreman_dir = try std.fmt.allocPrint(gpa, "{s}/.foreman", .{home});
    defer gpa.free(foreman_dir);
    const profile_path = try std.fmt.allocPrint(gpa, "{s}/profile.json", .{foreman_dir});
    defer gpa.free(profile_path);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{profile_path});
    defer gpa.free(tmp_path);

    std.Io.Dir.createDirAbsolute(io, foreman_dir, .default_dir) catch {};
    const pf = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch null;
    if (pf) |f| {
        var wbuf: [4096]u8 = undefined;
        var w = f.writerStreaming(io, &wbuf);
        // write JSON — best effort, ignore errors
        const ok = blk: {
            w.interface.writeAll("{\"profile_id\":\"") catch break :blk false;
            w.interface.writeAll(profile_id) catch break :blk false;
            w.interface.writeAll("\",\"hardware\":{\"cpu\":\"") catch break :blk false;
            w.interface.writeAll(cpu) catch break :blk false;
            w.interface.print("\",\"cores\":{d},\"ram_gb\":{d},\"os\":\"macos\",\"arch\":\"", .{ cores, ram_gb }) catch break :blk false;
            w.interface.writeAll(arch) catch break :blk false;
            w.interface.writeAll("\"},\"tools\":{") catch break :blk false;
            for (tools_list, 0..) |t, idx| {
                if (idx > 0) w.interface.writeAll(",") catch break :blk false;
                w.interface.print("\"{s}\":{{\"version\":\"{s}\",\"present\":{s}}}", .{
                    t.name, t.version, if (t.present) "true" else "false",
                }) catch break :blk false;
            }
            w.interface.print("}},\"optimal\":{{\"zig_build_flags\":\"{s}\"}},\"shell\":\"{s}\",\"scanned_at\":{d}}}", .{
                zig_flags, shell, scanned_at,
            }) catch break :blk false;
            w.interface.flush() catch break :blk false;
            break :blk true;
        };
        f.close(io);
        if (ok) {
            atomicRenameAbsolute(tmp_path, profile_path);
            // Pre-warm cache so `cache-fetch ~/.foreman/profile.json device` hits next session
            var tools_buf: [4096]u8 = undefined;
            var tools_len: usize = 0;
            var tools_ok = true;
            for (tools_list, 0..) |t, idx| {
                const sep: []const u8 = if (idx == 0) "" else ",";
                const part = std.fmt.bufPrint(tools_buf[tools_len..], "{s}\"{s}\":{{\"version\":\"{s}\",\"present\":{s}}}", .{
                    sep, t.name, t.version, if (t.present) "true" else "false",
                }) catch { tools_ok = false; break; };
                tools_len += part.len;
            }
            if (tools_ok) {
                const cache_json = std.fmt.allocPrint(gpa,
                    "{{\"profile_id\":\"{s}\",\"hardware\":{{\"cpu\":\"{s}\",\"cores\":{d},\"ram_gb\":{d},\"os\":\"macos\",\"arch\":\"{s}\"}},\"tools\":{{{s}}},\"optimal\":{{\"zig_build_flags\":\"{s}\"}},\"shell\":\"{s}\",\"scanned_at\":{d}}}",
                    .{ profile_id, cpu, cores, ram_gb, arch, tools_buf[0..tools_len], zig_flags, shell, scanned_at },
                ) catch null;
                if (cache_json) |cj| {
                    defer gpa.free(cj);
                    _ = computeCacheStore(gpa, io, profile_path, "device", cj) catch {};
                }
            }
        }
    }

    return .{
        .profile_id = profile_id,
        .hardware   = .{ .cpu = cpu, .cores = cores, .ram_gb = ram_gb, .os = "macos", .arch = arch },
        .tools      = tools_list,
        .optimal    = .{ .zig_build_flags = zig_flags },
        .shell      = shell,
        .scanned_at = scanned_at,
        .path       = try gpa.dupe(u8, profile_path),
    };
}

// --- delta-context subcommand ---

const DELTA_MAX_FILES: usize = 8;
const DELTA_MAX_SYMBOLS: usize = 10;
const DELTA_MAX_CALLERS: usize = 10;

pub const DeltaCaller = struct { file: []u8, line: u32 };
pub const DeltaSymbol = struct {
    name: []u8,
    kind: []const u8,
    file: []u8,
    line: u32,
    callers: []DeltaCaller,
};
pub const DeltaContextResult = struct {
    ref: []u8,
    symbols: []DeltaSymbol,
};

// Parse "@@ -old_start,old_count +new_start,new_count @@" hunk header.
// Returns {new_start, new_count} or null if not a hunk header.
fn parseHunkNewRange(line: []const u8) ?struct { start: u32, count: u32 } {
    if (!std.mem.startsWith(u8, line, "@@ ")) return null;
    // Find '+' in "... +new_start,new_count ..."
    const plus_pos = std.mem.indexOf(u8, line, " +") orelse return null;
    const rest = line[plus_pos + 2 ..];
    // Parse new_start
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {}
    const start = std.fmt.parseInt(u32, rest[0..i], 10) catch return null;
    // Parse optional ,count
    var count: u32 = 1;
    if (i < rest.len and rest[i] == ',') {
        i += 1;
        var j = i;
        while (j < rest.len and std.ascii.isDigit(rest[j])) : (j += 1) {}
        count = std.fmt.parseInt(u32, rest[i..j], 10) catch 1;
    }
    return .{ .start = start, .count = count };
}

// Run "git diff -U0 [ref] -- <rel_path>" in repo and collect changed new-file line numbers.
fn collectChangedLines(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    rel_path: []const u8,
    ref: []const u8,
    changed: *std.ArrayList(u32),
) !void {
    const argv = [_][]const u8{ "env", "-C", repo, "git", "diff", "-U0", ref, "--", rel_path };
    const result = std.process.run(gpa, io, .{ .argv = &argv }) catch return;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    var line_start: usize = 0;
    while (line_start < result.stdout.len) {
        const line_end = std.mem.indexOfScalarPos(u8, result.stdout, line_start, '\n') orelse result.stdout.len;
        const line = result.stdout[line_start..line_end];
        if (parseHunkNewRange(line)) |range| {
            var ln: u32 = range.start;
            const end_ln = range.start + range.count;
            while (ln < end_ln) : (ln += 1) {
                try changed.append(gpa, ln);
            }
        }
        line_start = line_end + 1;
    }
}

// Find which symbol a given line belongs to (symbol owns lines from its line until next symbol's line).
fn findOwningSymbol(symbols: []const Symbol, line: u32) ?usize {
    if (symbols.len == 0) return null;
    var best: ?usize = null;
    for (symbols, 0..) |sym, i| {
        if (sym.line <= line) {
            if (best == null or sym.line > symbols[best.?].line) best = i;
        }
    }
    return best;
}

pub fn computeDeltaContext(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    ref: []const u8,
) !DeltaContextResult {
    // 1. Get changed files
    const files_argv = [_][]const u8{ "env", "-C", repo, "git", "diff", "--name-only", ref };
    const files_result = std.process.run(gpa, io, .{ .argv = &files_argv }) catch
        return error.GitFailed;
    defer gpa.free(files_result.stdout);
    defer gpa.free(files_result.stderr);

    var result_symbols: std.ArrayList(DeltaSymbol) = .empty;
    errdefer {
        for (result_symbols.items) |ds| {
            gpa.free(ds.name);
            gpa.free(ds.file);
            for (ds.callers) |c| gpa.free(c.file);
            gpa.free(ds.callers);
        }
        result_symbols.deinit(gpa);
    }

    var seen_symbols = std.StringHashMap(void).init(gpa);
    defer seen_symbols.deinit();

    var file_count: usize = 0;
    var file_start: usize = 0;
    while (file_start < files_result.stdout.len and file_count < DELTA_MAX_FILES) {
        const file_end = std.mem.indexOfScalarPos(u8, files_result.stdout, file_start, '\n') orelse files_result.stdout.len;
        const rel_path = std.mem.trimEnd(u8, files_result.stdout[file_start..file_end], " \t\r");
        file_start = file_end + 1;
        if (rel_path.len == 0) continue;
        // Skip non-source files
        if (shouldSkipGrepFile(rel_path)) continue;
        file_count += 1;

        // 2. Collect changed line numbers for this file
        var changed: std.ArrayList(u32) = .empty;
        defer changed.deinit(gpa);
        try collectChangedLines(gpa, io, repo, rel_path, ref, &changed);
        if (changed.items.len == 0) continue;

        // 3. Outline the current file
        const abs_path = try std.fs.path.join(gpa, &.{ repo, rel_path });
        defer gpa.free(abs_path);
        const outline = computeOutline(gpa, io, abs_path) catch continue;
        defer {
            for (outline.symbols) |s| gpa.free(s.name);
            gpa.free(outline.symbols);
            gpa.free(outline.path);
        }
        if (outline.symbols.len == 0) continue;

        // 4. Map changed lines → owning symbols (deduplicated)
        for (changed.items) |ln| {
            if (result_symbols.items.len >= DELTA_MAX_SYMBOLS) break;
            const idx = findOwningSymbol(outline.symbols, ln) orelse continue;
            const sym = outline.symbols[idx];
            // Deduplicate by name
            const key = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ rel_path, sym.name });
            defer gpa.free(key);
            if (seen_symbols.contains(key)) continue;
            try seen_symbols.put(try gpa.dupe(u8, key), {});

            // 5. Find callers via symbol-find
            const sf = computeSymbolFind(gpa, io, repo, sym.name) catch null;
            var callers_list: []DeltaCaller = &.{};
            if (sf) |found| {
                defer {
                    if (found.definition) |d| gpa.free(d.file);
                    for (found.references) |rf| gpa.free(rf.file);
                    gpa.free(found.references);
                }
                const caller_count = @min(found.references.len, DELTA_MAX_CALLERS);
                callers_list = try gpa.alloc(DeltaCaller, caller_count);
                for (found.references[0..caller_count], 0..) |rf, ci| {
                    callers_list[ci] = .{
                        .file = try gpa.dupe(u8, rf.file),
                        .line = rf.line,
                    };
                }
            }

            try result_symbols.append(gpa, .{
                .name    = try gpa.dupe(u8, sym.name),
                .kind    = sym.kind,
                .file    = try gpa.dupe(u8, rel_path),
                .line    = sym.line,
                .callers = callers_list,
            });
        }
    }

    // Free seen_symbols keys
    var it = seen_symbols.keyIterator();
    while (it.next()) |k| gpa.free(k.*);

    return .{
        .ref     = try gpa.dupe(u8, ref),
        .symbols = try result_symbols.toOwnedSlice(gpa),
    };
}

// --- git-cache subcommand ---

pub const GitCacheCommit = struct { hash: []u8, subject: []u8, author: []u8, date: []u8 };
pub const GitCacheResult = struct {
    hit: bool,
    branch: []u8,
    head: []u8,
    dirty: bool,
    ahead: u32,
    behind: u32,
    commits: []GitCacheCommit,
};

// Parse "N\tM\n" output from git rev-list --left-right --count HEAD...@{u}
fn parseAheadBehind(raw: []const u8) struct { ahead: u32, behind: u32 } {
    const tab = std.mem.indexOfScalar(u8, raw, '\t') orelse return .{ .ahead = 0, .behind = 0 };
    const ahead = std.fmt.parseInt(u32, std.mem.trimEnd(u8, raw[0..tab], " \r\n"), 10) catch 0;
    const behind = std.fmt.parseInt(u32, std.mem.trimEnd(u8, raw[tab + 1 ..], " \r\n"), 10) catch 0;
    return .{ .ahead = ahead, .behind = behind };
}

fn gitCachePath(gpa: std.mem.Allocator, home: []const u8, repo: []const u8) ![]u8 {
    const key = sha256Hex(repo);
    return std.fmt.allocPrint(gpa, "{s}/.cache/foreman-tools/gc-{s}.json", .{ home, key });
}

pub fn computeGitCache(gpa: std.mem.Allocator, io: std.Io, repo: []const u8) !GitCacheResult {
    // Current HEAD SHA
    const head_raw = runGit(gpa, io, repo, &.{ "rev-parse", "HEAD" }) catch
        return error.NotAGitRepo;
    defer gpa.free(head_raw);
    const head_sha = std.mem.trimEnd(u8, head_raw, " \r\n");

    // Locate cache file
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);
    const cache_path = try gitCachePath(gpa, home, repo);
    defer gpa.free(cache_path);

    // Try to read the cache
    if (std.Io.Dir.openFileAbsolute(io, cache_path, .{})) |cf| {
        var rbuf: [4096]u8 = undefined;
        var reader = cf.reader(io, &rbuf);
        const content = reader.interface.allocRemaining(gpa, .limited(512 * 1024)) catch blk: {
            cf.close(io);
            break :blk null;
        };
        cf.close(io);
        if (content) |c| {
            defer gpa.free(c);
            // First line is the stored HEAD SHA
            if (std.mem.indexOfScalar(u8, c, '\n')) |nl| {
                const stored_head = c[0..nl];
                if (std.mem.eql(u8, stored_head, head_sha)) {
                    // Parse the stored JSON
                    const json = c[nl + 1 ..];
                    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch null;
                    if (parsed) |pv| {
                        defer pv.deinit();
                        if (pv.value == .object) {
                            const obj = pv.value.object;
                            const branch_v = obj.get("branch") orelse std.json.Value{ .string = "" };
                            const dirty_v  = obj.get("dirty")  orelse std.json.Value{ .bool = false };
                            const ahead_v  = obj.get("ahead")  orelse std.json.Value{ .integer = 0 };
                            const behind_v = obj.get("behind") orelse std.json.Value{ .integer = 0 };
                            const branch_s = if (branch_v == .string) branch_v.string else "";
                            const dirty_b  = if (dirty_v  == .bool)   dirty_v.bool   else false;
                            const ahead_n: u32  = if (ahead_v  == .integer) @intCast(@max(0, ahead_v.integer))  else 0;
                            const behind_n: u32 = if (behind_v == .integer) @intCast(@max(0, behind_v.integer)) else 0;
                            // Parse commits array
                            var cached_commits: std.ArrayList(GitCacheCommit) = .empty;
                            errdefer {
                                for (cached_commits.items) |cc| {
                                    gpa.free(cc.hash); gpa.free(cc.subject);
                                    gpa.free(cc.author); gpa.free(cc.date);
                                }
                                cached_commits.deinit(gpa);
                            }
                            if (obj.get("commits")) |commits_v| {
                                if (commits_v == .array) {
                                    for (commits_v.array.items) |entry| {
                                        if (entry != .object) continue;
                                        const eo = entry.object;
                                        const h = if (eo.get("hash"))    |v| if (v == .string) v.string else "" else "";
                                        const s = if (eo.get("subject")) |v| if (v == .string) v.string else "" else "";
                                        const a = if (eo.get("author"))  |v| if (v == .string) v.string else "" else "";
                                        const d = if (eo.get("date"))    |v| if (v == .string) v.string else "" else "";
                                        try cached_commits.append(gpa, .{
                                            .hash    = try gpa.dupe(u8, h),
                                            .subject = try gpa.dupe(u8, s),
                                            .author  = try gpa.dupe(u8, a),
                                            .date    = try gpa.dupe(u8, d),
                                        });
                                    }
                                }
                            }
                            return .{
                                .hit     = true,
                                .branch  = try gpa.dupe(u8, branch_s),
                                .head    = try gpa.dupe(u8, head_sha),
                                .dirty   = dirty_b,
                                .ahead   = ahead_n,
                                .behind  = behind_n,
                                .commits = try cached_commits.toOwnedSlice(gpa),
                            };
                        }
                    }
                }
            }
        }
    } else |_| {}

    // Cache miss — run git commands
    const branch_raw = runGit(gpa, io, repo, &.{ "rev-parse", "--abbrev-ref", "HEAD" }) catch
        try gpa.dupe(u8, "HEAD\n");
    defer gpa.free(branch_raw);
    const branch = try gpa.dupe(u8, std.mem.trimEnd(u8, branch_raw, " \r\n"));

    const status_raw = runGit(gpa, io, repo, &.{ "status", "--porcelain" }) catch
        try gpa.dupe(u8, "");
    defer gpa.free(status_raw);
    const dirty = std.mem.trimEnd(u8, status_raw, " \r\n").len > 0;

    var ahead: u32 = 0;
    var behind: u32 = 0;
    if (runGit(gpa, io, repo, &.{ "rev-list", "--left-right", "--count", "HEAD...@{u}" })) |ab_raw| {
        defer gpa.free(ab_raw);
        const ab = parseAheadBehind(ab_raw);
        ahead = ab.ahead;
        behind = ab.behind;
    } else |_| {}

    // Recent commits: hash\tsubject\tauthor\tdate
    const log_raw = runGit(gpa, io, repo, &.{
        "log", "-n", "10", "--format=%H\t%s\t%an\t%ad", "--date=short",
    }) catch try gpa.dupe(u8, "");
    defer gpa.free(log_raw);

    var commits: std.ArrayList(GitCacheCommit) = .empty;
    errdefer {
        for (commits.items) |c| {
            gpa.free(c.hash);
            gpa.free(c.subject);
            gpa.free(c.author);
            gpa.free(c.date);
        }
        commits.deinit(gpa);
    }

    var log_line_start: usize = 0;
    while (log_line_start < log_raw.len) {
        const log_line_end = std.mem.indexOfScalarPos(u8, log_raw, log_line_start, '\n') orelse log_raw.len;
        const log_line = log_raw[log_line_start..log_line_end];
        log_line_start = log_line_end + 1;
        if (log_line.len == 0) continue;
        // Split on tabs
        var fields: [4][]const u8 = .{ "", "", "", "" };
        var fi: usize = 0;
        var fs: usize = 0;
        for (log_line, 0..) |ch, ci| {
            if (ch == '\t' and fi < 3) {
                fields[fi] = log_line[fs..ci];
                fi += 1;
                fs = ci + 1;
            }
        }
        fields[fi] = log_line[fs..];
        try commits.append(gpa, .{
            .hash    = try gpa.dupe(u8, fields[0]),
            .subject = try gpa.dupe(u8, fields[1]),
            .author  = try gpa.dupe(u8, fields[2]),
            .date    = try gpa.dupe(u8, fields[3]),
        });
    }

    // Write cache — serialize to JSON first, then write atomically
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}/.cache/foreman-tools", .{home});
    defer gpa.free(cache_dir);
    std.Io.Dir.createDirAbsolute(io, cache_dir, .default_dir) catch {};
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{cache_path});
    defer gpa.free(tmp_path);

    if (std.Io.Dir.createFileAbsolute(io, tmp_path, .{})) |wf| {
        var wbuf: [4096]u8 = undefined;
        var w = wf.writerStreaming(io, &wbuf);
        const write_ok = blk: {
            // First line: head SHA for invalidation
            w.interface.writeAll(head_sha) catch break :blk false;
            w.interface.writeAll("\n") catch break :blk false;
            // JSON state (no hit field in stored form)
            w.interface.print("{{\"branch\":\"{s}\",\"head\":\"{s}\",\"dirty\":{s},\"ahead\":{d},\"behind\":{d},\"commits\":[",
                .{ branch, head_sha, if (dirty) "true" else "false", ahead, behind }) catch break :blk false;
            for (commits.items, 0..) |cm, ci| {
                if (ci > 0) w.interface.writeAll(",") catch break :blk false;
                w.interface.print("{{\"hash\":\"{s}\",\"subject\":\"{s}\",\"author\":\"{s}\",\"date\":\"{s}\"}}",
                    .{ cm.hash, cm.subject, cm.author, cm.date }) catch break :blk false;
            }
            w.interface.writeAll("]}") catch break :blk false;
            w.interface.flush() catch break :blk false;
            break :blk true;
        };
        wf.close(io);
        if (write_ok) atomicRenameAbsolute(tmp_path, cache_path);
    } else |_| {}

    return .{
        .hit     = false,
        .branch  = branch,
        .head    = try gpa.dupe(u8, head_sha),
        .dirty   = dirty,
        .ahead   = ahead,
        .behind  = behind,
        .commits = try commits.toOwnedSlice(gpa),
    };
}

// --- prod-ready ---

pub const ProdReadyItem = struct {
    source:  []const u8,
    message: []const u8,
};

pub const ProdReadyResult = struct {
    ready:    bool,
    blockers: []ProdReadyItem,
    warnings: []ProdReadyItem,
};

pub fn computeProdReady(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ProdReadyResult {
    var blockers: std.ArrayList(ProdReadyItem) = .empty;
    var warnings: std.ArrayList(ProdReadyItem) = .empty;

    // 1. Quality gate (build + tests)
    const qg_opt: ?QualityGateResult = blk: {
        const r = computeQualityGate(gpa, io, path) catch |e| switch (e) {
            else => {
                warnings.append(gpa, .{
                    .source  = "quality-gate",
                    .message = "could not run quality gate",
                }) catch {};
                break :blk null;
            },
        };
        break :blk r;
    };
    if (qg_opt) |qg| {
        if (qg.critical.len > 0) {
            try blockers.append(gpa, .{
                .source  = "quality-gate",
                .message = try std.fmt.allocPrint(gpa, "{d} critical issue(s): build or test runner crashed", .{qg.critical.len}),
            });
        }
        if (qg.high.len > 0) {
            var build_errors: usize = 0;
            var test_fails:   usize = 0;
            for (qg.high) |f| {
                if (std.mem.eql(u8, f.source, "build")) build_errors += 1
                else test_fails += 1;
            }
            try blockers.append(gpa, .{
                .source  = "quality-gate",
                .message = try std.fmt.allocPrint(gpa, "{d} build error(s), {d} test failure(s)", .{ build_errors, test_fails }),
            });
        }
        if (qg.medium.len > 0) {
            try warnings.append(gpa, .{
                .source  = "quality-gate",
                .message = try std.fmt.allocPrint(gpa, "{d} build warning(s)", .{qg.medium.len}),
            });
        }
        if (!qg.build_ran) {
            try warnings.append(gpa, .{
                .source  = "quality-gate",
                .message = "no build system detected — build not verified",
            });
        }
        if (!qg.tests_ran) {
            try warnings.append(gpa, .{
                .source  = "quality-gate",
                .message = "no test framework detected — tests not verified",
            });
        }
    }

    // 2. Secret scan
    const ss_opt: ?SecretScanResult = blk: {
        const r = computeSecretScan(gpa, io, path) catch |e| switch (e) {
            else => {
                warnings.append(gpa, .{
                    .source  = "secret-scan",
                    .message = "could not run secret scan",
                }) catch {};
                break :blk null;
            },
        };
        break :blk r;
    };
    if (ss_opt) |ss| {
        if (ss.findings.len > 0) {
            try blockers.append(gpa, .{
                .source  = "secret-scan",
                .message = try std.fmt.allocPrint(gpa, "{d} hardcoded secret(s) found", .{ss.findings.len}),
            });
        }
        if (ss.truncated) {
            try warnings.append(gpa, .{
                .source  = "secret-scan",
                .message = "scan truncated at 200 findings — more may exist",
            });
        }
    }

    // 3. Missing runtime deps
    const ei_opt: ?EnvInspectResult = blk: {
        const r = computeEnvInspect(gpa, io, path) catch {
            break :blk null;
        };
        break :blk r;
    };
    if (ei_opt) |ei| {
        for (ei.missing) |dep| {
            try warnings.append(gpa, .{
                .source  = "env-inspect",
                .message = try std.fmt.allocPrint(gpa, "missing: {s}", .{dep}),
            });
        }
    }

    return .{
        .ready    = blockers.items.len == 0,
        .blockers = try blockers.toOwnedSlice(gpa),
        .warnings = try warnings.toOwnedSlice(gpa),
    };
}

// --- validate-schema ---

const VALIDATE_MAX_VIOLATIONS: usize = 50;
const VALIDATE_MAX_DEPTH: u32 = 6;

pub const SchemaViolation = struct {
    path:     []const u8,
    expected: []const u8,
    got:      []const u8,
};

pub const ValidateSchemaResult = struct {
    valid:      bool,
    violations: []SchemaViolation,
    file:       []const u8,
    schema:     []const u8,
};

fn jsonMatchesType(v: std.json.Value, t: []const u8) bool {
    return switch (v) {
        .null          => std.mem.eql(u8, t, "null"),
        .bool          => std.mem.eql(u8, t, "boolean") or std.mem.eql(u8, t, "bool"),
        .integer       => std.mem.eql(u8, t, "integer") or std.mem.eql(u8, t, "number"),
        .float, .number_string => std.mem.eql(u8, t, "number"),
        .string        => std.mem.eql(u8, t, "string"),
        .array         => std.mem.eql(u8, t, "array"),
        .object        => std.mem.eql(u8, t, "object"),
    };
}

fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null          => b == .null,
        .bool          => |av| switch (b) { .bool => |bv| av == bv, else => false },
        .integer       => |av| switch (b) { .integer => |bv| av == bv, else => false },
        .float         => |av| switch (b) { .float => |bv| av == bv, else => false },
        .number_string => |av| switch (b) { .number_string => |bv| std.mem.eql(u8, av, bv), else => false },
        .string        => |av| switch (b) { .string => |bv| std.mem.eql(u8, av, bv), else => false },
        else           => false,
    };
}

fn validateValue(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList(SchemaViolation),
    data: std.json.Value,
    schema: std.json.Value,
    path: []const u8,
    depth: u32,
) !void {
    if (violations.items.len >= VALIDATE_MAX_VIOLATIONS) return;
    if (depth >= VALIDATE_MAX_DEPTH) return;
    if (schema != .object) return;
    const sch = schema.object;

    // Type check
    if (sch.get("type")) |type_node| {
        if (type_node == .string) {
            if (!jsonMatchesType(data, type_node.string)) {
                try violations.append(gpa, .{
                    .path     = try gpa.dupe(u8, path),
                    .expected = try gpa.dupe(u8, type_node.string),
                    .got      = jsonTypeName(data),
                });
                return; // type mismatch — skip further checks
            }
        }
    }

    // Enum check
    if (sch.get("enum")) |enum_node| {
        if (enum_node == .array) {
            var found = false;
            for (enum_node.array.items) |item| {
                if (jsonValuesEqual(data, item)) { found = true; break; }
            }
            if (!found) {
                try violations.append(gpa, .{
                    .path     = try gpa.dupe(u8, path),
                    .expected = "one of enum values",
                    .got      = jsonTypeName(data),
                });
            }
        }
    }

    // String constraints
    if (data == .string) {
        if (sch.get("minLength")) |ml| {
            if (ml == .integer) min_len: {
                const min: usize = @intCast(@max(0, ml.integer));
                if (data.string.len < min) {
                    try violations.append(gpa, .{
                        .path     = try gpa.dupe(u8, path),
                        .expected = try std.fmt.allocPrint(gpa, "minLength {d}", .{min}),
                        .got      = try std.fmt.allocPrint(gpa, "length {d}", .{data.string.len}),
                    });
                }
                break :min_len;
            }
        }
        if (sch.get("maxLength")) |ml| {
            if (ml == .integer) max_len: {
                const max: usize = @intCast(@max(0, ml.integer));
                if (data.string.len > max) {
                    try violations.append(gpa, .{
                        .path     = try gpa.dupe(u8, path),
                        .expected = try std.fmt.allocPrint(gpa, "maxLength {d}", .{max}),
                        .got      = try std.fmt.allocPrint(gpa, "length {d}", .{data.string.len}),
                    });
                }
                break :max_len;
            }
        }
    }

    // Number constraints
    if (data == .integer or data == .float) {
        const val: f64 = switch (data) {
            .integer => |n| @as(f64, @floatFromInt(n)),
            .float   => |f| f,
            else     => unreachable,
        };
        if (sch.get("minimum")) |mn| min_num: {
            const min: f64 = switch (mn) {
                .integer => |n| @as(f64, @floatFromInt(n)),
                .float   => |f| f,
                else     => break :min_num,
            };
            if (val < min) {
                try violations.append(gpa, .{
                    .path     = try gpa.dupe(u8, path),
                    .expected = try std.fmt.allocPrint(gpa, ">= {d}", .{min}),
                    .got      = try std.fmt.allocPrint(gpa, "{d}", .{val}),
                });
            }
        }
        if (sch.get("maximum")) |mx| max_num: {
            const max: f64 = switch (mx) {
                .integer => |n| @as(f64, @floatFromInt(n)),
                .float   => |f| f,
                else     => break :max_num,
            };
            if (val > max) {
                try violations.append(gpa, .{
                    .path     = try gpa.dupe(u8, path),
                    .expected = try std.fmt.allocPrint(gpa, "<= {d}", .{max}),
                    .got      = try std.fmt.allocPrint(gpa, "{d}", .{val}),
                });
            }
        }
    }

    // Object: required + properties + additionalProperties
    if (data == .object) {
        if (sch.get("required")) |req_node| {
            if (req_node == .array) {
                for (req_node.array.items) |req| {
                    if (violations.items.len >= VALIDATE_MAX_VIOLATIONS) break;
                    if (req != .string) continue;
                    if (data.object.get(req.string) == null) {
                        const vpath = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ path, req.string });
                        try violations.append(gpa, .{
                            .path     = vpath,
                            .expected = "present",
                            .got      = "missing",
                        });
                    }
                }
            }
        }
        if (sch.get("properties")) |props_node| {
            if (props_node == .object) {
                var it = props_node.object.iterator();
                while (it.next()) |entry| {
                    if (violations.items.len >= VALIDATE_MAX_VIOLATIONS) break;
                    const key = entry.key_ptr.*;
                    const prop_schema = entry.value_ptr.*;
                    if (data.object.get(key)) |prop_data| {
                        const vpath = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ path, key });
                        defer gpa.free(vpath);
                        try validateValue(gpa, violations, prop_data, prop_schema, vpath, depth + 1);
                    }
                }
            }
        }
        if (sch.get("additionalProperties")) |ap| {
            if (ap == .bool and !ap.bool) {
                if (sch.get("properties")) |props_node| {
                    if (props_node == .object) {
                        var it = data.object.iterator();
                        while (it.next()) |entry| {
                            if (violations.items.len >= VALIDATE_MAX_VIOLATIONS) break;
                            const key = entry.key_ptr.*;
                            if (props_node.object.get(key) == null) {
                                const vpath = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ path, key });
                                try violations.append(gpa, .{
                                    .path     = vpath,
                                    .expected = "not present",
                                    .got      = "unexpected key",
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    // Array: minItems + maxItems + items
    if (data == .array) {
        if (sch.get("minItems")) |mi| {
            if (mi == .integer) min_items: {
                const min: usize = @intCast(@max(0, mi.integer));
                if (data.array.items.len < min) {
                    try violations.append(gpa, .{
                        .path     = try gpa.dupe(u8, path),
                        .expected = try std.fmt.allocPrint(gpa, "minItems {d}", .{min}),
                        .got      = try std.fmt.allocPrint(gpa, "{d} items", .{data.array.items.len}),
                    });
                }
                break :min_items;
            }
        }
        if (sch.get("maxItems")) |mi| {
            if (mi == .integer) max_items: {
                const max: usize = @intCast(@max(0, mi.integer));
                if (data.array.items.len > max) {
                    try violations.append(gpa, .{
                        .path     = try gpa.dupe(u8, path),
                        .expected = try std.fmt.allocPrint(gpa, "maxItems {d}", .{max}),
                        .got      = try std.fmt.allocPrint(gpa, "{d} items", .{data.array.items.len}),
                    });
                }
                break :max_items;
            }
        }
        if (sch.get("items")) |items_schema| {
            for (data.array.items, 0..) |item, idx| {
                if (violations.items.len >= VALIDATE_MAX_VIOLATIONS) break;
                const vpath = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ path, idx });
                defer gpa.free(vpath);
                try validateValue(gpa, violations, item, items_schema, vpath, depth + 1);
            }
        }
    }
}

pub fn computeValidateSchema(
    gpa: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    schema_path: []const u8,
) !ValidateSchemaResult {
    const data_file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch return error.FileNotFound;
    defer data_file.close(io);
    var rbuf1: [4096]u8 = undefined;
    var r1 = data_file.reader(io, &rbuf1);
    const data_content = try r1.interface.allocRemaining(gpa, .limited(10 * 1024 * 1024));
    defer gpa.free(data_content);

    const schema_file = std.Io.Dir.openFileAbsolute(io, schema_path, .{}) catch return error.SchemaNotFound;
    defer schema_file.close(io);
    var rbuf2: [4096]u8 = undefined;
    var r2 = schema_file.reader(io, &rbuf2);
    const schema_content = try r2.interface.allocRemaining(gpa, .limited(1 * 1024 * 1024));
    defer gpa.free(schema_content);

    const data_parsed   = std.json.parseFromSlice(std.json.Value, gpa, data_content,   .{}) catch return error.InvalidJson;
    defer data_parsed.deinit();
    const schema_parsed = std.json.parseFromSlice(std.json.Value, gpa, schema_content, .{}) catch return error.InvalidSchema;
    defer schema_parsed.deinit();

    var violations: std.ArrayList(SchemaViolation) = .empty;
    try validateValue(gpa, &violations, data_parsed.value, schema_parsed.value, "$", 0);

    return .{
        .valid      = violations.items.len == 0,
        .violations = try violations.toOwnedSlice(gpa),
        .file       = file_path,
        .schema     = schema_path,
    };
}

// --- quality-gate ---

const QUALITY_GATE_MAX_PER_LEVEL: usize = 50;

pub const QualityFinding = struct {
    source:  []const u8,
    file:    []const u8,
    line:    u32,
    message: []const u8,
};

pub const QualityGateResult = struct {
    verdict:      []const u8, // "pass" or "fail"
    critical:     []QualityFinding,
    high:         []QualityFinding,
    medium:       []QualityFinding,
    low:          []QualityFinding,
    build_ran:    bool,
    build_tool:   []const u8,
    tests_ran:    bool,
    test_fw:      []const u8,
    tests_passed: u32,
    tests_failed: u32,
};

pub fn computeQualityGate(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !QualityGateResult {
    var critical: std.ArrayList(QualityFinding) = .empty;
    var high:     std.ArrayList(QualityFinding) = .empty;
    var medium:   std.ArrayList(QualityFinding) = .empty;
    var low:      std.ArrayList(QualityFinding) = .empty;

    var build_ran  = false;
    var build_tool: []const u8 = "";
    var tests_ran  = false;
    var test_fw:    []const u8 = "";
    var tests_passed: u32 = 0;
    var tests_failed: u32 = 0;

    // Build phase
    const build_opt: ?BuildResult = blk: {
        const r = computeBuild(gpa, io, path) catch |e| switch (e) {
            error.NoBuildSystem => break :blk null,
            else => return e,
        };
        break :blk r;
    };
    if (build_opt) |br| {
        build_ran  = true;
        build_tool = br.tool;
        if (!br.success) {
            if (br.errors.len > 0) {
                for (br.errors) |berr| {
                    if (high.items.len >= QUALITY_GATE_MAX_PER_LEVEL) break;
                    try high.append(gpa, .{
                        .source  = "build",
                        .file    = berr.file,
                        .line    = berr.line,
                        .message = berr.message,
                    });
                }
            } else {
                try critical.append(gpa, .{
                    .source  = "build",
                    .file    = "",
                    .line    = 0,
                    .message = try std.fmt.allocPrint(gpa, "build failed: {s} exited non-zero", .{br.tool}),
                });
            }
        }
        for (br.warnings) |bw| {
            if (medium.items.len >= QUALITY_GATE_MAX_PER_LEVEL) break;
            try medium.append(gpa, .{
                .source  = "build",
                .file    = bw.file,
                .line    = bw.line,
                .message = bw.message,
            });
        }
    }

    // Test phase
    const tests_opt: ?RunTestsResult = blk: {
        const r = computeRunTests(gpa, io, path) catch |e| switch (e) {
            error.NoTestFramework => break :blk null,
            else => return e,
        };
        break :blk r;
    };
    if (tests_opt) |tr| {
        tests_ran    = true;
        test_fw      = tr.framework;
        tests_passed = tr.passed;
        tests_failed = tr.failed;
        if (!tr.success and tr.failures.len == 0 and tr.failed == 0) {
            try critical.append(gpa, .{
                .source  = "tests",
                .file    = "",
                .line    = 0,
                .message = try std.fmt.allocPrint(gpa, "test runner crashed: {s}", .{tr.framework}),
            });
        } else {
            for (tr.failures) |tf| {
                if (high.items.len >= QUALITY_GATE_MAX_PER_LEVEL) break;
                try high.append(gpa, .{
                    .source  = "tests",
                    .file    = tf.file,
                    .line    = tf.line,
                    .message = tf.message,
                });
            }
        }
    }

    const verdict: []const u8 = if (critical.items.len > 0 or high.items.len > 0) "fail" else "pass";

    return .{
        .verdict      = verdict,
        .critical     = try critical.toOwnedSlice(gpa),
        .high         = try high.toOwnedSlice(gpa),
        .medium       = try medium.toOwnedSlice(gpa),
        .low          = try low.toOwnedSlice(gpa),
        .build_ran    = build_ran,
        .build_tool   = build_tool,
        .tests_ran    = tests_ran,
        .test_fw      = test_fw,
        .tests_passed = tests_passed,
        .tests_failed = tests_failed,
    };
}

// --- shell-run ---

pub const SHELL_RUN_DISPLAY_MAX: usize = 128 * 1024;

pub const ShellRunResult = struct {
    command:          []const u8, // not owned
    exit_code:        i32,
    stdout:           []u8,       // owned by gpa
    stderr:           []u8,       // owned by gpa
    duration_ms:      u64,
    timed_out:        bool,
    blocked:          bool,
    block_reason:     []const u8, // string literal, not owned
};

fn shellRunRmRfDanger(lower: []const u8) bool {
    const pats = [_][]const u8{ "rm -rf /", "rm -rf ~/", "rm -rf ~" };
    for (pats) |pat| {
        var i: usize = 0;
        while (std.mem.indexOf(u8, lower[i..], pat)) |rel| {
            const pos = i + rel;
            const after = pos + pat.len;
            if (after >= lower.len) return true;
            const c = lower[after];
            if (c == ' ' or c == '\t' or c == '\n' or c == ';' or
                c == '&' or c == '|' or c == '*' or c == '/') return true;
            i = pos + 1;
        }
    }
    return false;
}

fn shellRunBlockReason(lower: []const u8) ?[]const u8 {
    if (shellRunRmRfDanger(lower)) return "rm -rf on root or home";
    if (std.mem.indexOf(u8, lower, "mkfs") != null) return "filesystem format (mkfs)";
    if (std.mem.indexOf(u8, lower, "dd ") != null and
        std.mem.indexOf(u8, lower, "of=/dev/") != null) return "raw disk write (dd of=/dev/)";
    if (std.mem.indexOf(u8, lower, "drop table") != null) return "SQL drop table";
    if (std.mem.indexOf(u8, lower, "drop database") != null) return "SQL drop database";
    if (std.mem.indexOf(u8, lower, "truncate table") != null) return "SQL truncate table";
    return null;
}

pub fn computeShellRun(gpa: std.mem.Allocator, io: std.Io, command: []const u8, timeout_ms: u64) !ShellRunResult {
    // Destructive pattern check (case-insensitive, first 4KB)
    var lower_buf: [4096]u8 = undefined;
    const check_len = @min(command.len, lower_buf.len);
    _ = std.ascii.lowerString(lower_buf[0..check_len], command[0..check_len]);
    if (shellRunBlockReason(lower_buf[0..check_len])) |reason| {
        return .{
            .command      = command,
            .exit_code    = -1,
            .stdout       = try gpa.dupe(u8, ""),
            .stderr       = try gpa.dupe(u8, ""),
            .duration_ms  = 0,
            .timed_out    = false,
            .blocked      = true,
            .block_reason = reason,
        };
    }

    var ts_start: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_start);

    const r = std.process.run(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", command } }) catch |e| return e;
    errdefer gpa.free(r.stdout);
    errdefer gpa.free(r.stderr);

    var ts_end: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_end);
    const duration_ms: u64 = blk: {
        const s0 = @as(u64, @intCast(ts_start.sec)) * 1000 + @as(u64, @intCast(ts_start.nsec)) / 1_000_000;
        const s1 = @as(u64, @intCast(ts_end.sec))   * 1000 + @as(u64, @intCast(ts_end.nsec))   / 1_000_000;
        break :blk if (s1 > s0) s1 - s0 else 0;
    };

    const exit_code: i32 = switch (r.term) {
        .exited => |c| @as(i32, @intCast(c)),
        else    => -1,
    };

    return .{
        .command      = command,
        .exit_code    = exit_code,
        .stdout       = r.stdout,
        .stderr       = r.stderr,
        .duration_ms  = duration_ms,
        .timed_out    = duration_ms >= timeout_ms,
        .blocked      = false,
        .block_reason = "",
    };
}

// --- project-state ---

const PROJECT_STATE_MAX_DECISIONS: usize = 100;
const PROJECT_STATE_MAX_PATTERNS: usize = 50;

pub const ProjectStateDecision = struct {
    date: []u8,
    what: []u8,
    why: []u8,
};

pub const ProjectStateResult = struct {
    path: []u8,
    decisions: []ProjectStateDecision,
    known_patterns: [][]u8,
};

pub const ProjectStateMode = union(enum) {
    read,
    record_decision: struct { what: []const u8, why: []const u8 },
    record_pattern: []const u8,
};

fn projectStatePath(gpa: std.mem.Allocator, home: []const u8, project_path: []const u8) ![]u8 {
    const key = sha256Hex(project_path);
    return std.fmt.allocPrint(gpa, "{s}/.foreman/state/ps-{s}.json", .{ home, key });
}

fn tsToDateStr(gpa: std.mem.Allocator, ts_secs: u64) ![]u8 {
    var d: u64 = ts_secs / 86400;
    var y: u64 = 1970;
    while (true) {
        const leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
        const days_in_year: u64 = if (leap) 366 else 365;
        if (d < days_in_year) break;
        d -= days_in_year;
        y += 1;
    }
    const leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
    const month_days = [12]u64{ 31, if (leap) @as(u64, 29) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u64 = 1;
    for (month_days) |md| {
        if (d < md) break;
        d -= md;
        m += 1;
    }
    d += 1;
    return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, m, d });
}

fn parseProjectStateFile(gpa: std.mem.Allocator, io: std.Io, state_path: []const u8, decisions: *std.ArrayList(ProjectStateDecision), patterns: *std.ArrayList([]u8)) void {
    const file = std.Io.Dir.openFileAbsolute(io, state_path, .{}) catch return;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var r = file.reader(io, &read_buf);
    const content = r.interface.allocRemaining(gpa, .limited(1 * 1024 * 1024)) catch return;
    defer gpa.free(content);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;

    // Parse decisions
    if (obj.get("decisions")) |dv| {
        if (dv == .array) {
            for (dv.array.items) |item| {
                if (item != .object) continue;
                const d = item.object;
                const date_v = d.get("date") orelse continue;
                const what_v = d.get("what") orelse continue;
                const why_v  = d.get("why")  orelse continue;
                if (date_v != .string or what_v != .string or why_v != .string) continue;
                const dec = ProjectStateDecision{
                    .date = gpa.dupe(u8, date_v.string) catch continue,
                    .what = gpa.dupe(u8, what_v.string) catch continue,
                    .why  = gpa.dupe(u8, why_v.string)  catch continue,
                };
                decisions.append(gpa, dec) catch continue;
                if (decisions.items.len >= PROJECT_STATE_MAX_DECISIONS) break;
            }
        }
    }

    // Parse knownPatterns
    if (obj.get("knownPatterns")) |pv| {
        if (pv == .array) {
            for (pv.array.items) |item| {
                if (item != .string) continue;
                const pat = gpa.dupe(u8, item.string) catch continue;
                patterns.append(gpa, pat) catch continue;
                if (patterns.items.len >= PROJECT_STATE_MAX_PATTERNS) break;
            }
        }
    }
}

fn writeProjectStateFile(gpa: std.mem.Allocator, io: std.Io, state_path: []const u8, decisions: []const ProjectStateDecision, patterns: []const []u8) void {
    const tmp_path = std.fmt.allocPrint(gpa, "{s}.tmp", .{state_path}) catch return;
    defer gpa.free(tmp_path);
    const f = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch return;
    var wbuf: [4096]u8 = undefined;
    var w = f.writerStreaming(io, &wbuf);
    const ok = blk: {
        w.interface.writeAll("{\"decisions\":[") catch break :blk false;
        for (decisions, 0..) |dec, i| {
            if (i > 0) w.interface.writeAll(",") catch break :blk false;
            const date_esc = allocJsonEscape(gpa, dec.date) catch break :blk false;
            defer gpa.free(date_esc);
            const what_esc = allocJsonEscape(gpa, dec.what) catch break :blk false;
            defer gpa.free(what_esc);
            const why_esc = allocJsonEscape(gpa, dec.why) catch break :blk false;
            defer gpa.free(why_esc);
            w.interface.print("{{\"date\":\"{s}\",\"what\":\"{s}\",\"why\":\"{s}\"}}", .{
                date_esc, what_esc, why_esc,
            }) catch break :blk false;
        }
        w.interface.writeAll("],\"knownPatterns\":[") catch break :blk false;
        for (patterns, 0..) |pat, i| {
            if (i > 0) w.interface.writeAll(",") catch break :blk false;
            const pat_esc = allocJsonEscape(gpa, pat) catch break :blk false;
            defer gpa.free(pat_esc);
            w.interface.print("\"{s}\"", .{pat_esc}) catch break :blk false;
        }
        w.interface.writeAll("]}\n") catch break :blk false;
        w.interface.flush() catch break :blk false;
        break :blk true;
    };
    f.close(io);
    if (ok) atomicRenameAbsolute(tmp_path, state_path);
}

pub fn computeProjectState(gpa: std.mem.Allocator, io: std.Io, project_path: []const u8, mode: ProjectStateMode) !ProjectStateResult {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.sliceTo(home_ptr, 0);

    // Ensure state directory exists
    const state_dir = try std.fmt.allocPrint(gpa, "{s}/.foreman/state", .{home});
    defer gpa.free(state_dir);
    const foreman_dir = try std.fmt.allocPrint(gpa, "{s}/.foreman", .{home});
    defer gpa.free(foreman_dir);
    std.Io.Dir.createDirAbsolute(io, foreman_dir, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(io, state_dir, .default_dir) catch {};

    const state_path = try projectStatePath(gpa, home, project_path);
    defer gpa.free(state_path);

    var decisions: std.ArrayList(ProjectStateDecision) = .empty;
    var patterns: std.ArrayList([]u8) = .empty;

    parseProjectStateFile(gpa, io, state_path, &decisions, &patterns);

    var dirty = false;

    switch (mode) {
        .read => {},
        .record_decision => |rec| {
            if (decisions.items.len < PROJECT_STATE_MAX_DECISIONS) {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                const date_str = try tsToDateStr(gpa, @intCast(ts.sec));
                const dec = ProjectStateDecision{
                    .date = date_str,
                    .what = try gpa.dupe(u8, rec.what),
                    .why  = try gpa.dupe(u8, rec.why),
                };
                try decisions.append(gpa, dec);
                dirty = true;
            }
        },
        .record_pattern => |pat| {
            if (patterns.items.len < PROJECT_STATE_MAX_PATTERNS) {
                const dup = try gpa.dupe(u8, pat);
                try patterns.append(gpa, dup);
                dirty = true;
            }
        },
    }

    if (dirty) {
        writeProjectStateFile(gpa, io, state_path, decisions.items, patterns.items);
    }

    return .{
        .path         = try gpa.dupe(u8, project_path),
        .decisions    = try decisions.toOwnedSlice(gpa),
        .known_patterns = try patterns.toOwnedSlice(gpa),
    };
}

// --- registry ---

pub const RegistrySubcommand = struct {
    name: []const u8,
    description: []const u8,
    args: []const u8,
};

pub const RegistryResult = struct {
    version: []const u8,
    subcommands: []const RegistrySubcommand,
};

pub fn computeRegistry() RegistryResult {
    const cmds: []const RegistrySubcommand = &[_]RegistrySubcommand{
        .{ .name = "doctor",          .description = "session deps (claude/git/gh present + versions)",                    .args = ""                                   },
        .{ .name = "compat-check",    .description = "tool version drift vs baseline; surfaces rollback advice",           .args = "[--baseline|--update-baseline]"     },
        .{ .name = "status",          .description = "workspace up-to-date vs origin",                                    .args = "<workspace>"                        },
        .{ .name = "changes-preview", .description = "incoming commits + files changed",                                  .args = "<repo>"                             },
        .{ .name = "commits",         .description = "commits since a tag",                                               .args = "<repo> [tag]"                       },
        .{ .name = "gh-user",         .description = "GitHub auth + login info",                                          .args = ""                                   },
        .{ .name = "release-info",    .description = "latest tag, next version, dirty state",                             .args = "<repo>"                             },
        .{ .name = "repo-info",       .description = "remote owner/repo/url",                                             .args = "<repo>"                             },
        .{ .name = "tag-exists",      .description = "check if a tag exists",                                             .args = "<repo> <tag>"                       },
        .{ .name = "scan",            .description = "project structure, entry point, file inventory",                    .args = "<path>"                             },
        .{ .name = "diff-dirs",       .description = "structural diff of two directories",                                .args = "<path1> <path2>"                    },
        .{ .name = "grep",            .description = "search for a string across files",                                  .args = "<root> <pattern> [ext]"             },
        .{ .name = "find-files",      .description = "find files by name/glob",                                           .args = "<root> <glob>"                      },
        .{ .name = "json-query",      .description = "extract a value from a JSON file",                                  .args = "<file> <dot-path>"                  },
        .{ .name = "git-diff",        .description = "structured diff summary",                                           .args = "<repo> [ref]"                       },
        .{ .name = "list-dir",        .description = "immediate directory contents",                                      .args = "<path>"                             },
        .{ .name = "file-stats",      .description = "line count + byte size of a file",                                  .args = "<file>"                             },
        .{ .name = "env-scan",        .description = ".env* file keys (keys only, never values)",                         .args = "<root>"                             },
        .{ .name = "toml-query",      .description = "extract a value from a TOML file",                                  .args = "<file> <dot-path>"                  },
        .{ .name = "parse-stack",     .description = "structured file:line:col:fn from a stack trace (stdin)",            .args = ""                                   },
        .{ .name = "list-projects",   .description = "GitHub repos with isForeman + isLocal flags",                      .args = "<foreman-root>"                     },
        .{ .name = "tarball-sha",     .description = "GitHub tarball SHA256 with retry",                                  .args = "<owner> <repo> <tag>"               },
        .{ .name = "formula-info",    .description = "Homebrew formula fields (url, sha256, version)",                    .args = "<tap-path> <formula-name>"          },
        .{ .name = "validate-hooks",  .description = "Claude Code Stop hooks present check",                              .args = ""                                   },
        .{ .name = "gh-release",      .description = "GitHub release creation via notes file",                            .args = "<owner> <repo> <tag> <title> <notes-file>" },
        .{ .name = "file-hash",       .description = "SHA256 hash of a local file",                                      .args = "<file>"                             },
        .{ .name = "cache-fetch",     .description = "retrieve cached sub-key for a file; hit:true means skip read",     .args = "<file> <sub-key>"                   },
        .{ .name = "cache-store",     .description = "store extracted JSON keyed to file content (stdin)",                .args = "<file> <sub-key>"                   },
        .{ .name = "cache-check",     .description = "persistent change detection for a file",                            .args = "<file>"                             },
        .{ .name = "context-scan",    .description = "compact project summary (structure + top files by size)",           .args = "<path>"                             },
        .{ .name = "context-rank",    .description = "relevance ranking — score files by query (top 15)",                 .args = "<root> <query>"                     },
        .{ .name = "context-changed", .description = "changed files with unified diff content",                           .args = "<repo> [ref]"                       },
        .{ .name = "context-evidence",.description = "relevant excerpts from a file without reading the whole thing",     .args = "<file> <pattern>"                   },
        .{ .name = "yaml-query",      .description = "extract a value from a YAML file",                                  .args = "<file> <dot-path>"                  },
        .{ .name = "outline",         .description = "structural outline of a source file (function/class names + lines)",.args = "<file>"                             },
        .{ .name = "deps",            .description = "project dependencies from any package manifest",                    .args = "<root>"                             },
        .{ .name = "run-tests",       .description = "run tests + get structured pass/fail/failures",                     .args = "<root>"                             },
        .{ .name = "build",           .description = "detect build system, run build, get structured errors/warnings",    .args = "<root>"                             },
        .{ .name = "env-inspect",     .description = "detect languages, runtimes, package managers, missing deps",        .args = "<root>"                             },
        .{ .name = "symbol-find",     .description = "locate a symbol's definition and all references",                   .args = "<root> <symbol>"                    },
        .{ .name = "secret-scan",     .description = "scan for hardcoded secrets across a project",                       .args = "<root>"                             },
        .{ .name = "device-scan",     .description = "snapshot hardware + tools + optimal settings to profile.json",      .args = ""                                   },
        .{ .name = "delta-context",   .description = "changed symbols since a ref + their callers",                       .args = "<repo> [ref]"                       },
        .{ .name = "git-cache",       .description = "branch, HEAD, dirty state, ahead/behind, last 10 commits (cached)",.args = "<repo>"                             },
        .{ .name = "project-state",   .description = "read/write project decisions and known patterns across sessions",   .args = "<path> [record-decision <what> [<why>] | record-pattern <pattern>]" },
        .{ .name = "shell-run",       .description = "run a shell command safely — blocks destructive patterns",          .args = "[--timeout <ms>] <command>"         },
        .{ .name = "quality-gate",    .description = "aggregate build + test results into a severity-bucketed verdict",   .args = "<root>"                             },
        .{ .name = "validate-schema", .description = "validate a JSON file against a JSON Schema subset",                 .args = "<file> <schema>"                    },
        .{ .name = "prod-ready",      .description = "composite production readiness: quality-gate + secret-scan + env-inspect", .args = "<root>"                     },
        .{ .name = "registry",          .description = "machine-readable catalog of all subcommands (this output)",              .args = ""                    },
        .{ .name = "capability-check",  .description = "check if a capability is natively available in foreman-tools or needs Claude fallback", .args = "<query...>" },
        .{ .name = "route",             .description = "task router — returns execution plan with subcommand, argHint, confidence, reason",     .args = "<task...>"  },
        .{ .name = "report",            .description = "composite project status — git state + build + tests + secrets",                         .args = "<path>"     },
        .{ .name = "metrics",           .description = "telemetry snapshot — cache entries, project states, decisions, estimated token savings", .args = ""           },
        .{ .name = "session-snapshot",  .description = "write ground-truth session state to ~/.foreman/session-snapshot.json before compaction", .args = "<foreman-root>" },
        .{ .name = "sandbox-check",     .description = "classify a shell operation by severity (safe/caution/destructive/blocked) and return whether it is allowed", .args = "<command...>" },
        .{ .name = "rollback",            .description = "snapshot/list/revert git state — capture current HEAD+branch, list stored snapshots, or get revert commands for a snapshot", .args = "<repo-path> [--list | --revert <id>]" },
        .{ .name = "capability-promote", .description = "score a shell command for promotion eligibility as a foreman-tools subcommand (0-100 + recommendation)", .args = "<command...>" },
        .{ .name = "ant",               .description = "list files changed in a path since a timestamp (mtime-based, no git required)",                             .args = "<path> [--since <ms>]" },
        .{ .name = "worker-run",        .description = "run a script in a language runtime (python/node/deno/bun/go/ruby/bash/swift/zig/lua/php) — returns structured JSON", .args = "<lang> <script> [args...]" },
        .{ .name = "worker-list",       .description = "list all supported language workers with binary name and file extension",                                            .args = ""                          },
    };
    return .{ .version = VERSION, .subcommands = cmds };
}

// --- capability-check ---

pub const CapabilityCheckResult = struct {
    query: []const u8,
    available: bool,
    source: []const u8,      // "native" | "claude"
    subcommand: []const u8,  // "" when not found
    description: []const u8, // "" when not found
    args: []const u8,        // "" when not found
    confidence: []const u8,  // "exact" | "high" | "medium" | "low" | "none"
};

pub fn computeCapabilityCheck(gpa: std.mem.Allocator, query: []const u8) !CapabilityCheckResult {
    const reg = computeRegistry();

    // Lowercase query once
    const q_lower = try gpa.alloc(u8, query.len);
    defer gpa.free(q_lower);
    for (query, 0..) |c, i| q_lower[i] = std.ascii.toLower(c);

    var best_score: u32 = 0;
    var best_total: u32 = 0; // tie-breaker: total name+desc word matches
    var best_idx: usize = reg.subcommands.len;

    for (reg.subcommands, 0..) |cmd, idx| {
        const name_lower = try gpa.alloc(u8, cmd.name.len);
        defer gpa.free(name_lower);
        for (cmd.name, 0..) |c, i| name_lower[i] = std.ascii.toLower(c);

        const desc_lower = try gpa.alloc(u8, cmd.description.len);
        defer gpa.free(desc_lower);
        for (cmd.description, 0..) |c, i| desc_lower[i] = std.ascii.toLower(c);

        var score: u32 = 0;
        var name_match_count: u32 = 0;
        var desc_match_count: u32 = 0;

        if (std.mem.eql(u8, name_lower, q_lower)) {
            score = 100;
        } else if (std.mem.indexOf(u8, name_lower, q_lower) != null or
                   std.mem.indexOf(u8, q_lower, name_lower) != null) {
            score = 80;
        } else {
            var all_in_name: bool = true;
            var all_in_desc: bool = true;
            var any_in_name: bool = false;
            var any_in_desc: bool = false;
            var word_count: u32 = 0;
            var it = std.mem.tokenizeScalar(u8, q_lower, ' ');
            while (it.next()) |word| {
                if (word.len < 3) continue; // skip stop words
                word_count += 1;
                if (std.mem.indexOf(u8, name_lower, word) != null) {
                    any_in_name = true;
                    name_match_count += 1;
                } else {
                    all_in_name = false;
                }
                if (std.mem.indexOf(u8, desc_lower, word) != null) {
                    any_in_desc = true;
                    desc_match_count += 1;
                } else {
                    all_in_desc = false;
                }
            }
            if (word_count > 0) {
                if (all_in_name)              score = 70
                else if (all_in_desc)         score = 60
                else if (name_match_count >= 2) score = 50
                else if (desc_match_count >= 2) score = 45
                else if (any_in_name)         score = 35
                else if (any_in_desc)         score = 30;
            }
        }

        const total = name_match_count + desc_match_count;
        if (score > best_score or (score == best_score and total > best_total)) {
            best_score = score;
            best_total = total;
            best_idx = idx;
        }
    }

    const THRESHOLD: u32 = 30;
    if (best_idx < reg.subcommands.len and best_score >= THRESHOLD) {
        const cmd = reg.subcommands[best_idx];
        const confidence: []const u8 = if (best_score >= 100) "exact"
            else if (best_score >= 70) "high"
            else if (best_score >= 50) "medium"
            else "low";
        return .{
            .query       = try gpa.dupe(u8, query),
            .available   = true,
            .source      = "native",
            .subcommand  = cmd.name,
            .description = cmd.description,
            .args        = cmd.args,
            .confidence  = confidence,
        };
    }
    return .{
        .query       = try gpa.dupe(u8, query),
        .available   = false,
        .source      = "claude",
        .subcommand  = "",
        .description = "",
        .args        = "",
        .confidence  = "none",
    };
}

// --- route ---

pub const RouteStep = struct {
    step: u32,
    layer: []const u8,
    subcommand: []const u8,
    arg_hint: []const u8,
    reason: []const u8,
    confidence: []const u8,
};

pub const RouteResult = struct {
    task: []const u8,
    routed: bool,
    steps: []RouteStep,   // gpa-owned slice; strings within are borrowed from static data
    fallback: []const u8, // "claude" or ""
    reason: []const u8,   // fallback explanation or ""
};

const RouteEnrichment = struct {
    subcommand: []const u8,
    arg_hint: []const u8,
    reason: []const u8,
};

const ROUTE_ENRICHMENTS: []const RouteEnrichment = &[_]RouteEnrichment{
    .{ .subcommand = "git-cache",       .arg_hint = "<repo-path>",           .reason = "cached branch/HEAD/dirty/commits — hit:true means zero git subprocesses this session" },
    .{ .subcommand = "status",          .arg_hint = "<workspace>",            .reason = "workspace up-to-date vs origin in one call; use before git operations" },
    .{ .subcommand = "run-tests",       .arg_hint = "<abs-path>",             .reason = "auto-detects framework, runs tests, returns structured failures — read verdict + failures array" },
    .{ .subcommand = "build",           .arg_hint = "<abs-path>",             .reason = "auto-detects build system, returns structured errors with file:line — read success + errors array" },
    .{ .subcommand = "quality-gate",    .arg_hint = "<abs-path>",             .reason = "runs build + tests, severity-bucketed verdict — call before promoting or merging" },
    .{ .subcommand = "prod-ready",      .arg_hint = "<abs-path>",             .reason = "composite gate (quality-gate + secret-scan + env-inspect) — call before any deploy" },
    .{ .subcommand = "secret-scan",     .arg_hint = "<abs-path>",             .reason = "walks project tree, flags hardcoded secrets by pattern — read findings array" },
    .{ .subcommand = "outline",         .arg_hint = "<abs-file-path>",        .reason = "function/class/struct names + line numbers — use instead of reading the full file" },
    .{ .subcommand = "context-scan",    .arg_hint = "<abs-path>",             .reason = "compact project summary (structure + top files by size) — use before reading any source" },
    .{ .subcommand = "context-rank",    .arg_hint = "<abs-root> <query>",     .reason = "score and rank files by query relevance — read highest-ranked files first" },
    .{ .subcommand = "context-evidence",.arg_hint = "<abs-file> <pattern>",   .reason = "relevant excerpts (±10 lines) without reading the whole file" },
    .{ .subcommand = "symbol-find",     .arg_hint = "<abs-root> <symbol>",    .reason = "definition + all references in one call — replaces grep + read N files" },
    .{ .subcommand = "deps",            .arg_hint = "<abs-root>",             .reason = "declared dependencies from any manifest — replaces reading the full manifest file" },
    .{ .subcommand = "env-inspect",     .arg_hint = "<abs-root>",             .reason = "detects languages, runtimes, package managers, missing deps — replaces which + --version loops" },
    .{ .subcommand = "project-state",   .arg_hint = "<abs-path>",             .reason = "persisted decisions and known patterns across sessions from ~/.foreman/state/" },
    .{ .subcommand = "cache-fetch",     .arg_hint = "<abs-file> <sub-key>",   .reason = "hit:true → skip the read entirely and use value; hit:false → read file + cache-store" },
    .{ .subcommand = "delta-context",   .arg_hint = "<repo-path> [ref]",      .reason = "changed symbols + callers — targeted impact analysis without reading raw git diffs" },
    .{ .subcommand = "validate-schema", .arg_hint = "<abs-file> <abs-schema>",.reason = "JSON Schema compliance check — returns violations with $-rooted paths" },
    .{ .subcommand = "shell-run",       .arg_hint = "[--timeout <ms>] <cmd>", .reason = "safe shell execution with destructive-pattern blocking and structured output" },
    .{ .subcommand = "scan",            .arg_hint = "<abs-path>",             .reason = "project structure, entry point, file inventory — use context-scan when only structure is needed" },
    .{ .subcommand = "git-diff",        .arg_hint = "<repo> [ref]",           .reason = "structured diff summary — use instead of reading raw git diff output" },
    .{ .subcommand = "doctor",          .arg_hint = "",                        .reason = "session deps check (claude/git/gh present + versions) — run once at session start" },
    .{ .subcommand = "release-info",    .arg_hint = "<repo>",                 .reason = "latest tag, next version, dirty state in one call — use before /release or /brew-release" },
    .{ .subcommand = "file-hash",       .arg_hint = "<abs-file>",             .reason = "SHA256 of a local file — foundation for change detection before re-reading" },
    .{ .subcommand = "capability-check",.arg_hint = "<query...>",             .reason = "check if a task is natively handled before deciding whether to shell out" },
};

pub fn computeRoute(gpa: std.mem.Allocator, task: []const u8) !RouteResult {
    const cap = try computeCapabilityCheck(gpa, task);
    defer gpa.free(cap.query);

    if (!cap.available) {
        return .{
            .task     = try gpa.dupe(u8, task),
            .routed   = false,
            .steps    = try gpa.alloc(RouteStep, 0),
            .fallback = "claude",
            .reason   = "no native subcommand matches this task",
        };
    }

    // Find enrichment for the matched subcommand
    var arg_hint: []const u8 = cap.args;
    var reason: []const u8 = cap.description;
    for (ROUTE_ENRICHMENTS) |enrich| {
        if (std.mem.eql(u8, enrich.subcommand, cap.subcommand)) {
            arg_hint = enrich.arg_hint;
            reason   = enrich.reason;
            break;
        }
    }

    const steps = try gpa.alloc(RouteStep, 1);
    steps[0] = .{
        .step       = 1,
        .layer      = "native",
        .subcommand = cap.subcommand,
        .arg_hint   = arg_hint,
        .reason     = reason,
        .confidence = cap.confidence,
    };

    return .{
        .task     = try gpa.dupe(u8, task),
        .routed   = true,
        .steps    = steps,
        .fallback = "",
        .reason   = "",
    };
}

// --- report ---

pub const ReportIssue = struct { source: []const u8, message: []const u8, severity: []const u8 };

pub const ReportResult = struct {
    path: []const u8,
    status: []const u8,          // "clean" | "issues" | "blocked"
    confidence: []const u8,      // "high" | "medium" | "low"
    git_branch: []const u8,
    git_dirty: bool,
    build_ok: bool,
    tests_ok: bool,
    secrets_found: bool,
    issues: []ReportIssue,
    next_action: []const u8,
};

pub fn computeReport(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ReportResult {
    var issues: std.ArrayList(ReportIssue) = .empty;

    // Git state
    const git_opt: ?GitCacheResult = blk: {
        const r = computeGitCache(gpa, io, path) catch { break :blk null; };
        break :blk r;
    };
    const git_branch = if (git_opt) |g| g.branch else "";
    const git_dirty  = if (git_opt) |g| g.dirty  else false;

    // Build + tests via quality-gate
    const qg_opt: ?QualityGateResult = blk: {
        const r = computeQualityGate(gpa, io, path) catch { break :blk null; };
        break :blk r;
    };
    const build_ok = if (qg_opt) |q| blk2: {
        if (!q.build_ran) break :blk2 true; // no build system → treat as ok
        break :blk2 q.critical.len == 0 and q.high.len == 0;
    } else true;
    const tests_ok = if (qg_opt) |q| blk2: {
        if (!q.tests_ran) break :blk2 true; // no test framework → treat as ok
        break :blk2 q.tests_failed == 0;
    } else true;

    if (qg_opt) |q| {
        for (q.critical) |f| {
            if (issues.items.len >= 20) break;
            try issues.append(gpa, .{
                .source   = try gpa.dupe(u8, f.source),
                .message  = try gpa.dupe(u8, f.message),
                .severity = "critical",
            });
        }
        for (q.high) |f| {
            if (issues.items.len >= 20) break;
            try issues.append(gpa, .{
                .source   = try gpa.dupe(u8, f.source),
                .message  = try gpa.dupe(u8, f.message),
                .severity = "high",
            });
        }
        for (q.medium) |f| {
            if (issues.items.len >= 20) break;
            try issues.append(gpa, .{
                .source   = try gpa.dupe(u8, f.source),
                .message  = try gpa.dupe(u8, f.message),
                .severity = "medium",
            });
        }
    }

    // Secrets
    const sec_opt: ?SecretScanResult = blk: {
        const r = computeSecretScan(gpa, io, path) catch { break :blk null; };
        break :blk r;
    };
    const secrets_found = if (sec_opt) |s| s.findings.len > 0 else false;
    if (sec_opt) |s| {
        if (s.findings.len > 0 and issues.items.len < 20) {
            const msg = try std.fmt.allocPrint(gpa, "{d} hardcoded secret(s) found", .{s.findings.len});
            try issues.append(gpa, .{ .source = "secret-scan", .message = msg, .severity = "critical" });
        }
    }

    // Derive status + confidence
    var has_critical = secrets_found;
    var has_high = false;
    if (!build_ok) { has_critical = true; }
    if (!tests_ok) { has_high = true; }
    for (issues.items) |iss| {
        if (std.mem.eql(u8, iss.severity, "critical")) has_critical = true;
        if (std.mem.eql(u8, iss.severity, "high"))     has_high = true;
    }
    const status: []const u8 = if (has_critical) "blocked"
        else if (has_high or issues.items.len > 0) "issues"
        else "clean";

    const confidence: []const u8 = if (qg_opt != null) "high"
        else if (git_opt != null) "medium"
        else "low";

    // Next action
    const next_action: []const u8 = if (has_critical)
        "fix critical issues before proceeding"
    else if (has_high)
        "fix high-severity issues, then re-run /quality-gate"
    else if (git_dirty)
        "commit or stash uncommitted changes"
    else if (issues.items.len > 0)
        "review medium findings, then run /prod-ready"
    else
        "run /prod-ready before deploying";

    return .{
        .path          = try gpa.dupe(u8, path),
        .status        = status,
        .confidence    = confidence,
        .git_branch    = if (git_branch.len > 0) try gpa.dupe(u8, git_branch) else "",
        .git_dirty     = git_dirty,
        .build_ok      = build_ok,
        .tests_ok      = tests_ok,
        .secrets_found = secrets_found,
        .issues        = try issues.toOwnedSlice(gpa),
        .next_action   = next_action,
    };
}

// --- metrics ---

pub const MetricsResult = struct {
    cache_entries: u32,
    project_states: u32,
    total_decisions: u32,
    total_patterns: u32,
    device_profiled: bool,
    compat_baseline_set: bool,
    estimated_token_savings: u32,
};

pub fn computeMetrics(gpa: std.mem.Allocator, io: std.Io) !MetricsResult {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home: []const u8 = std.mem.span(home_ptr);

    // --- Cache entries ---
    const cache_dir_path = try std.fmt.allocPrint(gpa, "{s}/.cache/foreman-tools", .{home});
    defer gpa.free(cache_dir_path);
    var cache_entries: u32 = 0;
    cache_walk: {
        var dir = std.Io.Dir.openDirAbsolute(io, cache_dir_path, .{ .iterate = true }) catch break :cache_walk;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch break :cache_walk) |entry| {
            if (entry.kind != .file) continue;
            cache_entries += 1;
        }
    }

    // --- Project states (decisions + patterns) ---
    const state_dir_path = try std.fmt.allocPrint(gpa, "{s}/.foreman/state", .{home});
    defer gpa.free(state_dir_path);
    var project_states: u32 = 0;
    var total_decisions: u32 = 0;
    var total_patterns: u32 = 0;
    state_walk: {
        var dir = std.Io.Dir.openDirAbsolute(io, state_dir_path, .{ .iterate = true }) catch break :state_walk;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch break :state_walk) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            project_states += 1;
            const file_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ state_dir_path, entry.name });
            defer gpa.free(file_path);
            const content: []u8 = blk: {
                var f = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch break :blk &.{};
                var rbuf: [4096]u8 = undefined;
                var r = f.reader(io, &rbuf);
                break :blk r.interface.allocRemaining(gpa, .limited(65536)) catch &.{};
            };
            defer if (content.len > 0) gpa.free(content);
            if (content.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            if (obj.get("decisions")) |dv| {
                if (dv == .array) total_decisions += @intCast(dv.array.items.len);
            }
            if (obj.get("known_patterns")) |pv| {
                if (pv == .array) total_patterns += @intCast(pv.array.items.len);
            }
        }
    }

    // --- Profile and baseline ---
    const profile_path = try std.fmt.allocPrint(gpa, "{s}/.foreman/profile.json", .{home});
    defer gpa.free(profile_path);
    const baseline_path = try std.fmt.allocPrint(gpa, "{s}/.foreman/compat-baseline.json", .{home});
    defer gpa.free(baseline_path);
    const device_profiled    = fileExists(io, profile_path);
    const compat_baseline_set = fileExists(io, baseline_path);

    // Estimated token savings: each cache entry represents ~200 tokens saved on a hit
    // Assuming the documented 80% cache-hit-rate target: savings = entries × 0.8 × 200 = entries × 160
    const estimated_token_savings = cache_entries *% 160;

    return .{
        .cache_entries         = cache_entries,
        .project_states        = project_states,
        .total_decisions       = total_decisions,
        .total_patterns        = total_patterns,
        .device_profiled       = device_profiled,
        .compat_baseline_set   = compat_baseline_set,
        .estimated_token_savings = estimated_token_savings,
    };
}

// --- session-snapshot subcommand ---

pub fn computeSnapshot(gpa: std.mem.Allocator, io: std.Io, foreman_root: []const u8) ![]u8 {
    // Read ROADMAP.md and extract Active Work facts
    const roadmap_path = try std.fmt.allocPrint(gpa, "{s}/ROADMAP.md", .{foreman_root});
    defer gpa.free(roadmap_path);

    var wave_line: []const u8 = "unknown";
    var current_line: []const u8 = "unknown";
    var wave_owned = false;
    var current_owned = false;

    roadmap_blk: {
        var f = std.Io.Dir.openFileAbsolute(io, roadmap_path, .{}) catch break :roadmap_blk;
        var rbuf: [4096]u8 = undefined;
        var r = f.reader(io, &rbuf);
        const content = r.interface.allocRemaining(gpa, .limited(512 * 1024)) catch break :roadmap_blk;
        defer gpa.free(content);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (std.mem.startsWith(u8, line, "**Wave:**")) {
                const val = std.mem.trim(u8, line["**Wave:**".len..], " ");
                wave_line = gpa.dupe(u8, val) catch break :roadmap_blk;
                wave_owned = true;
            } else if (std.mem.startsWith(u8, line, "**Current:**")) {
                const val = std.mem.trim(u8, line["**Current:**".len..], " ");
                current_line = gpa.dupe(u8, val) catch break :roadmap_blk;
                current_owned = true;
            }
        }
    }
    defer if (wave_owned) gpa.free(wave_line);
    defer if (current_owned) gpa.free(current_line);

    // JSON-escape extracted strings
    const wave_esc = try allocJsonEscape(gpa, wave_line);
    defer gpa.free(wave_esc);
    const current_esc = try allocJsonEscape(gpa, current_line);
    defer gpa.free(current_esc);

    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "version": "{s}",
        \\  "wave": "{s}",
        \\  "current": "{s}",
        \\  "pending_errors": null
        \\}}
    , .{ VERSION, wave_esc, current_esc });

    // Write to ~/.foreman/session-snapshot.json (atomic)
    write_blk: {
        const home_ptr = std.c.getenv("HOME") orelse break :write_blk;
        const home: []const u8 = std.mem.span(home_ptr);
        const foreman_dir = try std.fmt.allocPrint(gpa, "{s}/.foreman", .{home});
        defer gpa.free(foreman_dir);
        std.Io.Dir.createDirAbsolute(io, foreman_dir, .default_dir) catch {};
        var tmp_buf: [512]u8 = undefined;
        const snap_path = std.fmt.bufPrint(&tmp_buf, "{s}/.foreman/session-snapshot.json", .{home}) catch break :write_blk;
        var tmp_buf2: [520]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf2, "{s}.tmp", .{snap_path}) catch break :write_blk;
        const wf = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch break :write_blk;
        var wbuf: [256]u8 = undefined;
        var w = wf.writerStreaming(io, &wbuf);
        w.interface.writeAll(json) catch { wf.close(io); break :write_blk; };
        w.interface.flush() catch {};
        wf.close(io);
        atomicRenameAbsolute(tmp_path, snap_path);
    }

    return json; // caller must gpa.free
}

// --- rollback subcommand (Module 29) ---

fn rollbackSnapPath(gpa: std.mem.Allocator, home: []const u8, repo_path: []const u8) ![]u8 {
    const name_buf = try gpa.alloc(u8, repo_path.len);
    defer gpa.free(name_buf);
    for (repo_path, 0..) |c, i| {
        name_buf[i] = if (std.ascii.isAlphanumeric(c) or c == '-') c else '_';
    }
    const name_slice = if (name_buf.len > 80) name_buf[name_buf.len - 80..] else name_buf;
    return std.fmt.allocPrint(gpa, "{s}/.foreman/snapshots/{s}.json", .{ home, name_slice });
}

pub fn computeRollbackSnapshot(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8) ![]u8 {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home: []const u8 = std.mem.span(home_ptr);

    const git = try computeGitCache(gpa, io, repo_path);
    var _ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &_ts);
    const ts_ms: i64 = _ts.sec *% 1000 + @divTrunc(_ts.nsec, 1_000_000);

    var id_buf: [32]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{ts_ms});

    const foreman_dir = try std.fmt.allocPrint(gpa, "{s}/.foreman", .{home});
    defer gpa.free(foreman_dir);
    const snap_dir = try std.fmt.allocPrint(gpa, "{s}/.foreman/snapshots", .{home});
    defer gpa.free(snap_dir);
    std.Io.Dir.createDirAbsolute(io, foreman_dir, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(io, snap_dir, .default_dir) catch {};

    const snap_path = try rollbackSnapPath(gpa, home, repo_path);
    defer gpa.free(snap_path);

    var arr: std.ArrayList(u8) = .empty;
    defer arr.deinit(gpa);
    var count: u32 = 0;

    existing_blk: {
        var f = std.Io.Dir.openFileAbsolute(io, snap_path, .{}) catch break :existing_blk;
        var rbuf: [4096]u8 = undefined;
        var r = f.reader(io, &rbuf);
        const content = r.interface.allocRemaining(gpa, .limited(64 * 1024)) catch break :existing_blk;
        defer gpa.free(content);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch break :existing_blk;
        defer parsed.deinit();
        if (parsed.value != .array) break :existing_blk;
        const items = parsed.value.array.items;
        const start: usize = if (items.len >= 19) items.len - 19 else 0;
        for (items[start..]) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const eid = if (obj.get("id"))            |v| if (v == .string)  v.string  else "" else "";
            const ebr = if (obj.get("branch"))        |v| if (v == .string)  v.string  else "" else "";
            const ehd = if (obj.get("head"))           |v| if (v == .string)  v.string  else "" else "";
            const edr = if (obj.get("dirty"))          |v| if (v == .bool)    v.bool    else false else false;
            const ems: i64 = if (obj.get("created_at_ms")) |v| if (v == .integer) v.integer else 0 else 0;
            if (arr.items.len > 0) try arr.append(gpa, ',');
            const item_json = try std.fmt.allocPrint(gpa,
                "{{\"id\":\"{s}\",\"branch\":\"{s}\",\"head\":\"{s}\",\"dirty\":{s},\"created_at_ms\":{d}}}",
                .{ eid, ebr, ehd, if (edr) "true" else "false", ems });
            defer gpa.free(item_json);
            try arr.appendSlice(gpa, item_json);
            count += 1;
        }
    }

    if (arr.items.len > 0) try arr.append(gpa, ',');
    const new_entry = try std.fmt.allocPrint(gpa,
        "{{\"id\":\"{s}\",\"branch\":\"{s}\",\"head\":\"{s}\",\"dirty\":{s},\"created_at_ms\":{d}}}",
        .{ id_str, git.branch, git.head, if (git.dirty) "true" else "false", ts_ms });
    defer gpa.free(new_entry);
    try arr.appendSlice(gpa, new_entry);
    count += 1;

    var tmp_buf: [640]u8 = undefined;
    write_blk: {
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{snap_path}) catch break :write_blk;
        const wf = std.Io.Dir.createFileAbsolute(io, tmp_path, .{}) catch break :write_blk;
        var wbuf: [256]u8 = undefined;
        var w = wf.writerStreaming(io, &wbuf);
        w.interface.writeAll("[") catch { wf.close(io); break :write_blk; };
        w.interface.writeAll(arr.items) catch {};
        w.interface.writeAll("]") catch {};
        w.interface.flush() catch {};
        wf.close(io);
        atomicRenameAbsolute(tmp_path, snap_path);
    }

    const snap_esc = try allocJsonEscape(gpa, snap_path);
    defer gpa.free(snap_esc);
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "id": "{s}",
        \\  "branch": "{s}",
        \\  "head": "{s}",
        \\  "dirty": {s},
        \\  "created_at_ms": {d},
        \\  "snapshot_count": {d},
        \\  "snapshot_file": "{s}"
        \\}}
    , .{ id_str, git.branch, git.head, if (git.dirty) "true" else "false", ts_ms, count, snap_esc });
}

pub fn computeRollbackList(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8) ![]u8 {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home: []const u8 = std.mem.span(home_ptr);
    const snap_path = try rollbackSnapPath(gpa, home, repo_path);
    defer gpa.free(snap_path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const repo_esc = try allocJsonEscape(gpa, repo_path);
    defer gpa.free(repo_esc);
    const header = try std.fmt.allocPrint(gpa, "{{\n  \"repo\": \"{s}\",\n  \"snapshots\": [", .{repo_esc});
    defer gpa.free(header);
    try out.appendSlice(gpa, header);

    var count: u32 = 0;
    list_blk: {
        var f = std.Io.Dir.openFileAbsolute(io, snap_path, .{}) catch break :list_blk;
        var rbuf: [4096]u8 = undefined;
        var r = f.reader(io, &rbuf);
        const content = r.interface.allocRemaining(gpa, .limited(64 * 1024)) catch break :list_blk;
        defer gpa.free(content);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch break :list_blk;
        defer parsed.deinit();
        if (parsed.value != .array) break :list_blk;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const eid = if (obj.get("id"))            |v| if (v == .string)  v.string  else "" else "";
            const ebr = if (obj.get("branch"))        |v| if (v == .string)  v.string  else "" else "";
            const ehd = if (obj.get("head"))           |v| if (v == .string)  v.string  else "" else "";
            const edr = if (obj.get("dirty"))          |v| if (v == .bool)    v.bool    else false else false;
            const ems: i64 = if (obj.get("created_at_ms")) |v| if (v == .integer) v.integer else 0 else 0;
            if (count > 0) try out.append(gpa, ',');
            const entry = try std.fmt.allocPrint(gpa,
                "\n    {{\"id\":\"{s}\",\"branch\":\"{s}\",\"head\":\"{s}\",\"dirty\":{s},\"created_at_ms\":{d}}}",
                .{ eid, ebr, ehd, if (edr) "true" else "false", ems });
            defer gpa.free(entry);
            try out.appendSlice(gpa, entry);
            count += 1;
        }
    }

    const footer = try std.fmt.allocPrint(gpa, "\n  ],\n  \"count\": {d}\n}}", .{count});
    defer gpa.free(footer);
    try out.appendSlice(gpa, footer);
    return out.toOwnedSlice(gpa);
}

pub fn computeRollbackRevert(gpa: std.mem.Allocator, io: std.Io, repo_path: []const u8, snapshot_id: []const u8) ![]u8 {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home: []const u8 = std.mem.span(home_ptr);
    const snap_path = try rollbackSnapPath(gpa, home, repo_path);
    defer gpa.free(snap_path);

    var f = std.Io.Dir.openFileAbsolute(io, snap_path, .{}) catch return error.NoSnapshots;
    var rbuf: [4096]u8 = undefined;
    var r = f.reader(io, &rbuf);
    const content = r.interface.allocRemaining(gpa, .limited(64 * 1024)) catch return error.NoSnapshots;
    defer gpa.free(content);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch return error.NoSnapshots;
    defer parsed.deinit();

    if (parsed.value != .array) return error.NoSnapshots;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const eid = if (obj.get("id")) |v| if (v == .string) v.string else "" else "";
        if (!std.mem.eql(u8, eid, snapshot_id)) continue;
        const branch = if (obj.get("branch")) |v| if (v == .string) v.string else "" else "";
        const head   = if (obj.get("head"))   |v| if (v == .string) v.string else "" else "";
        const repo_esc   = try allocJsonEscape(gpa, repo_path);
        defer gpa.free(repo_esc);
        const branch_esc = try allocJsonEscape(gpa, branch);
        defer gpa.free(branch_esc);
        const head_esc   = try allocJsonEscape(gpa, head);
        defer gpa.free(head_esc);
        return std.fmt.allocPrint(gpa,
            \\{{
            \\  "snapshot_id": "{s}",
            \\  "branch": "{s}",
            \\  "head": "{s}",
            \\  "commands": [
            \\    "git -C {s} checkout {s}",
            \\    "git -C {s} reset --hard {s}"
            \\  ],
            \\  "warning": "These commands discard uncommitted changes. Verify with sandbox-check first."
            \\}}
        , .{ snapshot_id, branch_esc, head_esc, repo_esc, branch_esc, repo_esc, head_esc });
    }
    return error.SnapshotNotFound;
}

// --- sandbox-check subcommand ---

pub const SandboxSeverity = enum { safe, caution, destructive, blocked };

pub const SandboxCheckResult = struct {
    operation: []const u8, // duped — caller must free
    allowed: bool,
    severity: []const u8,  // static string literal
    reason: []const u8,    // static string literal
};

const SandboxPattern = struct {
    needle: []const u8,
    severity: SandboxSeverity,
    reason: []const u8,
};

const SANDBOX_PATTERNS = [_]SandboxPattern{
    // blocked — never allowed
    .{ .needle = "sudo rm",              .severity = .blocked,     .reason = "privileged recursive delete" },
    .{ .needle = "mkfs",                 .severity = .blocked,     .reason = "filesystem format" },
    .{ .needle = "fdisk",                .severity = .blocked,     .reason = "disk partition editor" },
    .{ .needle = "dd if=",               .severity = .blocked,     .reason = "raw disk write" },
    .{ .needle = ":(){:|:&};:",           .severity = .blocked,     .reason = "fork bomb" },
    // destructive — not allowed without override
    .{ .needle = "rm -rf",               .severity = .destructive, .reason = "recursive force delete" },
    .{ .needle = "rm -fr",               .severity = .destructive, .reason = "recursive force delete" },
    .{ .needle = "rm -r",                .severity = .destructive, .reason = "recursive delete" },
    .{ .needle = "git reset --hard",     .severity = .destructive, .reason = "discards uncommitted changes" },
    .{ .needle = "git push --force",     .severity = .destructive, .reason = "force-pushes over remote history" },
    .{ .needle = "git push -f",          .severity = .destructive, .reason = "force-pushes over remote history" },
    .{ .needle = "git checkout .",       .severity = .destructive, .reason = "discards all working-tree changes" },
    .{ .needle = "git restore .",        .severity = .destructive, .reason = "discards all working-tree changes" },
    .{ .needle = "git clean -f",         .severity = .destructive, .reason = "removes untracked files" },
    .{ .needle = "drop table",           .severity = .destructive, .reason = "drops database table" },
    .{ .needle = "drop database",        .severity = .destructive, .reason = "drops entire database" },
    .{ .needle = "truncate table",       .severity = .destructive, .reason = "deletes all rows in table" },
    .{ .needle = "git branch -d",        .severity = .destructive, .reason = "force-deletes git branch" },
    .{ .needle = "--no-verify",          .severity = .destructive, .reason = "bypasses git hooks" },
    // caution — allowed with warning
    .{ .needle = "git push",             .severity = .caution,     .reason = "pushes to remote" },
    .{ .needle = "git commit",           .severity = .caution,     .reason = "creates a commit" },
    .{ .needle = "git tag",              .severity = .caution,     .reason = "creates or deletes a tag" },
    .{ .needle = "npm publish",          .severity = .caution,     .reason = "publishes package publicly" },
    .{ .needle = "yarn publish",         .severity = .caution,     .reason = "publishes package publicly" },
    .{ .needle = "cargo publish",        .severity = .caution,     .reason = "publishes crate publicly" },
    .{ .needle = "brew install",         .severity = .caution,     .reason = "installs system package" },
    .{ .needle = "brew upgrade",         .severity = .caution,     .reason = "upgrades system package" },
    .{ .needle = "pip install",          .severity = .caution,     .reason = "installs python package" },
    .{ .needle = "npm install",          .severity = .caution,     .reason = "installs node package" },
    .{ .needle = "gh release create",    .severity = .caution,     .reason = "publishes a GitHub release" },
    .{ .needle = "gh pr create",         .severity = .caution,     .reason = "opens a pull request" },
};

pub fn computeSandboxCheck(gpa: std.mem.Allocator, operation: []const u8) !SandboxCheckResult {
    // Lowercase the operation once; all needles in SANDBOX_PATTERNS are already lowercase
    const op_lower = try gpa.alloc(u8, operation.len);
    defer gpa.free(op_lower);
    _ = std.ascii.lowerString(op_lower, operation);

    var worst: SandboxSeverity = .safe;
    var worst_reason: []const u8 = "no destructive patterns matched";

    for (SANDBOX_PATTERNS) |pat| {
        if (!std.mem.containsAtLeast(u8, op_lower, 1, pat.needle)) continue;
        const rank: u8 = switch (pat.severity) { .safe => 0, .caution => 1, .destructive => 2, .blocked => 3 };
        const best: u8  = switch (worst)         { .safe => 0, .caution => 1, .destructive => 2, .blocked => 3 };
        if (rank > best) { worst = pat.severity; worst_reason = pat.reason; }
    }

    return .{
        .operation = try gpa.dupe(u8, operation),
        .allowed   = switch (worst) { .safe => true, .caution => true, .destructive => false, .blocked => false },
        .severity  = switch (worst) { .safe => "safe", .caution => "caution", .destructive => "destructive", .blocked => "blocked" },
        .reason    = worst_reason,
    };
}

// --- capability-promote (Module 21) ---

pub fn computeCapabilityPromote(gpa: std.mem.Allocator, command: []const u8) ![]u8 {
    // Lowercase command for pattern matching
    const cmd_lower = try gpa.alloc(u8, command.len);
    defer gpa.free(cmd_lower);
    for (command, 0..) |c, i| cmd_lower[i] = std.ascii.toLower(c);

    // Check if already covered by an existing subcommand at exact/high confidence
    const check = try computeCapabilityCheck(gpa, command);
    defer gpa.free(check.query);
    const already_covered = check.available and
        (std.mem.eql(u8, check.confidence, "exact") or std.mem.eql(u8, check.confidence, "high"));

    if (already_covered) {
        const sub = check.subcommand; // static registry string — safe to borrow after check.query freed
        const cmd_esc = try allocJsonEscape(gpa, command);
        defer gpa.free(cmd_esc);
        const sub_esc = try allocJsonEscape(gpa, sub);
        defer gpa.free(sub_esc);
        return std.fmt.allocPrint(gpa,
            \\{{
            \\  "command": "{s}",
            \\  "score": 0,
            \\  "already_covered": true,
            \\  "similar_subcommand": "{s}",
            \\  "recommendation": "skip",
            \\  "reasons": ["already covered by foreman-tools subcommand \"{s}\""]
            \\}}
        , .{ cmd_esc, sub_esc, sub_esc });
    }

    // Score promotion signals
    var score: u32 = 10; // baseline
    var reasons: [8][]const u8 = undefined;
    var n: usize = 0;

    if (std.mem.indexOf(u8, cmd_lower, "git ") != null or
        std.mem.startsWith(u8, cmd_lower, "git")) {
        score += 20; reasons[n] = "git operation"; n += 1;
    }
    if (std.mem.indexOf(u8, cmd_lower, "jq") != null or
        std.mem.indexOf(u8, cmd_lower, " awk") != null or
        std.mem.indexOf(u8, cmd_lower, "grep") != null or
        std.mem.indexOf(u8, cmd_lower, " sed ") != null or
        std.mem.indexOf(u8, cmd_lower, " head") != null or
        std.mem.indexOf(u8, cmd_lower, " tail") != null) {
        score += 20; reasons[n] = "parses structured output"; n += 1;
    }
    const has_side_effects =
        std.mem.indexOf(u8, cmd_lower, "push") != null or
        std.mem.indexOf(u8, cmd_lower, "commit") != null or
        std.mem.indexOf(u8, cmd_lower, " rm ") != null or
        std.mem.indexOf(u8, cmd_lower, "write") != null or
        std.mem.indexOf(u8, cmd_lower, "install") != null or
        std.mem.indexOf(u8, cmd_lower, "publish") != null;
    if (!has_side_effects) {
        score += 15; reasons[n] = "read-only / no side effects"; n += 1;
    }
    const has_nondeterminism =
        std.mem.indexOf(u8, cmd_lower, "date") != null or
        std.mem.indexOf(u8, cmd_lower, "random") != null or
        std.mem.indexOf(u8, cmd_lower, "sleep") != null;
    if (!has_nondeterminism) {
        score += 15; reasons[n] = "deterministic"; n += 1;
    }
    if (command.len < 80) {
        score += 10; reasons[n] = "compact command"; n += 1;
    }
    if (std.mem.indexOf(u8, cmd_lower, "/") != null or
        std.mem.indexOf(u8, cmd_lower, "<path") != null or
        std.mem.indexOf(u8, cmd_lower, "<repo") != null) {
        score += 10; reasons[n] = "takes path/repo argument"; n += 1;
    }

    const recommendation: []const u8 = if (score >= 60) "promote" else if (score >= 40) "consider" else "skip";

    // Build reasons JSON array content
    var reasons_buf: std.ArrayList(u8) = .empty;
    defer reasons_buf.deinit(gpa);
    for (reasons[0..n], 0..) |r, i| {
        if (i > 0) try reasons_buf.append(gpa, ',');
        try reasons_buf.appendSlice(gpa, "\"");
        try reasons_buf.appendSlice(gpa, r);
        try reasons_buf.appendSlice(gpa, "\"");
    }

    const cmd_esc = try allocJsonEscape(gpa, command);
    defer gpa.free(cmd_esc);

    // similar_subcommand is only meaningful in the already_covered early-return path
    const similar_json: []u8 = try gpa.dupe(u8, "null");
    defer gpa.free(similar_json);

    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "command": "{s}",
        \\  "score": {d},
        \\  "already_covered": false,
        \\  "similar_subcommand": {s},
        \\  "recommendation": "{s}",
        \\  "reasons": [{s}]
        \\}}
    , .{ cmd_esc, score, similar_json, recommendation, reasons_buf.items });
}

// --- ant subcommand (Ant colony: "what changed?" — mtime-based filesystem diff) ---

const ANT_CAP: usize = 500;

const AntEntry = struct {
    path: []u8,
    mtime_ms: i64,
};

fn antGetMtimeMs(io: std.Io, abs_path: []const u8) i64 {
    const file = std.Io.Dir.openFileAbsolute(io, abs_path, .{}) catch return 0;
    defer file.close(io);
    const st = file.stat(io) catch return 0;
    return @intCast(@divTrunc(st.mtime.nanoseconds, 1_000_000));
}

fn walkAntFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    rel_prefix: []const u8,
    root: []const u8,
    since_ms: i64,
    changed: *std.ArrayList(AntEntry),
    total: *u32,
    truncated: *bool,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipScanDir(entry.name)) continue;
            const sub_prefix: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            defer gpa.free(sub_prefix);
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            try walkAntFiles(gpa, io, sub, sub_prefix, root, since_ms, changed, total, truncated);
        } else if (entry.kind == .file) {
            if (shouldSkipScanFile(entry.name)) continue;
            const rel_path: []u8 = if (rel_prefix.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_prefix, entry.name });
            var transferred = false;
            defer if (!transferred) gpa.free(rel_path);
            const abs_path = std.fs.path.join(gpa, &.{ root, rel_path }) catch continue;
            defer gpa.free(abs_path);
            const mtime = antGetMtimeMs(io, abs_path);
            if (mtime > since_ms) {
                total.* += 1;
                if (changed.items.len < ANT_CAP) {
                    try changed.append(gpa, .{ .path = rel_path, .mtime_ms = mtime });
                    transferred = true;
                } else {
                    truncated.* = true;
                }
            }
        }
    }
}

pub fn computeAnt(gpa: std.mem.Allocator, io: std.Io, root_path: []const u8, since_ms: i64) ![]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true }) catch
        return error.PathNotFound;
    defer dir.close(io);

    var changed: std.ArrayList(AntEntry) = .empty;
    defer {
        for (changed.items) |e| gpa.free(e.path);
        changed.deinit(gpa);
    }
    var total: u32 = 0;
    var truncated = false;
    try walkAntFiles(gpa, io, dir, "", root_path, since_ms, &changed, &total, &truncated);

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const now_ms: i64 = ts.sec *% 1000 + @divTrunc(ts.nsec, 1_000_000);

    const root_esc = try allocJsonEscape(gpa, root_path);
    defer gpa.free(root_esc);

    var arr: std.ArrayList(u8) = .empty;
    defer arr.deinit(gpa);
    for (changed.items, 0..) |e, idx| {
        const path_esc = try allocJsonEscape(gpa, e.path);
        defer gpa.free(path_esc);
        if (idx > 0) try arr.appendSlice(gpa, ",\n");
        const line = try std.fmt.allocPrint(gpa, "    {{\"path\": \"{s}\", \"mtimeMs\": {d}}}", .{ path_esc, e.mtime_ms });
        defer gpa.free(line);
        try arr.appendSlice(gpa, line);
    }

    if (changed.items.len == 0) {
        return std.fmt.allocPrint(gpa,
            \\{{
            \\  "root": "{s}",
            \\  "sinceMs": {d},
            \\  "scannedAtMs": {d},
            \\  "total": 0,
            \\  "truncated": false,
            \\  "changed": []
            \\}}
        , .{ root_esc, since_ms, now_ms });
    }
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "root": "{s}",
        \\  "sinceMs": {d},
        \\  "scannedAtMs": {d},
        \\  "total": {d},
        \\  "truncated": {s},
        \\  "changed": [
        \\{s}
        \\  ]
        \\}}
    , .{ root_esc, since_ms, now_ms, total, if (truncated) "true" else "false", arr.items });
}

// --- worker-run / worker-list subcommands (Module 10 — Language Worker Manager) ---

const WORKER_OUTPUT_CAP: usize = 64 * 1024;
pub const WORKER_DEFAULT_TIMEOUT_MS: u64 = 30_000;

const WorkerEntry = struct {
    lang:       []const u8,
    candidates: []const []const u8,
    prefix:     []const []const u8,
    ext:        []const u8,
    alias:      bool = false,
};

const WORKER_LANGS = [_]WorkerEntry{
    .{ .lang = "python",  .candidates = &.{ "python3", "python" },             .prefix = &.{},                       .ext = "py"    },
    .{ .lang = "py",      .candidates = &.{ "python3", "python" },             .prefix = &.{},                       .ext = "py",    .alias = true },
    .{ .lang = "node",    .candidates = &.{ "node", "nodejs" },                .prefix = &.{},                       .ext = "js"    },
    .{ .lang = "js",      .candidates = &.{ "node", "nodejs" },                .prefix = &.{},                       .ext = "js",    .alias = true },
    .{ .lang = "deno",    .candidates = &.{ "deno" },                          .prefix = &.{ "run", "--allow-all" }, .ext = "ts"    },
    .{ .lang = "bun",     .candidates = &.{ "bun" },                           .prefix = &.{},                       .ext = "ts"    },
    .{ .lang = "go",      .candidates = &.{ "go" },                            .prefix = &.{ "run" },                .ext = "go"    },
    .{ .lang = "golang",  .candidates = &.{ "go" },                            .prefix = &.{ "run" },                .ext = "go",    .alias = true },
    .{ .lang = "ruby",    .candidates = &.{ "ruby" },                          .prefix = &.{},                       .ext = "rb"    },
    .{ .lang = "rb",      .candidates = &.{ "ruby" },                          .prefix = &.{},                       .ext = "rb",    .alias = true },
    .{ .lang = "bash",    .candidates = &.{ "bash", "sh" },                    .prefix = &.{},                       .ext = "sh"    },
    .{ .lang = "sh",      .candidates = &.{ "sh", "bash" },                    .prefix = &.{},                       .ext = "sh",    .alias = true },
    .{ .lang = "swift",   .candidates = &.{ "swift" },                         .prefix = &.{},                       .ext = "swift" },
    .{ .lang = "zig",     .candidates = &.{ "zig" },                           .prefix = &.{ "run" },                .ext = "zig"   },
    .{ .lang = "lua",     .candidates = &.{ "lua", "lua5.4", "lua5.3", "lua5.2" }, .prefix = &.{},                  .ext = "lua"   },
    .{ .lang = "php",     .candidates = &.{ "php", "php8", "php7" },           .prefix = &.{},                       .ext = "php"   },
};

fn workerFindEntry(lang: []const u8) ?WorkerEntry {
    for (&WORKER_LANGS) |e| {
        if (std.mem.eql(u8, e.lang, lang)) return e;
    }
    return null;
}

pub fn computeWorkerList(gpa: std.mem.Allocator) ![]u8 {
    var arr: std.ArrayList(u8) = .empty;
    defer arr.deinit(gpa);
    var first = true;
    for (&WORKER_LANGS) |e| {
        if (e.alias) continue;
        if (!first) try arr.appendSlice(gpa, ", ");
        first = false;
        const entry = try std.fmt.allocPrint(gpa,
            \\{{"lang": "{s}", "binary": "{s}", "ext": "{s}"}}
        , .{ e.lang, e.candidates[0], e.ext });
        defer gpa.free(entry);
        try arr.appendSlice(gpa, entry);
    }
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "workers": [{s}],
        \\  "count": {d}
        \\}}
    , .{ arr.items, blk: {
        var n: u32 = 0;
        for (&WORKER_LANGS) |e| { if (!e.alias) n += 1; }
        break :blk n;
    } });
}

pub fn computeWorkerRun(
    gpa:        std.mem.Allocator,
    io:         std.Io,
    lang:       []const u8,
    script_path: []const u8,
    extra_args: []const []const u8,
    timeout_ms: u64,
) ![]u8 {
    const entry = workerFindEntry(lang) orelse return error.UnknownLang;

    var ts_start: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_start);

    const RunOk = struct { stdout: []u8, stderr: []u8, exit: i32, interp: []const u8 };
    var run_ok: ?RunOk = null;

    for (entry.candidates) |cand| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, cand);
        for (entry.prefix) |a| try argv.append(gpa, a);
        try argv.append(gpa, script_path);
        for (extra_args) |a| try argv.append(gpa, a);

        const r = std.process.run(gpa, io, .{ .argv = argv.items }) catch |e| switch (e) {
            error.FileNotFound, error.AccessDenied, error.InvalidExe => continue,
            else => return e,
        };
        run_ok = .{
            .stdout = r.stdout,
            .stderr = r.stderr,
            .exit   = switch (r.term) { .exited => |c| @as(i32, @intCast(c)), else => -1 },
            .interp = cand,
        };
        break;
    }

    const res = run_ok orelse return error.InterpreterNotFound;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    var ts_end: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts_end);
    const duration_ms: u64 = blk: {
        const s0 = @as(u64, @intCast(ts_start.sec)) * 1000 + @as(u64, @intCast(ts_start.nsec)) / 1_000_000;
        const s1 = @as(u64, @intCast(ts_end.sec))   * 1000 + @as(u64, @intCast(ts_end.nsec))   / 1_000_000;
        break :blk if (s1 > s0) s1 - s0 else 0;
    };

    const truncated = res.stdout.len > WORKER_OUTPUT_CAP or res.stderr.len > WORKER_OUTPUT_CAP;
    const out_slice  = res.stdout[0..@min(res.stdout.len, WORKER_OUTPUT_CAP)];
    const err_slice  = res.stderr[0..@min(res.stderr.len, WORKER_OUTPUT_CAP)];

    const lang_esc   = try allocJsonEscape(gpa, lang);         defer gpa.free(lang_esc);
    const interp_esc = try allocJsonEscape(gpa, res.interp);   defer gpa.free(interp_esc);
    const script_esc = try allocJsonEscape(gpa, script_path);  defer gpa.free(script_esc);
    const out_esc    = try allocJsonEscape(gpa, out_slice);     defer gpa.free(out_esc);
    const err_esc    = try allocJsonEscape(gpa, err_slice);     defer gpa.free(err_esc);

    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "lang": "{s}",
        \\  "interpreter": "{s}",
        \\  "script": "{s}",
        \\  "exit_code": {d},
        \\  "stdout": "{s}",
        \\  "stderr": "{s}",
        \\  "duration_ms": {d},
        \\  "timed_out": {s},
        \\  "truncated": {s}
        \\}}
    , .{
        lang_esc, interp_esc, script_esc,
        res.exit, out_esc, err_esc,
        duration_ms,
        if (duration_ms >= timeout_ms) "true" else "false",
        if (truncated) "true" else "false",
    });
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

