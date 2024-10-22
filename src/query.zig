const std = @import("std");
const pg = @import("pg");
const zollections = @import("zollections");
const errors = @import("errors.zig");
const database = @import("database.zig");
const postgresql = @import("postgresql.zig");
const _sql = @import("sql.zig");
const conditions = @import("conditions.zig");
const repository = @import("repository.zig");

/// Repository query configuration structure.
pub const RepositoryQueryConfiguration = struct {
	select: ?_sql.SqlParams = null,
	join: ?_sql.SqlParams = null,
	where: ?_sql.SqlParams = null,
};

/// Repository models query manager.
/// Manage query string build and its execution.
pub fn RepositoryQuery(comptime Model: type, comptime TableShape: type, comptime repositoryConfig: repository.RepositoryConfiguration(Model, TableShape)) type {
	// Pre-compute SQL buffer size.
	const selectClause = "SELECT";
	const fromClause = "FROM";
	const whereClause = "WHERE";
	// SELECT ? FROM {repositoryConfig.table}??;
	const fixedSqlSize = selectClause.len + 1 + 0 + 1 + fromClause.len + 1 + repositoryConfig.table.len + 0 + 0 + 1;
	const defaultSelectSql = "*";

	return struct {
		const Self = @This();

		arena: std.heap.ArenaAllocator,
		connector: database.Connector,
		connection: *database.Connection = undefined,
		queryConfig: RepositoryQueryConfiguration,

		sql: ?[]const u8 = null,

		/// Set selected columns.
		pub fn select(self: *Self, _select: _sql.SqlParams) void {
			self.queryConfig.select = _select;
		}

		/// Set selected columns for SELECT clause.
		pub fn selectColumns(self: *Self, _select: []const []const u8) !void {
			if (_select.len == 0) {
				return errors.AtLeastOneSelectionRequired;
			}

			self.select(.{
				// Join selected columns.
				.sql = std.mem.join(self.arena.allocator(), ", ", _select),
				.params = &[_]_sql.QueryParameter{}, // No parameters.
			});
		}

		/// Set JOIN clause.
		pub fn join(self: *Self, _join: _sql.SqlParams) void {
			self.queryConfig.join = _join;
		}

		/// Set WHERE conditions.
		pub fn where(self: *Self, _where: _sql.SqlParams) void {
			self.queryConfig.where = _where;
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

		/// Build SQL query.
		pub fn buildSql(self: *Self) !void {
			// Start parameter counter at 1.
			var currentParameter: usize = 1;

			// Compute SELECT size.
			var selectSize: usize = defaultSelectSql.len;
			if (self.queryConfig.select) |_select| {
				selectSize = _select.sql.len + _sql.computeRequiredSpaceForParametersNumbers(_select.params.len, currentParameter - 1);
				currentParameter += _select.params.len;
			}

			// Compute JOIN size.
			var joinSize: usize = 0;
			if (self.queryConfig.join) |_join| {
				joinSize = 1 + _join.sql.len + _sql.computeRequiredSpaceForParametersNumbers(_join.params.len, currentParameter - 1);
				currentParameter += _join.params.len;
			}

			// Compute WHERE size.
			var whereSize: usize = 0;
			if (self.queryConfig.where) |_where| {
				whereSize = 1 + whereClause.len + _where.sql.len + 1 + _sql.computeRequiredSpaceForParametersNumbers(_where.params.len, currentParameter - 1);
				currentParameter += _where.params.len;
			}

			// Allocate SQL buffer from computed size.
			const sqlBuf = try self.arena.allocator().alloc(u8, fixedSqlSize
				+ (selectSize)
				+ (joinSize)
				+ (whereSize)
			);

			// Fill SQL buffer.

			// Restart parameter counter at 1.
			currentParameter = 1;

			// SELECT clause.
			@memcpy(sqlBuf[0..selectClause.len+1], selectClause ++ " ");
			var sqlBufCursor: usize = selectClause.len+1;

			// Copy SELECT clause content and replace parameters, if there are some.
			try _sql.copyAndReplaceSqlParameters(&currentParameter,
				if (self.queryConfig.select) |_select| _select.params.len else 0,
				sqlBuf[sqlBufCursor..sqlBufCursor+selectSize],
				if (self.queryConfig.select) |_select| _select.sql else defaultSelectSql,
			);
			sqlBufCursor += selectSize;

			// FROM clause.
			sqlBuf[sqlBufCursor] = ' '; sqlBufCursor += 1;
			std.mem.copyForwards(u8, sqlBuf[sqlBufCursor..sqlBufCursor+fromClause.len], fromClause); sqlBufCursor += fromClause.len;
			sqlBuf[sqlBufCursor] = ' '; sqlBufCursor += 1;

			// Table name.
			std.mem.copyForwards(u8, sqlBuf[sqlBufCursor..sqlBufCursor+repositoryConfig.table.len], repositoryConfig.table); sqlBufCursor += repositoryConfig.table.len;

			// JOIN clause.
			if (self.queryConfig.join) |_join| {
				sqlBuf[sqlBufCursor] = ' ';
				// Copy JOIN clause and replace parameters, if there are some.
				try _sql.copyAndReplaceSqlParameters(&currentParameter,
					_join.params.len,
					sqlBuf[sqlBufCursor+1..sqlBufCursor+joinSize], _join.sql
				);
				sqlBufCursor += joinSize;
			}

			// WHERE clause.
			if (self.queryConfig.where) |_where| {
				@memcpy(sqlBuf[sqlBufCursor..sqlBufCursor+(1 + whereClause.len + 1)], " " ++ whereClause ++ " ");
				// Copy WHERE clause content and replace parameters, if there are some.
				try _sql.copyAndReplaceSqlParameters(&currentParameter,
					_where.params.len,
					sqlBuf[sqlBufCursor+(1+whereClause.len+1)..sqlBufCursor+whereSize], _where.sql
				);
				sqlBufCursor += whereSize;
			}

			// ";" to end the query.
			sqlBuf[sqlBufCursor] = ';'; sqlBufCursor += 1;

			// Save built SQL query.
			self.sql = sqlBuf;
		}

		/// Execute the built query.
		fn execQuery(self: *Self) !*pg.Result {
			// Get the connection to the database.
			self.connection = try self.connector.getConnection();
			errdefer self.connection.release();

			// Initialize a new PostgreSQL statement.
			var statement = try pg.Stmt.init(self.connection.connection, .{
				.column_names = true,
				.allocator = self.arena.allocator(),
			});
			errdefer statement.deinit();

			// Prepare SQL query.
			statement.prepare(self.sql.?)
				catch |err| return postgresql.handlePostgresqlError(err, self.connection, &statement);

			// Bind query parameters.
			if (self.queryConfig.select) |_select|
				try postgresql.bindQueryParameters(&statement, _select.params);
			if (self.queryConfig.join) |_join|
				try postgresql.bindQueryParameters(&statement, _join.params);
			if (self.queryConfig.where) |_where|
				try postgresql.bindQueryParameters(&statement, _where.params);

			// Execute the query and get its result.
			const result = statement.execute()
				catch |err| return postgresql.handlePostgresqlError(err, self.connection, &statement);

			// Query executed successfully, return the result.
			return result;
		}

		/// Retrieve queried models.
		pub fn get(self: *Self, allocator: std.mem.Allocator) !repository.RepositoryResult(Model) {
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

		/// Initialize a new repository query.
		pub fn init(allocator: std.mem.Allocator, connector: database.Connector, queryConfig: RepositoryQueryConfiguration) Self {
			return .{
				// Initialize the query arena allocator.
				.arena = std.heap.ArenaAllocator.init(allocator),
				.connector = connector,
				.queryConfig = queryConfig,
			};
		}

		/// Deinitialize the repository query.
		pub fn deinit(self: *Self) void {
			// Free everything allocated for this query.
			self.arena.deinit();
		}
	};
}
