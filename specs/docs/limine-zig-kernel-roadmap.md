# Building A Zig Kernel With Limine And QEMU

This is a tutorial-style guide for recreating the `zernel` project as a small
Zig kernel inspired by Zen's `reboot` branch.

The architecture is:

```text
Zig freestanding ELF kernel -> Limine bootloader -> bootable ISO -> QEMU
```

The goal is to build a real bootable kernel path, not a native program that
pretends to be a kernel. Limine handles the firmware-specific boot work and
passes our kernel useful information such as a framebuffer, memory map, and
higher-half direct map.

## What We Are Building

The first milestone is intentionally small and starts with `x86_64`:

1. Build a static `x86_64-freestanding-none` ELF kernel with Zig.
2. Export a `_start` entry point.
3. Ask Limine for a framebuffer.
4. Fill the framebuffer with a visible color pattern.
5. Halt the CPU forever.
6. Package the kernel into a bootable ISO.
7. Run the ISO in QEMU.

Do not add GDT, IDT, paging changes, heap allocation, or interrupts yet. Those
are later milestones.

After the `x86_64` kernel boots, extend the same project to build an `aarch64`
kernel as a second target. The source can stay mostly shared, but the build
target, linker script, halt instruction, Limine EFI binary, and QEMU command are
architecture-specific.

## Prerequisites

Install the local tools:

```sh
brew install qemu xorriso make
```

Check Zig:

```sh
zig version
```

This guide assumes Zig `0.16.0`, matching the Zen `reboot` branch we are using
as a reference.

## Important Concepts

### This Is Not A UEFI App

A UEFI app is a PE/COFF executable launched by firmware. It talks to UEFI
services through `std.os.uefi`.

This tutorial builds a freestanding ELF kernel instead. Limine is the UEFI/BIOS
program. Limine loads our ELF kernel, prepares the machine, and jumps to our
entry point.

### This Is Not VGA Text Mode

The early `main.zig` wrote to `0xB8000`. That address is legacy VGA text memory.
It is not a good base for a modern Limine kernel.

Here, display output starts with the Limine framebuffer. Limine tells us where
the framebuffer is, how wide it is, how tall it is, and how many bytes each row
uses.

### Why Limine

Without a bootloader, the kernel must handle many platform details itself:

- BIOS versus UEFI
- loading an ELF image
- entering long mode
- page tables
- memory map discovery
- framebuffer discovery

Limine gives us a stable boot protocol so we can focus on kernel code first.

### Multi-Architecture Shape

We can support both `x86_64` and `aarch64`, but not by pretending they boot the
same way.

The practical split is:

```text
x86_64  -> Limine BIOS/UEFI ISO -> qemu-system-x86_64
aarch64 -> Limine UEFI ISO      -> qemu-system-aarch64 + EDK2 firmware
```

The Limine binary branch includes both `BOOTX64.EFI` and `BOOTAA64.EFI`. For
`x86_64`, we can also use the BIOS CD files. For `aarch64`, treat the boot path
as UEFI-only.

We should keep one shared `kernel/src/main.zig` as long as possible, using small
architecture-specific helpers only where unavoidable.

## Final Project Layout

Move the repository toward this structure:

```text
zernel/
  Makefile
  boot/
    limine.conf
  kernel/
    build.zig
    build.zig.zon
    linker-x86_64.ld
    linker-aarch64.ld
    src/
      main.zig
```

The responsibilities are:

- `Makefile`: download/build Limine, build the kernel, create the ISO, run QEMU.
- `boot/limine.conf`: tell Limine how to boot our kernel.
- `kernel/build.zig`: compile the freestanding Zig kernel.
- `kernel/build.zig.zon`: pin the Zig package dependency for Limine protocol structs.
- `kernel/linker-*.ld`: place kernel sections where Limine and each architecture expect them.
- `kernel/src/main.zig`: kernel entry point and first framebuffer write.

## Step 1: Create The Directories

From the repo root:

```sh
mkdir -p boot kernel/src
```

The current stock Zig files at the repo root can stay for now, but the kernel
we are building will live under `kernel/`.

## Step 2: Add `boot/limine.conf`

Create `boot/limine.conf`:

```text
timeout: 0

/Zernel
    protocol: limine
    kernel_path: boot():/kernel
    kaslr: no
```

Explanation:

- `timeout: 0` boots immediately.
- `/Zernel` is the boot menu entry name.
- `protocol: limine` selects the Limine boot protocol.
- `kernel_path: boot():/kernel` tells Limine to load the file named `kernel`
  from the ISO root.
- `kaslr: no` disables kernel address randomization while we are learning and
  debugging.

## Step 3: Add `kernel/build.zig.zon`

Create `kernel/build.zig.zon`:

```zig
.{
    .name = .zernel_kernel,
    .version = "0.0.1",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .limine = .{
            .url = "https://github.com/48cf/limine-zig/archive/7b29b6e6f6d35052f01ed3831085a39aae131705.tar.gz",
            .hash = "1220f946f839eab2ec49dca1c805ce72ac3e3ef9c47b3afcdecd1c05a7b35f66d277",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "linker-x86_64.ld",
        "linker-aarch64.ld",
        "src",
    },
}
```

This pins the same Limine Zig package used by the Zen reference. That package
contains Zig definitions for Limine request and response structures.

## Step 4: Add `kernel/build.zig`

Create `kernel/build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    var target_query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };

    const Feature = std.Target.x86.Feature;
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.x87));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
    target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .pic = false,
        .omit_frame_pointer = false,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .link_libc = false,
        .link_libcpp = false,
    });

    const limine = b.dependency("limine", .{});
    kernel_module.addImport("limine", limine.module("limine"));

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_module,
        .linkage = .static,
    });

    kernel.want_lto = false;
    kernel.link_function_sections = true;
    kernel.link_data_sections = true;
    kernel.link_gc_sections = true;
    kernel.link_z_max_page_size = 0x1000;
    kernel.setLinkerScript(b.path("linker-x86_64.ld"));

    b.installArtifact(kernel);
}
```

Key details:

- The target is `x86_64-freestanding-none`, not native macOS.
- The red zone is disabled. Interrupts can clobber the red zone, so kernels
  should not rely on it.
- Stack protector/checking are disabled for the first boot path.
- Floating-point and SIMD features are disabled until the kernel knows how to
  save and restore that CPU state.
- `.code_model = .kernel` pairs with the higher-half linker script.
- The output binary is named `kernel`, matching `limine.conf`.

## Step 5: Add `kernel/linker-x86_64.ld`

Create `kernel/linker-x86_64.ld`:

```ld
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

PHDRS
{
    limine_requests PT_LOAD;
    text            PT_LOAD;
    rodata          PT_LOAD;
    data            PT_LOAD;
}

SECTIONS
{
    . = 0xFFFFFFFF80000000;

    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :limine_requests

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
```

Important parts:

- `ENTRY(_start)` means the kernel must export `_start`.
- The base address is in the higher half: `0xFFFFFFFF80000000`.
- The `.limine_requests` section is kept explicitly. If the linker discards it,
  Limine will not see our boot protocol requests.
- `.eh_frame` and note sections are discarded to keep early kernel output
  smaller and simpler.

## Step 6: Add The First Kernel

Create `kernel/src/main.zig`:

```zig
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
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const red: u32 = @intCast((x * 255) / width);
            const green: u32 = @intCast((y * 255) / height);
            const blue: u32 = 0x40;
            raw_pixels[y * pixels_per_line + x] = (red << 16) | (green << 8) | blue;
        }
    }
}

fn hang() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
```

What this does:

- `base_revision` tells Limine which protocol revision we expect.
- `framebuffer_request` asks Limine to provide a framebuffer response.
- `_start` is the true kernel entry point.
- `paint` writes directly to framebuffer memory.
- `hang` disables interrupts and halts forever.

Why this avoids a text terminal at first:

- A terminal requires a font, glyph rendering, cursor state, scrolling, and
  formatted output.
- A color gradient is enough to prove the kernel booted and can write pixels.

## Step 7: Add The Top-Level `Makefile`

Create `Makefile` at the repo root:

```make
ZIGFLAGS := -Doptimize=ReleaseSafe

ISO_DIR := iso_root
ISO_FILE := zernel.iso
KERNEL_BIN := kernel/zig-out/bin/kernel

.PHONY: all
all: $(ISO_FILE)

boot/limine:
	git clone https://codeberg.org/Limine/Limine.git \
		--branch=v9.x-binary --depth=1               \
		boot/limine
	$(MAKE) -C boot/limine

.PHONY: kernel
kernel:
	cd kernel && zig build $(ZIGFLAGS)

$(ISO_FILE): boot/limine kernel
	rm -rf $(ISO_DIR)
	mkdir -p $(ISO_DIR)/EFI/BOOT

	cp boot/limine.conf $(ISO_DIR)
	cp $(KERNEL_BIN) $(ISO_DIR)

	cp boot/limine/limine-bios.sys    \
	   boot/limine/limine-bios-cd.bin \
	   boot/limine/limine-uefi-cd.bin \
	   $(ISO_DIR)

	cp boot/limine/BOOTX64.EFI \
	   boot/limine/BOOTIA32.EFI \
	   $(ISO_DIR)/EFI/BOOT/

	xorriso -as mkisofs -R -r -J -b limine-bios-cd.bin                \
		-no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus     \
		-apm-block-size 2048 --efi-boot limine-uefi-cd.bin            \
		-efi-boot-part --efi-boot-image --protective-msdos-label      \
		$(ISO_DIR) -o $(ISO_FILE)

	./boot/limine/limine bios-install $(ISO_FILE)
	rm -rf $(ISO_DIR)

.PHONY: run
run: $(ISO_FILE)
	qemu-system-x86_64 -M q35 -m 128M -cdrom $(ISO_FILE) -boot d

.PHONY: debug
debug: $(ISO_FILE)
	qemu-system-x86_64 -M q35 -m 128M -cdrom $(ISO_FILE) -boot d \
		-serial stdio -no-reboot -no-shutdown

.PHONY: clean
clean:
	rm -rf $(ISO_DIR) $(ISO_FILE)
	rm -rf kernel/.zig-cache kernel/zig-out

.PHONY: distclean
distclean: clean
	rm -rf boot/limine
```

What each target does:

- `make`: builds `zernel.iso`.
- `make kernel`: builds only the Zig kernel.
- `make run`: boots the ISO in QEMU.
- `make debug`: boots with serial/stdout and keeps QEMU open on crashes.
- `make clean`: removes build products.
- `make distclean`: also removes the downloaded Limine tree.

## Step 8: Build The Kernel Only

Start with the Zig kernel before making an ISO:

```sh
make kernel
```

Expected output artifact:

```text
kernel/zig-out/bin/kernel
```

If this fails, do not continue to ISO creation. Fix the kernel build first.

Useful checks:

```sh
file kernel/zig-out/bin/kernel
```

Expected shape:

```text
ELF 64-bit LSB executable, x86-64
```

## Step 9: Build The ISO

Build the bootable ISO:

```sh
make
```

Expected output:

```text
zernel.iso
```

This step downloads Limine the first time. If the download fails, check network
access and try again.

## Step 10: Run In QEMU

Run:

```sh
make run
```

Expected result:

- QEMU opens.
- Limine boots immediately.
- The screen shows a color gradient.
- The VM stays running because the kernel halts forever.

If QEMU exits immediately, run:

```sh
make debug
```

The debug target uses:

```sh
-serial stdio -no-reboot -no-shutdown
```

That makes crashes easier to see.

## Step 11: Add `aarch64` Beside `x86_64`

Once the `x86_64` checkpoint boots, add `aarch64` as a second architecture.
Do this as a second phase so there is always one known-good boot path.

The multi-architecture target matrix should be:

```text
x86_64:
  Zig target: x86_64-freestanding-none
  Kernel file: kernel-x86_64
  Limine EFI path: EFI/BOOT/BOOTX64.EFI
  Optional BIOS support: yes
  QEMU: qemu-system-x86_64

aarch64:
  Zig target: aarch64-freestanding-none
  Kernel file: kernel-aarch64
  Limine EFI path: EFI/BOOT/BOOTAA64.EFI
  Optional BIOS support: no
  QEMU: qemu-system-aarch64
```

### Rename The x86 Linker Script

The earlier `kernel/linker-x86_64.ld` is x86-specific because it uses:

```ld
OUTPUT_FORMAT(elf64-x86-64)
. = 0xFFFFFFFF80000000;
```

Keep it for `x86_64`.

### Add `kernel/linker-aarch64.ld`

Limine rejects lower-half kernel load segments on `aarch64`, so use a
higher-half layout here too. Create `kernel/linker-aarch64.ld`:

```ld
OUTPUT_FORMAT(elf64-littleaarch64)
ENTRY(_start)

PHDRS
{
    text   PT_LOAD;
    rodata PT_LOAD;
    data   PT_LOAD;
}

SECTIONS
{
    . = 0xFFFFFFFF80000000;

    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :data

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));
    .data : {
        *(.data .data.*)
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
    }
}
```

The important detail is that all loadable program headers are now in the higher
half. If this starts at `SIZEOF_HEADERS`, Limine will fail with:

```text
PANIC: elf: Lower half PHDRs are not allowed
```

### Make `hang()` Architecture-Specific

The x86 halt code uses `cli` and `hlt`. That will not assemble for `aarch64`.
Update the tutorial kernel's `hang()` to branch on the compile target:

```zig
const builtin = @import("builtin");
const limine = @import("limine");

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
```

The framebuffer painting code can remain shared.

### Update `kernel/build.zig` To Accept `-Darch`

The first build file hardcoded `x86_64`. Replace the hardcoded target setup with
an architecture option:

```zig
const arch_name = b.option([]const u8, "arch", "Kernel architecture: x86_64 or aarch64") orelse "x86_64";

const cpu_arch: std.Target.Cpu.Arch = if (std.mem.eql(u8, arch_name, "x86_64"))
    .x86_64
else if (std.mem.eql(u8, arch_name, "aarch64"))
    .aarch64
else
    @panic("unsupported -Darch value");

var target_query: std.Target.Query = .{
    .cpu_arch = cpu_arch,
    .os_tag = .freestanding,
    .abi = .none,
};

if (cpu_arch == .x86_64) {
    const Feature = std.Target.x86.Feature;
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.x87));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
    target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));
}
```

Then choose the linker script and output name from `arch_name`:

```zig
const linker_script = if (cpu_arch == .x86_64)
    b.path("linker-x86_64.ld")
else
    b.path("linker-aarch64.ld");

const kernel = b.addExecutable(.{
    .name = b.fmt("kernel-{s}", .{arch_name}),
    .root_module = kernel_module,
    .linkage = .static,
});

kernel.setLinkerScript(linker_script);
```

For `x86_64`, keep:

```zig
.code_model = .kernel,
```

For `aarch64`, use `.large`. LLVM does not allow `.kernel` on AArch64, and
`.small` is not appropriate once the linker script places the kernel in the
higher half:

```zig
.code_model = if (cpu_arch == .x86_64) .kernel else .large,
```

The expected commands become:

```sh
cd kernel
zig build -Darch=x86_64
zig build -Darch=aarch64
```

Expected artifacts:

```text
kernel/zig-out/bin/kernel-x86_64
kernel/zig-out/bin/kernel-aarch64
```

### Add Architecture-Specific ISO Targets

Keep one Limine download, but create separate ISO outputs:

```text
zernel-x86_64.iso
zernel-aarch64.iso
```

The Makefile targets should be:

```sh
make iso-x86_64
make iso-aarch64
make iso-all
```

Keep `make` as a shorthand for the known-good `x86_64` ISO while the `aarch64`
path is still being brought up.

For `x86_64`, copy:

```text
boot/limine/limine-bios.sys
boot/limine/limine-bios-cd.bin
boot/limine/limine-uefi-cd.bin
boot/limine/BOOTX64.EFI -> EFI/BOOT/BOOTX64.EFI
kernel/zig-out/bin/kernel-x86_64 -> kernel
```

For `aarch64`, copy:

```text
boot/limine/limine-uefi-cd.bin
boot/limine/BOOTAA64.EFI -> EFI/BOOT/BOOTAA64.EFI
kernel/zig-out/bin/kernel-aarch64 -> kernel
```

The `limine.conf` can stay the same because each ISO still contains a file named
`/kernel`.

The matching run targets should be:

```sh
make run-x86_64
make run-aarch64
make debug-x86_64
make debug-aarch64
```

### Run x86_64

```sh
qemu-system-x86_64 -M q35 -m 128M -cdrom zernel-x86_64.iso -boot d
```

Debug form:

```sh
qemu-system-x86_64 -M q35 -m 128M -cdrom zernel-x86_64.iso -boot d \
    -serial stdio -no-reboot -no-shutdown
```

### Run aarch64

On Homebrew QEMU, the AArch64 EDK2 firmware is usually:

```text
/opt/homebrew/share/qemu/edk2-aarch64-code.fd
```

Run:

```sh
qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a72 \
    -m 128M \
    -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
    -device ramfb \
    -cdrom zernel-aarch64.iso \
    -boot d
```

Debug form:

```sh
qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a72 \
    -m 128M \
    -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
    -device ramfb \
    -cdrom zernel-aarch64.iso \
    -boot d \
    -serial stdio \
    -no-reboot \
    -no-shutdown
```

If QEMU cannot find the firmware file, inspect:

```sh
ls /opt/homebrew/share/qemu
```

Look for `edk2-aarch64-code.fd`.

The `-device ramfb` argument matters. The AArch64 `virt` machine does not expose
the same default VGA device as x86 QEMU. `ramfb` gives the firmware a simple
framebuffer device, which lets Limine satisfy the framebuffer request.

### Recommended Order

Do the ports in this order:

1. Boot `x86_64`.
2. Change `hang()` to be architecture-aware while still testing `x86_64`.
3. Add the `-Darch` build option.
4. Confirm `x86_64` still boots.
5. Add `linker-aarch64.ld`.
6. Build `aarch64`.
7. Package `zernel-aarch64.iso`.
8. Boot `aarch64` in QEMU.

That order keeps regressions narrow.

## Troubleshooting

### `zig build` Downloads The Limine Dependency Every Time

This should not happen after the first successful build. Zig stores package
downloads in its global cache. If the cache is being cleared, the dependency
will be fetched again.

### `framebuffer_request.response` Is Null

Likely causes:

- The `.limine_requests` section was discarded.
- the active linker script is missing `KEEP(*(.limine_requests))`.
- `kernel.setLinkerScript(...)` is not wired in the build file.
- The ISO is booting an old kernel binary.

Run:

```sh
make clean
make
```

### QEMU Reboots Instantly

That usually means a CPU fault escalated into a triple fault.

Run:

```sh
make debug
```

Then simplify `_start` until it only calls `hang()`. Add code back one block at
a time.

### The Screen Is Black

Possible causes:

- The kernel did not boot.
- The framebuffer request failed.
- The framebuffer format is not 32 bits per pixel.
- The pixel format is different from the assumed `0x00RRGGBB` layout.

For the first version, `framebuffer.bpp != 32` halts. Later, inspect
`red_mask_shift`, `green_mask_shift`, and `blue_mask_shift` instead of assuming
RGB layout.

### `xorriso` Is Missing

Install it:

```sh
brew install xorriso
```

### `qemu-system-x86_64` Is Missing

Install QEMU:

```sh
brew install qemu
```

### `qemu-system-aarch64` Is Missing

Homebrew's `qemu` package should include it:

```sh
brew install qemu
```

Then check:

```sh
which qemu-system-aarch64
```

## Next Milestones

After the color-gradient kernel boots, add features in this order.

### Milestone 2: Serial Logging

Add a tiny COM1 serial writer. This gives a debugging path that does not depend
on the framebuffer.

Then update `make debug` to keep:

```sh
-serial stdio
```

### Milestone 3: Panic Handler

Add:

```zig
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn
```

The panic handler should write to serial first, then framebuffer if available,
then halt.

### Milestone 4: Framebuffer Terminal

Add:

- bitmap font
- draw glyph
- write character
- write string
- newline handling
- scrolling
- basic colors

This turns the first framebuffer proof into usable kernel output.

### Milestone 5: GDT

Set up a known-good Global Descriptor Table. Limine has already put the CPU in
long mode, but the kernel should eventually own its descriptor tables.

### Milestone 6: IDT And Exceptions

Set up an Interrupt Descriptor Table and handlers for CPU exceptions. This is
where crashes become diagnosable instead of silent reboots.

### Milestone 7: Memory Map

Request and parse Limine's memory map. Print usable regions through serial or
the framebuffer terminal.

### Milestone 8: Physical Page Allocator

Build a page allocator from the usable memory map entries.

### Milestone 9: Virtual Memory

Inspect the active paging setup, then create kernel-owned page table management.

### Milestone 10: Heap

Build a kernel heap on top of the physical and virtual memory allocators.

## Reference Links

- Zen `reboot` branch: https://github.com/AndreaOrru/zen/tree/reboot
- Zen Makefile: https://raw.githubusercontent.com/AndreaOrru/zen/reboot/Makefile
- Zen kernel build: https://raw.githubusercontent.com/AndreaOrru/zen/reboot/kernel/build.zig
- Zen Limine config: https://raw.githubusercontent.com/AndreaOrru/zen/reboot/boot/limine.conf
- Zen linker script: https://raw.githubusercontent.com/AndreaOrru/zen/reboot/kernel/linker.ld
- Limine bootloader: https://codeberg.org/Limine/Limine
- Limine Zig protocol structs: https://github.com/48cf/limine-zig
