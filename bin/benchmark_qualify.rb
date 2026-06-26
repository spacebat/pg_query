#!/usr/bin/env ruby

require 'bundler/setup'
require 'benchmark/ips'
require_relative '../lib/pg_query'

# Small query (~300 bytes) - no qualification needed (already qualified)
SMALL_NO_QUALIFY = <<~SQL.strip
  WITH user_stats AS (
    SELECT user_id, COUNT(*) as order_count#{' '}
    FROM public.orders#{' '}
    WHERE created_at > '2024-01-01'
    GROUP BY user_id
  )
  SELECT u.name, us.order_count, u.email
  FROM public.users u
  JOIN user_stats us ON u.id = us.user_id
  WHERE us.order_count > 5
  ORDER BY us.order_count DESC
SQL

# Small query (~300 bytes) - needs qualification
SMALL_WITH_QUALIFY = <<~SQL.strip
  WITH user_stats AS (
    SELECT user_id, COUNT(*) as order_count#{' '}
    FROM orders#{' '}
    WHERE created_at > '2024-01-01'
    GROUP BY user_id
  )
  SELECT u.name, us.order_count, u.email
  FROM users u
  JOIN user_stats us ON u.id = us.user_id
  WHERE us.order_count > 5
  ORDER BY us.order_count DESC
SQL

# Large query (~3000 bytes) - no qualification needed
LARGE_NO_QUALIFY = <<~SQL.strip
  WITH RECURSIVE organization_hierarchy AS (
    -- Base case: top-level managers
    SELECT#{' '}
      emp.employee_id,
      emp.manager_id,
      emp.name,
      emp.department_id,
      emp.salary,
      emp.hire_date,
      1 as level,
      ARRAY[emp.employee_id] as path
    FROM public.employees emp
    WHERE emp.manager_id IS NULL
  #{'  '}
    UNION ALL
  #{'  '}
    -- Recursive case: direct reports
    SELECT#{' '}
      e.employee_id,
      e.manager_id,
      e.name,
      e.department_id,
      e.salary,
      e.hire_date,
      oh.level + 1,
      oh.path || e.employee_id
    FROM public.employees e
    JOIN organization_hierarchy oh ON e.manager_id = oh.employee_id
    WHERE e.employee_id != ALL(oh.path)  -- Prevent cycles
  ),
  department_stats AS (
    SELECT#{' '}
      d.department_id,
      d.department_name,
      d.budget,
      COUNT(oh.employee_id) as employee_count,
      AVG(oh.salary) as avg_salary,
      SUM(oh.salary) as total_salary,
      MAX(oh.level) as max_hierarchy_level
    FROM public.departments d
    LEFT JOIN organization_hierarchy oh ON d.department_id = oh.department_id
    GROUP BY d.department_id, d.department_name, d.budget
  ),
  recent_projects AS (
    SELECT#{' '}
      p.project_id,
      p.project_name,
      p.start_date,
      p.end_date,
      p.budget,
      p.department_id,
      STRING_AGG(DISTINCT e.name, ', ' ORDER BY e.name) as team_members,
      COUNT(DISTINCT e.employee_id) as team_size
    FROM public.projects p
    LEFT JOIN public.project_assignments pa ON p.project_id = pa.project_id
    LEFT JOIN public.employees e ON pa.employee_id = e.employee_id
    WHERE p.start_date >= '2023-01-01'
    GROUP BY p.project_id, p.project_name, p.start_date, p.end_date, p.budget, p.department_id
  )
  SELECT#{' '}
    ds.department_name,
    ds.employee_count,
    ds.avg_salary,
    ds.total_salary,
    ds.max_hierarchy_level,
    ds.budget,
    ds.budget - ds.total_salary as budget_remaining,
    COUNT(rp.project_id) as active_projects,
    SUM(rp.budget) as project_budgets,
    AVG(rp.team_size) as avg_team_size,
    STRING_AGG(rp.project_name, '; ' ORDER BY rp.start_date DESC) as recent_project_names
  FROM department_stats ds
  LEFT JOIN recent_projects rp ON ds.department_id = rp.department_id
  WHERE ds.employee_count > 0
  GROUP BY#{' '}
    ds.department_id, ds.department_name, ds.employee_count,#{' '}
    ds.avg_salary, ds.total_salary, ds.max_hierarchy_level,#{' '}
    ds.budget
  HAVING COUNT(rp.project_id) >= 1 OR ds.total_salary < ds.budget * 0.8
  ORDER BY ds.total_salary DESC, ds.employee_count DESC
  LIMIT 50
SQL

# Large query (~3000 bytes) - needs qualification
LARGE_WITH_QUALIFY = <<~SQL.strip
  WITH RECURSIVE organization_hierarchy AS (
    -- Base case: top-level managers
    SELECT#{' '}
      emp.employee_id,
      emp.manager_id,
      emp.name,
      emp.department_id,
      emp.salary,
      emp.hire_date,
      1 as level,
      ARRAY[emp.employee_id] as path
    FROM employees emp
    WHERE emp.manager_id IS NULL
  #{'  '}
    UNION ALL
  #{'  '}
    -- Recursive case: direct reports
    SELECT#{' '}
      e.employee_id,
      e.manager_id,
      e.name,
      e.department_id,
      e.salary,
      e.hire_date,
      oh.level + 1,
      oh.path || e.employee_id
    FROM employees e
    JOIN organization_hierarchy oh ON e.manager_id = oh.employee_id
    WHERE e.employee_id != ALL(oh.path)  -- Prevent cycles
  ),
  department_stats AS (
    SELECT#{' '}
      d.department_id,
      d.department_name,
      d.budget,
      COUNT(oh.employee_id) as employee_count,
      AVG(oh.salary) as avg_salary,
      SUM(oh.salary) as total_salary,
      MAX(oh.level) as max_hierarchy_level
    FROM departments d
    LEFT JOIN organization_hierarchy oh ON d.department_id = oh.department_id
    GROUP BY d.department_id, d.department_name, d.budget
  ),
  recent_projects AS (
    SELECT#{' '}
      p.project_id,
      p.project_name,
      p.start_date,
      p.end_date,
      p.budget,
      p.department_id,
      STRING_AGG(DISTINCT e.name, ', ' ORDER BY e.name) as team_members,
      COUNT(DISTINCT e.employee_id) as team_size
    FROM projects p
    LEFT JOIN project_assignments pa ON p.project_id = pa.project_id
    LEFT JOIN employees e ON pa.employee_id = e.employee_id
    WHERE p.start_date >= '2023-01-01'
    GROUP BY p.project_id, p.project_name, p.start_date, p.end_date, p.budget, p.department_id
  )
  SELECT#{' '}
    ds.department_name,
    ds.employee_count,
    ds.avg_salary,
    ds.total_salary,
    ds.max_hierarchy_level,
    ds.budget,
    ds.budget - ds.total_salary as budget_remaining,
    COUNT(rp.project_id) as active_projects,
    SUM(rp.budget) as project_budgets,
    AVG(rp.team_size) as avg_team_size,
    STRING_AGG(rp.project_name, '; ' ORDER BY rp.start_date DESC) as recent_project_names
  FROM department_stats ds
  LEFT JOIN recent_projects rp ON ds.department_id = rp.department_id
  WHERE ds.employee_count > 0
  GROUP BY#{' '}
    ds.department_id, ds.department_name, ds.employee_count,#{' '}
    ds.avg_salary, ds.total_salary, ds.max_hierarchy_level,#{' '}
    ds.budget
  HAVING COUNT(rp.project_id) >= 1 OR ds.total_salary < ds.budget * 0.8
  ORDER BY ds.total_salary DESC, ds.employee_count DESC
  LIMIT 50
SQL

# Sample function names for qualify_with_funcs testing
FUNCTION_NAMES = %w[now count sum avg max min string_agg].freeze

# Filter arguments for qualify_with_filter, so we can measure the cost the
# tenant-filter pass adds on top of plain qualification.
FILTER_COLUMN = 'sbid'.freeze
FILTER_VALUE = 42

# Filter-specific fixtures: each exercises a distinct tenant-filter rewrite path
# so the benchmark reflects the real cost spread, not just the cheapest case.
# The SMALL_/LARGE_WITH_QUALIFY queries above only hit simple WHERE-injection;
# these hit the paths that build extra AST.
#
# Baseline: plain WHERE-clause predicate injection (cheapest path).
FILTER_SIMPLE_WHERE = 'SELECT * FROM users u JOIN orders o ON u.id = o.user_id WHERE o.total > 100'.freeze
# Outer USING join: the nullable side is rewritten into a filtered derived table
# (SELECT * FROM orders WHERE ...) -- the most AST-heavy rewrite.
FILTER_USING_WRAP = 'SELECT * FROM users u LEFT JOIN orders o USING (id)'.freeze
# NATURAL outer join: same derived-table wrapping path.
FILTER_NATURAL_WRAP = 'SELECT * FROM users u NATURAL LEFT JOIN orders o'.freeze
# RETURNING subquery: filter pass must descend into the RETURNING expression.
FILTER_RETURNING = 'UPDATE users SET active = true RETURNING id, (SELECT count(*) FROM orders WHERE orders.user_id = users.id)'.freeze
# INSERT ... VALUES: write-payload injection (append column + value per tuple).
FILTER_INSERT_VALUES = "INSERT INTO shifts (employee_id, start_date, end_date) VALUES (1, '2026-01-01', '2026-01-02'), (2, '2026-01-03', '2026-01-04'), (3, '2026-01-05', '2026-01-06')".freeze

# All single-path filter fixtures, for warmup and reporting.
FILTER_FIXTURES = {
  'SimpleWhere' => FILTER_SIMPLE_WHERE,
  'UsingWrap' => FILTER_USING_WRAP,
  'NaturalWrap' => FILTER_NATURAL_WRAP,
  'Returning' => FILTER_RETURNING,
  'InsertValues' => FILTER_INSERT_VALUES
}.freeze

# Large (~1.3 KB) query that hits MANY transform sites in one statement: two CTE
# bodies, several outer joins (including USING/NATURAL derived-table wrapping and
# a nullable join-subtree), correlated subqueries, and IN-subqueries. This is the
# filter analogue of LARGE_WITH_QUALIFY, so we can compare qualify vs
# qualify_with_filter at scale when there is a lot to rewrite, not just one
# transform on a tiny query.
LARGE_FILTER_HEAVY = <<~SQL.strip
  WITH active_emps AS (
    SELECT e.employee_id, e.name, e.department_id, e.manager_id
    FROM employees e
    LEFT JOIN terminations t USING (employee_id)
    WHERE t.employee_id IS NULL
  ),
  dept_rollup AS (
    SELECT d.department_id, d.department_name,
           (SELECT count(*) FROM projects p WHERE p.department_id = d.department_id) AS project_count,
           (SELECT avg(s.amount) FROM salaries s WHERE s.department_id = d.department_id) AS avg_salary
    FROM departments d
    NATURAL LEFT JOIN budgets b
    WHERE d.active = true
  )
  SELECT ae.name, dr.department_name, dr.project_count, dr.avg_salary, sched.shift_count,
         coalesce((SELECT sum(h.hours) FROM hours h WHERE h.employee_id = ae.employee_id), 0) AS total_hours
  FROM active_emps ae
  JOIN dept_rollup dr ON ae.department_id = dr.department_id
  LEFT JOIN managers m ON ae.manager_id = m.manager_id
  RIGHT JOIN locations loc USING (location_id)
  LEFT JOIN schedules sched ON ae.employee_id = sched.employee_id
  FULL JOIN audit_log al USING (employee_id)
  WHERE ae.employee_id IN (SELECT a.employee_id FROM assignments a WHERE a.active = true)
    AND ae.department_id IN (SELECT pa.department_id FROM project_assignments pa WHERE pa.role = 'lead')
  ORDER BY dr.avg_salary DESC
  LIMIT 100
SQL

def qualify_filtered(sql)
  PgQuery.qualify_with_filter(sql, 'public', filter_column: FILTER_COLUMN, filter_value: FILTER_VALUE)
end

puts 'pg_query Qualify Performance Benchmark'
puts '=' * 50
puts "Ruby version: #{RUBY_VERSION}"
puts "pg_query version: #{PgQuery::VERSION}"
puts ''

# Display query sizes
puts 'Query sizes:'
puts "Small no-qualify: #{SMALL_NO_QUALIFY.bytesize} bytes"
puts "Small with-qualify: #{SMALL_WITH_QUALIFY.bytesize} bytes"
puts "Large no-qualify: #{LARGE_NO_QUALIFY.bytesize} bytes"
puts "Large with-qualify: #{LARGE_WITH_QUALIFY.bytesize} bytes"
puts "Large filter-heavy: #{LARGE_FILTER_HEAVY.bytesize} bytes"
puts ''

# Warmup
puts 'Warming up...'
3.times do
  PgQuery.qualify(SMALL_NO_QUALIFY, 'public')
  PgQuery.qualify(SMALL_WITH_QUALIFY, 'public')
  PgQuery.qualify(LARGE_NO_QUALIFY, 'public')
  PgQuery.qualify(LARGE_WITH_QUALIFY, 'public')
  PgQuery.qualify_with_filter(SMALL_WITH_QUALIFY, 'public',
                              filter_column: FILTER_COLUMN, filter_value: FILTER_VALUE)
  PgQuery.qualify_with_filter(LARGE_WITH_QUALIFY, 'public',
                              filter_column: FILTER_COLUMN, filter_value: FILTER_VALUE)
  FILTER_FIXTURES.each_value { |sql| qualify_filtered(sql) }
  PgQuery.qualify(LARGE_FILTER_HEAVY, 'public')
  qualify_filtered(LARGE_FILTER_HEAVY)
end
puts ''

Benchmark.ips do |x|
  x.config(time: 10, warmup: 3)

  # Small queries - qualify
  x.report('Small/No-qualify/qualify') do
    PgQuery.qualify(SMALL_NO_QUALIFY, 'public')
  end

  x.report('Small/With-qualify/qualify') do
    PgQuery.qualify(SMALL_WITH_QUALIFY, 'public')
  end

  # Small queries - qualify_with_funcs
  x.report('Small/No-qualify/qualify_with_funcs') do
    PgQuery.qualify_with_funcs(SMALL_NO_QUALIFY, 'public', FUNCTION_NAMES)
  end

  x.report('Small/With-qualify/qualify_with_funcs') do
    PgQuery.qualify_with_funcs(SMALL_WITH_QUALIFY, 'public', FUNCTION_NAMES)
  end

  # Large queries - qualify
  x.report('Large/No-qualify/qualify') do
    PgQuery.qualify(LARGE_NO_QUALIFY, 'public')
  end

  x.report('Large/With-qualify/qualify') do
    PgQuery.qualify(LARGE_WITH_QUALIFY, 'public')
  end

  # Large queries - qualify_with_funcs
  x.report('Large/No-qualify/qualify_with_funcs') do
    PgQuery.qualify_with_funcs(LARGE_NO_QUALIFY, 'public', FUNCTION_NAMES)
  end

  x.report('Large/With-qualify/qualify_with_funcs') do
    PgQuery.qualify_with_funcs(LARGE_WITH_QUALIFY, 'public', FUNCTION_NAMES)
  end

  # qualify_with_filter: the tenant-filter pass on top of qualification. Paired
  # with the matching qualify reports above so the filter overhead is visible.
  x.report('Small/With-qualify/qualify_with_filter') do
    PgQuery.qualify_with_filter(SMALL_WITH_QUALIFY, 'public',
                                filter_column: FILTER_COLUMN, filter_value: FILTER_VALUE)
  end

  x.report('Large/With-qualify/qualify_with_filter') do
    PgQuery.qualify_with_filter(LARGE_WITH_QUALIFY, 'public',
                                filter_column: FILTER_COLUMN, filter_value: FILTER_VALUE)
  end

  # Per-rewrite-path filter fixtures, so the cost of the heavier rewrites
  # (derived-table wrapping, RETURNING descent, write-payload injection) is
  # visible rather than averaged into a single simple-WHERE number.
  FILTER_FIXTURES.each do |name, sql|
    x.report("Filter/#{name}/qualify_with_filter") do
      qualify_filtered(sql)
    end
  end

  # Large, transform-heavy query: qualify vs qualify_with_filter at scale, so the
  # filter overhead is measured when there is a lot to rewrite in one statement
  # (parity with the Large/With-qualify pair above, which only hits simple WHERE).
  x.report('LargeFilterHeavy/qualify') do
    PgQuery.qualify(LARGE_FILTER_HEAVY, 'public')
  end

  x.report('LargeFilterHeavy/qualify_with_filter') do
    qualify_filtered(LARGE_FILTER_HEAVY)
  end

  x.compare!
end

puts ''
puts 'Benchmark complete!'
puts ''

# Show sample outputs to verify correctness
puts 'Sample outputs (first 200 chars):'
puts ''
puts 'Small with-qualify result:'
result = PgQuery.qualify(SMALL_WITH_QUALIFY, 'public')
puts result[0..200] + '...'
puts ''

puts 'Large with-qualify result:'
result = PgQuery.qualify(LARGE_WITH_QUALIFY, 'public')
puts result[0..200] + '...'
puts ''

puts 'Filter rewrite-path results:'
FILTER_FIXTURES.each do |name, sql|
  puts "  #{name}: #{qualify_filtered(sql)}"
end
puts ''

puts 'Large filter-heavy result (first 300 chars):'
puts qualify_filtered(LARGE_FILTER_HEAVY)[0..300] + '...'
