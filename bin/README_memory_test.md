# Memory Leak Testing Script

This script tests the pg_query library for memory leaks by running thousands of qualify operations on SQL queries extracted from markdown files.

## Usage

```bash
./memory_leak_test.rb [options] markdown_file
```

### Options

- `-n, --iterations N`: Number of iterations (default: 10,000)
- `-s, --schema SCHEMA`: Schema name for qualification (default: public)  
- `-f, --functions FUNCS`: Function name patterns to qualify (default: custom_%,lz_%,encrypt_data)
- `-v, --verbose`: Verbose output showing progress
- `-h, --help`: Show help

### Examples

Basic test with 1000 iterations:
```bash
./memory_leak_test.rb --iterations 1000 test_sql_queries.md
```

Full test with 10,000 iterations (default):
```bash
./memory_leak_test.rb test_sql_queries.md
```

Verbose test with custom schema:
```bash
./memory_leak_test.rb --verbose --schema myschema --iterations 5000 test_sql_queries.md
```

Custom function patterns:
```bash
./memory_leak_test.rb --functions "encrypt_%,compress_%,hash_%" test_sql_queries.md
```

## What It Tests

The script:

1. **Extracts SQL queries** from markdown code blocks (```sql) and inline SQL
2. **Randomly selects queries** to call qualify functions on
3. **Measures memory usage** before and after:
   - Ruby VM heap memory
   - Process RSS (Resident Set Size) 
   - Process VSZ (Virtual Size)
4. **Reports memory growth** and flags potential leaks

## Memory Leak Detection

The script considers a memory leak to be present if:

- **RSS grows by >10MB**: Major leak detected
- **RSS grows by >2MB**: Minor memory growth  
- **Ruby heap grows by >5MB**: Significant Ruby memory growth

## Markdown Format

The script looks for SQL in two formats:

### Code blocks:
```sql
SELECT * FROM users WHERE id = 1
```

### Inline SQL:
Text with `SELECT * FROM users` or other SQL keywords.

## Output

Example output:
```
PgQuery Memory Leak Test
========================================
Iterations: 10000
Schema: public
Function names: ["custom_%", "lz_%", "encrypt_data"]
Markdown file: test_sql_queries.md

Found 38 SQL queries

Initial Memory:
  Ruby Heap: 0.21 MB (55 pages, 31204 objects)
  Process RSS: 19.49 MB
  Process VSZ: 463.96 MB

Running 10000 iterations...
Iteration 1000: RSS=19.8MB, VSZ=464.1MB, Ruby Heap=0.22MB
Iteration 2000: RSS=20.1MB, VSZ=464.3MB, Ruby Heap=0.23MB
...
Completed 10000 iterations in 0.85 seconds

Final Memory:
  Ruby Heap: 0.25 MB (62 pages, 29876 objects)
  Process RSS: 22.3 MB
  Process VSZ: 465.2 MB

Memory Change:
  Ruby Heap: 0.04 MB
  Process RSS: 2.81 MB
  Process VSZ: 1.24 MB

✅ No significant memory leak detected
```

## Files

- `memory_leak_test.rb`: Main testing script
- `test_sql_queries.md`: Sample SQL queries for testing
- `README_memory_test.md`: This documentation

## Requirements

- Ruby with pg_query gem installed
- Linux system (for /proc/self/status memory reading)
- Markdown file with SQL queries to test
