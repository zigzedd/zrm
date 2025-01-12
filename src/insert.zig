const std = @import("std");
const pg = @import("pg");
const zollections = @import("zollections");
const ZrmError = @import("errors.zig").ZrmError;
const database = @import("database.zig");
const postgresql = @import("postgresql.zig");
const _sql = @import("sql.zig");
const repository = @import("repository.zig");
const _result = @import("result.zig");

/// Type of an insertable column. Insert shape should be composed of only these.
fn InsertableColumn(comptime ValueType: type) type {
	return struct {
		value: ?ValueType = null,
		default: bool = false,
	};
}

/// Build an insertable structure type from a normal structure.
pub fn Insertable(comptime StructType: type) type {
	// Get type info of the given structure.
	const typeInfo = @typeInfo(StructType);

	// Initialize fields of the insertable struct.
	var newFields: [typeInfo.Struct.fields.len]std.builtin.Type.StructField = undefined;
	for (typeInfo.Struct.fields, &newFields) |field, *newField| {
		// Create a new field for each field of the given struct.
		const newFieldType = InsertableColumn(field.type);
		newField.* = std.builtin.Type.StructField{
			.name = field.name,
			.type = newFieldType,
			.default_value = null,
			.is_comptime = false,
			.alignment = @alignOf(newFieldType),
		};
	}

	// Return the insertable structure type.
	return @Type(std.builtin.Type{
		.Struct = .{
			.layout = .auto,
			.decls = &[0]std.builtin.Type.Declaration{},
			.fields = &newFields,
			.is_tuple = false,
		},
	});
}

/// Repository insert query configuration structure.
pub fn RepositoryInsertConfiguration(comptime InsertShape: type) type {
	return struct {
		values: []const Insertable(InsertShape) = undefined,
		returning: ?_sql.RawQuery = null,
	};
}

/// Repository models insert manager.
/// Manage insert query string build and execution.
pub fn RepositoryInsert(comptime Model: type, comptime TableShape: type, comptime repositoryConfig: repository.RepositoryConfiguration(Model, TableShape), comptime InsertShape: type) type {
	// Create columns list.
	const columns = comptime columnsFinder: {
		// Get insert shape type data.
		const insertType = @typeInfo(InsertShape);
		// Initialize a columns slice of "fields len" size.
		var columnsList: [insertType.Struct.fields.len][]const u8 = undefined;

		// Add structure fields to the columns slice.
		var i: usize = 0;
		for (insertType.Struct.fields) |field| {
			// Check that the table type defines the same fields.
			if (!@hasField(TableShape, field.name))
				//TODO check its type?
				@compileError("The table doesn't contain the indicated insert columns.");

			// Add each structure field to columns list.
			columnsList[i] = field.name;
			i += 1;
		}

		// Assign built columns list.
		break :columnsFinder columnsList;
	};

	// Pre-compute SQL buffer size.
	const sqlBase = "INSERT INTO " ++ repositoryConfig.table ++ comptime buildInsertColumns: {
		// Compute the size of the insert columns buffer.
		var insertColumnsSize = 0;
		for (columns) |column| {
			insertColumnsSize += column.len + 1;
		}
		insertColumnsSize = insertColumnsSize - 1 + 2; // 2 for parentheses.

		var columnsBuf: [insertColumnsSize]u8 = undefined;
		// Initialize columns buffer cursor.
		var columnsBufCursor = 0;
		// Open parentheses.
		columnsBuf[columnsBufCursor] = '('; columnsBufCursor += 1;

		for (columns) |column| {
			// Write each column name, with a ',' as separator.
			@memcpy(columnsBuf[columnsBufCursor..columnsBufCursor+column.len+1], column ++ ",");
			columnsBufCursor += column.len + 1;
		}

		// Replace the last ',' by a ')'.
		columnsBuf[columnsBufCursor - 1] = ')';

		break :buildInsertColumns columnsBuf;
	} ++ " VALUES ";

	// Initialize the RETURNING clause.
	const returningClause = "RETURNING";

	// INSERT INTO {repositoryConfig.table} VALUES ?;
	const fixedSqlSize = sqlBase.len + 0 + 1;

	return struct {
		const Self = @This();

		const Configuration = RepositoryInsertConfiguration(InsertShape);

		/// Result mapper type.
		pub const ResultMapper = _result.ResultMapper(Model, TableShape, null, repositoryConfig, null, null);

		arena: std.heap.ArenaAllocator,
		connector: database.Connector,
		connection: *database.Connection = undefined,
		insertConfig: Configuration,

		sql: ?[]const u8 = null,

		/// Parse given model or shape and put the result in newValue.
		fn parseData(newValue: *Insertable(InsertShape), value: anytype) !void {
			// If the given value is a model, first convert it to its SQL equivalent.
			if (@TypeOf(value) == Model) {
				return parseData(newValue, try repositoryConfig.toSql(value));
			}

			inline for (columns) |column| {
				@field(newValue.*, column) = .{ .value = @field(value, column) };
			}
		}

		/// Parse one value to insert.
		fn parseOne(self: *Self, value: anytype) !void {
			const newValues = try self.arena.allocator().alloc(Insertable(InsertShape), 1);
			// Parse the given value.
			try parseData(&newValues[0], value);
			self.insertConfig.values = newValues;
		}

		/// Parse a slice of values to insert.
		fn parseSlice(self: *Self, value: anytype) !void {
			const newValues = try self.arena.allocator().alloc(Insertable(InsertShape), value.len);
			for (0..value.len) |i| {
				// Parse each value in the given slice.
				try parseData(&newValues[i], value[i]);
			}
			self.insertConfig.values = newValues;
		}

		/// Set values to insert.
		/// Values can be Model, TableShape or InsertShape.
		pub fn values(self: *Self, _values: anytype) !void {
			// Get values type.
			const valuesType = @TypeOf(_values);

			switch (@typeInfo(valuesType)) {
				.Pointer => |ptr| {
					switch (ptr.size) {
						// It's a single object.
						.One => switch (@typeInfo(ptr.child)) {
							// It's an array, parse it.
							.Array => try self.parseSlice(_values),
							// It's a structure, parse it.
							.Struct => try self.parseOne(_values.*),
							else => @compileError("Cannot insert values of type " ++ @typeName(ptr.child)),
						},
						// It's a slice, parse it.
						else => switch (@typeInfo(ptr.child)) {
							.Struct => try self.parseSlice(_values),
							else => @compileError("Cannot insert values of type " ++ @typeName(ptr.child)),
						}
					}
				},
				// It's a structure, just parse it.
				.Struct => try self.parseOne(_values),

				else => @compileError("Cannot insert values of type " ++ @typeName(valuesType)),
			}
		}

		/// Set selected columns for RETURNING clause.
		pub fn returning(self: *Self, _select: _sql.RawQuery) void {
			self.insertConfig.returning = _select;
		}

		/// Set selected columns for RETURNING clause.
		pub fn returningColumns(self: *Self, _select: []const []const u8) void {
			if (_select.len == 0) {
				return ZrmError.AtLeastOneSelectionRequired;
			}

			self.returning(.{
				// Join selected columns.
				.sql = std.mem.join(self.arena.allocator(), ", ", _select),
				.params = &[_]_sql.RawQueryParameter{}, // No parameters.
			});
		}

		/// Set RETURNING all columns of the table after insert.
		pub fn returningAll(self: *Self) void {
			self.returning(.{
				.sql = "*",
				.params = &[_]_sql.RawQueryParameter{}, // No parameters.
			});
		}

		/// Build SQL query.
		pub fn buildSql(self: *Self) !void {
			if (self.insertConfig.values.len == 0) {
				// At least one value is required to insert.
				return ZrmError.AtLeastOneValueRequired;
			}

			// Compute VALUES parameters count.
			const valuesParametersCount = self.insertConfig.values.len * columns.len;

			// Compute values SQL size (format: "($1,$2,$3),($4,$5,$6),($7,$8,$9)").
			const valuesSqlSize = _sql.computeRequiredSpaceForParametersNumbers(valuesParametersCount, 0)
				+ valuesParametersCount // Dollars in values sets.
				+ (self.insertConfig.values.len * (columns.len - 1)) // ',' separators in values sets.
				+ (self.insertConfig.values.len - 1) // ',' separators between values sets.
				+ (self.insertConfig.values.len * 2) // Parentheses of values sets.
			;

			// Compute RETURNING size.
			const returningSize: usize = if (self.insertConfig.returning) |_returning| (
				1 + returningClause.len + _returning.sql.len + 1 + _sql.computeRequiredSpaceForParametersNumbers(_returning.params.len, valuesParametersCount)
			) else 0;

			// Initialize SQL buffer.
			var sqlBuf = try std.ArrayList(u8).initCapacity(self.arena.allocator(), fixedSqlSize + valuesSqlSize + returningSize);
			defer sqlBuf.deinit();

			// Append initial "INSERT INTO table VALUES ".
			try sqlBuf.appendSlice(sqlBase);

			// Start parameter counter at 1.
			var currentParameter: usize = 1;

			if (self.insertConfig.values.len == 0) {
				// No values, output an empty values set.
				try sqlBuf.appendSlice("()");
			} else {
				// Build values set.
				for (self.insertConfig.values) |_| {
					// Add the first '('.
					try sqlBuf.append('(');
					inline for (columns) |_| {
						// Create the parameter string and append it to the SQL buffer.
						try sqlBuf.writer().print("${d},", .{currentParameter});
						// Increment parameter count.
						currentParameter += 1;
					}
					// Replace the final ',' with a ')'.
					sqlBuf.items[sqlBuf.items.len - 1] = ')';
					// Add the final ','.
					try sqlBuf.append(',');
				}

				// Remove the last ','.
				_ = sqlBuf.pop();
			}

			// Append RETURNING clause, if there is one defined.
			if (self.insertConfig.returning) |_returning| {
				try sqlBuf.appendSlice(" " ++ returningClause ++ " ");
				// Copy RETURNING clause content and replace parameters, if there are some.
				try _sql.copyAndReplaceSqlParameters(&currentParameter,
					_returning.params.len, sqlBuf.writer(), _returning.sql
				);
			}

			// ";" to end the query.
			try sqlBuf.append(';');

			// Save built SQL query.
			self.sql = try sqlBuf.toOwnedSlice();
		}

		/// Execute the insert query.
		fn execQuery(self: *Self) !*pg.Result {
			// Get a connection to the database.
			self.connection = try self.connector.getConnection();
			errdefer self.connection.release();

			// Initialize a new PostgreSQL statement.
			var statement = try pg.Stmt.init(self.connection.connection, .{
				.column_names = true,
				.allocator = self.arena.allocator(),
			});
			errdefer statement.deinit();

			// Prepare SQL insert query.
			statement.prepare(self.sql.?)
				catch |err| return postgresql.handlePostgresqlError(err, self.connection, &statement);

			// Bind INSERT query parameters.
			for (self.insertConfig.values) |row| {
				inline for (columns) |column| {
					try statement.bind(@field(row, column).value);
				}
			}
			// Bind RETURNING query parameters.
			if (self.insertConfig.returning) |_returning| {
				try postgresql.bindQueryParameters(&statement,  _returning.params);
			}

			// Execute the query and get its result.
			const result = statement.execute()
				catch |err| return postgresql.handlePostgresqlError(err, self.connection, &statement);

			// Query executed successfully, return the result.
			return result;
		}

		/// Insert given models.
		pub fn insert(self: *Self, allocator: std.mem.Allocator) !repository.RepositoryResult(Model) {
			// Build SQL query if it wasn't built.
			if (self.sql) |_| {} else { try self.buildSql(); }

			// Execute query and get its result.
			var queryResult = try self.execQuery();
			defer self.connection.release();
			defer queryResult.deinit();

			// Map query results.
			var postgresqlReader = postgresql.QueryResultReader(TableShape, null, null).init(queryResult);
			return try ResultMapper.map(false, allocator, self.connector, postgresqlReader.reader());
		}

		/// Initialize a new repository insert query.
		pub fn init(allocator: std.mem.Allocator, connector: database.Connector) Self {
			return .{
				// Initialize an arena allocator for the insert query.
				.arena = std.heap.ArenaAllocator.init(allocator),
				.connector = connector,
				.insertConfig = .{},
			};
		}

		/// Deinitialize the repository insert query.
		pub fn deinit(self: *Self) void {
			// Free everything allocated for this insert query.
			self.arena.deinit();
		}
	};
}
