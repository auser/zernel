const limine = @import("limine");
const font = @import("font.zig");

var framebuffer: ?*limine.Framebuffer = null;
var cursor_col: usize = 0;
var cursor_row: usize = 0;

pub fn init(fb: *limine.Framebuffer) void {
  framebuffer = fb;
}

pub fn drawGlyph(cell_x: usize, cell_y: usize, ch: u8, fg: u32, bg: u32) void {
  const fb = framebuffer orelse return;
  const pixels: [*]volatile u32 = @ptrCast(@alignCast(fb.address));
  const pitch_pixels: usize = @intCast(fb.pitch / 4);
  const glyph_rows = font.glyph(ch);

  const start_x = cell_x * font.width;
  const start_y = cell_y * font.height;

  for (glyph_rows, 0..) |bits, row| {
    var col: usize = 0;
    while (col < font.width) : (col += 1) {
      const mask: u8 = @as(u8, 1) << @intCast(7 - col);
      const color = if ((bits & mask) != 0) fg else bg;
      pixels[(start_y + row) * pitch_pixels + (start_x + col)] = color;
    }
  }
}


pub fn putChar(ch: u8) void {
  switch (ch) {
    '\n' => {
      cursor_col = 0;
      cursor_row += 1;
    },
    '\r' => cursor_col = 0,
    else => {
      drawGlyph(cursor_col, cursor_row, ch, 0x00ffffff, 0x00000000);
      cursor_col += 1;
      if (cursor_col >= cols()) {
        cursor_col = 0;
        cursor_row += 1;
      }
    },
  }
}

pub fn writeString(bytes: []const u8) void {
  for (bytes) |byte| putChar(byte);
}

fn newline() void {
  cursor_col = 0;
  cursor_row += 1;
  if (cursor_row >= rows()) {
    scrollOneRow();
    cursor_row = rows() - 1;
  }
}

fn scrollOneRow() void {
    const fb = framebuffer orelse return;
    const pixels: [*]volatile u32 = @ptrCast(@alignCast(fb.address));
    const pitch_pixels: usize = @intCast(fb.pitch / 4);
    const width: usize = @intCast(fb.width);
    const height: usize = @intCast(fb.height);
    const row_pixels = font.height;

    var y: usize = 0;
    while (y + row_pixels < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            pixels[y * pitch_pixels + x] = pixels[(y + row_pixels) * pitch_pixels + x];
        }
    }

    clearPixelRows(height - row_pixels, height);
}

fn cols() usize {
  const fb = framebuffer orelse return 0;
  return @as(usize, @intCast(fb.width)) / font.width;
}

fn rows() usize {
  const fb = framebuffer orelse return 0;
  return @as(usize, @intCast(fb.height)) / font.height;
}

fn clearPixelRows(start_y: usize, end_y: usize) void {
    const fb = framebuffer orelse return;
    const pixels: [*]volatile u32 = @ptrCast(@alignCast(fb.address));
    const pitch_pixels: usize = @intCast(fb.pitch / 4);
    const width: usize = @intCast(fb.width);

    var y = start_y;
    while (y < end_y) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            pixels[y * pitch_pixels + x] = 0x00000000;
        }
    }
}
