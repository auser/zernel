const arch = @import("arch.zig");
const boot_info = @import("boot/info.zig");
const klog = @import("klog.zig");
const limine = @import("limine");
const panic = @import("panic.zig").panic;

// This is the entrypoint
export fn _start() callconv(.c) noreturn {
    arch.initEarlyDebug();
    klog.info("zernel: booting");
    klog.info("serial initialized");

    if (!boot_info.base_revision.is_supported()) {
        panic("unsupported Limine base revision");
    }

    const info = boot_info.load();
    boot_info.validate(&info);
    boot_info.logFramebuffer(&info);
    boot_info.logMemoryMap(&info);
    boot_info.logAddressInfo(&info);

    paint(info.framebuffer);
    arch.halt();
}

fn paint(framebuffer: *limine.Framebuffer) void {
  const width: usize = @intCast(framebuffer.width);
  const height: usize = @intCast(framebuffer.height);
  const pitch: usize = @intCast(framebuffer.pitch);

  const pixels_per_line = pitch / 4;

  const raw_pixels: [*]volatile u32 = @ptrCast(@alignCast(framebuffer.address));

  var y: usize = 0;
  while (y < height): (y+=1) {
    var x: usize = 0;
    while (x<width):(x+=1) {
      const red: u32 = @intCast((x * 255) / width);
      const green: u32 = @intCast((y * 255) / height);
      const blue: u32 = 0x40;
      raw_pixels[y * pixels_per_line + x] = (red << 16) | (green << 8) | blue;
    }
  }
}
