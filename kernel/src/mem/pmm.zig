const page = @import("page.zig");
const panic = @import("../utils/panic.zig").panic;
const boot_info = @import("../boot/info.zig");
const limine = @import("limine");

pub fn init(info: *const boot_info.BootInfo) void {
  // Init
  const highest = findHighestUsable(info.memory_map);
  const total_pages = page.alignUp(highest) / page.size;
  const bytes = bitmapBytes(total_pages);

  const bitmap_phys =
    findBitmapStorage(info.memory_map, bytes) orelse
    panic("no pmm bitmap storage");

  const bitmap_virt = boot_info.physToHhdm(info, bitmap_phys);
  const bitmap: []u8 = @as([*]u8, @ptrFromInt(bitmap_virt))[0..bytes];

  // Clear the memory
  @memset(bitmap, 0xff);

  state = .{
    .bitmap = bitmap,
    .total_pages = total_pages,
    .free_pages = 0,
  };

  markUsableMemoryFree(info.memory_map);
  reserveRange(bitmap_phys, page.alignUp(bytes));
  reservePage(0);
}

pub fn allocPage() ?usize {
  var s = &(state orelse return null);

  var index: usize = 0;
  while (index < s.total_pages) : (index += 1) {
    if (!isUsed(s.bitmap, index)) {
      setUsed(s.bitmap, index, true);
      s.free_pages -= 1;
      return index * page.size;
    }
  }

  return null;
}

pub fn freePage(phys: usize) void {
  var s = &(state orelse panic("pmm not initialized"));

  if (!page.isAligned(phys)) {
    panic("freePage: unaligned address");
  }

  const index = phys / page.size;
  if (index >= s.total_pages) {
    panic("freePage: out of range");
  }

  if (!isUsed(s.bitmap, index)) {
    panic("freePage: double free");
  }

  setUsed(s.bitmap, index, false);
  s.free_pages += 1;
}

const State = struct {
  bitmap: []u8,
  total_pages: usize,
  free_pages: usize,
};

var state: ?State = null;

fn bitmapBytes(total_pages: usize) usize {
  return (total_pages + 7) / 8;
}

fn bitmapLocation(page_index: usize) struct { byte: usize, mask: u8 } {
  const bit_index: u3 = @intCast(page_index % 8);
  return .{
    .byte = page_index / 8,
    .mask = @as(u8, 1) << bit_index,
  };
}

fn isUsed(bitmap: []const u8, page_index: usize) bool {
  const loc = bitmapLocation(page_index);
  return (bitmap[loc.byte] & loc.mask) != 0;
}

fn setUsed(bitmap: []u8, page_index: usize, used: bool) void {
  const loc = bitmapLocation(page_index);
  if (used) {
    bitmap[loc.byte] |= loc.mask;
  } else {
    bitmap[loc.byte] &= ~loc.mask;
  }
}

fn findHighestUsable(memory_map: *limine.MemoryMapResponse) usize {
  var highest: usize = 0;
  for (memory_map.entries()) |entry| {
    if (entry.kind != .usable) continue;
    const end: usize = @intCast(entry.base + entry.length);
    if (end > highest) highest = end;
  }
  return highest;
}

fn findBitmapStorage(memory_map: *limine.MemoryMapResponse, bytes: usize) ?usize {
  const needed = page.alignUp(bytes);
  for (memory_map.entries()) |entry| {
    if (entry.kind != .usable) continue;

    const base: usize = page.alignUp(@intCast(entry.base));
    const end: usize = @intCast(entry.base + entry.length);
    if (base + needed <= end) return base;
  }
  return null;
}

fn markPageUsed(page_index: usize, used: bool) void {
  var s = &(state orelse panic("pmm not initialized"));
  const was_used = isUsed(s.bitmap, page_index);
  if (was_used == used) return;

  setUsed(s.bitmap, page_index, used);
  if (used) {
    s.free_pages -= 1;
  } else {
    s.free_pages += 1;
  }
}

fn markRange(phys: usize, length: usize, used: bool) void {
  const start = page.alignDown(phys);
  const end = page.alignUp(phys + length);

  var current = start;
  while (current < end) : (current += page.size) {
    markPageUsed(current / page.size, used);
  }
}

fn markUsableMemoryFree(memory_map: *limine.MemoryMapResponse) void {
  for (memory_map.entries()) |entry| {
    if (entry.kind != .usable) continue;
    markRange(@intCast(entry.base), @intCast(entry.length), false);
  }
}

fn reserveRange(phys: usize, length: usize) void {
  markRange(phys, length, true);
}

fn reservePage(phys: usize) void {
  reserveRange(phys, page.size);
}
