const std = @import("std");
const rl = @import("../core/raylib.zig").c;

const ui = @import("../core/ui.zig");
const config = @import("../core/config.zig");

const CacheEntry = struct {
    path: []const u8,
    tex: rl.Texture2D,
    used: u64,
};

pub fn run(alloc: std.mem.Allocator) !void {
    const cfg = config.load(alloc);
    const paths = try collectCandidates(alloc);
    defer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit();
    }

    ui.initWindow("zuiy wallpaper", 900, 600);
    defer rl.CloseWindow();

    const theme = ui.Theme{};
    const font_size: f32 = 22;
    const font_handle = ui.loadFont(alloc, font_size);
    defer ui.unloadFont(font_handle);

    const line_h: f32 = font_size + 6;
    const padding: f32 = 16;
    const list_w: f32 = 260;
    const list_max: usize = 16;
    const header_h = ui.headerHeight(font_size);

    const desired = ui.clampWindowSize(900, 600);
    rl.SetWindowSize(desired.w, desired.h);
    ui.centerWindow(desired.w, desired.h);

    var cursor: usize = 0;
    var scroll: usize = 0;
    var selected: ?[]const u8 = null;

    var cache = std.array_list.Managed(CacheEntry).init(alloc);
    defer {
        for (cache.items) |e| {
            rl.UnloadTexture(e.tex);
            alloc.free(e.path);
        }
        cache.deinit();
    }
    var use_counter: u64 = 0;

    var has_tex = false;
    var tex: rl.Texture2D = undefined;
    var last_idx: ?usize = null;
    var pending_idx: ?usize = null;
    var preview_deadline: f64 = 0;
    const preview_delay: f64 = 0.0;
    var live_apply = cfg.wallpaper_live_apply;
    var last_live_idx: ?usize = null;

    var filter = std.array_list.Managed(u8).init(alloc);
    defer filter.deinit();
    var filter_mode = false;
    var visible = std.array_list.Managed(usize).init(alloc);
    defer visible.deinit();

    while (!rl.WindowShouldClose()) {
        const now = rl.GetTime();
        if (filter_mode) {
            handleFilterInput(&filter, &filter_mode);
        } else {
            if (rl.IsKeyPressed(rl.KEY_SLASH)) filter_mode = true;
            if (rl.IsKeyPressed(rl.KEY_ESCAPE) or rl.IsKeyPressed(rl.KEY_Q)) break;
        }
        if (rl.IsKeyPressed(rl.KEY_ENTER)) {
            if (paths.items.len > 0) {
                const idx = if (visible.items.len > 0) visible.items[cursor] else cursor;
                selected = paths.items[idx];
            }
            break;
        }
        if (!filter_mode and rl.IsKeyPressed(rl.KEY_SPACE)) {
            live_apply = !live_apply;
        }

        if (rl.IsKeyPressed(rl.KEY_TAB) or rl.IsKeyPressed(rl.KEY_DOWN) or rl.IsKeyPressed(rl.KEY_J)) {
            if (cursor + 1 < paths.items.len) cursor += 1;
        }
        if (rl.IsKeyPressed(rl.KEY_UP) or (rl.IsKeyDown(rl.KEY_LEFT_SHIFT) and rl.IsKeyPressed(rl.KEY_TAB)) or rl.IsKeyPressed(rl.KEY_K)) {
            if (cursor > 0) cursor -= 1;
        }
        if (rl.IsKeyPressed(rl.KEY_PAGE_DOWN)) {
            const step: usize = 5;
            if (paths.items.len > 0) cursor = @min(cursor + step, paths.items.len - 1);
        }
        if (rl.IsKeyPressed(rl.KEY_PAGE_UP)) {
            const step: usize = 5;
            cursor = if (cursor > step) cursor - step else 0;
        }

        const wheel = rl.GetMouseWheelMove();
        if (wheel < 0 and cursor + 1 < paths.items.len) cursor += 1;
        if (wheel > 0 and cursor > 0) cursor -= 1;

        buildVisible(paths.items, filter.items, &visible);
        const list_count = if (visible.items.len > 0) visible.items.len else paths.items.len;
        if (cursor >= list_count and list_count > 0) cursor = list_count - 1;
        const list_rows = @min(list_max, list_count);
        if (cursor < scroll) scroll = cursor;
        if (cursor >= scroll + list_rows and list_rows > 0) scroll = cursor - (list_rows - 1);

        // debounce preview load
        if (list_count > 0) {
            const actual_idx = if (visible.items.len > 0) visible.items[cursor] else cursor;
            if (last_idx == null or last_idx.? != actual_idx) {
                if (pending_idx == null or pending_idx.? != actual_idx) {
                    pending_idx = actual_idx;
                    preview_deadline = now + preview_delay;
                }
                if (live_apply and (last_live_idx == null or last_live_idx.? != actual_idx)) {
                    applyWallpaper(alloc, paths.items[actual_idx]) catch {};
                    last_live_idx = actual_idx;
                }
            }
        } else {
            pending_idx = null;
            last_idx = null;
            has_tex = false;
        }

        if (pending_idx != null and now >= preview_deadline) {
            const idx = pending_idx.?;
            if (idx < paths.items.len) {
                const path = paths.items[idx];
                if (getCachedTexture(alloc, &cache, &use_counter, path, @intCast(cfg.wallpaper_preview_max_dim), @intCast(cfg.wallpaper_cache_size))) |t| {
                    tex = t;
                    has_tex = true;
                    last_idx = idx;
                } else {
                    has_tex = false;
                }
            }
            pending_idx = null;
        }

        rl.BeginDrawing();
        rl.ClearBackground(theme.bg);
        ui.drawHeader(alloc, font_handle.font, font_size, theme, padding);
        if (filter.items.len > 0 or filter_mode or live_apply) {
            var buf: [256]u8 = undefined;
            const live = if (live_apply) " live" else "";
            const label = std.fmt.bufPrint(&buf, "/{s}{s}", .{ filter.items, live }) catch "/";
            ui.drawText(font_handle.font, font_size, label, padding + 140, 6, theme.muted);
        }

        // list panel
        const list_h = @as(f32, @floatFromInt(rl.GetScreenHeight())) - header_h;
        rl.DrawRectangleRec(rl.Rectangle{ .x = 0, .y = header_h, .width = list_w, .height = list_h }, theme.button);

        const y: f32 = header_h + padding + 6;
        var row: usize = 0;
        while (row < list_rows and scroll + row < list_count) : (row += 1) {
            const vi = scroll + row;
            const idx = if (visible.items.len > 0) visible.items[vi] else vi;
            const name = basename(paths.items[idx]);
            const is_sel = vi == cursor;
            const rect = rl.Rectangle{ .x = padding, .y = y + @as(f32, @floatFromInt(row)) * line_h, .width = list_w - 2 * padding, .height = line_h };
            if (is_sel) rl.DrawRectangleRec(rect, theme.button_active) else rl.DrawRectangleRec(rect, theme.button_hover);
            var name_buf: [256]u8 = undefined;
            const max_w = rect.width - 12;
            const out = ui.ellipsizeToBuf(font_handle.font, font_size, name, max_w, &name_buf);
            ui.drawText(font_handle.font, font_size, out, rect.x + 6, rect.y + 2, theme.fg);
        }

        // preview panel
        const preview_x = list_w + padding;
        const preview_y = header_h + padding;
        const preview_w = @as(f32, @floatFromInt(rl.GetScreenWidth())) - preview_x - padding;
        const preview_h = @as(f32, @floatFromInt(rl.GetScreenHeight())) - header_h - padding * 2;
        rl.DrawRectangleLinesEx(rl.Rectangle{ .x = preview_x, .y = preview_y, .width = preview_w, .height = preview_h }, 2, theme.muted);

        rl.BeginScissorMode(@intFromFloat(preview_x), @intFromFloat(preview_y), @intFromFloat(preview_w), @intFromFloat(preview_h));
        if (has_tex) {
            const tex_w = @as(f32, @floatFromInt(tex.width));
            const tex_h = @as(f32, @floatFromInt(tex.height));
            const scale = @min(preview_w / tex_w, preview_h / tex_h);
            const dst_w = tex_w * scale;
            const dst_h = tex_h * scale;
            const dst_x = preview_x + (preview_w - dst_w) / 2;
            const dst_y = preview_y + (preview_h - dst_h) / 2;
            const src = rl.Rectangle{ .x = 0, .y = 0, .width = tex_w, .height = tex_h };
            const dst = rl.Rectangle{ .x = dst_x, .y = dst_y, .width = dst_w, .height = dst_h };
            rl.DrawTexturePro(tex, src, dst, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
        } else {
            ui.drawText(font_handle.font, font_size, "(sem preview)", preview_x + 10, preview_y + 20, theme.muted);
        }
        rl.EndScissorMode();

        // mouse click select
        if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            const mp = rl.GetMousePosition();
            if (mp.x < list_w and mp.y >= y and mp.y < y + @as(f32, @floatFromInt(list_rows)) * line_h) {
                const idx = @as(usize, @intFromFloat((mp.y - y) / line_h));
                if (scroll + idx < list_count) {
                    cursor = scroll + idx;
                    const actual = if (visible.items.len > 0) visible.items[cursor] else cursor;
                    selected = paths.items[actual];
                    rl.EndDrawing();
                    break;
                }
            }
        }

        rl.EndDrawing();
    }

    if (selected) |path| {
        try applyWallpaper(alloc, path);
    }
}

fn basename(path: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, path, '/');
    return it.next() orelse path;
}

fn collectCandidates(alloc: std.mem.Allocator) !std.array_list.Managed([]const u8) {
    var list = std.array_list.Managed([]const u8).init(alloc);

    const home = std.posix.getenv("HOME") orelse "/";
    const dir_env = std.posix.getenv("ZUIY_WALLPAPER_DIR");

    var dirs = std.array_list.Managed([]const u8).init(alloc);
    defer dirs.deinit();

    if (dir_env) |d| try dirs.append(d);
    try dirs.append(try std.fs.path.join(alloc, &.{ home, "Pictures" }));
    try dirs.append(try std.fs.path.join(alloc, &.{ home, "Pictures", "Wallpapers" }));
    try dirs.append(try std.fs.path.join(alloc, &.{ home, "dotfiles", "wallpapers" }));

    defer {
        for (dirs.items) |d| {
            if (dir_env == null or !std.mem.eql(u8, d, dir_env.?)) alloc.free(d);
        }
    }

    for (dirs.items) |dir_path| {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!isImage(entry.name)) continue;
            const full = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
            try list.append(full);
        }
    }

    return list;
}

fn isImage(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".png") or
        std.mem.endsWith(u8, name, ".jpg") or
        std.mem.endsWith(u8, name, ".jpeg") or
        std.mem.endsWith(u8, name, ".webp");
}

fn applyWallpaper(alloc: std.mem.Allocator, path: []const u8) !void {
    if (std.posix.getenv("ZUIY_WALLPAPER_CMD")) |cmdline| {
        var args = std.array_list.Managed([]const u8).init(alloc);
        defer args.deinit();

        var it = std.mem.tokenizeAny(u8, cmdline, " \t");
        while (it.next()) |tok| try args.append(tok);
        try args.append(path);
        try spawn(alloc, args.items);
        return;
    }

    try spawn(alloc, &.{ "swww", "img", path });
}

fn spawn(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawn();
}

fn handleFilterInput(filter: *std.array_list.Managed(u8), filter_mode: *bool) void {
    var c: i32 = rl.GetCharPressed();
    while (c > 0) : (c = rl.GetCharPressed()) {
        if (c >= 32 and c < 127) filter.append(@intCast(c)) catch {};
    }
    if (rl.IsKeyPressed(rl.KEY_BACKSPACE)) {
        if (filter.items.len > 0) _ = filter.pop();
    }
    if (rl.IsKeyPressed(rl.KEY_ENTER) or rl.IsKeyPressed(rl.KEY_ESCAPE)) {
        filter_mode.* = false;
    }
    if (rl.IsKeyPressed(rl.KEY_SLASH)) {
        filter_mode.* = true;
    }
}

fn buildVisible(paths: []const []const u8, filter: []const u8, out: *std.array_list.Managed(usize)) void {
    out.clearRetainingCapacity();
    if (filter.len == 0) return;
    for (paths, 0..) |p, i| {
        if (containsIgnoreCase(p, filter)) out.append(i) catch {};
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            const h = haystack[i + j];
            if (std.ascii.toLower(h) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn getCachedTexture(alloc: std.mem.Allocator, cache: *std.array_list.Managed(CacheEntry), use_counter: *u64, path: []const u8, max_dim: i32, cache_limit: i32) ?rl.Texture2D {
    use_counter.* += 1;
    var i: usize = 0;
    while (i < cache.items.len) : (i += 1) {
        if (std.mem.eql(u8, cache.items[i].path, path)) {
            cache.items[i].used = use_counter.*;
            return cache.items[i].tex;
        }
    }

    const tex = loadPreviewTexture(alloc, path, max_dim);
    if (tex.id == 0) return null;

    const dup_path = alloc.dupe(u8, path) catch {
        rl.UnloadTexture(tex);
        return null;
    };

    if (cache.items.len >= @as(usize, @intCast(cache_limit))) {
        var evict_idx: usize = 0;
        var min_used = cache.items[0].used;
        var j: usize = 1;
        while (j < cache.items.len) : (j += 1) {
            if (cache.items[j].used < min_used) {
                min_used = cache.items[j].used;
                evict_idx = j;
            }
        }
        rl.UnloadTexture(cache.items[evict_idx].tex);
        alloc.free(cache.items[evict_idx].path);
        cache.items[evict_idx] = .{ .path = dup_path, .tex = tex, .used = use_counter.* };
    } else {
        cache.append(.{ .path = dup_path, .tex = tex, .used = use_counter.* }) catch {
            rl.UnloadTexture(tex);
            alloc.free(dup_path);
            return null;
        };
    }
    return tex;
}

fn loadPreviewTexture(alloc: std.mem.Allocator, path: []const u8, max_dim: i32) rl.Texture2D {
    if (getThumbPath(alloc, path)) |thumb_path| {
        defer alloc.free(thumb_path);
        if (std.fs.accessAbsolute(thumb_path, .{})) {
            if (loadTextureFromPath(thumb_path)) |t| return t;
        } else |_| {}
        if (generateThumb(path, thumb_path, max_dim)) {
            if (loadTextureFromPath(thumb_path)) |t| return t;
        }
    }

    if (loadTextureFromPath(path)) |t| return t;
    return rl.Texture2D{};
}

fn loadTextureFromPath(path: []const u8) ?rl.Texture2D {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const n = @min(path.len, buf.len - 1);
    @memcpy(buf[0..n], path[0..n]);
    buf[n] = 0;
    const tex = rl.LoadTexture(@ptrCast(&buf));
    if (tex.id == 0) return null;
    return tex;
}

fn getThumbPath(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const cache_root = std.posix.getenv("XDG_CACHE_HOME") orelse null;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = if (cache_root) |r| r else blk: {
        const home = std.posix.getenv("HOME") orelse return null;
        break :blk std.fmt.bufPrint(&root_buf, "{s}/.cache", .{home}) catch return null;
    };

    const st = std.fs.cwd().statFile(path) catch return null;
    const key = hashKey(path, st.mtime);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/zuiy/thumbs", .{root}) catch return null;
    std.fs.cwd().makePath(dir) catch {};

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&out_buf, "{s}/{s}.png", .{ dir, key[0..] }) catch return null;
    return alloc.dupe(u8, p) catch null;
}

fn hashKey(path: []const u8, mtime: i128) [16]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    var tbuf: [16]u8 = undefined;
    const t = std.fmt.bufPrint(&tbuf, "{d}", .{mtime}) catch "0";
    hasher.update(t);
    const h = hasher.final();
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{h}) catch {};
    return out;
}

fn generateThumb(src: []const u8, dst: []const u8, max_dim: i32) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const n = @min(src.len, buf.len - 1);
    @memcpy(buf[0..n], src[0..n]);
    buf[n] = 0;
    const img = rl.LoadImage(@ptrCast(&buf));
    if (img.data == null) return false;

    var work = img;
    const w = work.width;
    const h = work.height;
    if (w > max_dim or h > max_dim) {
        const scale = @min(@as(f32, @floatFromInt(max_dim)) / @as(f32, @floatFromInt(w)), @as(f32, @floatFromInt(max_dim)) / @as(f32, @floatFromInt(h)));
        const nw = @as(i32, @intFromFloat(@as(f32, @floatFromInt(w)) * scale));
        const nh = @as(i32, @intFromFloat(@as(f32, @floatFromInt(h)) * scale));
        rl.ImageResize(&work, nw, nh);
    }
    var out_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const dn = @min(dst.len, out_buf.len - 1);
    @memcpy(out_buf[0..dn], dst[0..dn]);
    out_buf[dn] = 0;
    const ok = rl.ExportImage(work, @ptrCast(&out_buf));
    rl.UnloadImage(work);
    return ok;
}
