const std = @import("std");
const errors = @import("errors.zig");

/// A structure with SQL and its parameters.
pub const SqlParams = struct {
	sql: []const u8,
	params: []const QueryParameter,
};

/// Generate parameters SQL in the form of "?,?,?,?"
pub fn generateParametersSql(allocator: std.mem.Allocator, parametersCount: u64) ![]const u8 {
	// Allocate required string size.
	var sql: []u8 = try allocator.alloc(u8, parametersCount * 2 - 1);
	for (0..parametersCount) |i| {
		// Add a '?' for the current parameter.
		sql[i*2] = '?';
		// Add a ',' if it's not the last parameter.
		if (i + 1 != parametersCount)
			sql[i*2 + 1] = ',';
	}
	return sql;
}

/// Compute required string size of numbers for the given parameters count, with taking in account the already used parameters numbers.
pub fn computeRequiredSpaceForParametersNumbers(parametersCount: usize, alreadyUsedParameters: usize) usize {
	var remainingUsedParameters = alreadyUsedParameters; // Initialize the count of used parameters to mark as taken.
	var numbersSize: usize = 0; // Initialize the required size.
	var remaining = parametersCount; // Initialize the remaining parameters to count.
	var currentSliceSize: usize = 9; // Initialize the first slice size of numbers.
	var i: usize = 1; // Initialize the current slice count.

	while (remaining > 0) {
		if (currentSliceSize <= remainingUsedParameters) {
			// All numbers of the current slice are taken by the already used parameters.
			remainingUsedParameters -= currentSliceSize;
		} else {
			// Compute the count of numbers in the current slice.
			const numbersCount = @min(remaining, currentSliceSize - remainingUsedParameters);

			// Add the required string size of all numbers in this slice.
			numbersSize += i * (numbersCount);
			// Subtract the counted numbers in this current slice.
			remaining -= numbersCount;

			// No remaining used parameters.
			remainingUsedParameters = 0;
		}

		// Move to the next slice.
		i += 1;
		currentSliceSize *= 10;
	}

	// Return the computed numbers size.
	return numbersSize;
}

/// Compute required string size of numbers for the given parameters count.
pub fn computeRequiredSpaceForNumbers(parametersCount: usize) usize {
	var numbersSize: usize = 0; // Initialize the required size.
	var remaining = parametersCount; // Initialize the remaining parameters to count.
	var currentSliceSize: usize = 9; // Initialize the first slice size of numbers.
	var i: usize = 1; // Initialize the current slice count.

	while (remaining > 0) {
		// Compute the count of numbers in the current slice.
		const numbersCount = @min(remaining, currentSliceSize);
		// Add the required string size of all numbers in this slice.
		numbersSize += i * numbersCount;
		// Subtract the counted numbers in this current slice.
		remaining -= numbersCount;
		// Move to the next slice.
		i += 1;
		currentSliceSize *= 10;
	}

	// Return the computed numbers size.
	return numbersSize;
}

/// Compute required string size for the given parameter number.
pub fn computeRequiredSpaceForParameter(parameterNumber: usize) !usize {
	var i: usize = 1;
	while (parameterNumber >= try std.math.powi(usize, 10, i)) {
		i += 1;
	}
	return i;
}

pub fn copyAndReplaceSqlParameters(currentParameter: *usize, parametersCount: usize, dest: []u8, source: []const u8) !void {
	// If there are no parameters, just copy source SQL.
	if (parametersCount <= 0) {
		std.mem.copyForwards(u8, dest, source);
	}

	// Current dest cursor.
	var destCursor: usize = 0;

	for (source) |char| {
		// Copy each character but '?', replaced by the current parameter string.

		if (char == '?') {
			// Create the parameter string.
			const paramSize = 1 + try computeRequiredSpaceForParameter(currentParameter.*);
			// Copy the parameter string in place of '?'.
			_ = try std.fmt.bufPrint(dest[destCursor..destCursor+paramSize], "${d}", .{currentParameter.*});
			// Add parameter string length to the current query cursor.
			destCursor += paramSize;
			// Increment parameter count.
			currentParameter.* += 1;
		} else {
			// Simply pass the current character.
			dest[destCursor] = char;
			destCursor += 1;
		}
	}
}

pub fn numberSqlParameters(sql: []const u8, comptime parametersCount: usize) [sql.len + computeRequiredSpaceForNumbers(parametersCount)]u8 {
	// If there are no parameters, just return built SQL.
	if (parametersCount <= 0) {
		return @as([sql.len]u8, sql[0..sql.len].*);
	}

	// New query buffer.
	var query: [sql.len + computeRequiredSpaceForNumbers(parametersCount)]u8 = undefined;

	// Current query cursor.
	var queryCursor: usize = 0;
	// Current parameter count.
	var currentParameter: usize = 1;

	for (sql) |char| {
		// Copy each character but '?', replaced by the current parameter string.

		if (char == '?') {
			var buffer: [computeRequiredSpaceForParameter(currentParameter)]u8 = undefined;
			// Create the parameter string.
			const paramStr = try std.fmt.bufPrint(&buffer, "${d}", .{currentParameter});
			// Copy the parameter string in place of '?'.
			@memcpy(query[queryCursor..(queryCursor + paramStr.len)], paramStr);
			// Add parameter string length to the current query cursor.
			queryCursor += paramStr.len;
			// Increment parameter count.
			currentParameter += 1;
		} else {
			// Simply pass the current character.
			query[queryCursor] = char;
			queryCursor += 1;
		}
	}

	// Return built query.
	return query;
}

/// A query parameter.
pub const QueryParameter = union(enum) {
	string: []const u8,
	integer: i64,
	number: f64,
	bool: bool,
	null: void,

	/// Convert any value to a query parameter.
	pub fn fromValue(value: anytype) errors.ZrmError!QueryParameter {
		// Get given value type.
		const valueType = @typeInfo(@TypeOf(value));

		return switch (valueType) {
			.Int, .ComptimeInt => return .{ .integer = @intCast(value), },
			.Float, .ComptimeFloat => return .{ .number = @floatCast(value), },
			.Bool => return .{ .bool = value, },
			.Null => return .{ .null = true, },
			.Pointer => |pointer| {
				if (pointer.size == .One) {
					// Get pointed value.
					return QueryParameter.fromValue(value.*);
				} else {
					// Can only take an array of u8 (= string).
					if (pointer.child == u8) {
						return .{ .string = value };
					} else {
						return errors.ZrmError.UnsupportedTableType;
					}
				}
			},
			.Enum, .EnumLiteral => {
				return .{ .string = @tagName(value) };
			},
			.Optional => {
				if (value) |val| {
					// The optional value is defined, use it as a query parameter.
					return QueryParameter.fromValue(val);
				} else {
					// If an optional value is not defined, set it to NULL.
					return .{ .null = true };
				}
			},
			else => return errors.ZrmError.UnsupportedTableType
		};
	}
};
