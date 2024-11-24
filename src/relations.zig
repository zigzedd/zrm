const std = @import("std");
const pg = @import("pg");
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

	const FromKeyType = std.meta.fields(FromModel)[std.meta.fieldIndex(FromModel, fromRepositoryConfig.key[0]).?].type;
	const QueryType = _query.RepositoryQuery(ToModel, ToTable, toRepositoryConfig, null);

	return struct {
		const Self = @This();

		fn getRepositoryConfiguration(_: *anyopaque) repository.RepositoryConfiguration(ToModel, ToTable) {
			return toRepositoryConfig;
		}

		fn inlineMapping(_: *anyopaque) bool {
			return false;
		}

		fn genJoin(_: *anyopaque, comptime _: []const u8) []const u8 {
			unreachable; // No possible join in a many relation.
		}

		fn genSelect(_: *anyopaque, comptime table: []const u8, comptime prefix: []const u8) []const u8 {
			return _sql.SelectBuild(ToTable, table, prefix);
		}

		fn buildQuery(_: *anyopaque, opaqueModels: []const anyopaque, opaqueQuery: *anyopaque) !void {
			var models: []const FromModel = undefined;
			models.len = opaqueModels.len;
			models.ptr = @ptrCast(@alignCast(opaqueModels.ptr));
			const query: *QueryType = @ptrCast(@alignCast(opaqueQuery));

			// Prepare given models IDs.
			const modelsIds = try query.arena.allocator().alloc(FromKeyType, models.len);
			for (models, modelsIds) |model, *modelId| {
				modelId.* = @field(model, fromRepositoryConfig.key[0]);
			}

			switch (config) {
				.direct => {
					// Build WHERE condition.
					try query.whereIn(FromKeyType, "\"" ++ toRepositoryConfig.table ++ "\".\"" ++ foreignKey ++ "\"", modelsIds);
				},
				.through => |through| {
					query.join(.{
						.sql = "INNER JOIN \"" ++ through.table ++ "\" ON " ++
							"\"" ++ toRepositoryConfig.table ++ "\"." ++ modelKey ++ " = " ++ "\""  ++ through.table ++ "\"." ++ through.joinModelKey,
						.params = &[0]_sql.RawQueryParameter{},
					});

					// Build WHERE condition.
					try query.whereIn(FromKeyType, "\"" ++ through.table ++ "\".\"" ++ through.joinForeignKey ++ "\"", modelsIds);
				},
			}
		}

		pub fn relation(self: *Self) Relation(ToModel, ToTable) {
			return .{
				._interface = .{
					.instance = self,

					.getRepositoryConfiguration = getRepositoryConfiguration,
					.inlineMapping = inlineMapping,
					.genJoin = genJoin,
					.genSelect = genSelect,
					.buildQuery = buildQuery,
				},
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

	const FromKeyType = std.meta.fields(FromModel)[std.meta.fieldIndex(FromModel, fromRepositoryConfig.key[0]).?].type;
	const QueryType = _query.RepositoryQuery(ToModel, ToTable, toRepositoryConfig, null);

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

	return struct {
		const Self = @This();

		fn getRepositoryConfiguration(_: *anyopaque) repository.RepositoryConfiguration(ToModel, ToTable) {
			return toRepositoryConfig;
		}

		fn inlineMapping(_: *anyopaque) bool {
			return true;
		}

		fn genJoin(_: *anyopaque, comptime alias: []const u8) []const u8 {
			return switch (config) {
				.direct => (
					"LEFT JOIN \"" ++ toRepositoryConfig.table ++ "\" AS \"" ++ alias ++ "\" ON " ++
						"\"" ++ fromRepositoryConfig.table ++ "\"." ++ foreignKey ++ " = \"" ++ alias ++ "\"." ++ modelKey
				),

				.reverse => (
					"LEFT JOIN \"" ++ toRepositoryConfig.table ++ "\" AS \"" ++ alias ++ "\" ON " ++
						"\"" ++ fromRepositoryConfig.table ++ "\"." ++ modelKey ++ " = \"" ++ alias ++ "\"." ++ foreignKey
				),

				.through => |through| (
					"LEFT JOIN \"" ++ through.table ++ "\" AS \"" ++ alias ++ "_pivot\" ON " ++
						"\"" ++ fromRepositoryConfig.table ++ "\"." ++ foreignKey ++ " = " ++ "\"" ++ alias ++ "_pivot\"." ++ through.joinForeignKey ++
					"LEFT JOIN \"" ++ toRepositoryConfig.table ++ "\" AS \"" ++ alias ++ "\" ON " ++
						"\"" ++ alias ++ "_pivot\"." ++ through.joinModelKey ++ " = " ++ "\"" ++ alias ++ "\"." ++ modelKey
				),
			};
		}

		fn genSelect(_: *anyopaque, comptime table: []const u8, comptime prefix: []const u8) []const u8 {
			return _sql.SelectBuild(ToTable, table, prefix);
		}

		fn buildQuery(_: *anyopaque, opaqueModels: []const anyopaque, opaqueQuery: *anyopaque) !void {
			var models: []const FromModel = undefined;
			models.len = opaqueModels.len;
			models.ptr = @ptrCast(@alignCast(opaqueModels.ptr));
			const query: *QueryType = @ptrCast(@alignCast(opaqueQuery));

			// Prepare given models IDs.
			const modelsIds = try query.arena.allocator().alloc(FromKeyType, models.len);
			for (models, modelsIds) |model, *modelId| {
				modelId.* = @field(model, fromRepositoryConfig.key[0]);
			}

			switch (config) {
				.direct => {
					query.join((_sql.RawQuery{
						.sql = "INNER JOIN \"" ++ fromRepositoryConfig.table ++ "\" ON \"" ++ toRepositoryConfig.table ++ "\"." ++ modelKey ++ " = \"" ++ fromRepositoryConfig.table ++ "\"." ++ foreignKey,
						.params = &[0]_sql.RawQueryParameter{},
					}));

					// Build WHERE condition.
					try query.whereIn(FromKeyType, "\"" ++ fromRepositoryConfig.table ++ "\".\"" ++ fromRepositoryConfig.key[0] ++ "\"", modelsIds);
				},
				.reverse => {
					// Build WHERE condition.
					try query.whereIn(FromKeyType, "\"" ++ toRepositoryConfig.table ++ "\".\"" ++ foreignKey ++ "\"", modelsIds);
				},
				.through => |through| {
					query.join(.{
						.sql = "INNER JOIN \"" ++ through.table ++ "\" ON " ++
							"\"" ++ toRepositoryConfig.table ++ "\"." ++ modelKey ++ " = " ++ "\""  ++ through.table ++ "\"." ++ through.joinModelKey,
						.params = &[0]_sql.RawQueryParameter{},
					});

					// Build WHERE condition.
					try query.whereIn(FromKeyType, "\"" ++ through.table ++ "\".\"" ++ through.joinForeignKey ++ "\"", modelsIds);
				},
			}
		}

		pub fn relation(self: *Self) Relation(ToModel, ToTable) {
			return .{
				._interface = .{
					.instance = self,

					.getRepositoryConfiguration = getRepositoryConfiguration,
					.inlineMapping = inlineMapping,
					.genJoin = genJoin,
					.genSelect = genSelect,
					.buildQuery = buildQuery,
				},
			};
		}
	};
}

/// Generic model relation interface.
pub fn Relation(comptime ToModel: type, comptime ToTable: type) type {
	return struct {
		const Self = @This();

		pub const Model = ToModel;
		pub const TableShape = ToTable;

		_interface: struct {
			instance: *anyopaque,

			getRepositoryConfiguration: *const fn (self: *anyopaque) repository.RepositoryConfiguration(ToModel, ToTable),
			inlineMapping: *const fn (self: *anyopaque) bool,
			genJoin: *const fn (self: *anyopaque, comptime alias: []const u8) []const u8,
			genSelect: *const fn (self: *anyopaque, comptime table: []const u8, comptime prefix: []const u8) []const u8,
			buildQuery: *const fn (self: *anyopaque, models: []const anyopaque, query: *anyopaque) anyerror!void,
		},

		/// Read the related model repository configuration.
		pub fn getRepositoryConfiguration(self: Self) repository.RepositoryConfiguration(ToModel, ToTable) {
			return self._interface.getRepositoryConfiguration(self._interface.instance);
		}

		/// Relation mapping is done inline: this means that it's done at the same time the model is mapped,
		/// and that the associated data will be retrieved in the main query.
		pub fn inlineMapping(self: Self) bool {
			return self._interface.inlineMapping(self._interface.instance);
		}

		/// In case of inline mapping, generate a JOIN clause to retrieve the associated data.
		pub fn genJoin(self: Self, comptime alias: []const u8) []const u8 {
			return self._interface.genJoin(self._interface.instance, alias);
		}

		/// Generate a SELECT clause to retrieve the associated data, with the given table and prefix.
		pub fn genSelect(self: Self, comptime table: []const u8, comptime prefix: []const u8) []const u8 {
			return self._interface.genSelect(self._interface.instance, table, prefix);
		}

		/// Build the query to retrieve relation data.
		/// Is always used when inline mapping is not possible, but also when loading relations lazily.
		pub fn buildQuery(self: Self, models: []const anyopaque, query: *anyopaque) !void {
			return self._interface.buildQuery(self._interface.instance, models, query);
		}
	};
}


/// A model relation object.
pub const ModelRelation = struct {
	relation: type,
	field: []const u8,
};


/// Structure of an eager loaded relation.
pub const Eager = struct {
	/// Model field to fill for the relation.
	field: []const u8,
	/// The relation to eager load.
	relation: Relation,
	/// Subrelations to eager load.
	with: []const Eager,
};
