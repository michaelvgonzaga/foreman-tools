const std = @import("std");
const root = @import("4orman_tools");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    root.migrateStateDir(gpa, io);

    var err_buf: [512]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_writer.interface;

    var out_buf: [65536]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    if (args.len < 2) {
        try err.print("usage: 4orman-tools <subcommand> [args]\n", .{});
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
        try err.print("  yaml-query <file-path> <dot-path>\n", .{});
        try err.print("  list-projects <4orman-root>\n", .{});
        try err.print("  tarball-sha <owner> <repo> <tag>\n", .{});
        try err.print("  formula-info <tap-path> <formula-name>\n", .{});
        try err.print("  validate-hooks\n", .{});
        try err.print("  gh-release <owner> <repo> <tag> <title> <notes-file>\n", .{});
        try err.print("  file-hash <file-path>\n", .{});
        try err.print("  context-scan <path>\n", .{});
        try err.print("  context-rank <root-path> <query>\n", .{});
        try err.print("  context-changed <repo-path> [ref]\n", .{});
        try err.print("  context-evidence <file-path> <pattern>\n", .{});
        try err.print("  context-budget <file-path> [<file-path>...]\n", .{});
        try err.print("  context-gate <path> --task \"<task description>\"\n", .{});
        try err.print("  context-classifier \"<task description>\"\n", .{});
        try err.print("  context-dependency-graph <root-path> <rel-file-path>\n", .{});
        try err.print("  context-compressor <file-path> [--max-lines N]\n", .{});
        try err.print("  cache-check <file-path>\n", .{});
        try err.print("  cache-store <file-path> <sub-key>  (value JSON from stdin)\n", .{});
        try err.print("  cache-fetch <file-path> <sub-key>\n", .{});
        try err.print("  outline <file-path>\n", .{});
        try err.print("  deps <root-path>\n", .{});
        try err.print("  compat-check [--baseline | --update-baseline]\n", .{});
        try err.print("  run-tests <path>\n", .{});
        try err.print("  build <path>\n", .{});
        try err.print("  env-inspect <path>\n", .{});
        try err.print("  symbol-find <path> <symbol>\n", .{});
        try err.print("  secret-scan <path>\n", .{});
        try err.print("  device-scan\n", .{});
        try err.print("  delta-context <repo-path> [ref]\n", .{});
        try err.print("  git-cache <repo-path>\n", .{});
        try err.print("  project-state <path> [record-decision <what> [<why>]]\n", .{});
        try err.print("  project-state <path> [record-pattern <pattern>]\n", .{});
        try err.print("  ledger [show | record <winner> <question> <reasoning> | record-jungian <question> <chosen> <shadow> <synthesis> | record-outcome <id> <outcome> <matched|diverged> | check-stale | validate <id> | score <question> <sources-json>]\n", .{});
        try err.print("  shell-run [--timeout <ms>] <shell-command>\n", .{});
        try err.print("  quality-gate <path>\n", .{});
        try err.print("  validate-schema <file> <schema>\n", .{});
        try err.print("  prod-ready <path>\n", .{});
        try err.print("  registry\n", .{});
        try err.print("  capability-check <query...>\n", .{});
        try err.print("  route <task...>\n", .{});
        try err.print("  report <path>\n", .{});
        try err.print("  metrics\n", .{});
        try err.print("  session-snapshot <4orman-root>\n", .{});
        try err.print("  sandbox-check <command...>\n", .{});
        try err.print("  rollback <repo-path> [--list | --revert <id>]\n", .{});
        try err.print("  capability-promote <command...>\n", .{});
        try err.print("  ant <path> [--since <ms>]\n", .{});
        try err.print("  worker-run <lang> <script> [args...]   langs: python,node,deno,bun,go,ruby,bash,swift,zig,lua,php\n", .{});
        try err.print("  worker-list\n", .{});
        try err.print("  plugin-run <name> [args...]            run a plugin from ~/.4orman/plugins/\n", .{});
        try err.print("  plugin-list\n", .{});
        try err.print("  context-slice <abs-path> <focus-query>\n", .{});
        try err.print("  state-merge <file1> <file2>\n", .{});
        try err.print("  tui [<4orman-root>]\n", .{});
        try err.print("  knowledge-audit <project-path> [<4orman-root>]\n", .{});
        try err.print("  export <project-path> [--format fmz|brew|mac|linux|windows|backup] [--out <dir>]\n", .{});
        try err.print("  import <source-path> [<4orman-root>]\n", .{});
        try err.print("  promotion-queue [list | add <name> <description> | clear]\n", .{});
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
            try err.print("usage: 4orman-tools status <workspace-path>\n", .{});
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
            try err.print("usage: 4orman-tools commits <repo-path> [since-tag]\n", .{});
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
            try err.print("usage: 4orman-tools release-info <repo-path>\n", .{});
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
            try err.print("usage: 4orman-tools tag-exists <repo-path> <tag>\n", .{});
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
            try err.print("usage: 4orman-tools repo-info <repo-path>\n", .{});
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
            try err.print("usage: 4orman-tools changes-preview <repo-path>\n", .{});
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
            try err.print("usage: 4orman-tools scan <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = root.computeScan(gpa, io, abs_path) catch |e| {
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
            try err.print("usage: 4orman-tools diff-dirs <path1> <path2>\n", .{});
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
            try err.print("usage: 4orman-tools grep <root-path> <pattern> [ext-filter]\n", .{});
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
            for (result.matches) |m| {
                gpa.free(m.file);
                gpa.free(m.text);
            }
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
            for (result.frames) |f| {
                gpa.free(f.file);
                gpa.free(f.func);
            }
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
            try err.print("usage: 4orman-tools find-files <root-path> <glob>\n", .{});
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
            try err.print("usage: 4orman-tools json-query <file-path> <dot-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeJsonQuery(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                error.InvalidJson => try err.print("error: invalid JSON: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
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
            try err.print("usage: 4orman-tools git-diff <repo-path> [ref]\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const ref: []const u8 = if (args.len >= 4) args[3] else "";
        const result = root.computeGitDiff(gpa, io, args[2], ref) catch |e| {
            switch (e) {
                error.GitFailed => try err.print("error: git diff failed in: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
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
            try err.print("usage: 4orman-tools list-dir <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeListDir(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.PathNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
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
            try err.print("usage: 4orman-tools file-stats <file-path>\n", .{});
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
            try err.print("usage: 4orman-tools env-scan <root-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeEnvScan(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.RootNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
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
            try err.print("usage: 4orman-tools toml-query <file-path> <dot-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeTomlQuery(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
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
    } else if (std.mem.eql(u8, args[1], "yaml-query")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools yaml-query <file-path> <dot-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeYamlQuery(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
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
            try err.print("usage: 4orman-tools list-projects <4orman-root>\n", .{});
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
            try err.print("usage: 4orman-tools tarball-sha <owner> <repo> <tag>\n", .{});
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
            try err.print("usage: 4orman-tools formula-info <tap-path> <formula-name>\n", .{});
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
            try err.print("usage: 4orman-tools gh-release <owner> <repo> <tag> <title> <notes-file>\n", .{});
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
            try err.print("usage: 4orman-tools file-hash <file-path>\n", .{});
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
            try err.print("usage: 4orman-tools context-scan <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = root.computeContextScan(gpa, io, abs_path) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
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
    } else if (std.mem.eql(u8, args[1], "context-rank")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools context-rank <root-path> <query>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeContextRank(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            gpa.free(result.root);
            gpa.free(result.query);
            for (result.ranked) |f| gpa.free(f.path);
            gpa.free(result.ranked);
        }

        const esc_root = try root.allocJsonEscape(gpa, result.root);
        defer gpa.free(esc_root);
        const esc_query = try root.allocJsonEscape(gpa, result.query);
        defer gpa.free(esc_query);

        try out.print(
            "{{\n  \"root\": \"{s}\",\n  \"query\": \"{s}\",\n  \"fileCount\": {d},\n  \"ranked\": [\n",
            .{ esc_root, esc_query, result.fileCount },
        );
        for (result.ranked, 0..) |f, i| {
            const esc_path = try root.allocJsonEscape(gpa, f.path);
            defer gpa.free(esc_path);
            try out.print(
                "    {{\"path\": \"{s}\", \"score\": {d}, \"hits\": {d}, \"nameMatch\": {s}, \"kind\": \"{s}\", \"bytes\": {d}}}",
                .{ esc_path, f.score, f.hits, if (f.nameMatch) "true" else "false", f.kind, f.bytes },
            );
            if (i + 1 < result.ranked.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-changed")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools context-changed <repo-path> [ref]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const ref = if (args.len >= 4) args[3] else "HEAD";

        const result = root.computeContextChanged(gpa, io, args[2], ref) catch |e| {
            switch (e) {
                error.GitFailed => try err.print("error: git command failed in: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.files) |f| {
                gpa.free(f.path);
                gpa.free(f.diff);
            }
            gpa.free(result.files);
        }

        const esc_ref = try root.allocJsonEscape(gpa, result.ref);
        defer gpa.free(esc_ref);

        try out.print(
            "{{\n  \"ref\": \"{s}\",\n  \"totalFiles\": {d},\n  \"totalAdditions\": {d},\n  \"totalDeletions\": {d},\n  \"truncated\": {s},\n  \"files\": [\n",
            .{ esc_ref, result.totalFiles, result.totalAdditions, result.totalDeletions, if (result.truncated) "true" else "false" },
        );
        for (result.files, 0..) |f, i| {
            const esc_path = try root.allocJsonEscape(gpa, f.path);
            defer gpa.free(esc_path);
            const esc_diff = try root.allocJsonEscape(gpa, f.diff);
            defer gpa.free(esc_diff);
            try out.print(
                "    {{\"path\": \"{s}\", \"status\": \"{s}\", \"additions\": {d}, \"deletions\": {d}, \"diff\": \"{s}\"}}",
                .{ esc_path, f.status, f.additions, f.deletions, esc_diff },
            );
            if (i + 1 < result.files.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-evidence")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools context-evidence <file-path> <pattern>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeContextEvidence(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
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
    } else if (std.mem.eql(u8, args[1], "context-budget")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools context-budget <file-path> [<file-path>...]\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = try root.computeContextBudget(gpa, io, args[2..]);
        defer {
            for (result.breakdown) |e| gpa.free(e.path);
            gpa.free(result.breakdown);
        }

        try out.print("{{\n  \"tokenEstimate\": {d},\n  \"risk\": \"{s}\",\n  \"breakdown\": [\n", .{ result.tokenEstimate, result.risk });
        for (result.breakdown, 0..) |e, i| {
            const esc_path = try root.allocJsonEscape(gpa, e.path);
            defer gpa.free(esc_path);
            try out.print("    {{\"path\": \"{s}\", \"bytes\": {d}, \"tokens\": {d}}}", .{ esc_path, e.bytes, e.tokens });
            if (i + 1 < result.breakdown.len) try out.writeAll(",");
            try out.writeAll("\n");
        }
        try out.writeAll("  ]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-gate")) {
        var task: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--task") and i + 1 < args.len) {
                task = args[i + 1];
                i += 1;
            }
        }

        if (args.len < 3 or task == null) {
            try err.print("usage: 4orman-tools context-gate <path> --task \"<task description>\"\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeContextGate(gpa, io, args[2], task.?) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            gpa.free(result.task);
            for (result.includeFiles) |f| gpa.free(f);
            gpa.free(result.includeFiles);
            gpa.free(result.reason);
        }

        const esc_task = try root.allocJsonEscape(gpa, result.task);
        defer gpa.free(esc_task);
        const esc_reason = try root.allocJsonEscape(gpa, result.reason);
        defer gpa.free(esc_reason);

        try out.print(
            "{{\n  \"task\": \"{s}\",\n  \"token_estimate\": {d},\n  \"risk\": \"{s}\",\n  \"include\": {{\n    \"files\": [",
            .{ esc_task, result.tokenEstimate, result.risk },
        );
        for (result.includeFiles, 0..) |f, fi| {
            const esc_f = try root.allocJsonEscape(gpa, f);
            defer gpa.free(esc_f);
            if (fi > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{esc_f});
        }
        try out.print(
            "],\n    \"errors\": [],\n    \"diff\": {s}\n  }},\n  \"exclude\": {{\n    \"dirs\": [\"zig-cache\", \".zig-cache\", \"zig-out\", \".git\", \"node_modules\"],\n    \"large_files\": true,\n    \"secrets\": {s}\n  }},\n  \"next_action\": {{\n    \"send_to_ai\": {s},\n    \"reason\": \"{s}\"\n  }}\n}}\n",
            .{
                if (result.includeDiff) "true" else "false",
                if (result.excludeSecrets) "true" else "false",
                if (result.sendToAi) "true" else "false",
                esc_reason,
            },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-classifier")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools context-classifier \"<task description>\"\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = try root.computeContextClassifier(gpa, args[2]);
        defer gpa.free(result.signals);

        try out.print("{{\n  \"task_type\": \"{s}\",\n  \"confidence\": {d:.2},\n  \"signals\": [", .{ result.taskType, result.confidence });
        for (result.signals, 0..) |s, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{s});
        }
        try out.writeAll("]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-dependency-graph")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools context-dependency-graph <root-path> <rel-file-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeContextDependencyGraph(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[3]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            gpa.free(result.root);
            for (result.imports) |imp| gpa.free(imp);
            gpa.free(result.imports);
            for (result.importedBy) |p| gpa.free(p);
            gpa.free(result.importedBy);
        }

        const esc_root = try root.allocJsonEscape(gpa, result.root);
        defer gpa.free(esc_root);

        try out.print("{{\n  \"root\": \"{s}\",\n  \"imports\": [", .{esc_root});
        for (result.imports, 0..) |imp, i| {
            const esc = try root.allocJsonEscape(gpa, imp);
            defer gpa.free(esc);
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{esc});
        }
        try out.writeAll("],\n  \"importedBy\": [");
        for (result.importedBy, 0..) |p, i| {
            const esc = try root.allocJsonEscape(gpa, p);
            defer gpa.free(esc);
            if (i > 0) try out.writeAll(", ");
            try out.print("\"{s}\"", .{esc});
        }
        try out.writeAll("]\n}\n");
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-compressor")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools context-compressor <file-path> [--max-lines N]\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        var max_lines: usize = 200;
        if (args.len >= 5 and std.mem.eql(u8, args[3], "--max-lines")) {
            max_lines = std.fmt.parseInt(usize, args[4], 10) catch 200;
        }

        const result = root.computeContextCompressor(gpa, io, args[2], max_lines) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            gpa.free(result.path);
            gpa.free(result.summary);
        }

        const esc_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(esc_path);
        const esc_summary = try root.allocJsonEscape(gpa, result.summary);
        defer gpa.free(esc_summary);

        try out.print(
            "{{\n  \"path\": \"{s}\",\n  \"originalLines\": {d},\n  \"compressedLines\": {d},\n  \"summary\": \"{s}\"\n}}\n",
            .{ esc_path, result.originalLines, result.compressedLines, esc_summary },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "cache-check")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools cache-check <file-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeCacheCheck(gpa, io, args[2]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                error.NoHome => try err.print("error: HOME environment variable not set\n", .{}),
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
            try err.print("usage: 4orman-tools cache-store <file-path> <sub-key>  (value JSON from stdin)\n", .{});
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
                error.NoHome => try err.print("error: HOME environment variable not set\n", .{}),
                else => try err.print("error: {}\n", .{e}),
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
            try err.print("usage: 4orman-tools cache-fetch <file-path> <sub-key>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeCacheFetch(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                error.NoHome => try err.print("error: HOME environment variable not set\n", .{}),
                else => try err.print("error: {}\n", .{e}),
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
    } else if (std.mem.eql(u8, args[1], "outline")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools outline <file-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = root.computeOutline(gpa, io, abs_path) catch |e| {
            switch (e) {
                error.FileNotFound => try err.print("error: file not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.symbols) |s| gpa.free(s.name);
            gpa.free(result.symbols);
            gpa.free(result.path);
        }

        const esc_path = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(esc_path);

        try out.print("{{\n  \"path\": \"{s}\",\n  \"lang\": \"{s}\",\n  \"symbols\": [", .{ esc_path, result.lang });
        for (result.symbols, 0..) |sym, i| {
            const esc_name = try root.allocJsonEscape(gpa, sym.name);
            defer gpa.free(esc_name);
            if (i > 0) try out.print(",", .{});
            try out.print("\n    {{\"name\": \"{s}\", \"kind\": \"{s}\", \"line\": {d}}}", .{ esc_name, sym.kind, sym.line });
        }
        if (result.symbols.len > 0) try out.print("\n  ", .{});
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "deps")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools deps <root-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = root.computeDeps(gpa, io, abs_path) catch |e| {
            switch (e) {
                error.NoManifestFound => try err.print("error: no supported manifest found in: {s}\n", .{args[2]}),
                error.InvalidJson => try err.print("error: invalid JSON in package.json: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.deps) |d| {
                gpa.free(d.name);
                gpa.free(d.version);
            }
            gpa.free(result.deps);
            gpa.free(result.manifest);
        }

        const esc_manifest = try root.allocJsonEscape(gpa, result.manifest);
        defer gpa.free(esc_manifest);

        try out.print(
            "{{\n  \"manifest\": \"{s}\",\n  \"format\": \"{s}\",\n  \"totalCount\": {d},\n  \"deps\": [",
            .{ esc_manifest, result.format, result.totalCount },
        );
        for (result.deps, 0..) |dep, i| {
            const esc_name = try root.allocJsonEscape(gpa, dep.name);
            defer gpa.free(esc_name);
            const esc_ver = try root.allocJsonEscape(gpa, dep.version);
            defer gpa.free(esc_ver);
            if (i > 0) try out.print(",", .{});
            try out.print(
                "\n    {{\"name\": \"{s}\", \"version\": \"{s}\", \"dev\": {s}}}",
                .{ esc_name, esc_ver, if (dep.dev) "true" else "false" },
            );
        }
        if (result.deps.len > 0) try out.print("\n  ", .{});
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "compat-check")) {
        const do_baseline = args.len >= 3 and
            (std.mem.eql(u8, args[2], "--baseline") or std.mem.eql(u8, args[2], "--update-baseline"));

        if (do_baseline) {
            const result = root.computeCompatBaseline(gpa, io) catch |e| {
                switch (e) {
                    error.NoHome => try err.print("error: HOME environment variable not set\n", .{}),
                    else => try err.print("error: {}\n", .{e}),
                }
                try err.flush();
                std.process.exit(1);
            };
            defer {
                for (result.versions) |v| gpa.free(v);
                gpa.free(result.path);
            }

            const esc_path = try root.allocJsonEscape(gpa, result.path);
            defer gpa.free(esc_path);

            try out.print(
                "{{\n  \"recorded\": {s},\n  \"path\": \"{s}\",\n  \"tools\": {{",
                .{ if (result.recorded) "true" else "false", esc_path },
            );
            for (root.COMPAT_TOOLS, 0..) |tool, i| {
                if (i > 0) try out.print(",", .{});
                const esc_ver = try root.allocJsonEscape(gpa, result.versions[i]);
                defer gpa.free(esc_ver);
                try out.print("\n    \"{s}\": \"{s}\"", .{ tool, esc_ver });
            }
            try out.print("\n  }}\n}}\n", .{});
            try out.flush();
        } else {
            const result = root.computeCompatCheck(gpa, io) catch |e| {
                switch (e) {
                    error.NoHome => try err.print("error: HOME environment variable not set\n", .{}),
                    else => try err.print("error: {}\n", .{e}),
                }
                try err.flush();
                std.process.exit(1);
            };
            defer {
                for (result.drifted) |d| {
                    gpa.free(d.tool);
                    gpa.free(d.was);
                    gpa.free(d.now);
                    gpa.free(d.rollback);
                }
                gpa.free(result.drifted);
                gpa.free(result.baseline_age);
                gpa.free(result.advice);
            }

            const esc_age = try root.allocJsonEscape(gpa, result.baseline_age);
            defer gpa.free(esc_age);
            const esc_advice = try root.allocJsonEscape(gpa, result.advice);
            defer gpa.free(esc_advice);

            try out.print(
                "{{\n  \"ok\": {s},\n  \"baselineAge\": \"{s}\",\n  \"drifted\": [",
                .{ if (result.ok) "true" else "false", esc_age },
            );
            for (result.drifted, 0..) |d, i| {
                if (i > 0) try out.print(",", .{});
                const esc_tool = try root.allocJsonEscape(gpa, d.tool);
                defer gpa.free(esc_tool);
                const esc_was = try root.allocJsonEscape(gpa, d.was);
                defer gpa.free(esc_was);
                const esc_now = try root.allocJsonEscape(gpa, d.now);
                defer gpa.free(esc_now);
                const esc_rollback = try root.allocJsonEscape(gpa, d.rollback);
                defer gpa.free(esc_rollback);
                try out.print(
                    "\n    {{\"tool\": \"{s}\", \"was\": \"{s}\", \"now\": \"{s}\", \"risk\": \"{s}\", \"rollback\": \"{s}\"}}",
                    .{ esc_tool, esc_was, esc_now, d.risk, esc_rollback },
                );
            }
            if (result.drifted.len > 0) try out.print("\n  ", .{});
            try out.print("],\n  \"advice\": \"{s}\"\n}}\n", .{esc_advice});
            try out.flush();
        }
    } else if (std.mem.eql(u8, args[1], "run-tests")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools run-tests <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = root.computeRunTests(gpa, io, abs_path) catch |e| {
            switch (e) {
                error.NoTestFramework => try err.print("error: no supported test framework found in: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.failures) |f| {
                gpa.free(f.file);
                gpa.free(f.@"test");
                gpa.free(f.message);
            }
            gpa.free(result.failures);
            gpa.free(result.command);
            if (result.uncertainty_candidates.len > 0) gpa.free(result.uncertainty_candidates);
        }

        const esc_fw = try root.allocJsonEscape(gpa, result.framework);
        defer gpa.free(esc_fw);
        const esc_cmd = try root.allocJsonEscape(gpa, result.command);
        defer gpa.free(esc_cmd);

        try out.print(
            "{{\n  \"framework\": \"{s}\",\n  \"command\": \"{s}\",\n  \"success\": {s},\n  \"passed\": {d},\n  \"failed\": {d},\n  \"skipped\": {d},\n  \"duration_ms\": {d},\n  \"failures\": [",
            .{ esc_fw, esc_cmd, if (result.success) "true" else "false", result.passed, result.failed, result.skipped, result.duration_ms },
        );
        for (result.failures, 0..) |f, i| {
            const esc_file = try root.allocJsonEscape(gpa, f.file);
            defer gpa.free(esc_file);
            const esc_test = try root.allocJsonEscape(gpa, f.@"test");
            defer gpa.free(esc_test);
            const esc_msg = try root.allocJsonEscape(gpa, f.message);
            defer gpa.free(esc_msg);
            if (i > 0) try out.print(",", .{});
            try out.print(
                "\n    {{\"file\": \"{s}\", \"line\": {d}, \"test\": \"{s}\", \"message\": \"{s}\"}}",
                .{ esc_file, f.line, esc_test, esc_msg },
            );
        }
        if (result.failures.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"truncated\": {s},\n  \"roleConfidence\": \"{s}\",\n  \"resolvedBy\": \"{s}\",\n  \"uncertaintyReason\": \"{s}\",\n  \"uncertaintyCandidates\": [", .{ if (result.truncated) "true" else "false", result.role_confidence, result.resolved_by, result.uncertainty_reason });
        for (result.uncertainty_candidates, 0..) |c, i| {
            if (i > 0) try out.print(", ", .{});
            try out.print("\"{s}\"", .{c});
        }
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "symbol-find")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools symbol-find <path> <symbol>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const result = root.computeSymbolFind(gpa, io, args[2], args[3]) catch |e| {
            switch (e) {
                error.RootNotFound => try err.print("error: path not found: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            if (result.definition) |d| gpa.free(d.file);
            for (result.references) |rf| gpa.free(rf.file);
            gpa.free(result.references);
        }

        try out.print("{{\n  \"symbol\": \"{s}\",\n  \"kind\": \"{s}\",\n  \"definition\": ", .{ result.symbol, result.kind });
        if (result.definition) |d| {
            const esc = try root.allocJsonEscape(gpa, d.file);
            defer gpa.free(esc);
            try out.print("{{\"file\": \"{s}\", \"line\": {d}}}", .{ esc, d.line });
        } else {
            try out.print("null", .{});
        }
        try out.print(",\n  \"references\": [", .{});
        for (result.references, 0..) |rf, i| {
            const esc = try root.allocJsonEscape(gpa, rf.file);
            defer gpa.free(esc);
            if (i > 0) try out.print(",", .{});
            try out.print("\n    {{\"file\": \"{s}\", \"line\": {d}}}", .{ esc, rf.line });
        }
        if (result.references.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"capped\": {s}\n}}\n", .{if (result.capped) "true" else "false"});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "env-inspect")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools env-inspect <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = root.computeEnvInspect(gpa, io, abs_path) catch |e| {
            try err.print("error: {}\n", .{e});
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.languages) |l| gpa.free(l.version);
            gpa.free(result.languages);
            for (result.packageManagers) |p| gpa.free(p.version);
            gpa.free(result.packageManagers);
            for (result.missing) |m| gpa.free(m);
            gpa.free(result.missing);
            for (result.envVars) |v| gpa.free(v);
            gpa.free(result.envVars);
        }

        try out.print("{{\n  \"languages\": [", .{});
        for (result.languages, 0..) |l, i| {
            const esc_ver = try root.allocJsonEscape(gpa, l.version);
            defer gpa.free(esc_ver);
            if (i > 0) try out.print(",", .{});
            try out.print(
                "\n    {{\"name\": \"{s}\", \"version\": \"{s}\", \"present\": {s}}}",
                .{ l.name, esc_ver, if (l.present) "true" else "false" },
            );
        }
        if (result.languages.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"packageManagers\": [", .{});
        for (result.packageManagers, 0..) |p, i| {
            const esc_ver = try root.allocJsonEscape(gpa, p.version);
            defer gpa.free(esc_ver);
            if (i > 0) try out.print(",", .{});
            try out.print(
                "\n    {{\"name\": \"{s}\", \"version\": \"{s}\", \"present\": {s}}}",
                .{ p.name, esc_ver, if (p.present) "true" else "false" },
            );
        }
        if (result.packageManagers.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"missing\": [", .{});
        for (result.missing, 0..) |m, i| {
            const esc = try root.allocJsonEscape(gpa, m);
            defer gpa.free(esc);
            if (i > 0) try out.print(", ", .{});
            try out.print("\"{s}\"", .{esc});
        }
        try out.print("],\n  \"envVars\": [", .{});
        for (result.envVars, 0..) |v, i| {
            const esc = try root.allocJsonEscape(gpa, v);
            defer gpa.free(esc);
            if (i > 0) try out.print(", ", .{});
            try out.print("\"{s}\"", .{esc});
        }
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "build")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools build <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }

        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = root.computeBuild(gpa, io, abs_path) catch |e| {
            switch (e) {
                error.NoBuildSystem => try err.print("error: no supported build system found in: {s}\n", .{args[2]}),
                else => try err.print("error: {}\n", .{e}),
            }
            try err.flush();
            std.process.exit(1);
        };
        defer {
            for (result.errors) |be| {
                gpa.free(be.file);
                gpa.free(be.message);
            }
            gpa.free(result.errors);
            for (result.warnings) |bw| {
                gpa.free(bw.file);
                gpa.free(bw.message);
            }
            gpa.free(result.warnings);
            gpa.free(result.command);
            if (result.uncertainty_candidates.len > 0) gpa.free(result.uncertainty_candidates);
        }

        const esc_tool = try root.allocJsonEscape(gpa, result.tool);
        defer gpa.free(esc_tool);
        const esc_cmd = try root.allocJsonEscape(gpa, result.command);
        defer gpa.free(esc_cmd);

        try out.print(
            "{{\n  \"tool\": \"{s}\",\n  \"command\": \"{s}\",\n  \"success\": {s},\n  \"errors\": [",
            .{ esc_tool, esc_cmd, if (result.success) "true" else "false" },
        );
        for (result.errors, 0..) |be, i| {
            const esc_file = try root.allocJsonEscape(gpa, be.file);
            defer gpa.free(esc_file);
            const esc_msg = try root.allocJsonEscape(gpa, be.message);
            defer gpa.free(esc_msg);
            if (i > 0) try out.print(",", .{});
            try out.print(
                "\n    {{\"file\": \"{s}\", \"line\": {d}, \"col\": {d}, \"message\": \"{s}\", \"severity\": \"{s}\"}}",
                .{ esc_file, be.line, be.col, esc_msg, be.severity },
            );
        }
        if (result.errors.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"warnings\": [", .{});
        for (result.warnings, 0..) |bw, i| {
            const esc_file = try root.allocJsonEscape(gpa, bw.file);
            defer gpa.free(esc_file);
            const esc_msg = try root.allocJsonEscape(gpa, bw.message);
            defer gpa.free(esc_msg);
            if (i > 0) try out.print(",", .{});
            try out.print(
                "\n    {{\"file\": \"{s}\", \"line\": {d}, \"col\": {d}, \"message\": \"{s}\"}}",
                .{ esc_file, bw.line, bw.col, esc_msg },
            );
        }
        if (result.warnings.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"duration_ms\": {d},\n  \"truncated\": {s},\n  \"roleConfidence\": \"{s}\",\n  \"resolvedBy\": \"{s}\",\n  \"uncertaintyReason\": \"{s}\",\n  \"uncertaintyCandidates\": [", .{ result.duration_ms, if (result.truncated) "true" else "false", result.role_confidence, result.resolved_by, result.uncertainty_reason });
        for (result.uncertainty_candidates, 0..) |c, i| {
            if (i > 0) try out.print(", ", .{});
            try out.print("\"{s}\"", .{c});
        }
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "secret-scan")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools secret-scan <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = root.computeSecretScan(gpa, io, abs_path) catch |e| switch (e) {
            error.RootNotFound => {
                try err.print("error: path not found: {s}\n", .{args[2]});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        try out.print("{{\n  \"findings\": [", .{});
        for (result.findings, 0..) |f, i| {
            if (i > 0) try out.print(",", .{});
            try out.print(
                "\n    {{\"file\": \"{s}\", \"line\": {d}, \"pattern\": \"{s}\", \"severity\": \"{s}\"}}",
                .{ f.file, f.line, f.pattern, f.severity },
            );
        }
        if (result.findings.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"truncated\": {s}\n}}\n", .{if (result.truncated) "true" else "false"});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "device-scan")) {
        const result = root.computeDeviceScan(gpa, io) catch |e| switch (e) {
            error.NoHome => {
                try err.print("error: HOME not set\n", .{});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        try out.print("{{\n  \"profile_id\": \"{s}\",\n  \"hardware\": {{\"cpu\": \"{s}\", \"cores\": {d}, \"ram_gb\": {d}, \"os\": \"macos\", \"arch\": \"{s}\"}},\n  \"tools\": {{", .{ result.profile_id, result.hardware.cpu, result.hardware.cores, result.hardware.ram_gb, result.hardware.arch });
        for (result.tools, 0..) |t, i| {
            if (i > 0) try out.print(",", .{});
            try out.print("\n    \"{s}\": {{\"version\": \"{s}\", \"present\": {s}}}", .{ t.name, t.version, if (t.present) "true" else "false" });
        }
        try out.print("\n  }},\n  \"optimal\": {{\"zig_build_flags\": \"{s}\"}},\n  \"shell\": \"{s}\",\n  \"scanned_at\": {d},\n  \"path\": \"{s}\"\n}}\n", .{ result.optimal.zig_build_flags, result.shell, result.scanned_at, result.path });
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "delta-context")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools delta-context <repo-path> [ref]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const ref = if (args.len >= 4) args[3] else "HEAD";
        const result = root.computeDeltaContext(gpa, io, args[2], ref) catch |e| switch (e) {
            error.GitFailed => {
                try err.print("error: git diff failed in: {s}\n", .{args[2]});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        try out.print("{{\n  \"ref\": \"{s}\",\n  \"symbols\": [", .{result.ref});
        for (result.symbols, 0..) |ds, i| {
            if (i > 0) try out.print(",", .{});
            try out.print(
                "\n    {{\"name\": \"{s}\", \"kind\": \"{s}\", \"file\": \"{s}\", \"line\": {d}, \"callers\": [",
                .{ ds.name, ds.kind, ds.file, ds.line },
            );
            for (ds.callers, 0..) |c, ci| {
                if (ci > 0) try out.print(",", .{});
                try out.print("{{\"file\": \"{s}\", \"line\": {d}}}", .{ c.file, c.line });
            }
            try out.print("]}}", .{});
        }
        if (result.symbols.len > 0) try out.print("\n  ", .{});
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "git-cache")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools git-cache <repo-path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const result = root.computeGitCache(gpa, io, args[2]) catch |e| switch (e) {
            error.NotAGitRepo => {
                try err.print("error: not a git repo: {s}\n", .{args[2]});
                try err.flush();
                std.process.exit(1);
            },
            error.NoHome => {
                try err.print("error: HOME not set\n", .{});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        try out.print("{{\n  \"hit\": {s},\n  \"branch\": \"{s}\",\n  \"head\": \"{s}\",\n  \"dirty\": {s},\n  \"ahead\": {d},\n  \"behind\": {d},\n  \"commits\": [", .{ if (result.hit) "true" else "false", result.branch, result.head, if (result.dirty) "true" else "false", result.ahead, result.behind });
        for (result.commits, 0..) |c, i| {
            if (i > 0) try out.print(",", .{});
            try out.print("\n    {{\"hash\": \"{s}\", \"subject\": \"{s}\", \"author\": \"{s}\", \"date\": \"{s}\"}}", .{ c.hash, c.subject, c.author, c.date });
        }
        if (result.commits.len > 0) try out.print("\n  ", .{});
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "prod-ready")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools prod-ready <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = try root.computeProdReady(gpa, io, abs_path);
        try out.print("{{\n  \"ready\": {s},\n  \"blockers\": [", .{if (result.ready) "true" else "false"});
        for (result.blockers, 0..) |b, i| {
            if (i > 0) try out.print(",", .{});
            const msg_esc = try root.allocJsonEscape(gpa, b.message);
            defer gpa.free(msg_esc);
            try out.print("\n    {{\"source\": \"{s}\", \"message\": \"{s}\"}}", .{ b.source, msg_esc });
        }
        if (result.blockers.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"warnings\": [", .{});
        for (result.warnings, 0..) |w, i| {
            if (i > 0) try out.print(",", .{});
            const msg_esc = try root.allocJsonEscape(gpa, w.message);
            defer gpa.free(msg_esc);
            try out.print("\n    {{\"source\": \"{s}\", \"message\": \"{s}\"}}", .{ w.source, msg_esc });
        }
        if (result.warnings.len > 0) try out.print("\n  ", .{});
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "validate-schema")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools validate-schema <file> <schema>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const result = root.computeValidateSchema(gpa, io, args[2], args[3]) catch |e| switch (e) {
            error.FileNotFound => {
                try err.print("error: file not found: {s}\n", .{args[2]});
                try err.flush();
                std.process.exit(1);
            },
            error.SchemaNotFound => {
                try err.print("error: schema not found: {s}\n", .{args[3]});
                try err.flush();
                std.process.exit(1);
            },
            error.InvalidJson => {
                try err.print("error: invalid JSON in file: {s}\n", .{args[2]});
                try err.flush();
                std.process.exit(1);
            },
            error.InvalidSchema => {
                try err.print("error: invalid JSON in schema: {s}\n", .{args[3]});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        const file_esc = try root.allocJsonEscape(gpa, result.file);
        defer gpa.free(file_esc);
        const schema_esc = try root.allocJsonEscape(gpa, result.schema);
        defer gpa.free(schema_esc);
        try out.print("{{\n  \"valid\": {s},\n  \"file\": \"{s}\",\n  \"schema\": \"{s}\",\n  \"violations\": [", .{ if (result.valid) "true" else "false", file_esc, schema_esc });
        for (result.violations, 0..) |v, i| {
            if (i > 0) try out.print(",", .{});
            const path_esc = try root.allocJsonEscape(gpa, v.path);
            defer gpa.free(path_esc);
            const exp_esc = try root.allocJsonEscape(gpa, v.expected);
            defer gpa.free(exp_esc);
            const got_esc = try root.allocJsonEscape(gpa, v.got);
            defer gpa.free(got_esc);
            try out.print("\n    {{\"path\": \"{s}\", \"expected\": \"{s}\", \"got\": \"{s}\"}}", .{
                path_esc, exp_esc, got_esc,
            });
        }
        if (result.violations.len > 0) try out.print("\n  ", .{});
        try out.print("]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "quality-gate")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools quality-gate <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = try root.computeQualityGate(gpa, io, abs_path);
        // Helper to print a findings array
        try out.print("{{\n  \"verdict\": \"{s}\",\n", .{result.verdict});
        const levels = [_]struct { name: []const u8, items: []const root.QualityFinding }{
            .{ .name = "critical", .items = result.critical },
            .{ .name = "high", .items = result.high },
            .{ .name = "medium", .items = result.medium },
            .{ .name = "low", .items = result.low },
        };
        for (levels) |level| {
            try out.print("  \"{s}\": [", .{level.name});
            for (level.items, 0..) |f, i| {
                if (i > 0) try out.print(",", .{});
                const msg_esc = try root.allocJsonEscape(gpa, f.message);
                defer gpa.free(msg_esc);
                const file_esc = try root.allocJsonEscape(gpa, f.file);
                defer gpa.free(file_esc);
                try out.print("\n    {{\"source\": \"{s}\", \"file\": \"{s}\", \"line\": {d}, \"message\": \"{s}\"}}", .{
                    f.source, file_esc, f.line, msg_esc,
                });
            }
            if (level.items.len > 0) try out.print("\n  ", .{});
            try out.print("],\n", .{});
        }
        try out.print("  \"buildRan\": {s},\n  \"buildTool\": \"{s}\",\n  \"testsRan\": {s},\n  \"testFramework\": \"{s}\",\n  \"testsPassed\": {d},\n  \"testsFailed\": {d}\n}}\n", .{
            if (result.build_ran) "true" else "false", result.build_tool,
            if (result.tests_ran) "true" else "false", result.test_fw,
            result.tests_passed,                       result.tests_failed,
        });
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "shell-run")) {
        var timeout_ms: u64 = 30_000;
        var cmd_idx: usize = 2;
        if (args.len >= 5 and std.mem.eql(u8, args[2], "--timeout")) {
            timeout_ms = std.fmt.parseInt(u64, args[3], 10) catch 30_000;
            cmd_idx = 4;
        }
        if (args.len <= cmd_idx) {
            try err.print("usage: 4orman-tools shell-run [--timeout <ms>] <shell-command>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const command = args[cmd_idx];
        const result = root.computeShellRun(gpa, io, command, timeout_ms) catch |e| switch (e) {
            else => return e,
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        const DMAX = root.SHELL_RUN_DISPLAY_MAX;
        const stdout_trunc = result.stdout.len > DMAX;
        const stderr_trunc = result.stderr.len > DMAX;
        const stdout_display = result.stdout[0..@min(result.stdout.len, DMAX)];
        const stderr_display = result.stderr[0..@min(result.stderr.len, DMAX)];
        const stdout_esc = try root.allocJsonEscape(gpa, stdout_display);
        defer gpa.free(stdout_esc);
        const stderr_esc = try root.allocJsonEscape(gpa, stderr_display);
        defer gpa.free(stderr_esc);
        const cmd_esc = try root.allocJsonEscape(gpa, result.command);
        defer gpa.free(cmd_esc);
        const block_esc = try root.allocJsonEscape(gpa, result.block_reason);
        defer gpa.free(block_esc);
        const block_json = if (result.block_reason.len > 0)
            try std.fmt.allocPrint(gpa, "\"{s}\"", .{block_esc})
        else
            try gpa.dupe(u8, "null");
        defer gpa.free(block_json);
        try out.print("{{\n  \"command\": \"{s}\",\n  \"exitCode\": {d},\n  \"stdout\": \"{s}\",\n  \"stderr\": \"{s}\",\n  \"durationMs\": {d},\n  \"timedOut\": {s},\n  \"blocked\": {s},\n  \"blockReason\": {s},\n  \"stdoutTruncated\": {s},\n  \"stderrTruncated\": {s}\n}}\n", .{
            cmd_esc,                                   result.exit_code,                        stdout_esc, stderr_esc,                            result.duration_ms,
            if (result.timed_out) "true" else "false", if (result.blocked) "true" else "false", block_json, if (stdout_trunc) "true" else "false", if (stderr_trunc) "true" else "false",
        });
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "project-state")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools project-state <path> [record-decision <what> [<why>]]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const ps_path = args[2];
        var ps_mode: root.ProjectStateMode = .read;
        if (args.len >= 5 and std.mem.eql(u8, args[3], "record-decision")) {
            const what = args[4];
            const why: []const u8 = if (args.len >= 6) args[5] else "";
            ps_mode = .{ .record_decision = .{ .what = what, .why = why } };
        } else if (args.len >= 5 and std.mem.eql(u8, args[3], "record-pattern")) {
            ps_mode = .{ .record_pattern = args[4] };
        }
        const result = root.computeProjectState(gpa, io, ps_path, ps_mode) catch |e| switch (e) {
            error.NoHome => {
                try err.print("error: HOME not set\n", .{});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        const path_esc = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(path_esc);
        try out.print("{{\n  \"path\": \"{s}\",\n  \"decisions\": [", .{path_esc});
        for (result.decisions, 0..) |d, i| {
            if (i > 0) try out.print(",", .{});
            const date_esc = try root.allocJsonEscape(gpa, d.date);
            defer gpa.free(date_esc);
            const what_esc = try root.allocJsonEscape(gpa, d.what);
            defer gpa.free(what_esc);
            const why_esc = try root.allocJsonEscape(gpa, d.why);
            defer gpa.free(why_esc);
            try out.print("\n    {{\"date\": \"{s}\", \"what\": \"{s}\", \"why\": \"{s}\"}}", .{
                date_esc, what_esc, why_esc,
            });
        }
        if (result.decisions.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"knownPatterns\": [", .{});
        for (result.known_patterns, 0..) |pat, i| {
            if (i > 0) try out.print(",", .{});
            const pat_esc = try root.allocJsonEscape(gpa, pat);
            defer gpa.free(pat_esc);
            try out.print("\n    \"{s}\"", .{pat_esc});
        }
        if (result.known_patterns.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"lastBuildResult\": null,\n  \"lastTestResult\": null\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "ledger")) {
        // ledger score <question> <sources-json> — separate path, does not use LedgerMode
        if (args.len >= 3 and std.mem.eql(u8, args[2], "score")) {
            if (args.len < 5) {
                try err.print("usage: 4orman-tools ledger score <question> <sources-json>\n", .{});
                try err.flush();
                std.process.exit(1);
            }
            const sr = root.computeLedgerScore(gpa, io, args[3], args[4]) catch |e| switch (e) {
                error.NoHome => {
                    try err.print("error: HOME not set\n", .{});
                    try err.flush();
                    std.process.exit(1);
                },
                else => return e,
            };
            const reason_esc = try root.allocJsonEscape(gpa, sr.reason);
            defer gpa.free(reason_esc);
            const winner_str: []const u8 = if (sr.winner) |w| blk: {
                const we = try root.allocJsonEscape(gpa, w);
                break :blk we;
            } else try gpa.dupe(u8, "null");
            defer gpa.free(winner_str);
            const winner_json: []const u8 = if (sr.winner != null) blk: {
                const buf = try std.fmt.allocPrint(gpa, "\"{s}\"", .{winner_str});
                break :blk buf;
            } else try gpa.dupe(u8, "null");
            defer gpa.free(winner_json);
            try out.print("{{\n  \"composite\": {d:.1},\n  \"sample_count\": {d},\n  \"total_points\": {d},\n  \"max_points\": {d},\n  \"winner\": {s},\n  \"void\": {s},\n  \"reason\": \"{s}\",\n  \"zig_entry_found\": {s},\n  \"zig_entry_stale\": {s}\n}}\n", .{
                sr.composite, sr.sample_count, sr.total_points, sr.max_points,
                winner_json,
                if (sr.void_round) "true" else "false",
                reason_esc,
                if (sr.zig_entry_found) "true" else "false",
                if (sr.zig_entry_stale) "true" else "false",
            });
            try out.flush();
        } else {
            var ledger_mode: root.LedgerMode = .show;
            if (args.len >= 3) {
                if (std.mem.eql(u8, args[2], "show")) {
                    ledger_mode = .show;
                } else if (std.mem.eql(u8, args[2], "check-stale")) {
                    ledger_mode = .check_stale;
                } else if (std.mem.eql(u8, args[2], "record")) {
                    if (args.len < 6) {
                        try err.print("usage: 4orman-tools ledger record <winner> <question> <reasoning>\n", .{});
                        try err.flush();
                        std.process.exit(1);
                    }
                    ledger_mode = .{ .record = .{ .winner = args[3], .question = args[4], .reasoning = args[5] } };
                } else if (std.mem.eql(u8, args[2], "validate")) {
                    if (args.len < 4) {
                        try err.print("usage: 4orman-tools ledger validate <id>\n", .{});
                        try err.flush();
                        std.process.exit(1);
                    }
                    ledger_mode = .{ .validate = args[3] };
                } else if (std.mem.eql(u8, args[2], "record-jungian")) {
                    if (args.len < 7) {
                        try err.print("usage: 4orman-tools ledger record-jungian <question> <chosen> <shadow> <synthesis>\n", .{});
                        try err.flush();
                        std.process.exit(1);
                    }
                    ledger_mode = .{ .record_jungian = .{ .question = args[3], .chosen = args[4], .shadow = args[5], .synthesis = args[6] } };
                } else if (std.mem.eql(u8, args[2], "record-outcome")) {
                    if (args.len < 6) {
                        try err.print("usage: 4orman-tools ledger record-outcome <id> <outcome> <matched|diverged>\n", .{});
                        try err.flush();
                        std.process.exit(1);
                    }
                    if (!std.mem.eql(u8, args[5], "matched") and !std.mem.eql(u8, args[5], "diverged")) {
                        try err.print("error: <matched|diverged> must be exactly one of those two words, got: {s}\n", .{args[5]});
                        try err.flush();
                        std.process.exit(1);
                    }
                    ledger_mode = .{ .record_outcome = .{ .id = args[3], .outcome = args[4], .matched = args[5] } };
                }
            }
            const lresult = root.computeLedger(gpa, io, ledger_mode) catch |e| switch (e) {
                error.NoHome => {
                    try err.print("error: HOME not set\n", .{});
                    try err.flush();
                    std.process.exit(1);
                },
                else => return e,
            };
            try out.print("{{\n  \"total\": {d},\n  \"stale_count\": {d},\n  \"entries\": [", .{ lresult.total, lresult.stale_count });
            for (lresult.entries, 0..) |e, i| {
                if (i > 0) try out.print(",", .{});
                const id_esc = try root.allocJsonEscape(gpa, e.id);
                defer gpa.free(id_esc);
                const date_esc = try root.allocJsonEscape(gpa, e.date);
                defer gpa.free(date_esc);
                const win_esc = try root.allocJsonEscape(gpa, e.winner);
                defer gpa.free(win_esc);
                const q_esc = try root.allocJsonEscape(gpa, e.question);
                defer gpa.free(q_esc);
                const r_esc = try root.allocJsonEscape(gpa, e.reasoning);
                defer gpa.free(r_esc);
                const cat_esc = try root.allocJsonEscape(gpa, e.category);
                defer gpa.free(cat_esc);
                const shadow_esc = try root.allocJsonEscape(gpa, e.shadow);
                defer gpa.free(shadow_esc);
                const synth_esc = try root.allocJsonEscape(gpa, e.synthesis);
                defer gpa.free(synth_esc);
                const outcome_esc = try root.allocJsonEscape(gpa, e.outcome);
                defer gpa.free(outcome_esc);
                const matched_esc = try root.allocJsonEscape(gpa, e.outcome_matched);
                defer gpa.free(matched_esc);
                try out.print("\n    {{\"id\": \"{s}\", \"date\": \"{s}\", \"recorded_ts\": {d}, \"revalidation_due_ts\": {d}, \"category\": \"{s}\", \"winner\": \"{s}\", \"question\": \"{s}\", \"reasoning\": \"{s}\", \"shadow\": \"{s}\", \"synthesis\": \"{s}\", \"outcome\": \"{s}\", \"outcomeMatched\": \"{s}\", \"outcomeRecordedTs\": {d}, \"outcomeReviewDue\": {s}, \"is_stale\": {s}}}", .{
                    id_esc, date_esc, e.recorded_ts, e.revalidation_due_ts, cat_esc, win_esc, q_esc, r_esc, shadow_esc, synth_esc, outcome_esc, matched_esc, e.outcome_recorded_ts,
                    if (e.outcome_review_due) "true" else "false",
                    if (e.is_stale) "true" else "false",
                });
            }
            if (lresult.entries.len > 0) try out.print("\n  ", .{});
            try out.print("]\n}}\n", .{});
            try out.flush();
        }
    } else if (std.mem.eql(u8, args[1], "metrics")) {
        const result = try root.computeMetrics(gpa, io);
        try out.print(
            "{{\n  \"cacheEntries\": {d},\n  \"projectStates\": {d},\n  \"totalDecisions\": {d},\n  \"totalPatterns\": {d},\n  \"deviceProfiled\": {s},\n  \"compatBaselineSet\": {s},\n  \"estimatedTokenSavings\": {d},\n  \"note\": \"savings estimated at 80% hit rate x 200 tokens/hit\"\n}}\n",
            .{ result.cache_entries, result.project_states, result.total_decisions, result.total_patterns, if (result.device_profiled) "true" else "false", if (result.compat_baseline_set) "true" else "false", result.estimated_token_savings },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "rollback")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools rollback <repo-path> [--list | --revert <id>]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const repo_path = args[2];
        if (args.len >= 4 and std.mem.eql(u8, args[3], "--list")) {
            const json = try root.computeRollbackList(gpa, io, repo_path);
            defer gpa.free(json);
            try out.print("{s}\n", .{json});
        } else if (args.len >= 5 and std.mem.eql(u8, args[3], "--revert")) {
            const json = root.computeRollbackRevert(gpa, io, repo_path, args[4]) catch |e| switch (e) {
                error.NoSnapshots, error.SnapshotNotFound => {
                    try err.print("error: snapshot not found: {s}\n", .{args[4]});
                    try err.flush();
                    std.process.exit(1);
                },
                else => return e,
            };
            defer gpa.free(json);
            try out.print("{s}\n", .{json});
        } else {
            const json = try root.computeRollbackSnapshot(gpa, io, repo_path);
            defer gpa.free(json);
            try out.print("{s}\n", .{json});
        }
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "sandbox-check")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools sandbox-check <command...>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const operation = try std.mem.join(gpa, " ", args[2..]);
        defer gpa.free(operation);
        const result = try root.computeSandboxCheck(gpa, operation);
        defer gpa.free(result.operation);
        const op_esc = try root.allocJsonEscape(gpa, result.operation);
        defer gpa.free(op_esc);
        const reason_esc = try root.allocJsonEscape(gpa, result.reason);
        defer gpa.free(reason_esc);
        try out.print(
            "{{\n  \"operation\": \"{s}\",\n  \"allowed\": {s},\n  \"severity\": \"{s}\",\n  \"reason\": \"{s}\"\n}}\n",
            .{ op_esc, if (result.allowed) "true" else "false", result.severity, reason_esc },
        );
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "session-snapshot")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools session-snapshot <4orman-root>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const json = try root.computeSnapshot(gpa, io, args[2]);
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "report")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools report <path>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const abs_path = root.resolveAbsolutePath(gpa, io, args[2]) catch {
            try err.print("error: path not found: {s}\n", .{args[2]});
            try err.flush();
            std.process.exit(1);
        };
        defer gpa.free(abs_path);

        const result = try root.computeReport(gpa, io, abs_path);
        const path_esc = try root.allocJsonEscape(gpa, result.path);
        defer gpa.free(path_esc);
        const branch_esc = try root.allocJsonEscape(gpa, result.git_branch);
        defer gpa.free(branch_esc);
        const action_esc = try root.allocJsonEscape(gpa, result.next_action);
        defer gpa.free(action_esc);
        try out.print(
            "{{\n  \"path\": \"{s}\",\n  \"status\": \"{s}\",\n  \"confidence\": \"{s}\",\n  \"gitBranch\": \"{s}\",\n  \"gitDirty\": {s},\n  \"buildOk\": {s},\n  \"testsOk\": {s},\n  \"secretsFound\": {s},\n  \"issues\": [",
            .{ path_esc, result.status, result.confidence, branch_esc, if (result.git_dirty) "true" else "false", if (result.build_ok) "true" else "false", if (result.tests_ok) "true" else "false", if (result.secrets_found) "true" else "false" },
        );
        for (result.issues, 0..) |iss, i| {
            const comma: []const u8 = if (i + 1 < result.issues.len) "," else "";
            const src_esc = try root.allocJsonEscape(gpa, iss.source);
            defer gpa.free(src_esc);
            const msg_esc = try root.allocJsonEscape(gpa, iss.message);
            defer gpa.free(msg_esc);
            try out.print("\n    {{\"source\": \"{s}\", \"severity\": \"{s}\", \"message\": \"{s}\"}}{s}", .{ src_esc, iss.severity, msg_esc, comma });
        }
        if (result.issues.len > 0) try out.print("\n  ", .{});
        try out.print("],\n  \"nextAction\": \"{s}\"\n}}\n", .{action_esc});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "route")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools route <task...>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const task = try std.mem.join(gpa, " ", args[2..]);
        defer gpa.free(task);
        const result = try root.computeRoute(gpa, io, task);
        defer gpa.free(result.task);
        defer gpa.free(result.steps);
        const task_esc = try root.allocJsonEscape(gpa, result.task);
        defer gpa.free(task_esc);
        try out.print("{{\n  \"task\": \"{s}\",\n  \"routed\": {s},\n  \"steps\": [", .{ task_esc, if (result.routed) "true" else "false" });
        for (result.steps, 0..) |step, i| {
            const comma: []const u8 = if (i + 1 < result.steps.len) "," else "";
            const reason_esc = try root.allocJsonEscape(gpa, step.reason);
            defer gpa.free(reason_esc);
            try out.print(
                "\n    {{\"step\": {d}, \"layer\": \"{s}\", \"subcommand\": \"{s}\", \"argHint\": \"{s}\", \"confidence\": \"{s}\", \"reason\": \"{s}\"}}{s}",
                .{ step.step, step.layer, step.subcommand, step.arg_hint, step.confidence, reason_esc, comma },
            );
        }
        if (result.steps.len > 0) try out.print("\n  ", .{});
        if (result.routed) {
            try out.print("],\n  \"fallback\": null\n}}\n", .{});
        } else {
            const reason_esc = try root.allocJsonEscape(gpa, result.reason);
            defer gpa.free(reason_esc);
            try out.print("],\n  \"fallback\": \"claude\",\n  \"reason\": \"{s}\"\n}}\n", .{reason_esc});
        }
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "capability-check")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools capability-check <query...>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const query = try std.mem.join(gpa, " ", args[2..]);
        defer gpa.free(query);
        const result = try root.computeCapabilityCheck(gpa, io, query);
        defer gpa.free(result.query);
        const query_esc = try root.allocJsonEscape(gpa, result.query);
        defer gpa.free(query_esc);
        if (result.available and std.mem.eql(u8, result.source, "native")) {
            const desc_esc = try root.allocJsonEscape(gpa, result.description);
            defer gpa.free(desc_esc);
            const args_esc = try root.allocJsonEscape(gpa, result.args);
            defer gpa.free(args_esc);
            try out.print(
                "{{\n  \"query\": \"{s}\",\n  \"available\": true,\n  \"source\": \"native\",\n  \"subcommand\": \"{s}\",\n  \"description\": \"{s}\",\n  \"args\": \"{s}\",\n  \"confidence\": \"{s}\",\n  \"ledgerId\": null,\n  \"ledgerReasoning\": null,\n  \"needsDecision\": false\n}}\n",
                .{ query_esc, result.subcommand, desc_esc, args_esc, result.confidence },
            );
        } else if (result.available and std.mem.eql(u8, result.source, "ledger")) {
            const reasoning_esc = try root.allocJsonEscape(gpa, result.ledger_reasoning);
            defer gpa.free(reasoning_esc);
            try out.print(
                "{{\n  \"query\": \"{s}\",\n  \"available\": true,\n  \"source\": \"ledger\",\n  \"subcommand\": null,\n  \"description\": null,\n  \"args\": null,\n  \"confidence\": \"{s}\",\n  \"ledgerId\": \"{s}\",\n  \"ledgerReasoning\": \"{s}\",\n  \"needsDecision\": false\n}}\n",
                .{ query_esc, result.confidence, result.ledger_id, reasoning_esc },
            );
        } else {
            try out.print(
                "{{\n  \"query\": \"{s}\",\n  \"available\": false,\n  \"source\": \"claude\",\n  \"subcommand\": null,\n  \"description\": null,\n  \"args\": null,\n  \"confidence\": \"none\",\n  \"ledgerId\": null,\n  \"ledgerReasoning\": null,\n  \"needsDecision\": {s}\n}}\n",
                .{ query_esc, if (result.needs_decision) "true" else "false" },
            );
        }
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "capability-promote")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools capability-promote <command...>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const command = try std.mem.join(gpa, " ", args[2..]);
        defer gpa.free(command);
        const json = try root.computeCapabilityPromote(gpa, io, command);
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "ant")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools ant <path> [--since <ms>]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const ant_path = args[2];
        var since_ms: i64 = blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const now: i64 = ts.sec *% 1000 + @divTrunc(ts.nsec, 1_000_000);
            break :blk now - 86_400_000;
        };
        var arg_i: usize = 3;
        while (arg_i < args.len) : (arg_i += 1) {
            if (std.mem.eql(u8, args[arg_i], "--since") and arg_i + 1 < args.len) {
                since_ms = std.fmt.parseInt(i64, args[arg_i + 1], 10) catch since_ms;
                arg_i += 1;
            }
        }
        const json = root.computeAnt(gpa, io, ant_path, since_ms) catch |e| switch (e) {
            error.PathNotFound => {
                try err.print("error: path not found: {s}\n", .{ant_path});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "worker-list")) {
        const json = try root.computeWorkerList(gpa);
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "worker-run")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools worker-run <lang> <script> [args...]\n", .{});
            try err.print("langs: python py node js deno bun go golang ruby rb bash sh swift zig lua php\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const lang = args[2];
        const script_path = args[3];
        const extra_args = if (args.len > 4) args[4..] else args[0..0];
        const json = root.computeWorkerRun(gpa, io, lang, script_path, extra_args, root.WORKER_DEFAULT_TIMEOUT_MS) catch |e| switch (e) {
            error.UnknownLang => {
                try err.print("error: unknown language '{s}'. Supported: python py node js deno bun go golang ruby rb bash sh swift zig lua php\n", .{lang});
                try err.flush();
                std.process.exit(1);
            },
            error.InterpreterNotFound => {
                try err.print("error: no interpreter found for '{s}'. Install it and ensure it is in PATH.\n", .{lang});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "context-slice")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools context-slice <abs-path> <focus-query>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const json = root.computeContextSlice(gpa, io, args[2], args[3]) catch |e| switch (e) {
            error.PathNotFound => {
                try err.print("error: path not found: {s}\n", .{args[2]});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "state-merge")) {
        if (args.len < 4) {
            try err.print("usage: 4orman-tools state-merge <file1> <file2>\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const json = root.computeStateMerge(gpa, io, args[2], args[3]) catch |e| switch (e) {
            error.File1NotFound => {
                try err.print("error: file not found: {s}\n", .{args[2]});
                try err.flush();
                std.process.exit(1);
            },
            error.File2NotFound => {
                try err.print("error: file not found: {s}\n", .{args[3]});
                try err.flush();
                std.process.exit(1);
            },
            error.File1InvalidJson => {
                try err.print("error: invalid JSON in {s}\n", .{args[2]});
                try err.flush();
                std.process.exit(1);
            },
            error.File2InvalidJson => {
                try err.print("error: invalid JSON in {s}\n", .{args[3]});
                try err.flush();
                std.process.exit(1);
            },
            error.NotObjects => {
                try err.print("error: both files must be JSON objects\n", .{});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "plugin-list")) {
        const json = try root.computePluginList(gpa, io);
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "plugin-run")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools plugin-run <name> [args...]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const plugin_name = args[2];
        const extra_args = if (args.len > 3) args[3..] else args[0..0];
        const json = root.computePluginRun(gpa, io, plugin_name, extra_args) catch |e| switch (e) {
            error.PluginNotFound => {
                try err.print("error: plugin '{s}' not found in ~/.4orman/plugins/\n", .{plugin_name});
                try err.flush();
                std.process.exit(1);
            },
            error.ManifestInvalid => {
                try err.print("error: invalid manifest for plugin '{s}' (bad JSON or wrong field type)\n", .{plugin_name});
                try err.flush();
                std.process.exit(1);
            },
            error.ManifestMissingField => {
                try err.print("error: invalid manifest for plugin '{s}': missing required field (name, lang, or entry)\n", .{plugin_name});
                try err.flush();
                std.process.exit(1);
            },
            error.PluginUnknownLang => {
                try err.print("error: plugin '{s}' specifies an unknown lang\n", .{plugin_name});
                try err.flush();
                std.process.exit(1);
            },
            error.PluginInterpreterNotFound => {
                try err.print("error: interpreter not found for plugin '{s}'\n", .{plugin_name});
                try err.flush();
                std.process.exit(1);
            },
            else => return e,
        };
        defer gpa.free(json);
        try out.print("{s}\n", .{json});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "tui")) {
        const workspace_root = if (args.len >= 3) args[2] else blk: {
            const home_ptr = std.c.getenv("HOME") orelse {
                try err.print("error: HOME not set\n", .{});
                try err.flush();
                std.process.exit(1);
            };
            const home = std.mem.sliceTo(home_ptr, 0);
            break :blk try std.fmt.allocPrint(gpa, "{s}/4orman", .{home});
        };
        try root.computeTui(gpa, io, workspace_root);
    } else if (std.mem.eql(u8, args[1], "knowledge-audit")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools knowledge-audit <project-path> [<4orman-root>]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const project_path = args[2];
        const workspace_root = if (args.len >= 4) args[3] else blk: {
            const home_ptr = std.c.getenv("HOME") orelse {
                try err.print("error: HOME not set\n", .{});
                try err.flush();
                std.process.exit(1);
            };
            const home = std.mem.sliceTo(home_ptr, 0);
            break :blk try std.fmt.allocPrint(gpa, "{s}/4orman", .{home});
        };
        const result = try root.computeKnowledgeAudit(gpa, io, project_path, workspace_root);
        try out.print("{{\n  \"project\": \"{s}\",\n  \"path\": \"{s}\",\n  \"ready\": {s},\n", .{
            result.project, result.path, if (result.ready) "true" else "false",
        });
        try out.print("  \"captured\": [\n", .{});
        for (result.captured, 0..) |item, i| {
            const comma: []const u8 = if (i + 1 < result.captured.len) "," else "";
            try out.print("    {{\"label\": \"{s}\", \"source\": \"{s}\"}}{s}\n", .{ item.label, item.source, comma });
        }
        try out.print("  ],\n  \"unextracted\": [\n", .{});
        for (result.unextracted, 0..) |item, i| {
            const comma: []const u8 = if (i + 1 < result.unextracted.len) "," else "";
            try out.print("    {{\"label\": \"{s}\", \"source\": \"{s}\"}}{s}\n", .{ item.label, item.source, comma });
        }
        try out.print("  ],\n  \"warnings\": [\n", .{});
        for (result.warnings, 0..) |item, i| {
            const comma: []const u8 = if (i + 1 < result.warnings.len) "," else "";
            try out.print("    {{\"label\": \"{s}\", \"source\": \"{s}\"}}{s}\n", .{ item.label, item.source, comma });
        }
        try out.print("  ]\n}}\n", .{});
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "export")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools export <project-path> [--format fmz|brew|mac|linux|windows|backup] [--out <dir>]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const project_path = args[2];
        var format_str: []const u8 = "fmz";
        var out_dir: []const u8 = ".";
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
                format_str = args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
                out_dir = args[i + 1];
                i += 1;
            }
        }
        const home = std.mem.sliceTo(std.c.getenv("HOME") orelse ".", 0);
        const workspace_root = try std.fmt.allocPrint(gpa, "{s}/4orman", .{home});
        defer gpa.free(workspace_root);
        const result = try root.computeExport(gpa, io, project_path, workspace_root, format_str, out_dir);
        const success_str: []const u8 = if (result.success) "true" else "false";
        try out.print("{{\n  \"name\": \"{s}\",\n  \"version\": \"{s}\",\n  \"format\": \"{s}\",\n  \"output_path\": \"{s}\",\n  \"success\": {s},\n  \"note\": \"{s}\"\n}}\n", .{
            result.name, result.version, result.format, result.output_path, success_str, result.note,
        });
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "import")) {
        if (args.len < 3) {
            try err.print("usage: 4orman-tools import <source-path> [<4orman-root>]\n", .{});
            try err.flush();
            std.process.exit(1);
        }
        const source_path = args[2];
        const workspace_root = if (args.len >= 4) args[3] else blk: {
            const home = std.mem.sliceTo(std.c.getenv("HOME") orelse ".", 0);
            break :blk try std.fmt.allocPrint(gpa, "{s}/4orman", .{home});
        };
        const result = try root.computeImport(gpa, io, source_path, workspace_root);
        const success_str: []const u8 = if (result.success) "true" else "false";
        try out.print("{{\n  \"name\": \"{s}\",\n  \"dest_path\": \"{s}\",\n  \"source_format\": \"{s}\",\n  \"deps_note\": \"{s}\",\n  \"success\": {s},\n  \"note\": \"{s}\"\n}}\n", .{
            result.name, result.dest_path, result.source_format, result.deps_note, success_str, result.note,
        });
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "promotion-queue")) {
        const mode: root.PromotionQueueMode = blk: {
            if (args.len < 3 or std.mem.eql(u8, args[2], "list")) break :blk .list;
            if (std.mem.eql(u8, args[2], "clear")) break :blk .clear;
            if (std.mem.eql(u8, args[2], "add")) {
                if (args.len < 5) {
                    try err.print("usage: 4orman-tools promotion-queue add <name> <description>\n", .{});
                    try err.flush();
                    std.process.exit(1);
                }
                break :blk .{ .add = .{ .name = args[3], .description = args[4] } };
            }
            try err.print("usage: 4orman-tools promotion-queue [list | add <name> <description> | clear]\n", .{});
            try err.flush();
            std.process.exit(1);
        };
        const result = try root.computePromotionQueue(gpa, io, mode);
        if (std.mem.eql(u8, result.op, "list")) {
            try out.print("{{\"op\":\"list\",\"count\":{d},\"entries\":[", .{result.count});
            for (result.entries, 0..) |e, i| {
                const comma: []const u8 = if (i + 1 < result.entries.len) "," else "";
                try out.print("{{\"name\":\"{s}\",\"description\":\"{s}\",\"added_at\":\"{s}\"}}{s}", .{ e.name, e.description, e.added_at, comma });
            }
            try out.print("]}}\n", .{});
        } else {
            try out.print("{{\"op\":\"{s}\",\"count\":{d},\"success\":{},\"note\":\"{s}\"}}\n", .{ result.op, result.count, result.success, result.note });
        }
        try out.flush();
    } else if (std.mem.eql(u8, args[1], "registry")) {
        const result = root.computeRegistry();
        try out.print("{{\n  \"version\": \"{s}\",\n  \"subcommands\": [\n", .{result.version});
        for (result.subcommands, 0..) |cmd, i| {
            const comma: []const u8 = if (i + 1 < result.subcommands.len) "," else "";
            try out.print("    {{\"name\": \"{s}\", \"description\": \"{s}\", \"args\": \"{s}\"}}{s}\n", .{ cmd.name, cmd.description, cmd.args, comma });
        }
        try out.print("  ]\n}}\n", .{});
        try out.flush();
    } else {
        try err.print("unknown subcommand: {s}\n", .{args[1]});
        try err.flush();
        std.process.exit(1);
    }
}
