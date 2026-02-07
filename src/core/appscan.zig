const std = @import("std");
const util = @import("util.zig");

pub const AppEntry = struct {
    name: []const u8,
    exec: []const u8,
    desktop_path: []const u8,
    icon: []const u8,
};

pub fn scanApps(alloc: std.mem.Allocator) ![]AppEntry {
    var apps = std.array_list.Managed(AppEntry).init(alloc);
    errdefer {
        for (apps.items) |app| {
            alloc.free(app.name);
            alloc.free(app.exec);
            alloc.free(app.desktop_path);
            if (app.icon.len > 0) alloc.free(app.icon);
        }
        apps.deinit();
    }

    var dirs = try collectAppDirs(alloc);
    defer {
        for (dirs.items) |d| alloc.free(d);
        dirs.deinit();
    }

    for (dirs.items) |dir_path| {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.walk(alloc) catch continue;
        defer it.deinit();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".desktop")) continue;

            const full_path = try std.fs.path.join(alloc, &.{ dir_path, entry.path });
            defer alloc.free(full_path);

            if (try parseDesktopFile(alloc, full_path)) |app| {
                try apps.append(app);
            }
        }
    }

    return apps.toOwnedSlice();
}

pub fn freeApps(alloc: std.mem.Allocator, apps: []AppEntry) void {
    for (apps) |app| {
        alloc.free(app.name);
        alloc.free(app.exec);
        alloc.free(app.desktop_path);
        if (app.icon.len > 0) alloc.free(app.icon);
    }
    alloc.free(apps);
}

fn collectAppDirs(alloc: std.mem.Allocator) !std.array_list.Managed([]const u8) {
    var dirs = std.array_list.Managed([]const u8).init(alloc);

    const home = std.posix.getenv("HOME") orelse "/";
    const xdg_data_home = std.posix.getenv("XDG_DATA_HOME");
    const data_home = if (xdg_data_home) |v| v else blk: {
        break :blk try std.fs.path.join(alloc, &.{ home, ".local", "share" });
    };
    defer if (xdg_data_home == null) alloc.free(data_home);

    try dirs.append(try std.fs.path.join(alloc, &.{ data_home, "applications" }));

    const xdg_data_dirs = std.posix.getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.tokenizeScalar(u8, xdg_data_dirs, ':');
    while (it.next()) |p| {
        try dirs.append(try std.fs.path.join(alloc, &.{ p, "applications" }));
    }

    return dirs;
}

fn parseDesktopFile(alloc: std.mem.Allocator, path: []const u8) !?AppEntry {
    const data = util.readFileAlloc(alloc, path, 512 * 1024) catch return null;
    defer alloc.free(data);

    var name: ?[]const u8 = null;
    var exec: ?[]const u8 = null;
    var hidden = false;
    var icon: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;

        if (std.mem.startsWith(u8, line, "NoDisplay=")) {
            if (std.mem.endsWith(u8, line, "true")) hidden = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "Hidden=")) {
            if (std.mem.endsWith(u8, line, "true")) hidden = true;
            continue;
        }

        if (name == null and std.mem.startsWith(u8, line, "Name=")) {
            name = std.mem.trim(u8, line[5..], " \t\r");
            continue;
        }
        if (exec == null and std.mem.startsWith(u8, line, "Exec=")) {
            exec = std.mem.trim(u8, line[5..], " \t\r");
            continue;
        }
        if (icon == null and std.mem.startsWith(u8, line, "Icon=")) {
            icon = std.mem.trim(u8, line[5..], " \t\r");
            continue;
        }
    }

    if (hidden) return null;
    if (name == null or exec == null) return null;

    const clean_exec = try sanitizeExec(alloc, exec.?);
    const name_copy = try alloc.dupe(u8, name.?);
    const path_copy = try alloc.dupe(u8, path);
    const icon_copy = if (icon) |ic| try resolveIcon(alloc, ic) else try alloc.dupe(u8, "");

    return AppEntry{
        .name = name_copy,
        .exec = clean_exec,
        .desktop_path = path_copy,
        .icon = icon_copy,
    };
}

fn sanitizeExec(alloc: std.mem.Allocator, exec: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(alloc);
    var token = std.array_list.Managed(u8).init(alloc);
    defer token.deinit();
    var in_quote: ?u8 = null;
    var first = true;
    var i: usize = 0;

    while (i < exec.len) : (i += 1) {
        const c = exec[i];
        if (in_quote) |q| {
            if (c == q) {
                in_quote = null;
            } else {
                try token.append(c);
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            in_quote = c;
            continue;
        }
        if (c == ' ' or c == '\t') {
            if (token.items.len > 0) {
                stripPlaceholders(&token);
                if (token.items.len > 0) {
                    if (!first) try out.append(' ');
                    try out.appendSlice(token.items);
                    first = false;
                }
                token.clearRetainingCapacity();
            }
            continue;
        }
        try token.append(c);
    }
    if (token.items.len > 0) {
        stripPlaceholders(&token);
        if (token.items.len > 0) {
            if (!first) try out.append(' ');
            try out.appendSlice(token.items);
        }
    }
    return out.toOwnedSlice();
}

fn stripPlaceholders(token: *std.array_list.Managed(u8)) void {
    if (token.items.len == 0) return;
    var out = std.array_list.Managed(u8).initCapacity(token.allocator, token.items.len) catch return;
    defer out.deinit();
    var i: usize = 0;
    while (i < token.items.len) : (i += 1) {
        const c = token.items[i];
        if (c == '%' and i + 1 < token.items.len) {
            i += 1;
            continue;
        }
        out.append(c) catch {};
    }
    token.clearRetainingCapacity();
    token.appendSlice(out.items) catch {};
}

fn resolveIcon(alloc: std.mem.Allocator, icon: []const u8) ![]const u8 {
    if (icon.len == 0) return alloc.dupe(u8, "");
    if (std.mem.indexOfScalar(u8, icon, '/')) |_| {
        return alloc.dupe(u8, icon);
    }
    if (std.mem.endsWith(u8, icon, ".png") or std.mem.endsWith(u8, icon, ".svg") or std.mem.endsWith(u8, icon, ".xpm")) {
        return alloc.dupe(u8, icon);
    }

    const candidates = [_][]const u8{
        "/usr/share/icons/hicolor/48x48/apps",
        "/usr/share/icons/hicolor/64x64/apps",
        "/usr/share/icons/hicolor/32x32/apps",
        "/usr/share/pixmaps",
    };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (candidates) |dir| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ dir, icon }) catch continue;
        if (std.fs.cwd().access(p, .{})) {
            return alloc.dupe(u8, p);
        } else |_| {}
        const p2 = std.fmt.bufPrint(&buf, "{s}/{s}.svg", .{ dir, icon }) catch continue;
        if (std.fs.cwd().access(p2, .{})) {
            return alloc.dupe(u8, p2);
        } else |_| {}
    }
    return alloc.dupe(u8, "");
}
