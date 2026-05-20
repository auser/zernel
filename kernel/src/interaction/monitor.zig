const arch = @import("../arch.zig");
const klog = @import("../utils/klog.zig");
const boot_info = @import("../boot/info.zig");
const core = @import("../core/system.zig");
const command = @import("command.zig");
const input = @import("input.zig");
const line = @import("line.zig");

const BootInfo = boot_info.BootInfo;

pub fn run(info: *const BootInfo) noreturn {
    var reader = line.Reader.init(readEarlyDebug, readKeyboardKey, writeDebug);

    klog.info("monitor ready");
    while (true) {
        arch.writeEarlyDebug("> ");
        const input_line = reader.read();
        dispatch(info, input_line);
    }
}

fn readEarlyDebug() ?u8 {
    return arch.readEarlyDebug();
}

fn readKeyboardKey() ?input.Key {
    const key = arch.readKeyboardKey() orelse return null;
    return .{
        .code = key.code,
        .pressed = key.pressed,
    };
}

fn writeDebug(bytes: []const u8) void {
    arch.writeEarlyDebug(bytes);
}

fn dispatch(info: *const BootInfo, input_line: []const u8) void {
    if (command.equals(input_line, "help")) {
        klog.info("commands: help boot mem fb objects caps cells routes dispatch scheduler tick provenance provenance-json clear halt");
    } else if (command.equals(input_line, "boot")) {
        boot_info.logAddressInfo(info);
    } else if (command.equals(input_line, "mem")) {
        boot_info.logMemoryMap(info);
    } else if (command.equals(input_line, "fb")) {
        boot_info.logFramebuffer(info);
    } else if (command.equals(input_line, "objects")) {
        core.dumpObjects();
    } else if (command.equals(input_line, "caps")) {
        core.dumpCapabilities();
    } else if (command.equals(input_line, "cells")) {
        core.dumpCells();
    } else if (command.equals(input_line, "routes")) {
        core.dumpRoutes();
    } else if (command.equals(input_line, "dispatch")) {
        _ = core.dispatchNextRoute() catch {
            klog.warn("dispatch failed");
        };
        core.dumpRoutes();
    } else if (command.equals(input_line, "scheduler")) {
        core.dumpScheduler();
    } else if (command.equals(input_line, "tick")) {
        _ = core.schedulerTick();
        core.dumpScheduler();
    } else if (command.equals(input_line, "provenance")) {
        core.dumpProvenance();
    } else if (command.equals(input_line, "provenance-json")) {
        core.dumpProvenanceJsonLines();
    } else if (command.equals(input_line, "clear")) {
        // Optional once framebuffer console exposes clear().
    } else if (command.equals(input_line, "halt")) {
        arch.halt();
    } else if (input_line.len != 0) {
        klog.warn("unknown command");
    }
}
