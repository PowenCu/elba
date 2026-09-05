const std = @import("std");

/// Locate the LLVM installation without hard-coded machine paths.
///
/// Resolution order:
/// 1. `LLVM_INCLUDE_DIR` / `LLVM_LIB_DIR` environment variables (explicit override)
/// 2. Well-known per-platform locations (MSYS2, Homebrew, system packages)
///
/// The library name varies by platform and packaging: Windows DLL import
/// libraries are versioned (`libLLVM-22`), while Linux/macOS linkers resolve
/// the unversioned `-lLLVM-22` or `-lLLVM` form.
fn configureLLVM(b: *std.Build, exe_mod: *std.Build.Module) void {
    const env_map = std.process.getEnvMap(b.allocator) catch |err| {
        std.debug.print("warning: could not read environment ({s}); falling back to defaults\n", .{@errorName(err)});
        return defaultLLVMLocation(b, exe_mod);
    };
    defer env_map.deinit(b.allocator);

    const include_dir = env_map.get("LLVM_INCLUDE_DIR");
    const lib_dir = env_map.get("LLVM_LIB_DIR");

    if (include_dir != null or lib_dir != null) {
        if (include_dir) |dir| {
            exe_mod.addSystemIncludePath(.{ .cwd_relative = dir });
        }
        if (lib_dir) |dir| {
            exe_mod.addLibraryPath(.{ .cwd_relative = dir });
        }
        exe_mod.link_libc = true;
        exe_mod.linkSystemLibrary(llvmLibName(), .{});
        return;
    }

    defaultLLVMLocation(b, exe_mod);
}

/// Try each well-known LLVM location until one exists on disk.
fn defaultLLVMLocation(b: *std.Build, exe_mod: *std.Build.Module) void {
    const candidates = llvmSearchPaths(b);

    for (candidates) |candidate| {
        var dir = std.fs.openDirAbsolute(candidate.prefix, .{}) catch continue;
        dir.close();

        if (candidate.include_sub) |sub| {
            var inc = dir.openDir(sub, .{}) catch continue;
            inc.close();
            exe_mod.addSystemIncludePath(.{
                .src_path = .{ .owner = b, .sub_path = candidate.include_rel },
            });
        }
        exe_mod.addLibraryPath(.{
            .src_path = .{ .owner = b, .sub_path = candidate.lib_rel },
        });
        exe_mod.link_libc = true;
        exe_mod.linkSystemLibrary(candidate.lib_name, .{});
        return;
    }

    // No known location found; still emit the link directive so the error
    // message comes from the linker rather than silently skipping the backend.
    std.debug.print(
        \\warning: LLVM was not found in any well-known location.
        \\  Set LLVM_INCLUDE_DIR and LLVM_LIB_DIR to your LLVM 22 install, e.g.:
        \\    PowerShell: $env:LLVM_INCLUDE_DIR="C:\msys64\ucrt64\include"; $env:LLVM_LIB_DIR="C:\msys64\ucrt64\bin"
        \\    POSIX:      export LLVM_INCLUDE_DIR=/usr/lib/llvm-22/include LLVM_LIB_DIR=/usr/lib/llvm-22/lib
        \\
    , .{});
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary(llvmLibName(), .{});
}

const SearchCandidate = struct {
    prefix: []const u8,
    include_sub: ?[]const u8,
    /// Path fragments relative to this file for Zig's src_path resolution.
    include_rel: []const u8,
    lib_rel: []const u8,
    lib_name: []const u8,
};

fn llvmSearchPaths(b: *std.Build) []const SearchCandidate {
    _ = b;
    return switch (@import("builtin").os.tag) {
        .windows => &[_]SearchCandidate{
            .{ .prefix = "C:\\msys64\\ucrt64", .include_sub = "include", .include_rel = "C:/msys64/ucrt64/include", .lib_rel = "C:/msys64/ucrt64/bin", .lib_name = "libLLVM-22" },
            .{ .prefix = "D:\\ThirdPartyTools\\msys64\\ucrt64", .include_sub = "include", .include_rel = "D:/ThirdPartyTools/msys64/ucrt64/include", .lib_rel = "D:/ThirdPartyTools/msys64/ucrt64/bin", .lib_name = "libLLVM-22" },
            .{ .prefix = "C:\\Program Files\\LLVM", .include_sub = "include", .include_rel = "C:/Program Files/LLVM/include", .lib_rel = "C:/Program Files/LLVM/lib", .lib_name = "libLLVM" },
        },
        .macos => &[_]SearchCandidate{
            .{ .prefix = "/opt/homebrew/opt/llvm", .include_sub = "include", .include_rel = "/opt/homebrew/opt/llvm/include", .lib_rel = "/opt/homebrew/opt/llvm/lib", .lib_name = "LLVM" },
            .{ .prefix = "/usr/local/opt/llvm", .include_sub = "include", .include_rel = "/usr/local/opt/llvm/include", .lib_rel = "/usr/local/opt/llvm/lib", .lib_name = "LLVM" },
        },
        else => &[_]SearchCandidate{
            .{ .prefix = "/usr/lib/llvm-22", .include_sub = "include", .include_rel = "/usr/lib/llvm-22/include", .lib_rel = "/usr/lib/llvm-22/lib", .lib_name = "LLVM-22" },
            .{ .prefix = "/usr/lib/llvm", .include_sub = "include", .include_rel = "/usr/lib/llvm/include", .lib_rel = "/usr/lib/llvm/lib", .lib_name = "LLVM" },
            .{ .prefix = "/usr", .include_sub = "include", .include_rel = "/usr/include", .lib_rel = "/usr/lib", .lib_name = "LLVM" },
        },
    };
}

fn llvmLibName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => "libLLVM-22",
        else => "LLVM-22",
    };
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    // const lib_mod = b.createModule(.{
    //     // `root_source_file` is the Zig "entry point" of the module. If a module
    //     // only contains e.g. external object files, you can make this `null`.
    //     // In this case the main source file is merely a path, however, in more
    //     // complicated build scripts, this could be a generated file.
    //     .root_source_file = b.path("src/root.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This configures the module to link against the LLVM libraries.
    exe_mod.addSystemIncludePath(.{ .src_path = .{ .owner = b, .sub_path = "D:/ThirdPartyTools/msys64/ucrt64/include" } });
    exe_mod.addLibraryPath(.{ .src_path = .{ .owner = b, .sub_path = "D:/ThirdPartyTools/msys64/ucrt64/bin" } });
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("libLLVM-22", .{});

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    // exe_mod.addImport("elba_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // // for actually invoking the compiler.
    // const lib = b.addLibrary(.{
    //     .linkage = .static,
    //     .name = "elba",
    //     .root_module = lib_mod,
    // });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    // b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "elba",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    // const lib_unit_tests = b.addTest(.{
    //     .root_module = lib_mod,
    // });

    // const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const frontend_test_mod = b.createModule(.{
        .root_source_file = b.path("src/frontend_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const frontend_unit_tests = b.addTest(.{
        .root_module = frontend_test_mod,
    });
    const run_frontend_unit_tests = b.addRunArtifact(frontend_unit_tests);
    const frontend_test_step = b.step("test-frontend", "Run frontend unit tests");
    frontend_test_step.dependOn(&run_frontend_unit_tests.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_frontend_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
