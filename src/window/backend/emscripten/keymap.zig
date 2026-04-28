const std = @import("std");
const window = @import("window");
const Key = window.Key;

pub const code_to_key = std.StaticStringMap(Key).initComptime(.{
    .{ "KeyA", .a },           .{ "KeyB", .b },           .{ "KeyC", .c },           .{ "KeyD", .d },
    .{ "KeyE", .e },           .{ "KeyF", .f },           .{ "KeyG", .g },           .{ "KeyH", .h },
    .{ "KeyI", .i },           .{ "KeyJ", .j },           .{ "KeyK", .k },           .{ "KeyL", .l },
    .{ "KeyM", .m },           .{ "KeyN", .n },           .{ "KeyO", .o },           .{ "KeyP", .p },
    .{ "KeyQ", .q },           .{ "KeyR", .r },           .{ "KeyS", .s },           .{ "KeyT", .t },
    .{ "KeyU", .u },           .{ "KeyV", .v },           .{ "KeyW", .w },           .{ "KeyX", .x },
    .{ "KeyY", .y },           .{ "KeyZ", .z },

    .{ "Digit0", .@"0" },      .{ "Digit1", .@"1" },      .{ "Digit2", .@"2" },      .{ "Digit3", .@"3" },
    .{ "Digit4", .@"4" },      .{ "Digit5", .@"5" },      .{ "Digit6", .@"6" },      .{ "Digit7", .@"7" },
    .{ "Digit8", .@"8" },      .{ "Digit9", .@"9" },

    .{ "F1", .f1 },            .{ "F2", .f2 },            .{ "F3", .f3 },            .{ "F4", .f4 },
    .{ "F5", .f5 },            .{ "F6", .f6 },            .{ "F7", .f7 },            .{ "F8", .f8 },
    .{ "F9", .f9 },            .{ "F10", .f10 },          .{ "F11", .f11 },          .{ "F12", .f12 },
    .{ "F13", .f13 },          .{ "F14", .f14 },          .{ "F15", .f15 },          .{ "F16", .f16 },
    .{ "F17", .f17 },          .{ "F18", .f18 },          .{ "F19", .f19 },          .{ "F20", .f20 },
    .{ "F21", .f21 },          .{ "F22", .f22 },          .{ "F23", .f23 },          .{ "F24", .f24 },
    .{ "F25", .f25 },

    .{ "Numpad0", .kp_0 },     .{ "Numpad1", .kp_1 },     .{ "Numpad2", .kp_2 },     .{ "Numpad3", .kp_3 },
    .{ "Numpad4", .kp_4 },     .{ "Numpad5", .kp_5 },     .{ "Numpad6", .kp_6 },     .{ "Numpad7", .kp_7 },
    .{ "Numpad8", .kp_8 },     .{ "Numpad9", .kp_9 },
    .{ "NumpadDecimal", .kp_decimal },
    .{ "NumpadDivide", .kp_divide },
    .{ "NumpadMultiply", .kp_multiply },
    .{ "NumpadSubtract", .kp_subtract },
    .{ "NumpadAdd", .kp_add },
    .{ "NumpadEnter", .kp_enter },
    .{ "NumpadEqual", .kp_equal },

    .{ "Space", .space },
    .{ "Quote", .apostrophe },
    .{ "Comma", .comma },
    .{ "Minus", .minus },
    .{ "Period", .period },
    .{ "Slash", .slash },
    .{ "Semicolon", .semicolon },
    .{ "Equal", .equal },
    .{ "BracketLeft", .left_bracket },
    .{ "Backslash", .backslash },
    .{ "BracketRight", .right_bracket },
    .{ "Backquote", .grave_accent },
    .{ "IntlBackslash", .world_1 },
    .{ "IntlRo", .world_2 },

    .{ "Escape", .escape },
    .{ "Enter", .enter },
    .{ "Tab", .tab },
    .{ "Backspace", .backspace },
    .{ "Insert", .insert },
    .{ "Delete", .delete },
    .{ "ArrowRight", .right },
    .{ "ArrowLeft", .left },
    .{ "ArrowDown", .down },
    .{ "ArrowUp", .up },
    .{ "PageUp", .page_up },
    .{ "PageDown", .page_down },
    .{ "Home", .home },
    .{ "End", .end },
    .{ "CapsLock", .caps_lock },
    .{ "ScrollLock", .scroll_lock },
    .{ "NumLock", .num_lock },
    .{ "PrintScreen", .print_screen },
    .{ "Pause", .pause },

    .{ "ShiftLeft", .left_shift },
    .{ "ShiftRight", .right_shift },
    .{ "ControlLeft", .left_control },
    .{ "ControlRight", .right_control },
    .{ "AltLeft", .left_alt },
    .{ "AltRight", .right_alt },
    .{ "MetaLeft", .left_super },
    .{ "MetaRight", .right_super },
    .{ "OSLeft", .left_super },
    .{ "OSRight", .right_super },
    .{ "ContextMenu", .menu },
});

pub fn translateCode(code_buf: []const u8) ?Key {
    const slice = std.mem.sliceTo(code_buf, 0);
    if (slice.len == 0) return null;
    return code_to_key.get(slice);
}
