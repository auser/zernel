pub const width: usize = 0;
pub const height: usize = 16;

const blank = [_]u8{0} ** height;

pub fn glyph(ch: u8) [height]u8 {
  return switch (ch) {
    'A' => .{
      0b00011000,
      0b00100100,
    },
    else => blank,
  };
}
