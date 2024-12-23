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
		.size = 1,
	});
}

/// An example submodel, child of the example model.
pub const MySubmodel = struct {
	uuid: []const u8,
	label: []const u8,

	parent_id: ?i32 = null,
	parent: ?MyModel = null,
};

const MySubmodelTable = struct {
	uuid: []const u8,
	label: []const u8,

	parent_id: ?i32 = null,
};

// Convert an SQL row to a model.
fn submodelFromSql(raw: MySubmodelTable) !MySubmodel {
	return .{
		.uuid = raw.uuid,
		.label = raw.label,
		.parent_id = raw.parent_id,
	};
}

/// Convert a model to an SQL row.
fn submodelToSql(model: MySubmodel) !MySubmodelTable {
	return .{
		.uuid = model.uuid,
		.label = model.label,
		.parent_id = model.parent_id,
	};
}

/// Declare a model repository.
pub const MySubmodelRepository = zrm.Repository(MySubmodel, MySubmodelTable, .{
	.table = "submodels",

	// Insert shape used by default for inserts in the repository.
	.insertShape = MySubmodelTable,

	.key = &[_][]const u8{"uuid"},

	.fromSql = &submodelFromSql,
	.toSql = &submodelToSql,
});

pub const MySubmodelRelationships = MySubmodelRepository.relationships.define(.{
	.parent = MySubmodelRepository.relationships.one(MyModelRepository, .{
		.direct = .{
			.foreignKey = "parent_id",
		},
	}),
});

/// An example model.
pub const MyModel = struct {
	id: i32,
	name: []const u8,
	amount: f64,

	submodels: ?[]const MySubmodel = null,
};

/// SQL table shape of the example model.
pub const MyModelTable = struct {
	id: i32,
	name: []const u8,
	amount: f64,
};

// Convert an SQL row to a model.
fn modelFromSql(raw: MyModelTable) !MyModel {
	return .{
		.id = raw.id,
		.name = raw.name,
		.amount = raw.amount,
	};
}

/// Convert a model to an SQL row.
fn modelToSql(model: MyModel) !MyModelTable {
	return .{
		.id = model.id,
		.name = model.name,
		.amount = model.amount,
	};
}

/// Declare a model repository.
pub const MyModelRepository = zrm.Repository(MyModel, MyModelTable, .{
	.table = "models",

	// Insert shape used by default for inserts in the repository.
	.insertShape = struct {
		name: []const u8,
		amount: f64,
	},

	.key = &[_][]const u8{"id"},

	.fromSql = &modelFromSql,
	.toSql = &modelToSql,
});

pub const MyModelRelationships = MyModelRepository.relationships.define(.{
	.submodels = MyModelRepository.relationships.many(MySubmodelRepository, .{
		.direct = .{
			.foreignKey = "parent_id",
		}
	}),
});


test "model structures" {
	// Initialize a test model.
	const testModel = MyModel{
		.id = 10,
		.name = "test",
		.amount = 15.5,

		.submodels = &[_]MySubmodel{
			MySubmodel{
				.uuid = "56c378bf-cfda-4438-9b33-b4c63f190907",
				.label = "test",
			},
		},
	};

	// Test that the model is correctly initialized.
	try std.testing.expectEqual(10, testModel.id);
	try std.testing.expectEqualStrings("56c378bf-cfda-4438-9b33-b4c63f190907", testModel.submodels.?[0].uuid);
}


test "repository query SQL builder" {
	zrm.setDebug(true);

	try initDatabase();
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	var query = MyModelRepository.Query.init(std.testing.allocator, poolConnector.connector(), .{});
	defer query.deinit();
	try query.whereIn(usize, "id", &[_]usize{1, 2});
	try query.buildSql();

	const expectedSql = "SELECT \"models\".* FROM \"models\" WHERE id IN ($1,$2);";
	try std.testing.expectEqual(expectedSql.len, query.sql.?.len);
	try std.testing.expectEqualStrings(expectedSql, query.sql.?);
}

test "repository element retrieval" {
	zrm.setDebug(true);

	try initDatabase();
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	// Prepare a query for models.
	var query = MyModelRepository.Query.init(std.testing.allocator, poolConnector.connector(), .{});
	try query.whereValue(usize, "id", "=", 1);
	defer query.deinit();

	// Build SQL.
	try query.buildSql();

	// Check built SQL.
	const expectedSql = "SELECT \"models\".* FROM \"models\" WHERE id = $1;";
	try std.testing.expectEqual(expectedSql.len, query.sql.?.len);
	try std.testing.expectEqualStrings(expectedSql, query.sql.?);

	// Get models.
	var result = try query.get(std.testing.allocator);
	defer result.deinit();

	// Check that one model has been retrieved, then check its type and values.
	try std.testing.expectEqual(1, result.models.len);
	try std.testing.expectEqual(MyModel, @TypeOf(result.models[0].*));
	try std.testing.expectEqual(1, result.models[0].id);
	try std.testing.expectEqualStrings("test", result.models[0].name);
	try std.testing.expectEqual(50.00, result.models[0].amount);
}

test "repository complex SQL query" {
	zrm.setDebug(true);

	try initDatabase();
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	var query = MyModelRepository.Query.init(std.testing.allocator, poolConnector.connector(), .{});
	defer query.deinit();
	query.where(
		try query.newCondition().@"or"(&[_]zrm.RawQuery{
			try query.newCondition().value(usize, "id", "=", 1),
			try query.newCondition().@"and"(&[_]zrm.RawQuery{
				try query.newCondition().in(usize, "id", &[_]usize{100000, 200000, 300000}),
				try query.newCondition().@"or"(&[_]zrm.RawQuery{
					try query.newCondition().value(f64, "amount", ">", 12.13),
					try query.newCondition().value([]const u8, "name", "=", "test"),
				})
			}),
		})
	);
	try query.buildSql();

	const expectedSql = "SELECT \"models\".* FROM \"models\" WHERE (id = $1 OR (id IN ($2,$3,$4) AND (amount > $5 OR name = $6)));";
	try std.testing.expectEqual(expectedSql.len, query.sql.?.len);
	try std.testing.expectEqualStrings(expectedSql, query.sql.?);

	// Get models.
	var result = try query.get(std.testing.allocator);
	defer result.deinit();

	// Check that one model has been retrieved.
	try std.testing.expectEqual(1, result.models.len);
	try std.testing.expectEqual(1, result.models[0].id);
}

test "repository element creation" {
	zrm.setDebug(true);

	try initDatabase();
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	// Create a model to insert.
	const newModel = MyModel{
		.id = undefined,
		.amount = 75,
		.name = "inserted model",
	};

	// Initialize an insert query.
	var insertQuery = MyModelRepository.Insert.init(std.testing.allocator, poolConnector.connector());
	defer insertQuery.deinit();
	// Insert the new model.
	try insertQuery.values(newModel);
	insertQuery.returningAll();

	// Build SQL.
	try insertQuery.buildSql();

	// Check built SQL.
	const expectedSql = "INSERT INTO models(name,amount) VALUES ($1,$2) RETURNING *;";
	try std.testing.expectEqual(expectedSql.len, insertQuery.sql.?.len);
	try std.testing.expectEqualStrings(expectedSql, insertQuery.sql.?);

	// Insert models.
	var result = try insertQuery.insert(std.testing.allocator);
	defer result.deinit();

	// Check the inserted model.
	try std.testing.expectEqual(1, result.models.len);
	try std.testing.expectEqual(75, result.models[0].amount);
	try std.testing.expectEqualStrings("inserted model", result.models[0].name);
}

test "repository element update" {
	zrm.setDebug(true);

	try initDatabase();
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	// Initialize an update query.
	var updateQuery = MyModelRepository.Update(struct {
		name: []const u8,
	}).init(std.testing.allocator, poolConnector.connector());
	defer updateQuery.deinit();

	// Update a model's name.
	try updateQuery.set(.{ .name = "newname" });
	try updateQuery.whereValue(usize, "id", "=", 2);
	updateQuery.returningAll();

	// Build SQL.
	try updateQuery.buildSql();

	// Check built SQL.
	const expectedSql = "UPDATE models SET name=$1 WHERE id = $2 RETURNING *;";
	try std.testing.expectEqual(expectedSql.len, updateQuery.sql.?.len);
	try std.testing.expectEqualStrings(expectedSql, updateQuery.sql.?);

	// Update models.
	var result = try updateQuery.update(std.testing.allocator);
	defer result.deinit();

	// Check the updated model.
	try std.testing.expectEqual(1, result.models.len);
	try std.testing.expectEqual(2, result.models[0].id);
	try std.testing.expectEqualStrings("newname", result.models[0].name);
}

test "model create, save and find" {
	zrm.setDebug(true);

	try initDatabase();
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	// Initialize a test model.
	var newModel = MyModel{
		.id = 0,
		.amount = 555,
		.name = "newly created model",
	};


	// Create the new model.
	var result = try MyModelRepository.create(std.testing.allocator, poolConnector.connector(), &newModel);
	defer result.deinit(); // Will clear some values in newModel.

	// Check that the model is correctly defined.
	try std.testing.expect(newModel.id > 1);
	try std.testing.expectEqualStrings("newly created model", newModel.name);


	const postInsertId = newModel.id;
	const postInsertAmount = newModel.amount;

	// Update the model.
	newModel.name = "recently updated name";

	var result2 = try MyModelRepository.save(std.testing.allocator, poolConnector.connector(), &newModel);
	defer result2.deinit(); // Will clear some values in newModel.

	// Checking that the model has been updated (but only the right field).
	try std.testing.expectEqual(postInsertId, newModel.id);
	try std.testing.expectEqualStrings("recently updated name", newModel.name);
	try std.testing.expectEqual(postInsertAmount, newModel.amount);


	// Do another update.
	newModel.amount = 12.226;

	var result3 = try MyModelRepository.save(std.testing.allocator, poolConnector.connector(), &newModel);
	defer result3.deinit(); // Will clear some values in newModel.

	// Checking that the model has been updated (but only the right field).
	try std.testing.expectEqual(postInsertId, newModel.id);
	try std.testing.expectEqualStrings("recently updated name", newModel.name);
	try std.testing.expectEqual(12.23, newModel.amount);


	// Try to find the created then saved model, to check that everything has been saved correctly.
	var result4 = try MyModelRepository.find(std.testing.allocator, poolConnector.connector(), newModel.id);
	defer result4.deinit(); // Will clear some values in newModel.

	try std.testing.expectEqualDeep(newModel, result4.first().?.*);


	// Try to find multiple models at once.
	var result5 = try MyModelRepository.find(std.testing.allocator, poolConnector.connector(), &[_]i32{1, newModel.id});
	defer result5.deinit();

	try std.testing.expectEqual(2, result5.models.len);
	try std.testing.expectEqual(1, result5.models[0].id);
	try std.testing.expectEqual(newModel.id, result5.models[1].id);
}
