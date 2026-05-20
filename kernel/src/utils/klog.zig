const arch = @import("../arch.zig");
const console = @import("../fb/console.zig");

fn write(bytes: []const u8) void {
  arch.writeEarlyDebug(bytes);
  console.writeString(bytes);
}

fn line(level: []const u8, msg: []const u8) void {
  arch.writeEarlyDebug("[");
  arch.writeEarlyDebug(level);
  arch.writeEarlyDebug("] ");
  arch.writeEarlyDebug(msg);
  arch.writeEarlyDebug("\n");
}

pub fn info(msg: []const u8) void {
  line("info", msg);
}

pub fn warn(msg: []const u8) void {
  line("warn", msg);
}

pub fn err(msg: []const u8) void {
  line("err", msg);
}

pub fn hex(value: usize) void {
  var buffer: [2 + @sizeOf(usize) * 2]u8 = undefined;
  buffer[0] = '0';
  buffer[1] = 'x';

  var index: usize = 2;
  var shift: usize = @bitSizeOf(usize);
  var started = false;
  while (shift > 0) {
    shift -= 4;
    const nibble: u8 = @intCast((value >> @intCast(shift)) & 0xf);
    if (nibble != 0 or started or shift == 0) {
      started = true;
      buffer[index] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
      index += 1;
    }
  }

  arch.writeEarlyDebug(buffer[0..index]);
}

pub fn dec(value: usize) void {
  var buffer: [@sizeOf(usize) * 3]u8 = undefined;
  var index = buffer.len;
  var remaining = value;

  if (remaining == 0) {
    arch.writeEarlyDebug("0");
    return;
  }

  while (remaining > 0) {
    index -= 1;
    buffer[index] = '0' + @as(u8, @intCast(remaining % 10));
    remaining /= 10;
  }

  arch.writeEarlyDebug(buffer[index..]);
}

pub fn labelDec(label: []const u8, value: usize) void {
  arch.writeEarlyDebug(label);
  arch.writeEarlyDebug(": ");
  dec(value);
  arch.writeEarlyDebug("\n");
}

pub fn labelHex(label: []const u8, value: usize) void {
  arch.writeEarlyDebug(label);
  arch.writeEarlyDebug(": ");
  hex(value);
  arch.writeEarlyDebug("\n");
}
