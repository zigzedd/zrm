const std = @import("std");
const zrm = @import("zrm");

test "zrm.conditions.value" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const condition = try zrm.conditions.value(usize, arena.allocator(), "test", "=", 5);

	try std.testing.expectEqualStrings("test = ?", condition.sql);
	try std.testing.expectEqual(1,	condition.params.len);
	try std.testing.expectEqual(5,	condition.params[0].integer);
}

test "zrm.conditions.in" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const condition = try zrm.conditions.in(usize, arena.allocator(), "intest", &[_]usize{2, 3, 8});

	try std.testing.expectEqualStrings("intest IN (?,?,?)", condition.sql);
	try std.testing.expectEqual(3,	condition.params.len);
	try std.testing.expectEqual(2,	condition.params[0].integer);
	try std.testing.expectEqual(3,	condition.params[1].integer);
	try std.testing.expectEqual(8,	condition.params[2].integer);
}

test "zrm.conditions.column" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const condition = try zrm.conditions.column(arena.allocator(), "firstcol", "<>", "secondcol");

	try std.testing.expectEqualStrings("firstcol <> secondcol", condition.sql);
	try std.testing.expectEqual(0,	condition.params.len);
}

test "zrm.conditions combined" {
	var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
	defer arena.deinit();

	const condition = try zrm.conditions.@"and"(arena.allocator(), &[_]zrm.SqlParams{
		try zrm.conditions.value(usize, arena.allocator(), "test", "=", 5),
		try zrm.conditions.@"or"(arena.allocator(), &[_]zrm.SqlParams{
			try zrm.conditions.in(usize, arena.allocator(), "intest", &[_]usize{2, 3, 8}),
			try zrm.conditions.column(arena.allocator(), "firstcol", "<>", "secondcol"),
		}),
	});

	try std.testing.expectEqualStrings("(test = ? AND (intest IN (?,?,?) OR firstcol <> secondcol))", condition.sql);
	try std.testing.expectEqual(4,	condition.params.len);
	try std.testing.expectEqual(5,	condition.params[0].integer);
	try std.testing.expectEqual(2,	condition.params[1].integer);
	try std.testing.expectEqual(3,	condition.params[2].integer);
	try std.testing.expectEqual(8,	condition.params[3].integer);
}
