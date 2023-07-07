const std = @import("std");
const rl = @import("common.zig").rl;

extern fn init() callconv(.C) void;
extern fn update() callconv(.C) void;

pub fn main() !void {
    init();

    while (!rl.WindowShouldClose()) {
        update();
    }
}

export var _fltused: i32 = 0x9875;

export fn __chkstk() callconv(.C) void {
    return;
}
