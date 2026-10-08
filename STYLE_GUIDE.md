# Style guide for coding in weft

## snake_case !!!

Let's use snake case please. I know I'm asking a lot from you.

## Use on ly {} when needed

In most cases, simple if, for and while don't need {}

```zig
for(foo) |bar|
  continue
else
  ...;

if(foo)
  ...
else if(bar)
  ...
else
  ..;
```

The only exception would be when you use a for-else which contains another control flow:

```zig
for(foo) |bar| {
  if(bar)
    break bar;
} else false;

// of course this ain't very beatiful

//NOT THIS
for(foo) |bar| 
  if(bar)
    break bar;
  else {}
else false;
```

## Naming allocators

The first arguments to a function are they allocators it uses. A function usually needs just two allocators,
a `gpa` which comes first. The gpa is used for performing operations inside the function, and `ara` which is usually useful for
leaky functions and implies it should be passed an arena allocator.
The last allocator is `alloc` which is a function-scoped arena allocator.

```zig
fn load_config_leaky(gpa: std.mem.Allocator, ara: std.mem.Allocator) Config {
  // use the gpa here where you can free the result
  const path = gpa.print("/tmp/config.zon");
  defer gpa.free(path);

  // the returned Config will depend on this file_contents, so it can not be freed here, and since it is not
  // returned it must use the arena allocator so it can be freed
  const file_contents = read_file_content(ara, path);

  return zero_copy_parse(Config, .{
    .gpa = gpa,
    .arena = ara,
    .content = file_contents,
  });
}
```

## Functions taking an `ara` must have the `_leaky` suffix

if a function makes non-tracable allocations which need to be freed, and thus takes an `ara`, then it should have the `_leaky` suffix.

## specify the type in the type annotations, not the value

an example here

```zig
// GOOD
var arena: std.heap.ArenaAllocator = .init(gpa);
// BAD
var arena = std.heap.ArenaAllocator.init(gpa);
```

## Always put else clauses when needed

Even if the content of an if statement returns on a success condition and the rest of the function won't run, use else if possible, except the blocks really differ much in length.

```zig
// BAD
fn foo() void {
  if(...) 
    return;
  ...;
}
// GOOD
fn foo() void {
  if(...) 
    return;
  else
    ...;
}
// BETTER (for one-liners)
fn foo() void {
  return if(...)
    ...
  else
    ...;
}
```

## Always put if, else, for, orelse, catch clauses on a new line || expand function call before catch clauses

```zig
// GOOD
foo(
  
) catch |err| { // always put catch on a new line
  ..
};

if(foo)
  ...
else
  ...;
// BAD
foo() catch |err| {
  ...
};

if(foo) ... else ...;
```
The only exception is for small `orelse` and `catch` clauses with little content. like `catch foo.bar()` or `orelse 5`.

## Use alloc.print instead of std.fmt.allocPrint
Just a note because we're in zig 0.17 which adds this new method.


```zig
// GOOD
const str = try alloc.print("hello {s}", .{name});

// BAD
const str = try std.fmt.allocPrint(alloc, "hello {s}", .{name});
```

## Use only unmanaged hashmaps and array lists

Avoid managed container types where the allocator is stored inside the container struct. Use unmanaged containers and pass the allocator explicitly on each operation:the object usually only need to store a fixedbuffer allocator or an arena allocatorplea.
```zig
{
  // GOOD
  var list: std.ArrayListUnmanaged(u8) = .empty;
  defer list.deinit(gpa);
  try list.append(gpa, 42);

  var map: std.StringHashMapUnmanaged(Item) = .empty;
  defer map.deinit(gpa);
}
```



## Avoid comments

Avoid comments please, we always prefare descriptive variable names, closing expressions in a `blk: {break :blk;}` block.
Doc comments are acceptable though, but even those should be avoided as in this stage that's just more work.


## Avoid mutable variables

Instead of flags, try to use builtin `for else` or a block and break:

```zig
const status = status: {
  var temp = ...;

  break :status tmp;
};
```

## Name loop labels as you name the variable

If you have a `for` loop, name the loop label after the **captured variable** (e.g. `|bar|`). Same for assignments: name the block label after the variable to which it is assigned.

```zig
bar: for (foo) |bar|
  break :bar;

const status = status: {
  ...
  break :status tmp;
};
```

## Avoid returning inside control flows

When possible, it is better to return the `for` or `if` or `while` rather than having several return statements.
This rules applies in other places too, prefare using the control flow as an expression than doing the same return/call at the end of each branch.

## Always pass io

`io`, just like `gpa` and `ara` should always be passed as a function argument, and not be stored in the object, the object usually only need to store a fixedbuffer allocator or an arena allocator.

## Use `return try` when returning from a call which can fail


