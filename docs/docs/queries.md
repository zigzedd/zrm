# Queries

To define and use queries, you must have a fully defined [repository](/docs/repositories). In this tutorial, we'll be assuming that we have a defined repository for a user model, as it's defined in [this section](/docs/repositories.html#define-a-repository).

Executing queries also require to [set up a connection to your database](/docs/database). We'll also be assuming that we have a working database connector set up, as it's defined in [this section](/docs/database#pool-connector).

## Query building

ZRM repositories provide a model query builder by default. We can access it from the published type `Query`.

### Basics

Let's start with the most simple query we can make.

```zig
var myFirstQuery = UserRepository.Query.init(
	allocator, poolConnector.connector(), .{}
);
defer myFirstQuery.deinit();
```

As you can see, we're creating a new query instance with our [previously defined connector](/docs/database#pool-connector). The last argument has no mandatory fields, but here are all the available options:

- `select`: a raw query part where we can set all columns that we want to select. By default, all columns of the table are retrieved (in the form of `"table_name".*`).
- `join`: a raw query part where we can set all joined tables. By default, nothing is set (~ empty string) and there will be no `JOIN` clause.
- `where`: a raw query part where we can set all the conditions to apply to the query. By default, nothing is set and there will be no `WHERE` clause.

::: warning
It is currently **NOT recommended** to use these variables to build your queries. This configuration object is experimental and might be used later to define comptime-known parts of the query, and may also be entirely removed.
:::

Based on the current configuration, we can execute this query as is, and ZRM will try to get **all** models in the defined table.

### Conditions

::: warning
Calling any of the `whereX` functions on a query overrides anything that has been previously set. If you call `whereValue` two times, only the secondly defined condition will be kept. If you need to have multiple conditions at once, you should use the [conditions builder](/docs/queries#conditions-builder).
:::

#### Simple value

Add a condition between a column and a runtime value. The type of the value must be provided as a first argument. Any valid SQL operator is accepted.

```zig
try query.whereValue(usize, "id", "!=", 1);
try query.whereValue(f32, "\"products\".\"amount\"", "<", 35.25);
```

#### Primary keys

Add a condition on the primary keys. If the primary key is composite, a structure with all the keys values is expected.

```zig
// Find the model with ID 1.
try query.whereKey(1);
// Find the model with primary key ('foo', 'bar').
try compositeQuery.whereKey(.{ .identifier = "foo", .name = "bar" });
```

The provided argument can also be an array of keys.

```zig
// Find models with ID 1 or 3.
try query.whereKey(&[_]usize{1, 3});
// Find models with primary key ('foo', 'bar') or ('baz', 'test').
try compositeQuery.whereKey(&[_]struct{identifier: []const u8, name: []const u8}{
	.{ .identifier = "foo", .name = "bar" },
	.{ .identifier = "baz", .name = "test" }
});
```

If you just need to get models from their ID without any other condition, repositories provide a `find` function which do just that.

```zig
const models = UserRepository.find(allocator, poolConnector.connector(), 1);
```

#### Array

Add a `WHERE column IN` condition.

```zig
try query.whereIn(usize, "id", &[_]usize{1, 2});
```

#### Column

Add a condition between two columns in the query. The columns name all must be comptime-known.

```zig
try query.whereColumn("products.amount", "<", "clients.available_amount");
```

#### Conditions builder

Sometimes, we need to build complex conditions. For this purpose, we can use the conditions builder.

The recommended way to initialize a conditions builder is to use the query, as the built conditions will be freed when the query is deinitialized.

```zig
try query.newCondition()
```

We can also directly use the conditions builder with our own allocator.

```zig
try zrm.conditions.Builder.init(allocator);
```

With the conditions builder, we can build complex conditions with AND / OR and different types of tests.

```zig
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
// will produce the following WHERE clause:
// WHERE (id = ? OR (id IN (?,?,?) AND (amount > ? OR name = ?)))
```

#### Raw where

To set a raw `WHERE` clause content, we can use the `where` function.

```zig
query.where(zrm.RawQuery{
	.sql = "id = ?",
	.params = &[_]zrm.RawQueryParameter{.{.integer = 1}}
});
```

### Joins

::: warning
ZRM currently only supports **raw joins** definitions. Real join definition functions are expected to come in next releases.
:::

To set a raw `JOIN` clause, we can use the `join` function.

```zig
query.join(zrm.RawQuery{
	.sql = "INNER JOIN foo ON user.id = foo.user_id",
	.params = &[0]zrm.RawQueryParameter{}
});
// or
query.join(zrm.RawQuery{
	.sql = "LEFT JOIN foo ON foo.id = ?",
	.params = &[_]zrm.RawQueryParameter{.{.integer = 1}}
});
```

### Selects

::: danger
**Never** put user-sent values as selected columns. This could lead to severe security issues (like [SQL injections](https://en.wikipedia.org/wiki/SQL_injection)).
:::

#### Columns

We can select specific columns in a query with `selectColumns`. At least one selected column is required.

```zig
try query.selectColumns(&[_][]const u8{"id", "label AS name", "amount"});
```

#### Raw select

To set a raw `SELECT` clause content, we can use the `select` function.

```zig
query.where(zrm.RawQuery{
	.sql = "id, label AS name, amount",
	.params = &[0]zrm.RawQueryParameter{}
});
```

## Results

When our query is fully configured, we can finally call `get` to retrieve the results. We must provide an allocator to hold all the allocated models and their values. The results don't require the query to be kept, so we **can** run `query.deinit()` after getting the results without losing what has been retrieved.

```zig
var result = try query.get(allocator);
defer result.deinit();
```

The result structure allows to access the models list or the first model directly, if we just want a single one (or made sure that only one has been retrieved).

```zig{4,8}
var result = try query.get(allocator);
defer result.deinit();

if (result.first()) |model| {
	// Do something with the first model.
}

for (result.models) |model| {
	// Do something with all models.
}
```

The query builder allows you to get zig models from the database, but you may also need to [store them in database](/docs/insert-update) after creating or altering them.
