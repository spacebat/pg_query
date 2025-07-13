#include "pg_query.h"
#include "pg_query_internal.h"
#include "pg_query_readfuncs.h"
#include "pg_query_outfuncs.h"
#include "postgres.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "utils/memutils.h"

static void qualify_rangevar(RangeVar *rv, const char *schema, List *cte_names) {
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

    // If not a CTE and not already qualified, add schema
    if (!rv->schemaname || strcmp(rv->schemaname, "") == 0) {
        rv->schemaname = pstrdup(schema);
    }
}

static void qualify_node(Node *node, const char *schema, List *cte_names);

static void qualify_list(List *list, const char *schema, List *cte_names) {
    ListCell *lc;
    foreach(lc, list) {
        Node *n = (Node *) lfirst(lc);
        qualify_node(n, schema, cte_names);
    }
}

static void qualify_node(Node *node, const char *schema, List *cte_names) {
    if (!node) return;

    switch (nodeTag(node)) {
        case T_RangeVar:
            qualify_rangevar((RangeVar *) node, schema, cte_names);
            break;
        case T_SelectStmt: {
            SelectStmt *stmt = (SelectStmt *) node;
            List *stmt_cte_names = cte_names;

            // If this statement has a WITH clause, collect CTE names
            if (stmt->withClause) {
                WithClause *with = (WithClause *) stmt->withClause;
                List *new_cte_names = NIL;
                ListCell *lc;
                foreach(lc, with->ctes) {
                    CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                    new_cte_names = lappend(new_cte_names, cte->ctename);
                }
                stmt_cte_names = list_concat(cte_names, new_cte_names);
                qualify_node((Node *) stmt->withClause, schema, stmt_cte_names);
            }

            qualify_list(stmt->fromClause, schema, stmt_cte_names);
            qualify_node((Node *) stmt->whereClause, schema, stmt_cte_names);
            qualify_node((Node *) stmt->havingClause, schema, stmt_cte_names);
            qualify_list(stmt->groupClause, schema, stmt_cte_names);
            qualify_list(stmt->sortClause, schema, stmt_cte_names);
            qualify_list(stmt->targetList, schema, stmt_cte_names);
            qualify_list(stmt->valuesLists, schema, stmt_cte_names);
            if (stmt->limitCount) qualify_node((Node *) stmt->limitCount, schema, stmt_cte_names);
            if (stmt->limitOffset) qualify_node((Node *) stmt->limitOffset, schema, stmt_cte_names);
            if (stmt->larg) qualify_node((Node *) stmt->larg, schema, stmt_cte_names);
            if (stmt->rarg) qualify_node((Node *) stmt->rarg, schema, stmt_cte_names);
            break;
        }
        case T_InsertStmt: {
            InsertStmt *stmt = (InsertStmt *) node;
            List *stmt_cte_names = cte_names;

            if (stmt->withClause) {
                WithClause *with = (WithClause *) stmt->withClause;
                List *new_cte_names = NIL;
                ListCell *lc;
                foreach(lc, with->ctes) {
                    CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                    new_cte_names = lappend(new_cte_names, cte->ctename);
                }
                stmt_cte_names = list_concat(cte_names, new_cte_names);
                qualify_node((Node *) stmt->withClause, schema, stmt_cte_names);
            }

            qualify_node((Node *) stmt->relation, schema, stmt_cte_names);
            if (stmt->selectStmt) qualify_node((Node *) stmt->selectStmt, schema, stmt_cte_names);
            if (stmt->onConflictClause) qualify_node((Node *) stmt->onConflictClause, schema, stmt_cte_names);
            qualify_list(stmt->returningList, schema, stmt_cte_names);
            break;
        }
        case T_UpdateStmt: {
            UpdateStmt *stmt = (UpdateStmt *) node;
            List *stmt_cte_names = cte_names;

            if (stmt->withClause) {
                WithClause *with = (WithClause *) stmt->withClause;
                List *new_cte_names = NIL;
                ListCell *lc;
                foreach(lc, with->ctes) {
                    CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                    new_cte_names = lappend(new_cte_names, cte->ctename);
                }
                stmt_cte_names = list_concat(cte_names, new_cte_names);
                qualify_node((Node *) stmt->withClause, schema, stmt_cte_names);
            }

            qualify_node((Node *) stmt->relation, schema, stmt_cte_names);
            qualify_list(stmt->fromClause, schema, stmt_cte_names);
            qualify_node((Node *) stmt->whereClause, schema, stmt_cte_names);
            qualify_list(stmt->targetList, schema, stmt_cte_names);
            qualify_list(stmt->returningList, schema, stmt_cte_names);
            break;
        }
        case T_DeleteStmt: {
            DeleteStmt *stmt = (DeleteStmt *) node;
            List *stmt_cte_names = cte_names;

            if (stmt->withClause) {
                WithClause *with = (WithClause *) stmt->withClause;
                List *new_cte_names = NIL;
                ListCell *lc;
                foreach(lc, with->ctes) {
                    CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
                    new_cte_names = lappend(new_cte_names, cte->ctename);
                }
                stmt_cte_names = list_concat(cte_names, new_cte_names);
                qualify_node((Node *) stmt->withClause, schema, stmt_cte_names);
            }

            qualify_node((Node *) stmt->relation, schema, stmt_cte_names);
            qualify_list(stmt->usingClause, schema, stmt_cte_names);
            qualify_node((Node *) stmt->whereClause, schema, stmt_cte_names);
            qualify_list(stmt->returningList, schema, stmt_cte_names);
            break;
        }
        case T_JoinExpr: {
            JoinExpr *join = (JoinExpr *) node;
            qualify_node(join->larg, schema, cte_names);
            qualify_node(join->rarg, schema, cte_names);
            qualify_node(join->quals, schema, cte_names);
            break;
        }
        case T_FromExpr: {
            FromExpr *from = (FromExpr *) node;
            qualify_list(from->fromlist, schema, cte_names);
            qualify_node(from->quals, schema, cte_names);
            break;
        }
        case T_SubLink: {
            SubLink *sublink = (SubLink *) node;
            qualify_node(sublink->subselect, schema, cte_names);
            qualify_node(sublink->testexpr, schema, cte_names);
            break;
        }
        case T_A_Expr: {
            A_Expr *aexpr = (A_Expr *) node;
            qualify_node(aexpr->lexpr, schema, cte_names);
            qualify_node(aexpr->rexpr, schema, cte_names);
            break;
        }
        case T_FuncCall: {
            FuncCall *func = (FuncCall *) node;
            qualify_list(func->args, schema, cte_names);
            qualify_node(func->agg_filter, schema, cte_names);
            qualify_node((Node *)func->over, schema, cte_names);
            break;
        }
        case T_ResTarget: {
            ResTarget *res = (ResTarget *) node;
            qualify_node(res->val, schema, cte_names);
            break;
        }
        case T_WithClause: {
            WithClause *with = (WithClause *) node;
            qualify_list(with->ctes, schema, cte_names);
            break;
        }
        case T_CommonTableExpr: {
            CommonTableExpr *cte = (CommonTableExpr *) node;
            // Only qualify the CTE query, not the CTE name itself
            qualify_node(cte->ctequery, schema, cte_names);
            break;
        }
        case T_SortBy: {
            SortBy *sortby = (SortBy *) node;
            qualify_node(sortby->node, schema, cte_names);
            break;
        }
        case T_RangeSubselect: {
            RangeSubselect *subselect = (RangeSubselect *) node;
            qualify_node(subselect->subquery, schema, cte_names);
            break;
        }
        case T_List: {
            List *list = (List *) node;
            qualify_list(list, schema, cte_names);
            break;
        }
        case T_BoolExpr: {
            BoolExpr *boolexpr = (BoolExpr *) node;
            qualify_list(boolexpr->args, schema, cte_names);
            break;
        }
        case T_OnConflictClause: {
            OnConflictClause *onconflict = (OnConflictClause *) node;
            qualify_list(onconflict->targetList, schema, cte_names);
            qualify_node((Node *) onconflict->whereClause, schema, cte_names);
            break;
        }
        case T_CoalesceExpr: {
            CoalesceExpr *coalesceexpr = (CoalesceExpr *) node;
            qualify_list(coalesceexpr->args, schema, cte_names);
            break;
        }
        case T_ColumnRef:/*  { */
        /*     ColumnRef *colref = (ColumnRef *) node; */
        /*     // Only qualify two-part column references (table.column format) */
        /*     if (list_length(colref->fields) == 2) { */
        /*         Node *first = (Node *) linitial(colref->fields); */
        /*         if (IsA(first, String)) { */
        /*             String *table_name = (String *) first; */
        /*             // Check if this is a CTE name, if so, don't qualify */
        /*             if (cte_names) { */
        /*                 ListCell *lc; */
        /*                 foreach(lc, cte_names) { */
        /*                     char *cte_name = (char *) lfirst(lc); */
        /*                     if (strcmp(table_name->sval, cte_name) == 0) { */
        /*                         return; // Don't qualify CTE column references */
        /*                     } */
        /*                 } */
        /*             } */
        /*             // Only qualify if table name is not an alias (longer than 2 chars and contains underscore or common table patterns) */
        /*             if (strlen(table_name->sval) > 2 &&  */
        /*                 (strchr(table_name->sval, '_') != NULL ||  */
        /*                  strstr(table_name->sval, "user") != NULL ||  */
        /*                  strstr(table_name->sval, "order") != NULL || */
        /*                  strstr(table_name->sval, "product") != NULL)) { */
        /*                 // Create a new schema string node and insert it at the beginning */
        /*                 String *schema_str = makeString(pstrdup(schema)); */
        /*                 colref->fields = lcons(schema_str, colref->fields); */
        /*             } */
        /*         } */
        /*     } */
        /*     break; */
        /* } */

        case T_A_Const:
        case T_TypeCast:
        case T_NullTest:
        case T_BooleanTest:
        case T_CaseExpr:
        case T_MinMaxExpr:
        case T_A_ArrayExpr:
        case T_RowExpr:
        case T_CoerceToDomain:
        case T_CoerceViaIO:
        case T_ArrayCoerceExpr:
        case T_ConvertRowtypeExpr:
        case T_CollateExpr:
        case T_WindowDef:
        case T_RangeFunction:
        case T_TypeName:
        case T_ColumnDef:
        case T_IndexElem:
        case T_Constraint:
        case T_DefElem:
        case T_LockingClause:
        case T_XmlSerialize:
        case T_SetOperationStmt:
        case T_WindowClause:
        case T_IndexStmt:
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

char* pg_query_qualify_sql(const char *sql, const char *schema) {
    PgQueryProtobufParseResult parse_result = {0};
    PgQueryDeparseResult deparse_result = {0};
    List *stmts;
    ListCell *lc;
    char *result = NULL;
    MemoryContext ctx;

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
            qualify_node(raw_stmt->stmt, schema, NULL);
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
