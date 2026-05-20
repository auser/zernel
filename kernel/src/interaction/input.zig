pub const Source = enum {
    early_debug,
    keyboard,
};

pub const Key = struct {
    code: u16,
    pressed: bool,
};

pub const Event = union(enum) {
    byte: u8,
    key: Key,
};

pub const ReadByteFn = *const fn () ?u8;
pub const ReadKeyFn = *const fn () ?Key;

pub fn poll(read_byte: ReadByteFn, read_key: ReadKeyFn) ?Event {
    if (read_byte()) |byte| {
        return .{ .byte = byte };
    }

    if (read_key()) |key| {
        return .{ .key = .{
            .code = key.code,
            .pressed = key.pressed,
        } };
    }

    return null;
}

fn testByte() ?u8 {
    return 'x';
}

fn testNoByte() ?u8 {
    return null;
}

fn testKey() ?Key {
    return .{ .code = 1, .pressed = true };
}

fn testNoKey() ?Key {
    return null;
}

test "poll prefers early debug bytes" {
    const std = @import("std");

    const event = poll(testByte, testKey) orelse return error.TestExpectedEqual;
    try std.testing.expect(event == .byte);
    try std.testing.expect(event.byte == 'x');
}

test "poll returns keyboard keys when no byte is available" {
    const std = @import("std");

    const event = poll(testNoByte, testKey) orelse return error.TestExpectedEqual;
    try std.testing.expect(event == .key);
    try std.testing.expect(event.key.code == 1);
    try std.testing.expect(event.key.pressed);
}

test "poll returns null when no input is available" {
    const std = @import("std");

    try std.testing.expect(poll(testNoByte, testNoKey) == null);
}
