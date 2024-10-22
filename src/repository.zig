const std = @import("std");
const zollections = @import("zollections");
const database = @import("database.zig");
const _sql = @import("sql.zig");
const _conditions = @import("conditions.zig");
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

/// Build the type of a model key, based on the given configuration.
pub fn ModelKeyType(comptime Model: type, comptime TableShape: type, comptime config: RepositoryConfiguration(Model, TableShape)) type {
	if (config.key.len == 0) {
		// Get the type of the simple key.
		return std.meta.fields(TableShape)[std.meta.fieldIndex(TableShape, config.key[0]).?].type;
	} else {
		// Build the type of the composite key.

		// Build key fields.
		var fields: [config.key.len]std.builtin.Type.StructField = undefined;
		inline for (config.key, &fields) |keyName, *field| {
			// Build NULL-terminated key name as field name.
			var fieldName: [keyName.len:0]u8 = undefined;
			@memcpy(fieldName[0..keyName.len], keyName);

			// Get current field type.
			const fieldType = std.meta.fields(TableShape)[std.meta.fieldIndex(TableShape, keyName).?].type;

			field.* = .{
				.name = &fieldName,
				.type = fieldType,
				.default_value = null,
				.is_comptime = false,
				.alignment = @alignOf(fieldType),
			};
		}

		return @Type(.{
			.Struct = std.builtin.Type.Struct{
				.layout = std.builtin.Type.ContainerLayout.auto,
				.fields = &fields,
				.decls = &[_]std.builtin.Type.Declaration{},
				.is_tuple = false,
			},
		});
	}
}

/// Repository of structures of a certain type.
pub fn Repository(comptime Model: type, comptime TableShape: type, comptime config: RepositoryConfiguration(Model, TableShape)) type {
	return struct {
		const Self = @This();

		pub const Query: type = query.RepositoryQuery(Model, TableShape, config);
		pub const Insert: type = insert.RepositoryInsert(Model, TableShape, config, config.insertShape);

		/// Type of one model key.
		pub const KeyType = ModelKeyType(Model, TableShape, config);

		pub fn InsertCustom(comptime InsertShape: type) type {
			return insert.RepositoryInsert(Model, TableShape, config, InsertShape);
		}

		pub fn Update(comptime UpdateShape: type) type {
			return update.RepositoryUpdate(Model, TableShape, config, UpdateShape);
		}

		/// Try to find the requested model.
		/// For simple keys: modelKey type must match the type of its corresponding field.
		/// modelKey can be an array / slice of keys.
		/// For composite keys: modelKey must be a struct with all the keys, matching the type of their corresponding field.
		/// modelKey can be an array / slice of these structs.
		pub fn find(allocator: std.mem.Allocator, connector: database.Connector, modelKey: anytype) !RepositoryResult(Model) {
			// Initialize a new query.
			var modelQuery = Self.Query.init(allocator, connector, .{});
			defer modelQuery.deinit();

			if (config.key.len == 1) {
				// Find key name and its type.
				const keyName = config.key[0];
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
											try modelQuery.whereValue(KeyType, keyName, "=", modelKey)
										else
											// Otherwise, use it as an array.
											try modelQuery.whereIn(keyType, keyName, modelKey);
									},
									// Add a simple condition with the pointed value.
									else => try modelQuery.whereValue(keyType, keyName, "=", modelKey.*),
								}
							},
							// Add a whereIn with the slice.
							else => {
								if (ptr.child == u8)
									// If the child is a string, use it as a simple value.
									try modelQuery.whereValue(KeyType, keyName, "=", modelKey)
								else
									// Otherwise, use it as an array.
									try modelQuery.whereIn(keyType, keyName, modelKey);
							},
						}
					},
					// Add a simple condition with the given value.
					else => try modelQuery.whereValue(keyType, keyName, "=", modelKey),
				}
			} else {
				// Accept arrays / slices of keys, and simple keys.
				// Uniformize modelKey parameter to a slice.
				const modelKeysList: []const Self.KeyType = switch (@typeInfo(@TypeOf(modelKey))) {
					.Pointer => |ptr| switch (ptr.size) {
						.One => switch (@typeInfo(ptr.child)) {
							// Already an array.
							.Array => @as([]const Self.KeyType, modelKey),
							// Convert the pointer to an array.
							else => &[1]Self.KeyType{@as(Self.KeyType, modelKey.*)},
						},
						// Already a slice.
						else => @as([]const Self.KeyType, modelKey),
					},
					// Convert the value to an array.
					else => &[1]Self.KeyType{@as(Self.KeyType, modelKey)},
				};

				// Initialize keys conditions list.
				const conditions: []_sql.SqlParams = try allocator.alloc(_sql.SqlParams, modelKeysList.len);
				defer allocator.free(conditions);

				// For each model key, add its conditions.
				for (modelKeysList, conditions) |_modelKey, *condition| {
					condition.* = try modelQuery.newCondition().@"and"(
						&try buildCompositeKeysConditions(TableShape, config.key, modelQuery.newCondition(), _modelKey)
					);
				}

				// Set WHERE conditions in the query with all keys conditions.
				modelQuery.where(try modelQuery.newCondition().@"or"(conditions));
			}

			// Execute query and return its result.
			return try modelQuery.get(allocator);
		}

		/// Perform creation of the given new model in the repository.
		/// The model will be altered with the inserted values.
		pub fn create(allocator: std.mem.Allocator, connector: database.Connector, newModel: *Model) !RepositoryResult(Model) {
			// Initialize a new insert query for the given model.
			var insertQuery = Self.Insert.init(allocator, connector);
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
		pub fn save(allocator: std.mem.Allocator, connector: database.Connector, existingModel: *Model) !RepositoryResult(Model) {
			// Convert the model to its SQL form.
			const modelSql = try config.toSql(existingModel.*);

			// Initialize a new update query for the given model.
			var updateQuery = Self.Update(TableShape).init(allocator, connector);
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

/// Build conditions for given composite keys, with a model key structure.
pub fn buildCompositeKeysConditions(comptime TableShape: type, comptime keys: []const []const u8, conditionsBuilder: _conditions.Builder, modelKey: anytype) ![keys.len]_sql.SqlParams {
	// Conditions list for all keys in the composite key.
	var conditions: [keys.len]_sql.SqlParams = undefined;

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
