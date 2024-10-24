const std = @import("std");

const err_str = "\x1b[31merror\x1b[0m: ";
const warning_str = "\x1b[33mwarning\x1b[0m: ";
const temp_name = "vidirz.tmp";
const default_editor = "vi";
const usage_fmt = "Usage: {0s} [-v|-d|-i|-f|-h] [DIR]\n";
const extra = "Run '{0s} -h' a for description of options.\n";
const help_fmt = usage_fmt ++
    \\   DIR  Specify which directory to edit. Default is the current working directory.
    \\    -v  Verbose mode. Show me what's going on.
    \\    -d  Dry run. Like verbose but don't do anything.
    \\    -i  Interactive mode. Prompt before each action.
    \\    -f  Force. Remove directories without prompting.
    \\    -h  Show this help message.
    \\
;

const Entry = struct {
    name: []const u8,
    action: union(enum) {
        keep,
        rename: []const u8,
        delete,
    } = .delete,
};

fn die(comptime msg: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print(msg, args) catch {};
    std.process.exit(1);
}

fn prompt(comptime fmt: []const u8, args: anytype) !bool {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdErr().writer();
    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    while (true) {
        stream.reset();
        try stdout.print(fmt ++ " y/n: ", args);
        stdin.streamUntilDelimiter(stream.writer(), '\n', buf.len) catch |e| die(
            "\n" ++ err_str ++ "read error: {s}\n",
            .{@errorName(e)},
        );
        const opt = stream.getWritten();
        if (std.mem.eql(u8, opt, "y") or std.mem.eql(u8, opt, "Y")) {
            return true;
        }
        if (std.mem.eql(u8, opt, "n") or std.mem.eql(u8, opt, "N")) {
            return false;
        }
    }
}

pub fn main() !void {
    var args = std.process.args();
    const me = args.next().?;

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var verbose = false;
    var dry_run = false;
    var interactive = false;
    var force = false;

    // Parse command line arguments
    while (args.next()) |arg| {
        if (arg[0] == '-') {
            const opts = arg[1..];
            if (opts.len == 0) {
                die(usage_fmt ++ extra ++ err_str ++ "empty option\n", .{me});
                std.process.exit(1);
            }

            for (opts) |opt| {
                switch (opt) {
                    'v' => verbose = true,
                    'd' => dry_run = true,
                    'i' => interactive = true,
                    'f' => force = true,
                    'h' => {
                        try stdout.print(help_fmt, .{me});
                        std.process.exit(0);
                    },
                    else => {
                        die(
                            usage_fmt ++ extra ++ err_str ++ "unknown option '{1c}'\n",
                            .{ me, opt },
                        );
                        std.process.exit(1);
                    },
                }
            }
            continue;
        }

        std.process.changeCurDir(arg) catch |e| die(
            err_str ++ "unable to change current working directory to '{s}': {s}\n",
            .{ arg, @errorName(e) },
        );
    }

    if (force) interactive = false;
    if (interactive and !dry_run) verbose = false;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var entries = std.ArrayList(Entry).init(allocator);
    defer {
        // Free allocated strings
        for (entries.items) |*entry| {
            allocator.free(entry.name);
            switch (entry.action) {
                .rename => |s| allocator.free(s),
                else => {},
            }
            entry.action = .delete;
        }
        entries.deinit();
    }

    // Read directory entries
    {
        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch |e| die(
            err_str ++ "unable to set iterate option for cwd: {s}\n",
            .{@errorName(e)},
        );
        defer dir.close();

        var dir_iter = dir.iterate();
        while (dir_iter.next() catch |e| die(
            err_str ++ "unable to read directory: {s}\n",
            .{@errorName(e)},
        )) |entry| {
            try entries.append(.{ .name = try allocator.dupe(u8, entry.name) });
        }
    }

    // Create temporary
    {
        const temp = std.fs.cwd().createFile(temp_name, .{}) catch |e| die(
            err_str ++ "unable create temporary: {s}\n",
            .{@errorName(e)},
        );
        defer temp.close();
        for (entries.items, 0..) |entry, i| {
            try temp.writer().print("{d:0>4}    {s}\n", .{ i, entry.name });
        }
    }

    var exit_code: u8 = 0;
    {
        defer {
            std.fs.cwd().deleteFile(temp_name) catch {
                stderr.print(warning_str ++ "couldn't delete temporary {s}\n", .{temp_name}) catch {};
            };
        }

        // Determine editor command
        const default_editor_dup = try allocator.dupe(u8, default_editor);
        var use_default_editor = false;
        const editor = get_editor: {
            var env = std.process.getEnvMap(allocator) catch |e| {
                try stderr.print(
                    warning_str ++ "unable to read environment map: {s}. Using default editor '{s}'.\n",
                    .{ @errorName(e), default_editor_dup },
                );
                use_default_editor = true;
                break :get_editor default_editor_dup;
            };
            defer env.deinit();

            break :get_editor try allocator.dupe(u8, env.get("EDITOR") orelse {
                try stderr.print(
                    warning_str ++ "EDITOR not set, using default '{s}'\n",
                    .{default_editor_dup},
                );
                use_default_editor = true;
                break :get_editor default_editor_dup;
            });
        };
        if (!use_default_editor) {
            allocator.free(default_editor_dup);
        }
        defer allocator.free(editor);

        // Run editor command
        var child = std.process.Child.init(&.{ editor, temp_name }, allocator);
        const term = child.spawnAndWait() catch |e| die(
            err_str ++ "unable to run '{s}': {s}\n",
            .{ editor, @errorName(e) },
        );

        switch (term) {
            .Exited => |code| if (code != 0)
                die(err_str ++ "{s} returned {d}\n", .{ editor, code }),
            else => die(err_str ++ "{s} did not exit\n", .{editor}),
        }

        // Read modified file
        {
            var temp = std.fs.cwd().openFile(temp_name, .{}) catch |e| die(
                err_str ++ "unable to reopen temporary: {s}\n",
                .{@errorName(e)},
            );
            defer temp.close();

            const reader = temp.reader();

            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();

            const num_orig_entries = entries.items.len;
            read_loop: while (true) {
                buf.clearRetainingCapacity();

                reader.streamUntilDelimiter(buf.writer(), ' ', null) catch |e| {
                    switch (e) {
                        error.EndOfStream => break :read_loop,
                        else => die(
                            err_str ++ "while reading from temporary: {s}\n",
                            .{@errorName(e)},
                        ),
                    }
                };

                const index = std.fmt.parseInt(usize, buf.items, 10) catch |e| die(
                    err_str ++ "parse error at '{s}': {s}\n",
                    .{ buf.items, @errorName(e) },
                );

                if (index > num_orig_entries)
                    die(
                        err_str ++ "too big index in temporary ({d} > {d})\n",
                        .{ index, num_orig_entries },
                    );

                if (entries.items[index].action != .delete)
                    die(err_str ++ "duplicate index {d}\n", .{index});

                // Read filename
                buf.clearRetainingCapacity();

                reader.streamUntilDelimiter(buf.writer(), '\n', null) catch |e| die(
                    err_str ++ "while reading filename for index {d}: {s}\n",
                    .{ index, @errorName(e) },
                );

                const filename = try allocator.dupe(u8, std.mem.trim(u8, buf.items, " "));

                var entry = &entries.items[index];

                // Update corresponding entry
                if (std.mem.eql(u8, entry.name, filename)) {
                    allocator.free(filename);
                    entry.action = .keep;
                } else {
                    entry.action = .{ .rename = filename };
                }
            }
        }

        if (dry_run) try stderr.print(warning_str ++ "dry run\n", .{});

        // Execute
        for (entries.items) |entry| {
            const stat = std.fs.cwd().statFile(entry.name) catch |e| {
                try stderr.print(err_str ++ "unable to stat file {s}: {s}\n", .{ entry.name, @errorName(e) });
                exit_code = 1;
                continue;
            };

            const is_dir = switch (stat.kind) {
                .directory => true,
                .file, .named_pipe => false,
                else => {
                    if (entry.action != .keep) {
                        try stdout.print(
                            "Skipping {s} {s}\n",
                            .{ @tagName(stat.kind), entry.name },
                        );
                    }
                    continue;
                },
            };

            switch (entry.action) {
                .keep => {},

                .rename => |new_name| {
                    if (!interactive or try prompt(
                        "Rename '{s}' to '{s}'?",
                        .{ entry.name, new_name },
                    )) {
                        if (!dry_run) {
                            std.fs.cwd().rename(entry.name, new_name) catch |e| {
                                try stderr.print(
                                    err_str ++ "unable to rename {s}: {s}\n",
                                    .{ entry.name, @errorName(e) },
                                );
                                exit_code = 1;
                                continue;
                            };
                        }
                        if (verbose) try stdout.print("rename    {s}    to    {s}.\n", .{ entry.name, new_name });
                    }
                },

                .delete => {
                    if (!interactive or try prompt("Delete {s}?", .{entry.name})) {
                        if (is_dir) {
                            if (!force and !try prompt("Delete directory {s}?", .{entry.name}))
                                continue;
                            if (!dry_run) {
                                std.fs.cwd().deleteTree(entry.name) catch |e| {
                                    try stderr.print(
                                        err_str ++ "unable to delete {s}: {s}\n",
                                        .{ entry.name, @errorName(e) },
                                    );
                                    exit_code = 1;
                                    continue;
                                };
                            }
                        } else {
                            if (!dry_run) {
                                std.fs.cwd().deleteFile(entry.name) catch |e| {
                                    try stderr.print(
                                        err_str ++ "unable to delete {s}: {s}\n",
                                        .{ entry.name, @errorName(e) },
                                    );
                                    exit_code = 1;
                                    continue;
                                };
                            }
                        }
                        if (verbose) try stdout.print("delete    {s}\n", .{entry.name});
                    }
                },
            }
        }
    }

    std.process.exit(exit_code);
}
