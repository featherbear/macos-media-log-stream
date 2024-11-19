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
        const foundIdx = strContains(u8, temp.items, service);
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

            const newStr = try allocator.alloc(u8, item.len);
            std.mem.copyForwards(u8, newStr, item);

            try temp.append(newStr);
        }
    }
}

const TYPE = enum { CAM_MIC_LOC, SCREEN, SCREEN_LEGACY, SCREEN_INBUILT };

fn read(allocator: std.mem.Allocator, filter: []const u8, ignored: *std.ArrayList([]const u8), callbackWriter: ?std.io.Writer(std.fs.File, std.fs.File.WriteError, std.fs.File.write)) !void {
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

    var activeServices = struct { cam_mic_loc: std.ArrayList([]const u8), screen: std.ArrayList([]const u8), screen_legacy: std.ArrayList([]const u8), screen_inbuilt: std.ArrayList([]const u8) }{
        .cam_mic_loc = try std.ArrayList([]const u8).initCapacity(allocator, 5),
        .screen = try std.ArrayList([]const u8).initCapacity(allocator, 5),
        .screen_legacy = try std.ArrayList([]const u8).initCapacity(allocator, 5),
        .screen_inbuilt = try std.ArrayList([]const u8).initCapacity(allocator, 5),
    };
    var tempServices = try std.ArrayList([]const u8).initCapacity(allocator, 5);

    defer activeServices.cam_mic_loc.deinit();
    defer activeServices.screen.deinit();
    defer activeServices.screen_legacy.deinit();
    defer activeServices.screen_inbuilt.deinit();
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
            try processScreenRecordInbuilt(parsed.value, &tempServices, activeServices.screen_inbuilt, allocator);
        }

        // Remove ignored services
        {
            var remainingChecks = tempServices.items.len;
            var idx: usize = 0;
            while (remainingChecks > 0) {
                if (strContains(u8, ignored.items, tempServices.items[idx]) != null) {
                    const removed = tempServices.swapRemove(idx);
                    allocator.free(removed);
                } else {
                    idx += 1;
                }
                remainingChecks -= 1;
            }
        }

        {
            var activeService = &switch (serviceType) {
                TYPE.CAM_MIC_LOC => activeServices.cam_mic_loc,
                TYPE.SCREEN => activeServices.screen,
                TYPE.SCREEN_LEGACY => activeServices.screen_legacy,
                TYPE.SCREEN_INBUILT => activeServices.screen_inbuilt,
            };

            // Check for new services
            {
                for (tempServices.items) |value| {
                    if (strContains(u8, activeService.items, value) == null) {
                        try stdout.print("{s},newService,{s}\n", .{ parsed.value.timestamp, value });

                        const newStr = try allocator.alloc(u8, value.len);
                        std.mem.copyForwards(u8, newStr, value);

                        try activeService.append(newStr);
                    }
                }
            }

            // Check for removed services
            {
                for (activeService.items, 0..) |value, idx| {
                    if (strContains(u8, tempServices.items, value) == null) {
                        try stdout.print("{s},expiredService,{s}\n", .{ parsed.value.timestamp, value });

                        const removedItem = activeService.swapRemove(idx);
                        allocator.free(removedItem);

                        // Iterate just once
                        break;
                    }
                }
            }
        }

        for (tempServices.items) |str| {
            allocator.free(str);
        }

        tempServices.clearAndFree();

        if (callbackWriter) |callback| {
            var combined = try std.ArrayList([]const u8).initCapacity(allocator, activeServices.cam_mic_loc.items.len + activeServices.screen.items.len + activeServices.screen_legacy.items.len + activeServices.screen_inbuilt.items.len);

            try combined.appendSlice(activeServices.cam_mic_loc.items);
            try combined.appendSlice(activeServices.screen.items);
            try combined.appendSlice(activeServices.screen_legacy.items);
            try combined.appendSlice(activeServices.screen_inbuilt.items);

            for (combined.items, 0..) |item, idx| {
                if (idx != 0) {
                    try callback.writeByte(',');
                }

                try callback.print("{s}", .{item});
            }
            try callback.writeByte('\n');
        }
    }
}

const processUtil = @import("./processUtil.zig");

fn strContains(comptime T: type, haystack: [][]const T, needle: []const T) ?usize {
    for (haystack, 0..) |haystackItem, idx| {
        if (std.mem.eql(T, haystackItem, needle)) {
            return idx;
        }
    } else {
        return null;
    }
}

pub fn main() !void {
    var allocatorBacking = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = allocatorBacking.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var ignoredApplications = std.ArrayList([]const u8).init(allocator);
    var callbackArguments = std.ArrayList([]const u8).init(allocator);

    try stderr.print("--------------------\n", .{});
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            break;
        }
        try stderr.print("Ignoring {s}\n", .{arg});
        try ignoredApplications.append(arg);
    }

    while (args.next()) |arg| try callbackArguments.append(arg);

    var callbackWriter: ?std.io.Writer(std.fs.File, std.fs.File.WriteError, std.fs.File.write) = undefined;

    if (callbackArguments.items.len != 0) {
        var callbackProc = ChildProcess.init(callbackArguments.items, allocator);
        callbackProc.stdin_behavior = ChildProcess.StdIo.Pipe;
        callbackProc.stdout_behavior = ChildProcess.StdIo.Inherit;
        callbackProc.stderr_behavior = ChildProcess.StdIo.Inherit;

        try callbackProc.spawn();
        callbackWriter = callbackProc.stdin.?.writer();

        try stderr.print("Callback process started: {s}\n", .{callbackArguments.items});
    }

    if (true) {
        // We only see new events - any existing consumers won't be detected until the next event
        // We could possibly perform a lookback with `log show`, or trigger an event by requesting a sensor
        // But, whatever.
        try read(allocator,
            \\(subsystem == 'com.apple.controlcenter' && category == 'sensor-indicators' && formatString BEGINSWITH 'Active ')
            \\OR (subsystem == 'com.apple.controlcenter' && category == 'contentSharing')
            \\OR (subsystem == 'com.apple.screencapture' && formatString BEGINSWITH 'sampleBuffer: ')
        , &ignoredApplications, callbackWriter);
    }
}
