const std = @import("std");
const rl = @import("../core/raylib.zig").c;

const ui = @import("../core/ui.zig");

const Notification = struct {
    id: ?u64,
    summary: []const u8,
    body: []const u8,
    appname: []const u8,
    has_actions: bool,
    actions: [][]const u8,
};

const Selection = struct { index: ?usize, cancelled: bool };

pub fn run(alloc: std.mem.Allocator) !void {
    const json_bytes = fetchHistoryJson(alloc) catch |err| {
        var buf: [256]u8 = undefined;
        const out = std.fs.File.stdout();
        const msg = try std.fmt.bufPrint(&buf, "notify: falhou ao ler dunst history ({s})\n", .{@errorName(err)});
        _ = try out.writeAll(msg);
        return;
    };
    defer alloc.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{});
    defer parsed.deinit();

    const list = try extractNotifications(alloc, parsed.value);
    defer freeNotifications(alloc, list);

    var empty_mode = false;
    if (list.len == 0) {
        empty_mode = true;
    }

    const sel = try runList(alloc, "Notificacoes", list, empty_mode);
    if (sel.cancelled or sel.index == null) return;
    if (empty_mode) return;

    const chosen = list[sel.index.?];
    try historyPop(alloc, chosen.id, sel.index.?);
}

fn runList(alloc: std.mem.Allocator, title: []const u8, items: []const Notification, empty_mode: bool) !Selection {
    ui.initWindow("zuiy notify", 560, 520);
    defer rl.CloseWindow();

    const theme = ui.Theme{};
    const font_size: f32 = 20;
    const font_handle = ui.loadFont(alloc, font_size);
    defer ui.unloadFont(font_handle);

    const line_h: f32 = font_size + 6;
    const padding: f32 = 16;
    const header_h = ui.headerHeight(font_size);
    const card_h: f32 = line_h * 2 + 10;

    const desired = calcWindowSize(font_handle.font, font_size, title, items, padding, card_h, header_h);
    const clamped = ui.clampWindowSize(desired.w, desired.h);
    rl.SetWindowSize(clamped.w, clamped.h);
    ui.centerWindow(clamped.w, clamped.h);

    var cursor: usize = 0;
    var scroll: usize = 0;
    var repeat_dir: i32 = 0;
    var next_repeat: f64 = 0;
    const repeat_delay: f64 = 0.25;
    const repeat_rate: f64 = 0.05;
    var dnd_paused = getDunstPaused(alloc) catch false;
    var filter = std.array_list.Managed(u8).init(alloc);
    defer filter.deinit();
    var filter_mode = false;
    var visible = std.array_list.Managed(usize).init(alloc);
    defer visible.deinit();

    while (!rl.WindowShouldClose()) {
        const now = rl.GetTime();
        const down_pressed = rl.IsKeyPressed(rl.KEY_DOWN);
        const up_pressed = rl.IsKeyPressed(rl.KEY_UP);

        if (filter_mode) {
            handleFilterInput(&filter, &filter_mode);
        } else {
            if (rl.IsKeyPressed(rl.KEY_SLASH)) filter_mode = true;
            if (rl.IsKeyPressed(rl.KEY_ESCAPE) or rl.IsKeyPressed(rl.KEY_Q)) return Selection{ .index = null, .cancelled = true };
            if (rl.IsKeyPressed(rl.KEY_ENTER)) return Selection{ .index = cursor, .cancelled = false };
            if (rl.IsKeyPressed(rl.KEY_X)) {
                _ = spawn(alloc, &.{ "dunstctl", "history-clear" }) catch {};
                return Selection{ .index = null, .cancelled = true };
            }
        }

        if (rl.IsKeyPressed(rl.KEY_D)) {
            dnd_paused = !dnd_paused;
            _ = setDunstPaused(alloc, dnd_paused) catch {};
        }

        buildVisible(items, empty_mode, filter.items, &visible);
        const show_empty = empty_mode or (filter.items.len > 0 and visible.items.len == 0);
        const item_count: usize = if (show_empty) 1 else visible.items.len;
        if (cursor >= item_count) cursor = if (item_count > 0) item_count - 1 else 0;

        if (rl.IsKeyPressed(rl.KEY_TAB) or down_pressed) {
            if (cursor + 1 < item_count) cursor += 1;
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

        if (repeat_dir == 1 and rl.IsKeyDown(rl.KEY_DOWN) and now >= next_repeat) {
            if (cursor + 1 < item_count) cursor += 1;
            next_repeat = now + repeat_rate;
        } else if (repeat_dir == -1 and rl.IsKeyDown(rl.KEY_UP) and now >= next_repeat) {
            if (cursor > 0) cursor -= 1;
            next_repeat = now + repeat_rate;
        }
        if (repeat_dir == 1 and !rl.IsKeyDown(rl.KEY_DOWN)) repeat_dir = 0;
        if (repeat_dir == -1 and !rl.IsKeyDown(rl.KEY_UP)) repeat_dir = 0;

        const wheel = rl.GetMouseWheelMove();
        if (wheel < 0 and cursor + 1 < item_count) cursor += 1;
        if (wheel > 0 and cursor > 0) cursor -= 1;

        const avail_h = @as(f32, @floatFromInt(rl.GetScreenHeight())) - header_h - padding * 2;
        const list_rows = @min(item_count, @as(usize, @intFromFloat(@max(1, avail_h / card_h))));
        if (cursor < scroll) scroll = cursor;
        if (cursor >= scroll + list_rows and list_rows > 0) scroll = cursor - (list_rows - 1);

        rl.BeginDrawing();
        rl.ClearBackground(theme.bg);

        ui.drawHeader(alloc, font_handle.font, font_size, theme, padding);
        const dnd_text = if (dnd_paused) "DND: on" else "DND: off";
        const dnd_w = ui.measureText(font_handle.font, font_size, dnd_text);
        ui.drawText(font_handle.font, font_size, dnd_text, @as(f32, @floatFromInt(rl.GetScreenWidth())) - dnd_w - padding, 6, theme.muted);
        if (filter.items.len > 0 or filter_mode) {
            var buf: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "/{s}", .{filter.items}) catch "/";
            ui.drawText(font_handle.font, font_size, label, padding, 6, theme.muted);
        }

        const y: f32 = header_h + padding;
        var row: usize = 0;
        while (row < list_rows and scroll + row < item_count) : (row += 1) {
            const vi = scroll + row;
            const idx = if (show_empty or visible.items.len == 0) 0 else visible.items[vi];
            const rect = rl.Rectangle{
                .x = padding,
                .y = y + @as(f32, @floatFromInt(row)) * card_h,
                .width = @as(f32, @floatFromInt(rl.GetScreenWidth())) - 2 * padding,
                .height = card_h - 6,
            };
            const is_sel = vi == cursor;
            const bg = if (is_sel) theme.button_active else theme.button;
            rl.DrawRectangleRec(rect, bg);
            rl.DrawRectangleLinesEx(rect, 2, theme.muted);

            var line1_buf: [512]u8 = undefined;
            var line2_buf: [512]u8 = undefined;
            const max_w = rect.width - 16;
            const line1 = if (show_empty) (if (filter.items.len > 0) "(sem resultados)" else "(sem notificacoes)") else blk: {
                if (items[idx].appname.len == 0) break :blk items[idx].summary;
                const built = std.fmt.bufPrint(&line1_buf, "[{s}] {s}", .{ items[idx].appname, items[idx].summary }) catch items[idx].summary;
                break :blk built;
            };
            const line2 = if (show_empty) "" else items[idx].body;
            const out1 = ui.ellipsizeToBuf(font_handle.font, font_size, line1, max_w, &line1_buf);
            const out2 = ui.ellipsizeToBuf(font_handle.font, font_size, line2, max_w, &line2_buf);
            ui.drawText(font_handle.font, font_size, out1, rect.x + 8, rect.y + 4, theme.fg);
            if (line2.len > 0) {
                ui.drawText(font_handle.font, font_size, out2, rect.x + 8, rect.y + 4 + line_h, theme.muted);
            }

            if (!show_empty and items[idx].actions.len > 0 and is_sel) {
                drawActions(font_handle.font, font_size, theme, rect, items[idx].actions);
            }
        }

        if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            const mp = rl.GetMousePosition();
            if (mp.y >= y and mp.y < y + @as(f32, @floatFromInt(list_rows)) * card_h) {
                const idx = @as(usize, @intFromFloat((mp.y - y) / card_h));
                if (scroll + idx < item_count) return Selection{ .index = scroll + idx, .cancelled = false };
            }
            if (!show_empty and item_count > 0) {
                if (visible.items.len > 0 and cursor < visible.items.len) {
                    const actual = visible.items[cursor];
                    if (handleActionClick(items[actual], mp, font_handle.font, font_size, theme, padding, y, card_h, cursor, scroll)) |act_idx| {
                        try historyPop(alloc, items[actual].id, actual);
                        var buf: [8]u8 = undefined;
                        const a = std.fmt.bufPrint(&buf, "{d}", .{act_idx}) catch "0";
                        _ = try spawn(alloc, &.{ "dunstctl", "action", a });
                        return Selection{ .index = null, .cancelled = true };
                    }
                }
            }
        }

        if (!show_empty and visible.items.len > 0 and cursor < visible.items.len) {
            const actual = visible.items[cursor];
            if (items[actual].actions.len > 0) {
                if (rl.IsKeyPressed(rl.KEY_ONE)) return try doAction(alloc, items[actual], actual, 0);
                if (rl.IsKeyPressed(rl.KEY_TWO)) return try doAction(alloc, items[actual], actual, 1);
                if (rl.IsKeyPressed(rl.KEY_THREE)) return try doAction(alloc, items[actual], actual, 2);
                if (rl.IsKeyPressed(rl.KEY_FOUR)) return try doAction(alloc, items[actual], actual, 3);
                if (rl.IsKeyPressed(rl.KEY_FIVE)) return try doAction(alloc, items[actual], actual, 4);
            }
        }

        rl.EndDrawing();
    }

    return Selection{ .index = null, .cancelled = true };
}

fn calcWindowSize(font: rl.Font, size: f32, title: []const u8, items: []const Notification, padding: f32, card_h: f32, header_h: f32) struct { w: i32, h: i32 } {
    var max_w: f32 = ui.measureText(font, size, title);
    var buf: [512]u8 = undefined;
    for (items) |n| {
        const l1 = if (n.appname.len == 0) n.summary else std.fmt.bufPrint(&buf, "[{s}] {s}", .{ n.appname, n.summary }) catch n.summary;
        max_w = @max(max_w, ui.measureText(font, size, l1));
        if (n.body.len > 0) max_w = @max(max_w, ui.measureText(font, size, n.body));
    }
    const mw = @as(f32, @floatFromInt(rl.GetMonitorWidth(0)));
    const mh = @as(f32, @floatFromInt(rl.GetMonitorHeight(0)));
    const content_w = @min(max_w + padding * 2 + 40, mw * 0.8);
    const rows: f32 = @floatFromInt(@max(items.len, 1));
    const content_h = @min(header_h + padding * 2 + card_h * rows + 10, mh * 0.7);
    return .{ .w = @intFromFloat(content_w), .h = @intFromFloat(content_h) };
}


fn fetchHistoryJson(alloc: std.mem.Allocator) ![]u8 {
    var child = std.process.Child.init(&.{ "dunstctl", "history" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(alloc, 1024 * 1024);
    errdefer alloc.free(stdout);

    const stderr = try child.stderr.?.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(stderr);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.DunstctlFailed,
        else => return error.DunstctlFailed,
    }

    return stdout;
}

fn historyPop(alloc: std.mem.Allocator, id: ?u64, index: usize) !void {
    if (id) |nid| {
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{nid});
        _ = try spawn(alloc, &.{ "dunstctl", "history-pop", id_str });
        return;
    }

    var i: usize = 0;
    while (i <= index) : (i += 1) {
        _ = try spawn(alloc, &.{ "dunstctl", "history-pop" });
    }
}

fn spawn(alloc: std.mem.Allocator, argv: []const []const u8) !std.process.Child.Term {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return child.wait();
}

fn getDunstPaused(alloc: std.mem.Allocator) !bool {
    var child = std.process.Child.init(&.{ "dunstctl", "is-paused" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(alloc, 64);
    defer alloc.free(out);
    _ = try child.wait();
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "1");
}

fn setDunstPaused(alloc: std.mem.Allocator, paused: bool) !void {
    const arg = if (paused) "true" else "false";
    _ = try spawn(alloc, &.{ "dunstctl", "set-paused", arg });
}

fn extractNotifications(alloc: std.mem.Allocator, value: std.json.Value) ![]Notification {
    var arr_opt: ?[]const std.json.Value = null;

    switch (value) {
        .array => |a| arr_opt = a.items,
        .object => |o| {
            if (o.get("data")) |v| {
                if (v == .array) {
                    const items = v.array.items;
                    if (items.len > 0 and items[0] == .array) {
                        arr_opt = items[0].array.items;
                    } else {
                        arr_opt = items;
                    }
                }
            }
            if (arr_opt == null) if (o.get("history")) |v| {
                if (v == .array) arr_opt = v.array.items;
            };
            if (arr_opt == null) if (o.get("notifications")) |v| {
                if (v == .array) arr_opt = v.array.items;
            };
        },
        else => {},
    }

    const arr = arr_opt orelse return &[_]Notification{};

    var list = std.array_list.Managed(Notification).init(alloc);
    errdefer {
        for (list.items) |n| {
            alloc.free(n.summary);
            alloc.free(n.body);
            alloc.free(n.appname);
        }
        list.deinit();
    }

    for (arr) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const id = extractU64(obj, "id");
        const summary = extractStringDup(alloc, obj, "summary") orelse try alloc.dupe(u8, "(sem resumo)");
        const body = extractStringDup(alloc, obj, "body") orelse try alloc.dupe(u8, "");
        const appname = extractStringDup(alloc, obj, "appname") orelse extractStringDup(alloc, obj, "app") orelse try alloc.dupe(u8, "");
        const actions = extractActions(alloc, obj);
        const has_actions = actions.len > 0;

        try list.append(.{
            .id = id,
            .summary = summary,
            .body = body,
            .appname = appname,
            .has_actions = has_actions,
            .actions = actions,
        });
    }

    return list.toOwnedSlice();
}

fn extractU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .integer => |i| std.math.cast(u64, i),
            .string => |s| std.fmt.parseUnsigned(u64, s, 10) catch null,
            .object => |o| blk: {
                if (o.get("data")) |d| {
                    break :blk switch (d) {
                        .integer => |i| std.math.cast(u64, i),
                        .string => |s| std.fmt.parseUnsigned(u64, s, 10) catch null,
                        else => null,
                    };
                }
                break :blk null;
            },
            else => null,
        };
    }
    return null;
}

fn extractStringDup(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]u8 {
    if (obj.get(key)) |v| {
        switch (v) {
            .string => return alloc.dupe(u8, v.string) catch null,
            .object => |o| {
                if (o.get("data")) |d| {
                    if (d == .string) return alloc.dupe(u8, d.string) catch null;
                }
            },
            else => {},
        }
    }
    return null;
}

fn hasActions(obj: std.json.ObjectMap) bool {
    if (obj.get("actions")) |v| {
        if (v == .array) return v.array.items.len > 0;
        if (v == .object) {
            if (v.object.get("data")) |d| {
                return d == .array and d.array.items.len > 0;
            }
        }
    }
    return false;
}

fn extractActions(alloc: std.mem.Allocator, obj: std.json.ObjectMap) [][]const u8 {
    if (obj.get("actions")) |v| {
        const arr = switch (v) {
            .array => v.array.items,
            .object => blk: {
                if (v.object.get("data")) |d| {
                    if (d == .array) break :blk d.array.items;
                }
                break :blk &[_]std.json.Value{};
            },
            else => &[_]std.json.Value{},
        };
        if (arr.len == 0) return alloc.alloc([]const u8, 0) catch &[_][]const u8{};
        var out = std.array_list.Managed([]const u8).init(alloc);
        errdefer {
            for (out.items) |s| alloc.free(s);
            out.deinit();
        }
        var i: usize = 0;
        while (i < arr.len) : (i += 1) {
            if (arr[i] == .string) {
                // dunst actions are usually pairs (id, label)
                if (i + 1 < arr.len and arr[i + 1] == .string) {
                    const label = arr[i + 1].string;
                    out.append(alloc.dupe(u8, label) catch continue) catch {};
                    i += 1;
                } else {
                    const label = arr[i].string;
                    out.append(alloc.dupe(u8, label) catch continue) catch {};
                }
            }
        }
        return out.toOwnedSlice() catch alloc.alloc([]const u8, 0) catch &[_][]const u8{};
    }
    return alloc.alloc([]const u8, 0) catch &[_][]const u8{};
}

fn freeNotifications(alloc: std.mem.Allocator, list: []Notification) void {
    for (list) |n| {
        alloc.free(n.summary);
        alloc.free(n.body);
        alloc.free(n.appname);
        for (n.actions) |a| alloc.free(a);
        alloc.free(n.actions);
    }
    alloc.free(list);
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
}

fn buildVisible(items: []const Notification, empty_mode: bool, filter: []const u8, out: *std.array_list.Managed(usize)) void {
    out.clearRetainingCapacity();
    if (empty_mode) return;
    if (filter.len == 0) {
        for (items, 0..) |_, i| out.append(i) catch {};
        return;
    }
    for (items, 0..) |n, i| {
        if (containsIgnoreCase(n.summary, filter) or containsIgnoreCase(n.body, filter) or containsIgnoreCase(n.appname, filter)) {
            out.append(i) catch {};
        }
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

fn drawActions(font: rl.Font, size: f32, theme: ui.Theme, rect: rl.Rectangle, actions: [][]const u8) void {
    const max = @min(actions.len, 5);
    if (max == 0) return;
    const btn_h: f32 = 22;
    const gap: f32 = 6;
    var x = rect.x + 8;
    const y = rect.y + rect.height - btn_h - 4;
    var i: usize = 0;
    while (i < max) : (i += 1) {
        const label = actions[i];
        const w = @min(140, ui.measureText(font, size, label) + 16);
        const r = rl.Rectangle{ .x = x, .y = y, .width = w, .height = btn_h };
        rl.DrawRectangleRec(r, theme.button_hover);
        rl.DrawRectangleLinesEx(r, 1, theme.muted);
        ui.drawText(font, size, label, r.x + 6, r.y + 2, theme.fg);
        x += w + gap;
    }
}

fn handleActionClick(n: Notification, mp: rl.Vector2, font: rl.Font, size: f32, theme: ui.Theme, padding: f32, list_y: f32, card_h: f32, cursor: usize, scroll: usize) ?usize {
    _ = theme;
    if (n.actions.len == 0) return null;
    if (cursor < scroll) return null;
    const row = cursor - scroll;
    const rect = rl.Rectangle{
        .x = padding,
        .y = list_y + @as(f32, @floatFromInt(row)) * card_h,
        .width = @as(f32, @floatFromInt(rl.GetScreenWidth())) - 2 * padding,
        .height = card_h - 6,
    };
    const max = @min(n.actions.len, 5);
    const btn_h: f32 = 22;
    const gap: f32 = 6;
    var x = rect.x + 8;
    const y = rect.y + rect.height - btn_h - 4;
    var i: usize = 0;
    while (i < max) : (i += 1) {
        const label = n.actions[i];
        const w = @min(140, ui.measureText(font, size, label) + 16);
        const r = rl.Rectangle{ .x = x, .y = y, .width = w, .height = btn_h };
        if (rl.CheckCollisionPointRec(mp, r)) return i;
        x += w + gap;
    }
    return null;
}

fn doAction(alloc: std.mem.Allocator, n: Notification, idx: usize, action_idx: usize) !Selection {
    if (action_idx >= n.actions.len) return Selection{ .index = idx, .cancelled = false };
    try historyPop(alloc, n.id, idx);
    var buf: [8]u8 = undefined;
    const a = std.fmt.bufPrint(&buf, "{d}", .{action_idx}) catch "0";
    _ = try spawn(alloc, &.{ "dunstctl", "action", a });
    return Selection{ .index = null, .cancelled = true };
}
