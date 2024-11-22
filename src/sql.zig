const std = @import("std");
const errors = @import("errors.zig");

/// A structure with SQL and its parameters.
pub const RawQuery = struct {
	const Self = @This();

	sql: []const u8,
	params: []const RawQueryParameter,

	/// Build an SQL query with all the given query parts, separated by a space.
	pub fn fromConcat(allocator: std.mem.Allocator, queries: []const RawQuery) !Self {
		// Allocate an array with all SQL queries.
		const queriesSql = try allocator.alloc([]const u8, queries.len);
		defer allocator.free(queriesSql);

		// Allocate an array with all parameters arrays.
		const queriesParams = try allocator.alloc([]const RawQueryParameter, queries.len);
		defer allocator.free(queriesSql);

		// Fill SQL queries and parameters arrays.
		for (queries, queriesSql, queriesParams) |_query, *_querySql, *_queryParam| {
			_querySql.* = _query.sql;
			_queryParam.* = _query.params;
		}

		// Build final query with its parameters.
		return Self{
			.sql = try std.mem.join(allocator, " ", queriesSql),
			.params = try std.mem.concat(allocator, RawQueryParameter, queriesParams),
		};
	}

	/// Build a full SQL query with numbered parameters.
	pub fn build(self: Self, allocator: std.mem.Allocator) ![]u8 {
		if (self.params.len <= 0) {
			// No parameters, just copy SQL.
			return allocator.dupe(u8, self.sql);
		} else {
			// Copy SQL and replace '?' by numbered parameters.
			const sqlSize = self.sql.len + computeRequiredSpaceForNumbers(self.params.len);
			var sqlBuf = try std.ArrayList(u8).initCapacity(allocator, sqlSize);
			defer sqlBuf.deinit();

			// Parameter counter.
			var currentParameter: usize = 1;

			for (self.sql) |char| {
				// Copy each character but '?', replaced by the current parameter string.

				if (char == '?') {
					// Copy the parameter string in place of '?'.
					try sqlBuf.writer().print("${d}", .{currentParameter});
					// Increment parameter count.
					currentParameter += 1;
				} else {
					// Simply pass the current character.
					try sqlBuf.append(char);
				}
			}

			// Return the built SQL query.
			return sqlBuf.toOwnedSlice();
		}
	}
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

/// A query parameter.
pub const RawQueryParameter = union(enum) {
	string: []const u8,
	integer: i64,
	number: f64,
	bool: bool,
	null: void,

	/// Convert any value to a query parameter.
	pub fn fromValue(value: anytype) errors.ZrmError!RawQueryParameter {
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
					return RawQueryParameter.fromValue(value.*);
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
					return RawQueryParameter.fromValue(val);
				} else {
					// If an optional value is not defined, set it to NULL.
					return .{ .null = true };
				}
			},
			else => return errors.ZrmError.UnsupportedTableType
		};
	}
};


/// SELECT query part builder for a given table.
pub fn SelectBuilder(comptime TableShape: type) type {
	// Get fields count in the table shape.
	const columnsCount = @typeInfo(TableShape).Struct.fields.len;

	// Sum of lengths of all selected columns formats.
	var _selectColumnsLength = 0;

	const selectColumns = comptime select: {
		// Initialize the select columns array.
		var _select: [columnsCount][]const u8 = undefined;

		// For each field, generate a format string.
		for (@typeInfo(TableShape).Struct.fields, &_select) |field, *columnSelect| {
			// Select the current field column.
			columnSelect.* = "\"{s}\".\"" ++ field.name ++ "\" AS \"{s}" ++ field.name ++ "\"";
			_selectColumnsLength = _selectColumnsLength + columnSelect.len;
		}

		break :select _select;
	};

	// Export computed select columns length.
	const selectColumnsLength = _selectColumnsLength;

	return struct {
		/// Build a SELECT query part for a given table, renaming columns with the given prefix.
		pub fn build(allocator: std.mem.Allocator, table: []const u8, prefix: []const u8) ![]const u8 {
			// Initialize full select string with precomputed size.
			var fullSelect = try std.ArrayList(u8).initCapacity(allocator,
				selectColumnsLength // static SQL size.
					+ columnsCount*(table.len - 2 + prefix.len - 2) // replacing %s and %s by table and prefix.
					+ (columnsCount - 1) * 2  // ", "
			);
			defer fullSelect.deinit();

			var first = true;
			inline for (selectColumns) |columnSelect| {
				// Add ", " between all selected columns.
				if (first) {
					first = false;
				} else {
					try fullSelect.appendSlice(", ");
				}

				try fullSelect.writer().print(columnSelect, .{table, prefix});
			}

			return fullSelect.toOwnedSlice(); // Return built full select.
		}
	};
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

/// Copy the given source query and replace '?' parameters by numbered parameters.
pub fn copyAndReplaceSqlParameters(currentParameter: *usize, parametersCount: usize, writer: std.ArrayList(u8).Writer, source: []const u8) !void {
	// If there are no parameters, just copy source SQL.
	if (parametersCount <= 0) {
		try writer.writeAll(source);
		return;
	}

	for (source) |char| {
		// Copy each character but '?', replaced by the current parameter string.

		if (char == '?') {
			// Copy the parameter string in place of '?'.
			try writer.print("${d}", .{currentParameter.*});
			// Increment parameter count.
			currentParameter.* += 1;
		} else {
			// Simply write the current character.
			try writer.writeByte(char);
		}
	}
}
