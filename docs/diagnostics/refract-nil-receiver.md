# `refract/nil-receiver`

A method is being called on a receiver whose inferred type is `NilClass`.

## Why this might fire

Refract narrows local-variable types through assignments, conditionals, and predicates. When a local variable's type narrows to `NilClass` (for example, after `x = nil` or because the only branch that sets `x` did not execute), any subsequent method call on that receiver will raise `NoMethodError` at runtime.

This check fires only when the receiver's type confidence is high enough — Sorbet sigs (90), RBS sigs (90), and literal narrowing (85) all clear the bar. Method-chain inference (38–55) is excluded by design to avoid false positives.

## Example

```ruby
x = nil
x.foo   # refract/nil-receiver: NoMethodError at runtime
```

## How to fix

If `nil` is a real possibility, gate the call:

```ruby
x&.foo                 # safe nav: returns nil if x is nil
x ? x.foo : default    # explicit branch
```

If `nil` should never reach this point, narrow the type earlier with `raise` / `return` or with type annotations:

```ruby
raise "x must be set" if x.nil?
x.foo                  # narrowed to non-nil after the guard
```

## Suppress

If this fires on intentional code (e.g., a test that asserts the raise), suppress per-workspace:

```sh
echo "refract/nil-receiver" >> .refract/disabled.txt
```
