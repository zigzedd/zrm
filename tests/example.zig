const std = @import("std");
const pg = @import("pg");
const zrm = @import("zrm");

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


pub const Media = struct {
	pub const Table = struct {
		id: i32,
		filename: []const u8,

		pub const Insert = struct {
			filename: []const u8,
		};
	};

	id: i32,
	filename: []const u8,
};
pub const MediaRepository = zrm.Repository(Media, Media.Table, .{
	.table = "example_medias",
	.insertShape = Media.Table.Insert,

	.key = &[_][]const u8{"id"},

	.fromSql = zrm.helpers.TableModel(Media, Media.Table).copyTableToModel,
	.toSql = zrm.helpers.TableModel(Media, Media.Table).copyModelToTable,
});

pub const User = struct {
	pub const Table = struct {
		id: i32,
		name: []const u8,
		picture_id: ?i32,

		pub const Insert = struct {
			name: []const u8,
			picture_id: ?i32,
		};
	};

	id: i32,
	name: []const u8,
	picture_id: ?i32,
	picture: ?Media = null,

	info: ?UserInfo = null,

	messages: ?[]Message = null,
	medias: ?[]Media = null,
};
pub const UserRepository = zrm.Repository(User, User.Table, .{
	.table = "example_users",
	.insertShape = User.Table.Insert,

	.key = &[_][]const u8{"id"},

	.fromSql = zrm.helpers.TableModel(User, User.Table).copyTableToModel,
	.toSql = zrm.helpers.TableModel(User, User.Table).copyModelToTable,
});
pub const UserRelations = UserRepository.relations.define(.{
	.picture = UserRepository.relations.one(MediaRepository, .{
		.direct = .{
			.foreignKey = "picture_id",
		}
	}),

	.info = UserRepository.relations.one(UserInfoRepository, .{
		.reverse = .{},
	}),

	.messages = UserRepository.relations.many(MessageRepository, .{
		.direct = .{
			.foreignKey = "user_id",
		},
	}),

	//TODO double through to get medias?
});

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

	//TODO is there a way to solve the "struct 'example.User' depends on itself" error when adding this relation?
	// user: ?User = null,
};
pub const UserInfoRepository = zrm.Repository(UserInfo, UserInfo.Table, .{
	.table = "example_users_info",
	.insertShape = UserInfo.Table.Insert,

	.key = &[_][]const u8{"user_id"},

	.fromSql = zrm.helpers.TableModel(UserInfo, UserInfo.Table).copyTableToModel,
	.toSql = zrm.helpers.TableModel(UserInfo, UserInfo.Table).copyModelToTable,
});
pub const UserInfoRelations = UserInfoRepository.relations.define(.{
	// .user = UserInfoRepository.relations.one(UserRepository, .{
	// 	.direct = .{
	// 		.foreignKey = "user_id",
	// 	},
	// }),
});

pub const Message = struct {
	pub const Table = struct {
		id: i32,
		text: []const u8,
		user_id: i32,

		pub const Insert = struct {
			text: []const u8,
			user_id: i32,
		};
	};

	id: i32,
	text: []const u8,
	user_id: i32,
	user: ?User = null,
	user_picture: ?Media = null,
	medias: ?[]Media = null,
};
pub const MessageRepository = zrm.Repository(Message, Message.Table, .{
	.table = "example_messages",
	.insertShape = Message.Table.Insert,

	.key = &[_][]const u8{"id"},

	.fromSql = zrm.helpers.TableModel(Message, Message.Table).copyTableToModel,
	.toSql = zrm.helpers.TableModel(Message, Message.Table).copyModelToTable,
});
pub const MessageRelations = MessageRepository.relations.define(.{
	.user = MessageRepository.relations.one(UserRepository, .{
		.direct = .{
			.foreignKey = "user_id",
		}
	}),

	.user_picture = MessageRepository.relations.one(MediaRepository, .{
		.through = .{
			.table = "example_users",
			.foreignKey = "user_id",
			.joinForeignKey = "id",
			.joinModelKey = "picture_id",
		},
	}),

	.medias = MessageRepository.relations.many(MediaRepository, .{
		.through = .{
			.table = "example_messages_medias",
			.joinModelKey = "message_id",
			.joinForeignKey = "media_id",
		},
	}),
});


test "user picture media" {
	zrm.setDebug(true);

	try initDatabase(std.testing.allocator);
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	var firstQuery = UserRepository.QueryWith(
		// Retrieve picture of users.
		&[_]zrm.relations.Relation{UserRelations.picture}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try firstQuery.whereKey(1);
	defer firstQuery.deinit();

	var firstResult = try firstQuery.get(std.testing.allocator);
	defer firstResult.deinit();

	try std.testing.expectEqual(1, firstResult.models.len);
	try std.testing.expectEqual(1, firstResult.models[0].picture_id);
	try std.testing.expectEqual(1, firstResult.models[0].picture.?.id);
	try std.testing.expectEqualStrings("profile.jpg", firstResult.models[0].picture.?.filename);



	var secondQuery = UserRepository.QueryWith(
		// Retrieve picture of users.
		&[_]zrm.relations.Relation{UserRelations.picture}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try secondQuery.whereKey(3);
	defer secondQuery.deinit();

	var secondResult = try secondQuery.get(std.testing.allocator);
	defer secondResult.deinit();

	try std.testing.expectEqual(1, secondResult.models.len);
	try std.testing.expectEqual(2, secondResult.models[0].picture_id);
	try std.testing.expectEqual(2, secondResult.models[0].picture.?.id);
	try std.testing.expectEqualStrings("profile.png", secondResult.models[0].picture.?.filename);



	var thirdQuery = UserRepository.QueryWith(
		// Retrieve picture of users.
		&[_]zrm.relations.Relation{UserRelations.picture}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try thirdQuery.whereKey(5);
	defer thirdQuery.deinit();

	var thirdResult = try thirdQuery.get(std.testing.allocator);
	defer thirdResult.deinit();

	try std.testing.expectEqual(1, thirdResult.models.len);
	try std.testing.expectEqual(null, thirdResult.models[0].picture_id);
	try std.testing.expectEqual(null, thirdResult.models[0].picture);



	var fourthQuery = UserRepository.QueryWith(
	// Retrieve picture of users.
		&[_]zrm.relations.Relation{UserRelations.picture}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try fourthQuery.whereKey(19);
	defer fourthQuery.deinit();

	var fourthResult = try fourthQuery.get(std.testing.allocator);
	defer fourthResult.deinit();

	try std.testing.expectEqual(0, fourthResult.models.len);
}


test "user has info" {
	zrm.setDebug(true);

	try initDatabase(std.testing.allocator);
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	var firstQuery = UserRepository.QueryWith(
		// Retrieve info of users.
    &[_]zrm.relations.Relation{UserRelations.info}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try firstQuery.whereKey(2);
	defer firstQuery.deinit();

	var firstResult = try firstQuery.get(std.testing.allocator);
	defer firstResult.deinit();

	try std.testing.expectEqual(1, firstResult.models.len);
	try std.testing.expect(firstResult.models[0].info != null);
	try std.testing.expectEqual(2, firstResult.models[0].info.?.user_id);
	try std.testing.expectEqual(876348000000000, firstResult.models[0].info.?.birthdate);



	var secondQuery = UserRepository.QueryWith(
		// Retrieve info of users.
    &[_]zrm.relations.Relation{UserRelations.info}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try secondQuery.whereKey(1);
	defer secondQuery.deinit();

	var secondResult = try secondQuery.get(std.testing.allocator);
	defer secondResult.deinit();

	try std.testing.expectEqual(1, secondResult.models.len);
	try std.testing.expect(secondResult.models[0].info == null);
}


test "user has many messages" {
	zrm.setDebug(true);

	try initDatabase(std.testing.allocator);
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	var firstQuery = UserRepository.QueryWith(
		// Retrieve messages of users.
		&[_]zrm.relations.Relation{UserRelations.messages}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try firstQuery.whereKey(1);
	defer firstQuery.deinit();

	var firstResult = try firstQuery.get(std.testing.allocator);
	defer firstResult.deinit();

	try std.testing.expectEqual(1, firstResult.models.len);
	try std.testing.expect(firstResult.models[0].messages != null);
	try std.testing.expectEqual(3, firstResult.models[0].messages.?.len);

	for (firstResult.models[0].messages.?) |message| {
		if (message.id == 2) {
			try std.testing.expectEqualStrings("I want to test something.", message.text);
		} else if (message.id == 3) {
			try std.testing.expectEqualStrings("Lorem ipsum dolor sit amet", message.text);
		} else if (message.id == 6) {
			try std.testing.expectEqualStrings("foo bar baz", message.text);
		} else {
			try std.testing.expect(false);
		}
	}



	var secondQuery = UserRepository.QueryWith(
		// Retrieve messages of users.
		&[_]zrm.relations.Relation{UserRelations.messages}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try secondQuery.whereKey(5);
	defer secondQuery.deinit();

	var secondResult = try secondQuery.get(std.testing.allocator);
	defer secondResult.deinit();

	try std.testing.expectEqual(1, secondResult.models.len);
	try std.testing.expect(secondResult.models[0].messages != null);
	try std.testing.expectEqual(0, secondResult.models[0].messages.?.len);
}



test "message has many medias through pivot table" {
	zrm.setDebug(true);

	try initDatabase(std.testing.allocator);
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	var firstQuery = MessageRepository.QueryWith(
		// Retrieve medias of messages.
		&[_]zrm.relations.Relation{MessageRelations.medias}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try firstQuery.whereKey(1);
	defer firstQuery.deinit();

	var firstResult = try firstQuery.get(std.testing.allocator);
	defer firstResult.deinit();

	try std.testing.expectEqual(1, firstResult.models.len);
	try std.testing.expect(firstResult.models[0].medias != null);
	try std.testing.expectEqual(1, firstResult.models[0].medias.?.len);
	try std.testing.expectEqualStrings("attachment.png", firstResult.models[0].medias.?[0].filename);



	var secondQuery = MessageRepository.QueryWith(
		// Retrieve medias of messages.
		&[_]zrm.relations.Relation{MessageRelations.medias}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try secondQuery.whereKey(6);
	defer secondQuery.deinit();

	var secondResult = try secondQuery.get(std.testing.allocator);
	defer secondResult.deinit();

	try std.testing.expectEqual(1, secondResult.models.len);
	try std.testing.expect(secondResult.models[0].medias != null);
	try std.testing.expectEqual(2, secondResult.models[0].medias.?.len);

	for (secondResult.models[0].medias.?) |media| {
		if (media.id == 3) {
			try std.testing.expectEqualStrings("attachment.png", media.filename);
		} else if (media.id == 5) {
			try std.testing.expectEqualStrings("music.opus", media.filename);
		} else {
			try std.testing.expect(false);
		}
	}



	var thirdQuery = MessageRepository.QueryWith(
		// Retrieve medias of messages.
		&[_]zrm.relations.Relation{MessageRelations.medias}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try thirdQuery.whereKey(4);
	defer thirdQuery.deinit();

	var thirdResult = try thirdQuery.get(std.testing.allocator);
	defer thirdResult.deinit();

	try std.testing.expectEqual(1, thirdResult.models.len);
	try std.testing.expect(thirdResult.models[0].medias != null);
	try std.testing.expectEqualStrings("Je pense donc je suis", thirdResult.models[0].text);
	try std.testing.expectEqual(0, thirdResult.models[0].medias.?.len);
}

test "message has one user picture URL through users table" {
	zrm.setDebug(true);

	try initDatabase(std.testing.allocator);
	defer database.deinit();
	var poolConnector = zrm.database.PoolConnector{
		.pool = database,
	};

	var firstQuery = MessageRepository.QueryWith(
		// Retrieve user pictures of messages.
		&[_]zrm.relations.Relation{MessageRelations.user_picture}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try firstQuery.whereKey(1);
	defer firstQuery.deinit();

	var firstResult = try firstQuery.get(std.testing.allocator);
	defer firstResult.deinit();

	try std.testing.expectEqual(1, firstResult.models.len);
	try std.testing.expect(firstResult.models[0].user_picture != null);
	try std.testing.expectEqualStrings("profile.jpg", firstResult.models[0].user_picture.?.filename);



	var secondQuery = MessageRepository.QueryWith(
		// Retrieve user pictures of messages.
		&[_]zrm.relations.Relation{MessageRelations.user_picture}
	).init(std.testing.allocator, poolConnector.connector(), .{});
	try secondQuery.whereKey(4);
	defer secondQuery.deinit();

	var secondResult = try secondQuery.get(std.testing.allocator);
	defer secondResult.deinit();

	try std.testing.expectEqual(1, secondResult.models.len);
	try std.testing.expect(secondResult.models[0].user_picture == null);
}

//TODO try to load all one relations types in another query (with buildQuery).
