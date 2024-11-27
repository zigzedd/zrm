# Documentation

Welcome to the ZRM documentation!

ZRM is a try to make a fast and efficient zig-native [ORM](https://en.wikipedia.org/wiki/Object%E2%80%93relational_mapping) (Object Relational Mapper). With ZRM, you can define your zig models structures and easily link them to your database tables.

ZRM is using [compile-time features](https://ziglang.org/documentation/0.13.0/#toc-comptime) of the zig language to do a lot of generic work you clearly don't want to do.

## How does it look like?

```zig
/// User model.
pub const User = struct {
	pub const Table = struct {
		id: i32,
		name: []const u8,

		pub const Insert = struct {
			name: []const u8,
		};
	};

	id: i32,
	name: []const u8,
	info: ?UserInfo = null,
};
/// Repository of User model.
pub const UserRepository = zrm.Repository(User, User.Table, .{
	.table = "example_users",
	.insertShape = User.Table.Insert,

	.key = &[_][]const u8{"id"},

	.fromSql = zrm.helpers.TableModel(User, User.Table).copyTableToModel,
	.toSql = zrm.helpers.TableModel(User, User.Table).copyModelToTable,
});
/// Relationships of User model.
pub const UserRelationships = UserRepository.relationships.define(.{
	.info = UserRepository.relationships.one(UserInfoRepository, .{
		.reverse = .{},
	}),
});

/// User info model.
pub const UserInfo = struct {
	pub const Table = struct {
		user_id: i32,
		birthdate: i64,

		pub const Insert = struct {
			user_id: i32,
			birthdate: i64,
		};
	};

	user_id: i32,
	birthdate: i64,

	user: ?*User = null,
};
/// Repository of UserInfo model.
pub const UserInfoRepository = zrm.Repository(UserInfo, UserInfo.Table, .{
	.table = "example_users_info",
	.insertShape = UserInfo.Table.Insert,

	.key = &[_][]const u8{"user_id"},

	.fromSql = zrm.helpers.TableModel(UserInfo, UserInfo.Table).copyTableToModel,
	.toSql = zrm.helpers.TableModel(UserInfo, UserInfo.Table).copyModelToTable,
});
/// Relationships of UserInfo model.
pub const UserInfoRelationships = UserInfoRepository.relationships.define(.{
	.user = UserInfoRepository.relationships.one(UserRepository, .{
		.direct = .{
			.foreignKey = "user_id",
		},
	}),
});



// Initialize a query to get users.
var firstQuery = UserRepository.QueryWith(
	// Retrieve info of users.
  &[_]zrm.relationships.Relationship{UserRelationships.info}
).init(std.testing.allocator, poolConnector.connector(), .{});
// We want to get the user with ID 2.
try firstQuery.whereKey(2);
defer firstQuery.deinit();

// Executing the query and getting its result.
var firstResult = try firstQuery.get(std.testing.allocator);
defer firstResult.deinit();

if (firstResult.first()) |myUser| {
	// A user has been found.
	std.debug.print("birthdate timestamp: {d}\n", .{user.info.birthdate});
	// Changing user name.
	myUser.name = "zrm lover";
	// Saving the altered user.
	const saveResult = UserRepository.save(allocator, poolConnector.connector(), myUser);
	defer saveResult.deinit();
} else {
	std.debug.print("no user with id 2 :-(\n", .{});
}
```

## Discover

This documentation will help you to discover all the features provided by ZRM and how you can use them in your project. We'll cover [installation](/docs/install), [database connection](/docs/database), [repository declaration](/docs/repositories), [queries](/docs/queries), [insertions and updates](/docs/insert-update), and [relationships](/docs/relationships). Most examples are based on a test file, [`tests/example.zig`](https://code.zeptotech.net/zedd/zrm/src/branch/main/tests/example.zig), which demonstrates and tests models, repositories, relationships and queries.
