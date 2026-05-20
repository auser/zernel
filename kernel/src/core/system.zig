const builtin = @import("builtin");
const boot_info = @import("../boot/info.zig");
const arch = @import("../arch.zig");
const build_options = @import("build_options");
const klog = @import("../utils/klog.zig");
const mapping = @import("../mem/mapping.zig");
const page = @import("../mem/page.zig");
const pmm = @import("../mem/pmm.zig");
const panic = @import("../utils/panic.zig").panic;

pub const object = @import("object.zig");
pub const address_space = @import("address_space.zig");
pub const capability = @import("capability.zig");
pub const cell = @import("cell.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const heap = @import("../mem/heap.zig");
pub const policy = @import("policy.zig");
pub const provenance = @import("provenance.zig");
pub const route = @import("route.zig");
pub const scheduler = @import("scheduler.zig");
pub const stack = @import("stack.zig");

const BootInfo = boot_info.BootInfo;

pub const BootReport = struct {
    version: usize = 1,
    arch_name: []const u8,
    build_mode: []const u8,
    git_commit: []const u8,
    objects: usize,
    capabilities: usize,
    cells: usize,
    routes: usize,
    provenance: usize,
};

var objects: object.Registry = .{};
var address_spaces: address_space.Registry = .{};
var capabilities: capability.Registry = .{};
var cells: cell.Registry = .{};
var provenance_records: provenance.Registry = .{};
var routes: route.Registry = .{};
var dispatcher_state: dispatcher.Dispatcher = .{};
var scheduler_state: scheduler.Scheduler = .{};
var stacks: stack.Registry = .{};

var kernel_log_object: object.ObjectId = .invalid;
var framebuffer_object: object.ObjectId = .invalid;
var memory_map_object: object.ObjectId = .invalid;
var boot_cell_object: object.ObjectId = .invalid;

var framebuffer_read_capability: capability.CapabilityId = .invalid;
var memory_map_read_capability: capability.CapabilityId = .invalid;

var boot_cell: cell.CellId = .invalid;
var boot_inspect_route: route.RouteId = .invalid;

pub fn initBoot(info: *const BootInfo) void {
    _ = info;

    objects.reset();
    address_spaces.reset();
    capabilities.reset();
    cells.reset();
    provenance_records.reset();
    routes.reset();
    dispatcher_state = .{};
    scheduler_state.reset();
    stacks.reset();

    kernel_log_object = createObject(.kernel_log, "kernel_log");
    framebuffer_object = createObject(.framebuffer, "framebuffer");
    memory_map_object = createObject(.memory_region, "memory_map");
    boot_cell_object = createObject(.execution_cell, "kernel_boot");

    framebuffer_read_capability = grantCapability(framebuffer_object, .{ .read = true });
    memory_map_read_capability = grantCapability(memory_map_object, .{ .read = true });

    boot_cell = cells.create(&objects, .kernel_boot, boot_cell_object) catch
        panic("core cell registry init failed");
    record(.cell_created, .ok, boot_cell_object, boot_cell, .invalid, .invalid);

    cells.grantCapability(&capabilities, boot_cell, framebuffer_read_capability) catch
        panic("boot cell capability grant failed");
    record(.capability_attached, .ok, framebuffer_object, boot_cell, framebuffer_read_capability, .invalid);

    cells.transition(boot_cell, .ready) catch panic("boot cell transition failed");
    record(.cell_transitioned, .ok, boot_cell_object, boot_cell, .invalid, .invalid);

    boot_inspect_route = createRoute(
        .inspect_object,
        boot_cell,
        framebuffer_read_capability,
        framebuffer_object,
        .invalid,
    ) catch panic("boot route create failed");

    scheduler_state.setCurrent(&cells, boot_cell) catch panic("boot scheduler current cell failed");
    record(.scheduler_current, .ok, boot_cell_object, boot_cell, .invalid, .invalid);
}

pub fn bootReport() BootReport {
    return .{
        .arch_name = archName(),
        .build_mode = build_options.build_mode,
        .git_commit = build_options.git_commit,
        .objects = objects.count,
        .capabilities = capabilities.count,
        .cells = cells.count,
        .routes = routes.count,
        .provenance = provenance_records.count,
    };
}

pub fn dumpBootReport() void {
    const report = bootReport();

    arch.writeEarlyDebug("__ZERNEL_BOOT_REPORT__ {\"version\":");
    klog.dec(report.version);
    arch.writeEarlyDebug(",\"arch\":\"");
    arch.writeEarlyDebug(report.arch_name);
    arch.writeEarlyDebug("\",\"build\":\"");
    arch.writeEarlyDebug(report.build_mode);
    arch.writeEarlyDebug("\",\"commit\":\"");
    arch.writeEarlyDebug(report.git_commit);
    arch.writeEarlyDebug("\",\"objects\":");
    klog.dec(report.objects);
    arch.writeEarlyDebug(",\"caps\":");
    klog.dec(report.capabilities);
    arch.writeEarlyDebug(",\"cells\":");
    klog.dec(report.cells);
    arch.writeEarlyDebug(",\"routes\":");
    klog.dec(report.routes);
    arch.writeEarlyDebug(",\"provenance\":");
    klog.dec(report.provenance);
    arch.writeEarlyDebug("}\n");
}

pub fn dumpObjects() void {
    klog.info("objects");

    var index: usize = 0;
    while (index < objects.count) : (index += 1) {
        const entry = objects.at(index) orelse continue;
        klog.labelDec("  id", @intFromEnum(entry.id));
        klog.labelDec("  kind", @intFromEnum(entry.kind));
        klog.labelDec("  generation", entry.generation);
        klog.info(entry.name);
    }
}

pub fn dumpCapabilities() void {
    klog.info("capabilities");

    var index: usize = 0;
    while (index < capabilities.count) : (index += 1) {
        const entry = capabilities.at(index) orelse continue;
        klog.labelDec("  id", @intFromEnum(entry.id));
        klog.labelDec("  target", @intFromEnum(entry.target));
        klog.labelDec("  generation", entry.generation);
        klog.labelDec("  revoked", boolToInt(entry.revoked));
        dumpRights(entry.rights);
    }
}

pub fn dumpCells() void {
    klog.info("cells");

    var index: usize = 0;
    while (index < cells.count) : (index += 1) {
        const entry = cells.at(index) orelse continue;
        klog.labelDec("  id", @intFromEnum(entry.id));
        klog.labelDec("  kind", @intFromEnum(entry.kind));
        klog.labelDec("  state", @intFromEnum(entry.state));
        klog.labelDec("  object", @intFromEnum(entry.object_id));
        klog.labelDec("  capabilities", entry.capability_count);
        klog.labelDec("  budget ticks", entry.budget_ticks);
        klog.labelDec("  memory pages", entry.memory_pages);
    }
}

pub fn dumpRoutes() void {
    klog.info("routes");

    var index: usize = 0;
    while (index < routes.count) : (index += 1) {
        const entry = routes.at(index) orelse continue;
        klog.labelDec("  id", @intFromEnum(entry.id));
        klog.labelDec("  kind", @intFromEnum(entry.kind));
        klog.labelDec("  status", @intFromEnum(entry.status));
        klog.labelDec("  source cell", @intFromEnum(entry.source_cell));
        klog.labelDec("  capability", @intFromEnum(entry.capability));
        klog.labelDec("  input object", @intFromEnum(entry.input_object));
        klog.labelDec("  output object", @intFromEnum(entry.output_object));
    }
}

pub fn dumpScheduler() void {
    const snapshot = scheduler_state.snapshot();

    klog.info("scheduler");
    klog.labelDec("  ticks", @intCast(snapshot.ticks));
    klog.labelDec("  current cell", @intFromEnum(snapshot.current_cell));
}

pub fn schedulerTick() scheduler.TickResult {
    const result = scheduler_state.tick(&cells);
    const snapshot = scheduler_state.snapshot();
    if (snapshot.current_cell != .invalid) {
        const entry = cells.get(snapshot.current_cell) orelse {
            record(.scheduler_tick, .failed, .invalid, .invalid, .invalid, .invalid);
            return result;
        };
        record(.scheduler_tick, .ok, entry.object_id, snapshot.current_cell, .invalid, .invalid);
    } else {
        record(.scheduler_tick, .ok, .invalid, .invalid, .invalid, .invalid);
    }
    return result;
}

pub fn dispatchNextRoute() dispatcher.DispatchError!dispatcher.DispatchResult {
    const result = try dispatcher_state.dispatchNext(&routes, &cells);
    switch (result.status) {
        .accepted => recordRouteTransition(result.route_id, .ok),
        .denied => recordRouteTransition(result.route_id, .denied),
        .idle, .deferred => {},
    }
    return result;
}

pub fn dumpProvenance() void {
    klog.info("provenance");

    var index: usize = 0;
    while (index < provenance_records.count) : (index += 1) {
        const entry = provenance_records.at(index) orelse continue;
        klog.labelDec("  seq", entry.sequence);
        klog.labelDec("  operation", @intFromEnum(entry.operation));
        klog.labelDec("  result", @intFromEnum(entry.result));
        klog.labelDec("  object", @intFromEnum(entry.object_id));
        klog.labelDec("  source cell", @intFromEnum(entry.source_cell));
        klog.labelDec("  capability", @intFromEnum(entry.capability_id));
        klog.labelDec("  route", @intFromEnum(entry.route_id));
    }
}

pub fn dumpProvenanceJsonLines() void {
    var index: usize = 0;
    while (index < provenance_records.count) : (index += 1) {
        const entry = provenance_records.at(index) orelse continue;
        arch.writeEarlyDebug("__ZERNEL_PROVENANCE__ {\"seq\":");
        klog.dec(@intCast(entry.sequence));
        arch.writeEarlyDebug(",\"op\":\"");
        arch.writeEarlyDebug(provenance.operationName(entry.operation));
        arch.writeEarlyDebug("\",\"result\":\"");
        arch.writeEarlyDebug(provenance.resultName(entry.result));
        arch.writeEarlyDebug("\",\"object\":");
        klog.dec(@intFromEnum(entry.object_id));
        arch.writeEarlyDebug(",\"cell\":");
        klog.dec(@intFromEnum(entry.source_cell));
        arch.writeEarlyDebug(",\"cap\":");
        klog.dec(@intFromEnum(entry.capability_id));
        arch.writeEarlyDebug(",\"route\":");
        klog.dec(@intFromEnum(entry.route_id));
        arch.writeEarlyDebug("}\n");
    }
}

pub fn objectRegistry() *const object.Registry {
    return &objects;
}

pub fn addressSpaceRegistry() *const address_space.Registry {
    return &address_spaces;
}

pub fn capabilityRegistry() *const capability.Registry {
    return &capabilities;
}

pub fn cellRegistry() *const cell.Registry {
    return &cells;
}

pub fn routeRegistry() *const route.Registry {
    return &routes;
}

pub fn provenanceRegistry() *const provenance.Registry {
    return &provenance_records;
}

pub fn schedulerSnapshot() scheduler.Snapshot {
    return scheduler_state.snapshot();
}

pub fn stackRegistry() *const stack.Registry {
    return &stacks;
}

pub fn framebufferObject() object.ObjectId {
    return framebuffer_object;
}

pub fn memoryMapObject() object.ObjectId {
    return memory_map_object;
}

pub fn bootCellObject() object.ObjectId {
    return boot_cell_object;
}

pub fn framebufferReadCapability() capability.CapabilityId {
    return framebuffer_read_capability;
}

pub fn memoryMapReadCapability() capability.CapabilityId {
    return memory_map_read_capability;
}

pub fn bootCell() cell.CellId {
    return boot_cell;
}

pub fn bootInspectRoute() route.RouteId {
    return boot_inspect_route;
}

pub fn revokeCapability(id: capability.CapabilityId) capability.RevokeError!void {
    const entry = capabilities.get(id) orelse return error.InvalidCapability;
    const target = entry.target;
    try capabilities.revoke(id);
    record(.capability_revoked, .ok, target, .invalid, id, .invalid);
}

pub fn delegateCapability(
    source_cell: cell.CellId,
    target_cell: cell.CellId,
    source_cap: capability.CapabilityId,
    rights: capability.CapabilityRights,
) cell.DelegateError!capability.CapabilityId {
    const child = try cells.delegateCapability(
        &capabilities,
        source_cell,
        target_cell,
        source_cap,
        rights,
    );
    const child_entry = capabilities.getActive(child) orelse return error.InvalidCapability;
    record(.capability_delegated, .ok, child_entry.target, source_cell, child, .invalid);
    return child;
}

pub fn createRoute(
    kind: route.RouteKind,
    source_cell: cell.CellId,
    cap: capability.CapabilityId,
    input_object: object.ObjectId,
    output_object: object.ObjectId,
) route.CreateError!route.RouteId {
    const id = routes.create(
        &cells,
        &capabilities,
        &objects,
        kind,
        source_cell,
        cap,
        input_object,
        output_object,
    ) catch |err| {
        recordRouteDenial(source_cell, cap, input_object);
        return err;
    };

    record(.route_created, .ok, input_object, source_cell, cap, id);
    return id;
}

pub fn transitionRoute(id: route.RouteId, next: route.RouteStatus) route.TransitionError!void {
    try routes.transition(id, next);
    recordRouteTransition(id, .ok);
}

pub const CellMemoryError = error{
    InvalidCell,
    OutOfMemory,
    InvalidPageOwner,
    PmmNotInitialized,
    UnalignedAddress,
    EmptyRange,
    OutOfRange,
    DoubleFree,
    Overflow,
    OwnerMismatch,
    Underflow,
};

pub const CellMappingError = error{
    InvalidCell,
    UnalignedAddress,
    MissingOwner,
    PageNotOwnedByCell,
    WritableExecutable,
};

pub const CellStackError = error{
    InvalidCell,
    InvalidPageCount,
    RegistryFull,
    OutOfMemory,
    InvalidPageOwner,
    PmmNotInitialized,
    UnalignedAddress,
    EmptyRange,
    OutOfRange,
    DoubleFree,
    Overflow,
    OwnerMismatch,
    Underflow,
    InvalidStack,
    StackOwnerMismatch,
    InvalidAddressSpace,
    StackAlreadyAttached,
    StackListFull,
    StackMapped,
    AddressOutsideLayout,
    GuardPage,
    GuardPageMapped,
    MissingOwner,
    PageNotOwnedByCell,
    WritableExecutable,
    Unsupported,
};

pub fn allocateCellPage(id: cell.CellId) CellMemoryError!usize {
    const entry = cells.get(id) orelse return error.InvalidCell;
    const phys = pmm.allocPageOwned(pmm.PageOwner.cell(@intFromEnum(id))) orelse return error.OutOfMemory;
    cells.chargeMemoryPages(id, 1) catch |err| {
        pmm.freePage(phys);
        return switch (err) {
            error.InvalidCell => error.InvalidCell,
            error.Underflow => error.Underflow,
        };
    };
    record(.cell_memory_allocated, .ok, entry.object_id, id, .invalid, .invalid);
    return phys;
}

pub fn freeCellPage(id: cell.CellId, phys: usize) CellMemoryError!void {
    if (cells.get(id) == null) return error.InvalidCell;
    if (!page.isAligned(phys)) return error.UnalignedAddress;
    try pmm.freePagesOwned(phys, page.size, pmm.PageOwner.cell(@intFromEnum(id)));
    try cells.releaseMemoryPages(id, 1);
    const entry = cells.get(id) orelse return error.InvalidCell;
    record(.cell_memory_freed, .ok, entry.object_id, id, .invalid, .invalid);
}

pub fn validateCellPageMapping(
    id: cell.CellId,
    phys: usize,
    permissions: mapping.Permissions,
) CellMappingError!void {
    const entry = cells.get(id) orelse return error.InvalidCell;
    if (!page.isAligned(phys)) return error.UnalignedAddress;
    const owner = pmm.pageOwner(phys) orelse return error.MissingOwner;
    try mapping.validateCellPageMapping(@intFromEnum(id), owner, permissions);
    record(.cell_mapping_validated, .ok, entry.object_id, id, .invalid, .invalid);
}

pub fn allocateCellStack(id: cell.CellId, page_count: usize) CellStackError!stack.StackId {
    const cell_entry = cells.get(id) orelse return error.InvalidCell;
    const before_count = address_spaces.count;
    _ = try address_spaces.ensureForCell(id);
    if (address_spaces.count != before_count) {
        record(.cell_address_space_created, .ok, cell_entry.object_id, id, .invalid, .invalid);
    }

    const entry = try stacks.reserve(id, page_count);

    var allocated: usize = 0;
    errdefer rollbackCellStackAllocation(id, entry.id, allocated);

    while (allocated < page_count) : (allocated += 1) {
        entry.pages[allocated] = try allocateCellPage(id);
    }

    record(.cell_stack_allocated, .ok, cell_entry.object_id, id, .invalid, .invalid);
    return entry.id;
}

pub fn mapCellStack(info: *const BootInfo, id: cell.CellId, stack_id: stack.StackId) CellStackError!void {
    const cell_entry = cells.get(id) orelse return error.InvalidCell;
    const stack_entry = stacks.get(stack_id) orelse return error.InvalidStack;
    if (stack_entry.owner != id) return error.StackOwnerMismatch;

    const attached = address_spaces.getStackMapping(id, stack_id) orelse
        try address_spaces.attachStack(id, stack_entry);
    if (attached.mapped) return;

    try arch.paging.mapStackPages(
        info,
        attached.layout,
        @intFromEnum(id),
        stack_entry.pages[0..stack_entry.page_count],
        .{ .read = true, .write = true, .user = true },
    );

    try address_spaces.markStackMapped(id, stack_id);
    record(.cell_stack_mapped, .ok, cell_entry.object_id, id, .invalid, .invalid);
}

pub fn freeCellStack(id: cell.CellId, stack_id: stack.StackId) CellStackError!void {
    const cell_entry = cells.get(id) orelse return error.InvalidCell;
    const entry = stacks.get(stack_id) orelse return error.InvalidStack;
    if (entry.owner != id) return error.StackOwnerMismatch;
    if (address_spaces.getStackMapping(id, stack_id)) |attached| {
        if (attached.mapped) return error.StackMapped;
        try address_spaces.detachStack(id, stack_id);
    }

    const page_count = entry.page_count;
    var pages: [stack.max_stack_pages]usize = [_]usize{0} ** stack.max_stack_pages;
    var index: usize = 0;
    while (index < page_count) : (index += 1) {
        pages[index] = entry.pages[index];
    }

    index = 0;
    while (index < page_count) : (index += 1) {
        try freeCellPage(id, pages[index]);
    }

    try stacks.release(stack_id, id);
    record(.cell_stack_freed, .ok, cell_entry.object_id, id, .invalid, .invalid);
}

fn recordRouteTransition(id: route.RouteId, result: provenance.Result) void {
    const entry = routes.get(id) orelse return;
    record(.route_transitioned, result, entry.input_object, entry.source_cell, entry.capability, id);
}

fn rollbackCellStackAllocation(id: cell.CellId, stack_id: stack.StackId, allocated: usize) void {
    const entry = stacks.get(stack_id) orelse return;

    var index: usize = 0;
    while (index < allocated) : (index += 1) {
        freeCellPage(id, entry.pages[index]) catch {};
    }

    stacks.release(stack_id, id) catch {};
}

fn createObject(kind: object.ObjectKind, name: []const u8) object.ObjectId {
    const id = objects.create(kind, name) catch panic("core object registry full");
    record(.object_created, .ok, id, .invalid, .invalid, .invalid);
    return id;
}

fn grantCapability(
    target: object.ObjectId,
    rights: capability.CapabilityRights,
) capability.CapabilityId {
    const id = capabilities.grant(&objects, target, rights) catch panic("core capability grant failed");
    record(.capability_granted, .ok, target, .invalid, id, .invalid);
    return id;
}

fn record(
    operation: provenance.Operation,
    result: provenance.Result,
    object_id: object.ObjectId,
    source_cell: cell.CellId,
    capability_id: capability.CapabilityId,
    route_id: route.RouteId,
) void {
    provenance_records.record(
        operation,
        result,
        object_id,
        source_cell,
        capability_id,
        route_id,
    ) catch panic("core provenance registry full");
}

fn recordRouteDenial(
    source_cell: cell.CellId,
    cap: capability.CapabilityId,
    input_object: object.ObjectId,
) void {
    if (cells.get(source_cell) == null) return;
    if (capabilities.get(cap) == null) return;

    record(.route_denied, .denied, input_object, source_cell, cap, .invalid);
}

fn dumpRights(rights: capability.CapabilityRights) void {
    klog.labelDec("  read", boolToInt(rights.read));
    klog.labelDec("  write", boolToInt(rights.write));
    klog.labelDec("  execute", boolToInt(rights.execute));
    klog.labelDec("  delegate", boolToInt(rights.delegate));
}

fn boolToInt(value: bool) usize {
    return if (value) 1 else 0;
}

fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "unknown",
    };
}
