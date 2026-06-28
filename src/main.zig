const std = @import("std");
const root = @import("foreman_tools");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var err_buf: [512]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_writer.interface;

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    if (args.len < 2) {
        try err.print("usage: foreman-tools <subcommand> [args]\n", .{});
        try err.print("subcommands: status <workspace-path>\n", .{});
        try err.flush();
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[1], "status")) {
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
    } else {
        try err.print("unknown subcommand: {s}\n", .{args[1]});
        try err.flush();
        std.process.exit(1);
    }
}
