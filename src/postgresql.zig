const std = @import("std");
const pg = @import("pg");
const global = @import("global.zig");
const errors = @import("errors.zig");
const database = @import("database.zig");
const _sql = @import("sql.zig");
const repository = @import("repository.zig");

/// PostgreSQL query error details.
pub const PostgresqlError = struct {
	code: []const u8,
	message: []const u8,
};

/// Try to bind query parameters to the statement.
pub fn bindQueryParameters(statement: *pg.Stmt, parameters: []const _sql.QueryParameter) !void {
	for (parameters) |parameter| {
		// Try to bind each parameter in the slice.
		try bindQueryParameter(statement, parameter);
	}
}

/// Try to bind a query parameter to the statement.
pub fn bindQueryParameter(statement: *pg.Stmt, parameter: _sql.QueryParameter) !void {
	switch (parameter) {
		.integer => |integer| try statement.bind(integer),
		.number => |number| try statement.bind(number),
		.string => |string| try statement.bind(string),
		.bool => |boolVal| try statement.bind(boolVal),
		.null => try statement.bind(null),
	}
}

/// PostgreSQL error handling by ZRM.
pub fn handlePostgresqlError(err: anyerror, connection: *database.Connection, statement: *pg.Stmt) anyerror {
	// Release connection and statement as query failed.
	defer statement.deinit();
	defer connection.release();

	if (connection.connection.err) |sqlErr| {
		if (global.debugMode) {
			// If debug mode is enabled, show the PostgreSQL error.
			std.debug.print("PostgreSQL error\n{s}: {s}\n", .{sqlErr.code, sqlErr.message});
		}

		// Return that an error happened in query execution.
		return errors.ZrmError.QueryFailed;
	} else {
		// Not an SQL error, just return it.
		return err;
	}
}
