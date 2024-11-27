<p align="center">
	<a href="https://code.zeptotech.net/zedd/zrm">
		<picture>
			<img alt="ZRM logo" width="150" src="https://code.zeptotech.net/zedd/zrm/raw/branch/main/logo.svg" />
		</picture>
	</a>
</p>

<h1 align="center">
	ZRM
</h1>

<h4 align="center">
	<a href="https://zedd.zeptotech.net/zrm">Documentation</a>
|
	<a href="https://zedd.zeptotech.net/zrm/api">API</a>
</h4>

<p align="center">
	Zig relational mapper
</p>

ZRM is part of [_zedd_](https://code.zeptotech.net/zedd), a collection of useful libraries for zig.

## ZRM

_ZRM_ provides a simple interface to relational databases in Zig. Define your repositories and easily write queries to retrieve and save complex Zig structures.

## Versions

ZRM 0.2.0 is made and tested with zig 0.13.0.

## Work in progress

ZRM aims to handle a lot for you, but it takes time to make. Have a look to [the issues](https://code.zeptotech.net/zedd/zrm/issues) to see what is currently planned or being worked on.

## How to use

### Install

In your project directory:

```shell
$ zig fetch --save https://code.zeptotech.net/zedd/zrm/archive/v0.2.0.tar.gz
```

In `build.zig`:

```zig
// Add zrm dependency.
const zrm = b.dependency("zrm", .{
	.target = target,
	.optimize = optimize,
});
exe.root_module.addImport("zrm", zrm.module("zrm"));
```

### Documentation

A full documentation can be found on [zedd.zeptotech.net/zrm](https://zedd.zeptotech.net/zrm).

### Examples

Some examples can be found in `tests` directory:

- [`tests/example.zig`](https://code.zeptotech.net/zedd/zrm/src/branch/main/tests/example.zig)
- [`tests/repository.zig`](https://code.zeptotech.net/zedd/zrm/src/branch/main/tests/repository.zig)
- [`tests/composite.zig`](https://code.zeptotech.net/zedd/zrm/src/branch/main/tests/composite.zig)
