# Migrate from Solargraph

## TL;DR

1. Remove `solargraph` from your Gemfile.
2. Install refract.
3. Point editor at `refract --stdio`.
4. Open workspace.

## Parity matrix

| Feature                      | Solargraph | refract |
|------------------------------|------------|---------|
| hover / def / refs / rename  | ✅         | ✅ (faster — see BENCHMARK) |
| YARD doc rendering           | ✅         | ✅      |
| RBS / type hints             | partial    | ✅ (RBS + Sorbet + Steep) |
| Rails route awareness        | ❌         | ✅ (extensive) |
| ERB embedded ruby            | partial    | ✅      |
| inline AI completion         | ❌         | ✅      |
| Debug Adapter (DAP)          | ❌         | ✅      |
| Memory ceiling at scale      | 355–1271 MB | 26–55 MB (per BENCHMARK) |

## Behavioral differences

- **Cold start.** Solargraph 6–180 s before first answer (depending on workspace + bundle install). Refract 16–57 ms — workspace is indexed lazily as files open, then in background.
- **YARD docs.** Solargraph treats YARD as primary type source. Refract reads YARD into `params.description` and `doc_blocks`, but type resolution is RBS-first; YARD `@param [Type]` tags feed into the chain when no higher-confidence source is available.
- **Reek / RuboCop / etc.** Solargraph dispatches to a configurable formatter via its plugin system. Refract spawns RuboCop directly and namespaces additional sources (`brakeman/<code>`, `semgrep/<rule_id>`).

## Configuration mapping

| Solargraph setting               | refract equivalent                |
|----------------------------------|-----------------------------------|
| `.solargraph.yml: include`       | scanner default + `.refract/include.txt` |
| `.solargraph.yml: exclude`       | `${workspace}/.refract/exclude.txt` |
| `.solargraph.yml: reporters`     | `executeCommand: refract.recheckRubocop` |
| `bundler: true`                  | auto-detect via `Gemfile.lock` + `bundle exec` probe |
| custom YARD path                 | refract scans `.yardoc/` automatically |

## Rollback

Same as ruby-lsp — refract state is contained under `.refract/`. Reinstall solargraph, restart editor.
