
/// Append an element to the given array at comptime.
pub fn append(array: anytype, element: anytype) @TypeOf(array ++ .{element}) {
	return array ++ .{element};
}

/// Join strings into one, with the given separator in between.
pub fn join(separator: []const u8, slices: []const[]const u8) []const u8 {
	if (slices.len == 0) return "";

	// Compute total length of the string to make.
	const totalLen = total: {
		// Compute separator length.
		var total = separator.len * (slices.len - 1);
		// Add length of all slices.
		for (slices) |slice| total += slice.len;
		break :total total;
	};

	var buffer: [totalLen]u8 = undefined;

	// Based on std.mem.joinMaybeZ implementation.
	@memcpy(buffer[0..slices[0].len], slices[0]);
	var buf_index: usize = slices[0].len;
	for (slices[1..]) |slice| {
		@memcpy(buffer[buf_index .. buf_index + separator.len], separator);
		buf_index += separator.len;
		@memcpy(buffer[buf_index .. buf_index + slice.len], slice);
		buf_index += slice.len;
	}

	return &buffer;
}
