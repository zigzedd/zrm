const std = @import("std");
const zollections = @import("zollections");
const _database = @import("database.zig");
const _repository = @import("repository.zig");
const _relations = @import("relations.zig");

/// Structure of a model with its metadata.
pub fn ModelWithMetadata(comptime Model: type, comptime MetadataShape: ?type) type {
	if (MetadataShape) |MetadataType| {
		return struct {
			model: Model,
			metadata: MetadataType,
		};
	} else {
		return Model;
	}
}

/// Type of a retrieved table data, with its retrieved relations.
pub fn TableWithRelations(comptime TableShape: type, comptime MetadataShape: ?type, comptime optionalRelations: ?[]const _relations.Relation) type {
	if (optionalRelations) |relations| {
		const tableType = @typeInfo(TableShape);

		// Build fields list: copy the existing table type fields and add those for relations.
		var fields: [tableType.Struct.fields.len + relations.len + (if (MetadataShape) |_| 1 else 0)]std.builtin.Type.StructField = undefined;
		// Copy base table fields.
		@memcpy(fields[0..tableType.Struct.fields.len], tableType.Struct.fields);

		// For each relation, create a new struct field in the table shape.
		for (relations, fields[tableType.Struct.fields.len..(tableType.Struct.fields.len+relations.len)]) |relation, *field| {
			// Get relation field type (optional TableShape of the related value).
			const relationFieldType = @Type(std.builtin.Type{
				.Optional = .{
					.child = relation.TableShape
				},
			});

			// Create the new field from relation data.
			field.* = std.builtin.Type.StructField{
				.name = relation.field ++ [0:0]u8{},
				.type = relationFieldType,
				.default_value = null,
				.is_comptime = false,
				.alignment = @alignOf(relationFieldType),
			};
		}

		if (MetadataShape) |MetadataType| {
			// Add metadata field.
			fields[tableType.Struct.fields.len + relations.len] = std.builtin.Type.StructField{
				.name = "_zrm_metadata",
				.type = MetadataType,
				.default_value = null,
				.is_comptime = false,
				.alignment = @alignOf(MetadataType),
			};
		}

		// Build the new type.
		return @Type(std.builtin.Type{
			.Struct = .{
				.layout = tableType.Struct.layout,
				.fields = &fields,
				.decls = tableType.Struct.decls,
				.is_tuple = tableType.Struct.is_tuple,
				.backing_integer = tableType.Struct.backing_integer,
			},
		});
	} else {
		return TableShape;
	}
}

/// Convert a value of the fully retrieved type to the TableShape type.
pub fn toTableShape(comptime TableShape: type, comptime MetadataShape: ?type, comptime optionalRelations: ?[]const _relations.Relation, value: TableWithRelations(TableShape, MetadataShape, optionalRelations)) TableShape {
	if (optionalRelations) |_| {
		// Make a structure of TableShape type.
		var tableValue: TableShape = undefined;

		// Copy all fields of the table shape in the new structure.
		inline for (std.meta.fields(TableShape)) |field| {
			@field(tableValue, field.name) = @field(value, field.name);
		}

		// Return the simplified structure.
		return tableValue;
	} else {
		// No relations, it should already be of type TableShape.
		return value;
	}
}

/// Generic interface of a query result reader.
pub fn QueryResultReader(comptime TableShape: type, comptime MetadataShape: ?type, comptime inlineRelations: ?[]const _relations.Relation) type {
	return struct {
		const Self = @This();

		/// Generic interface of a query result reader instance.
		pub const Instance = struct {
			__interface: struct {
				instance: *anyopaque,
				next: *const fn (self: *anyopaque) anyerror!?TableWithRelations(TableShape, MetadataShape, inlineRelations),
			},

			allocator: std.mem.Allocator,

			pub fn next(self: Instance) !?TableWithRelations(TableShape, MetadataShape, inlineRelations) {
				return self.__interface.next(self.__interface.instance);
			}
		};

		_interface: struct {
			instance: *anyopaque,
			init: *const fn (self: *anyopaque, allocator: std.mem.Allocator) anyerror!Instance,
		},

		/// Initialize a reader instance.
		pub fn init(self: Self, allocator: std.mem.Allocator) !Instance {
			return self._interface.init(self._interface.instance, allocator);
		}
	};
}

/// Map query result to repository model structures, and load the given relations.
pub fn ResultMapper(comptime Model: type, comptime TableShape: type, comptime MetadataShape: ?type, comptime repositoryConfig: _repository.RepositoryConfiguration(Model, TableShape), comptime inlineRelations: ?[]const _relations.Relation, comptime relations: ?[]const _relations.Relation) type {
	return struct {
		/// Map the query result to a repository result, with all the required relations.
		pub fn map(comptime withMetadata: bool, allocator: std.mem.Allocator, connector: _database.Connector, queryReader: QueryResultReader(TableShape, MetadataShape, inlineRelations)) !_repository.RepositoryResult(if (withMetadata) ModelWithMetadata(Model, MetadataShape) else Model) {
			// Get result type depending on metadata
			const ResultType = if (withMetadata) ModelWithMetadata(Model, MetadataShape) else Model;

			// Create an arena for mapper data.
			var mapperArena = std.heap.ArenaAllocator.init(allocator);

			// Initialize query result reader.
			const reader = try queryReader.init(mapperArena.allocator());

			// Initialize models list.
			var models = std.ArrayList(*ResultType).init(allocator);
			defer models.deinit();

			// Get all raw models from the result reader.
			while (try reader.next()) |rawModel| {
				// Parse each raw model from the reader.
				const model = try allocator.create(ResultType);
				(if (withMetadata) model.model else model.*) = try repositoryConfig.fromSql(toTableShape(TableShape, MetadataShape, inlineRelations, rawModel));

				// Map inline relations.
				if (inlineRelations) |_inlineRelations| {
					// If there are loaded inline relations, map them to the result.
					inline for (_inlineRelations) |relation| {
						// Set the read inline relation value.
						@field(model.*, relation.field) = (
							if (@field(rawModel, relation.field)) |relationVal|
								try relation.repositoryConfiguration().fromSql(relationVal)
							else null
						);
					}
				}

				if (withMetadata) {
					// Set model metadata.
					model.metadata = rawModel._zrm_metadata;
				}

				try models.append(model);
			}

			if (relations) |relationsToLoad| {
				inline for (relationsToLoad) |relation| {
					// Build query for the relation to get.
					const query: *relation.QueryType = @ptrCast(@alignCast(
						try relation.buildQuery(@ptrCast(models.items), allocator, connector)
					));
					defer {
						query.deinit();
						allocator.destroy(query);
					}

					// Get related models.
					const relatedModels = try query.getWithMetadata(mapperArena.allocator());

					// Create a map with related models.
					const RelatedModelsListType = std.ArrayList(@TypeOf(relatedModels.models[0].model));
					const RelatedModelsMapType = std.AutoHashMap(std.meta.FieldType(@TypeOf(relatedModels.models[0].metadata), .__zrm_relation_key), RelatedModelsListType);
					var relatedModelsMap = RelatedModelsMapType.init(allocator);
					defer relatedModelsMap.deinit();

					// Fill the map of related models, indexing them by the relation key.
					for (relatedModels.models) |relatedModel| {
						// For each related model, put it in the map at the relation key.
						var modelsList = try relatedModelsMap.getOrPut(relatedModel.metadata.__zrm_relation_key);

						if (!modelsList.found_existing) {
							// Initialize the related models list.
							modelsList.value_ptr.* = RelatedModelsListType.init(mapperArena.allocator());
						}

						// Add the current related model to the list.
						try modelsList.value_ptr.append(relatedModel.model);
					}

					// For each model, at the grouped related models if there are some.
					for (models.items) |model| {
						@field(model, relation.field) = (
							if (relatedModelsMap.getPtr(@field(model, repositoryConfig.key[0]))) |relatedModelsList|
								// There are related models, set them.
								try relatedModelsList.toOwnedSlice()
							else
								// No related models, set an empty array.
								&[0](@TypeOf(relatedModels.models[0].model)){}
						);
					}
				}
			}

			// Return a result with the models.
			return _repository.RepositoryResult(ResultType).init(allocator,
				zollections.Collection(ResultType).init(allocator, try models.toOwnedSlice()),
				mapperArena,
			);
		}
	};
}
