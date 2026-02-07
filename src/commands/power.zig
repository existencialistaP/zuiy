const std = @import("std");
const rl = @import("../core/raylib.zig").c;

const ui = @import("../core/ui.zig");
const config = @import("../core/config.zig");

const Action = enum { shutdown, reboot, @"suspend", logout };

pub fn run(alloc: std.mem.Allocator) !void {
    const cfg = config.load(alloc);
    ui.initWindow("zuiy power", 420, 320);
    defer rl.CloseWindow();

    const theme = ui.Theme{};
    const font_size: f32 = 24;
    const font_handle = ui.loadFont(alloc, font_size);
    defer ui.unloadFont(font_handle);

    const labels = [_][]const u8{ "shutdown", "reboot", "suspend", "logout" };
    const btn_h: f32 = 48;
    const btn_w: f32 = 220;
    const gap: f32 = 12;
    const padding: f32 = 16;
    const line_h: f32 = font_size + 6;
    const header_h = ui.headerHeight(font_size);

    const total_h = header_h + padding + line_h + 12 + @as(f32, @floatFromInt(labels.len)) * btn_h + (@as(f32, @floatFromInt(labels.len)) - 1) * gap + padding;
    const desired = ui.clampWindowSize(460, @intFromFloat(total_h));
    rl.SetWindowSize(desired.w, desired.h);
    ui.centerWindow(desired.w, desired.h);

    var cursor: usize = 0;
    var selected: ?Action = null;
    var hold_start: ?f64 = null;
    const hold_s: f64 = @as(f64, @floatFromInt(cfg.power_hold_ms)) / 1000.0;

    while (!rl.WindowShouldClose()) {
        if (rl.IsKeyPressed(rl.KEY_ESCAPE) or rl.IsKeyPressed(rl.KEY_Q)) break;
        if (rl.IsKeyPressed(rl.KEY_ENTER)) {
            hold_start = rl.GetTime();
        }
        if (rl.IsKeyDown(rl.KEY_ENTER)) {
            if (hold_start) |t0| {
                if (rl.GetTime() - t0 >= hold_s) {
                    selected = actionAt(cursor);
                    break;
                }
            }
        } else {
            hold_start = null;
        }
        if (rl.IsKeyPressed(rl.KEY_TAB) or rl.IsKeyPressed(rl.KEY_DOWN)) {
            if (cursor + 1 < labels.len) cursor += 1;
        }
        if (rl.IsKeyPressed(rl.KEY_UP) or (rl.IsKeyDown(rl.KEY_LEFT_SHIFT) and rl.IsKeyPressed(rl.KEY_TAB))) {
            if (cursor > 0) cursor -= 1;
        }

        const wheel = rl.GetMouseWheelMove();
        if (wheel < 0 and cursor + 1 < labels.len) cursor += 1;
        if (wheel > 0 and cursor > 0) cursor -= 1;

        rl.BeginDrawing();
        rl.ClearBackground(theme.bg);

        const w = @as(f32, @floatFromInt(rl.GetScreenWidth()));
        ui.drawHeader(alloc, font_handle.font, font_size, theme, padding);
        var y: f32 = header_h + padding + 8;

        var i: usize = 0;
        while (i < labels.len) : (i += 1) {
            const x = (w - btn_w) / 2;
            const rect = rl.Rectangle{ .x = x, .y = y, .width = btn_w, .height = btn_h };
            const hover = rl.CheckCollisionPointRec(rl.GetMousePosition(), rect);
            const is_sel = i == cursor;
            const color = if (is_sel) theme.button_active else if (hover) theme.button_hover else theme.button;
            rl.DrawRectangleRec(rect, color);
            rl.DrawRectangleLinesEx(rect, 2, theme.muted);

            const text_w = ui.measureText(font_handle.font, font_size, labels[i]);
            ui.drawText(font_handle.font, font_size, labels[i], rect.x + (btn_w - text_w) / 2, rect.y + 10, theme.fg);

            if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and hover) {
                selected = actionAt(i);
                rl.EndDrawing();
                break;
            }

            y += btn_h + gap;
        }

        if (hold_start) |t0| {
            const progress = @min(1.0, (rl.GetTime() - t0) / hold_s);
            const wbar = @as(f32, @floatFromInt(rl.GetScreenWidth())) - 2 * padding;
            const bar = rl.Rectangle{ .x = padding, .y = @as(f32, @floatFromInt(rl.GetScreenHeight())) - 18, .width = wbar, .height = 6 };
            rl.DrawRectangleRec(bar, theme.muted);
            rl.DrawRectangleRec(rl.Rectangle{ .x = bar.x, .y = bar.y, .width = bar.width * @as(f32, @floatCast(progress)), .height = bar.height }, theme.accent);
        }

        rl.EndDrawing();
        if (selected != null) break;
    }

    if (selected) |act| try runAction(alloc, act);
}


fn actionAt(idx: usize) ?Action {
    return switch (idx) {
        0 => .shutdown,
        1 => .reboot,
        2 => .@"suspend",
        3 => .logout,
        else => null,
    };
}

fn runAction(alloc: std.mem.Allocator, action: Action) !void {
    switch (action) {
        .shutdown => try spawn(alloc, &.{ "systemctl", "poweroff" }),
        .reboot => try spawn(alloc, &.{ "systemctl", "reboot" }),
        .@"suspend" => try spawn(alloc, &.{ "systemctl", "suspend" }),
        .logout => {
            if (std.posix.getenv("XDG_SESSION_ID")) |sid| {
                try spawn(alloc, &.{ "loginctl", "terminate-session", sid });
            } else {
                try spawn(alloc, &.{ "loginctl", "terminate-user", std.posix.getenv("USER") orelse "" });
            }
        },
    }
}

fn spawn(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawn();
}
