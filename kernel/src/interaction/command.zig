pub fn equals(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }

    return true;
}

test "equals matches exact byte strings" {
    const std = @import("std");

    try std.testing.expect(equals("help", "help"));
    try std.testing.expect(!equals("help", "halt"));
    try std.testing.expect(!equals("help", "help "));
}
