/*
 * Ruby-free memory-safety harness for the tenant-filter rewrite path (Task 09,
 * tier 1). Calls the public C API in pg_query_qualify.h directly across the
 * rewrite shapes added in Tasks 01-07, with no Ruby interpreter in the process,
 * so it can be run under Valgrind/ASAN with zero interpreter noise and a
 * meaningful --error-exitcode.
 *
 * It is also a small correctness smoke test: each case asserts the expected
 * NULL/non-NULL result and (for filtered calls) the `unhandled` refusal flag,
 * and frees every returned string. Exit code is non-zero if any assertion
 * fails, so the same binary catches both logic regressions and leaks.
 *
 * Build (after `rake compile`, which produces the sibling .o files):
 *   see bin/run_memcheck.sh
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pg_query.h"
#include "pg_query_qualify.h"

static int failures = 0;
static int checks = 0;

static const char *SCHEMA = "public";
static const char *FUNCS[] = { "now_fn" };

/* Run a filtered qualify and assert the result is non-NULL, not refused, and
 * (when `must_contain` is non-NULL) contains the given substring. Frees it. */
static void expect_ok(const char *label, const char *sql, const char *must_contain)
{
    int unhandled = 0;
    char *out = pg_query_qualify_sql_full(sql, SCHEMA, NULL, 0, "sbid", 42,
                                          NULL, 0, &unhandled, 1 /* strict */);
    checks++;
    if (!out) {
        fprintf(stderr, "FAIL [%s]: expected SQL, got NULL (unhandled=%d)\n", label, unhandled);
        failures++;
        return;
    }
    if (unhandled) {
        fprintf(stderr, "FAIL [%s]: unexpected refusal flag\n", label);
        failures++;
    }
    if (must_contain && !strstr(out, must_contain)) {
        fprintf(stderr, "FAIL [%s]: output missing %s:\n  %s\n", label, must_contain, out);
        failures++;
    }
    free(out);
}

/* Run a filtered qualify in strict mode and assert it is refused: NULL result
 * with unhandled == 1 (distinct from a parse failure, which is NULL + 0). */
static void expect_refused(const char *label, const char *sql)
{
    int unhandled = 0;
    char *out = pg_query_qualify_sql_full(sql, SCHEMA, NULL, 0, "sbid", 42,
                                          NULL, 0, &unhandled, 1 /* strict */);
    checks++;
    if (out) {
        fprintf(stderr, "FAIL [%s]: expected refusal, got SQL:\n  %s\n", label, out);
        failures++;
        free(out);
        return;
    }
    if (!unhandled) {
        fprintf(stderr, "FAIL [%s]: NULL but unhandled flag not set (looks like a parse failure)\n", label);
        failures++;
    }
}

/* Run a non-strict (bypass) qualify and assert it returns SQL without refusing,
 * even for a shape that strict mode would refuse. Frees it. */
static void expect_bypass(const char *label, const char *sql)
{
    int unhandled = 0;
    char *out = pg_query_qualify_sql_full(sql, SCHEMA, NULL, 0, "sbid", 42,
                                          NULL, 0, &unhandled, 0 /* strict=false */);
    checks++;
    if (!out) {
        fprintf(stderr, "FAIL [%s]: expected SQL in bypass mode, got NULL\n", label);
        failures++;
        return;
    }
    free(out);
}

/* Excluded-table case: countries must not receive the filter. */
static void expect_excluded(const char *label, const char *sql, const char *exclude)
{
    int unhandled = 0;
    const char *ex[] = { exclude };
    char *out = pg_query_qualify_sql_full(sql, SCHEMA, NULL, 0, "sbid", 42,
                                          ex, 1, &unhandled, 1);
    checks++;
    if (!out) {
        fprintf(stderr, "FAIL [%s]: expected SQL, got NULL\n", label);
        failures++;
        return;
    }
    free(out);
}

int main(void)
{
    /* Plain qualification paths (no filter). */
    char *q = pg_query_qualify_sql("SELECT * FROM users", SCHEMA);
    checks++;
    if (!q) { fprintf(stderr, "FAIL [plain qualify]\n"); failures++; } else { free(q); }

    char *qf = pg_query_qualify_sql_with_funcs("SELECT now_fn() FROM users", SCHEMA, FUNCS, 1);
    checks++;
    if (!qf) { fprintf(stderr, "FAIL [qualify_with_funcs]\n"); failures++; } else { free(qf); }

    /* Outer USING / NATURAL join subquery wrapping (Task 03). */
    expect_ok("left using",  "SELECT * FROM users u LEFT JOIN orders o USING (id)", "WHERE");
    expect_ok("right using", "SELECT * FROM users u RIGHT JOIN orders o USING (id)", NULL);
    expect_ok("full using",  "SELECT * FROM users u FULL JOIN orders o USING (id)", NULL);
    expect_ok("natural left",  "SELECT * FROM users u NATURAL LEFT JOIN orders o", NULL);
    expect_ok("natural right", "SELECT * FROM users u NATURAL RIGHT JOIN orders o", NULL);
    expect_ok("natural full",  "SELECT * FROM users u NATURAL FULL JOIN orders o", NULL);
    expect_ok("explicit on left", "SELECT * FROM users u LEFT JOIN orders o ON u.id = o.user_id", NULL);
    // Nullable side of a USING/NATURAL join is itself a join subtree: every
    // table must be wrapped (regression for the ON-alongside-USING bug).
    expect_ok("using nullable join subtree", "SELECT * FROM a RIGHT JOIN b ON a.id = b.id FULL JOIN c USING (x)", NULL);
    expect_ok("natural nullable join subtree", "SELECT * FROM (a JOIN b ON a.id = b.id) NATURAL FULL JOIN c", NULL);

    /* RETURNING subqueries (Task 04). */
    expect_ok("insert returning subq", "INSERT INTO users (x) VALUES (1) RETURNING (SELECT count(*) FROM items)", NULL);
    expect_ok("update returning subq", "UPDATE users SET x = 1 RETURNING (SELECT count(*) FROM items)", NULL);
    expect_ok("delete returning subq", "DELETE FROM users RETURNING (SELECT count(*) FROM items)", NULL);

    /* INSERT ... VALUES injection + refusal (Task 07). */
    expect_ok("insert values single", "INSERT INTO shifts (a) VALUES (1)", "sbid");
    expect_ok("insert values multi",  "INSERT INTO shifts (a, b) VALUES (1, 2), (3, 4)", "sbid");
    expect_ok("insert values correct sbid", "INSERT INTO shifts (sbid, a) VALUES (42, 1)", NULL);
    expect_ok("insert values param sbid", "INSERT INTO shifts (a, sbid) VALUES ($1, $2)", "42");
    expect_ok("insert values multi param sbid", "INSERT INTO shifts (a, sbid) VALUES ($1, $2), ($3, $4)", "42");
    expect_ok("insert select",        "INSERT INTO audit (x) SELECT id FROM orders", "WHERE");
    expect_refused("insert values conflicting sbid", "INSERT INTO shifts (sbid, a) VALUES (7, 1)");
    expect_refused("insert values short tuple", "INSERT INTO shifts (a, sbid) VALUES ($1)");
    expect_refused("insert values no cols", "INSERT INTO shifts VALUES (1, 2)");
    expect_refused("insert default values", "INSERT INTO shifts DEFAULT VALUES");

    /* Strict statement gate (Task 01) + non-strict bypass (Task 06). */
    expect_refused("merge refused", "MERGE INTO accounts a USING txns t ON a.id = t.aid WHEN MATCHED THEN UPDATE SET bal = 1");
    expect_refused("copy refused",  "COPY (SELECT * FROM users) TO STDOUT");
    expect_bypass("merge bypass", "MERGE INTO accounts a USING txns t ON a.id = t.aid WHEN MATCHED THEN UPDATE SET bal = 1");
    expect_bypass("insert no cols bypass", "INSERT INTO shifts VALUES (1, 2)");

    /* Excluded table, CTE shadowing, LATERAL, nested subqueries. */
    expect_excluded("excluded table", "SELECT * FROM users u JOIN countries c ON u.country_id = c.id", "countries");
    expect_ok("cte shadowing", "WITH users AS (SELECT 1 AS id) SELECT * FROM users", NULL);
    expect_ok("lateral comma", "SELECT * FROM users u, LATERAL (SELECT * FROM orders o WHERE o.user_id = u.id) x", NULL);
    expect_ok("lateral join",  "SELECT * FROM users u JOIN LATERAL (SELECT * FROM orders o WHERE o.user_id = u.id) x ON true", NULL);
    expect_ok("nested subquery", "SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE total > (SELECT avg(total) FROM orders))", NULL);

    /* Parse failure: NULL result, but NOT a refusal (unhandled stays 0). */
    {
        int unhandled = 0;
        char *out = pg_query_qualify_sql_full("SELECT FROM FROM", SCHEMA, NULL, 0, "sbid", 42,
                                              NULL, 0, &unhandled, 1);
        checks++;
        if (out) { fprintf(stderr, "FAIL [parse failure]: expected NULL\n"); failures++; free(out); }
        else if (unhandled) { fprintf(stderr, "FAIL [parse failure]: unhandled set on a parse error\n"); failures++; }
    }

    fprintf(stderr, "memcheck harness: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
