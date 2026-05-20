const arch = @import("../arch.zig");
const klog = @import("../utils/klog.zig");
const boot_info = @import("../boot/info.zig");

const BootInfo = boot_info.BootInfo;

const max_line = 128;

pub fn run(info: *const BootInfo) noreturn {
  var buffer: [max_line]u8 = undefined;

  klog.info("monitor ready");
  while (true) {
    arch.writeEarlyDebug("> ");
    const line = readLine(&buffer);
    dispatch(info, line);
  }
}

fn readLine(buffer: *[max_line]u8) []const u8 {
  var len: usize = 0;
  while (true) {
    const byte = readInputByte() orelse continue;
    switch (byte) {
      '\r', '\n' => {
        klog.info("");
        return buffer[0..len];
      },
      8, 127 => {
        if (len > 0) len -= 1;
      },
      else => {
        if (len < buffer.len) {
          buffer[len] = byte;
          len += 1;
          echoByte(byte);
        }
      },
    }
  }
}

fn dispatch(info: *const BootInfo, line: []const u8) void {
    if (equals(line, "help")) {
        klog.info("commands: help boot mem fb clear halt");
    } else if (equals(line, "boot")) {
        boot_info.logAddressInfo(info);
    } else if (equals(line, "mem")) {
        boot_info.logMemoryMap(info);
    } else if (equals(line, "fb")) {
        boot_info.logFramebuffer(info);
    } else if (equals(line, "clear")) {
        // Optional once framebuffer console exposes clear().
    } else if (equals(line, "halt")) {
        arch.halt();
    } else if (line.len != 0) {
        klog.warn("unknown command");
    }
}

fn readInputByte() ?u8 {
    return arch.readEarlyDebug();
}

fn echoByte(byte: u8) void {
    arch.writeEarlyDebug(&.{byte});
}

fn equals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }

    return true;
}
