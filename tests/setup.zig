const std = @import("std");
const pg = @import("pg");

/// PostgreSQL database connection.
var database: *pg.Pool = undefined;

/// Initialize database connection.
fn initDatabase() !void {
	database = try pg.Pool.init(std.heap.page_allocator, .{
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

pub fn main() !void {
	try initDatabase();
	_ = try database.exec(@embedFile("initdb.sql"), .{});
}
