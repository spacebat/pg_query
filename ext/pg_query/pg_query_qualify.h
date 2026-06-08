// src/pg_query_qualify.h
#pragma once

char* pg_query_qualify_sql(const char* sql, const char* schema);
char* pg_query_qualify_sql_with_funcs(const char* sql, const char* schema, const char** func_names, int func_count);
char* pg_query_qualify_sql_full(const char* sql, const char* schema, const char** func_names, int func_count, const char* filter_column, int filter_value, const char** filter_exclude, int filter_exclude_count);
