const std = @import("std");
const git = @import("git");

const header_buffer_size = 16 * 1024;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stderr = std.io.getStdErr().writer();

    const usage = "Usage: git <clone> [options] [directory]\n";

    if (args.len <= 2) {
        try stderr.print("{s}\n", .{usage});
        return error.ExpectedCommandArgument;
    }

    const cmd = args[1];
    const cmd_args = args[2..];

    // git clone --filter=blob:none <url>
    if (std.mem.eql(u8, cmd, "clone")) {
        var filter: ?[]const u8 = null;
        var branch_option: ?[]const u8 = null;

        const has_output_dir = cmd_args.len > 2 and !std.mem.startsWith(u8, cmd_args[cmd_args.len - 1], "--");

        // Get the uri and output directory depending on the number of arguments.
        const uri_option = if (has_output_dir)
            cmd_args[cmd_args.len - 2]
        else
            cmd_args[cmd_args.len - 1];

        var uri = std.Uri.parse(uri_option) catch |err| {
            try stderr.print("unable to parse uri '{s}': {s}\n", .{ uri_option, @errorName(err) });
            return error.ParseUri;
        };
        if (branch_option) |branch| {
            uri.fragment = .{
                .raw = branch,
            };
        }

        var out_dir_path = out_dir: {
            if (has_output_dir) {
                break :out_dir cmd_args[cmd_args.len - 1];
            } else {
                var uri_path = try uri.path.toRawMaybeAlloc(allocator);
                // Trim to the last path component
                var slash_it = std.mem.splitScalar(u8, uri_path, '/');
                while (slash_it.next()) |slash| {
                    uri_path = slash;
                }

                // Remove .git
                if (std.mem.eql(u8, uri_path, ".git")) {
                    uri_path = uri_path[0 .. uri_path.len - 4];
                }

                break :out_dir uri_path;
            }
        };

        // relative(allocator, from, to)
        out_dir_path = try std.fs.path.relative(allocator, ".", out_dir_path);

        var out_dir = try std.fs.cwd().makeOpenPath(out_dir_path, .{});
        defer out_dir.close();

        const arg_end = if (has_output_dir) cmd_args.len - 2 else cmd_args.len - 1;

        for (cmd_args[0..arg_end]) |arg| {
            if (std.mem.startsWith(u8, arg, "--filter=")) {
                filter = arg[9..];

                if (!(std.mem.eql(u8, filter.?, "blob:none"))) {
                    try stderr.print("unknown filter {s}\n", .{filter.?});
                }
            } else if (std.mem.startsWith(u8, arg, "--branch=")) {
                branch_option = arg[9..];
            } else {
                try stderr.print("unknown option {s}\n", .{arg});
            }
        }

        var http_client = std.http.Client{
            .allocator = allocator,
        };
        var http_headers_buffer: [header_buffer_size]u8 = undefined;
        var session = try git.Session.init(allocator, &http_client, uri, &http_headers_buffer);
        session.filter = filter;
        defer session.deinit();

        var git_dir = try out_dir.makeOpenPath(".git", .{});
        defer git_dir.close();

        // Determine the oid to fetch, either from the branch provided in the uri or from the HEAD ref.
        const want_oid = want_oid: {
            const want_ref =
                if (uri.fragment) |fragment| try fragment.toRawMaybeAlloc(allocator) else "HEAD";
            if (git.Oid.parseAny(want_ref)) |oid| break :want_oid oid else |_| {}

            const want_ref_head = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{want_ref});
            const want_ref_tag = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{want_ref});

            var ref_iterator = session.listRefs(.{
                .ref_prefixes = &.{ want_ref, want_ref_head, want_ref_tag },
                .include_peeled = true,
                .server_header_buffer = &http_headers_buffer,
            }) catch |err| {
                try stderr.print(
                    "unable to list refs: {s}\n",
                    .{@errorName(err)},
                );

                return error.ListRefs;
            };
            defer ref_iterator.deinit();
            while (ref_iterator.next() catch |err| {
                try stderr.print(
                    "unable to iterate refs: {s}\n",
                    .{@errorName(err)},
                );

                return error.IterateRefs;
            }) |ref| {
                if (std.mem.eql(u8, ref.name, want_ref) or
                    std.mem.eql(u8, ref.name, want_ref_head) or
                    std.mem.eql(u8, ref.name, want_ref_tag))
                {
                    break :want_oid ref.peeled orelse ref.oid;
                }
            }

            try stderr.print("ref not found: {s}\n", .{want_ref});
            return error.RefNotFound;
        };

        var want_oid_buf: [git.Oid.max_formatted_length]u8 = undefined;
        _ = try std.fmt.bufPrint(&want_oid_buf, "{}", .{want_oid});
        var fetch_stream = try session.fetch(&.{&want_oid_buf}, &http_headers_buffer);
        defer fetch_stream.deinit();

        var progress_node = std.Progress.start(.{
            .estimated_total_items = fetch_stream.len,
            .root_name = try std.fmt.allocPrint(allocator, "Fetch {s}", .{uri}),
        });
        defer progress_node.end();

        var objects_dir = try git_dir.makeOpenPath("objects", .{});
        defer objects_dir.close();

        var pack_dir = try objects_dir.makeOpenPath("pack", .{});
        defer pack_dir.close();

        var pack_file = try pack_dir.createFile(
            try std.fmt.allocPrint(allocator, "pack-{s}.pack", .{want_oid}),
            .{ .read = true },
        );
        defer pack_file.close();

        var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
        try fifo.pump(fetch_stream.reader(), pack_file.writer());
        try pack_file.sync();

        var index_file = try pack_dir.createFile(
            try std.fmt.allocPrint(allocator, "pack-{s}.idx", .{want_oid}),
            .{ .read = true },
        );
        defer index_file.close();
        {
            const index_prog_node = progress_node.start("Index pack", 0);
            defer index_prog_node.end();
            var index_buffered_writer = std.io.bufferedWriter(index_file.writer());
            try git.indexPack(allocator, want_oid, pack_file, index_buffered_writer.writer());
            try index_buffered_writer.flush();
            try index_file.sync();
        }

        {
            const checkout_prog_node = progress_node.start("Checkout", 0);
            defer checkout_prog_node.end();
            var repository = try git.Repository.init(allocator, want_oid, pack_file, index_file);
            defer repository.deinit();
            var diagnostics: git.Diagnostics = .{ .allocator = allocator };
            try repository.checkout(out_dir, want_oid, &diagnostics);

            if (diagnostics.errors.items.len > 0) {
                for (diagnostics.errors.items) |item| {
                    switch (item) {
                        .unable_to_create_file => |i| {
                            try stderr.print("unable to create file {s}: {any}\n", .{ i.file_name, i.code });
                        },
                        .unable_to_create_sym_link => |i| {
                            try stderr.print("unable to create symlink {s} -> {s}: {any}\n", .{ i.file_name, i.link_name, i.code });
                        },
                    }
                }
            }
        }

        {
            var head_file = try git_dir.createFile("HEAD", .{});
            defer head_file.close();

            var head_writer = head_file.writer();
            try head_writer.print("{}\n", .{want_oid});
            try head_file.sync();
        }
    } else {
        try stderr.print("unknown command\n", .{});
    }
}
