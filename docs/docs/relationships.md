# Relationships

To define and use relationships, you must have a fully defined [repository](/docs/repositories). In this tutorial, we'll be assuming that we have a defined repository for a user model, as it's defined in [this section](/docs/repositories.html#define-a-repository).

Executing queries also require to [set up a connection to your database](/docs/database). We'll also be assuming that we have a working database connector set up, as it's defined in [this section](/docs/database#pool-connector).

## What is a relationship?

Before starting to define our relationships, let's try to define what they are. A relationship is a logical connection between models. In real-world applications, models are often connected between each other, and that's why we even made _relational_ databases.

If we are trying to create an easy model of a chat room, we could have two main entities:

- the chatters, that we will then call "users".
- the messages.

There is a relationship between a message and a user, because a message is always written by _someone_. In relational databases, we use foreign keys to represent this relationship (we would store a `user_id` in the `messages` table). But in programming languages, we manipulate structures and objects directly, so it can be a pain to perform operations with indexed maps or arrays.

That's why ORM are now so common in object-oriented languages. They greatly simplify the use of database-stored models, even sometimes completely hiding this fact. Zig structures are sometimes quite similar to objects of object-oriented languages, so simplifying interactions between zig structures and database tables is important.

## Define relationships

In ZRM, we define relationships on a repository. The defined relationships are stored in a comptime-known structure, reusable when building a model query.

```zig
const UserRelationships = UserRepository.relationships.define(.{
	// Here, we can define the relationships of the User model.
});
```

The field where the related models will be stored after retrieval is the one with the same name in the relationships structure.

```zig
const UserRelationships = UserRepository.relationships.define(.{
	// Will put the related model in `relatedModel` field of User structure:
	.relatedModel = UserRepository.relationships.one(.{...}),
	// Will put the related models in `relatedModels` field of User structure:
	.relatedModels = UserRepository.relationships.many(.{...}),
});
```

## `one` relationships

This type of relationship is used when only a single model is related. In our chat example, the relationship type between a message and a user is "one", as there's only one message author.

### Direct

![Direct one relation diagram](/relationships/one-direct.svg)

The direct one relationship uses a local foreign key to get the related model. In other libraries, this type of relationship can be referred as "belongs to". It has two parameters:

- **mandatory** `foreignKey`: name of the field / column where the related model key is stored.
- _optional_ `modelKey`: name of the key of the related model. When none is provided, the default related model key name is used (it's usually the right choice).

```zig
const MessageRelationships = MessageRepository.relationships.define(.{
	.user = MessageRepository.relationships.one(UserRepository, .{
		.direct => .{
			.foreignKey = "user_id",
		},
	}),
});
```

### Reverse

![Reverse one relation diagram](/relationships/one-reverse.svg)

The reverse one relationship uses a distant foreign key to get the related model. It can be used to get related models when they hold a foreign key to the origin model. In other libraries, this type of relationship can be referred as "has one". It has two parameters:

- _optional_ `foreignKey`: name of the field / column where the related model key is stored. When none is provided, the default related model key name is used.
- _optional_ `modelKey`: name of the key of the origin model. When none is provided, the default origin model key name is used (it's usually the right choice).

```zig
const UserRelationships = UserRepository.relationships.define(.{
	.info = UserRepository.relationships.one(UserInfoRepository, .{
		.reverse = .{
			.foreignKey = "user_id", // this is optional if "user_id" is the defined primary key of UserInfoRepository.
		},
	}),
});
```

### Through

![Through one relation diagram](/relationships/one-through.svg)

The through one relationship uses a pivot table to get the related model. It can be used to get related models when the foreign key is hold by an intermediate table. In other libraries, this type of relationship can be referred as "has one through". It has five parameters:

- **mandatory** `table`: name of the pivot / intermediate / join table.
- _optional_ `foreignKey`: name of the foreign key in the origin table. When none is provided, the default origin model key name is used (it's usually the right choice).
- **mandatory** `joinForeignKey`: name of the foreign key in the intermediate table. Its value will match the one in `foreignKey`.
- **mandatory** `joinModelKey`: name of the related model key name in the intermediate table. Its value will match the one in `modelKey`.
- _optional_ `modelKey`: name of the model key in the related table. When none is provided, the default related model key name is used (it's usually the right choice).

```zig
const MessageRelationships = MessageRepository.relationships.define(.{
	.user = MessageRepository.relationships.one(UserRepository, .{
		.direct = .{
			.foreignKey = "user_id",
		}
	}),

	.user_picture = MessageRepository.relationships.one(MediaRepository, .{
		.through = .{
			.table = "example_users",
			.foreignKey = "user_id",
			.joinForeignKey = "id",
			.joinModelKey = "picture_id",
		},
	}),
});
```

## `many` relationships

This type of relationship is used when only a many models are related. In our chat example, the relationship type between a user and messages is "many", as an author can write multiple messages.

### Direct

![Direct many relation diagram](/relationships/many-direct.svg)

The direct many relationship uses a distant foreign key to get related models. It's often used at the opposite side of a direct one relationship. In other libraries, this type of relationship can be referred as "has many". It has two parameters:

- **mandatory** `foreignKey`: name of the field / column where the origin model key is stored.
- _optional_ `modelKey`: name of the key of the origin model. When none is provided, the default origin model key name is used (it's usually the right choice).

```zig
const UserRelationships = UserRepository.relationships.define(.{
	.messages = UserRepository.relationships.many(MessageRepository, .{
		.direct = .{
			.foreignKey = "user_id",
		},
	}),
});
```

### Through

![Through many relation diagram](/relationships/many-through.svg)

The through many relationship uses a pivot table to get the related models. It can be used to get related models when the foreign key is hold by an intermediate table. In other libraries, this type of relationship can be referred as "belongs to many". It has five parameters:

- **mandatory** `table`: name of the pivot / intermediate / join table.
- _optional_ `foreignKey`: name of the foreign key in the origin table. When none is provided, the default origin model key name is used (it's usually the right choice).
- **mandatory** `joinForeignKey`: name of the foreign key in the intermediate table. Its value will match the one in `foreignKey`.
- **mandatory** `joinModelKey`: name of the related model key name in the intermediate table. Its value will match the one in `modelKey`.
- _optional_ `modelKey`: name of the model key in the related table. When none is provided, the default related model key name is used (it's usually the right choice).

```zig
const MessageRelationships = MessageRepository.relationships.define(.{
	.medias = MessageRepository.relationships.many(MediaRepository, .{
		.through = .{
			.table = "example_messages_medias",
			.joinModelKey = "message_id",
			.joinForeignKey = "media_id",
		},
	}),
});
```

## Query related models

Now that our relationships are defined, we can query our models with their relationships directly with the `QueryWith` function of the repository. `QueryWith` takes an array of `Relationship` structures, which are created by `Repository.relationships.define`. To get relationships along with the models, you just need to fill this array with the requested relationships.

```zig
// Initialize a user query, with their messages.
var userQuery = UserRepository.QueryWith(
	// Get messages of retrieved users.
	&[_]zrm.relationships.Relationship{UserRelationships.messages}
).init(std.testing.allocator, poolConnector.connector(), .{});
try userQuery.whereKey(1);
defer userQuery.deinit();

// Get the queried user with their messages.
var userResult = try userQuery.get(std.testing.allocator);
defer userResult.deinit();

if (userResult.first()) |user| {
	// The user has been found, showing their messages.
	for (user.messages.?) |message| {
		std.debug.print("{s}: {s}", .{user.name, message.text});
	}
}
```
