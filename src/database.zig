const std = @import("std");
const pg = @import("pg");
const session = @import("session.zig");

/// Abstract connection, provided by a connector.
pub const Connection = struct {
	/// Raw connection.
	connection: *pg.Conn,

	/// Connection implementation.
	_interface: struct {
		instance: *anyopaque,
		release: *const fn (self: *Connection) void,
	},

	/// Release the connection.
	pub fn release(self: *Connection) void {
		self._interface.release(self);
	}
};

/// Database connection manager for queries.
pub const Connector = struct {
	const Self = @This();

	/// Internal interface structure.
	_interface: struct {
		instance: *anyopaque,
		getConnection: *const fn (self: *anyopaque) anyerror!*Connection,
	},

	/// Get a connection.
	pub fn getConnection(self: Self) !*Connection {
		return try self._interface.getConnection(self._interface.instance);
	}
};



/// A simple pool connection.
pub const PoolConnection = struct {
	const Self = @This();

	/// Connector of the connection.
	connector: *PoolConnector,
	/// Connection instance, to only keep one at a time.
	_connection: ?Connection = null,

	/// Get a database connection.
	pub fn connection(self: *Self) !*Connection {
		if (self._connection == null) {
			// A new connection needs to be initialized.
			self._connection = .{
				.connection = try self.connector.pool.acquire(),
				._interface = .{
					.instance = self,
					.release = releaseConnection,
				},
			};
		}

		// Return the initialized connection.
		return &(self._connection.?);
	}

	// Implementation.

	/// Release the pool connection.
	fn releaseConnection(self: *Connection) void {
		self.connection.release();

		// Free allocated connection.
		const poolConnection: *PoolConnection = @ptrCast(@alignCast(self._interface.instance));
		poolConnection.connector.pool._allocator.destroy(poolConnection);
	}
};

/// A simple pool connector.
pub const PoolConnector = struct {
	const Self = @This();

	pool: *pg.Pool,

	/// Get a database connector instance for the current pool.
	pub fn connector(self: *Self) Connector {
		return .{
			._interface = .{
				.instance = self,
				.getConnection = getConnection,
			},
		};
	}

	// Implementation.

	/// Get the connection from the pool.
	fn getConnection(opaqueSelf: *anyopaque) !*Connection {
		const self: *Self = @ptrCast(@alignCast(opaqueSelf));

		// Initialize a new connection.
		const poolConnection = try self.pool._allocator.create(PoolConnection);
		poolConnection.* = .{
			.connector = self,
		};

		// Acquire a new connection from the pool.
		return try poolConnection.connection();
	}
};
