const builtin = @import("builtin");
const limine = @import("limine");

pub export var base_revision: limine.BaseRevision linksection(".limine_requests") = .{
  .revision = 3,
};

pub export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

export fn _start() callconv(.c) noreturn {
  if (!base_revision.is_supported()) {
    hang();
  }

  const response = framebuffer_request.response orelse hang();
  if (response.framebuffer_count == 0) {
    hang();
  }

  const framebuffer = response.framebuffers()[0];
  if (framebuffer.bpp != 32) {
    hang();
  }

  paint(framebuffer);
  hang();
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

fn hang() noreturn {
  switch (builtin.cpu.arch) {
    .x86_64 => {
      asm volatile ("cli");
      while (true) {
        asm volatile ("hlt");
      }
    },
    .aarch64 => {
      asm volatile ("msr daifset, #0xf");
      while (true) {
        asm volatile ("wfi");
      }
    },
  else => @compileError("unsupported kernel architecture"),
  }
}
