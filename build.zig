const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Create and expose our public module
    const mod = b.addModule("marketdata_ws_client", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Get the websocket dependency (must be listed in build.zig.zon)
    const websocket = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    // 3. Make websocket available inside our module as @import("websocket")
    mod.addImport("websocket", websocket.module("websocket"));
}
