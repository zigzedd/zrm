const std = @import("std");
const pg = @import("pg");
const zollections = @import("zollections");
const global = @import("global.zig");
const errors = @import("errors.zig");
const database = @import("database.zig");
const _sql = @import("sql.zig");
const _relations = @import("relations.zig");
const repository = @import("repository.zig");
const _result = @import("result.zig");

/// PostgreSQL query error details.
pub const PostgresqlError = struct {
	code: []const u8,
	message: []const u8,
};

/// Try to bind query parameters to the statement.
pub fn bindQueryParameters(statement: *pg.Stmt, parameters: []const _sql.RawQueryParameter) !void {
	for (parameters) |parameter| {
		// Try to bind each parameter in the slice.
		try bindQueryParameter(statement, parameter);
	}
}

/// Try to bind a query parameter to the statement.
pub fn bindQueryParameter(statement: *pg.Stmt, parameter: _sql.RawQueryParameter) !void {
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

	return handleRawPostgresqlError(err, connection.connection);
}

/// PostgreSQL raw error handling by ZRM.
pub fn handleRawPostgresqlError(err: anyerror, connection: *pg.Conn) anyerror {
	if (connection.err) |sqlErr| {
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

/// Make a PostgreSQL result mapper with the given prefix, if there is one.
pub fn makeMapper(comptime T: type, result: *pg.Result, allocator: std.mem.Allocator, optionalPrefix: ?[]const u8) !pg.Mapper(T) {
	var column_indexes: [std.meta.fields(T).len]?usize = undefined;

	inline for (std.meta.fields(T), 0..) |field, i| {
		if (optionalPrefix) |prefix| {
			const fullName = try std.fmt.allocPrint(allocator, "{s}" ++ field.name, .{prefix});
			defer allocator.free(fullName);
			column_indexes[i] = result.columnIndex(fullName);
		} else {
			column_indexes[i] = result.columnIndex(field.name);
		}
	}

	return .{
		.result = result,
		.allocator = allocator,
		.column_indexes = column_indexes,
	};
}

pub fn QueryResultReader(comptime TableShape: type, comptime inlineRelations: ?[]const _relations.ModelRelation) type {
	const InstanceInterface = _result.QueryResultReader(TableShape, inlineRelations).Instance;

	return struct {
		const Self = @This();

		pub const Instance = struct {
			/// Main object mapper.
			mainMapper: pg.Mapper(TableShape) = undefined,

			fn next(opaqueSelf: *anyopaque) !?TableShape { //TODO inline relations.
				const self: *Instance = @ptrCast(@alignCast(opaqueSelf));
				return try self.mainMapper.next();
			}

			pub fn instance(self: *Instance, allocator: std.mem.Allocator) InstanceInterface {
				return .{
					.__interface = .{
						.instance = self,
						.next = next,
					},

					.allocator = allocator,
				};
			}
		};

		instance: Instance = Instance{},

		/// The PostgreSQL query result.
		result: *pg.Result,

		fn initInstance(opaqueSelf: *anyopaque, allocator: std.mem.Allocator) !InstanceInterface {
			const self: *Self = @ptrCast(@alignCast(opaqueSelf));
			self.instance.mainMapper = try makeMapper(TableShape, self.result, allocator, null);
			return self.instance.instance(allocator);
		}

		pub fn reader(self: *Self) _result.QueryResultReader(TableShape, inlineRelations) {
			return .{
				._interface = .{
					.instance = self,
					.init = initInstance,
				},
			};
		}

		/// Initialize a PostgreSQL query result reader from the given query result.
		pub fn init(result: *pg.Result) Self {
			return .{
				.result = result,
			};
		}
	};
}
