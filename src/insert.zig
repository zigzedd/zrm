const std = @import("std");
const pg = @import("pg");
const zollections = @import("zollections");
const errors = @import("errors.zig");
const postgresql = @import("postgresql.zig");
const _sql = @import("sql.zig");
const repository = @import("repository.zig");

/// Type of an insertable column. Insert shape should be composed of only these.
pub fn Insertable(comptime ValueType: type) type {
	return struct {
		value: ?ValueType = null,
		default: bool = false,
	};
}

/// Repository insert query configuration structure.
pub fn RepositoryInsertConfiguration(comptime InsertShape: type) type {
	return struct {
		values: []const InsertShape = undefined,
		returning: ?_sql.SqlParams = null,
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

		arena: std.heap.ArenaAllocator,
		database: *pg.Pool,
		insertConfig: Configuration,

		sql: ?[]const u8 = null,

		/// Parse given model or shape and put the result in newValue.
		fn parseData(newValue: *InsertShape, value: anytype) !void {
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
			const newValues = try self.arena.allocator().alloc(InsertShape, 1);
			// Parse the given value.
			try parseData(&newValues[0], value);
			self.insertConfig.values = newValues;
		}

		/// Parse a slice of values to insert.
		fn parseSlice(self: *Self, value: anytype) !void {
			const newValues = try self.arena.allocator().alloc(InsertShape, value.len);
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
		pub fn returning(self: *Self, _select: _sql.SqlParams) void {
			self.insertConfig.returning = _select;
		}

		/// Set selected columns for RETURNING clause.
		pub fn returningColumns(self: *Self, _select: []const []const u8) void {
			if (_select.len == 0) {
				return errors.AtLeastOneSelectionRequired;
			}

			self.returning(.{
				// Join selected columns.
				.sql = std.mem.join(self.arena.allocator(), ", ", _select),
				.params = &[_]_sql.QueryParameter{}, // No parameters.
			});
		}

		/// Set RETURNING all columns of the table after insert.
		pub fn returningAll(self: *Self) void {
			self.returning(.{
				.sql = "*",
				.params = &[_]_sql.QueryParameter{}, // No parameters.
			});
		}

		/// Build SQL query.
		pub fn buildSql(self: *Self) !void {
			if (self.insertConfig.values.len == 0) {
				// At least one value is required to insert.
				return errors.ZrmError.AtLeastOneValueRequired;
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
			const sqlBuf = try self.arena.allocator().alloc(u8, fixedSqlSize + valuesSqlSize + returningSize);

			// Append initial "INSERT INTO table VALUES ".
			@memcpy(sqlBuf[0..sqlBase.len],sqlBase);
			var sqlBufCursor: usize = sqlBase.len;

			// Start parameter counter at 1.
			var currentParameter: usize = 1;

			if (self.insertConfig.values.len == 0) {
				// No values, output an empty values set.
				std.mem.copyForwards(u8, sqlBuf[sqlBufCursor..sqlBufCursor+2], "()");
				sqlBufCursor += 2;
			} else {
				// Build values set.
				for (self.insertConfig.values) |_| {
					// Add the first '('.
					sqlBuf[sqlBufCursor] = '('; sqlBufCursor += 1;
					inline for (columns) |_| {
						// Create the parameter string and append it to the SQL buffer.
						const paramSize = 1 + try _sql.computeRequiredSpaceForParameter(currentParameter) + 1;
						_ = try std.fmt.bufPrint(sqlBuf[sqlBufCursor..sqlBufCursor+paramSize], "${d},", .{currentParameter});
						sqlBufCursor += paramSize;
						// Increment parameter count.
						currentParameter += 1;
					}
					// Replace the final ',' with a ')'.
					sqlBuf[sqlBufCursor - 1] = ')';
					// Add the final ','.
					sqlBuf[sqlBufCursor] = ','; sqlBufCursor += 1;
				}
				sqlBufCursor -= 1;
			}

			// Append RETURNING clause, if there is one defined.
			if (self.insertConfig.returning) |_returning| {
				@memcpy(sqlBuf[sqlBufCursor..sqlBufCursor+(1 + returningClause.len + 1)], " " ++ returningClause ++ " ");
				// Copy RETURNING clause content and replace parameters, if there are some.
				try _sql.copyAndReplaceSqlParameters(&currentParameter,
					_returning.params.len,
					sqlBuf[sqlBufCursor+(1+returningClause.len+1)..sqlBufCursor+returningSize], _returning.sql
				);
				sqlBufCursor += returningSize;
			}

			// ";" to end the query.
			sqlBuf[sqlBufCursor] = ';'; sqlBufCursor += 1;

			// Save built SQL query.
			self.sql = sqlBuf;
		}

		/// Execute the insert query.
		fn execQuery(self: *Self) !*pg.Result {
			// Get a connection to the database.
			const connection = try self.database.acquire();
			errdefer connection.release();

			// Initialize a new PostgreSQL statement.
			var statement = try pg.Stmt.init(connection, .{
				.column_names = true,
				.release_conn = true,
				.allocator = self.arena.allocator(),
			});
			errdefer statement.deinit();

			// Prepare SQL insert query.
			statement.prepare(self.sql.?)
				catch |err| return postgresql.handlePostgresqlError(err, connection, &statement);

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
				catch |err| return postgresql.handlePostgresqlError(err, connection, &statement);

			// Query executed successfully, return the result.
			return result;
		}

		/// Insert given models.
		pub fn insert(self: *Self, allocator: std.mem.Allocator) !repository.RepositoryResult(Model) {
			// Build SQL query if it wasn't built.
			if (self.sql) |_| {} else { try self.buildSql(); }

			// Execute query and get its result.
			const queryResult = try self.execQuery();

			//TODO deduplicate this in postgresql.zig, we could do it if Mapper type was exposed.
			//TODO make a generic mapper and do it in repository.zig?
			// Create an arena for mapper data.
			var mapperArena = std.heap.ArenaAllocator.init(allocator);
			// Get result mapper.
			const mapper = queryResult.mapper(TableShape, .{ .allocator = mapperArena.allocator() });

			// Initialize models list.
			var models = std.ArrayList(*Model).init(allocator);
			defer models.deinit();

			// Get all raw models from the result mapper.
			while (try mapper.next()) |rawModel| {
				// Parse each raw model from the mapper.
				const model = try allocator.create(Model);
				model.* = try repositoryConfig.fromSql(rawModel);
				try models.append(model);
			}

			// Return a result with the models.
			return repository.RepositoryResult(Model).init(allocator,
				zollections.Collection(Model).init(allocator, try models.toOwnedSlice()),
				mapperArena,
			);
		}

		/// Initialize a new repository insert query.
		pub fn init(allocator: std.mem.Allocator, database: *pg.Pool) Self {
			return .{
				// Initialize an arena allocator for the insert query.
				.arena = std.heap.ArenaAllocator.init(allocator),
				.database = database,
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
