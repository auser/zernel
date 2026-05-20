pub const size: usize = 4096;

pub fn alignDown(value: usize) usize {
    return value & ~(size - 1);
}

pub fn alignUp(value: usize) usize {
    return alignDown(value + size - 1);
}

pub fn alignUpChecked(value: usize) ?usize {
    const result, const overflow = @addWithOverflow(value, size - 1);
    if (overflow != 0) return null;
    return alignDown(result);
}

pub fn isAligned(value: usize) bool {
    return (value & (size - 1)) == 0;
}

test "alignUpChecked rejects overflow" {
    const std = @import("std");

    try std.testing.expect(alignUpChecked(0) == 0);
    try std.testing.expect(alignUpChecked(1) == size);
    try std.testing.expect(alignUpChecked(size) == size);
    try std.testing.expect(alignUpChecked(std.math.maxInt(usize)) == null);
}
