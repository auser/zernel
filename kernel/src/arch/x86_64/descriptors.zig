comptime {
  if (@sizeOf(IdtEntry) != 16) @compileError("bad IDT entry size");
  if (@sizeOf(DescriptorPointer) != 10) @compileError("bad descriptor pointer size");
}

var idt: [256]IdtEntry = [_]IdtEntry{emptyEntry()} ** 256;

pub const DescriptorPointer = packed struct {
  limit: u16,
  base: u64
};

pub const IdtEntry = packed struct {
  offset_low: u16,
  selector: u16,
  ist: u3,
  reserved_0: u5,
  gate_type: u4,
  zero: u1,
  dpl: u2,
  present: bool,
  offset_mid: u16,
  offset_high: u32,
  reserved_1: u32,
};

const gdt = [_]u64{
  0x0000000000000000, // Null.
  0x00af9a000000ffff, // Kernel code.
  0x00af92000000ffff, // Kernel data.
};

pub const kernel_code_selector: u16 = 0x08;
pub const kernel_data_selector: u16 = 0x10;

// Load the gdt
pub fn loadGdt() void {
  const ptr = DescriptorPointer{
    .limit = @sizeOf(@TypeOf(gdt)) - 1,
    .base = @intFromPtr(&gdt),
  };

  asm volatile ("lgdt (%[ptr]"
    :
    : [ptr] "r" (&ptr)
    : "memory"
  );
}

pub fn loadIdt() void {
    const ptr = DescriptorPointer{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&ptr),
        : "memory"
    );
}

fn emptyEntry() IdtEntry {
    return .{
        .offset_low = 0,
        .selector = 0,
        .ist = 0,
        .reserved_0 = 0,
        .gate_type = 0,
        .zero = 0,
        .dpl = 0,
        .present = false,
        .offset_mid = 0,
        .offset_high = 0,
        .reserved_1 = 0,
    };
}

fn setGate(vector: u8, handler: *const fn () callconv(.naked) void) void {
    const addr = @intFromPtr(handler);
    idt[vector] = .{
        .offset_low = @truncate(addr),
        .selector = kernel_code_selector,
        .ist = 0,
        .reserved_0 = 0,
        .gate_type = 0xe,
        .zero = 0,
        .dpl = 0,
        .present = true,
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
        .reserved_1 = 0,
    };
}
