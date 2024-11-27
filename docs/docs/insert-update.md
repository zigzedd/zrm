# Insert & update

To define and use inserts and updates, you must have a fully defined [repository](/docs/repositories). In this tutorial, we'll be assuming that we have a defined repository for a user model, as it's defined in [this section](/docs/repositories.html#define-a-repository).

Executing inserts and updates also require to [set up a connection to your database](/docs/database). We'll also be assuming that we have a working database connector set up, as it's defined in [this section](/docs/database#pool-connector).

## Insert

Just like queries, we can insert models using the type `Insert` published on repositories. With this type, the inserted shape is the default one of the repository. You can customize this structure by using `InsertCustom` function.

```zig
const insertQuery = UserRepository.Insert.init(allocator, poolConnector.connector());
// or
const insertQuery = UserRepository.InsertCustom(struct {
	id: i32,
	name: []const u8,
}).init(allocator, poolConnector.connector());
```

If you just need to insert a model without any other parameters, repositories provide a `create` function which do just that. The given model **will be altered** with inserted row data.

```zig
const results = UserRepository.create(allocator, poolConnector.connector(), model);
defer results.deinit();
```

### Values

With an insert query, we can pass our values to insert with the `values` function. This looks like [`set` function of update queries](#values-1).

```zig
// Insert a single model.
try insertQuery.values(model);
// Insert an array of models.
try insertQuery.values(&[_]Model{firstModel, secondModel});

// Insert a table-shaped structure.
try insertQuery.values(table);
// Insert an array of table-shaped structures.
try insertQuery.values(&[_]Model.Table{firstTable, secondTable});

// Insert a structure matching InsertShape.
try insertQuery.values(insertShapeStructure);
// Insert an array of structures matching InsertShape.
try insertQuery.values(&[_]Model.Table.Insert{firstInsertShape, secondInsertShape});
```

### Returning

It's often useful to retrieve inserted data after the query. One use case would for example to get the inserted auto-increment IDs of the models. We can do this using the `returningX` functions of the insert query builder.

::: danger
Never put user-sent values as selected columns. This could lead to severe security issues (like [SQL injections](https://en.wikipedia.org/wiki/SQL_injection)).
:::

#### Returning all

This will return all the columns of the inserted rows.

```zig
try insertQuery.values(...);
insertQuery.returningAll();
```

#### Returning columns

This will return all the provided columns of the inserted rows.

```zig
try insertQuery.values(...);
insertQuery.returningColumns(&[_][]const u8{"id", "name"});
```

#### Raw returning

We can also directly provide raw `RETURNING` clause content.

```zig
try insertQuery.values(...);
insertQuery.returning("id, label AS name");
```

### Results

We can perform the insertion by running `insert` on the insert query.

```zig
const results = try insertQuery.insert(allocator);
defer results.deinit();
```

The results of an insert query are the same as normal queries. You can find the documentation about it in [its dedicated section](/docs/queries#results).

## Update

To make an update query, we must provide the structure of the updated columns (called update shape).

```zig
const updateQuery = UserRepository.Update(struct { name: []const u8 }).init(allocator, poolConnector.connector());
```

If you just need to update a model without any other parameters, repositories provide a `save` function which do just that. The given model **will be altered** with updated row data.

```zig
const results = UserRepository.save(allocator, poolConnector.connector(), model);
defer results.deinit();
```

### Values

With an update query, we can set our updated values with the `set` function. This looks like [`values` function of insert queries](#values).

```zig
// Set data of a single model.
try updateQuery.set(model);
// Set data of an array of models.
try updateQuery.values(&[_]Model{firstModel, secondModel});

// Set data of a table-shaped structure.
try updateQuery.values(table);
// Set data of an array of table-shaped structures.
try updateQuery.values(&[_]Model.Table{firstTable, secondTable});

// Set data of a structure matching UpdateShape.
try updateQuery.values(myUpdate);
// Set data of an array of structures matching UpdateShape.
try updateQuery.values(&[_]UpdateStruct{myFirstUpdate, mySecondUpdate});
```

### Conditions

The conditions building API is the same as normal queries. You can find the documentation about it in [its dedicated section](/docs/queries#conditions).

### Returning

The returning columns API is the same as insert queries. You can find the documentation about it in [its dedicated section](#returning).

### Results

We can perform the update by running `update` on the update query.

```zig
const results = try updateQuery.update(allocator);
defer results.deinit();
```

The results of an update query are the same as normal queries. You can find the documentation about it in [its dedicated section](/docs/queries#results).
