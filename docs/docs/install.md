# Installation

You can easily install ZRM using the `zig fetch` command:

```shell
$ zig fetch --save https://code.zeptotech.net/zedd/zrm/archive/v0.3.0.tar.gz
```

::: info
You can tweak the version if you want to use something else than the latest stable one, you can find all available versions in [the tags page](https://code.zeptotech.net/zedd/zrm/tags) on the repository.
:::

This should add something like the following in `build.zig.zon` dependencies:

```zon
.{
	// ...
	.dependencies = .{
		// ...
		.zrm = .{
			.url = "https://code.zeptotech.net/zedd/zrm/archive/v0.3.0.tar.gz",
			.hash = "12200fe147879d72381633e6f44d76db2c8a603cda1969b4e474c15c31052dbb24b7",
		},
		// ...
	},
	// ...
}
```

Then, you can add the `zrm` module to your project build in `build.zig`.

```zig
// Add zrm dependency.
const zrm = b.dependency("zrm", .{
	.target = target,
	.optimize = optimize,
});
exe.root_module.addImport("zrm", zrm.module("zrm"));
```

You can now start to use ZRM! Why not trying to define [your first repository](/docs/repositories)?
