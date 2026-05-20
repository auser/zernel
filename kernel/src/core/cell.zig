pub const CellId = enum(u32) { invalid = 0, _ };

pub const CellKind = enum(u16) {
    kernel_boot,
    shell_command,
    driver_service,
    route_worker,
    agent_loop,
};

pub const CellState = enum(u8) {
    created,
    ready,
    running,
    blocked,
    completed,
    failed,
};
