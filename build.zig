const std = @import("std");

pub fn build(b: *std.Build) void {
    const arch_name = b.option([]const u8, "arch", "Kernel architecture: x86_64 or aarch64") orelse "x86_64";

    const cpu_arch: std.Target.Cpu.Arch = if (std.mem.eql(u8, arch_name, "x86_64"))
        .x86_64
    else if (std.mem.eql(u8, arch_name, "aarch64"))
        .aarch64
    else
        @panic("unsupported -Darch value");

    var target_query: std.Target.Query = .{
        .cpu_arch = cpu_arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

    if (cpu_arch == .x86_64) {
        const Feature = std.Target.x86.Feature;
        target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.x87));
        target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
        target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
        target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
        target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
        target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
        target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));
    }

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("kernel/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = if (cpu_arch == .x86_64) .kernel else .large,
        .pic = false,
        .omit_frame_pointer = false,
        .red_zone = false,
        .stack_check = false,
        .link_libc = false,
        .link_libcpp = false,
    });

    const limine = b.dependency("limine", .{});
    kernel_module.addImport("limine", limine.module("limine"));

    const linker_script = if (cpu_arch == .x86_64)
        b.path("kernel/linker-x86_64.ld")
    else
        b.path("kernel/linker-aarch64.ld");

    const kernel = b.addExecutable(.{
        .name = b.fmt("kernel-{s}", .{arch_name}),
        .root_module = kernel_module,
        .linkage = .static,
    });

    kernel.setLinkerScript(linker_script);
    kernel.lto = .none;
    kernel.link_function_sections = true;
    kernel.link_data_sections = true;
    kernel.link_gc_sections = true;
    kernel.link_z_max_page_size = 0x1000;

    b.installArtifact(kernel);
}
