const std = @import("std");
const pg = @import("pg");
const zollections = @import("zollections");
const errors = @import("errors.zig");
const database = @import("database.zig");
const postgresql = @import("postgresql.zig");
const _sql = @import("sql.zig");
const _conditions = @import("conditions.zig");
const relations = @import("relations.zig");
const repository = @import("repository.zig");
const _comptime = @import("comptime.zig");
const _result = @import("result.zig");

/// Repository query configuration structure.
pub const RepositoryQueryConfiguration = struct {
	select: ?_sql.RawQuery = null,
	join: ?_sql.RawQuery = null,
	where: ?_sql.RawQuery = null,
};

/// Compiled relations structure.
const CompiledRelations = struct {
	inlineRelations: []relations.ModelRelation,
	otherRelations: []relations.ModelRelation,
	inlineSelect: []const u8,
	inlineJoins: []const u8,
};

/// Repository models query manager.
/// Manage query string build and its execution.
pub fn RepositoryQuery(comptime Model: type, comptime TableShape: type, comptime repositoryConfig: repository.RepositoryConfiguration(Model, TableShape), comptime with: ?[]const relations.ModelRelation) type {
	const compiledRelations = comptime compile: {
		// Inline relations list.
		var inlineRelations: []relations.ModelRelation = &[0]relations.ModelRelation{};

		if (with) |_with| {
			// If there are relations to eager load, prepare their query.

			// Initialize inline select array.
			var inlineSelect: [][]const u8 = &[0][]const u8{};
			// Initialize inline joins array.
			var inlineJoins: [][]const u8 = &[0][]const u8{};

			for (_with) |relation| {
				// For each relation, determine if it's inline or not.
				var relationImpl = relation.relation{};
				const relationInstance = relationImpl.relation();
				if (relationInstance.inlineMapping()) {
					// Add the current relation to inline relations.
					inlineRelations = @ptrCast(@constCast(_comptime.append(inlineRelations, relation)));

					// Build table alias and fields prefix for the relation.
					const tableAlias = "relations." ++ relation.field;
					const fieldsPrefix = tableAlias ++ ".";

					// Generate selected columns for the relation.
					inlineSelect = @ptrCast(@constCast(_comptime.append(inlineSelect, relationInstance.genSelect(tableAlias, fieldsPrefix))));
					// Generate joined table for the relation.
					inlineJoins = @ptrCast(@constCast(_comptime.append(inlineJoins, relationInstance.genJoin(tableAlias))));
				}
			}

			break :compile CompiledRelations{
				.inlineRelations = inlineRelations,
				.otherRelations = &[0]relations.ModelRelation{},
				.inlineSelect = if (inlineSelect.len > 0) ", " ++ _comptime.join(", ", inlineSelect) else "",
				.inlineJoins = if (inlineJoins.len > 0) " " ++ _comptime.join(" ", inlineJoins) else "",
			};
		} else {
			break :compile CompiledRelations{
				.inlineRelations = &[0]relations.ModelRelation{},
				.otherRelations = &[0]relations.ModelRelation{},
				.inlineSelect = "",
				.inlineJoins = "",
			};
		}
	};

	// Pre-compute SQL buffer.
	const fromClause = " FROM \"" ++ repositoryConfig.table ++ "\"";
	const defaultSelectSql = "\"" ++ repositoryConfig.table ++ "\".*" ++ compiledRelations.inlineSelect;
	const defaultJoin = compiledRelations.inlineJoins;

	// Model key type.
	const KeyType = repository.ModelKeyType(Model, TableShape, repositoryConfig);

	return struct {
		const Self = @This();

		/// Result mapper type.
		pub const ResultMapper = _result.ResultMapper(Model, TableShape, repositoryConfig, compiledRelations.inlineRelations, compiledRelations.otherRelations);

		arena: std.heap.ArenaAllocator,
		connector: database.Connector,
		connection: *database.Connection = undefined,
		queryConfig: RepositoryQueryConfiguration,

		query: ?_sql.RawQuery = null,
		sql: ?[]const u8 = null,

		/// Set selected columns.
		pub fn select(self: *Self, _select: _sql.RawQuery) void {
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
				.params = &[_]_sql.RawQueryParameter{}, // No parameters.
			});
		}

		/// Set JOIN clause.
		pub fn join(self: *Self, _join: _sql.RawQuery) void {
			self.queryConfig.join = _join;
		}

		/// Set WHERE conditions.
		pub fn where(self: *Self, _where: _sql.RawQuery) void {
			self.queryConfig.where = _where;
		}

		/// Create a new condition builder.
		pub fn newCondition(self: *Self) _conditions.Builder {
			return _conditions.Builder.init(self.arena.allocator());
		}

		/// Set a WHERE value condition.
		pub fn whereValue(self: *Self, comptime ValueType: type, comptime _column: []const u8, comptime operator: []const u8, _value: ValueType) !void {
			self.where(
				try _conditions.value(ValueType, self.arena.allocator(), _column, operator, _value)
			);
		}

		/// Set a WHERE column condition.
		pub fn whereColumn(self: *Self, comptime _column: []const u8, comptime operator: []const u8, comptime _valueColumn: []const u8) !void {
			self.where(
				try _conditions.column(self.arena.allocator(), _column, operator, _valueColumn)
			);
		}

		/// Set a WHERE IN condition.
		pub fn whereIn(self: *Self, comptime ValueType: type, comptime _column: []const u8, _value: []const ValueType) !void {
			self.where(
				try _conditions.in(ValueType, self.arena.allocator(), _column, _value)
			);
		}

		/// Set a WHERE from model key(s).
		/// For simple keys: modelKey type must match the type of its corresponding field.
		/// modelKey can be an array / slice of keys.
		/// For composite keys: modelKey must be a struct with all the keys, matching the type of their corresponding field.
		/// modelKey can be an array / slice of these structs.
		pub fn whereKey(self: *Self, modelKey: anytype) !void {
			if (repositoryConfig.key.len == 1) {
				// Find key name and its type.
				const keyName = repositoryConfig.key[0];
				const keyType = std.meta.fields(TableShape)[std.meta.fieldIndex(TableShape, keyName).?].type;

				// Accept arrays / slices of keys, and simple keys.
				switch (@typeInfo(@TypeOf(modelKey))) {
					.Pointer => |ptr| {
						switch (ptr.size) {
							.One => {
								switch (@typeInfo(ptr.child)) {
									// Add a whereIn with the array.
									.Array => {
										if (ptr.child == u8)
											// If the child is a string, use it as a simple value.
											try self.whereValue(KeyType, keyName, "=", modelKey)
										else
											// Otherwise, use it as an array.
											try self.whereIn(keyType, keyName, modelKey);
									},
									// Add a simple condition with the pointed value.
									else => try self.whereValue(keyType, keyName, "=", modelKey.*),
								}
							},
							// Add a whereIn with the slice.
							else => {
								if (ptr.child == u8)
									// If the child is a string, use it as a simple value.
									try self.whereValue(KeyType, keyName, "=", modelKey)
								else
									// Otherwise, use it as an array.
									try self.whereIn(keyType, keyName, modelKey);
							},
						}
					},
					// Add a simple condition with the given value.
					else => try self.whereValue(keyType, keyName, "=", modelKey),
				}
			} else {
				// Accept arrays / slices of keys, and simple keys.
				// Uniformize modelKey parameter to a slice.
				const modelKeysList: []const KeyType = switch (@typeInfo(@TypeOf(modelKey))) {
					.Pointer => |ptr| switch (ptr.size) {
						.One => switch (@typeInfo(ptr.child)) {
							// Already an array.
							.Array => @as([]const KeyType, modelKey),
							// Convert the pointer to an array.
							else => &[1]KeyType{@as(KeyType, modelKey.*)},
						},
						// Already a slice.
						else => @as([]const KeyType, modelKey),
					},
					// Convert the value to an array.
					else => &[1]KeyType{@as(KeyType, modelKey)},
				};

				// Initialize keys conditions list.
				const conditions: []_sql.RawQuery = try self.arena.allocator().alloc(_sql.RawQuery, modelKeysList.len);
				defer self.arena.allocator().free(conditions);

				// For each model key, add its conditions.
				for (modelKeysList, conditions) |_modelKey, *condition| {
					condition.* = try self.newCondition().@"and"(
						&try buildCompositeKeysConditions(TableShape, repositoryConfig.key, self.newCondition(), _modelKey)
					);
				}

				// Set WHERE conditions in the query with all keys conditions.
				self.where(try self.newCondition().@"or"(conditions));
			}
		}

		/// Build SQL query.
		pub fn buildSql(self: *Self) !void {
			// Build the full SQL query from all its parts.
			const sqlQuery = _sql.RawQuery{
				.sql = try std.mem.join(self.arena.allocator(), "", &[_][]const u8{
					"SELECT ", if (self.queryConfig.select) |_select| _select.sql else defaultSelectSql,
					fromClause,
					defaultJoin,
					if (self.queryConfig.join) |_| " " else "",
					if (self.queryConfig.join) |_join| _join.sql else "",
					if (self.queryConfig.where) |_| " WHERE " else "",
					if (self.queryConfig.where) |_where| _where.sql else "",
					";",
				}),
				.params = try std.mem.concat(self.arena.allocator(), _sql.RawQueryParameter, &[_][]const _sql.RawQueryParameter{
					if (self.queryConfig.select) |_select| _select.params else &[0]_sql.RawQueryParameter{},
					if (self.queryConfig.join) |_join| _join.params else &[0]_sql.RawQueryParameter{},
					if (self.queryConfig.where) |_where| _where.params else &[0]_sql.RawQueryParameter{},
				})
			};

			// Save built SQL query.
			self.query = sqlQuery;
			self.sql = try sqlQuery.build(self.arena.allocator());
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
			postgresql.bindQueryParameters(&statement, self.query.?.params)
				catch |err| return postgresql.handlePostgresqlError(err, self.connection, &statement);

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

			// Map query results.
			var postgresqlReader = postgresql.QueryResultReader(TableShape, compiledRelations.inlineRelations).init(queryResult);
			return try ResultMapper.map(allocator, postgresqlReader.reader());
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

/// Build conditions for given composite keys, with a model key structure.
pub fn buildCompositeKeysConditions(comptime TableShape: type, comptime keys: []const []const u8, conditionsBuilder: _conditions.Builder, modelKey: anytype) ![keys.len]_sql.RawQuery {
	// Conditions list for all keys in the composite key.
	var conditions: [keys.len]_sql.RawQuery = undefined;

	inline for (keys, &conditions) |keyName, *condition| {
		const keyType = std.meta.fields(TableShape)[std.meta.fieldIndex(TableShape, keyName).?].type;

		if (std.meta.fieldIndex(@TypeOf(modelKey), keyName)) |_| {
			// The field exists in the key structure, create its condition.
			condition.* = try conditionsBuilder.value(keyType, keyName, "=", @field(modelKey, keyName));
		} else {
			// The field doesn't exist, compilation error.
			@compileError("The key structure must include a field for " ++ keyName);
		}
	}

	// Return conditions for the current model key.
	return conditions;
}
