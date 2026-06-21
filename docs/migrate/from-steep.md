# Migrate from Steep (alone)

[Steep](https://github.com/soutaro/steep) is Soutaro Matsumoto's RBS-based type checker. Refract integrates with Steep the same way it does with Sorbet: ingests results, never replaces.

## Refract reads Steep's output

```bash
bundle exec steep init
bundle exec steep check                            # generate type results
refract --doctor                                   # confirms `steep` was found
```

The `Type bridges` line in `refract --doctor` shows `steep: ok` when wired.

## What Refract adds

- Steep's LSP supports hover, definition, completion. Refract adds: rename, references, code actions, document symbol, semantic tokens, inlay hints, signature help, type hierarchy, call hierarchy.
- 30 MCP tools for agents.
- Faster startup. Steep cold-start is 5-10 s on a Rails monolith. Refract is 50-150 ms.

## Side-by-side workflow

```jsonc
// .refractrc.json
{
  "steep": {
    "enabled": true,
    "config_path": "Steepfile",
    "min_confidence": 75
  }
}
```

Steep continues to type-check on save (or via `steep watch`). Refract reads the latest results and weights them at 85 confidence — below Sorbet strict, above RBS sigs alone.

## Where Steep wins

- Generics. `Array[T]`, `Hash[K, V]` with proper variance.
- Flow-sensitive narrowing on union types.
- RBS-first ergonomics: types live in `sig/` next to source.

Use Steep for the cases where you want type guarantees. Use Refract for everything else (search, refactor, agent tools, debugger).

## Switching off Steep entirely

Without Steep, Refract falls back to RBS sigs (read directly from `sig/*.rbs`) and inference. Confidence on union narrowing drops. Most navigation and search workflows are unaffected.
