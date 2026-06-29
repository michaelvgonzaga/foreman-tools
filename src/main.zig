const std = @import("std");
const root = @import("foreman_tools");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var err_buf: [512]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_writer.interface;

    var out_buf: [65536]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    if (args.len < 2) {
        try err.print("usage: foreman-tools <subcommand> [args]\n", .{});
        try err.print("subcommands:\n", .{});
        try err.print("  doctor\n", .{});
        try err.print("  status <workspace-path>\n", .{});
        try err.print("  commits <repo-path> [since-tag]\n", .{});
        try err.print("  gh-user\n", .{});
        try err.print("  release-info <repo-path>\n", .{});
        try err.print("  repo-info <repo-path>\n", .{});
        try err.print("  tag-exists <repo-path> <tag>\n", .{});
        try err.flush();
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "doctor")) {
        const result = try root.computeDoctor(gpa, io);
        defer gpa.free(result.version);

        const escaped_version = try root.allocJsonEscape(gpa, result.version);
        defer gpa.free(escaped_version);

        try out.print(
            "{{\n  \"claude\": {s},\n  \"git\": {s},\n  \"gh\": {s},\n  \"version\": \"{s}\"\n}}\n",
            .{
                if (result.claude) "true" else "false",
                if (result.git) "true" else "false",
                if (result.gh) "true" else "false",
                escaped_version,
            },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "status")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools status <workspace-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeStatus(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.NotAGitRepo => try err.print("error: not a git repository: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };

        try out.print(
            "{{\n  \"upToDate\": {s},\n  \"behindBy\": {d},\n  \"firstRun\": {s},\n  \"projectsFileExists\": {s}\n}}\n",
            .{
                if (result.upToDate) "true" else "false",
                result.behindBy,
                if (result.firstRun) "true" else "false",
                if (result.projectsFileExists) "true" else "false",
            },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "commits")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools commits <repo-path> [since-tag]\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const since_tag: ?[]const u8 = if (args.len >= 4) args[3] else null;

        const entries = root.computeCommits(gpa, io, args[2], since_tag) catch |e| {
            switch (e) {
                error.GitFailed => try err.print("error: git log failed (bad path or tag?): {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };

        try out.writeAll("[\n");
        for (entries, 0..) |entry, i| {
            const escaped_hash = try root.allocJsonEscape(gpa, entry.hash);
            defer gpa.free(escaped_hash);
            const escaped_msg = try root.allocJsonEscape(gpa, entry.message);
            defer gpa.free(escaped_msg);

            try out.print(
                "  {{\"hash\": \"{s}\", \"category\": \"{s}\", \"message\": \"{s}\"}}",
                .{ escaped_hash, entry.category, escaped_msg },
            );
            if (i + 1 < entries.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("]\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "gh-user")) {
        const result = try root.computeGhUser(gpa, io);
        defer gpa.free(result.login);

        const escaped_login = try root.allocJsonEscape(gpa, result.login);
        defer gpa.free(escaped_login);

        try out.print(
            "{{\n  \"authenticated\": {s},\n  \"login\": \"{s}\"\n}}\n",
            .{ if (result.authenticated) "true" else "false", escaped_login },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "release-info")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools release-info <repo-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeReleaseInfo(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.NotAGitRepo => try err.print("error: not a git repository: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            if (result.latestTag) |t| gpa.free(t);
            gpa.free(result.suggestedNext);
        }

        const escaped_next = try root.allocJsonEscape(gpa, result.suggestedNext);
        defer gpa.free(escaped_next);

        try out.writeAll("{\n");
        if (result.latestTag) |tag| {
            const escaped_tag = try root.allocJsonEscape(gpa, tag);
            defer gpa.free(escaped_tag);
            try out.print("  \"latestTag\": \"{s}\",\n", .{escaped_tag});
        } else {
            try out.writeAll("  \"latestTag\": null,\n");
        }
        try out.print(
            "  \"suggestedNext\": \"{s}\",\n  \"commitsSince\": {d},\n  \"isDirty\": {s}\n}}\n",
            .{ escaped_next, result.commitsSince, if (result.isDirty) "true" else "false" },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "tag-exists")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools tag-exists <repo-path> <tag>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeTagExists(gpa, io, args[2], args[3]) catch {
            try err.print("error: not a git repository: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };

        try out.print(
            "{{\n  \"exists\": {s}\n}}\n",
            .{if (result.exists) "true" else "false"},
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "repo-info")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools repo-info <repo-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeRepoInfo(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.NoRemote => try err.print("error: no remote 'origin' in: {s}\n", .{args[2]}),
                error.UnparsableRemote => try err.print("error: could not parse remote URL in: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            gpa.free(result.owner);
            gpa.free(result.repo);
            gpa.free(result.url);
        }

        const escaped_owner = try root.allocJsonEscape(gpa, result.owner);
        defer gpa.free(escaped_owner);
        const escaped_repo = try root.allocJsonEscape(gpa, result.repo);
        defer gpa.free(escaped_repo);
        const escaped_url = try root.allocJsonEscape(gpa, result.url);
        defer gpa.free(escaped_url);

        try out.print(
            "{{\n  \"owner\": \"{s}\",\n  \"repo\": \"{s}\",\n  \"url\": \"{s}\"\n}}\n",
            .{ escaped_owner, escaped_repo, escaped_url },
        );
        try out.flush();
    } else {
        try err.print("unknown subcommand: {s}\n", .{args[1]});
        try err.flush();
        std.process.exit(1);
    }
}
