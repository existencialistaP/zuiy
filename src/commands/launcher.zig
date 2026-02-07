const std = @import("std");
const rl = @import("../core/raylib.zig").c;

const ui = @import("../core/ui.zig");
const appscan = @import("../core/appscan.zig");
const fuzzy = @import("../core/fuzzy.zig");
const config = @import("../core/config.zig");

const IconEntry = struct {
    path: []const u8,
    tex: rl.Texture2D,
};

pub fn run(alloc: std.mem.Allocator) !void {
    _ = config.load(alloc);
    const apps = try appscan.scanApps(alloc);
    defer appscan.freeApps(alloc, apps);

    var matches = std.array_list.Managed(usize).init(alloc);
    defer matches.deinit();
    try buildMatches(apps, &matches, "");

    var query = std.array_list.Managed(u8).init(alloc);
    defer query.deinit();

    ui.initWindow("zuiy launcher", 640, 420);
    defer rl.CloseWindow();

    const theme = ui.Theme{};
    const font_size: f32 = 24;
    const font_handle = ui.loadFont(alloc, font_size);
    defer ui.unloadFont(font_handle);

    const line_h: f32 = font_size + 6;
    const padding: f32 = 16;
    const list_max: usize = 12;
    const header_h = ui.headerHeight(font_size);

    // dynamic size after font
    const desired = calcWindowSize(font_handle.font, font_size, apps, list_max, padding, line_h, header_h);
    const clamped = ui.clampWindowSize(desired.w, desired.h);
    rl.SetWindowSize(clamped.w, clamped.h);
    ui.centerWindow(clamped.w, clamped.h);

    var cursor: usize = 0;
    var scroll: usize = 0;
    var should_launch = false;
    var repeat_dir: i32 = 0;
    var next_repeat: f64 = 0;
    const repeat_delay: f64 = 0.25;
    const repeat_rate: f64 = 0.05;
    var icon_cache = std.array_list.Managed(IconEntry).init(alloc);
    defer {
        for (icon_cache.items) |e| {
            if (e.tex.id != 0) rl.UnloadTexture(e.tex);
            alloc.free(e.path);
        }
        icon_cache.deinit();
    }

    while (!rl.WindowShouldClose()) {
        const now = rl.GetTime();
        const down_pressed = rl.IsKeyPressed(rl.KEY_DOWN);
        const up_pressed = rl.IsKeyPressed(rl.KEY_UP);
        handleTextInput(&query);

        if (rl.IsKeyPressed(rl.KEY_BACKSPACE)) {
            if (query.items.len > 0) _ = query.pop();
        }

        if (rl.IsKeyPressed(rl.KEY_ESCAPE)) break;

        if (rl.IsKeyPressed(rl.KEY_ENTER)) {
            should_launch = true;
            break;
        }

        if (rl.IsKeyPressed(rl.KEY_TAB) or down_pressed) {
            if (cursor + 1 < matches.items.len) cursor += 1;
            if (down_pressed) {
                repeat_dir = 1;
                next_repeat = now + repeat_delay;
            }
        }
        if (up_pressed or (rl.IsKeyDown(rl.KEY_LEFT_SHIFT) and rl.IsKeyPressed(rl.KEY_TAB))) {
            if (cursor > 0) cursor -= 1;
            if (up_pressed) {
                repeat_dir = -1;
                next_repeat = now + repeat_delay;
            }
        }
        if (rl.IsKeyPressed(rl.KEY_PAGE_DOWN)) {
            if (matches.items.len > 0) {
                const step: usize = 5;
                cursor = @min(cursor + step, matches.items.len - 1);
            }
        }
        if (rl.IsKeyPressed(rl.KEY_PAGE_UP)) {
            const step: usize = 5;
            cursor = if (cursor > step) cursor - step else 0;
        }

        if (repeat_dir == 1 and rl.IsKeyDown(rl.KEY_DOWN) and now >= next_repeat) {
            if (cursor + 1 < matches.items.len) cursor += 1;
            next_repeat = now + repeat_rate;
        } else if (repeat_dir == -1 and rl.IsKeyDown(rl.KEY_UP) and now >= next_repeat) {
            if (cursor > 0) cursor -= 1;
            next_repeat = now + repeat_rate;
        }
        if (repeat_dir == 1 and !rl.IsKeyDown(rl.KEY_DOWN)) repeat_dir = 0;
        if (repeat_dir == -1 and !rl.IsKeyDown(rl.KEY_UP)) repeat_dir = 0;

        const wheel = rl.GetMouseWheelMove();
        if (wheel < 0) {
            if (cursor + 1 < matches.items.len) cursor += 1;
        } else if (wheel > 0) {
            if (cursor > 0) cursor -= 1;
        }

        const query_str = query.items;
        matches.clearRetainingCapacity();
        try buildMatches(apps, &matches, query_str);
        if (cursor >= matches.items.len and matches.items.len > 0) cursor = matches.items.len - 1;
        if (matches.items.len == 0) cursor = 0;

        // scroll
        const list_rows = @min(list_max, matches.items.len);
        if (cursor < scroll) scroll = cursor;
        if (cursor >= scroll + list_rows and list_rows > 0) {
            scroll = cursor - (list_rows - 1);
        }

        rl.BeginDrawing();
        rl.ClearBackground(theme.bg);

        ui.drawHeader(alloc, font_handle.font, font_size, theme, padding);
        var y: f32 = header_h + padding;
        ui.drawText(font_handle.font, font_size, ">", padding, y, theme.accent);
        ui.drawText(font_handle.font, font_size, query_str, padding + 18, y, theme.fg);
        y += line_h + 6;

        const list_y = y;
        const max_w = rl.GetScreenWidth();
        var row: usize = 0;
        while (row < list_rows and scroll + row < matches.items.len) : (row += 1) {
            const app_idx = matches.items[scroll + row];
            const name = apps[app_idx].name;
            const is_sel = scroll + row == cursor;
            const rect = rl.Rectangle{ .x = padding, .y = list_y + @as(f32, @floatFromInt(row)) * line_h, .width = @as(f32, @floatFromInt(max_w)) - 2 * padding, .height = line_h };
            if (is_sel) rl.DrawRectangleRec(rect, theme.button_active) else rl.DrawRectangleRec(rect, theme.button);
            var name_buf: [256]u8 = undefined;
            const icon_size: f32 = 20;
            var text_x: f32 = rect.x + 8;
            if (apps[app_idx].icon.len > 0) {
                if (getIconTexture(alloc, &icon_cache, apps[app_idx].icon)) |t| {
                    const dst = rl.Rectangle{ .x = rect.x + 6, .y = rect.y + 3, .width = icon_size, .height = icon_size };
                    rl.DrawTexturePro(t, rl.Rectangle{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(t.width)), .height = @as(f32, @floatFromInt(t.height)) }, dst, rl.Vector2{ .x = 0, .y = 0 }, 0, rl.WHITE);
                    text_x += icon_size + 6;
                }
            }
            const max_wi = rect.width - (text_x - rect.x) - 8;
            const label = ui.ellipsizeToBuf(font_handle.font, font_size, name, max_wi, &name_buf);
            drawHighlighted(font_handle.font, font_size, label, query_str, text_x, rect.y + 2, theme.fg, theme.accent);
        }

        // mouse click select
        if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            const mp = rl.GetMousePosition();
            if (mp.y >= list_y and mp.y < list_y + @as(f32, @floatFromInt(list_rows)) * line_h) {
                const idx = @as(usize, @intFromFloat((mp.y - list_y) / line_h));
                if (scroll + idx < matches.items.len) {
                    cursor = scroll + idx;
                    should_launch = true;
                    rl.EndDrawing();
                    break;
                }
            }
        }

        rl.EndDrawing();
    }

    if (should_launch and matches.items.len > 0 and cursor < matches.items.len) {
        const app_entry = apps[matches.items[cursor]];
        try spawnCommand(alloc, app_entry.exec);
    }
}

fn calcWindowSize(font: rl.Font, size: f32, apps: []const appscan.AppEntry, list_max: usize, padding: f32, line_h: f32, header_h: f32) struct { w: i32, h: i32 } {
    var max_name: f32 = 0;
    for (apps) |a| {
        const w = ui.measureText(font, size, a.name);
        if (w > max_name) max_name = w;
    }
    const input_w: f32 = 300;
    const content_w = @max(max_name, input_w) + padding * 2 + 20;
    const list_rows = @min(list_max, apps.len);
    const content_h = header_h + padding * 2 + line_h * (1 + @as(f32, @floatFromInt(list_rows))) + 10;
    return .{ .w = @intFromFloat(content_w), .h = @intFromFloat(content_h) };
}

fn buildMatches(apps: []const appscan.AppEntry, matches: *std.array_list.Managed(usize), query: []const u8) !void {
    if (query.len == 0) {
        for (apps, 0..) |_, i| try matches.append(i);
        return;
    }
    for (apps, 0..) |app, i| {
        if (fuzzy.isMatch(query, app.name)) try matches.append(i);
    }
    if (matches.items.len > 1) {
        const Ctx = struct {
            apps: []const appscan.AppEntry,
            query: []const u8,
            pub fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
                const sa = fuzzy.score(ctx.query, ctx.apps[lhs].name) orelse 999999;
                const sb = fuzzy.score(ctx.query, ctx.apps[rhs].name) orelse 999999;
                return sa < sb;
            }
        };
        std.sort.heap(usize, matches.items, Ctx{ .apps = apps, .query = query }, Ctx.lessThan);
    }
}

fn handleTextInput(query: *std.array_list.Managed(u8)) void {
    var c: i32 = rl.GetCharPressed();
    while (c > 0) : (c = rl.GetCharPressed()) {
        if (c >= 32 and c < 127) {
            query.append(@intCast(c)) catch {};
        }
    }
}

fn spawnCommand(alloc: std.mem.Allocator, cmdline: []const u8) !void {
    var args = std.array_list.Managed([]const u8).init(alloc);
    defer args.deinit();

    var it = std.mem.tokenizeAny(u8, cmdline, " \t");
    while (it.next()) |tok| {
        try args.append(tok);
    }
    if (args.items.len == 0) return;

    var child = std.process.Child.init(args.items, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawn();
}

fn getIconTexture(alloc: std.mem.Allocator, cache: *std.array_list.Managed(IconEntry), path: []const u8) ?rl.Texture2D {
    for (cache.items) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.tex;
    }
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const n = @min(path.len, buf.len - 1);
    @memcpy(buf[0..n], path[0..n]);
    buf[n] = 0;
    const tex = rl.LoadTexture(@ptrCast(&buf));
    if (tex.id == 0) return null;
    const dup = alloc.dupe(u8, path) catch {
        rl.UnloadTexture(tex);
        return null;
    };
    if (cache.items.len >= 48) {
        const evict = cache.items[0];
        rl.UnloadTexture(evict.tex);
        alloc.free(evict.path);
        cache.items[0] = .{ .path = dup, .tex = tex };
    } else {
        cache.append(.{ .path = dup, .tex = tex }) catch {
            rl.UnloadTexture(tex);
            alloc.free(dup);
            return null;
        };
    }
    return tex;
}

fn drawHighlighted(font: rl.Font, size: f32, text: []const u8, query: []const u8, x: f32, y: f32, base: rl.Color, accent: rl.Color) void {
    if (query.len == 0) {
        ui.drawText(font, size, text, x, y, base);
        return;
    }
    var qi: usize = 0;
    var cx = x;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i .. i + 1];
        const is_match = if (qi < query.len) (std.ascii.toLower(text[i]) == std.ascii.toLower(query[qi])) else false;
        const color = if (is_match) accent else base;
        ui.drawText(font, size, ch, cx, y, color);
        cx += ui.measureText(font, size, ch);
        if (is_match) qi += 1;
    }
}
