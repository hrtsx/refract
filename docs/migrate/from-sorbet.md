# Migrate from Sorbet (alone)

If you've been running `srb tc` or the Sorbet LSP and want to move to Refract — or run them side-by-side — read on.

## Refract reads Sorbet's output

Refract does **not** replace Sorbet's type checker. Instead, it ingests Sorbet results into a unified type oracle and surfaces them in hover, completion, and diagnostics. Run Sorbet as before; Refract picks up `.rbi` files and `srb tc --lsp` results automatically.

```bash
bundle exec srb init                                    # if not already
refract --doctor                                        # confirms `srb` was found
```

The `Type bridges` line in `refract --doctor` shows `sorbet: ok` when wired up correctly.

## Type confidence

Each type result has a confidence score 0-100. Refract sorts results in this order:

1. Sorbet (`# typed: strict` files): 95
2. Sorbet (`# typed: true`): 90
3. Steep: 85
4. RBS sigs: 80
5. YARD `@return` / `@param`: 60
6. Method-chain inference: 40-70 (decays per hop)
7. Literal inference: 30
8. Universal Object fallback: 10

Hover shows the highest-confidence result. `explain_type_chain` (MCP tool) shows all of them.

## What Refract gives you that Sorbet alone doesn't

- Hover, definition, completion, references, rename, code actions — full LSP 3.17. Sorbet's LSP is hover/def-only and slow.
- 30 MCP tools for LLM coding agents.
- Built-in DAP (`refract --dap`) proxying rdbg.
- RuboCop, Brakeman, Semgrep diagnostics out of the box.
- No annotation overhead — works on a fresh codebase with zero `.rbi` files.

## Side-by-side workflow

```jsonc
// .refractrc.json
{
  "sorbet": {
    "enabled": true,
    "typed_only": true,        // skip files without `# typed: true`
    "min_confidence": 80       // hide low-confidence guesses when Sorbet has an answer
  }
}
```

In this mode, Refract trusts Sorbet for typed files and uses its own inference everywhere else. Diagnostics are deduplicated — if Sorbet reports an error at line 42, Refract suppresses its own diagnostic at the same location.

## Switching off Sorbet entirely

```bash
refract --doctor                # confirm RBS / YARD give acceptable coverage
git rm -r sorbet/
```

Refract works without Sorbet. The cost is lower confidence on advanced cases (generics, refinements). The benefit is no annotation maintenance.
