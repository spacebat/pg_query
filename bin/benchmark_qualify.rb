#!/usr/bin/env ruby

require 'bundler/setup'
require 'benchmark/ips'
require_relative '../lib/pg_query'

# Small query (~300 bytes) - no qualification needed (already qualified)
SMALL_NO_QUALIFY = <<~SQL.strip
  WITH user_stats AS (
    SELECT user_id, COUNT(*) as order_count 
    FROM public.orders 
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
    SELECT user_id, COUNT(*) as order_count 
    FROM orders 
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
    SELECT 
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
    
    UNION ALL
    
    -- Recursive case: direct reports
    SELECT 
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
    SELECT 
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
    SELECT 
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
  SELECT 
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
  GROUP BY 
    ds.department_id, ds.department_name, ds.employee_count, 
    ds.avg_salary, ds.total_salary, ds.max_hierarchy_level, 
    ds.budget
  HAVING COUNT(rp.project_id) >= 1 OR ds.total_salary < ds.budget * 0.8
  ORDER BY ds.total_salary DESC, ds.employee_count DESC
  LIMIT 50
SQL

# Large query (~3000 bytes) - needs qualification
LARGE_WITH_QUALIFY = <<~SQL.strip
  WITH RECURSIVE organization_hierarchy AS (
    -- Base case: top-level managers
    SELECT 
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
    
    UNION ALL
    
    -- Recursive case: direct reports
    SELECT 
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
    SELECT 
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
    SELECT 
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
  SELECT 
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
  GROUP BY 
    ds.department_id, ds.department_name, ds.employee_count, 
    ds.avg_salary, ds.total_salary, ds.max_hierarchy_level, 
    ds.budget
  HAVING COUNT(rp.project_id) >= 1 OR ds.total_salary < ds.budget * 0.8
  ORDER BY ds.total_salary DESC, ds.employee_count DESC
  LIMIT 50
SQL

# Sample function names for qualify_with_funcs testing
FUNCTION_NAMES = ['now', 'count', 'sum', 'avg', 'max', 'min', 'string_agg'].freeze

puts "pg_query Qualify Performance Benchmark"
puts "=" * 50
puts "Ruby version: #{RUBY_VERSION}"
puts "pg_query version: #{PgQuery::VERSION}"
puts ""

# Display query sizes
puts "Query sizes:"
puts "Small no-qualify: #{SMALL_NO_QUALIFY.bytesize} bytes"
puts "Small with-qualify: #{SMALL_WITH_QUALIFY.bytesize} bytes"
puts "Large no-qualify: #{LARGE_NO_QUALIFY.bytesize} bytes"
puts "Large with-qualify: #{LARGE_WITH_QUALIFY.bytesize} bytes"
puts ""

# Warmup
puts "Warming up..."
3.times do
  PgQuery.qualify(SMALL_NO_QUALIFY, 'public')
  PgQuery.qualify(SMALL_WITH_QUALIFY, 'public')
  PgQuery.qualify(LARGE_NO_QUALIFY, 'public')
  PgQuery.qualify(LARGE_WITH_QUALIFY, 'public')
end
puts ""

Benchmark.ips do |x|
  x.config(time: 10, warmup: 3)
  
  # Small queries - qualify
  x.report("Small/No-qualify/qualify") do
    PgQuery.qualify(SMALL_NO_QUALIFY, 'public')
  end
  
  x.report("Small/With-qualify/qualify") do
    PgQuery.qualify(SMALL_WITH_QUALIFY, 'public')
  end
  
  # Small queries - qualify_with_funcs
  x.report("Small/No-qualify/qualify_with_funcs") do
    PgQuery.qualify_with_funcs(SMALL_NO_QUALIFY, 'public', FUNCTION_NAMES)
  end
  
  x.report("Small/With-qualify/qualify_with_funcs") do
    PgQuery.qualify_with_funcs(SMALL_WITH_QUALIFY, 'public', FUNCTION_NAMES)
  end
  
  # Large queries - qualify
  x.report("Large/No-qualify/qualify") do
    PgQuery.qualify(LARGE_NO_QUALIFY, 'public')
  end
  
  x.report("Large/With-qualify/qualify") do
    PgQuery.qualify(LARGE_WITH_QUALIFY, 'public')
  end
  
  # Large queries - qualify_with_funcs
  x.report("Large/No-qualify/qualify_with_funcs") do
    PgQuery.qualify_with_funcs(LARGE_NO_QUALIFY, 'public', FUNCTION_NAMES)
  end
  
  x.report("Large/With-qualify/qualify_with_funcs") do
    PgQuery.qualify_with_funcs(LARGE_WITH_QUALIFY, 'public', FUNCTION_NAMES)
  end
  
  x.compare!
end

puts ""
puts "Benchmark complete!"
puts ""

# Show sample outputs to verify correctness
puts "Sample outputs (first 200 chars):"
puts ""
puts "Small with-qualify result:"
result = PgQuery.qualify(SMALL_WITH_QUALIFY, 'public')
puts result[0..200] + "..."
puts ""

puts "Large with-qualify result:"
result = PgQuery.qualify(LARGE_WITH_QUALIFY, 'public')
puts result[0..200] + "..."
