const std = @import("std");
const pg = @import("pg");
const zollections = @import("zollections");
const _sql = @import("sql.zig");
const query = @import("query.zig");
const insert = @import("insert.zig");
const update = @import("update.zig");

// Type of the "model from SQL data" function.
pub fn ModelFromSql(comptime Model: type, comptime TableShape: type) type {
	return *const fn (raw: TableShape) anyerror!Model;
}
// Type of the "model to SQL data" function.
pub fn ModelToSql(comptime Model: type, comptime TableShape: type) type {
	return *const fn (model: Model) anyerror!TableShape;
}

/// Repository configuration structure.
pub fn RepositoryConfiguration(comptime Model: type, comptime TableShape: type) type {
	return struct {
		/// Table name for this repository.
		table: []const u8,

		/// Insert shape used by default for inserts in the repository.
		insertShape: type,

		/// Key(s) of the model.
		key: []const []const u8,

		/// Convert a model to an SQL table row.
		fromSql: ModelFromSql(Model, TableShape),
		/// Convert an SQL table row to a model.
		toSql: ModelToSql(Model, TableShape),
	};
}

/// Repository of structures of a certain type.
pub fn Repository(comptime Model: type, comptime TableShape: type, comptime config: RepositoryConfiguration(Model, TableShape)) type {
	return struct {
		const Self = @This();

		pub const Query: type = query.RepositoryQuery(Model, TableShape, config);
		pub const Insert: type = insert.RepositoryInsert(Model, TableShape, config, config.insertShape);

		pub fn InsertCustom(comptime InsertShape: type) type {
			return insert.RepositoryInsert(Model, TableShape, config, InsertShape);
		}

		pub fn Update(comptime UpdateShape: type) type {
			return update.RepositoryUpdate(Model, TableShape, config, UpdateShape);
		}

		/// Try to find the requested model.
		pub fn find(allocator: std.mem.Allocator, database: *pg.Pool, modelKey: anytype) !RepositoryResult(Model) {
			// Initialize a new query.
			var modelQuery = Self.Query.init(allocator, database, .{});
			defer modelQuery.deinit();

			if (config.key.len == 1) {
				// Add a simple condition.
				try modelQuery.whereValue(std.meta.fields(TableShape)[std.meta.fieldIndex(TableShape, config.key[0]).?].type, config.key[0], "=", modelKey);
			} else {
				// Add conditions for all keys in the composite key.
				var conditions: [config.key.len]_sql.SqlParams = undefined;

				inline for (config.key, &conditions) |keyName, *condition| {
					if (std.meta.fieldIndex(@TypeOf(modelKey), keyName)) |_| {
						// The field exists in the key structure, create its condition.
						condition.* = try modelQuery.newCondition().value(
							std.meta.fields(TableShape)[std.meta.fieldIndex(TableShape, keyName).?].type,
							keyName, "=",
							@field(modelKey, keyName),
						);
					} else {
						// The field doesn't exist, compilation error.
						@compileError("The key structure must include a field for " ++ keyName);
					}
				}

				// Set WHERE conditions in the query.
				modelQuery.where(try modelQuery.newCondition().@"and"(&conditions));
			}

			// Execute query and return its result.
			return try modelQuery.get(allocator);
		}

		/// Perform creation of the given new model in the repository.
		/// The model will be altered with the inserted values.
		pub fn create(allocator: std.mem.Allocator, database: *pg.Pool, newModel: *Model) !RepositoryResult(Model) {
			// Initialize a new insert query for the given model.
			var insertQuery = Self.Insert.init(allocator, database);
			defer insertQuery.deinit();
			try insertQuery.values(newModel);
			insertQuery.returningAll();

			// Execute insert query and get its result.
			const inserted = try insertQuery.insert(allocator);

			if (inserted.models.len > 0) {
				// Update model with its inserted values.
				newModel.* = inserted.models[0].*;
			}

			// Return inserted result.
			return inserted;
		}

		/// Perform save of the given existing model in the repository.
		pub fn save(allocator: std.mem.Allocator, database: *pg.Pool, existingModel: *Model) !RepositoryResult(Model) {
			// Convert the model to its SQL form.
			const modelSql = try config.toSql(existingModel.*);

			// Initialize a new update query for the given model.
			var updateQuery = Self.Update(TableShape).init(allocator, database);
			defer updateQuery.deinit();
			try updateQuery.set(modelSql);
			updateQuery.returningAll();

			// Initialize conditions array.
			var conditions: [config.key.len]_sql.SqlParams = undefined;
			inline for (config.key, &conditions) |keyName, *condition| {
				// Add a where condition for each key.
				condition.* = try updateQuery.newCondition().value(@TypeOf(@field(modelSql, keyName)), keyName, "=", @field(modelSql, keyName));
			}
			// Add WHERE to the update query with built conditions.
			updateQuery.where(try updateQuery.newCondition().@"and"(&conditions));

			// Execute update query and get its result.
			const updated = try updateQuery.update(allocator);

			if (updated.models.len > 0) {
				// Update model with its updated values.
				existingModel.* = updated.models[0].*;
			}

			// Return updated result.
			return updated;
		}
	};
}

/// A repository query result.
pub fn RepositoryResult(comptime Model: type) type {
	return struct {
		const Self = @This();

		allocator: std.mem.Allocator,
		mapperArena: std.heap.ArenaAllocator,

		/// The retrieved models.
		models: []*Model,
		/// The retrieved models collection (memory owner).
		collection: zollections.Collection(Model),

		/// Get the first model in the list, if there is one.
		pub fn first(self: Self) ?*Model {
			if (self.models.len > 0) {
				return self.models[0];
			} else {
				return null;
			}
		}

		/// Initialize a new repository query result.
		pub fn init(allocator: std.mem.Allocator, models: zollections.Collection(Model), mapperArena: std.heap.ArenaAllocator) Self {
			return .{
				.allocator = allocator,
				.mapperArena = mapperArena,
				.models = models.items,
				.collection = models,
			};
		}

		/// Deinitialize the repository query result.
		pub fn deinit(self: *Self) void {
			self.collection.deinit();
			self.mapperArena.deinit();
		}
	};
}
