# Repositories

The first concept that ZRM introduces is a pretty common one: **repositories**. Repositories are the main interface for you to access what is stored in database, or to store anything in it. It is the _bridge_ between your model (a normal zig structure) and the table in database.

## Define a model

There's nothing special to do to define a model to use with ZRM. Let's start with a simple user model.

```zig
const User = struct {
	id: i32,
	name: []const u8,
};
```

It's a quite simple structure, but you'll quickly add more things when working with it, so let's define another structure that will hold the structure of the user in database.

```zig
const User = struct {
	pub const Table = struct {
		id: i32,
		name: []const u8,
	};
	
	id: i32,
	name: []const u8,
};
```

For now, `User` and `User.Table` are the same, but this will change as we add more features to our user.

## Define a repository

Now, let's define a repository for our `User` model.

```zig
const UserRepository = zrm.Repository(User, User.Table, .{
	// ...
});
```

A repository is mainly based on 2 structures: the model and the table. These are the first two arguments. Next, it's a configuration object, with the following mandatory values:

- `table`: the table in which the models are stored.
- `insertShape`: the inserted columns by default. See [Insert & update](/docs/insert-update#insert) for more info.
- `key`: array of fields / columns to use as primary keys.
- `fromSql` / `toSql`: functions to convert tables to models and models to tables, which are used when getting and storing data.

Let's define all these fields:

```zig
const User = struct {
	pub const Table = struct {
		id: i32,
		name: []const u8,
		
		pub const Insert = struct {
			name: []const u8,
		};
	};

	id: i32,
	name: []const u8,
};

const UserRepository = zrm.Repository(User, User.Table, .{
	.table = "example_users",
	.insertShape = User.Table.Insert,

	.key = &[_][]const u8{"id"},

	.fromSql = userFromSql,
	.toSql = userToSql,
});

fn userFromSql(table: User.Table) User {
	return .{
		.id = table.id,
		.name = table.name,
	};
}

fn userToSql(user: User) User.Table {
	return .{
		.id = user.id,
		.name = user.name,
	};
}
```

We created a new structure for `insertShape`: it's the same as `User.Table`, but without the ID, as it will be automatically filled by the database when inserting (assuming that its column is defined as _auto-incrementing on insert_).

You may see that current implementation of `userFromSql` and `userToSql` is a bit useless. Luckily, ZRM provides a helper function to automatically generate them.

```zig{7,8}
const UserRepository = zrm.Repository(User, User.Table, .{
	.table = "example_users",
	.insertShape = User.Table.Insert,

	.key = &[_][]const u8{"id"},

	.fromSql = zrm.helpers.TableModel(User, User.Table).copyTableToModel,
	.toSql = zrm.helpers.TableModel(User, User.Table).copyModelToTable,
});
```

It's finally done! Our repository is fully defined. As you can see we defined the following:

- where to store the models in database (which table).
- what will be inserted.
- what are the primary keys of the model.
- how to format stored data and how to get them from their stored form.

These are all the info required by ZRM to know how to deal with your models. We can now have a look to [how to retrieve models from database](/docs/queries).
