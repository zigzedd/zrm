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

fn isSlice(comptime T: type) ?type {
	switch(@typeInfo(T)) {
		.Pointer => |ptr| {
			if (ptr.size != .Slice) {
				@compileError("cannot get value of type " ++ @typeName(T));
			}
			return if (ptr.child == u8) null else ptr.child;
		},
		.Optional => |opt| return isSlice(opt.child),
		else => return null,
	}
}

fn mapValue(comptime T: type, value: T, allocator: std.mem.Allocator) !T {
	switch (@typeInfo(T)) {
		.Optional => |opt| {
			if (value) |v| {
				return try mapValue(opt.child, v, allocator);
			}
			return null;
		},
		else => {},
	}

	if (T == []u8 or T == []const u8) {
		return try allocator.dupe(u8, value);
	}

	if (std.meta.hasFn(T, "pgzMoveOwner")) {
		return value.pgzMoveOwner(allocator);
	}

	return value;
}

fn rowMapColumn(self: *const pg.Row, field: *const std.builtin.Type.StructField, optional_column_index: ?usize, allocator: ?std.mem.Allocator) !field.type {
	const T = field.type;
	const column_index = optional_column_index orelse {
		if (field.default_value) |dflt| {
			return @as(*align(1) const field.type, @ptrCast(dflt)).*;
		}
		return error.FieldColumnMismatch;
	};

	if (comptime isSlice(T)) |S| {
		const slice = blk: {
			if (@typeInfo(T) == .Optional) {
				break :blk self.get(?pg.Iterator(S), column_index) orelse return null;
			} else {
				break :blk self.get(pg.Iterator(S), column_index);
			}
		};
		return try slice.alloc(allocator orelse return error.AllocatorRequiredForSliceMapping);
	}

	const value = self.get(field.type, column_index);
	const a = allocator orelse return value;
	return mapValue(T, value, a);
}

pub fn PgMapper(comptime T: type) type {
	return struct {
		result: *pg.Result,
		allocator: ?std.mem.Allocator,
		column_indexes: [std.meta.fields(T).len]?usize,

		const Self = @This();

		pub fn next(self: *const Self, row: *pg.Row) !?T {
			var value: T = undefined;

			const allocator = self.allocator;
			inline for (std.meta.fields(T), self.column_indexes) |field, optional_column_index| {
				//TODO I must reimplement row.mapColumn because it's not public :-(
				@field(value, field.name) = try rowMapColumn(row, &field, optional_column_index, allocator);
			}
			return value;
		}
	};
}

/// Make a PostgreSQL result mapper with the given prefix, if there is one.
pub fn makeMapper(comptime T: type, result: *pg.Result, allocator: std.mem.Allocator, optionalPrefix: ?[]const u8) !PgMapper(T) {
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

/// PostgreSQL implementation of the query result reader.
pub fn QueryResultReader(comptime TableShape: type, comptime MetadataShape: ?type, comptime inlineRelations: ?[]const _relations.Relation) type {
	const InstanceInterface = _result.QueryResultReader(TableShape, MetadataShape, inlineRelations).Instance;

	// Build relations mappers container type.
	const RelationsMappersType = comptime typeBuilder: {
		if (inlineRelations) |_inlineRelations| {
			// Make a field for each relation.
			var fields: [_inlineRelations.len]std.builtin.Type.StructField = undefined;

			for (_inlineRelations, &fields) |relation, *field| {
				// Get relation field type (TableShape of the related value).
				const relationFieldType = PgMapper(relation.TableShape);

				field.* = .{
					.name = relation.field ++ [0:0]u8{},
					.type = relationFieldType,
					.default_value = null,
					.is_comptime = false,
					.alignment = @alignOf(relationFieldType),
				};
			}

			// Build type with one field for each relation.
			break :typeBuilder @Type(std.builtin.Type{
				.Struct = .{
					.layout = std.builtin.Type.ContainerLayout.auto,
					.fields = &fields,
					.decls = &[0]std.builtin.Type.Declaration{},
					.is_tuple = false,
				},
			});
		}

		// Build default empty type.
		break :typeBuilder @Type(std.builtin.Type{
			.Struct = .{
				.layout = std.builtin.Type.ContainerLayout.auto,
				.fields = &[0]std.builtin.Type.StructField{},
				.decls = &[0]std.builtin.Type.Declaration{},
				.is_tuple = false,
			},
		});
	};

	return struct {
		const Self = @This();

		/// PostgreSQL implementation of the query result reader instance.
		pub const Instance = struct {
			/// Main object mapper.
			mainMapper: PgMapper(TableShape) = undefined,
			metadataMapper: PgMapper(MetadataShape orelse struct {}) = undefined,
			relationsMappers: RelationsMappersType = undefined,

			fn next(opaqueSelf: *anyopaque) !?_result.TableWithRelations(TableShape, MetadataShape, inlineRelations) {
				const self: *Instance = @ptrCast(@alignCast(opaqueSelf));

				// Try to get the next row.
				var row: pg.Row = try self.mainMapper.result.next() orelse return null;

				// Get main table result.
				const mainTable = try self.mainMapper.next(&row) orelse return null;

				// Initialize the result.
				var result: _result.TableWithRelations(TableShape, MetadataShape, inlineRelations) = undefined;

				// Copy each basic table field.
				inline for (std.meta.fields(TableShape)) |field| {
					@field(result, field.name) = @field(mainTable, field.name);
				}

				if (inlineRelations) |_inlineRelations| {
					// For each relation, retrieve its value and put it in the result.
					inline for (_inlineRelations) |relation| {
						//TODO detect null relation.
						@field(result, relation.field) = try @field(self.relationsMappers, relation.field).next(&row);
					}
				}

				if (MetadataShape) |_| {
					result._zrm_metadata = (try self.metadataMapper.next(&row)).?;
				}

				return result; // Return built result.
			}

			/// Get the generic reader instance instance.
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
			if (MetadataShape) |MetadataType| {
				self.instance.metadataMapper = try makeMapper(MetadataType, self.result, allocator, null);
			}

			if (inlineRelations) |_inlineRelations| {
				// Initialize mapper for each relation.
				inline for (_inlineRelations) |relation| {
					@field(self.instance.relationsMappers, relation.field) =
						try makeMapper(relation.TableShape, self.result, allocator, "relations." ++ relation.field ++ ".");
				}
			}

			return self.instance.instance(allocator);
		}

		/// Get the generic reader instance.
		pub fn reader(self: *Self) _result.QueryResultReader(TableShape, MetadataShape, inlineRelations) {
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
