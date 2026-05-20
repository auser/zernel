pub const DecodedKey = struct {
    code: u16,
    pressed: bool,
};

pub fn readScancode() ?u8 {
    return null;
}

pub fn decode(scancode: u8) ?DecodedKey {
    _ = scancode;
    return null;
}
