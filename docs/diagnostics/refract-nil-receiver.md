# `refract-nil-receiver`

**Severity:** Warning · **Source:** refract · **Confidence:** type-aware

Refract flags this when a method call is statically resolvable to a receiver whose type chain ends in `nil`. Example:

```ruby
user = User.find_by(email: "x")
user.name  # ⚠ refract-nil-receiver: User#find_by may return nil
```

## Why

`User.find_by` returns `User | nil` in the RBS sig. Calling `.name` on a `nil` raises `NoMethodError`.

## Fix

Use `&.`, an explicit `if user`, or a non-nil-returning method:

```ruby
user&.name                                # safe navigation
User.find_by!(email: "x").name           # raises ActiveRecord::RecordNotFound instead
if user then user.name end               # narrowed
```

## Confidence

Refract requires at least 80 confidence on the receiver's type before emitting this warning. Tune via `.refractrc.json`:

```json
{
  "diagnostics": {
    "typeCheckerConfidence": { "nilReceiver": 80 }
  }
}
```

Higher = fewer false positives. Lower = more aggressive flagging.

## Disable

Per-line:

```ruby
user.name  # refract:disable-line refract-nil-receiver
```

Per-file:

```ruby
# refract:disable-file refract-nil-receiver
```

Per-workspace, in `.refractrc.json`:

```json
{ "diagnostics": { "disabled": ["refract-nil-receiver"] } }
```
