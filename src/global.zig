const std = @import("std");

/// Set if debug mode is enabled or not.
pub var debugMode: bool = false;

/// Set debug mode status.
pub fn setDebug(comptime debug: bool) void {
	debugMode = debug;
}
