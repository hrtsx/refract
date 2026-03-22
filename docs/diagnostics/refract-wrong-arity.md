# `refract/wrong-arity`

A call site passes more positional arguments than the called method's signature accepts.

## Why this might fire

Refract indexes parameter signatures from `def`, Sorbet `sig {}`, and RBS declarations. When a call site's argument count exceeds the method's positional parameter count, and the method does not declare a splat (`*args`) or keyword splat (`**opts`), Ruby will raise `ArgumentError` at runtime.

This check fires only when the receiver's type confidence is ≥70 and the method has a unique resolution. Calls into ambiguously-typed receivers, methods accepting `*args` or `**opts`, or methods overridden by mixins where resolution is uncertain are skipped.

## Example

```ruby
class Greeter
  def hello(name)
    puts name
  end
end

g = Greeter.new
g.hello("a", "b")   # refract/wrong-arity: hello takes 1 arg, got 2
```

## How to fix

Either the call site or the signature is wrong. Adjust whichever is correct:

```ruby
g.hello("a")          # match signature
# or
def hello(*names)     # accept variable arity
```

## Suppress

If this fires on a method whose true arity is dynamic (e.g., monkeypatched via `define_method` at runtime in a way Refract can't see), suppress per-workspace:

```sh
echo "refract/wrong-arity" >> .refract/disabled.txt
```
