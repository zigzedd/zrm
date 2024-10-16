const std = @import("std");

pub fn build(b: *std.Build) void {
	// Standard target options allows the person running `zig build` to choose
	// what target to build for. Here we do not override the defaults, which
	// means any target is allowed, and the default is native. Other options
	// for restricting supported target set are available.
	const target = b.standardTargetOptions(.{});

	// Standard optimization options allow the person running `zig build` to select
	// between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
	// set a preferred release mode, allowing the user to decide how to optimize.
	const optimize = b.standardOptimizeOption(.{});

	// Add zollections dependency.
	const zollections = b.dependency("zollections", .{
		.target = target,
		.optimize = optimize,
	});
	// Add pg.zig dependency.
	const pg = b.dependency("pg", .{
		.target = target,
		.optimize = optimize,
	});

	const lib = b.addSharedLibrary(.{
		.name = "zrm",
		.root_source_file = b.path("src/root.zig"),
		.target = target,
		.optimize = optimize,
	});

	// This declares intent for the library to be installed into the standard
	// location when the user invokes the "install" step (the default step when
	// running `zig build`).
	b.installArtifact(lib);

	// Add zrm module.
	const zrm_module = b.addModule("zrm", .{
		.root_source_file = b.path("src/root.zig"),
		.target = target,
		.optimize = optimize,
	});

	// Add dependencies.
	lib.root_module.addImport("zollections", zollections.module("zollections"));
	zrm_module.addImport("zollections", zollections.module("zollections"));
	lib.root_module.addImport("pg", pg.module("pg"));
	zrm_module.addImport("pg", pg.module("pg"));

	// Creates a step for unit testing. This only builds the test executable
	// but does not run it.
	const lib_unit_tests = b.addTest(.{
		.root_source_file = b.path("tests/root.zig"),
		.target = target,
		.optimize = optimize,
	});

	// Add zouter dependency.
	lib_unit_tests.root_module.addImport("zrm", zrm_module);
	lib_unit_tests.root_module.addImport("zollections", zollections.module("zollections"));
	lib_unit_tests.root_module.addImport("pg", pg.module("pg"));

	const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
	run_lib_unit_tests.has_side_effects = true;

	// Add an executable for tests global setup.
	const tests_setup = b.addExecutable(.{
		.name = "tests_setup",
		.root_source_file = b.path("tests/setup.zig"),
		.target = target,
		.optimize = optimize,
	});
	tests_setup.root_module.addImport("pg", pg.module("pg"));
	const run_tests_setup = b.addRunArtifact(tests_setup);

	// Similar to creating the run step earlier, this exposes a `test` step to
	// the `zig build --help` menu, providing a way for the user to request
	// running the unit tests.
	const test_step = b.step("test", "Run unit tests.");
	test_step.dependOn(&run_tests_setup.step);
	test_step.dependOn(&run_lib_unit_tests.step);


	// Documentation generation.
	const install_docs = b.addInstallDirectory(.{
		.source_dir = lib.getEmittedDocs(),
		.install_dir = .prefix,
		.install_subdir = "docs",
	});

	// Documentation generation step.
	const docs_step = b.step("docs", "Emit documentation.");
	docs_step.dependOn(&install_docs.step);
}
