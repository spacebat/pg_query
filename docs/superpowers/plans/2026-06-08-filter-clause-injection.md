# Filter Clause Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional second pass to SQL qualification that injects a per-table row-restricting filter (e.g. `sbid = 42`) into every WHERE clause and outer-join ON clause, scoping every table in a query to a single value.

**Architecture:** A new, self-contained C tree-walk (`filter_node`) runs *after* the existing, unchanged `qualify_node` pass, on the same node tree, inside the same `PG_TRY` block. It only handles scope-bearing nodes (SELECT/UPDATE/DELETE/INSERT/CTE/RangeSubselect/SubLink) and the join tree within a scope. For each scope it collects real-table references, classifies each as nullable (outer-join nullable side) or not, builds an `alias.col = N` predicate per non-excluded table, and AND-s it into the scope's WHERE (non-nullable) or the owning join's ON (nullable). A thin Ruby method marshals a keyword API down to one positional C primitive.

**Tech Stack:** C (libpg_query / PostgreSQL parse-node API), Ruby C extension API, RSpec. Build with `rake compile`, test with `bundle exec rspec`.

---

## Background: key facts the implementer needs

**Node-building helpers (all already linked in):**
- `makeSimpleA_Expr(AEXPR_OP, "=", lexpr, rexpr, -1)` → `A_Expr*` for `lexpr = rexpr`. (`AEXPR_OP` is in `nodes/parsenodes.h`.)
- `makeBoolExpr(AND_EXPR, list_of_args, -1)` → `Expr*` for `a AND b [AND ...]`. (`AND_EXPR` is in `nodes/primnodes.h`.)
- `makeString(char *)`, `makeInteger(int)` (`nodes/value.h`).
- `pstrdup(const char *)` — duplicate a string into the current memory context.

**Integer constant idiom** (copied from `makeIntConst` in `src_backend_parser_gram.c:52935`):
```c
A_Const *n = makeNode(A_Const);
n->val.ival.type = T_Integer;
n->val.ival.ival = value;
n->location = -1;
// use (Node *) n
```

**Column reference idiom** — `t.sbid` is a `ColumnRef` whose `fields` is a `List` of `String` nodes:
```c
ColumnRef *cr = makeNode(ColumnRef);
cr->fields = list_make2(makeString(pstrdup(ref_name)), makeString(pstrdup(column)));
cr->location = -1;
```
(For an unqualified column you would use `list_make1`, but this feature always qualifies to the table reference name, so always two fields.)

**Relevant struct fields:**
- `RangeVar`: `schemaname`, `relname`, `alias` (an `Alias*` or NULL). `rv->alias->aliasname` is the alias string when present.
- `JoinExpr`: `jointype` (`JOIN_INNER`/`JOIN_LEFT`/`JOIN_RIGHT`/`JOIN_FULL`), `larg`, `rarg`, `quals` (the ON expression, a `Node*`).
- `SelectStmt`: `fromClause` (List), `whereClause` (Node*).
- `UpdateStmt`/`DeleteStmt`: `relation` (RangeVar* — the target), `fromClause`/`usingClause` (List), `whereClause` (Node*).
- `RangeSubselect`: `subquery` (Node* — a SelectStmt). `SubLink`: `subselect`, `testexpr`.
- `CommonTableExpr`: `ctequery`. `WithClause`: `ctes` (List of CommonTableExpr).
- `InsertStmt`: `selectStmt`, `withClause`. `CreateTableAsStmt`: `query`. `ViewStmt`: `query`. `ExplainStmt`: `query`.

**The reference name** used in the predicate is: `rv->alias->aliasname` if alias present, else `rv->relname`.

**Exclusion matching** reuses the existing `should_qualify_function` matching style from `pg_query_qualify.c:47` — exact match, or prefix match when the pattern ends in `%`. Match against `rv->relname`.

**Existing entry points** (`pg_query_qualify.c:700,761`): `pg_query_qualify_sql_with_funcs` does parse → enter ctx → `pg_query_protobuf_to_nodes` → `qualify_node` per stmt → `pg_query_nodes_to_protobuf` → deparse → exit ctx. The new pass slots in right after the `qualify_node` loop, before `pg_query_nodes_to_protobuf`.

**Build/test loop:** `rake compile` rebuilds the C extension; it MUST be run before rspec sees C changes. `bundle exec rspec spec/lib/qualify_spec.rb` runs the qualify tests.

---

## File Structure

- **Modify** `ext/pg_query/pg_query_qualify.h` — add the new full signature.
- **Modify** `ext/pg_query/pg_query_qualify.c` — add `filter_node` and its helpers; thread a filter spec into the entry point; add the full entry point.
- **Modify** `ext/pg_query/pg_query_ruby.c` — add a positional C primitive `qualify_full` and register it.
- **Modify** `lib/pg_query.rb` — require the new Ruby wrapper file.
- **Create** `lib/pg_query/qualify.rb` — Ruby `PgQuery.qualify_with_filter` keyword wrapper.
- **Modify** `spec/lib/qualify_spec.rb` — add a "filter injection" describe block.

The filter pass lives in `pg_query_qualify.c` alongside qualification because the two are composed there and share the same memory-context/parse/deparse scaffolding. It is a separate set of functions (`filter_node`, `filter_collect_tables`, `make_filter_predicate`, `table_is_excluded`) with no edits to `qualify_node` itself.

---

## Task 1: Filter spec struct and predicate builder

**Files:**
- Modify: `ext/pg_query/pg_query_qualify.c` (add near top, after includes, before `qualify_rangevar`)

This task adds the data structure carried through the filter walk and the helper that builds one `ref.col = N` predicate. No behavior is wired up yet; it compiles but is unused (mark unused helpers with nothing special — they will be used in Task 2; if the compiler warns about unused static functions, that is expected until Task 2).

- [ ] **Step 1: Add the FilterSpec struct and predicate/exclusion helpers**

Add this block immediately after the `#include` lines (around line 12) of `ext/pg_query/pg_query_qualify.c`:

```c
typedef struct FilterSpec {
    const char *column;            // e.g. "sbid"; NULL means "no filtering"
    int value;                     // integer value, e.g. 42
    const char **exclude;          // table names to skip (relname); may be NULL
    int exclude_count;             // length of exclude
} FilterSpec;

// Match a table name against the exclusion list. Reuses the same
// exact/prefix(%)-match convention as should_qualify_function.
static bool table_is_excluded(const char *relname, const FilterSpec *spec) {
    if (!relname || !spec || !spec->exclude || spec->exclude_count == 0) return false;
    for (int i = 0; i < spec->exclude_count; i++) {
        const char *pattern = spec->exclude[i];
        int pattern_len = strlen(pattern);
        if (pattern_len > 0 && pattern[pattern_len - 1] == '%') {
            if (strncmp(relname, pattern, pattern_len - 1) == 0) return true;
        } else {
            if (strcmp(relname, pattern) == 0) return true;
        }
    }
    return false;
}

// Build the AST for `ref_name.column = value` as an A_Expr.
static Node *make_filter_predicate(const char *ref_name, const FilterSpec *spec) {
    ColumnRef *cr = makeNode(ColumnRef);
    cr->fields = list_make2(makeString(pstrdup(ref_name)),
                            makeString(pstrdup(spec->column)));
    cr->location = -1;

    A_Const *konst = makeNode(A_Const);
    konst->val.ival.type = T_Integer;
    konst->val.ival.ival = spec->value;
    konst->location = -1;

    return (Node *) makeSimpleA_Expr(AEXPR_OP, "=", (Node *) cr, (Node *) konst, -1);
}

// AND `add` into `*existing` (creating/extending a BoolExpr as needed).
static void and_into(Node **existing, Node *add) {
    if (!add) return;
    if (*existing == NULL) {
        *existing = add;
    } else if (IsA(*existing, BoolExpr) && ((BoolExpr *) *existing)->boolop == AND_EXPR) {
        ((BoolExpr *) *existing)->args = lappend(((BoolExpr *) *existing)->args, add);
    } else {
        *existing = (Node *) makeBoolExpr(AND_EXPR, list_make2(*existing, add), -1);
    }
}
```

- [ ] **Step 2: Compile to verify it builds**

Run: `cd /home/akirkpatrick/lz/pg_query && rake compile`
Expected: compiles successfully (warnings about unused `make_filter_predicate`/`table_is_excluded`/`and_into` are acceptable at this stage).

- [ ] **Step 3: Commit**

```bash
cd /home/akirkpatrick/lz/pg_query
git add ext/pg_query/pg_query_qualify.c
git commit -m "Add filter predicate builder and exclusion helpers"
```

---

## Task 2: The filter tree-walk (`filter_node` + table collection)

**Files:**
- Modify: `ext/pg_query/pg_query_qualify.c` (add after the helpers from Task 1, before `qualify_node`'s forward declaration is fine; place the new functions after `and_into`)

This implements the walk itself. `filter_collect_tables` walks a FROM/join subtree, depositing each non-nullable table's predicate into a passed-in WHERE accumulator and each nullable table's predicate into the owning join's `quals`. `filter_node` handles scope-bearing statements, calls `filter_collect_tables` for the scope's FROM items, flushes the accumulator into `whereClause`, and recurses into nested scopes.

- [ ] **Step 1: Add forward declaration and the collection + walk functions**

Add forward declarations near the other forward declaration (`static void qualify_node(...)` at line 42):

```c
static void filter_node(Node *node, const FilterSpec *spec);
static void filter_collect_tables(Node *node, bool nullable, Node **where_accum, const FilterSpec *spec);
```

Then add the implementations (place them just before `pg_query_qualify_sql_with_funcs`, near line 700):

```c
// Walk a FROM/join subtree. Non-nullable tables' predicates go into
// *where_accum; a table on the nullable side of an outer join gets its
// predicate AND-ed into that join's ON (quals). Derived tables / function
// RTEs are recursed into (filter_node) but never get a wrapper predicate.
static void filter_collect_tables(Node *node, bool nullable, Node **where_accum, const FilterSpec *spec) {
    if (!node) return;
    check_stack_depth();

    switch (nodeTag(node)) {
        case T_RangeVar: {
            RangeVar *rv = (RangeVar *) node;
            if (!rv->relname) return;
            if (table_is_excluded(rv->relname, spec)) return;
            const char *ref = (rv->alias && rv->alias->aliasname)
                                  ? rv->alias->aliasname : rv->relname;
            Node *pred = make_filter_predicate(ref, spec);
            // Non-nullable tables go to WHERE here; nullable tables are handled
            // by the JoinExpr case below (which deposits into the join's quals).
            and_into(where_accum, pred);
            break;
        }
        case T_RangeSubselect: {
            // Derived table: scope the inner query; do not filter the wrapper.
            RangeSubselect *sub = (RangeSubselect *) node;
            filter_node(sub->subquery, spec);
            break;
        }
        case T_RangeFunction:
            // Function RTE (e.g. unnest(...)): nothing to scope.
            break;
        case T_JoinExpr: {
            JoinExpr *j = (JoinExpr *) node;
            bool left_nullable  = nullable || (j->jointype == JOIN_RIGHT || j->jointype == JOIN_FULL);
            bool right_nullable = nullable || (j->jointype == JOIN_LEFT  || j->jointype == JOIN_FULL);

            // For the nullable side introduced by THIS join, deposit predicates
            // into this join's ON (quals) instead of the scope WHERE. We do this
            // by collecting that side into a local accumulator and AND-ing the
            // result into j->quals.
            if (j->jointype == JOIN_LEFT || j->jointype == JOIN_RIGHT || j->jointype == JOIN_FULL) {
                Node *on_accum = NULL;
                // Left side
                if (j->jointype == JOIN_RIGHT || j->jointype == JOIN_FULL) {
                    filter_collect_tables(j->larg, left_nullable, &on_accum, spec);
                } else {
                    filter_collect_tables(j->larg, left_nullable, where_accum, spec);
                }
                // Right side
                if (j->jointype == JOIN_LEFT || j->jointype == JOIN_FULL) {
                    filter_collect_tables(j->rarg, right_nullable, &on_accum, spec);
                } else {
                    filter_collect_tables(j->rarg, right_nullable, where_accum, spec);
                }
                and_into(&j->quals, on_accum);
            } else {
                // INNER / CROSS: both sides flow to the current accumulator.
                filter_collect_tables(j->larg, left_nullable, where_accum, spec);
                filter_collect_tables(j->rarg, right_nullable, where_accum, spec);
            }
            break;
        }
        default:
            break;
    }
}

// Scope-aware walk: injects filters into SELECT/UPDATE/DELETE scopes and
// recurses into nested scopes (subqueries, CTEs, INSERT...SELECT, view/CTAS).
static void filter_node(Node *node, const FilterSpec *spec) {
    if (!node || !spec || !spec->column) return;
    check_stack_depth();

    switch (nodeTag(node)) {
        case T_SelectStmt: {
            SelectStmt *stmt = (SelectStmt *) node;

            // Recurse into CTEs first (their bodies are their own scopes).
            if (stmt->withClause) {
                ListCell *lc;
                foreach(lc, ((WithClause *) stmt->withClause)->ctes) {
                    CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                    filter_node(cte->ctequery, spec);
                }
            }

            // Set operations (UNION etc.) recurse into both arms.
            if (stmt->larg) filter_node((Node *) stmt->larg, spec);
            if (stmt->rarg) filter_node((Node *) stmt->rarg, spec);

            // Collect tables from this scope's FROM list into a WHERE accumulator.
            Node *where_accum = NULL;
            ListCell *lc;
            foreach(lc, stmt->fromClause) {
                filter_collect_tables((Node *) lfirst(lc), false, &where_accum, spec);
            }
            and_into(&stmt->whereClause, where_accum);

            // Recurse into subqueries that appear in expressions (WHERE IN (...), etc.)
            filter_node((Node *) stmt->whereClause, spec);
            break;
        }
        case T_UpdateStmt: {
            UpdateStmt *stmt = (UpdateStmt *) node;
            if (stmt->withClause) {
                ListCell *lc;
                foreach(lc, ((WithClause *) stmt->withClause)->ctes) {
                    filter_node(((CommonTableExpr *) lfirst(lc))->ctequery, spec);
                }
            }
            Node *where_accum = NULL;
            // Target relation (non-nullable).
            filter_collect_tables((Node *) stmt->relation, false, &where_accum, spec);
            // Additional FROM tables.
            ListCell *lc;
            foreach(lc, stmt->fromClause) {
                filter_collect_tables((Node *) lfirst(lc), false, &where_accum, spec);
            }
            and_into(&stmt->whereClause, where_accum);
            filter_node((Node *) stmt->whereClause, spec);
            break;
        }
        case T_DeleteStmt: {
            DeleteStmt *stmt = (DeleteStmt *) node;
            if (stmt->withClause) {
                ListCell *lc;
                foreach(lc, ((WithClause *) stmt->withClause)->ctes) {
                    filter_node(((CommonTableExpr *) lfirst(lc))->ctequery, spec);
                }
            }
            Node *where_accum = NULL;
            filter_collect_tables((Node *) stmt->relation, false, &where_accum, spec);
            ListCell *lc;
            foreach(lc, stmt->usingClause) {
                filter_collect_tables((Node *) lfirst(lc), false, &where_accum, spec);
            }
            and_into(&stmt->whereClause, where_accum);
            filter_node((Node *) stmt->whereClause, spec);
            break;
        }
        case T_InsertStmt: {
            InsertStmt *stmt = (InsertStmt *) node;
            if (stmt->withClause) {
                ListCell *lc;
                foreach(lc, ((WithClause *) stmt->withClause)->ctes) {
                    filter_node(((CommonTableExpr *) lfirst(lc))->ctequery, spec);
                }
            }
            // INSERT ... SELECT: scope the SELECT. INSERT ... VALUES: nothing.
            if (stmt->selectStmt) filter_node(stmt->selectStmt, spec);
            break;
        }
        case T_SubLink: {
            SubLink *sublink = (SubLink *) node;
            filter_node(sublink->subselect, spec);
            filter_node(sublink->testexpr, spec);
            break;
        }
        case T_BoolExpr: {
            // Recurse so subqueries nested inside AND/OR get scoped.
            ListCell *lc;
            foreach(lc, ((BoolExpr *) node)->args) {
                filter_node((Node *) lfirst(lc), spec);
            }
            break;
        }
        case T_A_Expr: {
            A_Expr *aexpr = (A_Expr *) node;
            filter_node(aexpr->lexpr, spec);
            filter_node(aexpr->rexpr, spec);
            break;
        }
        case T_CreateTableAsStmt:
            filter_node(((CreateTableAsStmt *) node)->query, spec);
            break;
        case T_ViewStmt:
            filter_node(((ViewStmt *) node)->query, spec);
            break;
        case T_ExplainStmt:
            filter_node(((ExplainStmt *) node)->query, spec);
            break;
        default:
            break;
    }
}
```

- [ ] **Step 2: Compile to verify it builds**

Run: `cd /home/akirkpatrick/lz/pg_query && rake compile`
Expected: compiles successfully, no unused-function warnings now.

- [ ] **Step 3: Commit**

```bash
cd /home/akirkpatrick/lz/pg_query
git add ext/pg_query/pg_query_qualify.c
git commit -m "Add filter_node tree-walk for per-table filter injection"
```

---

## Task 3: Wire the filter pass into the C entry point

**Files:**
- Modify: `ext/pg_query/pg_query_qualify.h`
- Modify: `ext/pg_query/pg_query_qualify.c` (the `pg_query_qualify_sql_with_funcs` function near line 700)

- [ ] **Step 1: Add the full signature to the header**

In `ext/pg_query/pg_query_qualify.h`, add a third declaration:

```c
char* pg_query_qualify_sql_full(const char* sql, const char* schema, const char** func_names, int func_count, const char* filter_column, int filter_value, const char** filter_exclude, int filter_exclude_count);
```

- [ ] **Step 2: Rename the existing entry point to the full version and add the filter pass**

In `ext/pg_query/pg_query_qualify.c`, change the signature at line 700 from:

```c
char* pg_query_qualify_sql_with_funcs(const char *sql, const char *schema, const char **func_names, int func_count) {
```

to:

```c
char* pg_query_qualify_sql_full(const char *sql, const char *schema, const char **func_names, int func_count, const char *filter_column, int filter_value, const char **filter_exclude, int filter_exclude_count) {
```

Then, inside the `PG_TRY` block, immediately AFTER the `qualify_node` loop (the `foreach(lc, stmts)` that calls `qualify_node`, ending at the line with the closing `}` before `PgQueryProtobuf qualified_protobuf = ...`), add the filter pass:

```c
        // Pass 2: inject row-restricting filter (only if a column was given).
        if (filter_column) {
            FilterSpec spec = {
                .column = filter_column,
                .value = filter_value,
                .exclude = filter_exclude,
                .exclude_count = filter_exclude_count
            };
            foreach(lc, stmts) {
                RawStmt *raw_stmt = castNode(RawStmt, lfirst(lc));
                filter_node(raw_stmt->stmt, &spec);
            }
        }
```

- [ ] **Step 3: Add a thin wrapper for the old with_funcs signature**

Add, just after `pg_query_qualify_sql_full` closes (before the existing `pg_query_qualify_sql` at line 761):

```c
char* pg_query_qualify_sql_with_funcs(const char *sql, const char *schema, const char **func_names, int func_count) {
    return pg_query_qualify_sql_full(sql, schema, func_names, func_count, NULL, 0, NULL, 0);
}
```

(`pg_query_qualify_sql` at line 761 already calls `pg_query_qualify_sql_with_funcs` and stays unchanged.)

- [ ] **Step 4: Compile to verify it builds**

Run: `cd /home/akirkpatrick/lz/pg_query && rake compile`
Expected: compiles successfully.

- [ ] **Step 5: Run the existing qualify specs to confirm no regression**

Run: `cd /home/akirkpatrick/lz/pg_query && bundle exec rspec spec/lib/qualify_spec.rb`
Expected: all existing examples PASS (filter path is dormant since no caller passes a column yet).

- [ ] **Step 6: Commit**

```bash
cd /home/akirkpatrick/lz/pg_query
git add ext/pg_query/pg_query_qualify.h ext/pg_query/pg_query_qualify.c
git commit -m "Wire filter pass into qualify entry point"
```

---

## Task 4: C Ruby primitive `qualify_full`

**Files:**
- Modify: `ext/pg_query/pg_query_ruby.c`

This adds a positional primitive that the Ruby keyword wrapper calls. Signature: `qualify_full(sql, schema, func_names_array, filter_column_or_nil, filter_value_int, filter_exclude_array)`.

- [ ] **Step 1: Add the forward declaration and registration**

In `ext/pg_query/pg_query_ruby.c`, after the existing `pg_query_ruby_qualify_with_funcs` declaration (line 20) add:

```c
VALUE pg_query_ruby_qualify_full(VALUE self, VALUE sql_str, VALUE schema_str, VALUE func_names_array, VALUE filter_column, VALUE filter_value, VALUE filter_exclude_array);
```

In `Init_pg_query`, after the `qualify_with_funcs` registration (line 35) add:

```c
	rb_define_singleton_method(cPgQuery, "qualify_full", pg_query_ruby_qualify_full, 6);
```

- [ ] **Step 2: Implement the primitive**

Add at the end of the file (after `pg_query_ruby_qualify_with_funcs`, which ends near line 306). This mirrors the existing func_names marshalling and adds the exclusion-array marshalling plus the column/value handling:

```c
static const char** ruby_string_array_to_c(VALUE array, int *out_count) {
	int count = RARRAY_LEN(array);
	*out_count = count;
	if (count == 0) return NULL;
	const char** result = malloc(count * sizeof(char*));
	if (!result) {
		rb_raise(rb_eNoMemError, "Memory allocation failed for string array");
	}
	for (int i = 0; i < count; i++) {
		VALUE v = rb_ary_entry(array, i);
		if (!RB_TYPE_P(v, T_STRING)) {
			free(result);
			rb_raise(rb_eTypeError, "Array element must be a string");
		}
		result[i] = StringValueCStr(v);
	}
	return result;
}

VALUE pg_query_ruby_qualify_full(VALUE self, VALUE sql_str, VALUE schema_str, VALUE func_names_array, VALUE filter_column, VALUE filter_value, VALUE filter_exclude_array) {
	Check_Type(sql_str, T_STRING);
	Check_Type(schema_str, T_STRING);
	Check_Type(func_names_array, T_ARRAY);
	Check_Type(filter_exclude_array, T_ARRAY);

	const char* sql = StringValueCStr(sql_str);
	const char* schema = StringValueCStr(schema_str);

	int func_count = 0;
	const char** func_names = ruby_string_array_to_c(func_names_array, &func_count);

	int exclude_count = 0;
	const char** filter_exclude = NULL;
	const char* column = NULL;
	int value = 0;
	char* result = NULL;
	VALUE output = Qnil;

	// filter_column is a String when filtering is requested, nil otherwise.
	if (!NIL_P(filter_column)) {
		Check_Type(filter_column, T_STRING);
		column = StringValueCStr(filter_column);
		value = NUM2INT(filter_value);
		filter_exclude = ruby_string_array_to_c(filter_exclude_array, &exclude_count);
	}

	result = pg_query_qualify_sql_full(sql, schema, func_names, func_count, column, value, filter_exclude, exclude_count);

	if (result) {
		output = rb_str_new_cstr(result);
		rb_enc_associate(output, rb_utf8_encoding());
		free(result);
	}

	if (func_names) free(func_names);
	if (filter_exclude) free(filter_exclude);

	return output;
}
```

- [ ] **Step 3: Compile to verify it builds**

Run: `cd /home/akirkpatrick/lz/pg_query && rake compile`
Expected: compiles successfully.

- [ ] **Step 4: Commit**

```bash
cd /home/akirkpatrick/lz/pg_query
git add ext/pg_query/pg_query_ruby.c
git commit -m "Add qualify_full Ruby primitive"
```

---

## Task 5: Ruby keyword wrapper `PgQuery.qualify_with_filter`

**Files:**
- Create: `lib/pg_query/qualify.rb`
- Modify: `lib/pg_query.rb`

- [ ] **Step 1: Write the failing test**

Add this describe block at the END of `spec/lib/qualify_spec.rb` (before the final `end` that closes `describe PgQuery, '#qualify'`... — actually add it as a sibling top-level describe at the very end of the file, after the existing closing `end`):

```ruby
describe PgQuery, '#qualify_with_filter' do
  it "injects the filter into a single-table SELECT with no WHERE" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users", "public", filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "SELECT * FROM public.users WHERE users.sbid = 42"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /home/akirkpatrick/lz/pg_query && bundle exec rspec spec/lib/qualify_spec.rb -e "single-table SELECT with no WHERE"`
Expected: FAIL with `NoMethodError: undefined method 'qualify_with_filter'`.

- [ ] **Step 3: Create the Ruby wrapper**

Create `lib/pg_query/qualify.rb`:

```ruby
module PgQuery
  # Qualify unqualified table names with +schema+, and optionally inject a
  # row-restricting filter (e.g. sbid = 42) into every WHERE and outer-join
  # ON clause so that every table is scoped to a single value.
  #
  # filter_column / filter_value: when given, inject "<column> = <value>"
  #   per table (qualified to each table's alias/name).
  # filter_exclude: table names (relname) to skip; entries ending in % are
  #   treated as prefix matches (e.g. "lookup_%").
  # func_names: function names to schema-qualify (same as qualify_with_funcs).
  #
  # Returns the rewritten SQL, or nil on parse/deparse failure.
  def self.qualify_with_filter(sql, schema, filter_column: nil, filter_value: nil,
                               filter_exclude: [], func_names: [])
    raise ArgumentError, 'filter_value is required when filter_column is given' \
      if filter_column && filter_value.nil?

    qualify_full(
      sql,
      schema,
      func_names,
      filter_column,
      filter_value || 0,
      filter_exclude
    )
  end
end
```

- [ ] **Step 4: Require the new file**

In `lib/pg_query.rb`, add after line 18 (`require 'pg_query/scan'`):

```ruby
require 'pg_query/qualify'
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /home/akirkpatrick/lz/pg_query && bundle exec rspec spec/lib/qualify_spec.rb -e "single-table SELECT with no WHERE"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /home/akirkpatrick/lz/pg_query
git add lib/pg_query/qualify.rb lib/pg_query.rb spec/lib/qualify_spec.rb
git commit -m "Add PgQuery.qualify_with_filter keyword wrapper"
```

---

## Task 6: Tests — WHERE, existing WHERE, inner JOIN

**Files:**
- Modify: `spec/lib/qualify_spec.rb`

- [ ] **Step 1: Add the tests**

Inside the `describe PgQuery, '#qualify_with_filter'` block, add:

```ruby
  it "ANDs the filter into an existing WHERE" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users WHERE name = 'a'", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "SELECT * FROM public.users WHERE name = 'a' AND users.sbid = 42"
  end

  it "filters every table of an inner JOIN in WHERE, qualified to its alias" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users u JOIN orders o ON u.id = o.user_id", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "SELECT * FROM public.users u JOIN public.orders o ON u.id = o.user_id WHERE u.sbid = 42 AND o.sbid = 42"
  end

  it "uses the table name when there is no alias" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users JOIN orders ON users.id = orders.user_id", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "SELECT * FROM public.users JOIN public.orders ON users.id = orders.user_id WHERE users.sbid = 42 AND orders.sbid = 42"
  end
```

- [ ] **Step 2: Run the tests**

Run: `cd /home/akirkpatrick/lz/pg_query && bundle exec rspec spec/lib/qualify_spec.rb -e "qualify_with_filter"`
Expected: all PASS. (If the deparser orders the ANDed conditions differently, adjust the expected string to match the actual output — run once, read the failure's actual value, and set the expectation to it. The semantics, not the operand order, are what matter.)

- [ ] **Step 3: Commit**

```bash
cd /home/akirkpatrick/lz/pg_query
git add spec/lib/qualify_spec.rb
git commit -m "Test filter injection for WHERE and inner JOIN"
```

---

## Task 7: Tests — outer joins (nullable side → ON)

**Files:**
- Modify: `spec/lib/qualify_spec.rb`

- [ ] **Step 1: Add the tests**

```ruby
  it "puts the nullable side of a LEFT JOIN into the ON clause" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users u LEFT JOIN orders o ON u.id = o.user_id", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "SELECT * FROM public.users u LEFT JOIN public.orders o ON u.id = o.user_id AND o.sbid = 42 WHERE u.sbid = 42"
  end

  it "puts the nullable side of a RIGHT JOIN into the ON clause" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users u RIGHT JOIN orders o ON u.id = o.user_id", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "SELECT * FROM public.users u RIGHT JOIN public.orders o ON u.id = o.user_id AND u.sbid = 42 WHERE o.sbid = 42"
  end

  it "puts both sides of a FULL JOIN into the ON clause" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users u FULL JOIN orders o ON u.id = o.user_id", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "SELECT * FROM public.users u FULL JOIN public.orders o ON u.id = o.user_id AND u.sbid = 42 AND o.sbid = 42"
  end
```

- [ ] **Step 2: Run the tests**

Run: `cd /home/akirkpatrick/lz/pg_query && bundle exec rspec spec/lib/qualify_spec.rb -e "qualify_with_filter"`
Expected: all PASS. (As in Task 6, if operand/AND ordering differs from the literal expectation, run once and set the expectation to the actual deparsed string. For the FULL JOIN with no WHERE, confirm there is NO `WHERE` clause emitted.)

- [ ] **Step 3: Commit**

```bash
cd /home/akirkpatrick/lz/pg_query
git add spec/lib/qualify_spec.rb
git commit -m "Test outer-join filter placement (nullable side -> ON)"
```

---

## Task 8: Tests — UPDATE, DELETE, subqueries, CTEs, INSERT, exclusion

**Files:**
- Modify: `spec/lib/qualify_spec.rb`

- [ ] **Step 1: Add the tests**

```ruby
  it "filters UPDATE target and USING/FROM tables" do
    query = described_class.qualify_with_filter(
      "UPDATE users SET name = 'a' FROM orders WHERE users.id = orders.user_id", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "UPDATE public.users SET name = 'a' FROM public.orders WHERE users.id = orders.user_id AND users.sbid = 42 AND orders.sbid = 42"
  end

  it "filters a DELETE target table" do
    query = described_class.qualify_with_filter(
      "DELETE FROM users WHERE id = 1", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "DELETE FROM public.users WHERE id = 1 AND users.sbid = 42"
  end

  it "filters inside a subquery and not the derived wrapper" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "SELECT * FROM public.users WHERE id IN (SELECT user_id FROM public.orders WHERE orders.sbid = 42) AND users.sbid = 42"
  end

  it "filters a CTE body at its definition" do
    query = described_class.qualify_with_filter(
      "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(query).to eq "WITH recent AS (SELECT * FROM public.orders WHERE orders.sbid = 42) SELECT * FROM recent"
  end

  it "filters the SELECT of an INSERT ... SELECT but not INSERT ... VALUES" do
    insert_select = described_class.qualify_with_filter(
      "INSERT INTO audit (x) SELECT id FROM orders", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(insert_select).to eq "INSERT INTO public.audit (x) SELECT id FROM public.orders WHERE orders.sbid = 42"

    insert_values = described_class.qualify_with_filter(
      "INSERT INTO users (name) VALUES ('a')", "public",
      filter_column: "sbid", filter_value: 42
    )
    expect(insert_values).to eq "INSERT INTO public.users (name) VALUES ('a')"
  end

  it "skips tables on the exclusion list (exact and % prefix)" do
    query = described_class.qualify_with_filter(
      "SELECT * FROM users u JOIN countries c ON u.country_id = c.id JOIN lookup_x l ON l.id = u.lx", "public",
      filter_column: "sbid", filter_value: 42, filter_exclude: ["countries", "lookup_%"]
    )
    expect(query).to eq "SELECT * FROM public.users u JOIN public.countries c ON u.country_id = c.id JOIN public.lookup_x l ON l.id = u.lx WHERE u.sbid = 42"
  end

  it "combines schema qualification, func qualification and filter in one call" do
    query = described_class.qualify_with_filter(
      "SELECT now_fn() FROM users", "public",
      filter_column: "sbid", filter_value: 42, func_names: ["now_fn"]
    )
    expect(query).to eq "SELECT public.now_fn() FROM public.users WHERE users.sbid = 42"
  end

  it "returns nil for invalid SQL" do
    expect(
      described_class.qualify_with_filter("INVALID SQL", "public",
                                          filter_column: "sbid", filter_value: 42)
    ).to be_nil
  end

  it "behaves like plain qualify when no filter_column is given" do
    expect(
      described_class.qualify_with_filter("SELECT * FROM users", "public")
    ).to eq "SELECT * FROM public.users"
  end
```

- [ ] **Step 2: Run the tests**

Run: `cd /home/akirkpatrick/lz/pg_query && bundle exec rspec spec/lib/qualify_spec.rb -e "qualify_with_filter"`
Expected: all PASS. For any case where the deparser's AND-operand order or whitespace differs from the literal expectation, run once, read the actual deparsed string from the failure output, confirm it is semantically correct, then set the expectation to match. The exclusion test in particular: confirm `countries` and `lookup_x` get NO `sbid` predicate while `users` does.

- [ ] **Step 3: Commit**

```bash
cd /home/akirkpatrick/lz/pg_query
git add spec/lib/qualify_spec.rb
git commit -m "Test filter injection for UPDATE/DELETE/subquery/CTE/INSERT/exclusion"
```

---

## Task 9: Full suite + lint

**Files:** none (verification only)

- [ ] **Step 1: Run the complete spec suite**

Run: `cd /home/akirkpatrick/lz/pg_query && bundle exec rspec`
Expected: all examples PASS (no regressions in any file).

- [ ] **Step 2: Run lint**

Run: `cd /home/akirkpatrick/lz/pg_query && bundle exec rubocop`
Expected: no offenses. Fix any offenses in `lib/pg_query/qualify.rb` or the spec (likely line-length); re-run until clean.

- [ ] **Step 3: Final commit (only if lint fixes were made)**

```bash
cd /home/akirkpatrick/lz/pg_query
git add -A
git commit -m "Lint fixes for filter injection"
```

---

## Self-Review notes (for the implementer)

- **Deparser operand order:** The PostgreSQL deparser may render `a AND b` with operands or whitespace differing from the literal strings in the test expectations. This is expected. Where it happens, run the test once, verify the *semantics* of the actual output, and update the expectation to the actual string. The exact-string assertions are starting points, not invariants.
- **NATURAL joins:** A `JoinExpr` with `isNatural = true` is handled the same as a regular join here (we add to `quals`, which is valid alongside a natural join's implicit conditions). No special handling needed for this iteration.
- **USING-clause joins:** Adding to `quals` on a join that used `USING (...)` is valid SQL and deparses correctly; no special handling needed.
- **Tables without the filter column:** Out of scope — the caller must use `filter_exclude` for tables lacking the column. A non-excluded table without `sbid` will produce SQL Postgres rejects at execution; that is by design (per spec Non-Goals).
