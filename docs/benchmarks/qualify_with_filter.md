# `qualify_with_filter` benchmark

Performance cost of the tenant-filter rewrite pass relative to plain
schema-qualification (Task 09). Regenerate with:

```
bundle exec ruby bin/benchmark_qualify.rb
```

Numbers vary by machine; what matters for rollout is the **relative** cost of
the filter pass over `qualify`, which is small. The filter pass runs as a second
AST walk after qualification, so its overhead scales with query size and with
which rewrite path a statement hits — and in every case it is dwarfed by the
parse/deparse the query already pays for.

## Filter overhead vs plain qualify

Same query, `qualify` vs `qualify_with_filter`, on the small (~300 byte CTE+JOIN)
and large (~3 KB recursive-CTE) fixtures. Captured on Linux x86_64, CRuby 3.4,
`benchmark-ips` (10s/report, 3s warmup).

| Query | Method | Throughput (i/s) | Per call (µs) | vs `qualify` |
|-------|--------|------------------|---------------|--------------|
| Small | `qualify`              | 8,673 | 115.3 | — |
| Small | `qualify_with_filter`  | 7,487 | 133.6 | ~1.16× slower (+18 µs) |
| Large | `qualify`              | 1,115 | 897.2 | — |
| Large | `qualify_with_filter`  | 1,121 | 892.4 | within noise (≈ free) |

The filter pass adds ~18 µs to the small query; on the large query it is lost in
run-to-run variance (the parse/deparse of a 3 KB query dominates everything).

The large fixtures above are filter-*light* (one simple WHERE on a big query).
The `LargeFilterHeavy` fixture is the opposite — a ~1.2 KB query that triggers
many transform sites in one statement (two CTE bodies, several outer joins
including USING/NATURAL derived-table wrapping and a nullable join-subtree,
correlated subqueries, IN-subqueries: ~13 predicate injections and 6 derived
tables in the rewritten output):

| Query | Method | Throughput (i/s) | Per call (µs) | vs `qualify` |
|-------|--------|------------------|---------------|--------------|
| LargeFilterHeavy | `qualify`             | 2,104 | 475.3 | — |
| LargeFilterHeavy | `qualify_with_filter` | 1,671 | 598.5 | ~1.26× slower (+123 µs) |

Even with a lot to rewrite in a single statement, the filter pass adds ~123 µs
(~26%) over qualification — a modest, roughly linear overhead in the number of
transform sites, with no pathological blow-up. (This query parses faster than
the 3 KB recursive-CTE fixture above, so its absolute i/s is higher; the +123 µs
delta is the figure of interest.)

## Cost by rewrite path

Each fixture isolates one tenant-filter rewrite path. These are short queries, so
absolute throughput is high and reflects mostly the per-path AST work plus the
(small) parse/deparse, not query size. Per-call µs is the useful column for
comparing paths.

| Rewrite path | Fixture | Throughput (i/s) | Per call (µs) |
|--------------|---------|------------------|---------------|
| Plain `WHERE` predicate injection      | `SimpleWhere`  | 15,531 | 64.4 |
| Outer `USING` → filtered derived table | `UsingWrap`    | 25,853 | 38.7 |
| `NATURAL` outer → derived table        | `NaturalWrap`  | 26,937 | 37.1 |
| `RETURNING` subquery descent           | `Returning`    | 15,639 | 63.9 |
| `INSERT … VALUES` payload injection    | `InsertValues` | 22,036 | 45.4 |

Reading it: the per-call differences track query size and parse/deparse work more
than the rewrite itself — the `USING`/`NATURAL` fixtures are the smallest inputs
and so the fastest, even though derived-table wrapping builds the most AST. The
`SimpleWhere` and `Returning` fixtures are slowest because their queries are
larger (a JOIN with a predicate, an UPDATE with a correlated subquery), not
because predicate/RETURNING handling is expensive. No path is an outlier: the
tenant-filter rewrite is cheap across the board relative to parse/deparse.

These are in-process rewrite costs only. The injected predicates also change what
the database executes; that execution cost is out of scope here.

## Memory safety

The native rewrite path is checked under Valgrind in CI (Task 09), in two tiers
(see `.github/workflows/ci.yml`):

- **`memcheck-c` (blocking):** a Ruby-free C harness, `bin/run_memcheck.sh` →
  `ext/pg_query/qualify_memcheck.c`, drives the rewrite API directly across every
  shape (USING/NATURAL wrapping, RETURNING subqueries, INSERT VALUES inject +
  refusal, strict vs non-strict). No interpreter, so `--error-exitcode=1` is a
  trustworthy gate. Verified clean: 0 errors, 0 definite/indirect leaks.
- **`memcheck-ruby` (informational):** the full qualify spec under Valgrind,
  `continue-on-error`. CRuby's conservative GC reports leaks that all originate
  in the `ruby` binary, not pg_query; `.valgrind-ruby.supp` cuts the bulk so the
  log is readable. Kept to surface a binding-level leak if one ever appears.
