#include "pg_query.h"
#include "pg_query_qualify.h"

#include "xxhash/xxhash.h"
#include <ruby.h>
#include <ruby/encoding.h>

void raise_ruby_parse_error(PgQueryProtobufParseResult result);
void raise_ruby_normalize_error(PgQueryNormalizeResult result);
void raise_ruby_fingerprint_error(PgQueryFingerprintResult result);
void raise_ruby_scan_error(PgQueryScanResult result);

VALUE pg_query_ruby_parse_protobuf(VALUE self, VALUE input);
VALUE pg_query_ruby_deparse_protobuf(VALUE self, VALUE input);
VALUE pg_query_ruby_normalize(VALUE self, VALUE input);
VALUE pg_query_ruby_fingerprint(VALUE self, VALUE input);
VALUE pg_query_ruby_scan(VALUE self, VALUE input);
VALUE pg_query_ruby_hash_xxh3_64(VALUE self, VALUE input, VALUE seed);
VALUE pg_query_ruby_qualify(VALUE self, VALUE sql_str, VALUE schema_str);
VALUE pg_query_ruby_qualify_with_funcs(VALUE self, VALUE sql_str, VALUE schema_str, VALUE func_names_array);
VALUE pg_query_ruby_qualify_full(VALUE self, VALUE sql_str, VALUE schema_str, VALUE func_names_array, VALUE filter_column, VALUE filter_value, VALUE filter_exclude_array);
static const char** ruby_string_array_to_c(VALUE array, int *out_count);

__attribute__((visibility ("default"))) void Init_pg_query(void)
{
	VALUE cPgQuery;

	cPgQuery = rb_define_module("PgQuery");

	rb_define_singleton_method(cPgQuery, "parse_protobuf", pg_query_ruby_parse_protobuf, 1);
	rb_define_singleton_method(cPgQuery, "deparse_protobuf", pg_query_ruby_deparse_protobuf, 1);
	rb_define_singleton_method(cPgQuery, "normalize", pg_query_ruby_normalize, 1);
	rb_define_singleton_method(cPgQuery, "fingerprint", pg_query_ruby_fingerprint, 1);
	rb_define_singleton_method(cPgQuery, "_raw_scan", pg_query_ruby_scan, 1);
	rb_define_singleton_method(cPgQuery, "hash_xxh3_64", pg_query_ruby_hash_xxh3_64, 2);
	rb_define_singleton_method(cPgQuery, "qualify", pg_query_ruby_qualify, 2);
	rb_define_singleton_method(cPgQuery, "qualify_with_funcs", pg_query_ruby_qualify_with_funcs, 3);
	rb_define_singleton_method(cPgQuery, "qualify_full", pg_query_ruby_qualify_full, 6);
	rb_define_const(cPgQuery, "PG_VERSION", rb_str_new2(PG_VERSION));
	rb_define_const(cPgQuery, "PG_MAJORVERSION", rb_str_new2(PG_MAJORVERSION));
	rb_define_const(cPgQuery, "PG_VERSION_NUM", INT2NUM(PG_VERSION_NUM));
}

void raise_ruby_parse_error(PgQueryProtobufParseResult result)
{
	VALUE cPgQuery, cParseError;
	VALUE args[4];

	cPgQuery    = rb_const_get(rb_cObject, rb_intern("PgQuery"));
	cParseError = rb_const_get_at(cPgQuery, rb_intern("ParseError"));

	args[0] = rb_str_new2(result.error->message);
	args[1] = rb_str_new2(result.error->filename);
	args[2] = INT2NUM(result.error->lineno);
	args[3] = INT2NUM(result.error->cursorpos);

	pg_query_free_protobuf_parse_result(result);

	rb_exc_raise(rb_class_new_instance(4, args, cParseError));
}

void raise_ruby_deparse_error(PgQueryDeparseResult result)
{
	VALUE cPgQuery, cParseError;
	VALUE args[4];

	cPgQuery    = rb_const_get(rb_cObject, rb_intern("PgQuery"));
	cParseError = rb_const_get_at(cPgQuery, rb_intern("ParseError"));

	args[0] = rb_str_new2(result.error->message);
	args[1] = rb_str_new2(result.error->filename);
	args[2] = INT2NUM(result.error->lineno);
	args[3] = INT2NUM(result.error->cursorpos);

	pg_query_free_deparse_result(result);

	rb_exc_raise(rb_class_new_instance(4, args, cParseError));
}

void raise_ruby_normalize_error(PgQueryNormalizeResult result)
{
	VALUE cPgQuery, cParseError;
	VALUE args[4];

	cPgQuery    = rb_const_get(rb_cObject, rb_intern("PgQuery"));
	cParseError = rb_const_get_at(cPgQuery, rb_intern("ParseError"));

	args[0] = rb_str_new2(result.error->message);
	args[1] = rb_str_new2(result.error->filename);
	args[2] = INT2NUM(result.error->lineno);
	args[3] = INT2NUM(result.error->cursorpos);

	pg_query_free_normalize_result(result);

	rb_exc_raise(rb_class_new_instance(4, args, cParseError));
}

void raise_ruby_fingerprint_error(PgQueryFingerprintResult result)
{
	VALUE cPgQuery, cParseError;
	VALUE args[4];

	cPgQuery    = rb_const_get(rb_cObject, rb_intern("PgQuery"));
	cParseError = rb_const_get_at(cPgQuery, rb_intern("ParseError"));

	args[0] = rb_str_new2(result.error->message);
	args[1] = rb_str_new2(result.error->filename);
	args[2] = INT2NUM(result.error->lineno);
	args[3] = INT2NUM(result.error->cursorpos);

	pg_query_free_fingerprint_result(result);

	rb_exc_raise(rb_class_new_instance(4, args, cParseError));
}

void raise_ruby_scan_error(PgQueryScanResult result)
{
	VALUE cPgQuery, cScanError;
	VALUE args[4];

	cPgQuery   = rb_const_get(rb_cObject, rb_intern("PgQuery"));
	cScanError = rb_const_get_at(cPgQuery, rb_intern("ScanError"));

	args[0] = rb_str_new2(result.error->message);
	args[1] = rb_str_new2(result.error->filename);
	args[2] = INT2NUM(result.error->lineno);
	args[3] = INT2NUM(result.error->cursorpos);

	pg_query_free_scan_result(result);

	rb_exc_raise(rb_class_new_instance(4, args, cScanError));
}

VALUE pg_query_ruby_parse_protobuf(VALUE self, VALUE input)
{
	Check_Type(input, T_STRING);

	VALUE output;
	PgQueryProtobufParseResult result = pg_query_parse_protobuf(StringValueCStr(input));

	if (result.error) raise_ruby_parse_error(result);

	output = rb_ary_new();

	rb_ary_push(output, rb_str_new(result.parse_tree.data, result.parse_tree.len));
	rb_ary_push(output, rb_str_new2(result.stderr_buffer));

	pg_query_free_protobuf_parse_result(result);

	return output;
}

VALUE pg_query_ruby_deparse_protobuf(VALUE self, VALUE input)
{
	Check_Type(input, T_STRING);

	VALUE output;
	PgQueryProtobuf pbuf = {0};
	PgQueryDeparseResult result = {0};

	pbuf.data = StringValuePtr(input);
	pbuf.len = RSTRING_LEN(input);
	result = pg_query_deparse_protobuf(pbuf);

	if (result.error) raise_ruby_deparse_error(result);

	output = rb_str_new2(result.query);

	pg_query_free_deparse_result(result);

	return output;
}

VALUE pg_query_ruby_normalize(VALUE self, VALUE input)
{
	Check_Type(input, T_STRING);

	VALUE output;
	PgQueryNormalizeResult result = pg_query_normalize(StringValueCStr(input));

	if (result.error) raise_ruby_normalize_error(result);

	output = rb_str_new2(result.normalized_query);

	pg_query_free_normalize_result(result);

	return output;
}

VALUE pg_query_ruby_fingerprint(VALUE self, VALUE input)
{
	Check_Type(input, T_STRING);

	VALUE output;
	PgQueryFingerprintResult result = pg_query_fingerprint(StringValueCStr(input));

	if (result.error) raise_ruby_fingerprint_error(result);

	if (result.fingerprint_str) {
		output = rb_str_new2(result.fingerprint_str);
	} else {
		output = Qnil;
	}

	pg_query_free_fingerprint_result(result);

	return output;
}

VALUE pg_query_ruby_scan(VALUE self, VALUE input)
{
	Check_Type(input, T_STRING);

	VALUE output;
	PgQueryScanResult result = pg_query_scan(StringValueCStr(input));

	if (result.error) raise_ruby_scan_error(result);

	output = rb_ary_new();

	rb_ary_push(output, rb_str_new(result.pbuf.data, result.pbuf.len));
	rb_ary_push(output, rb_str_new2(result.stderr_buffer));

	pg_query_free_scan_result(result);

	return output;
}

VALUE pg_query_ruby_hash_xxh3_64(VALUE self, VALUE input, VALUE seed)
{
	Check_Type(input, T_STRING);
	Check_Type(seed, T_FIXNUM);

#ifdef HAVE_LONG_LONG
	return ULL2NUM(XXH3_64bits_withSeed(StringValuePtr(input), RSTRING_LEN(input), NUM2ULONG(seed)));
#else
	return ULONG2NUM(XXH3_64bits_withSeed(StringValuePtr(input), RSTRING_LEN(input), NUM2ULONG(seed)));
#endif

}

VALUE pg_query_ruby_qualify(VALUE self, VALUE sql_str, VALUE schema_str) {
	Check_Type(sql_str, T_STRING);
	Check_Type(schema_str, T_STRING);

	const char* sql = StringValueCStr(sql_str);
	const char* schema = StringValueCStr(schema_str);

	char* result = pg_query_qualify_sql(sql, schema);

	if (result) {
		VALUE output = rb_str_new_cstr(result);
		rb_enc_associate(output, rb_utf8_encoding());
		free(result);
		return output;
	} else {
		return Qnil;
	}
}

VALUE pg_query_ruby_qualify_with_funcs(VALUE self, VALUE sql_str, VALUE schema_str, VALUE func_names_array) {
	Check_Type(sql_str, T_STRING);
	Check_Type(schema_str, T_STRING);
	Check_Type(func_names_array, T_ARRAY);

	const char* sql = StringValueCStr(sql_str);
	const char* schema = StringValueCStr(schema_str);

	// Convert Ruby array to C array
	int func_count = RARRAY_LEN(func_names_array);
	const char** func_names = NULL;
	char* result = NULL;
	VALUE output = Qnil;

	if (func_count > 0) {
		func_names = malloc(func_count * sizeof(char*));
		if (!func_names) {
			rb_raise(rb_eNoMemError, "Memory allocation failed for function names array");
		}

		// Convert array elements with exception safety
		for (int i = 0; i < func_count; i++) {
			VALUE func_name_val = rb_ary_entry(func_names_array, i);
			// Check_Type can raise exception - need cleanup if it fails
			if (!RB_TYPE_P(func_name_val, T_STRING)) {
				free(func_names);
				rb_raise(rb_eTypeError, "Function name must be a string");
			}
			func_names[i] = StringValueCStr(func_name_val);
		}
	}

	// Call the C function
	result = pg_query_qualify_sql_with_funcs(sql, schema, func_names, func_count);

	// Build output with proper cleanup
	if (result) {
		output = rb_str_new_cstr(result);
		rb_enc_associate(output, rb_utf8_encoding());
		free(result);
	}

	// Always free func_names array
	if (func_names) {
		free(func_names);
	}

	return output;
}

// Raise TypeError if any element of array is not a String. Allocates nothing,
// so it is safe to call before other native allocations (see
// pg_query_ruby_qualify_full, which prevalidates every array argument up front
// so a later TypeError cannot leak an already-malloc'd array).
static void ruby_validate_string_array(VALUE array) {
	int count = RARRAY_LEN(array);
	for (int i = 0; i < count; i++) {
		if (!RB_TYPE_P(rb_ary_entry(array, i), T_STRING)) {
			rb_raise(rb_eTypeError, "Array element must be a string");
		}
	}
}

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

	int exclude_count = 0;
	const char** filter_exclude = NULL;
	const char* column = NULL;
	int value = 0;
	char* result = NULL;
	VALUE output = Qnil;

	// Validate and convert every Ruby argument that can raise BEFORE any
	// malloc, so a TypeError/conversion failure never leaks a native array.
	// filter_column is a String when filtering is requested, nil otherwise.
	if (!NIL_P(filter_column)) {
		Check_Type(filter_column, T_STRING);
		column = StringValueCStr(filter_column);
		value = NUM2INT(filter_value);
	}

	// Type-check both arrays (no allocation) so that a non-string element in
	// either one raises here, before func_names is malloc'd below.
	ruby_validate_string_array(func_names_array);
	if (column) {
		ruby_validate_string_array(filter_exclude_array);
	}

	// Allocation happens only after the last raising validation above. The two
	// native arrays are freed unconditionally at the end of this function.
	int func_count = 0;
	const char** func_names = ruby_string_array_to_c(func_names_array, &func_count);

	if (column) {
		filter_exclude = ruby_string_array_to_c(filter_exclude_array, &exclude_count);
	}

	int unhandled = 0;
	result = pg_query_qualify_sql_full(sql, schema, func_names, func_count, column, value, filter_exclude, exclude_count, &unhandled);

	if (result) {
		output = rb_str_new_cstr(result);
		rb_enc_associate(output, rb_utf8_encoding());
		free(result);
	}

	if (func_names) free(func_names);
	if (filter_exclude) free(filter_exclude);

	// Refusal (unhandled top-level statement) is distinct from a parse/deparse
	// failure (result == NULL, unhandled == 0): raise so the tenant boundary
	// fails closed instead of silently returning unfiltered SQL or nil.
	if (!result && unhandled) {
		VALUE cPgQuery = rb_const_get(rb_cObject, rb_intern("PgQuery"));
		VALUE cUnhandled = rb_const_get_at(cPgQuery, rb_intern("TenantFilterUnhandled"));
		rb_raise(cUnhandled,
		         "qualify_with_filter refused an unsupported top-level statement; "
		         "the filter pass cannot scope it, so it would not be tenant-filtered");
	}

	return output;
}
