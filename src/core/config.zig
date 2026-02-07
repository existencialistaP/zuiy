const std = @import("std");
const util = @import("util.zig");

pub const Config = struct {
    power_hold_ms: u32 = 500,
    wallpaper_preview_max_dim: u32 = 720,
    wallpaper_cache_size: u32 = 6,
    wallpaper_live_apply: bool = false,
};

pub fn load(alloc: std.mem.Allocator) Config {
    var cfg = Config{};

    const path = configPath(alloc) catch return cfg;
    defer alloc.free(path);

    const data = util.readFileAlloc(alloc, path, 64 * 1024) catch return cfg;
    defer alloc.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            applyKey(&cfg, key, val);
        }
    }

    return cfg;
}

fn applyKey(cfg: *Config, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "power_hold_ms")) {
        if (std.fmt.parseUnsigned(u32, val, 10)) |v| cfg.power_hold_ms = v else |_| {}
        return;
    }
    if (std.mem.eql(u8, key, "wallpaper_preview_max_dim")) {
        if (std.fmt.parseUnsigned(u32, val, 10)) |v| cfg.wallpaper_preview_max_dim = v else |_| {}
        return;
    }
    if (std.mem.eql(u8, key, "wallpaper_cache_size")) {
        if (std.fmt.parseUnsigned(u32, val, 10)) |v| cfg.wallpaper_cache_size = v else |_| {}
        return;
    }
    if (std.mem.eql(u8, key, "wallpaper_live_apply")) {
        cfg.wallpaper_live_apply = parseBool(val);
        return;
    }
}

fn parseBool(val: []const u8) bool {
    return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "on");
}

fn configPath(alloc: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("ZUIY_CONFIG")) |p| {
        return try alloc.dupe(u8, p);
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return try std.fs.path.join(alloc, &.{ home, ".config", "zuiy", "config" });
}
