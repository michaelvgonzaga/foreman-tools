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
        try err.print("  json-query <file-path> <dot-path>\n", .{});
        try err.print("  git-diff <repo-path> [ref]\n", .{});
        try err.print("  list-dir <path>\n", .{});
        try err.print("  file-stats <file-path>\n", .{});
        try err.print("  env-scan <root-path>\n", .{});
        try err.print("  toml-query <file-path> <dot-path>\n", .{});
        try err.print("  list-projects <foreman-root>\n", .{});
        try err.print("  tarball-sha <owner> <repo> <tag>\n", .{});
        try err.print("  formula-info <tap-path> <formula-name>\n", .{});
        try err.print("  validate-hooks\n", .{});
        try err.print("  gh-release <owner> <repo> <tag> <title> <notes-file>\n", .{});
        try err.print("  file-hash <file-path>\n", .{});
        try err.print("  context-scan <path>\n", .{});
        try err.print("  context-evidence <file-path> <pattern>\n", .{});
        try err.print("  cache-check <file-path>\n", .{});
        try err.print("  cache-store <file-path> <sub-key>  (value JSON from stdin)\n", .{});
        try err.print("  cache-fetch <file-path> <sub-key>\n", .{});
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
    } else if (std.mem.eql(u8, args[1], "json-query")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools json-query <file-path> <dot-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeJsonQuery(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                error.InvalidJson  => try err.print("error: invalid JSON: {s}\n", .{args[2]}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer if (result.value_json) |v| gpa.free(v);

        const escaped_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(escaped_path);

        if (result.found) {
            try out.print(
                "{{\n  \"path\": \"{s}\",\n  \"found\": true,\n  \"type\": \"{s}\",\n  \"value\": {s}\n}}\n",
                .{ escaped_path, result.type_name, result.value_json.? },
            );
        } else {
            try out.print(
                "{{\n  \"path\": \"{s}\",\n  \"found\": false,\n  \"type\": null,\n  \"value\": null\n}}\n",
                .{escaped_path},
            );
        }
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "git-diff")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools git-diff <repo-path> [ref]\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const ref: []const u8 = if (args.len >= 4) args[3] else "";
        const result = root.computeGitDiff(gpa, io, args[2], ref) catch |e| {
            switch (e) {
                error.GitFailed => try err.print("error: git diff failed in: {s}\n", .{args[2]}),
                else            => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.files) |f| gpa.free(f.path);
            gpa.free(result.files);
        }

        const escaped_ref = try root.allocJsonEscape(gpa, result.ref);
        defer gpa.free(escaped_ref);

        try out.print(
            "{{\n  \"ref\": \"{s}\",\n  \"totalAdditions\": {d},\n  \"totalDeletions\": {d},\n  \"fileCount\": {d},\n  \"files\": [\n",
            .{ escaped_ref, result.totalAdditions, result.totalDeletions, result.fileCount },
        );
        for (result.files, 0..) |f, i| {
            const escaped_path = try root.allocJsonEscape(gpa, f.path);
            defer gpa.free(escaped_path);
            try out.print(
                "    {{\"path\": \"{s}\", \"additions\": {d}, \"deletions\": {d}, \"status\": \"{s}\"}}",
                .{ escaped_path, f.additions, f.deletions, f.status },
            );
            if (i + 1 < result.files.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "list-dir")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools list-dir <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeListDir(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.PathNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.entries) |e| gpa.free(e.name);
            gpa.free(result.entries);
        }

        const escaped_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(escaped_path);

        try out.print(
            "{{\n  \"path\": \"{s}\",\n  \"count\": {d},\n  \"entries\": [\n",
            .{ escaped_path, result.count },
        );
        for (result.entries, 0..) |e, i| {
            const escaped_name = try root.allocJsonEscape(gpa, e.name);
            defer gpa.free(escaped_name);
            if (std.mem.eql(u8, e.kind, "file")) {
                try out.print(
                    "    {{\"name\": \"{s}\", \"kind\": \"{s}\", \"bytes\": {d}}}",
                    .{ escaped_name, e.kind, e.bytes },
                );
            } else {
                try out.print(
                    "    {{\"name\": \"{s}\", \"kind\": \"{s}\"}}",
                    .{ escaped_name, e.kind },
                );
            }
            if (i + 1 < result.entries.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "file-stats")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools file-stats <file-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeFileStats(gpa, io, args[2]) catch {
            try err.print("error: file not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };

        const escaped_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(escaped_path);
        try out.print(
            "{{\n  \"path\": \"{s}\",\n  \"lines\": {d},\n  \"bytes\": {d}\n}}\n",
            .{ escaped_path, result.lines, result.bytes },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "env-scan")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools env-scan <root-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeEnvScan(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.RootNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.files) |ef| {
                gpa.free(ef.file);
                for (ef.keys) |k| gpa.free(k);
                gpa.free(ef.keys);
            }
            gpa.free(result.files);
        }

        const escaped_root = try root.allocJsonEscape(gpa, result.root);
        defer gpa.free(escaped_root);

        try out.print(
            "{{\n  \"root\": \"{s}\",\n  \"fileCount\": {d},\n  \"files\": [\n",
            .{ escaped_root, result.fileCount },
        );
        for (result.files, 0..) |ef, i| {
            const escaped_file = try root.allocJsonEscape(gpa, ef.file);
            defer gpa.free(escaped_file);
            try out.print(
                "    {{\"file\": \"{s}\", \"keyCount\": {d}, \"keys\": [",
                .{ escaped_file, ef.keyCount },
            );
            for (ef.keys, 0..) |k, ki| {
                const escaped_key = try root.allocJsonEscape(gpa, k);
                defer gpa.free(escaped_key);
                if (ki > 0) try out.writeAll(", ");
                try out.print("\"{s}\"", .{escaped_key});
            }
            try out.writeAll("]}");
            if (i + 1 < result.files.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "toml-query")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools toml-query <file-path> <dot-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeTomlQuery(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer if (result.value_json) |v| gpa.free(v);

        const escaped_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(escaped_path);

        if (result.found) {
            try out.print(
                "{{\n  \"path\": \"{s}\",\n  \"found\": true,\n  \"type\": \"{s}\",\n  \"value\": {s}\n}}\n",
                .{ escaped_path, result.type_name, result.value_json.? },
            );
        } else {
            try out.print(
                "{{\n  \"path\": \"{s}\",\n  \"found\": false,\n  \"type\": null,\n  \"value\": null\n}}\n",
                .{escaped_path},
            );
        }
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "list-projects")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools list-projects <foreman-root>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const entries = try root.computeListProjects(gpa, io, args[2]);
        defer {
            for (entries) |e| {
                gpa.free(e.name);
                gpa.free(e.url);
            }
            gpa.free(entries);
        }

        try out.writeAll("[\n");
        for (entries, 0..) |entry, i| {
            const escaped_name = try root.allocJsonEscape(gpa, entry.name);
            defer gpa.free(escaped_name);
            const escaped_url = try root.allocJsonEscape(gpa, entry.url);
            defer gpa.free(escaped_url);

            try out.print(
                "  {{\"name\": \"{s}\", \"url\": \"{s}\", \"isForeman\": {s}, \"isLocal\": {s}}}",
                .{
                    escaped_name,
                    escaped_url,
                    if (entry.isForeman) "true" else "false",
                    if (entry.isLocal) "true" else "false",
                },
            );
            if (i + 1 < entries.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("]\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "tarball-sha")) {
        if (args.len < 5) {
            try err.print("usage: foreman-tools tarball-sha <owner> <repo> <tag>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeTarballSha(gpa, io, args[2], args[3], args[4]) catch |e| {
            switch (e) {
                error.FetchFailed => try err.print("error: failed to fetch tarball (tag not yet available?)\n", .{}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(result.sha256);
        defer gpa.free(result.url);

        const escaped_sha = try root.allocJsonEscape(gpa, result.sha256);
        defer gpa.free(escaped_sha);
        const escaped_url = try root.allocJsonEscape(gpa, result.url);
        defer gpa.free(escaped_url);

        try out.print(
            "{{\n  \"sha256\": \"{s}\",\n  \"url\": \"{s}\"\n}}\n",
            .{ escaped_sha, escaped_url },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "formula-info")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools formula-info <tap-path> <formula-name>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeFormulaInfo(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FormulaNotFound => try err.print("error: formula file not found: {s}/Formula/{s}.rb\n", .{ args[2], args[3] }),
                error.MissingField => try err.print("error: formula missing required field (url, sha256, or version)\n", .{}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(result.formulaPath);
        defer gpa.free(result.url);
        defer gpa.free(result.sha256);
        defer gpa.free(result.version);

        const esc_path = try root.allocJsonEscape(gpa, result.formulaPath);
        defer gpa.free(esc_path);
        const esc_url = try root.allocJsonEscape(gpa, result.url);
        defer gpa.free(esc_url);
        const esc_sha = try root.allocJsonEscape(gpa, result.sha256);
        defer gpa.free(esc_sha);
        const esc_ver = try root.allocJsonEscape(gpa, result.version);
        defer gpa.free(esc_ver);

        try out.print(
            "{{\n  \"formulaPath\": \"{s}\",\n  \"url\": \"{s}\",\n  \"sha256\": \"{s}\",\n  \"version\": \"{s}\"\n}}\n",
            .{ esc_path, esc_url, esc_sha, esc_ver },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "validate-hooks")) {
        const result = root.computeValidateHooks(gpa, io) catch |e| {
            switch (e) {
                error.NoHome => try err.print("error: HOME environment variable not set\n", .{}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };

        try out.print(
            "{{\n  \"memorySync\": {s},\n  \"autoPush\": {s}\n}}\n",
            .{
                if (result.memorySync) "true" else "false",
                if (result.autoPush) "true" else "false",
            },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "gh-release")) {
        if (args.len < 7) {
            try err.print("usage: foreman-tools gh-release <owner> <repo> <tag> <title> <notes-file>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeGhRelease(gpa, io, args[2], args[3], args[4], args[5], args[6]) catch |e| {
            switch (e) {
                error.NotesFileNotFound => try err.print("error: notes file not found: {s}\n", .{args[6]}),
                error.GhFailed => try err.print("error: gh release create failed (check gh auth and tag existence)\n", .{}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(result.url);

        const esc_url = try root.allocJsonEscape(gpa, result.url);
        defer gpa.free(esc_url);

        try out.print("{{\n  \"url\": \"{s}\"\n}}\n", .{esc_url});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "file-hash")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools file-hash <file-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeFileHash(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(result.path);
        defer gpa.free(result.sha256);

        const esc_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(esc_path);
        const esc_sha = try root.allocJsonEscape(gpa, result.sha256);
        defer gpa.free(esc_sha);

        try out.print(
            "{{\n  \"path\": \"{s}\",\n  \"sha256\": \"{s}\",\n  \"bytes\": {d}\n}}\n",
            .{ esc_path, esc_sha, result.bytes },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-scan")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools context-scan <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeContextScan(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            if (result.entryPoint) |ep| gpa.free(ep);
            for (result.topFiles) |f| gpa.free(f.path);
            gpa.free(result.topFiles);
            for (result.keyFiles) |f| gpa.free(f);
            gpa.free(result.keyFiles);
            for (result.dirs) |d| gpa.free(d);
            gpa.free(result.dirs);
        }

        const esc_fw = try root.allocJsonEscape(gpa, result.framework);
        defer gpa.free(esc_fw);

        try out.print("{{\n  \"framework\": \"{s}\",\n", .{esc_fw});

        if (result.entryPoint) |ep| {
            const esc_ep = try root.allocJsonEscape(gpa, ep);
            defer gpa.free(esc_ep);
            try out.print("  \"entryPoint\": \"{s}\",\n", .{esc_ep});
        } else {
            try out.writeAll("  \"entryPoint\": null,\n");
        }

        try out.print(
            "  \"fileCount\": {d},\n  \"summary\": {{\"source\": {d}, \"test\": {d}, \"config\": {d}, \"docs\": {d}, \"other\": {d}}},\n",
            .{ result.fileCount, result.summary.source, result.summary.@"test", result.summary.config, result.summary.docs, result.summary.other },
        );

        try out.writeAll("  \"topFiles\": [\n");
        for (result.topFiles, 0..) |f, i| {
            const esc_p = try root.allocJsonEscape(gpa, f.path);
            defer gpa.free(esc_p);
            try out.print("    {{\"path\": \"{s}\", \"bytes\": {d}}}", .{ esc_p, f.bytes });
            if (i + 1 < result.topFiles.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ],\n  \"keyFiles\": [");
        for (result.keyFiles, 0..) |f, i| {
            const esc = try root.allocJsonEscape(gpa, f);
            defer gpa.free(esc);
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{esc});
        }
        try out.writeAll("],\n  \"dirs\": [");
        for (result.dirs, 0..) |d, i| {
            const esc = try root.allocJsonEscape(gpa, d);
            defer gpa.free(esc);
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{esc});
        }
        try out.writeAll("]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-evidence")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools context-evidence <file-path> <pattern>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeContextEvidence(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            gpa.free(result.path);
            gpa.free(result.pattern);
            for (result.chunks) |c| gpa.free(c.content);
            gpa.free(result.chunks);
        }

        const esc_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(esc_path);
        const esc_pat = try root.allocJsonEscape(gpa, result.pattern);
        defer gpa.free(esc_pat);

        try out.print(
            "{{\n  \"path\": \"{s}\",\n  \"pattern\": \"{s}\",\n  \"fileBytes\": {d},\n  \"matchCount\": {d},\n  \"chunks\": [\n",
            .{ esc_path, esc_pat, result.fileBytes, result.matchCount },
        );
        for (result.chunks, 0..) |chunk, i| {
            const esc_content = try root.allocJsonEscape(gpa, chunk.content);
            defer gpa.free(esc_content);
            try out.print(
                "    {{\"startLine\": {d}, \"endLine\": {d}, \"content\": \"{s}\"}}",
                .{ chunk.startLine, chunk.endLine, esc_content },
            );
            if (i + 1 < result.chunks.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "cache-check")) {
        if (args.len < 3) {
            try err.print("usage: foreman-tools cache-check <file-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeCacheCheck(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                error.NoHome       => try err.print("error: HOME environment variable not set\n", .{}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(result.path);
        defer gpa.free(result.sha256);

        const esc_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(esc_path);
        const esc_sha = try root.allocJsonEscape(gpa, result.sha256);
        defer gpa.free(esc_sha);

        try out.print(
            "{{\n  \"path\": \"{s}\",\n  \"sha256\": \"{s}\",\n  \"changed\": {s},\n  \"cached\": {s}\n}}\n",
            .{
                esc_path,
                esc_sha,
                if (result.changed) "true" else "false",
                if (result.cached) "true" else "false",
            },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "cache-store")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools cache-store <file-path> <sub-key>  (value JSON from stdin)\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        var stdin_buf: [4096]u8 = undefined;
        var stdin_rdr = std.Io.File.stdin().reader(io, &stdin_buf);
        const value_json = stdin_rdr.interface.allocRemaining(gpa, .limited(512 * 1024)) catch |e| {
            try err.print("error reading stdin: {}\n", .{e});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(value_json);

        const result = root.computeCacheStore(gpa, io, args[2], args[3], value_json) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                error.NoHome       => try err.print("error: HOME environment variable not set\n", .{}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(result.path);
        defer gpa.free(result.subKey);

        const esc_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(esc_path);
        const esc_key = try root.allocJsonEscape(gpa, result.subKey);
        defer gpa.free(esc_key);

        try out.print(
            "{{\n  \"path\": \"{s}\",\n  \"subKey\": \"{s}\",\n  \"stored\": {s}\n}}\n",
            .{ esc_path, esc_key, if (result.stored) "true" else "false" },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "cache-fetch")) {
        if (args.len < 4) {
            try err.print("usage: foreman-tools cache-fetch <file-path> <sub-key>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeCacheFetch(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                error.NoHome       => try err.print("error: HOME environment variable not set\n", .{}),
                else               => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(result.path);
        defer gpa.free(result.subKey);
        defer if (result.value) |v| gpa.free(v);

        const esc_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(esc_path);
        const esc_key = try root.allocJsonEscape(gpa, result.subKey);
        defer gpa.free(esc_key);

        if (result.hit) {
            try out.print(
                "{{\n  \"path\": \"{s}\",\n  \"subKey\": \"{s}\",\n  \"hit\": true,\n  \"value\": {s}\n}}\n",
                .{ esc_path, esc_key, result.value.? },
            );
        } else {
            try out.print(
                "{{\n  \"path\": \"{s}\",\n  \"subKey\": \"{s}\",\n  \"hit\": false,\n  \"value\": null\n}}\n",
                .{ esc_path, esc_key },
            );
        }
        try out.flush();
    } else {
        try err.print("unknown subcommand: {s}\n", .{args[1]});
        try err.flush();
        std.process.exit(1);
    }
}
