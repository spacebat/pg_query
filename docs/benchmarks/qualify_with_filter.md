# `qualify_with_filter` benchmark

Performance cost of the tenant-filter rewrite pass relative to plain
schema-qualification (Task 09). Regenerate with:

```
bundle exec ruby bin/benchmark_qualify.rb
```

Numbers vary by machine; what matters for rollout is the **relative** cost of
the filter pass over `qualify`, which is small and stable across runs. The
filter pass runs as a second AST walk after qualification, so its overhead
scales with query size, not as a fixed multiple.

## Results

Captured on Linux x86_64, CRuby 3.4, `benchmark-ips` (10s/report, 3s warmup).
Representative queries are the existing small (~300 byte CTE+JOIN) and large
(~3 KB recursive-CTE) benchmark fixtures in `bin/benchmark_qualify.rb`.

| Query | Method | Throughput (i/s) | Per call (µs) | vs `qualify` |
|-------|--------|------------------|---------------|--------------|
| Small | `qualify`              | 9,120 | 109.7 | — |
| Small | `qualify_with_filter`  | 7,896 | 126.7 | ~1.16× slower (+17 µs) |
| Large | `qualify`              | 1,225 | 816.2 | — |
| Large | `qualify_with_filter`  | 1,145 | 873.2 | ~1.07× slower (+57 µs) |

## Reading the numbers

- The filter pass adds roughly **15–20 µs** to a small query and **~55–60 µs**
  to a large one — a single-digit-to-mid-teens percentage on top of
  qualification, dominated in both cases by the underlying parse/deparse the
  query already pays for.
- `qualify` and `qualify_with_funcs` are within measurement error of each other,
  as before; adding `func_names` is effectively free.
- These are in-process rewrite costs only. The injected predicates also change
  what the database executes; that execution cost is out of scope here.

## Memory safety

The native rewrite path is exercised under Valgrind in CI (the `memcheck` job
in `.github/workflows/ci.yml`) running `spec/lib/qualify_spec.rb` with
`--leak-check=full --errors-for-leak-kinds=definite` and the
`.valgrind-ruby.supp` suppression file for interpreter noise. See that task's
open note about first-run suppression tuning.
