#include "pg_query.h"
#include "pg_query_internal.h"
#include "nodes/makefuncs.h"
#include "pg_query_readfuncs.h"
#include "pg_query_outfuncs.h"
#include "postgres.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "utils/memutils.h"
#include "miscadmin.h"


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


static void qualify_rangevar(RangeVar *rv, const char *schema, List *cte_names) {
    // Safety check: ensure rv and rv->relname are not NULL
    if (!rv || !rv->relname) return;

    // Check if this is a CTE name, if so, remove any schema qualification
    if (cte_names) {
        ListCell *lc;
        foreach(lc, cte_names) {
            char *cte_name = (char *) lfirst(lc);
            if (strcmp(rv->relname, cte_name) == 0) {
                rv->schemaname = NULL; // Remove any schema from CTE references
                return;
            }
        }
    }

    // Don't qualify tables that start with "pg_" (PostgreSQL system tables)
    if (strncmp(rv->relname, "pg_", 3) == 0) {
        return;
    }

    // If not a CTE and not already qualified, add schema
    if (!rv->schemaname || strcmp(rv->schemaname, "") == 0) {
        rv->schemaname = pstrdup(schema);
    }
}

static void qualify_node(Node *node, const char *schema, List *cte_names, const char **func_names, int func_count);
static void filter_node(Node *node, const FilterSpec *spec);
static void filter_collect_tables(Node *node, bool nullable, Node **where_accum, const FilterSpec *spec);

char* pg_query_qualify_sql(const char *sql, const char *schema);

// Helper function to check if a function name should be qualified
static bool should_qualify_function(const char *func_name, const char **func_names, int func_count) {
    if (!func_names || func_count == 0) return false;

    for (int i = 0; i < func_count; i++) {
        const char *pattern = func_names[i];
        int pattern_len = strlen(pattern);

        // Check for prefix match with %
        if (pattern_len > 0 && pattern[pattern_len - 1] == '%') {
            if (strncmp(func_name, pattern, pattern_len - 1) == 0) {
                return true;
            }
        } else {
            // Exact match
            if (strcmp(func_name, pattern) == 0) {
                return true;
            }
        }
    }
    return false;
}

static void qualify_list(List *list, const char *schema, List *cte_names, const char **func_names, int func_count) {
    ListCell *lc;
    foreach(lc, list) {
        Node *n = (Node *) lfirst(lc);
        qualify_node(n, schema, cte_names, func_names, func_count);
    }
}

static void qualify_node(Node *node, const char *schema, List *cte_names, const char **func_names, int func_count) {
    if (!node) return;

    // Prevent stack overflow from deeply nested SQL
    check_stack_depth();

    switch (nodeTag(node)) {
        case T_RangeVar:
            qualify_rangevar((RangeVar *) node, schema, cte_names);
            break;
        case T_SelectStmt: {
            SelectStmt *stmt = (SelectStmt *) node;
            List *stmt_cte_names = cte_names;

            // If this statement has a WITH clause, process it with proper scoping
            if (stmt->withClause) {
                WithClause *with = (WithClause *) stmt->withClause;
                List *local_cte_names = list_copy(cte_names);
                ListCell *lc;

                if (with->recursive) {
                    // WITH RECURSIVE: Add all CTE names to scope before processing any definition
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        local_cte_names = lappend(local_cte_names, cte->ctename);
                    }

                    // Now process each CTE with all names in scope
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        qualify_node(cte->ctequery, schema, local_cte_names, func_names, func_count);
                    }
                } else {
                    // WITH (non-recursive): Process definition first, then add name to scope
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        qualify_node(cte->ctequery, schema, local_cte_names, func_names, func_count);
                        local_cte_names = lappend(local_cte_names, cte->ctename);
                    }
                }
                stmt_cte_names = local_cte_names;
            }

            qualify_list(stmt->fromClause, schema, stmt_cte_names, func_names, func_count);
            qualify_node((Node *) stmt->whereClause, schema, stmt_cte_names, func_names, func_count);
            qualify_node((Node *) stmt->havingClause, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->groupClause, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->sortClause, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->targetList, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->valuesLists, schema, stmt_cte_names, func_names, func_count);
            if (stmt->limitCount) qualify_node((Node *) stmt->limitCount, schema, stmt_cte_names, func_names, func_count);
            if (stmt->limitOffset) qualify_node((Node *) stmt->limitOffset, schema, stmt_cte_names, func_names, func_count);
            if (stmt->larg) qualify_node((Node *) stmt->larg, schema, stmt_cte_names, func_names, func_count);
            if (stmt->rarg) qualify_node((Node *) stmt->rarg, schema, stmt_cte_names, func_names, func_count);
            break;
        }
        case T_InsertStmt: {
            InsertStmt *stmt = (InsertStmt *) node;
            List *stmt_cte_names = cte_names;

            if (stmt->withClause) {
                WithClause *with = (WithClause *) stmt->withClause;
                List *local_cte_names = list_copy(cte_names);
                ListCell *lc;

                if (with->recursive) {
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        local_cte_names = lappend(local_cte_names, cte->ctename);
                    }
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        qualify_node(cte->ctequery, schema, local_cte_names, func_names, func_count);
                    }
                } else {
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        qualify_node(cte->ctequery, schema, local_cte_names, func_names, func_count);
                        local_cte_names = lappend(local_cte_names, cte->ctename);
                    }
                }
                stmt_cte_names = local_cte_names;
            }

            qualify_node((Node *) stmt->relation, schema, stmt_cte_names, func_names, func_count);
            if (stmt->selectStmt) qualify_node((Node *) stmt->selectStmt, schema, stmt_cte_names, func_names, func_count);
            if (stmt->onConflictClause) qualify_node((Node *) stmt->onConflictClause, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->returningList, schema, stmt_cte_names, func_names, func_count);
            break;
        }
        case T_UpdateStmt: {
            UpdateStmt *stmt = (UpdateStmt *) node;
            List *stmt_cte_names = cte_names;

            if (stmt->withClause) {
                WithClause *with = (WithClause *) stmt->withClause;
                List *local_cte_names = list_copy(cte_names);
                ListCell *lc;

                if (with->recursive) {
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        local_cte_names = lappend(local_cte_names, cte->ctename);
                    }
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        qualify_node(cte->ctequery, schema, local_cte_names, func_names, func_count);
                    }
                } else {
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        qualify_node(cte->ctequery, schema, local_cte_names, func_names, func_count);
                        local_cte_names = lappend(local_cte_names, cte->ctename);
                    }
                }
                stmt_cte_names = local_cte_names;
            }

            qualify_node((Node *) stmt->relation, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->fromClause, schema, stmt_cte_names, func_names, func_count);
            qualify_node((Node *) stmt->whereClause, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->targetList, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->returningList, schema, stmt_cte_names, func_names, func_count);
            break;
        }
        case T_DeleteStmt: {
            DeleteStmt *stmt = (DeleteStmt *) node;
            List *stmt_cte_names = cte_names;

            if (stmt->withClause) {
                WithClause *with = (WithClause *) stmt->withClause;
                List *local_cte_names = list_copy(cte_names);
                ListCell *lc;

                if (with->recursive) {
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        local_cte_names = lappend(local_cte_names, cte->ctename);
                    }
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        qualify_node(cte->ctequery, schema, local_cte_names, func_names, func_count);
                    }
                } else {
                    foreach(lc, with->ctes) {
                        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                        qualify_node(cte->ctequery, schema, local_cte_names, func_names, func_count);
                        local_cte_names = lappend(local_cte_names, cte->ctename);
                    }
                }
                stmt_cte_names = local_cte_names;
            }

            qualify_node((Node *) stmt->relation, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->usingClause, schema, stmt_cte_names, func_names, func_count);
            qualify_node((Node *) stmt->whereClause, schema, stmt_cte_names, func_names, func_count);
            qualify_list(stmt->returningList, schema, stmt_cte_names, func_names, func_count);
            break;
        }
        case T_JoinExpr: {
            JoinExpr *join = (JoinExpr *) node;
            qualify_node(join->larg, schema, cte_names, func_names, func_count);
            qualify_node(join->rarg, schema, cte_names, func_names, func_count);
            qualify_node(join->quals, schema, cte_names, func_names, func_count);
            break;
        }
        case T_FromExpr: {
            FromExpr *from = (FromExpr *) node;
            qualify_list(from->fromlist, schema, cte_names, func_names, func_count);
            qualify_node(from->quals, schema, cte_names, func_names, func_count);
            break;
        }
        case T_SubLink: {
            SubLink *sublink = (SubLink *) node;
            qualify_node(sublink->subselect, schema, cte_names, func_names, func_count);
            qualify_node(sublink->testexpr, schema, cte_names, func_names, func_count);
            break;
        }
        case T_A_Expr: {
            A_Expr *aexpr = (A_Expr *) node;
            qualify_node(aexpr->lexpr, schema, cte_names, func_names, func_count);
            qualify_node(aexpr->rexpr, schema, cte_names, func_names, func_count);
            break;
        }
        case T_FuncCall: {
            FuncCall *func = (FuncCall *) node;

            // Check if function name should be qualified
            if (func->funcname && list_length(func->funcname) == 1) {
                char *func_name = strVal(linitial(func->funcname));
                if (should_qualify_function(func_name, func_names, func_count)) {
                    // Create qualified function name
                    String *schema_val = makeString(pstrdup(schema));
                    func->funcname = lcons(schema_val, func->funcname);
                }
            }

            qualify_list(func->args, schema, cte_names, func_names, func_count);
            qualify_node(func->agg_filter, schema, cte_names, func_names, func_count);
            qualify_node((Node *)func->over, schema, cte_names, func_names, func_count);
            break;
        }
        case T_ResTarget: {
            ResTarget *res = (ResTarget *) node;
            qualify_node(res->val, schema, cte_names, func_names, func_count);
            break;
        }
        case T_WithClause: {
            // WithClause is now handled directly in each statement type
            // This case should not be reached
            break;
        }
        case T_CommonTableExpr: {
            CommonTableExpr *cte = (CommonTableExpr *) node;
            // This case should not normally be reached directly since
            // CTEs are processed through T_WithClause
            qualify_node(cte->ctequery, schema, cte_names, func_names, func_count);
            break;
        }
        case T_SortBy: {
            SortBy *sortby = (SortBy *) node;
            qualify_node(sortby->node, schema, cte_names, func_names, func_count);
            break;
        }
        case T_RangeSubselect: {
            RangeSubselect *subselect = (RangeSubselect *) node;
            qualify_node(subselect->subquery, schema, cte_names, func_names, func_count);
            break;
        }
        case T_List: {
            List *list = (List *) node;
            qualify_list(list, schema, cte_names, func_names, func_count);
            break;
        }
        case T_BoolExpr: {
            BoolExpr *boolexpr = (BoolExpr *) node;
            qualify_list(boolexpr->args, schema, cte_names, func_names, func_count);
            break;
        }
        case T_OnConflictClause: {
            OnConflictClause *onconflict = (OnConflictClause *) node;
            qualify_list(onconflict->targetList, schema, cte_names, func_names, func_count);
            qualify_node((Node *) onconflict->whereClause, schema, cte_names, func_names, func_count);
            break;
        }
        case T_CoalesceExpr: {
            CoalesceExpr *coalesceexpr = (CoalesceExpr *) node;
            qualify_list(coalesceexpr->args, schema, cte_names, func_names, func_count);
            break;
        }
        case T_CaseExpr: {
            CaseExpr *caseexpr = (CaseExpr *) node;
            qualify_node((Node *) caseexpr->arg, schema, cte_names, func_names, func_count);
            qualify_list(caseexpr->args, schema, cte_names, func_names, func_count);
            qualify_node((Node *) caseexpr->defresult, schema, cte_names, func_names, func_count);
            break;
        }
        case T_CaseWhen: {
            CaseWhen *casewhen = (CaseWhen *) node;
            qualify_node((Node *) casewhen->expr, schema, cte_names, func_names, func_count);
            qualify_node((Node *) casewhen->result, schema, cte_names, func_names, func_count);
            break;
        }
        case T_WindowDef: {
            WindowDef *windef = (WindowDef *) node;
            /* PARTITION BY (...) */
            qualify_list(windef->partitionClause, schema, cte_names, func_names, func_count);
            /* ORDER BY (...) (list of SortBy, each of which we already recurse into) */
            qualify_list(windef->orderClause, schema, cte_names, func_names, func_count);
            /* frame bound expressions such as 'RANGE BETWEEN ...' */
            qualify_node(windef->startOffset, schema, cte_names, func_names, func_count);
            qualify_node(windef->endOffset, schema, cte_names, func_names, func_count);
            break;
        }
        case T_RangeFunction: {
            RangeFunction *rangeFunc = (RangeFunction *) node;
            /* Traverse the functions list which contains function calls */
            qualify_list(rangeFunc->functions, schema, cte_names, func_names, func_count);
            /* Traverse the column definition list if present */
            qualify_list(rangeFunc->coldeflist, schema, cte_names, func_names, func_count);
            break;
        }
        case T_CreateFunctionStmt: {
            CreateFunctionStmt *funcStmt = (CreateFunctionStmt *) node;

            // Qualify the function body (sql_body for SQL functions)
            if (funcStmt->sql_body) {
                qualify_node(funcStmt->sql_body, schema, cte_names, func_names, func_count);
            }

            // Qualify any table references in function options (like AS $$ ... $$ clauses)
            if (funcStmt->options) {
                // First, check the function language
                char *language = NULL;
                ListCell *lc;
                foreach(lc, funcStmt->options) {
                    DefElem *def = (DefElem *) lfirst(lc);
                    if (def && def->defname && strcmp(def->defname, "language") == 0) {
                        if (def->arg && IsA(def->arg, String)) {
                            String *lang_str = (String *) def->arg;
                            language = lang_str->sval;
                            break;
                        }
                    }
                }

                // Handle different function languages appropriately
                if (language && strcmp(language, "sql") == 0) {
                    // For SQL functions, qualify the entire body
                    foreach(lc, funcStmt->options) {
                        DefElem *def = (DefElem *) lfirst(lc);
                        if (def && def->defname && strcmp(def->defname, "as") == 0) {
                            // This is the function body definition
                            if (def->arg && IsA(def->arg, List)) {
                                // Function body is a list of strings (for SQL functions)
                                List *body_list = (List *) def->arg;
                                ListCell *body_lc;
                                foreach(body_lc, body_list) {
                                    Node *body_node = (Node *) lfirst(body_lc);
                                    if (body_node && IsA(body_node, String)) {
                                        String *body_str = (String *) body_node;
                                        // Parse the function body as SQL and qualify it
                                        char *qualified_body = NULL;
                                        PG_TRY();
                                        {
                                        qualified_body = pg_query_qualify_sql(body_str->sval, schema);
                                        }
                                        PG_CATCH();
                                        {
                                          /* Ignore qualification errors in function bodies */
                                        }
                                        PG_END_TRY();
                                        if (qualified_body) {
                                          // Replace the original body with the qualified version
                                          body_str->sval = pstrdup(qualified_body);
                                          free(qualified_body);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            break;
        }
        case T_IndexStmt: {
            IndexStmt *stmt = (IndexStmt *) node;
            // Qualify the table being indexed
            qualify_node((Node *) stmt->relation, schema, cte_names, func_names, func_count);
            // Qualify any expressions in the index
            qualify_list(stmt->indexParams, schema, cte_names, func_names, func_count);
            // Qualify the WHERE clause if present
            qualify_node(stmt->whereClause, schema, cte_names, func_names, func_count);
            break;
        }
        case T_CreateStmt: {
            CreateStmt *stmt = (CreateStmt *) node;
            // The table being created doesn't get qualified (it's the target)
            // But we need to qualify any table references in constraints
            qualify_list(stmt->tableElts, schema, cte_names, func_names, func_count);
            // Qualify inherits clause
            qualify_list(stmt->inhRelations, schema, cte_names, func_names, func_count);
            break;
        }
        case T_CreateTableAsStmt: {
            CreateTableAsStmt *stmt = (CreateTableAsStmt *) node;
            // The table being created doesn't get qualified (it's the target)
            // But qualify the query that defines the table content
            qualify_node(stmt->query, schema, cte_names, func_names, func_count);
            break;
        }
        case T_AlterTableStmt: {
            AlterTableStmt *stmt = (AlterTableStmt *) node;
            // Qualify the table being altered
            qualify_node((Node *) stmt->relation, schema, cte_names, func_names, func_count);
            // Qualify any commands that might reference other tables
            qualify_list(stmt->cmds, schema, cte_names, func_names, func_count);
            break;
        }
        case T_ViewStmt: {
            ViewStmt *stmt = (ViewStmt *) node;
            // The view being created doesn't get qualified
            // But qualify the query that defines the view
            qualify_node(stmt->query, schema, cte_names, func_names, func_count);
            break;
        }
        case T_DropStmt: {
            DropStmt *stmt = (DropStmt *) node;
            // Handle different object types differently
            if (stmt->removeType == OBJECT_TRIGGER) {
                // For DROP TRIGGER, objects contains lists that represent trigger specifications
                // Structure depends on whether table is already qualified:
                // - Unqualified table: [table_name, trigger_name]
                // - Qualified table: [schema_name, table_name, trigger_name]
                ListCell *lc;
                foreach(lc, stmt->objects) {
                    List *trigger_spec = (List *) lfirst(lc);
                    int spec_length = list_length(trigger_spec);

                    if (spec_length == 2) {
                        // Unqualified table: [table_name, trigger_name]
                        Node *table_name_node = (Node *) linitial(trigger_spec);
                        Node *trigger_name_node = (Node *) lsecond(trigger_spec);

                        if (IsA(table_name_node, String)) {
                            String *table_name_str = (String *) table_name_node;
                            RangeVar *rv = makeRangeVar(NULL, table_name_str->sval, -1);
                            qualify_rangevar(rv, schema, cte_names);

                            // If the table should be qualified, modify the list structure
                            if (rv->schemaname) {
                                // Replace [table_name, trigger_name] with [schema_name, table_name, trigger_name]
                                trigger_spec = NIL;
                                trigger_spec = lappend(trigger_spec, makeString(pstrdup(rv->schemaname)));
                                trigger_spec = lappend(trigger_spec, makeString(pstrdup(rv->relname)));
                                trigger_spec = lappend(trigger_spec, trigger_name_node);

                                // Replace the list in stmt->objects
                                lfirst(lc) = trigger_spec;
                            }
                        }
                    } else if (spec_length == 3) {
                        // Already qualified table: [schema_name, table_name, trigger_name]
                        // No need to modify - it's already qualified
                    }
                }
            } else {
                // For other drop types, handle based on the object type
                if (stmt->removeType == OBJECT_TABLE || stmt->removeType == OBJECT_VIEW ||
                    stmt->removeType == OBJECT_MATVIEW || stmt->removeType == OBJECT_INDEX ||
                    stmt->removeType == OBJECT_SEQUENCE) {
                    // These objects use simple name lists: [name] or [schema, name]
                    ListCell *lc;
                    foreach(lc, stmt->objects) {
                        List *name_list = (List *) lfirst(lc);
                        if (list_length(name_list) == 1) {
                            // Unqualified name: [name]
                            Node *name_node = (Node *) linitial(name_list);
                            if (IsA(name_node, String)) {
                                String *name_str = (String *) name_node;
                                RangeVar *rv = makeRangeVar(NULL, name_str->sval, -1);
                                qualify_rangevar(rv, schema, cte_names);

                                // If should be qualified, replace with [schema, name]
                                if (rv->schemaname) {
                                    name_list = NIL;
                                    name_list = lappend(name_list, makeString(pstrdup(rv->schemaname)));
                                    name_list = lappend(name_list, makeString(pstrdup(rv->relname)));
                                    lfirst(lc) = name_list;
                                }
                            }
                        }
                        // If list_length == 2, it's already qualified: [schema, name]
                        // No need to modify
                    }
                } else {
                    // For other drop types (FUNCTION, etc.), use the default handling
                    // These may have different structures (like ObjectWithArgs)
                    qualify_list(stmt->objects, schema, cte_names, func_names, func_count);
                }
            }
            break;
        }
        case T_CreateTrigStmt: {
            CreateTrigStmt *stmt = (CreateTrigStmt *) node;
            // Qualify the table the trigger is on
            qualify_node((Node *) stmt->relation, schema, cte_names, func_names, func_count);
            // Qualify any expressions in WHEN clause
            qualify_node(stmt->whenClause, schema, cte_names, func_names, func_count);
            // Qualify the function name if it's in the function list
            if (stmt->funcname && func_names && func_count > 0) {
                char *func_name = strVal(llast(stmt->funcname));
                if (should_qualify_function(func_name, func_names, func_count)) {
                    // If it's a single-element list (unqualified function), qualify it
                    if (list_length(stmt->funcname) == 1) {
                        stmt->funcname = lcons(makeString(pstrdup(schema)), stmt->funcname);
                    }
                }
            }
            break;
        }
        case T_VacuumStmt: {
            VacuumStmt *stmt = (VacuumStmt *) node;
            // Qualify table references in VACUUM/ANALYZE statements
            qualify_list(stmt->rels, schema, cte_names, func_names, func_count);
            break;
        }
        case T_VacuumRelation: {
            VacuumRelation *vacrel = (VacuumRelation *) node;
            // Qualify the table reference in the vacuum relation
            if (vacrel->relation) {
                qualify_rangevar(vacrel->relation, schema, cte_names);
            }
            break;
        }
        case T_ClusterStmt: {
            ClusterStmt *stmt = (ClusterStmt *) node;
            // Qualify table reference in CLUSTER statement
            if (stmt->relation) {
                qualify_rangevar(stmt->relation, schema, cte_names);
            }
            break;
        }
        case T_TruncateStmt: {
            TruncateStmt *stmt = (TruncateStmt *) node;
            // Qualify table references in TRUNCATE statement
            qualify_list(stmt->relations, schema, cte_names, func_names, func_count);
            break;
        }
        case T_ExplainStmt: {
            ExplainStmt *stmt = (ExplainStmt *) node;
            // Qualify the query being explained
            qualify_node(stmt->query, schema, cte_names, func_names, func_count);
            break;
        }
        case T_LockStmt: {
            LockStmt *stmt = (LockStmt *) node;
            // Qualify table references in LOCK statement
            qualify_list(stmt->relations, schema, cte_names, func_names, func_count);
            break;
        }
        case T_GrantStmt: {
            GrantStmt *stmt = (GrantStmt *) node;
            // Qualify the objects being granted on
            qualify_list(stmt->objects, schema, cte_names, func_names, func_count);
            break;
        }
        case T_AlterTableCmd: {
            AlterTableCmd *cmd = (AlterTableCmd *) node;
            // Qualify any table references in alter table commands
            qualify_node(cmd->def, schema, cte_names, func_names, func_count);
            break;
        }
        case T_Constraint: {
            Constraint *constraint = (Constraint *) node;
            // Qualify table references in foreign key constraints
            if (constraint->pktable) {
                qualify_node((Node *) constraint->pktable, schema, cte_names, func_names, func_count);
            }
            // Qualify any expressions in check constraints
            qualify_node(constraint->raw_expr, schema, cte_names, func_names, func_count);
            // cooked_expr is a char* not a Node*, so we skip it
            break;
        }
        case T_ColumnDef: {
            ColumnDef *coldef = (ColumnDef *) node;
            // Qualify any constraints on the column
            qualify_list(coldef->constraints, schema, cte_names, func_names, func_count);
            // Qualify default expressions
            qualify_node(coldef->raw_default, schema, cte_names, func_names, func_count);
            qualify_node(coldef->cooked_default, schema, cte_names, func_names, func_count);
            break;
        }
        case T_IndexElem: {
            IndexElem *elem = (IndexElem *) node;
            // Qualify any expressions in index elements
            qualify_node(elem->expr, schema, cte_names, func_names, func_count);
            break;
        }
        case T_ColumnRef:
        case T_A_Const:
        case T_TypeCast:
        case T_NullTest:
        case T_BooleanTest:
        case T_MinMaxExpr:
        case T_A_ArrayExpr:
        case T_RowExpr:
        case T_CoerceToDomain:
        case T_CoerceViaIO:
        case T_ArrayCoerceExpr:
        case T_ConvertRowtypeExpr:
        case T_CollateExpr:
        case T_TypeName:
        case T_DefElem:
        case T_LockingClause:
        case T_XmlSerialize:
        case T_SetOperationStmt:
        case T_WindowClause:
        case T_NotifyStmt:
        case T_DeclareCursorStmt:
        case T_CreateTableSpaceStmt:
        case T_DropTableSpaceStmt:
        case T_AlterTableSpaceOptionsStmt:
        case T_AlterTableMoveAllStmt:
        case T_SecLabelStmt:
        case T_CreateForeignTableStmt:
        case T_ImportForeignSchemaStmt:
        case T_CreateExtensionStmt:
        case T_AlterExtensionStmt:
        case T_AlterExtensionContentsStmt:
        case T_CreateEventTrigStmt:
        case T_AlterEventTrigStmt:
        case T_RefreshMatViewStmt:
        case T_ReplicaIdentityStmt:
        case T_AlterSystemStmt:
        case T_CreatePolicyStmt:
        case T_AlterPolicyStmt:
        case T_CreateTransformStmt:
        case T_CreateAmStmt:
        case T_CreatePublicationStmt:
        case T_AlterPublicationStmt:
        case T_CreateSubscriptionStmt:
        case T_AlterSubscriptionStmt:
        case T_DropSubscriptionStmt:
        case T_CreateStatsStmt:
        case T_AlterCollationStmt:
        case T_CallStmt:
        case T_AlterStatsStmt:
        case T_A_Indices:
        case T_A_Indirection:
        case T_A_Star:
        case T_ParamRef:
        case T_IntList:
        case T_OidList:
            // These node types either don't contain table references or are handled elsewhere
            break;
        default:
            // For any unhandled node types, we could add a warning or log
            break;
    }
}

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

char* pg_query_qualify_sql_with_funcs(const char *sql, const char *schema, const char **func_names, int func_count) {
    PgQueryProtobufParseResult parse_result = {0};
    PgQueryDeparseResult deparse_result = {0};
    List *stmts;
    ListCell *lc;
    char *result = NULL;
    MemoryContext ctx;

    // Safety check: ensure schema is not NULL
    if (!schema) return NULL;

    // Parse the SQL into protobuf
    parse_result = pg_query_parse_protobuf(sql);
    if (parse_result.error) {
        pg_query_free_protobuf_parse_result(parse_result);
        return NULL;
    }

    ctx = pg_query_enter_memory_context();

    PG_TRY();
    {

        // Convert protobuf to AST nodes
        stmts = pg_query_protobuf_to_nodes(parse_result.parse_tree);

        // Qualify table references in each statement
        foreach(lc, stmts) {
            RawStmt *raw_stmt = castNode(RawStmt, lfirst(lc));
            qualify_node(raw_stmt->stmt, schema, NULL, func_names, func_count);
        }

        // Convert back to protobuf
        PgQueryProtobuf qualified_protobuf = pg_query_nodes_to_protobuf(stmts);

        // Deparse back to SQL
        deparse_result = pg_query_deparse_protobuf(qualified_protobuf);
        if (deparse_result.error) {
            pg_query_free_deparse_result(deparse_result);
            result = NULL;
        } else {
            result = strdup(deparse_result.query);
            pg_query_free_deparse_result(deparse_result);
        }

        if (qualified_protobuf.data) {
            free(qualified_protobuf.data);
        }
    }
    PG_CATCH();
    {
        result = NULL;
    }
    PG_END_TRY();

    pg_query_exit_memory_context(ctx);
    pg_query_free_protobuf_parse_result(parse_result);

    return result;
}

char* pg_query_qualify_sql(const char *sql, const char *schema) {
    return pg_query_qualify_sql_with_funcs(sql, schema, NULL, 0);
}
