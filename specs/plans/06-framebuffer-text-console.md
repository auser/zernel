# Plan 06: Framebuffer Text Console

## Goal

Add human-readable on-screen text after serial logging and panic diagnostics
already exist.

The framebuffer console is useful, but it is not the first debugging mechanism.
It has more moving parts than serial output: fonts, glyph rendering, cursor
state, line wrapping, and scrolling.

## Why This Comes Next

The next code needs local, human-readable output that does not depend on the
serial terminal. Serial remains the primary early debug path, but a framebuffer
console makes panics, boot summaries, registry dumps, and future shell output
visible on the machine's main display.

The framebuffer console is needed for:

- showing boot progress on graphical QEMU and real hardware;
- making panic and exception output visible without serial setup;
- providing an output sink for an early kernel monitor or shell;
- inspecting object, capability, cell, and route registries in a friendlier
  form;
- preparing for later UI, compositor, or desktop experiments without making
  graphics the only debug path.

## What We Will Build

- A bitmap font.
- Glyph rendering into the Limine framebuffer.
- Cursor position state.
- Newline, carriage return, tab, and wrapping behavior.
- Scrolling.
- Integration with `klog` as a second output sink.

## Concepts To Understand First

- Framebuffer pitch versus width.
- Pixel formats and 32-bit color layout.
- Bitmap font storage.
- Character cell dimensions.
- Why text rendering must not assume contiguous rows of only visible pixels.

## Math Notes

### Pitch Versus Width

`width` is visible pixels per row. `pitch` is bytes per row in memory. They are
not always the same relationship because firmware may pad each row.

For 32-bit pixels:

```text
bytes_per_pixel = 4
pitch_pixels    = pitch / 4
```

The pixel index for `(x, y)` is:

```text
index = y * pitch_pixels + x
```

Use `pitch_pixels`, not `width`, when moving from one framebuffer row to the
next.

### Character Cell Coordinates

The console uses character-cell coordinates. With an 8x16 font:

```text
pixel_x = cell_x * 8
pixel_y = cell_y * 16
```

The number of text columns and rows is:

```text
columns = framebuffer_width / font_width
rows    = framebuffer_height / font_height
```

### Glyph Bits

Each glyph row is one byte. For an 8-pixel-wide font, bit 7 is the leftmost
pixel and bit 0 is the rightmost pixel:

```text
mask = 1 << (7 - column)
pixel_on = (glyph_row & mask) != 0
```

### Scrolling

Scrolling up by one text row means copying pixels upward by `font.height` pixel
rows:

```text
destination_y = y
source_y      = y + font.height
```

The last `font.height` pixel rows are then cleared.

## Step 1: Pick A Font

Start with a tiny built-in bitmap font.

Options:

- Embed an 8x16 public-domain bitmap font.
- Define a very small temporary font for digits and uppercase letters.

Solution:

Create `kernel/src/fb/font.zig`.

For the blog/tutorial path, start with a tiny font table that covers the
characters used in early logs. Then replace it with a full public-domain 8x16
font once the renderer works.

Shape:

File: `kernel/src/fb/font.zig`

```zig
pub const width: usize = 8;
pub const height: usize = 16;

pub fn glyph(ch: u8) [height]u8 {
    return switch (ch) {
        'A' => .{
            0b00011000,
            0b00100100,
            // ...
        },
        else => blank,
    };
}

const blank = [_]u8{0} ** height;
```

The font is deliberately plain data. It should not depend on allocation,
filesystems, or firmware services.

Checkpoint:

- Font data is compiled into the kernel.
- No filesystem or heap is needed.

## Step 2: Draw One Glyph

Add:

- `drawGlyph(x: usize, y: usize, ch: u8, fg: u32, bg: u32)`.

Solution:

Create `kernel/src/fb/console.zig`:

File: `kernel/src/fb/console.zig`

```zig
const limine = @import("limine");
const font = @import("font.zig");

var framebuffer: ?*limine.Framebuffer = null;

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
```

This version uses character-cell coordinates, not raw pixel coordinates, because
that makes later wrapping and scrolling easier.

Checkpoint:

- Drawing `A` at a fixed position works.
- Pixel writes respect framebuffer pitch.

## Step 3: Draw Strings

Add:

- Cursor column and row.
- `putChar`.
- `writeString`.

Support:

- Printable ASCII.
- `\n`.
- `\r`.

Solution:

Add console state:

File: `kernel/src/fb/console.zig`

```zig
var cursor_col: usize = 0;
var cursor_row: usize = 0;

fn cols() usize {
    const fb = framebuffer orelse return 0;
    return @as(usize, @intCast(fb.width)) / font.width;
}

fn rows() usize {
    const fb = framebuffer orelse return 0;
    return @as(usize, @intCast(fb.height)) / font.height;
}
```

Implement character output:

File: `kernel/src/fb/console.zig`

```zig
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
```

Scrolling can be added in the next step, so for now it is acceptable to stop
writing once `cursor_row >= rows()`.

Checkpoint:

- The kernel can write several lines of text to the screen.
- Serial logging still works independently.

## Step 4: Add Wrapping And Scrolling

When the cursor reaches the end of a line, wrap to the next row.

When the cursor reaches the bottom:

- Move existing text up by one character row.
- Clear the last row.

Solution:

Add a `newline()` helper:

File: `kernel/src/fb/console.zig`

```zig
fn newline() void {
    cursor_col = 0;
    cursor_row += 1;
    if (cursor_row >= rows()) {
        scrollOneRow();
        cursor_row = rows() - 1;
    }
}
```

Scrolling means copying framebuffer pixels upward by `font.height` pixel rows:

File: `kernel/src/fb/console.zig`

```zig
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
```

This is not the fastest scroll implementation, but it is simple and correct.

Checkpoint:

- Writing more lines than fit on the screen scrolls cleanly.
- Text does not corrupt memory outside the framebuffer.

## Step 5: Integrate With `klog`

Make `klog` write to:

- Serial.
- Framebuffer console when initialized.

Solution:

Change `klog` from direct serial-only output to output sinks:

File: `kernel/src/klog.zig`

```zig
const arch = @import("arch.zig");
const console = @import("fb/console.zig");

fn write(bytes: []const u8) void {
    arch.writeEarlyDebug(bytes);
    console.writeString(bytes);
}
```

The console should ignore writes until `console.init(framebuffer)` has been
called. That keeps early boot logs safe.

Checkpoint:

- Early logs before framebuffer console init still go to serial.
- Later logs appear both on screen and in the QEMU terminal.

## Step 6: Use Console In Panic Path

Update panic handling:

- Serial always receives the panic.
- Framebuffer console receives the panic if initialized.
- Screen can still switch to a distinct panic color or banner.

Solution:

Make panic use `klog`, not console directly:

File: `kernel/src/panic.zig`

```zig
const arch = @import("arch.zig");
const klog = @import("klog.zig");

pub fn panic(msg: []const u8) noreturn {
    klog.err("PANIC");
    klog.err(msg);
    klog.err("system halted");
    arch.halt();
}
```

If the console was not initialized, `klog` still writes to serial. If it was
initialized, the panic is visible in both places.

Checkpoint:

- Panics before console init are still visible over serial.
- Panics after console init are visible both over serial and on screen.

## Done When

- The kernel can print readable text on the framebuffer.
- Text output wraps and scrolls.
- The console is an optional output sink, not a dependency for early boot.
