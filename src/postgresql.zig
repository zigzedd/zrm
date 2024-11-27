const std = @import("std");
const pg = @import("pg");
const zollections = @import("zollections");
const global = @import("global.zig");
const errors = @import("errors.zig");
const database = @import("database.zig");
const _sql = @import("sql.zig");
const _relationships = @import("relationships.zig");
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

const PgError = error {
	NullValue,
};

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

fn getScalar(T: type, data: []const u8, oid: i32) T {
	switch (T) {
		u8 => return pg.types.Char.decode(data, oid),
		i16 => return pg.types.Int16.decode(data, oid),
		i32 => return pg.types.Int32.decode(data, oid),
		i64 => return pg.types.Int64.decode(data, oid),
		f32 => return pg.types.Float32.decode(data, oid),
		f64 => return pg.types.Float64.decode(data, oid),
		bool => return pg.types.Bool.decode(data, oid),
		[]const u8 => return pg.types.Bytea.decode(data, oid),
		[]u8 => return @constCast(pg.types.Bytea.decode(data, oid)),
		pg.types.Numeric => return pg.types.Numeric.decode(data, oid),
		pg.types.Cidr => return pg.types.Cidr.decode(data, oid),
		else => switch (@typeInfo(T)) {
			.Enum => {
				const str = pg.types.Bytea.decode(data, oid);
				return std.meta.stringToEnum(T, str).?;
			},
			else => @compileError("cannot get value of type " ++ @typeName(T)),
		},
	}
}

pub fn rowGet(self: *const pg.Row, comptime T: type, col: usize) PgError!T {
	const value = self.values[col];
	const TT = switch (@typeInfo(T)) {
		.Optional => |opt| {
			if (value.is_null) {
				return null;
			} else {
				return self.get(opt.child, col);
			}
		},
		.Struct => blk: {
			if (@hasDecl(T, "fromPgzRow") == true) {
				return T.fromPgzRow(value, self.oids[col]);
			}
			break :blk T;
		},
		else => blk: {
			if (value.is_null) return PgError.NullValue;
			break :blk T;
		},
	};

	return getScalar(TT, value.data, self.oids[col]);
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
				break :blk try rowGet(self, ?pg.Iterator(S), column_index) orelse return null;
			} else {
				break :blk try rowGet(self, pg.Iterator(S), column_index);
			}
		};
		return try slice.alloc(allocator orelse return error.AllocatorRequiredForSliceMapping);
	}

	const value = try rowGet(self, field.type, column_index);
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
pub fn QueryResultReader(comptime TableShape: type, comptime MetadataShape: ?type, comptime inlineRelationships: ?[]const _relationships.Relationship) type {
	const InstanceInterface = _result.QueryResultReader(TableShape, MetadataShape, inlineRelationships).Instance;

	// Build relationships mappers container type.
	const RelationshipsMappersType = comptime typeBuilder: {
		if (inlineRelationships) |_inlineRelationships| {
			// Make a field for each relationship.
			var fields: [_inlineRelationships.len]std.builtin.Type.StructField = undefined;

			for (_inlineRelationships, &fields) |relationship, *field| {
				// Get relationship field type (TableShape of the related value).
				const relationshipFieldType = PgMapper(relationship.TableShape);

				field.* = .{
					.name = relationship.field ++ [0:0]u8{},
					.type = relationshipFieldType,
					.default_value = null,
					.is_comptime = false,
					.alignment = @alignOf(relationshipFieldType),
				};
			}

			// Build type with one field for each relationship.
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
			relationshipsMappers: RelationshipsMappersType = undefined,

			fn next(opaqueSelf: *anyopaque) !?_result.TableWithRelationships(TableShape, MetadataShape, inlineRelationships) {
				const self: *Instance = @ptrCast(@alignCast(opaqueSelf));

				// Try to get the next row.
				var row: pg.Row = try self.mainMapper.result.next() orelse return null;

				// Get main table result.
				const mainTable = try self.mainMapper.next(&row) orelse return null;

				// Initialize the result.
				var result: _result.TableWithRelationships(TableShape, MetadataShape, inlineRelationships) = undefined;

				// Copy each basic table field.
				inline for (std.meta.fields(TableShape)) |field| {
					@field(result, field.name) = @field(mainTable, field.name);
				}

				if (inlineRelationships) |_inlineRelationships| {
					// For each relationship, retrieve its value and put it in the result.
					inline for (_inlineRelationships) |relationship| {
						@field(result, relationship.field) = @field(self.relationshipsMappers, relationship.field).next(&row) catch null;
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

			if (inlineRelationships) |_inlineRelationships| {
				// Initialize mapper for each relationship.
				inline for (_inlineRelationships) |relationship| {
					@field(self.instance.relationshipsMappers, relationship.field) =
						try makeMapper(relationship.TableShape, self.result, allocator, "relationships." ++ relationship.field ++ ".");
				}
			}

			return self.instance.instance(allocator);
		}

		/// Get the generic reader instance.
		pub fn reader(self: *Self) _result.QueryResultReader(TableShape, MetadataShape, inlineRelationships) {
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
