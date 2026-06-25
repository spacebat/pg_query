module PgQuery
  # Raised by +qualify_with_filter+ when filtering is requested but a top-level
  # statement is outside the strict allowlist the filter pass can scope (e.g.
  # MERGE, COPY (SELECT ...) TO, DECLARE ... CURSOR). The call is refused rather
  # than returning SQL that would not be tenant-filtered, so the tenant-isolation
  # boundary fails closed. This is distinct from +nil+, which still signals a
  # parse/deparse failure.
  class TenantFilterUnhandled < StandardError
  end

  # Raised by +qualify_with_filter+ in strict mode (the default) when a
  # +filter_column+ is given but +filter_value+ is +nil+ -- i.e. filtering was
  # requested with no tenant to scope to. Subclasses TenantFilterUnhandled so a
  # caller can rescue the base class to fail closed on both "no tenant" and
  # "unsupported statement", or rescue NilTenant specifically. Pass
  # +strict: false+ to instead qualify without filtering when the tenant is nil.
  class NilTenant < TenantFilterUnhandled
  end
end
