const std = @import("std");
const ChildProcess = std.process.Child;

const LogStream = struct { eventMessage: []const u8, timestamp: []const u8 };

const allocator = std.heap.page_allocator;

fn read(filter: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var proc = ChildProcess.init(&[_][]const u8{ "/usr/bin/log", "stream", "--style", "ndjson", "--predicate", filter }, allocator);
    proc.stdout_behavior = ChildProcess.StdIo.Pipe;
    proc.stderr_behavior = ChildProcess.StdIo.Ignore;
    try proc.spawn();

    // The max I've seen is around 5400 bytes
    var buffer: [8192]u8 = undefined;

    const reader = proc.stdout.?.reader();

    // Skip the first line: "Filtering the log data using ..."
    _ = try reader.readUntilDelimiter(&buffer, '\n');

    try stderr.print("Observing events...\n", .{});

    var activeServices = try std.ArrayList([]u8).initCapacity(allocator, 5);
    defer activeServices.deinit();

    var tempServices = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer tempServices.deinit();

    while (true) {
        const bytesRead = (try reader.readUntilDelimiter(&buffer, '\n')).len;
        const parsed = try std.json.parseFromSlice(LogStream, std.heap.page_allocator, buffer[0..bytesRead], .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (std.mem.startsWith(u8, parsed.value.eventMessage, "Active ")) {
            const prefix = "Active activity attributions changed to [";
            const extracted = parsed.value.eventMessage[prefix.len .. parsed.value.eventMessage.len - 1];
            if (extracted.len == 0) {
                try stderr.print("No items in active list\n", .{});
                // todo remove all from active list
                continue;
            }

            var items = std.mem.splitSequence(u8, extracted, ", ");

            while (items.next()) |itemDirty| {
                const item = itemDirty[1 .. itemDirty.len - 1];
                if (std.mem.eql(u8, item, "loc:System Services")) {
                    continue;
                }
                try tempServices.append(item);
            }

            // Check for new services
            {
                for (tempServices.items) |value| {
                    if (for (activeServices.items) |valueB| {
                        if (std.mem.eql(u8, value, valueB)) {
                            break false;
                        }
                    } else true) {
                        try stdout.print("New service {s}\n", .{value});
                        var str = try allocator.alloc(u8, value.len);
                        for (value, 0..) |char, i| {
                            str[i] = char;
                        }

                        try activeServices.append(str);
                    }
                }
            }

            // Check for removed services
            {
                for (activeServices.items, 0..) |value, idx| {
                    if (for (tempServices.items) |valueB| {
                        if (std.mem.eql(u8, value, valueB)) {
                            break false;
                        }
                    } else true) {
                        try stdout.print("Expiring service {s}\n", .{value});
                        const removedItem = activeServices.swapRemove(idx); // orderedRemove?
                        allocator.free(removedItem);
                    }
                }
            }
        }

        tempServices.clearAndFree();
    }
}

pub fn main() !void {
    try read("subsystem == 'com.apple.controlcenter' && category == 'sensor-indicators' && formatString BEGINSWITH 'Active '");
}
