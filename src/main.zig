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
        try err.print("  changes-preview <repo-path>\n", .{});
        try err.print("  scan <path>\n", .{});
        try err.print("  diff-dirs <path1> <path2>\n", .{});
        try err.print("  grep <root-path> <pattern> [ext-filter]\n", .{});
        try err.print("  parse-stack\n", .{});
        try err.print("  find-files <root-path> <glob>\n", .{});
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
    } else if (std.mem.eql(u8, args[1], "changes-preview")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools changes-preview <repo-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = try root.computeChangesPreview(gpa, io, args[2]);
        defer {
            for (result.commits) |e| {
                gpa.free(e.hash);
                gpa.free(e.message);
            }
            gpa.free(result.commits);
        }

        try out.writeAll("{\n  \"commits\": [\n");
        for (result.commits, 0..) |entry, i| {
            const escaped_hash = try root.allocJsonEscape(gpa, entry.hash);
            defer gpa.free(escaped_hash);
            const escaped_msg = try root.allocJsonEscape(gpa, entry.message);
            defer gpa.free(escaped_msg);

            try out.print(
                "    {{\"hash\": \"{s}\", \"category\": \"{s}\", \"message\": \"{s}\"}}",
                .{ escaped_hash, entry.category, escaped_msg },
            );
            if (i + 1 < result.commits.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.print("  ],\n  \"filesChanged\": {d}\n}}\n", .{result.filesChanged});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "scan")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools scan <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeScan(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.keyFiles) |f| gpa.free(f);
            gpa.free(result.keyFiles);
            for (result.dirMap) |d| gpa.free(d);
            gpa.free(result.dirMap);
            if (result.entryPoint) |ep| gpa.free(ep);
            for (result.files) |f| gpa.free(f.path);
            gpa.free(result.files);
        }

        const escaped_fw = try root.allocJsonEscape(gpa, result.framework);
        defer gpa.free(escaped_fw);

        try out.print("{{\n  \"framework\": \"{s}\",\n  \"keyFiles\": [", .{escaped_fw});
        for (result.keyFiles, 0..) |f, i| {
            const escaped = try root.allocJsonEscape(gpa, f);
            defer gpa.free(escaped);
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{escaped});
        }
        try out.print("],\n  \"depCount\": {d},\n  \"dirMap\": [", .{result.depCount});
        for (result.dirMap, 0..) |d, i| {
            const escaped = try root.allocJsonEscape(gpa, d);
            defer gpa.free(escaped);
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{escaped});
        }
        if (result.entryPoint) |ep| {
            const escaped_ep = try root.allocJsonEscape(gpa, ep);
            defer gpa.free(escaped_ep);
            try out.print("],\n  \"entryPoint\": \"{s}\",\n  \"fileCount\": {d},\n  \"files\": [\n", .{ escaped_ep, result.fileCount });
        } else {
            try out.print("],\n  \"entryPoint\": null,\n  \"fileCount\": {d},\n  \"files\": [\n", .{result.fileCount});
        }
        for (result.files, 0..) |f, i| {
            const escaped_path = try root.allocJsonEscape(gpa, f.path);
            defer gpa.free(escaped_path);
            try out.print(
                "    {{\"path\": \"{s}\", \"bytes\": {d}, \"kind\": \"{s}\"}}",
                .{ escaped_path, f.bytes, f.kind },
            );
            if (i + 1 < result.files.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "diff-dirs")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools diff-dirs <path1> <path2>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeDiffDirs(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.PathANotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                error.PathBNotFound => try err.print("error: path not found: {s}\n", .{args[3]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.onlyInA) |p| gpa.free(p);
            gpa.free(result.onlyInA);
            for (result.onlyInB) |p| gpa.free(p);
            gpa.free(result.onlyInB);
            for (result.inBoth) |e2| gpa.free(e2.path);
            gpa.free(result.inBoth);
        }

        try out.writeAll("{\"onlyInA\": [");
        for (result.onlyInA, 0..) |p, i| {
            const escaped = try root.allocJsonEscape(gpa, p);
            defer gpa.free(escaped);
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{escaped});
        }
        try out.writeAll("], \"onlyInB\": [");
        for (result.onlyInB, 0..) |p, i| {
            const escaped = try root.allocJsonEscape(gpa, p);
            defer gpa.free(escaped);
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{escaped});
        }
        try out.writeAll("], \"inBoth\": [\n");
        for (result.inBoth, 0..) |entry, i| {
            const escaped_path = try root.allocJsonEscape(gpa, entry.path);
            defer gpa.free(escaped_path);
            try out.print(
                "  {{\"path\": \"{s}\", \"bytesA\": {d}, \"bytesB\": {d}, \"same\": {s}}}",
                .{ escaped_path, entry.bytesA, entry.bytesB, if (entry.same) "true" else "false" },
            );
            if (i + 1 < result.inBoth.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("]}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "grep")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools grep <root-path> <pattern> [ext-filter]\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const ext_filter: ?[]const u8 = if (args.len >= 5) args[4] else null;
        const result = root.computeGrep(gpa, io, args[2], args[3], ext_filter) catch |e| {
            switch (e) {
                error.RootNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.matches) |m| { gpa.free(m.file); gpa.free(m.text); }
            gpa.free(result.matches);
        }

        const escaped_pattern = try root.allocJsonEscape(gpa, result.pattern);
        defer gpa.free(escaped_pattern);

        try out.print(
            "{{\n  \"pattern\": \"{s}\",\n  \"matchCount\": {d},\n  \"capped\": {s},\n  \"matches\": [\n",
            .{ escaped_pattern, result.matchCount, if (result.capped) "true" else "false" },
        );
        for (result.matches, 0..) |m, i| {
            const escaped_file = try root.allocJsonEscape(gpa, m.file);
            defer gpa.free(escaped_file);
            const escaped_text = try root.allocJsonEscape(gpa, m.text);
            defer gpa.free(escaped_text);
            try out.print(
                "    {{\"file\": \"{s}\", \"line\": {d}, \"col\": {d}, \"text\": \"{s}\"}}",
                .{ escaped_file, m.line, m.col, escaped_text },
            );
            if (i + 1 < result.matches.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "parse-stack")) {
        // Read stdin
        var stdin_read_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_read_buf);
        const input = stdin_reader.interface.allocRemaining(gpa, .limited(512 * 1024)) catch |e| {
            try err.print("error reading stdin: {}\n", .{e});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(input);

        const result = root.computeParseStack(gpa, input) catch |e| {
            try err.print("error: {}\n", .{e});
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.frames) |f| { gpa.free(f.file); gpa.free(f.func); }
            gpa.free(result.frames);
        }

        try out.writeAll("[\n");
        for (result.frames, 0..) |frame, i| {
            const escaped_file = try root.allocJsonEscape(gpa, frame.file);
            defer gpa.free(escaped_file);
            const escaped_func = try root.allocJsonEscape(gpa, frame.func);
            defer gpa.free(escaped_func);
            try out.print(
                "  {{\"file\": \"{s}\", \"line\": {d}, \"col\": {d}, \"fn\": \"{s}\"}}",
                .{ escaped_file, frame.line, frame.col, escaped_func },
            );
            if (i + 1 < result.frames.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("]\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "find-files")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools find-files <root-path> <glob>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeFindFiles(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.RootNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.files) |p| gpa.free(p);
            gpa.free(result.files);
        }

        const escaped_pattern = try root.allocJsonEscape(gpa, result.pattern);
        defer gpa.free(escaped_pattern);

        try out.print(
            "{{\n  \"pattern\": \"{s}\",\n  \"count\": {d},\n  \"capped\": {s},\n  \"files\": [\n",
            .{ escaped_pattern, result.count, if (result.capped) "true" else "false" },
        );
        for (result.files, 0..) |p, i| {
            const escaped = try root.allocJsonEscape(gpa, p);
            defer gpa.free(escaped);
            try out.print("    \"{s}\"", .{escaped});
            if (i + 1 < result.files.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else {
        try err.print("unknown subcommand: {s}\n", .{args[1]});
        try err.flush();
        std.process.exit(1);
    }
}
