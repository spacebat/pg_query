module PgQuery
  # Qualify unqualified table names with +schema+, and optionally inject a
  # row-restricting filter (e.g. sbid = 42) into every WHERE and outer-join
  # ON clause so that every table is scoped to a single value.
  #
  # filter_column / filter_value: when BOTH are given, inject
  #   "<column> = <value>" per table (qualified to each table's alias/name).
  #   Filter injection is skipped entirely unless both a column and a value are
  #   present, so a nil filter_value (e.g. no current tenant) produces a plainly
  #   qualified query with no row restriction.
  # filter_exclude: table names (relname) to skip; entries ending in % are
  #   treated as prefix matches (e.g. "lookup_%").
  # func_names: function names to schema-qualify (same as qualify_with_funcs).
  #
  # Returns the rewritten SQL, or nil on parse/deparse failure.
  def self.qualify_with_filter(sql, schema, filter_column: nil, filter_value: nil,
                               filter_exclude: [], func_names: [])
    # A nil filter_value means "no value to scope to" — skip the filter walk by
    # passing a nil column, which the native layer treats as no filtering.
    filter_column = nil if filter_value.nil?

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
