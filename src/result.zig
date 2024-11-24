const std = @import("std");
const zollections = @import("zollections");
const _repository = @import("repository.zig");
const _relations = @import("relations.zig");

/// Type of a retrieved table data, with its retrieved relations.
pub fn TableWithRelations(comptime TableShape: type, comptime optionalRelations: ?[]const _relations.ModelRelation) type {
	if (optionalRelations) |relations| {
		const tableType = @typeInfo(TableShape);

		// Build fields list: copy the existing table type fields and add those for relations.
		var fields: [tableType.Struct.fields.len + relations.len]std.builtin.Type.StructField = undefined;
		// Copy base table fields.
		@memcpy(fields[0..tableType.Struct.fields.len], tableType.Struct.fields);

		// For each relation, create a new struct field in the table shape.
		for (relations, fields[tableType.Struct.fields.len..]) |relation, *field| {
			// Get relation field type (optional TableShape of the related value).
			comptime var relationImpl = relation.relation{};
			const relationInstanceType = @TypeOf(relationImpl.relation());
			const relationFieldType = @Type(std.builtin.Type{
				.Optional = .{
					.child = relationInstanceType.TableShape
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
pub fn toTableShape(comptime TableShape: type, comptime optionalRelations: ?[]const _relations.ModelRelation, value: TableWithRelations(TableShape, optionalRelations)) TableShape {
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
pub fn QueryResultReader(comptime TableShape: type, comptime inlineRelations: ?[]const _relations.ModelRelation) type {
	return struct {
		const Self = @This();

		/// Generic interface of a query result reader instance.
		pub const Instance = struct {
			__interface: struct {
				instance: *anyopaque,
				next: *const fn (self: *anyopaque) anyerror!?TableWithRelations(TableShape, inlineRelations),
			},

			allocator: std.mem.Allocator,

			pub fn next(self: Instance) !?TableWithRelations(TableShape, inlineRelations) {
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
pub fn ResultMapper(comptime Model: type, comptime TableShape: type, comptime repositoryConfig: _repository.RepositoryConfiguration(Model, TableShape), comptime inlineRelations: ?[]const _relations.ModelRelation, comptime relations: ?[]const _relations.ModelRelation) type {
	_ = relations;
	return struct {
		/// Map the query result to a repository result, with all the required relations.
		pub fn map(allocator: std.mem.Allocator, queryReader: QueryResultReader(TableShape, inlineRelations)) !_repository.RepositoryResult(Model) {
			// Create an arena for mapper data.
			var mapperArena = std.heap.ArenaAllocator.init(allocator);

			// Initialize query result reader.
			const reader = try queryReader.init(mapperArena.allocator());

			// Initialize models list.
			var models = std.ArrayList(*Model).init(allocator);
			defer models.deinit();

			// Get all raw models from the result reader.
			while (try reader.next()) |rawModel| {
				// Parse each raw model from the reader.
				const model = try allocator.create(Model);
				model.* = try repositoryConfig.fromSql(toTableShape(TableShape, inlineRelations, rawModel));

				// Map inline relations.
				if (inlineRelations) |_inlineRelations| {
					// If there are loaded inline relations, map them to the result.
					inline for (_inlineRelations) |relation| {
						comptime var relationImpl = relation.relation{};
						const relationInstance = relationImpl.relation();
						// Set the read inline relation value.
						@field(model.*, relation.field) = (
							if (@field(rawModel, relation.field)) |relationVal|
								try relationInstance.getRepositoryConfiguration().fromSql(relationVal)
							else null
						);
					}
				}

				try models.append(model);
			}

			//TODO load relations?

			// Return a result with the models.
			return _repository.RepositoryResult(Model).init(allocator,
				zollections.Collection(Model).init(allocator, try models.toOwnedSlice()),
				mapperArena,
			);
		}
	};
}
