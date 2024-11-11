const std = @import("std");
const ChildProcess = std.process.Child;

const LogStream = struct { eventMessage: []const u8, subsystem: []const u8, processID: c_int, timestamp: []const u8 };

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const PREFIX_SCREENSHARE = "screen:";

fn processScreenRecord(entry: LogStream, temp: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    var items = std.mem.splitSequence(u8, entry.eventMessage, "\n");
    // Skip the first line (text)
    _ = items.next();
    while (items.next()) |itemDirty| {
        const needle = "bundleID: \"";

        const startIdx = std.mem.indexOf(u8, itemDirty, needle).? + needle.len;
        const endIdx = std.mem.indexOfPos(u8, itemDirty, startIdx, "\"").?;

        const item = itemDirty[startIdx..endIdx];

        const newStr = try std.fmt.allocPrint(allocator, "{s}{s}", .{ PREFIX_SCREENSHARE, item });
        try temp.append(newStr);
    }
}

fn processScreenRecordLegacy(entry: LogStream, temp: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    const newLineIndex = std.mem.indexOf(u8, entry.eventMessage, "\n");
    if (newLineIndex == null) {
        return;
    }

    var items = std.mem.splitSequence(u8, entry.eventMessage[newLineIndex.? + 1 ..], ", ");
    while (items.next()) |item| {
        // TODO: make an ignore file, or program args?
        if (std.mem.eql(u8, item, "com.lwouis.alt-tab-macos")) {
            continue;
        }

        const newStr = try std.fmt.allocPrint(allocator, "{s}{s}", .{ PREFIX_SCREENSHARE, item });
        try temp.append(newStr);
    }
}

fn processScreenRecordInbuilt(entry: LogStream, temp: *std.ArrayList([]const u8), source: std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    // WARN: The PID might not exist for the stop event since it might have closed already

    const pid = entry.processID;
    const ppid = processUtil.getppid_of_pid(pid);
    const ppid_path = processUtil.image_path_of_pid(ppid);

    const RecordingType = enum(u8) { Unknown, QuickTimePlayer, System };
    var recordingType = RecordingType.Unknown;
    if (std.mem.eql(u8, ppid_path, "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer")) {
        recordingType = RecordingType.System;
    } else if (std.mem.eql(u8, ppid_path, "/System/Applications/QuickTime Player.app/Contents/XPCServices/com.apple.quicktimeplayer.SharedPrefsVendor.xpc/Contents/MacOS/com.apple.quicktimeplayer.SharedPrefsVendor")) {
        recordingType = RecordingType.QuickTimePlayer;
    }

    // temp should result in a list of ALL active services.
    // Therefore get the existing active entries
    for (source.items) |item| {
        const newStr = try allocator.alloc(u8, item.len);
        std.mem.copyForwards(u8, newStr, item);
        try temp.append(newStr);
    }

    if (recordingType == RecordingType.Unknown) {
        // QuickTime Player's recorder and Cmd + Shift + 5 both share a mutex lock, so you can only use one or the other.
        // But you can manually call `/usr/sbin/screencapture -v ...`
        // We skip these cases because the other screen recording detections should pick them up
        return;
    }

    const service = try std.fmt.allocPrint(allocator, "{s}{s}", .{
        PREFIX_SCREENSHARE, switch (recordingType) {
            RecordingType.Unknown => "unknown",
            RecordingType.QuickTimePlayer => "quicktime",
            RecordingType.System => "system",
        },
    });

    if (std.mem.indexOf(u8, entry.eventMessage, "start") != null) {
        try temp.append(service);
        return;
    }

    if (std.mem.indexOf(u8, entry.eventMessage, "stop") != null) {
        var foundIdx: ?usize = null;
        for (temp.items, 0..) |value, idx| {
            if (std.mem.eql(u8, value, service)) {
                foundIdx = idx;
                break;
            }
        }

        if (foundIdx != null) {
            const removed = temp.swapRemove(foundIdx.?);
            allocator.free(removed);
        }
    } else {
        try stdout.print("UHMMMMM\n", .{});
        // TBH should panic at this point
        // uh oh
    }

    allocator.free(service);
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

const TYPE = enum { CAM_MIC_LOC, SCREEN, SCREEN_LEGACY, SCREEN_INBUILT };

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

    var activeServices_screen_inbuilt = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer activeServices_screen_inbuilt.deinit();

    var tempServices = try std.ArrayList([]const u8).initCapacity(allocator, 5);
    defer tempServices.deinit();

    while (true) {
        const bytesRead = (try reader.readUntilDelimiter(&buffer, '\n')).len;
        const parsed = try std.json.parseFromSlice(LogStream, allocator, buffer[0..bytesRead], .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var serviceType: TYPE = undefined;
        if (std.mem.startsWith(u8, parsed.value.eventMessage, "Active ")) {
            serviceType = TYPE.CAM_MIC_LOC;
            try processCamMicLoc(parsed.value, &tempServices, allocator);
        } else if (std.mem.startsWith(u8, parsed.value.eventMessage, "Content sharing streams ")) {
            serviceType = TYPE.SCREEN;
            try processScreenRecord(parsed.value, &tempServices, allocator);
        } else if (std.mem.startsWith(u8, parsed.value.eventMessage, "Legacy sharing bundle ids ")) {
            serviceType = TYPE.SCREEN_LEGACY;
            try processScreenRecordLegacy(parsed.value, &tempServices, allocator);
        } else if (std.mem.eql(u8, parsed.value.subsystem, "com.apple.screencapture")) {
            serviceType = TYPE.SCREEN_INBUILT;
            try processScreenRecordInbuilt(parsed.value, &tempServices, activeServices_screen_inbuilt, allocator);
        }

        {
            var activeServices = &switch (serviceType) {
                TYPE.CAM_MIC_LOC => activeServices_cam_mic_loc,
                TYPE.SCREEN => activeServices_screen,
                TYPE.SCREEN_LEGACY => activeServices_screen_legacy,
                TYPE.SCREEN_INBUILT => activeServices_screen_inbuilt,
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

const processUtil = @import("./processUtil.zig");

pub fn main() !void {
    var allocatorBacking = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = allocatorBacking.allocator();

    if (true) {
        // We only see new events - any existing consumers won't be detected until the next event
        // We could possibly perform a lookback with `log show`, or trigger an event by requesting a sensor
        // But, whatever.
        try read(
            \\(subsystem == 'com.apple.controlcenter' && category == 'sensor-indicators' && formatString BEGINSWITH 'Active ')
            \\OR (subsystem == 'com.apple.controlcenter' && category == 'contentSharing')
            \\OR (subsystem == 'com.apple.screencapture' && formatString BEGINSWITH 'sampleBuffer: ')
        , allocator);
    }
}
