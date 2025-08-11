// src/pg_query_qualify.h
#pragma once

char* pg_query_qualify_sql(const char* sql, const char* schema);
char* pg_query_qualify_sql_with_funcs(const char* sql, const char* schema, const char** func_names, int func_count);
