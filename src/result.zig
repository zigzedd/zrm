const std = @import("std");
const zollections = @import("zollections");
const _repository = @import("repository.zig");
const _relations = @import("relations.zig");

/// Generic interface of a query result reader.
pub fn QueryResultReader(comptime TableShape: type, comptime inlineRelations: ?[]const _relations.ModelRelation) type {
	_ = inlineRelations;
	return struct {
		const Self = @This();

		/// Generic interface of a query result reader instance.
		pub const Instance = struct {
			__interface: struct {
				instance: *anyopaque,
				next: *const fn (self: *anyopaque) anyerror!?TableShape, //TODO inline relations.
			},

			allocator: std.mem.Allocator,

			pub fn next(self: Instance) !?TableShape {
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
				model.* = try repositoryConfig.fromSql(rawModel);
				//TODO inline relations.
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
