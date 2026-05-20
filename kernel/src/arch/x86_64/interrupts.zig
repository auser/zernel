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
