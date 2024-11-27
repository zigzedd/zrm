# Database

As a database-to-zig mapper, ZRM obviously needs to connect to a database to operate. All interactions with ZRM features will first need to define a database connection.

::: info
ZRM currently only supports PostgreSQL through [pg.zig](https://github.com/karlseguin/pg.zig). More DBMS's support is [planned](https://code.zeptotech.net/zedd/zrm/issues/8).
:::

## Connection

As ZRM is currently using [pg.zig](https://github.com/karlseguin/pg.zig) to connect to PostgreSQL databases, you can find a full documentation and example on the [pg.zig documentation](https://github.com/karlseguin/pg.zig#example).

```zig
const database = try pg.Pool.init(allocator, .{
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
```

## Connector

ZRM does not use opened connections directly. All features use a generic interface called a `Connector`. A connector manages how connections are opened and released for a group of operations. There are currently two types of connectors in ZRM.

### Pool connector

The pool connector simply use a `pg.Pool` to get connections when needed. The only requirement is an opened database pool from pg.zig.

```zig
var poolConnector = zrm.database.PoolConnector{
	.pool = database,
};
```

### Session connector

A session connector use a single connection while it is initialized, which is very useful when you want to perform a group of operations in a transaction. The deinitialization releases the connection.

```zig
// Start a new session.
var session = try zrm.Session.init(database);
defer session.deinit();
```

Using sessions, you can start transactions and use savepoints.

```zig
try session.beginTransaction();

// Do something.

try session.savepoint("my_savepoint");

// Do something else.

try session.rollbackTo("my_savepoint");

// Do a third thing.

try session.commitTransaction();
// or
try session.rollbackTransaction();
```
