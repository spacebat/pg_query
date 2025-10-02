# Test SQL Queries for Memory Leak Testing

This file contains various SQL queries to test the qualify_with_funcs function.

## Basic Queries

```sql
SELECT * FROM users WHERE id = 1
```

```sql
INSERT INTO orders (user_id, amount, created_at) VALUES (1, 100.50, NOW())
```

```sql
UPDATE users SET last_login = NOW() WHERE id = 1
```

## Function Calls

```sql
SELECT custom_func(data), lz_compress(content) FROM logs WHERE date > '2024-01-01'
```

```sql
SELECT encrypt_data(password), custom_hash(email) FROM user_credentials
```

```sql
INSERT INTO processed_data (result) SELECT lz_decompress(compressed_data) FROM raw_data
```

## Complex Queries with CTEs

```sql
WITH recent_orders AS (
  SELECT user_id, SUM(amount) as total
  FROM orders 
  WHERE created_at > NOW() - INTERVAL '30 days'
  GROUP BY user_id
),
top_customers AS (
  SELECT * FROM recent_orders WHERE total > 1000
)
SELECT u.name, tc.total, custom_rank(tc.total) as rank
FROM users u
JOIN top_customers tc ON u.id = tc.user_id
ORDER BY tc.total DESC
```

## Nested Subqueries

```sql
SELECT 
  custom_score(
    (SELECT AVG(rating) FROM reviews WHERE product_id = p.id)
  ) as score
FROM products p 
WHERE p.category IN (
  SELECT category FROM trending_categories 
  WHERE month = EXTRACT(MONTH FROM NOW())
)
```

## Function Bodies (for CREATE FUNCTION statements)

```sql
CREATE OR REPLACE FUNCTION calculate_tax(amount DECIMAL)
RETURNS DECIMAL AS $$
BEGIN
  RETURN amount * 0.08;
END;
$$ LANGUAGE plpgsql
```

```sql
CREATE FUNCTION process_order_data(order_data TEXT)
RETURNS TABLE(order_id INT, processed_data TEXT) AS $$
  SELECT id, lz_compress(data) FROM orders WHERE raw_data = order_data
$$ LANGUAGE sql
```

## DDL Statements

```sql
CREATE TABLE user_analytics (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id),
  analytics_data JSONB,
  processed_at TIMESTAMP DEFAULT NOW()
)
```

```sql
CREATE INDEX idx_analytics_user ON user_analytics USING btree (user_id)
```

## Trigger Functions

```sql
CREATE TRIGGER update_timestamp 
BEFORE UPDATE ON users 
FOR EACH ROW 
EXECUTE FUNCTION update_ts()
```

## Multiple Statement Queries

```sql
DELETE FROM temp_calculations;
INSERT INTO temp_calculations 
SELECT id, custom_calculation(value) 
FROM source_data 
WHERE status = 'pending'
```

## Window Functions

```sql
SELECT 
  user_id,
  order_amount,
  custom_rank() OVER (PARTITION BY user_id ORDER BY order_amount DESC) as rank,
  lz_compress(order_details) as compressed_details
FROM orders
WHERE created_at > '2024-01-01'
```

## Recursive CTEs

```sql
WITH RECURSIVE category_tree AS (
  SELECT id, name, parent_id, 0 as level
  FROM categories 
  WHERE parent_id IS NULL
  
  UNION ALL
  
  SELECT c.id, c.name, c.parent_id, ct.level + 1
  FROM categories c
  JOIN category_tree ct ON c.parent_id = ct.id
)
SELECT custom_path(name, level) FROM category_tree
```

## VACUUM and ANALYZE

```sql
VACUUM ANALYZE users
```

```sql
CLUSTER users USING users_pkey
```

## Miscellaneous

Some inline SQL: `SELECT COUNT(*) FROM active_users` and `UPDATE stats SET last_updated = NOW()`.

More complex inline: `SELECT custom_func(data) FROM logs WHERE created_at > NOW() - INTERVAL '1 hour'`.
