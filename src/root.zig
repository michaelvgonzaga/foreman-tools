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

