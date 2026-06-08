# pg_query [ ![](https://img.shields.io/gem/v/pg_query.svg)](https://rubygems.org/gems/pg_query) [ ![](https://img.shields.io/gem/dt/pg_query.svg)](https://rubygems.org/gems/pg_query)

This Ruby extension uses the actual PostgreSQL server source to parse SQL queries and return the internal PostgreSQL parsetree.

In addition the extension allows you to normalize queries (replacing constant values with $n) and parse these normalized queries into a parsetree again.

When you build this extension, it builds parts of the PostgreSQL server source (see [libpg_query](https://github.com/pganalyze/libpg_query)), and then statically links it into this extension.

This may seem like a lot of complexity, but is the only reliable way of parsing all valid PostgreSQL queries.

You can find further examples and a longer rationale here: https://pganalyze.com/blog/parse-postgresql-queries-in-ruby.html

## Installation

```
gem install pg_query
```

Due to compiling parts of PostgreSQL, installation might take a while on slower systems. Expect up to 5 minutes.

## Usage

### Parsing a query

```ruby
PgQuery.parse("SELECT 1")

=> #<PgQuery::ParserResult:0x000000012ec4e9e0
  @query="SELECT 1",
  @tree=<PgQuery::ParseResult:
    version: 160001,
    stmts: [
      <PgQuery::RawStmt:
        stmt: <PgQuery::Node:
          select_stmt: <PgQuery::SelectStmt:
            distinct_clause: [],
            target_list: [
              <PgQuery::Node:
                res_target: <PgQuery::ResTarget:
                  name: "",
                  indirection: [],
                  val: <PgQuery::Node:
                    a_const: <PgQuery::A_Const:
                      ival: <PgQuery::Integer: ival: 1>,
                      isnull: false,
                      location: 7
                    >
                  >,
                  location: 7
                >
              >
            ],
            from_clause: [],
            group_clause: [],
            group_distinct: false,
            window_clause: [],
            values_lists: [],
            sort_clause: [],
            limit_option: :LIMIT_OPTION_DEFAULT,
            locking_clause: [],
            op: :SETOP_NONE,
            all: false
          >
        >,
        stmt_location: 0,
        stmt_len: 0
      >
    ]
  >,
  @warnings=[],
  @tables=nil,
  @aliases=nil,
  @cte_names=nil,
  @functions=nil
>
```

### Modifying a parsed query and turning it into SQL again

This is a simple example for `deparse`, for more complex modification, use `walk!`.

```ruby
parsed_query = PgQuery.parse("SELECT * FROM users")

# Modify the parse tree in some way
parsed_query.tree.stmts[0].stmt.select_stmt.from_clause[0].range_var.relname = 'other_users'

# Turn it into SQL again
parsed_query.deparse
=> "SELECT * FROM other_users"
```

### Schema-qualifying and filtering a query

`PgQuery.qualify` rewrites a query so every unqualified table name is prefixed
with a schema. `PgQuery.qualify_with_funcs` additionally schema-qualifies the
named functions.

```ruby
PgQuery.qualify("SELECT * FROM users", "public")
=> "SELECT * FROM public.users"

PgQuery.qualify_with_funcs("SELECT now_fn() FROM users", "public", ["now_fn"])
=> "SELECT public.now_fn() FROM public.users"
```

`PgQuery.qualify_with_filter` does the same schema qualification and, when given
a `filter_column` and `filter_value`, also injects a per-table row-restricting
predicate (e.g. `sbid = 42`) into every part of the query that selects or
affects rows. Each real table reference — at any nesting depth, in subqueries,
CTE bodies, `JOIN ... ON`, `INSERT ... SELECT`, and expressions — is constrained
to the value, so a query cannot read or modify rows belonging to another value.

```ruby
PgQuery.qualify_with_filter(
  "SELECT * FROM users u LEFT JOIN orders o ON u.id = o.user_id",
  "public",
  filter_column: "sbid",
  filter_value: 42
)
=> "SELECT * FROM public.users u " \
   "LEFT JOIN public.orders o ON u.id = o.user_id AND o.sbid = 42 " \
   "WHERE u.sbid = 42"
```

Note that the nullable side of an outer join (`orders` above) is filtered in the
join's `ON` clause rather than in `WHERE`, which preserves the outer join's
result shape instead of silently collapsing it to an inner join.

Keyword arguments:

* `filter_column:` / `filter_value:` — the predicate to inject (`column =
  value`). `value` is an integer. Filtering happens only when **both** are
  given; if either `filter_column` or `filter_value` is `nil` (the defaults),
  filtering is skipped entirely and the call behaves exactly like
  `PgQuery.qualify` (schema qualification only, no row restriction).
* `filter_exclude:` — table names that must **not** receive the filter, for
  reference/lookup tables that lack the column. Matching is against the table's
  name: exact, or a `%`-suffix prefix match (e.g. `"lookup_%"`). A non-excluded
  table that lacks the column will produce SQL that Postgres rejects at
  execution — configuring this list correctly is the caller's responsibility.
* `func_names:` — function names to schema-qualify, as in
  `qualify_with_funcs`.

```ruby
PgQuery.qualify_with_filter(
  "SELECT * FROM users u JOIN countries c ON u.country_id = c.id",
  "public",
  filter_column: "sbid",
  filter_value: 42,
  filter_exclude: ["countries", "lookup_%"]
)
=> "SELECT * FROM public.users u " \
   "JOIN public.countries c ON u.country_id = c.id " \
   "WHERE u.sbid = 42"
```

All three methods return the rewritten SQL, or `nil` if the query fails to
parse or deparse.

### Parsing a normalized query

```ruby
# Normalizing a query (like pg_stat_statements in Postgres 10+)
PgQuery.normalize("SELECT 1 FROM x WHERE y = 'foo'")

=> "SELECT $1 FROM x WHERE y = $2"
```

### Extracting tables from a query

```ruby
PgQuery.parse("SELECT $1 FROM x JOIN y USING (id) WHERE z = $2").tables

=> ["x", "y"]
```

### Extracting columns from a query

```ruby
PgQuery.parse("SELECT $1 FROM x WHERE x.y = $2 AND z = $3").filter_columns

=> [["x", "y"], [nil, "z"]]
```

### Fingerprinting a query

```ruby
PgQuery.parse("SELECT 1").fingerprint

=> "50fde20626009aba"

PgQuery.parse("SELECT 2; --- comment").fingerprint

=> "50fde20626009aba"

# Faster fingerprint method that is implemented inside the native C library
PgQuery.fingerprint("SELECT $1")

=> "50fde20626009aba"
```

### Scanning a query into tokens

```ruby
PgQuery.scan('SELECT 1 --comment')

=> [<PgQuery::ScanResult: version: 160001, tokens: [
<PgQuery::ScanToken: start: 0, end: 6, token: :SELECT, keyword_kind: :RESERVED_KEYWORD>,
<PgQuery::ScanToken: start: 7, end: 8, token: :ICONST, keyword_kind: :NO_KEYWORD>,
<PgQuery::ScanToken: start: 9, end: 18, token: :SQL_COMMENT, keyword_kind: :NO_KEYWORD>]>,
 []]
```

### Walking the parse tree

For generalized use, PgQuery provides `walk!` as a means to recursively work with the parsed query.

This can be used to create a bespoke pretty printer:

```ruby
parsed_query = PgQuery.parse "SELECT * FROM tbl"
parsed_query.walk! { |node, k, v, location| puts k }
```

More usefully, this can be used to rewrite a query. For example:

```ruby
parsed_query.walk! do |node, k, v, location|
  next unless k.eql?(:range_var) || k.eql?(:relation)
  next if v.relname.nil?
  v.relname = "X_" + v.relname
end

parsed_query.deparse
```

There are some caveats, and limitations, in this example.

First, some of the tree nodes are frozen. You can replace them, but you cannot modify in place.

Second, table rewriting is a bit more nuanced than this example. While this will rewrite the table names, it will
not correctly handle all CTEs, or rewrite columns with explicit table names.

## Supported Ruby Versions

Currently tested and officially supported Ruby versions:

* CRuby 2.7
* CRuby 3.0
* CRuby 3.1
* CRuby 3.2
* CRuby 3.3

Not supported:

* JRuby: `pg_query` relies on a C extension, which is discouraged / not properly supported for JRuby
* TruffleRuby: GraalVM [does not support sigjmp](https://www.graalvm.org/reference-manual/llvm/NativeExecution/), which is used by the Postgres error handling code (`pg_query` uses a copy of the Postgres parser & error handling code)

## Developer tasks

### Update libpg_query source

In order to update to a newer Postgres parser, first update [libpg_query](https://github.com/pganalyze/libpg_query) to the new Postgres version and tag a release.

Once that is done, follow the following steps:

1. Update `LIB_PG_QUERY_TAG` and `LIB_PG_QUERY_SHA256SUM` in `Rakefile`

2. Run `rake update_source` to update the source code

3. Commit the `Rakefile` and the modified files in `ext/pg_query` to this source tree and make a PR


## Resources

See [libpg_query](https://github.com/pganalyze/libpg_query/blob/15-latest/README.md#resources) for pg_query in other languages, as well as products/tools built on pg_query.

## Original Author

- [Lukas Fittl](mailto:lukas@fittl.com)


## Special Thanks to

- [Jack Danger Canty](https://github.com/JackDanger), for significantly improving deparsing


## License

PostgreSQL server source code, used under the [PostgreSQL license](https://www.postgresql.org/about/licence/).<br>
Portions Copyright (c) 1996-2023, The PostgreSQL Global Development Group<br>
Portions Copyright (c) 1994, The Regents of the University of California

All other parts are licensed under the 3-clause BSD license, see LICENSE file for details.<br>
Copyright (c) 2015, Lukas Fittl <lukas@fittl.com><br>
Copyright (c) 2016-2023, Duboce Labs, Inc. (pganalyze) <team@pganalyze.com>
