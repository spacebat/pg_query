# pg_query Ruby Extension Agent Guide

## General
- **Code priority**: Code should be clear and readable first, correct second, and performant third.
- **Test stability**: Ensure that your changes do not break other tests in the project, unless it is unavoidable.
- **Units of work**: When a task has completed and all tests pass, make a commit.

## Commands
- **Build**: `rake compile` (compiles C extension)
- **Test**: `rake spec` or `bundle exec rspec`
- **Test single file**: `bundle exec rspec spec/lib/fingerprint_spec.rb`
- **Lint**: `rake rubocop` or `bundle exec rubocop`
- **All checks**: `rake` (runs spec + lint)

## Architecture
- **Core**: PostgreSQL query parser C extension wrapping libpg_query
- **Main module**: `PgQuery` with methods: `parse`, `normalize`, `fingerprint`, `scan`
- **Key components**: Parser, Normalizer, Fingerprinter, Deparser, Tree walker
- **External deps**: libpg_query (PostgreSQL parser), protobuf for serialization

## Code Style
- **Lint**: RuboCop with custom rules (see .rubocop.yml)
- **Tests**: RSpec with SimpleCov coverage
- **Requires**: Ruby 3.0+ with google-protobuf dependency
- **Conventions**: Snake_case, no frozen string literals, module functions over class methods
- **Files**: lib/pg_query/ for modules, spec/lib/ for tests, ext/pg_query/ for C extension
