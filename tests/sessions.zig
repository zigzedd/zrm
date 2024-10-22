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
		.size = 1,
	});
}

test "session with rolled back transaction and savepoint" {
	zrm.setDebug(true);

	// Initialize database.
	try initDatabase(std.testing.allocator);
	defer database.deinit();

	// Start a new session and perform operations in a transaction.
	var session = try zrm.Session.init(database);
	defer session.deinit();


	try session.beginTransaction();

	
	// First UPDATE in the transaction.
	{
		var firstUpdate = repository.MyModelRepository.Update(struct {
			name: []const u8,
		}).init(std.testing.allocator, session.connector());
		defer firstUpdate.deinit();
		try firstUpdate.set(.{
			.name = "tempname",
		});
		try firstUpdate.whereValue(usize, "id", "=", 1);
		var firstUpdateResult = try firstUpdate.update(std.testing.allocator);
		firstUpdateResult.deinit();
	}


	// Set a savepoint.
	try session.savepoint("my_savepoint");


	// Second UPDATE in the transaction.
	{
		var secondUpdate = repository.MyModelRepository.Update(struct {
			amount: f64,
		}).init(std.testing.allocator, session.connector());
		defer secondUpdate.deinit();
		try secondUpdate.set(.{
			.amount = 52.25,
		});
		try secondUpdate.whereValue(usize, "id", "=", 1);
		var secondUpdateResult = try secondUpdate.update(std.testing.allocator);
		secondUpdateResult.deinit();
	}

	// SELECT before rollback to savepoint in the transaction.
	{
		var queryBeforeRollbackToSavepoint = repository.MyModelRepository.Query.init(std.testing.allocator, session.connector(), .{});
		try queryBeforeRollbackToSavepoint.whereValue(usize, "id", "=", 1);
		defer queryBeforeRollbackToSavepoint.deinit();

		// Get models.
		var resultBeforeRollbackToSavepoint = try queryBeforeRollbackToSavepoint.get(std.testing.allocator);
		defer resultBeforeRollbackToSavepoint.deinit();

		// Check that one model has been retrieved, then check its type and values.
		try std.testing.expectEqual(1, resultBeforeRollbackToSavepoint.models.len);
		try std.testing.expectEqual(repository.MyModel, @TypeOf(resultBeforeRollbackToSavepoint.models[0].*));
		try std.testing.expectEqual(1, resultBeforeRollbackToSavepoint.models[0].id);
		try std.testing.expectEqualStrings("tempname", resultBeforeRollbackToSavepoint.models[0].name);
		try std.testing.expectEqual(52.25, resultBeforeRollbackToSavepoint.models[0].amount);
	}


	try session.rollbackTo("my_savepoint");


	// SELECT after rollback to savepoint in the transaction.
	{
		var queryAfterRollbackToSavepoint = repository.MyModelRepository.Query.init(std.testing.allocator, session.connector(), .{});
		try queryAfterRollbackToSavepoint.whereValue(usize, "id", "=", 1);
		defer queryAfterRollbackToSavepoint.deinit();

		// Get models.
		var resultAfterRollbackToSavepoint = try queryAfterRollbackToSavepoint.get(std.testing.allocator);
		defer resultAfterRollbackToSavepoint.deinit();

		// Check that one model has been retrieved, then check its type and values.
		try std.testing.expectEqual(1, resultAfterRollbackToSavepoint.models.len);
		try std.testing.expectEqual(repository.MyModel, @TypeOf(resultAfterRollbackToSavepoint.models[0].*));
		try std.testing.expectEqual(1, resultAfterRollbackToSavepoint.models[0].id);
		try std.testing.expectEqualStrings("tempname", resultAfterRollbackToSavepoint.models[0].name);
		try std.testing.expectEqual(50.00, resultAfterRollbackToSavepoint.models[0].amount);
	}


	try session.rollbackTransaction();


	// SELECT outside of the rolled back transaction.
	{
		var queryOutside = repository.MyModelRepository.Query.init(std.testing.allocator, session.connector(), .{});
		try queryOutside.whereValue(usize, "id", "=", 1);
		defer queryOutside.deinit();

		// Get models.
		var resultOutside = try queryOutside.get(std.testing.allocator);
		defer resultOutside.deinit();

		// Check that one model has been retrieved, then check its type and values.
		try std.testing.expectEqual(1, resultOutside.models.len);
		try std.testing.expectEqual(repository.MyModel, @TypeOf(resultOutside.models[0].*));
		try std.testing.expectEqual(1, resultOutside.models[0].id);
		try std.testing.expectEqualStrings("test", resultOutside.models[0].name);
		try std.testing.expectEqual(50.00, resultOutside.models[0].amount);
	}
}
