# Contributing to Refract

## Development Setup

### Prerequisites
- Zig 0.16.0 or later
- Ruby (for testing integration)

### Build from Source

```bash
git clone https://github.com/Hirintsoa/refract.git
cd refract
zig build
```

### Running Tests

```bash
zig build test --summary all
```

All tests must pass before submitting a PR. The test suite provides comprehensive coverage of the LSP protocol implementation and indexing logic.

### Code Formatting

Before committing, ensure all code is formatted:

```bash
zig fmt .
```

This is enforced in CI. Improperly formatted code will fail the build.

## Contributing Guidelines

### General Rules

1. **No empty error handling**: Avoid `catch {}` without justification. If you must suppress an error, add a brief comment explaining why.
   - Good: `indexer.reindex(...) catch { self.sendLogMessage(2, "reindex failed"); };`
   - Avoid: `indexer.reindex(...) catch {};`

2. **Test isolation**: When adding new tests, use unique `/tmp/refract_test_*` directories for workspace isolation. Always clean up with `defer` statements.

3. **Documentation**: Keep code self-documenting where possible. Add comments for non-obvious logic.

### Pull Request Process

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes and ensure tests pass
4. Run `zig fmt .` to format code
5. Commit with clear, descriptive messages
6. Push to your fork and open a PR

### Code Review

All PRs require review before merging. Please be responsive to feedback and ready to iterate on your implementation.

### Testing Requirements

- Add tests for any new functionality
- All tests must pass before submitting a PR
- Tests should use isolated directories to prevent cross-test pollution

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design overview.

## Questions?

Open an issue or start a discussion.
