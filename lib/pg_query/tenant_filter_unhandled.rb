module PgQuery
  # Raised by +qualify_with_filter+ when filtering is requested but a top-level
  # statement is outside the strict allowlist the filter pass can scope (e.g.
  # MERGE, COPY (SELECT ...) TO, DECLARE ... CURSOR). The call is refused rather
  # than returning SQL that would not be tenant-filtered, so the tenant-isolation
  # boundary fails closed. This is distinct from +nil+, which still signals a
  # parse/deparse failure.
  class TenantFilterUnhandled < StandardError
  end
end
