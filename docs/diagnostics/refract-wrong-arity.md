# `refract-wrong-arity`

**Severity:** Warning · **Source:** refract · **Confidence:** type-aware

Refract flags this when a method call's argument count does not match the resolved method's arity. Example:

```ruby
class Greeter
  def hello(name) = "hi #{name}"
end

Greeter.new.hello("Alice", "Bob")  # ⚠ refract-wrong-arity: expected 1 arg, got 2
```

## Why

The method is statically resolvable to a known signature with arity 1. Two positional args raise `ArgumentError` at runtime.

## Caveats

Refract suppresses this diagnostic when:

- The method is `method_missing` or dispatches via `respond_to_missing?`.
- Any param has `**opts` or `*args` (catch-all).
- The receiver type is unknown or confidence < 70.
- The method was defined via `define_method` with a dynamic block (signature unknown).

## Fix

Match the signature. Use `--explain refract-wrong-arity` (MCP `explain_symbol`) to see the resolved sig.

## Disable

Per-line / per-file / per-workspace: same conventions as [`refract-nil-receiver`](refract-nil-receiver.md).
