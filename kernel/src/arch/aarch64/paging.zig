pub const page_size: usize = 4096;

pub fn pageOffset(virt: usize) usize {
  return virt & (page_size - 1);
}

