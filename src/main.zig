const std = @import("std");

const launcher = @import("commands/launcher.zig");
const power = @import("commands/power.zig");
const wallpaper = @import("commands/wallpaper.zig");
const notify = @import("commands/notify.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next(); // argv[0]
    const cmd = args.next();

    if (cmd == null) {
        try printUsage();
        return;
    }

    const cmd_str = cmd.?;
    if (std.mem.eql(u8, cmd_str, "launcher")) {
        try launcher.run(alloc);
    } else if (std.mem.eql(u8, cmd_str, "power")) {
        try power.run(alloc);
    } else if (std.mem.eql(u8, cmd_str, "wallpaper")) {
        try wallpaper.run(alloc);
    } else if (std.mem.eql(u8, cmd_str, "notify")) {
        try notify.run(alloc);
    } else {
        try printUsage();
        return;
    }
}

fn printUsage() !void {
    const out = std.fs.File.stdout();
    try out.writeAll(
        "zuiy <command>\n\n" ++
        "commands:\n" ++
        "  launcher\n" ++
        "  power\n" ++
        "  wallpaper\n" ++
        "  notify\n",
    );
}
