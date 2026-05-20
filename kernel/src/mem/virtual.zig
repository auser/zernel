const page = @import("page.zig");

pub const Region = enum {
    outside,
    low_guard,
    mapped,
    high_guard,
};

pub const LayoutError = error{
    UnalignedAddress,
    InvalidPageCount,
    Overflow,
    AddressOutsideLayout,
    GuardPage,
};

pub const StackLayout = struct {
    base: usize,
    mapped_pages: usize,
    low_guard_pages: usize,
    high_guard_pages: usize,

    pub fn init(
        base: usize,
        mapped_pages: usize,
        low_guard_pages: usize,
        high_guard_pages: usize,
    ) LayoutError!StackLayout {
        if (!page.isAligned(base)) return error.UnalignedAddress;
        if (mapped_pages == 0) return error.InvalidPageCount;
        if (low_guard_pages == 0 or high_guard_pages == 0) return error.InvalidPageCount;

        const total_pages = try checkedAddPages(mapped_pages, low_guard_pages, high_guard_pages);
        _ = try checkedBytes(total_pages);
        _ = try checkedEnd(base, try checkedBytes(total_pages));

        return .{
            .base = base,
            .mapped_pages = mapped_pages,
            .low_guard_pages = low_guard_pages,
            .high_guard_pages = high_guard_pages,
        };
    }

    pub fn totalPages(self: StackLayout) usize {
        return self.low_guard_pages + self.mapped_pages + self.high_guard_pages;
    }

    pub fn totalSize(self: StackLayout) usize {
        return self.totalPages() * page.size;
    }

    pub fn mappedBase(self: StackLayout) usize {
        return self.base + self.low_guard_pages * page.size;
    }

    pub fn highGuardBase(self: StackLayout) usize {
        return self.mappedBase() + self.mapped_pages * page.size;
    }

    pub fn end(self: StackLayout) usize {
        return self.base + self.totalSize();
    }

    pub fn mappedPage(self: StackLayout, index: usize) LayoutError!usize {
        if (index >= self.mapped_pages) return error.AddressOutsideLayout;
        const offset = try checkedBytes(index);
        return checkedEnd(self.mappedBase(), offset);
    }

    pub fn classify(self: StackLayout, virt: usize) Region {
        const aligned = page.alignDown(virt);
        if (aligned < self.base or aligned >= self.end()) return .outside;
        if (aligned < self.mappedBase()) return .low_guard;
        if (aligned < self.highGuardBase()) return .mapped;
        return .high_guard;
    }

    pub fn validateMappedAddress(self: StackLayout, virt: usize) LayoutError!void {
        if (!page.isAligned(virt)) return error.UnalignedAddress;
        return switch (self.classify(virt)) {
            .mapped => {},
            .low_guard, .high_guard => error.GuardPage,
            .outside => error.AddressOutsideLayout,
        };
    }
};

fn checkedAddPages(mapped_pages: usize, low_guard_pages: usize, high_guard_pages: usize) LayoutError!usize {
    const low_plus_mapped, const first_overflow = @addWithOverflow(low_guard_pages, mapped_pages);
    if (first_overflow != 0) return error.Overflow;
    const total, const second_overflow = @addWithOverflow(low_plus_mapped, high_guard_pages);
    if (second_overflow != 0) return error.Overflow;
    return total;
}

fn checkedBytes(pages: usize) LayoutError!usize {
    const bytes, const overflow = @mulWithOverflow(pages, page.size);
    if (overflow != 0) return error.Overflow;
    return bytes;
}

fn checkedEnd(base: usize, size: usize) LayoutError!usize {
    const end_address, const overflow = @addWithOverflow(base, size);
    if (overflow != 0) return error.Overflow;
    return end_address;
}

test "stack layout separates guard and mapped pages" {
    const std = @import("std");

    const layout = try StackLayout.init(0x4000_0000, 2, 1, 1);

    try std.testing.expect(layout.totalPages() == 4);
    try std.testing.expect(layout.mappedBase() == 0x4000_1000);
    try std.testing.expect(layout.highGuardBase() == 0x4000_3000);
    try std.testing.expect(layout.end() == 0x4000_4000);
    try std.testing.expect(layout.classify(0x4000_0000) == .low_guard);
    try std.testing.expect(layout.classify(0x4000_1000) == .mapped);
    try std.testing.expect(layout.classify(0x4000_2000) == .mapped);
    try std.testing.expect(layout.classify(0x4000_3000) == .high_guard);
    try std.testing.expect(layout.classify(0x4000_4000) == .outside);
}

test "stack layout validates only mapped page addresses" {
    const std = @import("std");

    const layout = try StackLayout.init(0x5000_0000, 1, 1, 1);

    try layout.validateMappedAddress(0x5000_1000);
    try std.testing.expectError(error.GuardPage, layout.validateMappedAddress(0x5000_0000));
    try std.testing.expectError(error.GuardPage, layout.validateMappedAddress(0x5000_2000));
    try std.testing.expectError(error.AddressOutsideLayout, layout.validateMappedAddress(0x5000_3000));
    try std.testing.expectError(error.UnalignedAddress, layout.validateMappedAddress(0x5000_1001));
}

test "stack layout rejects invalid and overflowing layouts" {
    const std = @import("std");

    try std.testing.expectError(error.UnalignedAddress, StackLayout.init(1, 1, 1, 1));
    try std.testing.expectError(error.InvalidPageCount, StackLayout.init(0x6000_0000, 0, 1, 1));
    try std.testing.expectError(error.InvalidPageCount, StackLayout.init(0x6000_0000, 1, 0, 1));
    try std.testing.expectError(error.Overflow, StackLayout.init(std.math.maxInt(usize) - page.size + 1, 1, 1, 1));
}
