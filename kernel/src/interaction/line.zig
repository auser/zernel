const input = @import("input.zig");

pub const max_line = 128;

pub const WriteFn = *const fn ([]const u8) void;

pub const Reader = struct {
    buffer: [max_line]u8 = undefined,
    read_byte: input.ReadByteFn,
    read_key: input.ReadKeyFn,
    write: WriteFn,

    pub fn init(read_byte: input.ReadByteFn, read_key: input.ReadKeyFn, write: WriteFn) Reader {
        return .{
            .read_byte = read_byte,
            .read_key = read_key,
            .write = write,
        };
    }

    pub fn read(self: *Reader) []const u8 {
        var len: usize = 0;
        while (true) {
            const byte = self.readInputByte() orelse continue;
            switch (byte) {
                '\r', '\n' => {
                    self.write("\n");
                    return self.buffer[0..len];
                },
                8, 127 => {
                    if (len > 0) {
                        len -= 1;
                        self.erasePreviousByte();
                    }
                },
                else => {
                    if (isPrintable(byte) and len < self.buffer.len) {
                        self.buffer[len] = byte;
                        len += 1;
                        self.echoByte(byte);
                    }
                },
            }
        }
    }
    fn readInputByte(self: *Reader) ?u8 {
        const event = input.poll(self.read_byte, self.read_key) orelse return null;
        return switch (event) {
            .byte => |byte| byte,
            .key => null,
        };
    }

    fn echoByte(self: *Reader, byte: u8) void {
        self.write(&.{byte});
    }

    fn erasePreviousByte(self: *Reader) void {
        self.write(&.{ 8, ' ', 8 });
    }
};

fn isPrintable(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x7e;
}


test "isPrintable accepts visible ascii only" {
    const std = @import("std");

    try std.testing.expect(!isPrintable(0));
    try std.testing.expect(!isPrintable('\n'));
    try std.testing.expect(isPrintable(' '));
    try std.testing.expect(isPrintable('~'));
    try std.testing.expect(!isPrintable(0x7f));
}
