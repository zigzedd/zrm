const std = @import("std");
const _sql = @import("sql.zig");
const ZrmError = @import("errors.zig").ZrmError;

const Static = @This();

/// Create a value condition on a column.
pub fn value(comptime ValueType: type, allocator: std.mem.Allocator, comptime _column: []const u8, comptime operator: []const u8, _value: ValueType) !_sql.RawQuery {
	// Initialize the SQL condition string.
	var comptimeSql: [_column.len + 1 + operator.len + 1 + 1]u8 = undefined;
	@memcpy(comptimeSql[0.._column.len], _column);
	@memcpy(comptimeSql[_column.len.._column.len + 1], " ");
	@memcpy(comptimeSql[_column.len + 1..(_column.len + 1 + operator.len)], operator);
	@memcpy(comptimeSql[_column.len + 1 + operator.len..], " ?");

	// Initialize SQL buffer and set its value to comptime-generated SQL.
	const sqlBuf = try allocator.alloc(u8, comptimeSql.len);
	std.mem.copyForwards(u8, sqlBuf, &comptimeSql);

	// Initialize parameters array.
	const params = try allocator.alloc(_sql.RawQueryParameter, 1);
	params[0] = try _sql.RawQueryParameter.fromValue(_value);

	// Return the built SQL condition.
	return .{
		.sql = sqlBuf,
		.params = params,
	};
}

/// Create a column condition on a column.
pub fn column(allocator: std.mem.Allocator, comptime _column: []const u8, comptime operator: []const u8, comptime valueColumn: []const u8) !_sql.RawQuery {
	// Initialize the SQL condition string.
	var comptimeSql: [_column.len + 1 + operator.len + 1 + valueColumn.len]u8 = undefined;
	@memcpy(comptimeSql[0.._column.len], _column);
	@memcpy(comptimeSql[_column.len.._column.len + 1], " ");
	@memcpy(comptimeSql[_column.len + 1..(_column.len + 1 + operator.len)], operator);
	@memcpy(comptimeSql[_column.len + 1 + operator.len.._column.len + 1 + operator.len + 1], " ");
	@memcpy(comptimeSql[_column.len + 1 + operator.len + 1..], valueColumn);

	// Initialize SQL buffer and set its value to comptime-generated SQL.
	const sqlBuf = try allocator.alloc(u8, comptimeSql.len);
	std.mem.copyForwards(u8, sqlBuf, &comptimeSql);

	// Return the built SQL condition.
	return .{
		.sql = sqlBuf,
		.params = &[0]_sql.RawQueryParameter{},
	};
}

/// Create an IN condition on a column.
pub fn in(comptime ValueType: type, allocator: std.mem.Allocator, _column: []const u8, _value: []const ValueType) !_sql.RawQuery {
	// Generate parameters SQL.
	const parametersSql = try _sql.generateParametersSql(allocator, _value.len);
	// Get all query parameters from given values.
	var valueParameters: []_sql.RawQueryParameter = try allocator.alloc(_sql.RawQueryParameter, _value.len);
	for (0.._value.len) |i| {
		// Convert every given value to a query parameter.
		valueParameters[i] = try _sql.RawQueryParameter.fromValue(_value[i]);
	}

	// Initialize the SQL condition string.
	var sqlBuf: []u8 = try allocator.alloc(u8, _column.len + 1 + 2 + 1 + 1 + parametersSql.len + 1);
	std.mem.copyForwards(u8, sqlBuf[0.._column.len], _column);
	std.mem.copyForwards(u8, sqlBuf[_column.len.._column.len + 1 + 2 + 1 + 1], " IN (");
	std.mem.copyForwards(u8, sqlBuf[_column.len + 1 + 2 + 1 + 1.._column.len + 1 + 2 + 1 + 1 + parametersSql.len], parametersSql);
	std.mem.copyForwards(u8, sqlBuf[_column.len + 1 + 2 + 1 + 1 + parametersSql.len..], ")");

	// Return the built SQL condition.
	return .{
		.sql = sqlBuf,
		.params = valueParameters,
	};
}

/// Generic conditions combiner generator.
fn conditionsCombiner(comptime keyword: []const u8, allocator: std.mem.Allocator, subconditions: []const _sql.RawQuery) !_sql.RawQuery {
	if (subconditions.len == 0) {
		// At least one condition is required.
		return ZrmError.AtLeastOneConditionRequired;
	}

	// Full keyword constant.
	const fullKeyword = " " ++ keyword ++ " ";

	// Compute size of the SQL to generate, and the count of query parameters in total.
	var sqlSize: usize = 1 + 1; // parentheses.
	var queryParametersCount: usize = 0;
	for (subconditions) |subcondition| {
		sqlSize += subcondition.sql.len;
		queryParametersCount += subcondition.params.len;
	}
	// There are n-1 keywords.
	sqlSize += (subconditions.len - 1) * fullKeyword.len;

	// Initialize the SQL condition string.
	var sqlBuf = try allocator.alloc(u8, sqlSize);
	// Initialize the query parameters array.
	var parameters = try allocator.alloc(_sql.RawQueryParameter, queryParametersCount);
	var sqlBufCursor: usize = 0; var parametersCursor: usize = 0;

	// Add first parenthesis.
	sqlBuf[sqlBufCursor] = '('; sqlBufCursor += 1;

	// Add all subconditions.
	for (0..subconditions.len) |i| {
		// Add each subcondition to SQL.
		const subcondition = subconditions[i];
		std.mem.copyForwards(u8, sqlBuf[sqlBufCursor..sqlBufCursor + subcondition.sql.len], subcondition.sql);
		sqlBufCursor += subcondition.sql.len;

		if (i < subconditions.len - 1) {
			// Append the keyword, if required.
			@memcpy(sqlBuf[sqlBufCursor..sqlBufCursor + fullKeyword.len], fullKeyword);
			sqlBufCursor += fullKeyword.len;
		}

		// Add query parameters to the array.
		std.mem.copyForwards(_sql.RawQueryParameter, parameters[parametersCursor..parametersCursor+subcondition.params.len], subcondition.params);
		parametersCursor += subcondition.params.len;
	}

	// Add last parenthesis.
	sqlBuf[sqlBufCursor] = ')'; sqlBufCursor += 1;

	// Return built SQL params.
	return .{
		.sql = sqlBuf,
		.params = parameters,
	};
}

/// Create an AND condition between multiple sub-conditions.
pub fn @"and"(allocator: std.mem.Allocator, subconditions: []const _sql.RawQuery) !_sql.RawQuery {
	return conditionsCombiner("AND", allocator, subconditions);
}

/// Create an OR condition between multiple sub-conditions.
pub fn @"or"(allocator: std.mem.Allocator, subconditions: []const _sql.RawQuery) !_sql.RawQuery {
	return conditionsCombiner("OR", allocator, subconditions);
}

/// A conditions builder.
pub const Builder = struct {
	const Self = @This();

	allocator: std.mem.Allocator,

	/// Create a value condition on a column.
	pub fn value(self: Self, comptime ValueType: type, comptime _column: []const u8, comptime operator: []const u8, _value: ValueType) !_sql.RawQuery {
		return Static.value(ValueType, self.allocator, _column, operator, _value);
	}

	/// Create a column condition on a column.
	pub fn column(self: Self, comptime _column: []const u8, comptime operator: []const u8, comptime valueColumn: []const u8) !_sql.RawQuery {
		return Static.column(self.allocator, _column, operator, valueColumn);
	}

	/// Create an IN condition on a column.
	pub fn in(self: Self, comptime ValueType: type, _column: []const u8, _value: []const ValueType) !_sql.RawQuery {
		return Static.in(ValueType, self.allocator, _column, _value);
	}

	/// Create an AND condition between multiple sub-conditions.
	pub fn @"and"(self: Self, subconditions: []const _sql.RawQuery) !_sql.RawQuery {
		return Static.@"and"(self.allocator, subconditions);
	}

	/// Create an OR condition between multiple sub-conditions.
	pub fn @"or"(self: Self, subconditions: []const _sql.RawQuery) !_sql.RawQuery {
		return Static.@"or"(self.allocator, subconditions);
	}

	/// Initialize a new conditions builder with the given allocator.
	pub fn init(allocator: std.mem.Allocator) Self {
		return .{
			.allocator = allocator,
		};
	}
};
