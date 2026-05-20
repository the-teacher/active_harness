# Contributing to ActiveHarness

Thank you for your interest in contributing!

> **Note:** This project is under active development. The API may change between versions.
> If you are planning a large contribution, please open an issue first to discuss the direction.

## AI-Assisted Development

This project is developed with the help of AI tools (GitHub Copilot, Claude, etc.).
Contributors are welcome to use AI assistance as well — just review and understand
every line before submitting.

## Getting Started

```bash
git clone https://github.com/the-teacher/active_harness.git
cd active_harness
bundle install
```

Run the test suite:

```bash
bundle exec rake test
```

## Project Structure

```
lib/
├── active_harness.rb          # entry point
└── active_harness/
    ├── agent.rb               # Agent base class
    ├── tribunal.rb            # Tribunal base class
    ├── pipeline.rb            # Pipeline base class
    ├── memory.rb              # Memory class
    ├── result.rb              # Result value object
    ├── agent/                 # Agent internals (hooks, models, prompt, etc.)
    ├── providers/             # HTTP adapters per provider
    ├── http/                  # Low-level HTTP client
    └── core/                  # Shared errors and utilities
test/
    └── active_harness/        # Minitest test files
```

## Guidelines

- **Describe the idea clearly.** Every issue or PR must include: what problem it solves, what the proposed solution is, and a concrete usage example. Inconsistent or vague descriptions will be asked to be revised before review.
- **One concern per PR.** Bug fixes, features, and refactors should be separate pull requests.
- **Minimize external runtime dependencies.** The gem currently depends only on `concurrent-ruby`. New dependencies are not forbidden, but must be justified — prefer solving things in Ruby first.
- **Ruby 2.6+ compatibility.** Avoid syntax unavailable in Ruby 2.6 (no endless `def`, no numbered block params).
- **Style.** Follow the existing code style. No linter is enforced — use common sense.

## Adding a Provider

1. Create `lib/active_harness/providers/<name>.rb` subclassing `Providers::Base`.
2. Implement `#call` — return a `Result` object.
3. Register the provider symbol in `lib/active_harness/agent/providers.rb`.
4. Add a test in `test/active_harness/providers/`.
5. Document the new provider in `README.PROVIDERS.md`.

## Reporting Bugs

Please open a GitHub issue with:

- Ruby version and gem version
- Minimal reproduction script
- Expected vs actual behaviour

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
