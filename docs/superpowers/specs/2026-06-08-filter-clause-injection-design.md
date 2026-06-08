# Filter Clause Injection — Design

**Date:** 2026-06-08
**Branch:** sql-qualification
**Status:** Approved design, ready for implementation plan

## Goal

Extend the existing SQL table-qualification feature so that, optionally, a
row-restricting filter predicate is injected into every part of a query that
selects or affects rows. The typical use is `sbid = N` where `N` is an integer:
every table in the query must be constrained to a single `sbid`, so that no
query can read or modify data belonging to another `sbid`.

The filter is **always injected** — never merely checked. Injecting `sbid = N`
is idempotent: if a query already constrains `sbid = N`, adding it again has no
effect on the result. This removes the need to detect whether a filter is
already present.

## Non-Goals

- We do not validate that a table actually has the `sbid` column. Tables known
  not to have it are handled via an explicit exclusion list (below). A
  non-excluded table without the column will produce SQL that Postgres rejects —
  that is the caller's responsibility to configure correctly.
- We do not support arbitrary predicate expressions or non-integer values in
  this iteration. The filter is exactly `column = <integer>`.
- We do not change the existing `qualify` / `qualify_with_funcs` behavior.

## API Surface

A new Ruby entry point, parallel to the existing ones:

```ruby
PgQuery.qualify_with_filter(
  sql,
  schema,
  filter_column: "sbid",
  filter_value:  42,
  filter_exclude: ["countries", "lookup_%"], # optional; % = prefix match
  func_names:     []                          # optional; existing behavior
)
```

- Returns the rewritten SQL string, or `nil` on parse/deparse failure —
  identical contract to the current `qualify`.
- `filter_column` + `filter_value` together specify the predicate
  `column = value`. `filter_value` is an integer.
- `filter_exclude` is a list of table names that must **not** receive the
  filter (e.g. reference/lookup tables with no `sbid` column). Matching reuses
  the existing convention from `func_names`: exact match, or prefix match when
  the entry ends in `%` (e.g. `lookup_%` matches `lookup_regions`). Matching is
  against the table's `relname` (not schema-qualified).
- `func_names` is carried through so callers can combine filter injection with
  function qualification in a single pass.

The existing `qualify` and `qualify_with_funcs` methods are unchanged. All three
funnel into one C function; a NULL `filter_column` means "no filter injection".

### C signature

```c
char* pg_query_qualify_sql_full(
    const char* sql, const char* schema,
    const char** func_names, int func_count,
    const char* filter_column, int filter_value,
    const char** filter_exclude, int filter_exclude_count);
```

`pg_query_qualify_sql` and `pg_query_qualify_sql_with_funcs` become thin wrappers
that call this with `filter_column = NULL`.

## Structure: Two Independent Passes

The feature is implemented as a **second tree-walk that is independent of the
existing `qualify_node` walk**. The proven qualification code is left untouched.

The composition inside the C entry point is sequential:

```
nodes = parse(sql)
qualify_node(nodes, ...)      // pass 1 — existing, unchanged
filter_node(nodes, ...)       // pass 2 — new, runs only if filter_column != NULL
deparse(nodes)
```

### Why two passes (and why they stay independent)

- **No risk to production behavior.** Pass 1 (`qualify_node`) is 600+ lines,
  handles ~40 node types, and has nine months of production hardening. Merging
  the filter logic into it would mean editing ~70 recursive call sites and the
  hot scope/join cases in place — every edit a regression opportunity on code
  that currently works. A separate pass touches none of it; the blast radius of
  any filter bug is confined to the new feature.

- **The coupling is one-way and resolved by ordering.** Pass 2 only ever
  *reads* the tree pass 1 produced, and only mutates fields pass 1 does not care
  about. There is no shared mutable state. In fact pass 2 does not even *depend*
  on pass 1 having run — filter-only (no schema qualification) would behave
  identically — they are simply composed in sequence.

  - Exclusion matching is against `relname`, which pass 1 never modifies (it
    only sets `schemaname`).
  - The predicate's reference name (`alias.sbid`, else `relname.sbid`) uses the
    alias or `relname` — again fields pass 1 does not change.

- **No re-entrancy hazard.** Pass 2 builds new nodes (`ColumnRef`, `A_Expr`,
  `A_Const`) and appends them to clauses. Because pass 1 has already completed
  before pass 2 starts, those new nodes can never be fed back into
  qualification — the hazard is eliminated by construction, not by care.

A function-pointer / visitor-array refactor of the single walk was considered
and rejected: it is the most invasive option (it rewrites the proven recursion
into a generic driver) and only pays off for 3+ transforms. For two transforms
it adds complexity rather than removing it (YAGNI).

## Injection Algorithm (Pass 2)

Pass 2 runs after qualification, so table names are already schema-qualified and
CTE references already de-qualified. `filter_node` is a focused walk that only
handles **scope-bearing nodes** (SELECT / UPDATE / DELETE / INSERT / CTE /
RangeSubselect / SubLink and the join tree within a scope). It ignores the ~40
leaf node types that pass 1 handles — there is no need to re-implement the full
switch.

### Scopes

Each `SELECT` / `UPDATE` / `DELETE` statement defines a **scope**. Within a
scope we walk its FROM/join tree, collecting every real-table reference
(`RangeVar`) together with:

1. The **reference name** used to address it: its alias if it has one, else its
   `relname`.
2. Whether it sits on the **nullable side** of an outer join.

`UPDATE` and `DELETE` have a target relation plus optional `FROM`/`USING`
tables; all are collected the same way (the target relation is non-nullable).

### Walking the join tree (nullability classification)

```
collect_tables(node, nullable):
  RangeVar       → if relname not excluded, record { ref_name, nullable }
  RangeSubselect → run the filter pass into the subquery (its own scope);
                   do NOT record the wrapper (the derived table has no sbid)
  RangeFunction  → skip (e.g. unnest(...))
  JoinExpr j:
    LEFT  → collect(j.larg, nullable);      collect(j.rarg, nullable = true)
    RIGHT → collect(j.larg, nullable=true); collect(j.rarg, nullable)
    FULL  → collect(j.larg, true);          collect(j.rarg, true)
    INNER / CROSS → both sides inherit the current `nullable`
```

A table introduced on the nullable side **by a particular join** has its
predicate placed in **that join's `ON` clause** (`j.quals`). All non-nullable
tables have their predicates placed in the scope's `WHERE` clause.

### Predicate construction

For a table referenced as `t`, build the AST for `t.<filter_column> = <value>`:

- `A_Expr` with kind `=`
- left: `ColumnRef` of `{ t, filter_column }`
- right: `A_Const` holding an `Integer` node with value `filter_value`

Because the value is a real integer const node, the deparser emits
`t.sbid = 42` with no quoting concerns. Multiple predicates within the same
target clause are combined with `AND` (a `BoolExpr` of kind `AND_EXPR`, or
appended to an existing one).

### Placement rules

- **Non-nullable tables** (the base/target table and inner-joined tables) →
  AND into the scope's `WHERE` clause, creating the clause if absent.
- **A table on the nullable side of an outer join** → AND into **that join's**
  `ON` clause. This preserves outer-join result shape: the row set the
  application receives is unchanged; we only attach matching, in-scope rows.

### Why nullable side goes to ON (outer-join semantics)

Putting `o.sbid = N` in `WHERE` for a `LEFT JOIN orders o` would drop every
outer row where `o` is NULL (because `NULL = N` is false), silently converting
the LEFT JOIN to an INNER JOIN and changing which rows the application sees.
Putting it in the join's `ON` instead preserves the LEFT JOIN: every in-scope
left row still appears, with order columns NULL when there is no matching,
in-scope order. The same rule generalizes to RIGHT (left side nullable) and
FULL (both nullable). In all cases scoping still holds — a NULL `sbid` on a
missing side is not data from another `sbid`, it is simply absent.

### Recursion

Each of these inner queries is its own scope and receives the same treatment:

- Subqueries in `FROM` (`RangeSubselect`)
- Subqueries in expressions (`SubLink`), reached **anywhere** an expression can
  appear, not just the obvious clauses. Pass 2 descends every expression subtree
  with PostgreSQL's `raw_expression_tree_walker`, so a subquery hidden inside a
  `coalesce(...)`, `CASE`, function argument, `IN (..., (SELECT ...))` value
  list, a `JOIN ... ON` predicate, `ORDER BY` / `GROUP BY` / `DISTINCT ON`,
  `LIMIT` / `OFFSET`, a `VALUES` list, or an `ON CONFLICT DO UPDATE SET` is still
  found and scoped. (Earlier iterations enumerated a fixed set of expression node
  types and leaked subqueries nested under any unenumerated container — using the
  generic walker closes that whole class.)
- Subqueries in the target list and `HAVING`
- CTE bodies (`WITH ... AS (SELECT ...)`) — filtered at the definition site
- `INSERT ... SELECT` — the SELECT is scoped
- `CREATE VIEW AS`, `CREATE TABLE AS` — the defining query is scoped

CTE *references* appearing in a FROM clause are treated like derived tables: the
wrapper is not filtered (it has no `sbid`); the CTE body is filtered where it is
defined. CTE-name scoping mirrors the existing `qualify_node` mechanism (a
`cte_names` list threaded through the walk, honoring `WITH RECURSIVE` ordering),
so a real table is never suppressed except where its name genuinely shadows a CTE
in scope (the same trade-off the qualification pass already makes).

The reach goal is concrete: **every real table reference, at any nesting depth,
in any clause, receives its `sbid` predicate.** The generic expression walker is
what makes that guarantee hold rather than depending on a hand-maintained list of
clauses.

### Statements with nothing to filter

- `INSERT ... VALUES` — no row-selection clause; nothing injected.
- DDL that only names a target table (CREATE TABLE, DROP, etc.) — nothing
  injected unless it contains a defining query (see Recursion).

## Worked Example

Input:

```sql
SELECT u.name, o.total
FROM users u
LEFT JOIN orders o ON u.id = o.user_id
JOIN regions r ON u.region_id = r.id
```

With `filter_column: "sbid"`, `filter_value: 42`:

- `users u` — base table, not nullable → WHERE
- `regions r` — inner-joined, not nullable → WHERE
- `orders o` — nullable side of the LEFT JOIN → that join's ON

Output:

```sql
SELECT u.name, o.total
FROM users u
LEFT JOIN orders o ON u.id = o.user_id AND o.sbid = 42
JOIN regions r ON u.region_id = r.id
WHERE u.sbid = 42 AND r.sbid = 42
```

## Error Handling

- Parse failure, deparse failure, or any caught error in the C layer → return
  `nil` (matching existing `qualify` behavior).
- Memory management follows the existing pattern: enter/exit memory context,
  free protobuf and deparse results, `PG_TRY`/`PG_CATCH` around the node work.
  Both passes (qualify then filter) run inside the same `PG_TRY` block on the
  same node tree, so an error in either yields `nil` with no leak.

## Testing

A new spec file (or a new section in `qualify_spec.rb`) covering:

- Single-table SELECT → filter in WHERE (no existing WHERE).
- Single-table SELECT with existing WHERE → predicate AND-ed in.
- Inner JOIN → both tables filtered in WHERE, each qualified to its alias.
- LEFT / RIGHT / FULL JOIN → nullable side's predicate in the ON clause, shape
  preserved.
- UPDATE and DELETE (target + USING/FROM tables).
- Subquery in FROM and in `WHERE IN (...)` → inner scope filtered, wrapper not.
- CTE → body filtered at definition; reference not filtered.
- INSERT ... SELECT → SELECT filtered; INSERT ... VALUES → unchanged.
- Exclusion list: exact match and `%` prefix match skip the named tables.
- Alias vs. no alias → reference name chosen correctly.
- Combined with schema qualification and `func_names` in one call.
- Invalid SQL → `nil`.
