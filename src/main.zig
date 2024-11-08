const std = @import("std");
const ChildProcess = std.process.Child;

const LogStream = struct { eventMessage: []const u8, timestamp: []const u8 };

const allocator = std.heap.page_allocator;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

fn processScreenShare(entry: LogStream, temp: *std.ArrayList([]const u8), activeServices: *std.ArrayList([]u8)) !void {
    var items = std.mem.splitSequence(u8, entry.eventMessage, "\n");
    // Skip the first line (text)
    _ = items.next();
    while (items.next()) |itemDirty| {
        const needle = "bundleID: \"";

        const startIdx = std.mem.indexOf(u8, itemDirty, needle).? + needle.len;
        const endIdx = std.mem.indexOfPos(u8, itemDirty, startIdx, "\"").?;

        const item = itemDirty[startIdx..endIdx];
        try temp.append(item);
    }

    {
        for (temp.items) |value| {
            if (for (activeServices.items) |valueB| {
                if (std.mem.eql(u8, value, valueB)) {
                    break false;
                }
            } else true) {
                try stdout.print("New service screen:{s}\n", .{value});
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
            if (for (temp.items) |valueB| {
                if (std.mem.eql(u8, value, valueB)) {
                    break false;
                }
            } else true) {
                try stdout.print("Expiring service screen:{s}\n", .{value});
                const removedItem = activeServices.swapRemove(idx); // orderedRemove?
                allocator.free(removedItem);
            }
        }
    }
}

fn processScreenShareLegacy(entry: LogStream, temp: *std.ArrayList([]const u8), activeServices: *std.ArrayList([]u8)) !void {
    var items = std.mem.splitSequence(u8, entry.eventMessage, "\n");
    // Skip the first line (text)
    _ = items.next();
    while (items.next()) |item| {
        try temp.append(item);
    }

    {
        for (temp.items) |value| {
            if (for (activeServices.items) |valueB| {
                if (std.mem.eql(u8, value, valueB)) {
                    break false;
                }
            } else true) {
                try stdout.print("New service screen:{s}\n", .{value});
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
            if (for (temp.items) |valueB| {
                if (std.mem.eql(u8, value, valueB)) {
                    break false;
                }
            } else true) {
                try stdout.print("Expiring service screen:{s}\n", .{value});
                const removedItem = activeServices.swapRemove(idx); // orderedRemove?
                allocator.free(removedItem);
            }
        }
    }
}

fn processCamMicLoc(entry: LogStream, temp: *std.ArrayList([]const u8), activeServices: *std.ArrayList([]u8)) !void {
    const prefix = "Active activity attributions changed to [";
    const extracted = entry.eventMessage[prefix.len .. entry.eventMessage.len - 1];

    if (extracted.len != 0) {
        var items = std.mem.splitSequence(u8, extracted, ", ");
        while (items.next()) |itemDirty| {
            const item = itemDirty[1 .. itemDirty.len - 1];
            if (std.mem.eql(u8, item, "loc:System Services")) {
                continue;
            }
            try temp.append(item);
        }
    }

    // Check for new services
    {
        for (temp.items) |value| {
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
            if (for (temp.items) |valueB| {
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

fn read(filter: []const u8) !void {
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

    var activeServices_cam_mic_loc = try std.ArrayList([]u8).initCapacity(allocator, 5);
    defer activeServices_cam_mic_loc.deinit();

    var activeServices_screen = try std.ArrayList([]u8).initCapacity(allocator, 5);
    defer activeServices_screen.deinit();

    var activeServices_screen_legacy = try std.ArrayList([]u8).initCapacity(allocator, 5);
    defer activeServices_screen_legacy.deinit();

    var tempServices = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer tempServices.deinit();

    while (true) {
        const bytesRead = (try reader.readUntilDelimiter(&buffer, '\n')).len;
        const parsed = try std.json.parseFromSlice(LogStream, std.heap.page_allocator, buffer[0..bytesRead], .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (std.mem.startsWith(u8, parsed.value.eventMessage, "Content sharing streams ")) {
            try processScreenShare(parsed.value, &tempServices, &activeServices_screen);
        } else if (std.mem.startsWith(u8, parsed.value.eventMessage, "Legacy sharing bundle ids ")) {
            try processScreenShareLegacy(parsed.value, &tempServices, &activeServices_screen_legacy);
        } else if (std.mem.startsWith(u8, parsed.value.eventMessage, "Active ")) {
            try processCamMicLoc(parsed.value, &tempServices, &activeServices_cam_mic_loc);
        }

        tempServices.clearAndFree();
    }
}

pub fn main() !void {

    // We only see new events
    try read("(subsystem == 'com.apple.controlcenter' && category == 'sensor-indicators' && formatString BEGINSWITH 'Active ') OR (subsystem == 'com.apple.controlcenter' && category == 'contentSharing')");
}
