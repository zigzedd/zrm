const std = @import("std");
const pg = @import("pg");
const zrm = @import("zrm");
const repository = @import("repository.zig");

/// PostgreSQL database connection.
var database: *pg.Pool = undefined;

/// Initialize database connection.
fn initDatabase(allocator: std.mem.Allocator) !void {
	database = try pg.Pool.init(allocator, .{
		.connect = .{
			.host = "localhost",
			.port = 5432,
		},
		.auth = .{
			.username = "zrm",
			.password = "zrm",
			.database = "zrm",
		},
		.size = 5,
	});
}

test "belongsTo" {
	zrm.setDebug(true);

	try initDatabase(std.testing.allocator);
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	// Build a query of submodels.
	var myQuery = repository.MySubmodelRepository.QueryWith(
		// Retrieve parents of submodels from relation.
		&[_]zrm.relations.ModelRelation{repository.MySubmodelRelations.parent}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	defer myQuery.deinit();

	try myQuery.buildSql();

	// Get query result.
	var result = try myQuery.get(std.testing.allocator);
	defer result.deinit();

	// Checking result.
	try std.testing.expectEqual(2, result.models.len);
	try std.testing.expectEqual(1, result.models[0].parent_id);
	try std.testing.expectEqual(1, result.models[1].parent_id);
	try std.testing.expectEqual(repository.MyModel, @TypeOf(result.models[0].parent.?));
	try std.testing.expectEqual(1, result.models[0].parent.?.id);
	try std.testing.expectEqual(1, result.models[1].parent.?.id);
}

test "hasMany" {
	zrm.setDebug(true);

	try initDatabase(std.testing.allocator);
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	// Build a query of submodels.
	var myQuery = repository.MyModelRepository.QueryWith(
	// Retrieve parents of submodels from relation.
		&[_]zrm.relations.ModelRelation{repository.MyModelRelations.submodels}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	defer myQuery.deinit();

	try myQuery.buildSql();

	// Get query result.
	var result = try myQuery.get(std.testing.allocator);
	defer result.deinit();

	// Checking result.
	try std.testing.expectEqual(4, result.models.len);
	try std.testing.expectEqual(repository.MySubmodel, @TypeOf(result.models[0].submodels.?[0]));

	// Checking retrieved submodels.
	for (result.models) |model| {
		try std.testing.expect(model.submodels != null);

		if (model.submodels.?.len > 0) {
			try std.testing.expectEqual(1, model.id);
			try std.testing.expectEqual(2, model.submodels.?.len);
			for (model.submodels.?) |submodel| {
				try std.testing.expectEqual(1, submodel.parent_id.?);
				try std.testing.expect(
					std.mem.eql(u8, &try pg.uuidToHex(submodel.uuid), "f6868a5b-2efc-455f-b76e-872df514404f")
						or std.mem.eql(u8, &try pg.uuidToHex(submodel.uuid), "013ef171-9781-40e9-b843-f6bc11890070")
				);
				try std.testing.expect(
					std.mem.eql(u8, submodel.label, "test") or std.mem.eql(u8, submodel.label, "another")
				);
			}
		}
	}
}
