const BuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    macos_sdk: ?[]const u8,
    link_mode: std.builtin.LinkMode,
};

pub fn build(b: *std.Build) !void {
    const options = parseBuildOptions(b);
    const lib = library(b, options);
    b.installArtifact(lib);

    addExampleSteps(b, options, lib);
    addTestSteps(b, options, lib);
    addQaSteps(b, options, lib);
    addUnitSteps(b, options, lib);
}

fn parseBuildOptions(b: *std.Build) BuildOptions {
    return .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .macos_sdk = b.option([]const u8, "macos-sdk", "Path to macOS SDK (optional), used on non-macOS platforms"),
        .link_mode = b.option(std.builtin.LinkMode, "libtype", "Build libui as a statically or dynamically linked library, default is static") orelse .static,
    };
}

fn library(b: *std.Build, options: BuildOptions) *std.Build.Step.Compile {
    const mod = b.addModule("ui", .{
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });

    mod.addIncludePath(b.path("common"));
    mod.addCMacro("libui_EXPORTS", "");
    mod.addCSourceFiles(.{
        .files = &libui_common_sources,
        .flags = &.{},
    });

    const lib = b.addLibrary(.{
        .name = "ui",
        .root_module = mod,
        .linkage = options.link_mode,
    });

    switch (options.target.result.os.tag) {
        .macos => {
            tryApplyMacOsSdk(b, mod, options);

            mod.addCSourceFiles(.{
                .files = &libui_darwin_sources,
                .flags = &.{},
            });
            mod.addIncludePath(b.path("darwin"));
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("AppKit", .{});

            lib.installHeader(b.path("ui_darwin.h"), "ui_darwin.h");
        },
        .windows => {
            mod.addCSourceFiles(.{
                .files = &libui_windows_sources,
                .flags = &.{
                    "-Wno-unused-parameter",
                    "-Wno-switch",
                    "-Wno-macro-redefined",
                },
            });
            mod.link_libcpp = true;
            mod.addIncludePath(b.path("windows"));
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("kernel32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("comctl32", .{});
            mod.linkSystemLibrary("uxtheme", .{});
            mod.linkSystemLibrary("msimg32", .{});
            mod.linkSystemLibrary("comdlg32", .{});
            mod.linkSystemLibrary("d2d1", .{});
            mod.linkSystemLibrary("dwrite", .{});
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("oleaut32", .{});
            mod.linkSystemLibrary("oleacc", .{});
            mod.linkSystemLibrary("uuid", .{});
            mod.linkSystemLibrary("windowscodecs", .{});

            lib.installHeader(b.path("ui_windows.h"), "ui_windows.h");
        },
        .linux => {
            lib.installHeader(b.path("ui_unix.h"), "ui_unix.h");

            mod.addCSourceFiles(.{
                .files = &libui_unix_sources,
                .flags = &.{},
            });
            mod.addIncludePath(b.path("unix"));
            mod.linkSystemLibrary("gtk+-3.0", .{});
        },
        else => unreachable,
    }

    lib.installHeader(b.path("ui.h"), "ui.h");
    return lib;
}

fn addExampleSteps(b: *std.Build, options: BuildOptions, lib: *std.Build.Step.Compile) void {
    const step = b.step("examples", "Build all libui example applications");
    const examples = [_][]const u8{
        "controlgallery",
        "datetime",
        "drawtext",
        "hello-world",
        "histogram",
        "timer",
        "window",
        "cpp-multithread",
    };
    inline for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .target = options.target,
                .optimize = options.optimize,
            }),
        });
        if (std.mem.eql(u8, name, "cpp-multithread")) {
            exe.root_module.addCSourceFile(.{
                .file = b.path("examples/cpp-multithread/main.cpp"),
                .flags = &.{},
            });
            exe.root_module.link_libcpp = true;
        } else {
            exe.root_module.addCSourceFile(.{
                .file = b.path("examples/" ++ name ++ "/main.c"),
                .flags = &.{},
            });
        }
        exe.root_module.linkLibrary(lib);
        tryApplyMacOsSdk(b, exe.root_module, options);
        if (options.target.result.os.tag == .windows) {
            exe.root_module.addWin32ResourceFile(.{
                .file = b.path("examples/resources.rc"),
                .flags = if (options.link_mode == .dynamic) &.{} else &.{ "/d", "_UI_STATIC" },
            });
            exe.subsystem = .Windows;
        }

        const build_step = b.step("example-" ++ name, "Build '" ++ name ++ "' example application");
        build_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        const run_step = b.step("run-example-" ++ name, "Build and run '" ++ name ++ "' example");
        run_step.dependOn(&b.addRunArtifact(exe).step);

        step.dependOn(build_step);
    }
}

fn addTestSteps(b: *std.Build, options: BuildOptions, lib: *std.Build.Step.Compile) void {
    const test_dir: std.Build.InstallDir = .{ .custom = "test" };

    const exe = b.addExecutable(.{
        .name = "test",
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
        }),
        .win32_manifest = b.path(if (options.link_mode == .dynamic) "test/test.manifest" else "test/test.static.manifest"),
    });
    exe.root_module.addCSourceFiles(.{
        .files = &libui_test_sources,
        .flags = &.{},
    });
    exe.root_module.linkLibrary(lib);
    tryApplyMacOsSdk(b, exe.root_module, options);

    const tester = b.step("test", "Build the main test suite executable");
    tester.dependOn(
        &b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = test_dir },
        }).step,
    );

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run-test", "Build and run the main test suite");
    run_step.dependOn(&run.step);
}

fn addQaSteps(b: *std.Build, options: BuildOptions, lib: *std.Build.Step.Compile) void {
    const test_dir: std.Build.InstallDir = .{ .custom = "test" };

    const exe = b.addExecutable(.{
        .name = "qa",
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
        }),
        .win32_manifest = b.path(if (options.link_mode == .dynamic) "test/qa/qa.manifest" else "test/qa/qa.static.manifest"),
    });
    exe.root_module.addCSourceFiles(.{
        .files = &libui_qa_sources,
        .flags = &.{},
    });
    exe.root_module.addIncludePath(b.path("test/qa/"));
    exe.root_module.linkLibrary(lib);
    tryApplyMacOsSdk(b, exe.root_module, options);

    const build_step = b.step("qa", "Build the QA test executable");
    build_step.dependOn(
        &b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = test_dir },
        }).step,
    );

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run-qa", "Build and run the QA test suite");
    run_step.dependOn(&run.step);
}

fn addUnitSteps(b: *std.Build, options: BuildOptions, lib: *std.Build.Step.Compile) void {
    const test_dir: std.Build.InstallDir = .{ .custom = "test" };

    const exe = b.addExecutable(.{
        .name = "unit",
        .root_module = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
        }),
        .win32_manifest = b.path(if (options.link_mode == .dynamic) "test/unit/unit.manifest" else "test/unit/unit.static.manifest"),
    });
    exe.root_module.addCSourceFiles(.{
        .files = &libui_unit_sources,
        .flags = &.{},
    });
    exe.root_module.addIncludePath(b.path("test/unit/"));
    exe.root_module.linkLibrary(lib);
    exe.root_module.linkSystemLibrary("cmocka", .{});
    tryApplyMacOsSdk(b, exe.root_module, options);

    const build_step = b.step("unit", "Build the unit test executable (requires cmocka)");
    build_step.dependOn(
        &b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = test_dir },
        }).step,
    );

    const run = b.addRunArtifact(exe);
    const run_step = b.step("run-unit", "Build and run unit tests (requires cmocka)");
    run_step.dependOn(&run.step);
}

fn tryApplyMacOsSdk(b: *std.Build, mod: *std.Build.Module, options: BuildOptions) void {
    if (builtin.os.tag != .macos and options.macos_sdk != null) {
        const macos_sdk_path: std.Build.LazyPath = .{ .cwd_relative = options.macos_sdk.? };
        mod.addSystemIncludePath(macos_sdk_path.path(b, "usr/include"));
        mod.addLibraryPath(macos_sdk_path.path(b, "usr/lib"));
        mod.addSystemFrameworkPath(macos_sdk_path.path(b, "System/Library/Frameworks"));
    }
}

const libui_common_sources = [_][]const u8{
    "common/areaevents.c",
    "common/attribute.c",
    "common/attrlist.c",
    "common/attrstr.c",
    "common/control.c",
    "common/debug.c",
    "common/matrix.c",
    "common/opentype.c",
    "common/shouldquit.c",
    "common/table.c",
    "common/tablemodel.c",
    "common/tablevalue.c",
    "common/userbugs.c",
    "common/utf.c",
};

const libui_darwin_sources = [_][]const u8{
    "darwin/aat.m",
    "darwin/alloc.m",
    "darwin/areaevents.m",
    "darwin/area.m",
    "darwin/attrstr.m",
    "darwin/autolayout.m",
    "darwin/box.m",
    "darwin/button.m",
    "darwin/checkbox.m",
    "darwin/colorbutton.m",
    "darwin/combobox.m",
    "darwin/control.m",
    "darwin/datetimepicker.m",
    "darwin/debug.m",
    "darwin/draw.m",
    "darwin/drawtext.m",
    "darwin/editablecombo.m",
    "darwin/entry.m",
    "darwin/event.m",
    "darwin/fontbutton.m",
    "darwin/fontmatch.m",
    "darwin/fonttraits.m",
    "darwin/fontvariation.m",
    "darwin/form.m",
    "darwin/future.m",
    "darwin/graphemes.m",
    "darwin/grid.m",
    "darwin/group.m",
    "darwin/image.m",
    "darwin/label.m",
    "darwin/main.m",
    "darwin/menu.m",
    "darwin/multilineentry.m",
    "darwin/nstextfield.m",
    "darwin/opentype.m",
    "darwin/progressbar.m",
    "darwin/radiobuttons.m",
    "darwin/scrollview.m",
    "darwin/separator.m",
    "darwin/slider.m",
    "darwin/spinbox.m",
    "darwin/stddialogs.m",
    "darwin/tablecolumn.m",
    "darwin/table.m",
    "darwin/tab.m",
    "darwin/text.m",
    "darwin/undocumented.m",
    "darwin/util.m",
    "darwin/window.m",
    "darwin/winmoveresize.m",
};

const libui_windows_sources = [_][]const u8{
    "windows/alloc.cpp",
    "windows/area.cpp",
    "windows/areadraw.cpp",
    "windows/areaevents.cpp",
    "windows/areascroll.cpp",
    "windows/areautil.cpp",
    "windows/attrstr.cpp",
    "windows/box.cpp",
    "windows/button.cpp",
    "windows/checkbox.cpp",
    "windows/colorbutton.cpp",
    "windows/colordialog.cpp",
    "windows/combobox.cpp",
    "windows/container.cpp",
    "windows/control.cpp",
    "windows/d2dscratch.cpp",
    "windows/datetimepicker.cpp",
    "windows/debug.cpp",
    "windows/draw.cpp",
    "windows/drawmatrix.cpp",
    "windows/drawpath.cpp",
    "windows/drawtext.cpp",
    "windows/dwrite.cpp",
    "windows/editablecombo.cpp",
    "windows/entry.cpp",
    "windows/events.cpp",
    "windows/fontbutton.cpp",
    "windows/fontdialog.cpp",
    "windows/fontmatch.cpp",
    "windows/form.cpp",
    "windows/graphemes.cpp",
    "windows/grid.cpp",
    "windows/group.cpp",
    "windows/image.cpp",
    "windows/init.cpp",
    "windows/label.cpp",
    "windows/main.cpp",
    "windows/menu.cpp",
    "windows/multilineentry.cpp",
    "windows/opentype.cpp",
    "windows/parent.cpp",
    "windows/progressbar.cpp",
    "windows/radiobuttons.cpp",
    "windows/separator.cpp",
    "windows/sizing.cpp",
    "windows/slider.cpp",
    "windows/spinbox.cpp",
    "windows/stddialogs.cpp",
    "windows/tab.cpp",
    "windows/table.cpp",
    "windows/tabledispinfo.cpp",
    "windows/tabledraw.cpp",
    "windows/tableediting.cpp",
    "windows/tablemetrics.cpp",
    "windows/tabpage.cpp",
    "windows/text.cpp",
    "windows/utf16.cpp",
    "windows/utilwin.cpp",
    "windows/window.cpp",
    "windows/winpublic.cpp",
    "windows/winutil.cpp",
};

const libui_unix_sources = [_][]const u8{
    "unix/alloc.c",
    "unix/area.c",
    "unix/attrstr.c",
    "unix/box.c",
    "unix/button.c",
    "unix/cellrendererbutton.c",
    "unix/checkbox.c",
    "unix/child.c",
    "unix/colorbutton.c",
    "unix/combobox.c",
    "unix/control.c",
    "unix/datetimepicker.c",
    "unix/debug.c",
    "unix/draw.c",
    "unix/drawmatrix.c",
    "unix/drawpath.c",
    "unix/drawtext.c",
    "unix/editablecombo.c",
    "unix/entry.c",
    "unix/fontbutton.c",
    "unix/fontmatch.c",
    "unix/form.c",
    "unix/future.c",
    "unix/graphemes.c",
    "unix/grid.c",
    "unix/group.c",
    "unix/image.c",
    "unix/label.c",
    "unix/main.c",
    "unix/menu.c",
    "unix/multilineentry.c",
    "unix/opentype.c",
    "unix/progressbar.c",
    "unix/radiobuttons.c",
    "unix/separator.c",
    "unix/slider.c",
    "unix/spinbox.c",
    "unix/stddialogs.c",
    "unix/tab.c",
    "unix/table.c",
    "unix/tablemodel.c",
    "unix/text.c",
    "unix/util.c",
    "unix/window.c",
};

const libui_test_sources = [_][]const u8{
    "test/drawtests.c",
    "test/images.c",
    "test/main.c",
    "test/menus.c",
    "test/page1.c",
    "test/page2.c",
    "test/page3.c",
    "test/page4.c",
    "test/page5.c",
    "test/page6.c",
    "test/page7.c",
    "test/page7a.c",
    "test/page7b.c",
    "test/page7c.c",
    // "test/page8.c",
    // "test/page9.c",
    // "test/page10.c",
    "test/page11.c",
    "test/page12.c",
    "test/page13.c",
    "test/page14.c",
    "test/page15.c",
    "test/page16.c",
    "test/page17.c",
    "test/spaced.c",
};

const libui_unit_sources = [_][]const u8{
    "test/unit/button.c",
    "test/unit/checkbox.c",
    "test/unit/combobox.c",
    "test/unit/drawmatrix.c",
    "test/unit/entry.c",
    "test/unit/init.c",
    "test/unit/label.c",
    "test/unit/main.c",
    "test/unit/menu.c",
    "test/unit/progressbar.c",
    "test/unit/radiobuttons.c",
    "test/unit/slider.c",
    "test/unit/spinbox.c",
    "test/unit/window.c",
};

const libui_qa_sources = [_][]const u8{
    "test/qa/button.c",
    "test/qa/checkbox.c",
    "test/qa/entry.c",
    "test/qa/label.c",
    "test/qa/main.c",
    "test/qa/qa.c",
    "test/qa/radiobuttons.c",
    "test/qa/separator.c",
    "test/qa/spinbox.c",
    "test/qa/window.c",
};

const std = @import("std");
const builtin = @import("builtin");
