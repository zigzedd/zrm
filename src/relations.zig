const std = @import("std");
const pg = @import("pg");
const _database = @import("database.zig");
const _sql = @import("sql.zig");
const repository = @import("repository.zig");
const _query = @import("query.zig");

/// Configure a "one to many" or "many to many" relation.
pub const ManyConfiguration = union(enum) {
	/// Direct one-to-many relation using a distant foreign key.
	direct: struct {
		/// The distant foreign key name pointing to the current model.
		foreignKey: []const u8,
		/// Current model key name.
		/// Use the default key name of the current model.
		modelKey: ?[]const u8 = null,
	},

	/// Used when performing a many-to-many relation through an association table.
	through: struct {
		/// Name of the join table.
		table: []const u8,
		/// The local foreign key name.
		/// Use the default key name of the current model.
		foreignKey: ?[]const u8 = null,
		/// The foreign key name in the join table.
		joinForeignKey: []const u8,
		/// The model key name in the join table.
		joinModelKey: []const u8,
		/// Associated model key name.
		/// Use the default key name of the associated model.
		modelKey: ?[]const u8 = null,
	},
};

/// Make a "one to many" or "many to many" relation.
pub fn many(comptime fromRepo: anytype, comptime toRepo: anytype, comptime config: ManyConfiguration) type {
	return typedMany(
		fromRepo.ModelType, fromRepo.TableType, fromRepo.config,
		toRepo.ModelType, toRepo.TableType, toRepo.config,
		config,
	);
}

/// Internal implementation of a new "one to many" or "many to many" relation.
pub fn typedMany(
	comptime FromModel: type, comptime FromTable: type,
	comptime fromRepositoryConfig: repository.RepositoryConfiguration(FromModel, FromTable),
	comptime ToModel: type, comptime ToTable: type,
	comptime toRepositoryConfig: repository.RepositoryConfiguration(ToModel, ToTable),
	comptime config: ManyConfiguration) type {

	return struct {
		/// Relation implementation.
		pub fn Implementation(field: []const u8) type {
			// Get foreign key from relation config or repository config.
			const foreignKey = switch (config) {
				.direct => |direct| direct.foreignKey,
				.through => |through| if (through.foreignKey) |_foreignKey| _foreignKey else toRepositoryConfig.key[0],
			};

			// Get model key from relation config or repository config.
			const modelKey = switch (config) {
				.direct => |direct| if (direct.modelKey) |_modelKey| _modelKey else fromRepositoryConfig.key[0],
				.through => |through| if (through.modelKey) |_modelKey| _modelKey else fromRepositoryConfig.key[0],
			};
			_ = modelKey;

			const FromKeyType = std.meta.fields(FromModel)[std.meta.fieldIndex(FromModel, fromRepositoryConfig.key[0]).?].type;
			const QueryType = _query.RepositoryQuery(ToModel, ToTable, toRepositoryConfig, null, struct {
				__zrm_relation_key: FromKeyType,
			});

			const alias = "relations." ++ field;
			const prefix = alias ++ ".";

			return struct {
				const Self = @This();

				fn genSelect() []const u8 {
					return _sql.SelectBuild(ToTable, alias, prefix);
				}

				fn buildQuery(opaqueModels: []const *anyopaque, allocator: std.mem.Allocator, connector: _database.Connector) !*anyopaque {
					const models: []const *FromModel = @ptrCast(@alignCast(opaqueModels));

					// Initialize the query to build.
					const query: *QueryType = try allocator.create(QueryType);
					errdefer allocator.destroy(query);
					query.* = QueryType.init(allocator, connector, .{});
					errdefer query.deinit();

					// Build base SELECT.
					const baseSelect = comptime _sql.SelectBuild(ToTable, toRepositoryConfig.table, "");

					// Prepare given models IDs.
					const modelsIds = try query.arena.allocator().alloc(FromKeyType, models.len);
					for (models, modelsIds) |model, *modelId| {
						modelId.* = @field(model, fromRepositoryConfig.key[0]);
					}

					switch (config) {
						.direct => {
							// Add SELECT.
							query.select(.{
								.sql = baseSelect ++ ", \"" ++ toRepositoryConfig.table ++ "\".\"" ++ foreignKey ++ "\" AS \"__zrm_relation_key\"",
								.params = &[0]_sql.RawQueryParameter{},
							});

							// Build WHERE condition.
							try query.whereIn(FromKeyType, "\"" ++ toRepositoryConfig.table ++ "\".\"" ++ foreignKey ++ "\"", modelsIds);
						},
						.through => |through| {
							// Add SELECT.
							query.select(.{
								.sql = baseSelect ++ ", \"" ++ prefix ++ "pivot" ++ "\".\"" ++ through.joinModelKey ++ "\" AS \"__zrm_relation_key\"",
								.params = &[0]_sql.RawQueryParameter{},
							});

							query.join(.{
								.sql = "INNER JOIN \"" ++ through.table ++ "\" AS \"" ++ prefix ++ "pivot" ++ "\" " ++
									"ON \"" ++ toRepositoryConfig.table ++ "\"." ++ foreignKey ++ " = " ++ "\"" ++ prefix ++ "pivot" ++ "\"." ++ through.joinForeignKey,
								.params = &[0]_sql.RawQueryParameter{},
							});

							// Build WHERE condition.
							try query.whereIn(FromKeyType, "\"" ++ prefix ++ "pivot" ++ "\".\"" ++ through.joinModelKey ++ "\"", modelsIds);
						},
					}

					return query; // Return built query.
				}

				/// Build the "many" generic relation.
				pub fn relation(_: Self) Relation {
					return .{
						._interface = .{
							.repositoryConfiguration = &toRepositoryConfig,

							.buildQuery = buildQuery,
						},
						.Model = ToModel,
						.TableShape = ToTable,
						.field = field,
						.alias = alias,
						.prefix = prefix,
						.QueryType = QueryType,

						.inlineMapping = false,
						.join = undefined,
						.select = genSelect(),
					};
				}
			};
		}
	};
}


/// Configure a "one to one" relation.
pub const OneConfiguration = union(enum) {
	/// Direct one-to-one relation using a local foreign key.
	direct: struct {
		/// The local foreign key name.
		foreignKey: []const u8,
		/// Associated model key name.
		/// Use the default key name of the associated model.
		modelKey: ?[]const u8 = null,
	},

	/// Reverse one-to-one relation using distant foreign key.
	reverse: struct {
		/// The distant foreign key name.
		foreignKey: []const u8,
		/// Current model key name.
		/// Use the default key name of the current model.
		modelKey: ?[]const u8 = null,
	},

	/// Used when performing a one-to-one relation through an association table.
	through: struct {
		/// Name of the join table.
		table: []const u8,
		/// The local foreign key name.
		/// Use the default key name of the current model.
		foreignKey: ?[]const u8 = null,
		/// The foreign key name in the join table.
		joinForeignKey: []const u8,
		/// The model key name in the join table.
		joinModelKey: []const u8,
		/// Associated model key name.
		/// Use the default key name of the associated model.
		modelKey: ?[]const u8 = null,
	},
};

/// Make a "one to one" relation.
pub fn one(comptime fromRepo: anytype, comptime toRepo: anytype, comptime config: OneConfiguration) type {
	return typedOne(
		fromRepo.ModelType, fromRepo.TableType, fromRepo.config,
		toRepo.ModelType, toRepo.TableType, toRepo.config,
		config,
	);
}

/// Internal implementation of a new "one to one" relation.
fn typedOne(
	comptime FromModel: type, comptime FromTable: type,
	comptime fromRepositoryConfig: repository.RepositoryConfiguration(FromModel, FromTable),
	comptime ToModel: type, comptime ToTable: type,
	comptime toRepositoryConfig: repository.RepositoryConfiguration(ToModel, ToTable),
	comptime config: OneConfiguration) type {

	return struct {
		pub fn Implementation(field: []const u8) type {
			const FromKeyType = std.meta.fields(FromModel)[std.meta.fieldIndex(FromModel, fromRepositoryConfig.key[0]).?].type;
			const QueryType = _query.RepositoryQuery(ToModel, ToTable, toRepositoryConfig, null, struct {
				__zrm_relation_key: FromKeyType,
			});

			// Get foreign key from relation config or repository config.
			const foreignKey = switch (config) {
				.direct => |direct| direct.foreignKey,
				.reverse => |reverse| reverse.foreignKey,
				.through => |through| if (through.foreignKey) |_foreignKey| _foreignKey else fromRepositoryConfig.key[0],
			};

			// Get model key from relation config or repository config.
			const modelKey = switch (config) {
				.direct => |direct| if (direct.modelKey) |_modelKey| _modelKey else toRepositoryConfig.key[0],
				.reverse => |reverse| if (reverse.modelKey) |_modelKey| _modelKey else toRepositoryConfig.key[0],
				.through => |through| if (through.modelKey) |_modelKey| _modelKey else toRepositoryConfig.key[0],
			};

			const alias = "relations." ++ field;
			const prefix = alias ++ ".";

			return struct {
				const Self = @This();

				fn genJoin() []const u8 {
					return switch (config) {
						.direct => (
							"LEFT JOIN \"" ++ toRepositoryConfig.table ++ "\" AS \"" ++ alias ++ "\" ON " ++
								"\"" ++ fromRepositoryConfig.table ++ "\".\"" ++ foreignKey ++ "\" = \"" ++ alias ++ "\".\"" ++ modelKey ++ "\""
						),

						.reverse => (
							"LEFT JOIN \"" ++ toRepositoryConfig.table ++ "\" AS \"" ++ alias ++ "\" ON " ++
								"\"" ++ fromRepositoryConfig.table ++ "\".\"" ++ modelKey ++ "\" = \"" ++ alias ++ "\".\"" ++ foreignKey ++ "\""
						),

						.through => |through| (
							"LEFT JOIN \"" ++ through.table ++ "\" AS \"" ++ alias ++ "_pivot\" ON " ++
								"\"" ++ fromRepositoryConfig.table ++ "\".\"" ++ foreignKey ++ "\" = " ++ "\"" ++ alias ++ "_pivot\".\"" ++ through.joinForeignKey ++ "\"" ++
							" LEFT JOIN \"" ++ toRepositoryConfig.table ++ "\" AS \"" ++ alias ++ "\" ON " ++
								"\"" ++ alias ++ "_pivot\".\"" ++ through.joinModelKey ++ "\" = " ++ "\"" ++ alias ++ "\".\"" ++ modelKey ++ "\""
						),
					};
				}

				fn genSelect() []const u8 {
					return _sql.SelectBuild(ToTable, alias, prefix);
				}

				fn buildQuery(opaqueModels: []const *anyopaque, allocator: std.mem.Allocator, connector: _database.Connector) !*anyopaque {
					const models: []const *FromModel = @ptrCast(@alignCast(opaqueModels));

					// Initialize the query to build.
					const query: *QueryType = try allocator.create(QueryType);
					errdefer allocator.destroy(query);
					query.* = QueryType.init(allocator, connector, .{});
					errdefer query.deinit();

					// Build base SELECT.
					const baseSelect = comptime _sql.SelectBuild(ToTable, toRepositoryConfig.table, "");

					// Prepare given models IDs.
					const modelsIds = try query.arena.allocator().alloc(FromKeyType, models.len);
					for (models, modelsIds) |model, *modelId| {
						modelId.* = @field(model, fromRepositoryConfig.key[0]);
					}

					switch (config) {
						.direct => {
							// Add SELECT.
							query.select(.{
								.sql = baseSelect ++ ", \"" ++ fromRepositoryConfig.table ++ "\".\"" ++ fromRepositoryConfig.key[0] ++ "\" AS \"__zrm_relation_key\"",
								.params = &[0]_sql.RawQueryParameter{},
							});

							query.join((_sql.RawQuery{
								.sql = "INNER JOIN \"" ++ fromRepositoryConfig.table ++ "\" AS \"" ++ prefix ++ "related" ++ "\" ON " ++
									"\"" ++ toRepositoryConfig.table ++ "\"." ++ modelKey ++ " = \"" ++ prefix ++ "related" ++ "\"." ++ foreignKey,
								.params = &[0]_sql.RawQueryParameter{},
							}));

							// Build WHERE condition.
							try query.whereIn(FromKeyType, "\"" ++ fromRepositoryConfig.table ++ "\".\"" ++ fromRepositoryConfig.key[0] ++ "\"", modelsIds);
						},
						.reverse => {
							// Add SELECT.
							query.select(.{
								.sql = baseSelect ++ ", \"" ++ toRepositoryConfig.table ++ "\".\"" ++ foreignKey ++ "\" AS \"__zrm_relation_key\"",
								.params = &[0]_sql.RawQueryParameter{},
							});

							// Build WHERE condition.
							try query.whereIn(FromKeyType, "\"" ++ toRepositoryConfig.table ++ "\".\"" ++ foreignKey ++ "\"", modelsIds);
						},
						.through => |through| {
							// Add SELECT.
							query.select(.{
								.sql = baseSelect ++ ", \"" ++ prefix ++ "pivot" ++ "\".\"" ++ through.joinForeignKey ++ "\" AS \"__zrm_relation_key\"",
								.params = &[0]_sql.RawQueryParameter{},
							});

							query.join(.{
								.sql = "INNER JOIN \"" ++ through.table ++ "\" AS \"" ++ prefix ++ "pivot" ++ "\" ON " ++
									"\"" ++ toRepositoryConfig.table ++ "\"." ++ modelKey ++ " = " ++ "\"" ++ prefix ++ "pivot" ++ "\"." ++ through.joinModelKey,
								.params = &[0]_sql.RawQueryParameter{},
							});

							// Build WHERE condition.
							try query.whereIn(FromKeyType, "\"" ++ prefix ++ "pivot" ++ "\".\"" ++ through.joinForeignKey ++ "\"", modelsIds);
						},
					}

					// Return built query.
					return query;
				}

				/// Build the "one" generic relation.
				pub fn relation(_: Self) Relation {
					return .{
						._interface = .{
							.repositoryConfiguration = &toRepositoryConfig,

							.buildQuery = buildQuery,
						},
						.Model = ToModel,
						.TableShape = ToTable,
						.field = field,
						.alias = alias,
						.prefix = prefix,
						.QueryType = QueryType,

						.inlineMapping = true,
						.join = genJoin(),
						.select = genSelect(),
					};
				}
			};
		}
	};
}

/// Generic model relation interface.
pub const Relation = struct {
	const Self = @This();

	_interface: struct {
		repositoryConfiguration: *const anyopaque,

		buildQuery: *const fn (models: []const *anyopaque, allocator: std.mem.Allocator, connector: _database.Connector) anyerror!*anyopaque,
	},

	/// Type of the related model.
	Model: type,
	/// Type of the related model table.
	TableShape: type,
	/// Field where to put the related model(s).
	field: []const u8,
	/// Table alias of the relation.
	alias: []const u8,
	/// Prefix of fields of the relation.
	prefix: []const u8,
	/// Type of a query of the related models.
	QueryType: type,

	/// Set if relation mapping is done inline: this means that it's done at the same time the model is mapped,
	/// and that the associated data will be retrieved in the main query.
	inlineMapping: bool,
	/// In case of inline mapping, the JOIN clause to retrieve the associated data.
	join: []const u8,
	/// The SELECT clause to retrieve the associated data.
	select: []const u8,

	/// Build the query to retrieve relation data.
	/// Is always used when inline mapping is not possible, but also when loading relations lazily.
	pub fn buildQuery(self: Self, models: []const *anyopaque, allocator: std.mem.Allocator, connector: _database.Connector) !*anyopaque {
		return self._interface.buildQuery(models, allocator, connector);
	}

	/// Get typed repository configuration for the related model.
	pub fn repositoryConfiguration(self: Self) repository.RepositoryConfiguration(self.Model, self.TableShape) {
		const repoConfig: *const repository.RepositoryConfiguration(self.Model, self.TableShape)
			= @ptrCast(@alignCast(self._interface.repositoryConfiguration));
		return repoConfig.*;
	}
};


/// Structure of an eager loaded relation.
pub const Eager = struct {
	/// The relation to eager load.
	relation: Relation,
	/// Subrelations to eager load.
	with: []const Eager,
};
