const std = @import("std");
const pg = @import("pg");
const postgresql = @import("postgresql.zig");
const database = @import("database.zig");

/// Session for multiple repository operations.
pub const Session = struct {
	const Self = @This();

	_database: *pg.Pool,

	/// The active connection for the session.
	connection: *pg.Conn,

	/// The count of active transactions for the session.
	activeTransactions: usize = 0,

	/// Execute a comptime-known SQL command for the current session.
	fn exec(self: Self, comptime sql: []const u8) !void {
		_ = self.connection.exec(sql, .{}) catch |err| {
			return postgresql.handleRawPostgresqlError(err, self.connection);
		};
	}

	/// Begin a new transaction.
	pub fn beginTransaction(self: Self) !void {
		try self.exec("BEGIN;");
	}

	/// Rollback the current transaction.
	pub fn rollbackTransaction(self: Self) !void {
		try self.exec("ROLLBACK;");
	}

	/// Rollback all active transactions.
	pub fn rollbackAll(self: Self) !void {
		for (0..self.activeTransactions) |_| {
			self.rollbackTransaction();
		}
	}

	/// Commit the current transaction.
	pub fn commitTransaction(self: Self) !void {
		try self.exec("COMMIT;");
	}

	/// Commit all active transactions.
	pub fn commitAll(self: Self) !void {
		for (0..self.activeTransactions) |_| {
			self.commitTransaction();
		}
	}

	/// Create a new savepoint with the given name.
	pub fn savepoint(self: Self, comptime _savepoint: []const u8) !void {
		try self.exec("SAVEPOINT " ++ _savepoint ++ ";");
	}

	/// Rollback to the savepoint with the given name.
	pub fn rollbackTo(self: Self, comptime _savepoint: []const u8) !void {
		try self.exec("ROLLBACK TO " ++ _savepoint ++ ";");
	}

	/// Initialize a new session.
	pub fn init(_database: *pg.Pool) !Session {
		return .{
			._database = _database,
			.connection = try _database.acquire(),
		};
	}

	/// Deinitialize the session.
	pub fn deinit(self: *Self) void {
		self.connection.release();
	}

	/// Get a database connector instance for the current session.
	pub fn connector(self: *Self) database.Connector {
		return database.Connector{
			._interface = .{
				.instance = self,
				.getConnection = getConnection,
			},
		};
	}

	// Connector implementation.

	/// Get the current connection.
	fn getConnection(opaqueSelf: *anyopaque) !*database.Connection {
		const self: *Self = @ptrCast(@alignCast(opaqueSelf));

		// Initialize a new connection.
		const sessionConnection = try self._database._allocator.create(SessionConnection);
		sessionConnection.* = .{
			.session = self,
		};

		return try sessionConnection.connection();
	}
};

fn noRelease(_: *anyopaque) void {}

/// A session connection.
const SessionConnection = struct {
	const Self = @This();

	/// Session of the connection.
	session: *Session,

	/// Connection instance, to only keep one at a time.
	_connection: ?database.Connection = null,

	/// Get a database connection.
	pub fn connection(self: *Self) !*database.Connection {
		if (self._connection == null) {
			// A new connection needs to be initialized.
			self._connection = .{
				.connection = self.session.connection,
				._interface = .{
					.instance = self,
					.release = releaseConnection,
				},
			};
		}

		return &(self._connection.?);
	}

	// Implementation.

	/// Free the current connection (doesn't actually release the connection, as it is required to stay the same all along the session).
	fn releaseConnection(self: *database.Connection) void {
		// Free allocated connection.
		const sessionConnection: *SessionConnection = @ptrCast(@alignCast(self._interface.instance));
		sessionConnection.session._database._allocator.destroy(sessionConnection);
	}
};
