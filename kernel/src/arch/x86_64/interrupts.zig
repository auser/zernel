const klog = @import("../../utils/klog.zig");
const panic = @import("../../utils/panic.zig").panic;

export fn isr_invalid_opcode() callconv(.naked) void {
  asm volatile (
    \\ pushq $0
    \\ pushq $6
    \\ jmp common_exception_stub
  );
}

export fn isr_page_fault() callconv(.naked) void {
  asm volatile (
    \\ pushq $14
    \\ jmp common_exception_stub
  );
}

pub const ExceptionFrame = extern struct {
    vector: usize,
    error_code: usize,
    rip: usize,
    cs: usize,
    rflags: usize,
};

pub fn exceptionHandler(frame: *const ExceptionFrame) noreturn {
    klog.writeLabelDec("exception vector", frame.vector);
    klog.writeLabelHex("error code", frame.error_code);
    klog.writeLabelHex("rip", frame.rip);

    if (frame.vector == 14) {
        klog.writeLabelHex("page fault address", readCr2());
    }

    panic("unhandled CPU exception");
}

fn readCr2() usize {
  return asm volatile ("mov %%cr2, %[value]"
    : [value] "=r" (-> usize),
  );
}
