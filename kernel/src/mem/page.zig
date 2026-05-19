pub const size: usize = 4096;

pub fn alignDown(value: usize) usize {
  return value & ~(size - 1);
}

pub fn alignUp(value: usize) usize {
  return alignDown(value + size - 1);
}

pub fn isAligned(value: usize) bool {
  return (value & (size - 1)) == 0;
}
