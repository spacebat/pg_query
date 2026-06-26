#!/usr/bin/env ruby

# Use the local development version
$LOAD_PATH.unshift(File.expand_path('./lib', __dir__))
require 'pg_query'
require 'optparse'

class MemoryLeakTester
  def initialize(options = {})
    @iterations = options[:iterations] || 10_000
    @schema = options[:schema] || 'public'
    @function_names = options[:function_names] || ['custom_%', 'lz_%', 'encrypt_data']
    @markdown_file = options[:markdown_file]
    @sql_queries = []
    @verbose = options[:verbose] || false
  end

  def run
    puts 'PgQuery Memory Leak Test'
    puts '=' * 40
    puts "Iterations: #{@iterations}"
    puts "Schema: #{@schema}"
    puts "Function names: #{@function_names.inspect}"
    puts "Markdown file: #{@markdown_file}"

    # Show which method will be tested
    if PgQuery.respond_to?(:qualify_with_funcs)
      puts 'Testing method: qualify_with_funcs ✓'
    elsif PgQuery.respond_to?(:qualify)
      puts 'Testing method: qualify'
    else
      puts 'Testing method: parse (fallback)'
    end
    puts

    # Extract SQL queries from markdown
    extract_sql_from_markdown

    if @sql_queries.empty?
      puts 'ERROR: No SQL queries found in markdown file'
      exit 1
    end

    puts "Found #{@sql_queries.length} SQL queries"
    puts

    # Measure initial memory
    initial_memory = measure_memory
    print_memory_stats('Initial', initial_memory)

    # Force garbage collection before starting
    GC.start
    sleep 0.1

    # Run the test loop
    puts "Running #{@iterations} iterations..."
    start_time = Time.now

    @iterations.times do |i|
      # Pick a random SQL query
      sql = @sql_queries.sample

      begin
        # Call qualify_with_funcs (fallback to qualify if not available)
        if PgQuery.respond_to?(:qualify_with_funcs)
          PgQuery.qualify_with_funcs(sql, @schema, @function_names)
          if @verbose && i.zero?
            puts '✓ Using qualify_with_funcs method'
          end
        elsif PgQuery.respond_to?(:qualify)
          PgQuery.qualify(sql, @schema)
          if @verbose && i.zero?
            puts '✓ Using qualify method'
          end
        else
          # Just parse to test memory usage
          PgQuery.parse(sql)
          if @verbose && i.zero?
            puts '⚠️  Using parse method (fallback)'
          end
        end

        if @verbose && i.positive? && (i % 10_000).zero?
          puts "Iteration #{i}: #{sql[0, 50]}..."
        end
      rescue StandardError => _e
        # Silently continue - errors are expected for some malformed SQL
        # Only report if really verbose and it's a new type of error
        next
      end

      # Periodic memory check
      if i.positive? && (i % 10_000).zero?
        current_memory = measure_memory
        puts "Iteration #{i}: RSS=#{current_memory[:rss_mb]}MB, VSZ=#{current_memory[:vsz_mb]}MB, Ruby Heap=#{current_memory[:ruby_heap_mb]}MB"
      end
    end

    end_time = Time.now
    puts "Completed #{@iterations} iterations in #{(end_time - start_time).round(2)} seconds"
    puts

    # Force garbage collection after test
    GC.start
    sleep 0.1

    # Measure final memory
    final_memory = measure_memory
    print_memory_stats('Final', final_memory)

    # Calculate and print differences
    print_memory_diff(initial_memory, final_memory)
  end

  private

  def extract_sql_from_markdown
    unless File.exist?(@markdown_file)
      puts "ERROR: Markdown file #{@markdown_file} not found"
      exit 1
    end

    content = File.read(@markdown_file)
    raw_queries = []

    # Extract SQL code blocks (```sql or ```SQL)
    sql_blocks = content.scan(/```(?:sql|SQL)\n(.*?)\n```/m)

    sql_blocks.each do |block|
      sql = block[0].strip

      next if sql.empty?
      next if sql.start_with?('--') # Skip comments
      next if sql.start_with?('#') # Skip comments
      next if sql.include?('$$') # Skip function bodies with dollar quoting

      raw_queries << sql
    end

    # Also try to extract inline SQL (single backticks with SQL keywords)
    inline_sql = content.scan(/`([^`]*(?:SELECT|INSERT|UPDATE|DELETE)[^`]*)`/i)
    inline_sql.each do |match|
      sql = match[0].strip
      next if sql.length < 15 # Skip very short snippets
      next if sql.include?('(') && !sql.include?(')') # Skip incomplete queries
      raw_queries << sql
    end

    # Use all extracted queries - validation happens during the test loop
    @sql_queries = raw_queries
    puts "Extracted #{@sql_queries.length} SQL queries for testing" if @verbose

    # Add some default test queries if none found
    return unless @sql_queries.empty?
    @sql_queries = [
      'SELECT * FROM users WHERE id = 1',
      'SELECT custom_func(data) FROM logs',
      'INSERT INTO orders (user_id, amount) VALUES (1, 100)',
      'UPDATE users SET last_login = NOW() WHERE id = 1',
      'DELETE FROM sessions WHERE expired_at < NOW()',
      'SELECT lz_compress(data), encrypt_data(secret) FROM sensitive_data',
      "WITH recent_orders AS (SELECT * FROM orders WHERE created_at > NOW() - INTERVAL '1 day') SELECT * FROM recent_orders",
      'CREATE TABLE test_table (id SERIAL PRIMARY KEY, name TEXT)',
      'DROP TABLE IF EXISTS temp_table',
      'SELECT COUNT(*) FROM (SELECT DISTINCT user_id FROM orders) t'
    ]
    puts 'No valid SQL found in markdown, using default test queries'
  end

  def measure_memory
    # Ruby VM memory statistics
    gc_stats = GC.stat
    heap_pages = gc_stats[:heap_allocated_pages] || 0
    page_size = gc_stats[:heap_page_size] || 4096
    ruby_heap_size = heap_pages * page_size
    ruby_heap_mb = (ruby_heap_size / 1024.0 / 1024.0).round(2)

    # OS process memory from /proc/self/status
    proc_status = read_proc_status

    {
      ruby_heap_mb: ruby_heap_mb,
      ruby_heap_pages: gc_stats[:heap_allocated_pages] || 0,
      ruby_objects: gc_stats[:heap_live_slots] || 0,
      rss_kb: proc_status[:rss_kb] || 0,
      rss_mb: ((proc_status[:rss_kb] || 0) / 1024.0).round(2),
      vsz_kb: proc_status[:vsz_kb] || 0,
      vsz_mb: ((proc_status[:vsz_kb] || 0) / 1024.0).round(2)
    }
  end

  def read_proc_status
    status = {}
    return status unless File.exist?('/proc/self/status')

    File.readlines('/proc/self/status').each do |line|
      case line
      when /^VmRSS:\s+(\d+)\s+kB/
        status[:rss_kb] = ::Regexp.last_match(1).to_i
      when /^VmSize:\s+(\d+)\s+kB/
        status[:vsz_kb] = ::Regexp.last_match(1).to_i
      end
    end

    status
  rescue StandardError
    {}
  end

  def print_memory_stats(label, memory)
    puts "#{label} Memory:"
    puts "  Ruby Heap: #{memory[:ruby_heap_mb]} MB (#{memory[:ruby_heap_pages]} pages, #{memory[:ruby_objects]} objects)"
    puts "  Process RSS: #{memory[:rss_mb]} MB"
    puts "  Process VSZ: #{memory[:vsz_mb]} MB"
    puts
  end

  def print_memory_diff(initial, final)
    puts 'Memory Change:'
    puts "  Ruby Heap: #{(final[:ruby_heap_mb] - initial[:ruby_heap_mb]).round(2)} MB"
    puts "  Process RSS: #{(final[:rss_mb] - initial[:rss_mb]).round(2)} MB"
    puts "  Process VSZ: #{(final[:vsz_mb] - initial[:vsz_mb]).round(2)} MB"
    puts

    # Determine if there's a significant leak
    rss_growth = final[:rss_mb] - initial[:rss_mb]
    heap_growth = final[:ruby_heap_mb] - initial[:ruby_heap_mb]

    if rss_growth > 10 # More than 10MB growth
      puts '⚠️  POTENTIAL MEMORY LEAK DETECTED!'
      puts "   RSS grew by #{rss_growth.round(2)} MB over #{@iterations} iterations"
      puts "   That's #{(rss_growth * 1024 / @iterations).round(2)} KB per iteration"
    elsif rss_growth > 2 # More than 2MB growth
      puts "⚠️  Minor memory growth detected (#{rss_growth.round(2)} MB)"
    else
      puts '✅ No significant memory leak detected'
    end

    return unless heap_growth > 5 # More than 5MB Ruby heap growth
    puts "⚠️  Ruby heap grew significantly: #{heap_growth.round(2)} MB"
  end
end

# Parse command line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [options] markdown_file"

  opts.on('-n', '--iterations N', Integer, 'Number of iterations (default: 100000)') do |n|
    options[:iterations] = n
  end

  opts.on('-s', '--schema SCHEMA', String, 'Schema name (default: public)') do |schema|
    options[:schema] = schema
  end

  opts.on('-f', '--functions FUNCS', Array, 'Function name patterns (default: custom_%,lz_%,encrypt_data)') do |funcs|
    options[:function_names] = funcs
  end

  opts.on('-v', '--verbose', 'Verbose output') do
    options[:verbose] = true
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit
  end
end.parse!

options[:markdown_file] = ARGV[0] || "#{__dir__}/test_sql_queries.md"

unless options[:markdown_file]
  puts 'ERROR: Please specify a markdown file'
  puts "Usage: #{$PROGRAM_NAME} [options] [markdown_file]"
  exit 1
end

# Run the test
tester = MemoryLeakTester.new(options)
tester.run
