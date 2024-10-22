const std = @import("std");
const pg = @import("pg");
const zollections = @import("zollections");
const errors = @import("errors.zig");
const database = @import("database.zig");
const postgresql = @import("postgresql.zig");
const _sql = @import("sql.zig");
const conditions = @import("conditions.zig");
const repository = @import("repository.zig");

/// Repository update query configuration structure.
pub fn RepositoryUpdateConfiguration(comptime UpdateShape: type) type {
	return struct {
		value: ?UpdateShape = null,
		where: ?_sql.SqlParams = null,
		returning: ?_sql.SqlParams = null,
	};
}

/// Repository models update manager.
/// Manage update query string build and execution.
pub fn RepositoryUpdate(comptime Model: type, comptime TableShape: type, comptime repositoryConfig: repository.RepositoryConfiguration(Model, TableShape), comptime UpdateShape: type) type {
	// Create columns list.
	const columns = comptime columnsFinder: {
		// Get update shape type data.
		const updateType = @typeInfo(UpdateShape);
		// Initialize a columns slice of "fields len" size.
		var columnsList: [updateType.Struct.fields.len][]const u8 = undefined;

		// Add structure fields to the columns slice.
		var i: usize = 0;
		for (updateType.Struct.fields) |field| {
			// Check that the table type defines the same fields.
			if (!@hasField(TableShape, field.name))
				//TODO check its type?
				@compileError("The table doesn't contain the indicated updated columns.");

			// Add each structure field to columns list.
			columnsList[i] = field.name;
			i += 1;
		}

		// Assign built columns list.
		break :columnsFinder columnsList;
	};

	// Pre-compute SQL buffer size.
	const sqlBase = "UPDATE " ++ repositoryConfig.table ++ " SET ";
	const whereClause = "WHERE";
	const returningClause = "RETURNING";

	// UPDATE {repositoryConfig.table} SET ?;
	const fixedSqlSize = sqlBase.len + 0 + 1;

	return struct {
		const Self = @This();

		const Configuration = RepositoryUpdateConfiguration(UpdateShape);

		arena: std.heap.ArenaAllocator,
		connector: database.Connector,
		connection: *database.Connection = undefined,
		updateConfig: Configuration,

		sql: ?[]const u8 = null,

		/// Parse given model or shape and put the result in newUpdate.
		fn parseData(newUpdate: *UpdateShape, _value: anytype) !void {
			// If the given value is a model, first convert it to its SQL equivalent.
			if (@TypeOf(_value) == Model) {
				return parseData(newUpdate, try repositoryConfig.toSql(_value));
			}

			inline for (columns) |column| {
				// Assign every given value to the update shape.
				@field(newUpdate.*, column) = @field(_value, column);
			}
		}

		/// Parse one "updates value".
		fn parseOne(self: *Self, _value: anytype) !void {
			const newUpdate = try self.arena.allocator().create(UpdateShape);
			try parseData(newUpdate, _value);
			self.updateConfig.value = newUpdate.*;
		}

		/// Set updated values.
		/// Values can be Model, TableShape or UpdateShape.
		pub fn set(self: *Self, _value: anytype) !void {
			// Get value type.
			const valueType = @TypeOf(_value);

			switch (@typeInfo(valueType)) {
				.Pointer => |ptr| {
					switch (ptr.size) {
						// It's a single object.
						.One => switch (@typeInfo(ptr.child)) {
							// It's a structure, parse it.
							.Struct => try self.parseOne(_value.*),
							// It's not a structure: cannot parse it.
							else => @compileError("Cannot set update value of type " ++ @typeName(ptr.child)),
						},
						// It's not a single object: cannot parse it.
						else => @compileError("Cannot set update value of type " ++ @typeName(ptr.child)),
					}
				},
				// It's a structure, just parse it.
				.Struct => try self.parseOne(_value),

				// It's not a structure nor a pointer to a structure: cannot parse it.
				else => @compileError("Cannot set update value of type " ++ @typeName(valueType)),
			}
		}

		/// Set WHERE conditions.
		pub fn where(self: *Self, _where: _sql.SqlParams) void {
			self.updateConfig.where = _where;
		}

		/// Create a new condition builder.
		pub fn newCondition(self: *Self) conditions.Builder {
			return conditions.Builder.init(self.arena.allocator());
		}

		/// Set a WHERE value condition.
		pub fn whereValue(self: *Self, comptime ValueType: type, comptime _column: []const u8, comptime operator: []const u8, _value: ValueType) !void {
			self.where(
				try conditions.value(ValueType, self.arena.allocator(), _column, operator, _value)
			);
		}

		/// Set a WHERE column condition.
		pub fn whereColumn(self: *Self, comptime _column: []const u8, comptime operator: []const u8, comptime _valueColumn: []const u8) !void {
			self.where(
				try conditions.column(self.arena.allocator(), _column, operator, _valueColumn)
			);
		}

		/// Set a WHERE IN condition.
		pub fn whereIn(self: *Self, comptime ValueType: type, comptime _column: []const u8, _value: []const ValueType) !void {
			self.where(
				try conditions.in(ValueType, self.arena.allocator(), _column, _value)
			);
		}

		/// Set selected columns for RETURNING clause.
		pub fn returning(self: *Self, _select: _sql.SqlParams) void {
			self.updateConfig.returning = _select;
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

		/// Set RETURNING all columns of the table after update.
		pub fn returningAll(self: *Self) void {
			self.returning(.{
				.sql = "*",
				.params = &[_]_sql.QueryParameter{}, // No parameters.
			});
		}

		/// Build SQL query.
		pub fn buildSql(self: *Self) !void {
			if (self.updateConfig.value) |_| {} else {
				// Updated values must be set.
				return errors.ZrmError.UpdatedValuesRequired;
			}

			// Start parameter counter at 1.
			var currentParameter: usize = 1;

			// Compute SET values size.
			var setSize: usize = 0;
			inline for (columns) |column| {
				// Compute size of each column value assignment.
				setSize += column.len + 1 + 1 + try _sql.computeRequiredSpaceForParameter(currentParameter) + 1;
				currentParameter += 1;
			}
			setSize -= 1; // The last ',' can be overwritten.

			// Compute WHERE size.
			var whereSize: usize = 0;
			if (self.updateConfig.where) |_where| {
				whereSize = 1 + whereClause.len + 1 + _where.sql.len + _sql.computeRequiredSpaceForParametersNumbers(_where.params.len, currentParameter - 1);
				currentParameter += _where.params.len;
			}

			// Compute RETURNING size.
			var returningSize: usize = 0;
			if (self.updateConfig.returning) |_returning| {
				returningSize = 1 + returningClause.len + _returning.sql.len + 1 + _sql.computeRequiredSpaceForParametersNumbers(_returning.params.len, currentParameter - 1);
				currentParameter += _returning.params.len;
			}

			// Allocate SQL buffer from computed size.
			const sqlBuf = try self.arena.allocator().alloc(u8, fixedSqlSize
				+ (setSize)
				+ (whereSize)
				+ (returningSize)
			);

			// Fill SQL buffer.

			// Restart parameter counter at 1.
			currentParameter = 1;

			// SQL query initialisation.
			@memcpy(sqlBuf[0..sqlBase.len], sqlBase);
			var sqlBufCursor: usize = sqlBase.len;

			// Add SET columns values.
			inline for (columns) |column| {
				// Create the SET string and append it to the SQL buffer.
				const setColumnSize = column.len + 1 + 1 + try _sql.computeRequiredSpaceForParameter(currentParameter) + 1;
				_ = try std.fmt.bufPrint(sqlBuf[sqlBufCursor..sqlBufCursor+setColumnSize], "{s}=${d},", .{column, currentParameter});
				sqlBufCursor += setColumnSize;
				// Increment parameter count.
				currentParameter += 1;
			}

			// Overwrite the last ','.
			sqlBufCursor -= 1;

			// WHERE clause.
			if (self.updateConfig.where) |_where| {
				@memcpy(sqlBuf[sqlBufCursor..sqlBufCursor+(1 + whereClause.len + 1)], " " ++ whereClause ++ " ");
				// Copy WHERE clause content and replace parameters, if there are some.
				try _sql.copyAndReplaceSqlParameters(&currentParameter,
					_where.params.len,
					sqlBuf[sqlBufCursor+(1+whereClause.len+1)..sqlBufCursor+whereSize], _where.sql
				);
				sqlBufCursor += whereSize;
			}

			// Append RETURNING clause, if there is one defined.
			if (self.updateConfig.returning) |_returning| {
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

		/// Execute the update query.
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

			// Prepare SQL update query.
			statement.prepare(self.sql.?)
				catch |err| return postgresql.handlePostgresqlError(err, self.connection, &statement);

			// Bind UPDATE query parameters.
			inline for (columns) |column| {
				try statement.bind(@field(self.updateConfig.value.?, column));
			}
			// Bind WHERE query parameters.
			if (self.updateConfig.where) |_where| {
				try postgresql.bindQueryParameters(&statement,  _where.params);
			}
			// Bind RETURNING query parameters.
			if (self.updateConfig.returning) |_returning| {
				try postgresql.bindQueryParameters(&statement,  _returning.params);
			}

			// Execute the query and get its result.
			const result = statement.execute()
				catch |err| return postgresql.handlePostgresqlError(err, self.connection, &statement);

			// Query executed successfully, return the result.
			return result;
		}

		/// Update given models.
		pub fn update(self: *Self, allocator: std.mem.Allocator) !repository.RepositoryResult(Model) {
			// Build SQL query if it wasn't built.
			if (self.sql) |_| {} else { try self.buildSql(); }

			// Execute query and get its result.
			var queryResult = try self.execQuery();
			defer self.connection.release();
			defer queryResult.deinit();

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

		/// Initialize a new repository update query.
		pub fn init(allocator: std.mem.Allocator, connector: database.Connector) Self {
			return .{
				// Initialize an arena allocator for the update query.
				.arena = std.heap.ArenaAllocator.init(allocator),
				.connector = connector,
				.updateConfig = .{},
			};
		}

		/// Deinitialize the repository update query.
		pub fn deinit(self: *Self) void {
			// Free everything allocated for this update query.
			self.arena.deinit();
		}
	};
}
