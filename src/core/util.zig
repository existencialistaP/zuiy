const std = @import("std");

pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, max_size);
}

pub fn getenvAlloc(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const v = std.posix.getenv(name) orelse return null;
    return alloc.dupe(u8, v) catch null;
}
