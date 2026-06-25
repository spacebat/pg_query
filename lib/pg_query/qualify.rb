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
  #
  # strict: (default true) is the fail-closed control for shared-schema tenant
  #   enforcement.
  #   - strict: true (default): a filter_column with a nil filter_value raises
  #     PgQuery::NilTenant (filtering requested with no tenant to scope to), and
  #     any top-level statement or INSERT ... VALUES shape the filter pass cannot
  #     scope is refused with PgQuery::TenantFilterUnhandled rather than returned
  #     unfiltered. Allowed roots are SELECT/INSERT/UPDATE/DELETE and the
  #     wrappers that only recurse into them (CREATE TABLE AS, CREATE VIEW,
  #     EXPLAIN); everything else (e.g. MERGE, COPY (SELECT ...) TO,
  #     DECLARE ... CURSOR) is refused, as is a multi-statement string in which
  #     any statement is unhandled.
  #   - strict: false: explicit admin/bypass mode. A nil filter_value means
  #     qualify only (no row restriction), and statements/INSERT shapes that
  #     would otherwise be refused are qualified without a filter instead.
  #   NilTenant subclasses TenantFilterUnhandled, so rescuing the base class
  #   catches both the nil-tenant and unsupported-statement cases.
  #
  # Plain qualification (PgQuery.qualify / qualify_with_funcs) is unaffected.
  def self.qualify_with_filter(sql, schema, filter_column: nil, filter_value: nil,
                               filter_exclude: [], func_names: [], strict: true)
    # Nil-tenant policy. A nil filter_value means "no value to scope to".
    #   strict (default): fail closed — requesting a filter with no tenant is an
    #     error, so raise NilTenant rather than silently producing unscoped SQL.
    #   strict: false: explicit bypass — skip the filter walk and qualify only.
    if !filter_column.nil? && filter_value.nil?
      if strict
        raise NilTenant, 'qualify_with_filter was given a filter_column but a nil ' \
                         'filter_value; pass strict: false to qualify without filtering'
      end

      filter_column = nil
    end

    # strict controls C-layer refusal of statements/INSERT shapes the filter
    # pass cannot scope. strict: true refuses (TenantFilterUnhandled); strict:
    # false qualifies them without refusing.
    qualify_full(
      sql,
      schema,
      func_names,
      filter_column,
      filter_value || 0,
      filter_exclude,
      strict
    )
  end
end
