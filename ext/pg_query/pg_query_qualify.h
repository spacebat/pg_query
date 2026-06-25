// src/pg_query_qualify.h
#pragma once

char* pg_query_qualify_sql(const char* sql, const char* schema);
char* pg_query_qualify_sql_with_funcs(const char* sql, const char* schema, const char** func_names, int func_count);
// out_unhandled (may be NULL): set to 1 when filtering was requested but a
// top-level statement is outside the strict allowlist, in which case the call
// returns NULL without mutating/deparsing. Lets callers distinguish a refusal
// from a parse/deparse failure (also NULL, but out_unhandled left 0).
char* pg_query_qualify_sql_full(const char* sql, const char* schema, const char** func_names, int func_count, const char* filter_column, int filter_value, const char** filter_exclude, int filter_exclude_count, int* out_unhandled);
