const std = @import("std");
const ChildProcess = std.process.Child;

const LogStream = struct { eventMessage: []const u8, timestamp: []const u8 };

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const PREFIX_SCREENSHARE = "screen:";

fn processScreenShare(entry: LogStream, temp: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    var items = std.mem.splitSequence(u8, entry.eventMessage, "\n");
    // Skip the first line (text)
    _ = items.next();
    while (items.next()) |itemDirty| {
        const needle = "bundleID: \"";

        const startIdx = std.mem.indexOf(u8, itemDirty, needle).? + needle.len;
        const endIdx = std.mem.indexOfPos(u8, itemDirty, startIdx, "\"").?;

        const item = itemDirty[startIdx..endIdx];

        const newStr = try allocator.alloc(u8, PREFIX_SCREENSHARE.len + item.len);

        std.mem.copyForwards(u8, newStr, PREFIX_SCREENSHARE);
        std.mem.copyForwards(u8, newStr[PREFIX_SCREENSHARE.len..], item);
        try temp.append(newStr);
    }
}

fn processScreenShareLegacy(entry: LogStream, temp: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    var items = std.mem.splitSequence(u8, entry.eventMessage, "\n");
    // Skip the first line (text)
    _ = items.next();
    while (items.next()) |item| {
        const newStr = try allocator.alloc(u8, PREFIX_SCREENSHARE.len + item.len);

        std.mem.copyForwards(u8, newStr, PREFIX_SCREENSHARE);
        std.mem.copyForwards(u8, newStr[PREFIX_SCREENSHARE.len..], item);
        try temp.append(newStr);
    }
}

fn processCamMicLoc(entry: LogStream, temp: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    const prefix = "Active activity attributions changed to [";
    const extracted = entry.eventMessage[prefix.len .. entry.eventMessage.len - 1];

    if (extracted.len != 0) {
        var items = std.mem.splitSequence(u8, extracted, ", ");
        while (items.next()) |itemDirty| {
            const item = itemDirty[1 .. itemDirty.len - 1];
            if (std.mem.eql(u8, item, "loc:System Services")) {
                continue;
            }

            const newStr = try allocator.alloc(u8, item.len);

            std.mem.copyForwards(u8, newStr, item);

            try temp.append(newStr);
        }
    }
}

const TYPE = enum { CAM_MIC_LOC, SCREEN, SCREEN_LEGACY };

fn read(filter: []const u8, allocator: std.mem.Allocator) !void {
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

    var activeServices_cam_mic_loc = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer activeServices_cam_mic_loc.deinit();

    var activeServices_screen = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer activeServices_screen.deinit();

    var activeServices_screen_legacy = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer activeServices_screen_legacy.deinit();

    var tempServices = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer tempServices.deinit();

    while (true) {
        const bytesRead = (try reader.readUntilDelimiter(&buffer, '\n')).len;
        const parsed = try std.json.parseFromSlice(LogStream, allocator, buffer[0..bytesRead], .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var serviceType: TYPE = undefined;
        if (std.mem.startsWith(u8, parsed.value.eventMessage, "Content sharing streams ")) {
            serviceType = TYPE.SCREEN;
            try processScreenShare(parsed.value, &tempServices, allocator);
        } else if (std.mem.startsWith(u8, parsed.value.eventMessage, "Legacy sharing bundle ids ")) {
            serviceType = TYPE.SCREEN_LEGACY;
            try processScreenShareLegacy(parsed.value, &tempServices, allocator);
        } else if (std.mem.startsWith(u8, parsed.value.eventMessage, "Active ")) {
            serviceType = TYPE.CAM_MIC_LOC;
            try processCamMicLoc(parsed.value, &tempServices, allocator);
        }

        {
            var activeServices = &switch (serviceType) {
                TYPE.CAM_MIC_LOC => activeServices_cam_mic_loc,
                TYPE.SCREEN => activeServices_screen,
                TYPE.SCREEN_LEGACY => activeServices_screen_legacy,
            };

            // Check for new services
            {
                for (tempServices.items) |value| {
                    if (for (activeServices.items) |valueB| {
                        if (std.mem.eql(u8, value, valueB)) {
                            break false;
                        }
                    } else true) {
                        try stdout.print("{s},newService,{s}\n", .{ parsed.value.timestamp, value });
                        const newStr = try allocator.alloc(u8, value.len);

                        std.mem.copyForwards(u8, newStr, value);
                        try activeServices.append(newStr);
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
                        try stdout.print("{s},expiredService,{s}\n", .{ parsed.value.timestamp, value });

                        const removedItem = activeServices.swapRemove(idx);
                        allocator.free(removedItem);
                    }
                }
            }
        }

        for (tempServices.items) |str| {
            allocator.free(str);
        }

        tempServices.clearAndFree();

        // {
        //     var combined = try std.ArrayList([]const u8).initCapacity(allocator, activeServices_cam_mic_loc.items.len + activeServices_screen.items.len + activeServices_screen_legacy.items.len);
        //     try combined.appendSlice(activeServices_cam_mic_loc.items);
        //     try combined.appendSlice(activeServices_screen.items);
        //     try combined.appendSlice(activeServices_screen_legacy.items);

        //     for (combined.items, 0..) |item, idx| {
        //         if (idx != 0) {
        //             // try stdout.print(",");
        //             try stdout.writeByte(',');
        //         }
        //         try stdout.print("{s}", .{item});
        //     }
        //     try stdout.writeByte('\n');
        // }
    }
}

pub fn main() !void {
    var allocatorBacking = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = allocatorBacking.allocator();

    // We only see new events - any existing consumers won't be detected until the next event
    // We could possibly perform a lookback with `log show`, or trigger an event by requesting a sensor
    // But, whatever.
    try read("(subsystem == 'com.apple.controlcenter' && category == 'sensor-indicators' && formatString BEGINSWITH 'Active ') OR (subsystem == 'com.apple.controlcenter' && category == 'contentSharing')", allocator);
}
