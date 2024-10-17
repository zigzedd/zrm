const std = @import("std");
const pg = @import("pg");
const zrm = @import("zrm");

/// PostgreSQL database connection.
var database: *pg.Pool = undefined;

/// Initialize database connection.
fn initDatabase() !void {
	database = try pg.Pool.init(std.testing.allocator, .{
		.connect = .{
			.host = "localhost",
			.port = 5432,
		},
		.auth = .{
			.username = "zrm",
			.password = "zrm",
			.database = "zrm",
		},
	});
}

/// An example model with composite key.
const CompositeModel = struct {
	firstcol: i32,
	secondcol: []const u8,

	label: ?[]const u8 = null,
};

/// SQL table shape of the example model with composite key.
const CompositeModelTable = struct {
	firstcol: i32,
	secondcol: []const u8,

	label: ?[]const u8,
};

// Convert an SQL row to a model.
fn modelFromSql(raw: CompositeModelTable) !CompositeModel {
	return .{
		.firstcol = raw.firstcol,
		.secondcol = raw.secondcol,
		.label = raw.label,
	};
}

/// Convert a model to an SQL row.
fn modelToSql(model: CompositeModel) !CompositeModelTable {
	return .{
		.firstcol = model.firstcol,
		.secondcol = model.secondcol,
		.label = model.label,
	};
}

/// Declare the composite model repository.
const CompositeModelRepository = zrm.Repository(CompositeModel, CompositeModelTable, .{
	.table = "composite_models",

	// Insert shape used by default for inserts in the repository.
	.insertShape = zrm.InsertableStruct(struct {
		secondcol: []const u8,
		label: []const u8,
	}),

	.key = &[_][]const u8{"firstcol", "secondcol"},

	.fromSql = &modelFromSql,
	.toSql = &modelToSql,
});


test "composite model create, save and find" {
	zrm.setDebug(true);

	try initDatabase();
	defer database.deinit();

	// Initialize a test model.
	var newModel = CompositeModel{
		.firstcol = 0,
		.secondcol = "identifier",
		.label = "test label",
	};


	// Create the new model.
	var result = try CompositeModelRepository.create(std.testing.allocator, database, &newModel);
	defer result.deinit(); // Will clear some values in newModel.

	// Check that the model is correctly defined.
	try std.testing.expect(newModel.firstcol > 0);
	try std.testing.expectEqualStrings("identifier", newModel.secondcol);
	try std.testing.expectEqualStrings("test label", newModel.label.?);


	const postInsertFirstcol = newModel.firstcol;
	const postInsertSecondcol = newModel.secondcol;

	// Update the model.
	newModel.label = null;

	var result2 = try CompositeModelRepository.save(std.testing.allocator, database, &newModel);
	defer result2.deinit(); // Will clear some values in newModel.

	// Checking that the model has been updated (but only the right field).
	try std.testing.expectEqual(postInsertFirstcol, newModel.firstcol);
	try std.testing.expectEqualStrings(postInsertSecondcol, newModel.secondcol);
	try std.testing.expectEqual(null, newModel.label);


	// Do another insert with the same secondcol.
	var insertQuery = CompositeModelRepository.Insert.init(std.testing.allocator, database);
	defer insertQuery.deinit();
	try insertQuery.values(.{
		.secondcol = "identifier",
		.label = "test",
	});
	insertQuery.returningAll();
	var result3 = try insertQuery.insert(std.testing.allocator);
	defer result3.deinit();

	// Checking that the other model has been inserted correctly.
	try std.testing.expect(result3.first().?.firstcol > newModel.firstcol);
	try std.testing.expectEqualStrings("identifier", result3.first().?.secondcol);
	try std.testing.expectEqualStrings("test", result3.first().?.label.?);


	// Try to find the created then saved model, to check that everything has been saved correctly.
	var result4 = try CompositeModelRepository.find(std.testing.allocator, database, .{
		.firstcol = newModel.firstcol,
		.secondcol = newModel.secondcol,
	});
	defer result4.deinit(); // Will clear some values in newModel.

	try std.testing.expectEqual(1, result4.models.len);
	try std.testing.expectEqualDeep(newModel, result4.first().?.*);


	// Try to find multiple models at once.
	var result5 = try CompositeModelRepository.find(std.testing.allocator, database, &[_]CompositeModelRepository.KeyType{
		.{
			.firstcol = newModel.firstcol,
			.secondcol = newModel.secondcol,
		},
		.{
			.firstcol = result3.first().?.firstcol,
			.secondcol = result3.first().?.secondcol,
		},
	});
	defer result5.deinit();

	try std.testing.expectEqual(2, result5.models.len);
	try std.testing.expectEqual(newModel.firstcol, result5.models[0].firstcol);
	try std.testing.expectEqualStrings(newModel.secondcol, result5.models[0].secondcol);
	try std.testing.expectEqual(result3.first().?.firstcol, result5.models[1].firstcol);
	try std.testing.expectEqualStrings(result3.first().?.secondcol, result5.models[1].secondcol);
}
