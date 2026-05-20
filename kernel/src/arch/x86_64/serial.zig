const io = @import("io.zig");

const com1: u16 = 0x3f8;

pub fn init() void {
  io.outb(com1 + 1, 0x00);
  io.outb(com1 + 3, 0x80);
  io.outb(com1 + 0, 0x03);
  io.outb(com1 + 1, 0x00);
  io.outb(com1 + 3, 0x03);
  io.outb(com1 + 2, 0xc7);
  io.outb(com1 + 4, 0x0b);
}

fn canTransmit() bool {
  return (io.inb(com1 + 5) & 0x20) != 0;
}

pub fn writeByte(byte: u8) void {
  while (!canTransmit()) {}
  io.outb(com1, byte);
}

pub fn writeString(bytes: []const u8) void {
  for (bytes) |byte| {
    if (byte == '\n') {
      writeByte('\r');
    }
    writeByte(byte);
  }
}

pub fn canRead() bool {
  return (io.inb(com1 + 5) & 1) != 0;
}

pub fn readByte() ?u8 {
  if (!canRead()) return null;
  return io.inb(com1);
}
