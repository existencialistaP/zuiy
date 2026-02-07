const std = @import("std");

pub const TimeInfo = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const BatteryInfo = struct {
    capacity: u8,
    status: []const u8,
};

pub const UptimeInfo = struct {
    seconds: u64,
};

pub fn getTimeInfo() TimeInfo {
    const ts = std.time.timestamp();
    const secs = std.math.cast(u64, ts) orelse 0;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return .{
        .year = @as(i32, year_day.year),
        .month = @as(u8, month_day.month.numeric()),
        .day = @as(u8, month_day.day_index + 1),
        .hour = @as(u8, day_seconds.getHoursIntoDay()),
        .minute = @as(u8, day_seconds.getMinutesIntoHour()),
        .second = @as(u8, day_seconds.getSecondsIntoMinute()),
    };
}

pub fn getBatteryInfo(alloc: std.mem.Allocator) ?BatteryInfo {
    const base = "/sys/class/power_supply";
    var dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, "BAT")) continue;

        const cap_path = std.fs.path.join(alloc, &.{ base, name, "capacity" }) catch continue;
        defer alloc.free(cap_path);

        const status_path = std.fs.path.join(alloc, &.{ base, name, "status" }) catch continue;
        defer alloc.free(status_path);

        const cap_data = std.fs.openFileAbsolute(cap_path, .{}) catch continue;
        defer cap_data.close();
        const status_data = std.fs.openFileAbsolute(status_path, .{}) catch continue;
        defer status_data.close();

        var cap_buf: [8]u8 = undefined;
        const cap_len = cap_data.readAll(&cap_buf) catch continue;
        const cap_trim = std.mem.trim(u8, cap_buf[0..cap_len], " \t\r\n");
        const cap = std.fmt.parseUnsigned(u8, cap_trim, 10) catch continue;

        var status_buf: [32]u8 = undefined;
        const status_len = status_data.readAll(&status_buf) catch continue;
        const status_trim = std.mem.trim(u8, status_buf[0..status_len], " \t\r\n");
        const status_copy = alloc.dupe(u8, status_trim) catch continue;

        return .{
            .capacity = cap,
            .status = status_copy,
        };
    }

    return null;
}

pub fn freeBatteryInfo(alloc: std.mem.Allocator, info: BatteryInfo) void {
    alloc.free(info.status);
}

pub fn getUptimeInfo(alloc: std.mem.Allocator) ?UptimeInfo {
    const data = readFile(alloc, "/proc/uptime", 128) catch return null;
    defer alloc.free(data);

    var it = std.mem.tokenizeAny(u8, data, " \t\r\n");
    const first = it.next() orelse return null;
    const secs_f = std.fmt.parseFloat(f64, first) catch return null;
    if (secs_f < 0) return null;
    return .{ .seconds = @as(u64, @intFromFloat(secs_f)) };
}

fn readFile(alloc: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, max_size);
}
