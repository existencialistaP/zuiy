const std = @import("std");
const rl = @import("raylib.zig").c;
const sysinfo = @import("../core/sysinfo.zig");

pub const Theme = struct {
    bg: rl.Color = .{ .r = 18, .g = 20, .b = 24, .a = 255 },
    fg: rl.Color = .{ .r = 230, .g = 230, .b = 230, .a = 255 },
    muted: rl.Color = .{ .r = 150, .g = 150, .b = 150, .a = 255 },
    accent: rl.Color = .{ .r = 80, .g = 160, .b = 255, .a = 255 },
    button: rl.Color = .{ .r = 35, .g = 38, .b = 45, .a = 255 },
    button_hover: rl.Color = .{ .r = 45, .g = 50, .b = 60, .a = 255 },
    button_active: rl.Color = .{ .r = 80, .g = 120, .b = 200, .a = 255 },
};

pub const FontHandle = struct {
    font: rl.Font,
    size: f32,
    is_custom: bool,
};

pub fn initWindow(title: []const u8, w: i32, h: i32) void {
    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitWindow(w, h, @ptrCast(title));
    rl.SetTargetFPS(60);
    rl.SetExitKey(rl.KEY_NULL);
}

pub fn centerWindow(w: i32, h: i32) void {
    const mw = rl.GetMonitorWidth(0);
    const mh = rl.GetMonitorHeight(0);
    const x = @divTrunc(mw - w, 2);
    const y = @divTrunc(mh - h, 2);
    rl.SetWindowPosition(x, y);
}

pub fn loadFont(alloc: std.mem.Allocator, size: f32) FontHandle {
    if (std.posix.getenv("ZUIY_FONT")) |path| {
        const path_z = alloc.dupeZ(u8, path) catch return .{ .font = rl.GetFontDefault(), .size = size, .is_custom = false };
        defer alloc.free(path_z);
        const font = rl.LoadFontEx(path_z.ptr, @intFromFloat(size), null, 0);
        if (font.texture.id != 0) {
            return .{ .font = font, .size = size, .is_custom = true };
        }
    }

    const candidates = [_][]const u8{
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
        "/usr/share/fonts/JetBrainsMonoNerdFont-Regular.ttf",
        "/usr/local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf",
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFontPropo-Regular.ttf",
    };
    for (candidates) |p| {
        if (std.fs.accessAbsolute(p, .{})) {
            const path_z = alloc.dupeZ(u8, p) catch break;
            defer alloc.free(path_z);
            const font = rl.LoadFontEx(path_z.ptr, @intFromFloat(size), null, 0);
            if (font.texture.id != 0) return .{ .font = font, .size = size, .is_custom = true };
        } else |_| {}
    }
    return .{ .font = rl.GetFontDefault(), .size = size, .is_custom = false };
}

pub fn unloadFont(f: FontHandle) void {
    if (f.is_custom) rl.UnloadFont(f.font);
}

pub fn measureText(font: rl.Font, size: f32, text: []const u8) f32 {
    var buf: [1024]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    return rl.MeasureTextEx(font, @ptrCast(&buf), size, 0).x;
}

pub fn clampWindowSize(w: i32, h: i32) struct { w: i32, h: i32 } {
    const mw = rl.GetMonitorWidth(0);
    const mh = rl.GetMonitorHeight(0);
    return .{ .w = @min(w, mw - 40), .h = @min(h, mh - 40) };
}

pub fn drawText(font: rl.Font, size: f32, text: []const u8, x: f32, y: f32, color: rl.Color) void {
    var buf: [1024]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    rl.DrawTextEx(font, @ptrCast(&buf), rl.Vector2{ .x = x, .y = y }, size, 0, color);
}

pub fn ellipsizeToBuf(font: rl.Font, size: f32, text: []const u8, max_w: f32, buf: []u8) []const u8 {
    if (text.len == 0) return text;
    if (measureText(font, size, text) <= max_w) return text;
    if (buf.len < 4) return text[0..0];

    const ellipsis = "...";
    var best: usize = 0;
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo <= hi) {
        const mid = (lo + hi) / 2;
        if (mid + ellipsis.len >= buf.len) {
            hi = if (mid == 0) 0 else mid - 1;
            continue;
        }
        std.mem.copyForwards(u8, buf[0..mid], text[0..mid]);
        std.mem.copyForwards(u8, buf[mid .. mid + ellipsis.len], ellipsis);
        const slice = buf[0 .. mid + ellipsis.len];
        if (measureText(font, size, slice) <= max_w) {
            best = mid;
            lo = mid + 1;
        } else if (mid == 0) {
            break;
        } else {
            hi = mid - 1;
        }
    }

    if (best == 0) {
        std.mem.copyForwards(u8, buf[0..ellipsis.len], ellipsis);
        return buf[0..ellipsis.len];
    }
    std.mem.copyForwards(u8, buf[0..best], text[0..best]);
    std.mem.copyForwards(u8, buf[best .. best + ellipsis.len], ellipsis);
    return buf[0 .. best + ellipsis.len];
}

pub fn headerHeight(size: f32) f32 {
    return size + 10;
}

pub fn drawHeader(alloc: std.mem.Allocator, font: rl.Font, size: f32, theme: Theme, padding: f32) void {
    var buf: [128]u8 = undefined;
    const t = sysinfo.getTimeInfo();
    var len = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}", .{ t.hour, t.minute }) catch {
        return;
    };

    if (sysinfo.getBatteryInfo(alloc)) |b| {
        defer sysinfo.freeBatteryInfo(alloc, b);
        var buf2: [128]u8 = undefined;
        const bat = std.fmt.bufPrint(&buf2, "  {d}% {s}", .{ b.capacity, b.status }) catch {
            return;
        };
        if (len.len + bat.len < buf.len) {
            @memcpy(buf[len.len .. len.len + bat.len], bat);
            len = buf[0 .. len.len + bat.len];
        }
    }

    drawText(font, size, len, padding, 6, theme.muted);
}
