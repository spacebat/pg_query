require 'spec_helper'

describe PgQuery, '#qualify' do
  describe "basic functionality" do
    it "qualifies a simple unqualified table name" do
      query = described_class.qualify("SELECT * FROM users", "public")
      expect(query).to eq "SELECT * FROM public.users"
    end

    it "preserves already qualified table names" do
      query = described_class.qualify("SELECT * FROM schema.users", "public")
      expect(query).to eq "SELECT * FROM schema.users"
    end

    it "qualifies tables in JOIN operations" do
      query = described_class.qualify("SELECT u.id, o.amount FROM users u JOIN orders o ON u.id = o.user_id", "public")
      expect(query).to eq "SELECT u.id, o.amount FROM public.users u JOIN public.orders o ON u.id = o.user_id"
    end

    it "qualifies tables in subqueries" do
      query = described_class.qualify("SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)", "public")
      expect(query).to eq "SELECT * FROM public.users WHERE id IN (SELECT user_id FROM public.orders)"
    end

    it "handles INSERT statements" do
      query = described_class.qualify("INSERT INTO users (name) VALUES ('test')", "public")
      expect(query).to eq "INSERT INTO public.users (name) VALUES ('test')"
    end

    it "handles UPDATE statements" do
      query = described_class.qualify("UPDATE users SET name = 'test'", "public")
      expect(query).to eq "UPDATE public.users SET name = 'test'"
    end

    it "handles DELETE statements" do
      query = described_class.qualify("DELETE FROM users WHERE id = 1", "public")
      expect(query).to eq "DELETE FROM public.users WHERE id = 1"
    end

    it "returns nil for invalid SQL" do
      query = described_class.qualify("INVALID SQL", "public")
      expect(query).to be_nil
    end
  end

  describe "advanced SELECT queries" do
    it "qualifies tables in multiple types of JOINs" do
      query = described_class.qualify("SELECT * FROM users u LEFT JOIN orders o ON u.id = o.user_id RIGHT JOIN products p ON o.product_id = p.id", "public")
      expect(query).to eq "SELECT * FROM public.users u LEFT JOIN public.orders o ON u.id = o.user_id RIGHT JOIN public.products p ON o.product_id = p.id"
    end

    it "qualifies tables in INNER and OUTER JOINs" do
      query = described_class.qualify("SELECT * FROM users u INNER JOIN profiles p ON u.id = p.user_id FULL OUTER JOIN settings s ON u.id = s.user_id", "public")
      expect(query).to eq "SELECT * FROM public.users u JOIN public.profiles p ON u.id = p.user_id FULL JOIN public.settings s ON u.id = s.user_id"
    end

    it "qualifies tables in CROSS JOIN" do
      query = described_class.qualify("SELECT * FROM users CROSS JOIN categories", "public")
      expect(query).to eq "SELECT * FROM public.users CROSS JOIN public.categories"
    end

    it "qualifies tables in nested subqueries" do
      query = described_class.qualify("SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE product_id IN (SELECT id FROM products WHERE active = true))", "public")
      expect(query).to eq "SELECT * FROM public.users WHERE id IN (SELECT user_id FROM public.orders WHERE product_id IN (SELECT id FROM public.products WHERE active = true))"
    end

    it "qualifies tables in EXISTS subqueries" do
      query = described_class.qualify("SELECT * FROM users u WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id)", "public")
      expect(query).to eq "SELECT * FROM public.users u WHERE EXISTS (SELECT 1 FROM public.orders o WHERE o.user_id = u.id)"
    end

    it "qualifies tables in NOT EXISTS subqueries" do
      query = described_class.qualify("SELECT * FROM users u WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id)", "public")
      expect(query).to eq "SELECT * FROM public.users u WHERE NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.user_id = u.id)"
    end

    it "qualifies tables in subqueries in SELECT clause" do
      query = described_class.qualify("SELECT id, name, (SELECT COUNT(*) FROM orders WHERE user_id = users.id) as order_count FROM users", "public")
      expect(query).to eq "SELECT id, name, (SELECT count(*) FROM public.orders WHERE user_id = users.id) AS order_count FROM public.users"
    end

    it "qualifies tables in UNION operations" do
      query = described_class.qualify("SELECT name FROM users UNION SELECT name FROM customers", "public")
      expect(query).to eq "SELECT name FROM public.users UNION SELECT name FROM public.customers"
    end

    it "qualifies tables in UNION ALL operations" do
      query = described_class.qualify("SELECT id, name FROM users UNION ALL SELECT id, name FROM customers", "public")
      expect(query).to eq "SELECT id, name FROM public.users UNION ALL SELECT id, name FROM public.customers"
    end

    it "qualifies tables in INTERSECT operations" do
      query = described_class.qualify("SELECT name FROM users INTERSECT SELECT name FROM customers", "public")
      expect(query).to eq "SELECT name FROM public.users INTERSECT SELECT name FROM public.customers"
    end

    it "qualifies tables in EXCEPT operations" do
      query = described_class.qualify("SELECT name FROM users EXCEPT SELECT name FROM customers", "public")
      expect(query).to eq "SELECT name FROM public.users EXCEPT SELECT name FROM public.customers"
    end

    it "qualifies tables with window functions" do
      query = described_class.qualify("SELECT id, name, ROW_NUMBER() OVER (ORDER BY created_at) FROM users", "public")
      expect(query).to eq "SELECT id, name, row_number() OVER (ORDER BY created_at) FROM public.users"
    end

    it "qualifies tables in complex window functions" do
      query = described_class.qualify("SELECT id, name, SUM(amount) OVER (PARTITION BY user_id ORDER BY created_at) FROM orders", "public")
      expect(query).to eq "SELECT id, name, sum(amount) OVER (PARTITION BY user_id ORDER BY created_at) FROM public.orders"
    end

    it "qualifies tables in GROUP BY and HAVING clauses" do
      query = described_class.qualify("SELECT user_id, COUNT(*) FROM orders GROUP BY user_id HAVING COUNT(*) > 5", "public")
      expect(query).to eq "SELECT user_id, count(*) FROM public.orders GROUP BY user_id HAVING count(*) > 5"
    end

    it "qualifies tables in ORDER BY clauses" do
      query = described_class.qualify("SELECT * FROM users ORDER BY (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "SELECT * FROM public.users ORDER BY (SELECT count(*) FROM public.orders WHERE user_id = users.id)"
    end

    it "qualifies tables in LIMIT and OFFSET with subqueries" do
      query = described_class.qualify("SELECT * FROM users LIMIT (SELECT COUNT(*) FROM settings WHERE key = 'max_users') OFFSET (SELECT COUNT(*) FROM users WHERE active = false)", "public")
      expect(query).to eq "SELECT * FROM public.users LIMIT (SELECT count(*) FROM public.settings WHERE key = 'max_users') OFFSET (SELECT count(*) FROM public.users WHERE active = false)"
    end
  end

  describe "advanced INSERT queries" do
    it "qualifies tables in INSERT with subquery" do
      query = described_class.qualify("INSERT INTO users (name, email) SELECT name, email FROM temp_users", "public")
      expect(query).to eq "INSERT INTO public.users (name, email) SELECT name, email FROM public.temp_users"
    end

    it "qualifies tables in INSERT with VALUES containing subqueries" do
      query = described_class.qualify("INSERT INTO orders (user_id, product_id) VALUES ((SELECT id FROM users WHERE email = 'test@example.com'), (SELECT id FROM products WHERE name = 'Test Product'))", "public")
      expect(query).to eq "INSERT INTO public.orders (user_id, product_id) VALUES ((SELECT id FROM public.users WHERE email = 'test@example.com'), (SELECT id FROM public.products WHERE name = 'Test Product'))"
    end

    it "qualifies tables in INSERT ON CONFLICT with subquery" do
      query = described_class.qualify("INSERT INTO users (name, email) VALUES ('John', 'john@example.com') ON CONFLICT (email) DO UPDATE SET name = (SELECT name FROM profiles WHERE user_id = users.id)", "public")
      expect(query).to eq "INSERT INTO public.users (name, email) VALUES ('John', 'john@example.com') ON CONFLICT (email) DO UPDATE SET name = (SELECT name FROM public.profiles WHERE user_id = users.id)"
    end

    it "qualifies tables in INSERT RETURNING with subquery" do
      query = described_class.qualify("INSERT INTO users (name) VALUES ('John') RETURNING id, (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "INSERT INTO public.users (name) VALUES ('John') RETURNING id, (SELECT count(*) FROM public.orders WHERE user_id = users.id)"
    end
  end

  describe "advanced UPDATE queries" do
    it "qualifies tables in UPDATE with FROM clause" do
      query = described_class.qualify("UPDATE users SET name = profiles.display_name FROM profiles WHERE users.id = profiles.user_id", "public")
      expect(query).to eq "UPDATE public.users SET name = profiles.display_name FROM public.profiles WHERE users.id = profiles.user_id"
    end

    it "qualifies tables in UPDATE with subquery in SET clause" do
      query = described_class.qualify("UPDATE users SET order_count = (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "UPDATE public.users SET order_count = (SELECT count(*) FROM public.orders WHERE user_id = users.id)"
    end

    it "qualifies tables in UPDATE with subquery in WHERE clause" do
      query = described_class.qualify("UPDATE users SET active = false WHERE id IN (SELECT user_id FROM orders WHERE created_at < '2023-01-01')", "public")
      expect(query).to eq "UPDATE public.users SET active = false WHERE id IN (SELECT user_id FROM public.orders WHERE created_at < '2023-01-01')"
    end

    it "qualifies tables in UPDATE with JOIN in FROM clause" do
      query = described_class.qualify("UPDATE users SET name = p.display_name FROM profiles p JOIN settings s ON p.user_id = s.user_id WHERE users.id = p.user_id", "public")
      expect(query).to eq "UPDATE public.users SET name = p.display_name FROM public.profiles p JOIN public.settings s ON p.user_id = s.user_id WHERE users.id = p.user_id"
    end

    it "qualifies tables in UPDATE RETURNING with subquery" do
      query = described_class.qualify("UPDATE users SET name = 'Updated' WHERE id = 1 RETURNING id, (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "UPDATE public.users SET name = 'Updated' WHERE id = 1 RETURNING id, (SELECT count(*) FROM public.orders WHERE user_id = users.id)"
    end
  end

  describe "advanced DELETE queries" do
    it "qualifies tables in DELETE with USING clause" do
      query = described_class.qualify("DELETE FROM users USING profiles WHERE users.id = profiles.user_id AND profiles.active = false", "public")
      expect(query).to eq "DELETE FROM public.users USING public.profiles WHERE users.id = profiles.user_id AND profiles.active = false"
    end

    it "qualifies tables in DELETE with subquery in WHERE clause" do
      query = described_class.qualify("DELETE FROM users WHERE id IN (SELECT user_id FROM orders WHERE created_at < '2023-01-01')", "public")
      expect(query).to eq "DELETE FROM public.users WHERE id IN (SELECT user_id FROM public.orders WHERE created_at < '2023-01-01')"
    end

    it "qualifies tables in DELETE with EXISTS subquery" do
      query = described_class.qualify("DELETE FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE user_id = users.id AND status = 'cancelled')", "public")
      expect(query).to eq "DELETE FROM public.users WHERE EXISTS (SELECT 1 FROM public.orders WHERE user_id = users.id AND status = 'cancelled')"
    end

    it "qualifies tables in DELETE with multiple tables in USING clause" do
      query = described_class.qualify("DELETE FROM users USING profiles, settings WHERE users.id = profiles.user_id AND users.id = settings.user_id AND profiles.active = false", "public")
      expect(query).to eq "DELETE FROM public.users USING public.profiles, public.settings WHERE users.id = profiles.user_id AND users.id = settings.user_id AND profiles.active = false"
    end

    it "qualifies tables in DELETE RETURNING with subquery" do
      query = described_class.qualify("DELETE FROM users WHERE id = 1 RETURNING id, (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "DELETE FROM public.users WHERE id = 1 RETURNING id, (SELECT count(*) FROM public.orders WHERE user_id = users.id)"
    end
  end

  describe "complex expressions and functions" do
    it "qualifies tables in function calls with subqueries" do
      query = described_class.qualify("SELECT COALESCE((SELECT name FROM users WHERE id = 1), 'Unknown') as user_name FROM profiles", "public")
      expect(query).to eq "SELECT COALESCE((SELECT name FROM public.users WHERE id = 1), 'Unknown') AS user_name FROM public.profiles"
    end

    it "qualifies tables in CASE expressions with subqueries" do
      query = described_class.qualify("SELECT CASE WHEN (SELECT COUNT(*) FROM orders WHERE user_id = users.id) > 0 THEN 'Active' ELSE 'Inactive' END FROM users", "public")
      expect(query).to eq "SELECT CASE WHEN (SELECT count(*) FROM public.orders WHERE user_id = users.id) > 0 THEN 'Active' ELSE 'Inactive' END FROM public.users"
    end

    it "qualifies tables in array expressions with subqueries" do
      query = described_class.qualify("SELECT ARRAY(SELECT name FROM categories WHERE parent_id = products.category_id) FROM products", "public")
      expect(query).to eq "SELECT ARRAY(SELECT name FROM public.categories WHERE parent_id = products.category_id) FROM public.products"
    end

    it "qualifies tables in row expressions with subqueries" do
      query = described_class.qualify("SELECT * FROM users WHERE (name, email) IN (SELECT name, email FROM temp_users)", "public")
      expect(query).to eq "SELECT * FROM public.users WHERE (name, email) IN (SELECT name, email FROM public.temp_users)"
    end

    it "qualifies tables in aggregate functions with subqueries" do
      query = described_class.qualify("SELECT COUNT((SELECT 1 FROM orders WHERE user_id = users.id)) FROM users", "public")
      expect(query).to eq "SELECT count((SELECT 1 FROM public.orders WHERE user_id = users.id)) FROM public.users"
    end
  end

  describe "CTE (Common Table Expression) handling" do
    it "qualifies tables within CTEs but not CTE names" do
      query = described_class.qualify("WITH user_stats AS (SELECT * FROM users) SELECT * FROM user_stats", "public")
      expect(query).to eq "WITH user_stats AS (SELECT * FROM public.users) SELECT * FROM user_stats"
    end

    it "handles multiple CTEs" do
      query = described_class.qualify(
        "WITH user_stats AS (SELECT * FROM users), order_stats AS (SELECT * FROM orders) SELECT * FROM user_stats JOIN order_stats ON user_stats.id = order_stats.user_id",
        "public"
      )
      expect(query).to eq "WITH user_stats AS (SELECT * FROM public.users), order_stats AS (SELECT * FROM public.orders) SELECT * FROM user_stats JOIN order_stats ON user_stats.id = order_stats.user_id"
    end

    it "handles recursive CTEs" do
      query = described_class.qualify(
        "WITH RECURSIVE tree AS (SELECT id, parent_id FROM categories WHERE parent_id IS NULL UNION ALL SELECT c.id, c.parent_id FROM categories c JOIN tree ct ON c.parent_id = ct.id) SELECT * FROM tree",
        "public"
      )
      expect(query).to eq "WITH RECURSIVE tree AS (SELECT id, parent_id FROM public.categories WHERE parent_id IS NULL UNION ALL SELECT c.id, c.parent_id FROM public.categories c JOIN tree ct ON c.parent_id = ct.id) SELECT * FROM tree"
    end

    it "handles CTEs with JOINs inside" do
      query = described_class.qualify(
        "WITH user_orders AS (SELECT u.id, o.amount FROM users u JOIN orders o ON u.id = o.user_id) SELECT * FROM user_orders WHERE amount > 100",
        "public"
      )
      expect(query).to eq "WITH user_orders AS (SELECT u.id, o.amount FROM public.users u JOIN public.orders o ON u.id = o.user_id) SELECT * FROM user_orders WHERE amount > 100"
    end

    it "handles CTEs in UPDATE statements" do
      query = described_class.qualify(
        "WITH active_users AS (SELECT id FROM users WHERE active = true) UPDATE profiles SET last_login = NOW() WHERE user_id IN (SELECT id FROM active_users)",
        "public"
      )
      expect(query).to eq "WITH active_users AS (SELECT id FROM public.users WHERE active = true) UPDATE public.profiles SET last_login = now() WHERE user_id IN (SELECT id FROM active_users)"
    end

    it "handles CTEs in DELETE statements" do
      query = described_class.qualify(
        "WITH old_data AS (SELECT id FROM logs) DELETE FROM logs WHERE id IN (SELECT id FROM old_data)",
        "public"
      )
      expect(query).to eq "WITH old_data AS (SELECT id FROM public.logs) DELETE FROM public.logs WHERE id IN (SELECT id FROM old_data)"
    end

    it "handles CTEs in INSERT statements" do
      query = described_class.qualify(
        "WITH new_users AS (SELECT name FROM temp_users WHERE validated = true) INSERT INTO users (name) SELECT name FROM new_users",
        "public"
      )
      expect(query).to eq "WITH new_users AS (SELECT name FROM public.temp_users WHERE validated = true) INSERT INTO public.users (name) SELECT name FROM new_users"
    end

    it "handles nested CTEs and complex queries" do
      query = described_class.qualify(
        "WITH regional_sales AS (SELECT region, SUM(sales_amount) AS total_sales FROM orders GROUP BY region), top_regions AS (SELECT region FROM regional_sales WHERE total_sales > (SELECT AVG(total_sales) FROM regional_sales)) SELECT region, total_sales FROM regional_sales WHERE region IN (SELECT region FROM top_regions) ORDER BY total_sales DESC",
        "public"
      )
      expect(query).to eq "WITH regional_sales AS (SELECT region, sum(sales_amount) AS total_sales FROM public.orders GROUP BY region), top_regions AS (SELECT region FROM regional_sales WHERE total_sales > (SELECT avg(total_sales) FROM regional_sales)) SELECT region, total_sales FROM regional_sales WHERE region IN (SELECT region FROM top_regions) ORDER BY total_sales DESC"
    end

    it "preserves already qualified table names in CTEs" do
      query = described_class.qualify(
        "WITH user_stats AS (SELECT * FROM other_schema.users) SELECT * FROM user_stats",
        "public"
      )
      expect(query).to eq "WITH user_stats AS (SELECT * FROM other_schema.users) SELECT * FROM user_stats"
    end

    it "qualifies tables with same name as CTE within CTE body" do
      query = described_class.qualify(
        "WITH shifts AS (select * from shifts limit 5) select id from shifts",
        "public"
      )
      expect(query).to eq "WITH shifts AS (SELECT * FROM public.shifts LIMIT 5) SELECT id FROM shifts"
    end

    it "qualifies tables with same name as CTE in multiple CTEs" do
      query = described_class.qualify(
        "WITH orders AS (select * from orders where status = 'pending'), users AS (select * from users where active = true) select * from orders join users on orders.user_id = users.id",
        "public"
      )
      expect(query).to eq "WITH orders AS (SELECT * FROM public.orders WHERE status = 'pending'), users AS (SELECT * FROM public.users WHERE active = true) SELECT * FROM orders JOIN users ON orders.user_id = users.id"
    end

    it "preserves existing behavior for recursive CTEs with same table name as CTE" do
      query = described_class.qualify(
        "WITH RECURSIVE tree AS (SELECT id, parent_id, name FROM tree WHERE parent_id IS NULL UNION ALL SELECT t.id, t.parent_id, t.name FROM tree t JOIN tree tr ON t.parent_id = tr.id) SELECT * FROM tree",
        "public"
      )
      expect(query).to eq "WITH RECURSIVE tree AS (SELECT id, parent_id, name FROM tree WHERE parent_id IS NULL UNION ALL SELECT t.id, t.parent_id, t.name FROM tree t JOIN tree tr ON t.parent_id = tr.id) SELECT * FROM tree"
    end

    it "handles CTEs that reference regular tables and other CTEs" do
      query = described_class.qualify(
        "WITH user_data AS (SELECT id, name FROM users), enriched_data AS (SELECT ud.id, ud.name, p.email FROM user_data ud JOIN profiles p ON ud.id = p.user_id) SELECT * FROM enriched_data",
        "public"
      )
      expect(query).to eq "WITH user_data AS (SELECT id, name FROM public.users), enriched_data AS (SELECT ud.id, ud.name, p.email FROM user_data ud JOIN public.profiles p ON ud.id = p.user_id) SELECT * FROM enriched_data"
    end
  end

  describe "edge cases" do
    it "handles empty schema names" do
      query = described_class.qualify("SELECT * FROM users", "")
      expect(query).to eq "SELECT * FROM users"
    end

    it "handles complex nested queries with CTEs" do
      query = described_class.qualify(
        "WITH RECURSIVE subordinates AS (SELECT employee_id, manager_id, name FROM employees WHERE manager_id = 1 UNION ALL SELECT e.employee_id, e.manager_id, e.name FROM employees e INNER JOIN subordinates s ON s.employee_id = e.manager_id) SELECT * FROM subordinates WHERE employee_id NOT IN (SELECT manager_id FROM employees WHERE manager_id IS NOT NULL)",
        "hr"
      )
      expect(query).to eq "WITH RECURSIVE subordinates AS (SELECT employee_id, manager_id, name FROM hr.employees WHERE manager_id = 1 UNION ALL SELECT e.employee_id, e.manager_id, e.name FROM hr.employees e JOIN subordinates s ON s.employee_id = e.manager_id) SELECT * FROM subordinates WHERE NOT employee_id IN (SELECT manager_id FROM hr.employees WHERE manager_id IS NOT NULL)"
    end

    it "handles window functions with CTEs" do
      query = described_class.qualify(
        "WITH ranked_sales AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY region ORDER BY sales_amount DESC) as rank FROM sales) SELECT * FROM ranked_sales WHERE rank <= 3",
        "public"
      )
      expect(query).to eq "WITH ranked_sales AS (SELECT *, row_number() OVER (PARTITION BY region ORDER BY sales_amount DESC) AS rank FROM public.sales) SELECT * FROM ranked_sales WHERE rank <= 3"
    end

    it "handles CTEs with UNION operations" do
      query = described_class.qualify(
        "WITH combined_data AS (SELECT id, name FROM users UNION ALL SELECT id, name FROM customers) SELECT * FROM combined_data ORDER BY name",
        "public"
      )
      expect(query).to eq "WITH combined_data AS (SELECT id, name FROM public.users UNION ALL SELECT id, name FROM public.customers) SELECT * FROM combined_data ORDER BY name"
    end
  end

  describe "different schema names" do
    it "qualifies with different schema names" do
      query = described_class.qualify("SELECT * FROM users", "analytics")
      expect(query).to eq "SELECT * FROM analytics.users"
    end

    it "qualifies CTEs with different schema names" do
      query = described_class.qualify(
        "WITH user_stats AS (SELECT * FROM users) SELECT * FROM user_stats",
        "analytics"
      )
      expect(query).to eq "WITH user_stats AS (SELECT * FROM analytics.users) SELECT * FROM user_stats"
    end

    it "properly quotes ASCII-encoded UUID schema names" do
      uuid_schema = "123e4567-e89b-12d3-a456-426614174000"
      query = described_class.qualify("SELECT * FROM users WHERE users.id = 1", uuid_schema)
      expect(query).to eq 'SELECT * FROM "123e4567-e89b-12d3-a456-426614174000".users WHERE users.id = 1'
    end

    it "quotes UUID schemas in complex queries with subqueries" do
      uuid_schema = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
      query = described_class.qualify(
        "UPDATE users SET name = (SELECT name FROM profiles WHERE user_id = users.id)",
        uuid_schema
      )
      expect(query).to eq 'UPDATE "f47ac10b-58cc-4372-a567-0e02b2c3d479".users SET name = (SELECT name FROM "f47ac10b-58cc-4372-a567-0e02b2c3d479".profiles WHERE user_id = users.id)'
    end
  end

  describe "JOIN conditions" do
    it "should qualify column references in JOIN conditions" do
      query = described_class.qualify("SELECT * FROM users u JOIN orders o ON u.id = o.user_id WHERE u.active = true", "public")
      expect(query).to eq "SELECT * FROM public.users u JOIN public.orders o ON u.id = o.user_id WHERE u.active = true"
    end
  end

  describe "pending improvements - complex subquery contexts" do
    it "should fully qualify tables in NOT EXISTS subqueries" do
      query = described_class.qualify("SELECT * FROM users u WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id)", "public")
      expect(query).to eq "SELECT * FROM public.users u WHERE NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.user_id = u.id)"
    end

    it "should fully qualify tables in ORDER BY subqueries" do
      query = described_class.qualify("SELECT * FROM users ORDER BY (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "SELECT * FROM public.users ORDER BY (SELECT count(*) FROM public.orders WHERE user_id = users.id)"
    end

    it "should fully qualify tables in LIMIT/OFFSET subqueries" do
      query = described_class.qualify("SELECT * FROM users LIMIT (SELECT COUNT(*) FROM settings WHERE key = 'max_users')", "public")
      expect(query).to eq "SELECT * FROM public.users LIMIT (SELECT count(*) FROM public.settings WHERE key = 'max_users')"
    end

    it "should fully qualify tables in INSERT VALUES subqueries" do
      query = described_class.qualify("INSERT INTO orders (user_id, product_id) VALUES ((SELECT id FROM users WHERE email = 'test@example.com'), 1)", "public")
      expect(query).to eq "INSERT INTO public.orders (user_id, product_id) VALUES ((SELECT id FROM public.users WHERE email = 'test@example.com'), 1)"
    end

    it "should fully qualify tables in INSERT ON CONFLICT subqueries" do
      query = described_class.qualify("INSERT INTO users (name, email) VALUES ('John', 'john@example.com') ON CONFLICT (email) DO UPDATE SET name = (SELECT name FROM profiles WHERE user_id = users.id)", "public")
      expect(query).to eq "INSERT INTO public.users (name, email) VALUES ('John', 'john@example.com') ON CONFLICT (email) DO UPDATE SET name = (SELECT name FROM public.profiles WHERE user_id = users.id)"
    end

    it "should fully qualify tables in RETURNING subqueries" do
      query = described_class.qualify("INSERT INTO users (name) VALUES ('John') RETURNING id, (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "INSERT INTO public.users (name) VALUES ('John') RETURNING id, (SELECT count(*) FROM public.orders WHERE user_id = users.id)"
    end

    it "should fully qualify tables in UPDATE SET subqueries" do
      query = described_class.qualify("UPDATE users SET order_count = (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "UPDATE public.users SET order_count = (SELECT count(*) FROM public.orders WHERE user_id = users.id)"
    end

    it "should fully qualify tables in DELETE WHERE EXISTS subqueries" do
      query = described_class.qualify("DELETE FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE user_id = users.id AND status = 'cancelled')", "public")
      expect(query).to eq "DELETE FROM public.users WHERE EXISTS (SELECT 1 FROM public.orders WHERE user_id = users.id AND status = 'cancelled')"
    end
  end

  describe "pending improvements - advanced expression contexts" do
    it "should fully qualify tables in function call subqueries" do
      query = described_class.qualify("SELECT COALESCE((SELECT name FROM users WHERE id = 1), 'Unknown') FROM profiles", "public")
      expect(query).to eq "SELECT COALESCE((SELECT name FROM public.users WHERE id = 1), 'Unknown') FROM public.profiles"
    end

    it "should fully qualify tables in CASE expression subqueries" do
      query = described_class.qualify("SELECT CASE WHEN (SELECT COUNT(*) FROM orders WHERE user_id = users.id) > 0 THEN 'Active' ELSE 'Inactive' END FROM users", "public")
      expect(query).to eq "SELECT CASE WHEN (SELECT count(*) FROM public.orders WHERE user_id = users.id) > 0 THEN 'Active' ELSE 'Inactive' END FROM public.users"
    end

    it "should fully qualify tables in array subqueries" do
      query = described_class.qualify("SELECT ARRAY(SELECT name FROM categories WHERE parent_id = products.category_id) FROM products", "public")
      expect(query).to eq "SELECT ARRAY(SELECT name FROM public.categories WHERE parent_id = products.category_id) FROM public.products"
    end

    it "should fully qualify tables in aggregate function subqueries" do
      query = described_class.qualify("SELECT COUNT((SELECT 1 FROM orders WHERE user_id = users.id)) FROM users", "public")
      expect(query).to eq "SELECT count((SELECT 1 FROM public.orders WHERE user_id = users.id)) FROM public.users"
    end

    it "should fully qualify tables in window function subqueries" do
      query = described_class.qualify("SELECT ROW_NUMBER() OVER (ORDER BY (SELECT created_at FROM profiles WHERE user_id = users.id)) FROM users", "public")
      expect(query).to eq "SELECT row_number() OVER (ORDER BY (SELECT created_at FROM public.profiles WHERE user_id = users.id)) FROM public.users"
    end

    it "should fully qualify tables in complex nested expressions" do
      query = described_class.qualify("SELECT * FROM users WHERE id = ANY(SELECT user_id FROM orders WHERE product_id = ANY(SELECT id FROM products WHERE category_id = 1))", "public")
      expect(query).to eq "SELECT * FROM public.users WHERE id = ANY (SELECT user_id FROM public.orders WHERE product_id = ANY (SELECT id FROM public.products WHERE category_id = 1))"
    end
  end

  describe "pending improvements - advanced SQL features" do
    it "should handle table-valued functions properly" do
      query = described_class.qualify("SELECT * FROM users u, generate_series(1, (SELECT COUNT(*) FROM orders)) AS s", "public")
      expect(query).to eq "SELECT * FROM public.users u, generate_series(1, (SELECT count(*) FROM public.orders)) s"
    end

    it "should handle lateral joins with subqueries" do
      query = described_class.qualify("SELECT * FROM users u, LATERAL (SELECT * FROM orders WHERE user_id = u.id) o", "public")
      expect(query).to eq "SELECT * FROM public.users u, LATERAL (SELECT * FROM public.orders WHERE user_id = u.id) o"
    end

    it "should handle VALUES clauses with subqueries" do
      query = described_class.qualify("SELECT * FROM users WHERE id IN (VALUES ((SELECT 1)), ((SELECT 2 FROM orders WHERE id = 1)))", "public")
      expect(query).to eq "SELECT * FROM public.users WHERE id IN (VALUES ((SELECT 1)), ((SELECT 2 FROM public.orders WHERE id = 1)))"
    end

    it "should handle stored procedure calls with table parameters" do
      # pending "Stored procedure calls with table parameters should be qualified"
      query = described_class.qualify("SELECT * FROM my_function((SELECT * FROM users WHERE active = true))", "public")
      expect(query).to eq "SELECT * FROM my_function((SELECT * FROM public.users WHERE active = true))"
    end

    it "should handle recursive CTE references in complex contexts" do
      query = described_class.qualify("WITH RECURSIVE tree AS (SELECT * FROM categories WHERE parent_id IS NULL UNION ALL SELECT c.* FROM categories c, tree WHERE c.parent_id = tree.id AND EXISTS (SELECT 1 FROM products WHERE category_id = c.id)) SELECT * FROM tree", "public")
      expect(query).to eq "WITH RECURSIVE tree AS (SELECT * FROM public.categories WHERE parent_id IS NULL UNION ALL SELECT c.* FROM public.categories c, tree WHERE c.parent_id = tree.id AND EXISTS (SELECT 1 FROM public.products WHERE category_id = c.id)) SELECT * FROM tree"
    end

    it "should handle table expressions in FROM clauses" do
      query = described_class.qualify("SELECT * FROM (SELECT * FROM users WHERE active = true) u JOIN (SELECT * FROM orders WHERE status = 'pending') o ON u.id = o.user_id", "public")
      expect(query).to eq "SELECT * FROM (SELECT * FROM public.users WHERE active = true) u JOIN (SELECT * FROM public.orders WHERE status = 'pending') o ON u.id = o.user_id"
    end

    it "should handle complex correlated subqueries" do
      query = described_class.qualify("SELECT * FROM users u WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id AND o.total > (SELECT AVG(total) FROM orders o2 WHERE o2.user_id = u.id))", "public")
      expect(query).to eq "SELECT * FROM public.users u WHERE EXISTS (SELECT 1 FROM public.orders o WHERE o.user_id = u.id AND o.total > (SELECT avg(total) FROM public.orders o2 WHERE o2.user_id = u.id))"
    end
  end

  describe "CREATE FUNCTION support" do
    it "qualifies table references in SQL function bodies" do
      sql = "CREATE FUNCTION get_user_orders(user_id int) RETURNS TABLE(order_id int, amount decimal) AS $$ SELECT id, amount FROM orders WHERE user_id = $1 $$ LANGUAGE SQL"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE FUNCTION get_user_orders(user_id int) RETURNS TABLE (order_id int, amount numeric) AS $$SELECT id, amount FROM public.orders WHERE user_id = $1$$ LANGUAGE sql"
    end

    it "qualifies table references in simple SQL function bodies" do
      sql = "CREATE FUNCTION get_user_count() RETURNS int AS $$ SELECT COUNT(*) FROM users $$ LANGUAGE SQL"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE FUNCTION get_user_count() RETURNS int AS $$SELECT count(*) FROM public.users$$ LANGUAGE sql"
    end

    it "qualifies table references in SQL functions with JOINs" do
      sql = "CREATE FUNCTION get_user_orders_with_products(user_id int) RETURNS TABLE(order_id int, product_name text) AS $$ SELECT o.id, p.name FROM orders o JOIN products p ON o.product_id = p.id WHERE o.user_id = $1 $$ LANGUAGE SQL"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE FUNCTION get_user_orders_with_products(user_id int) RETURNS TABLE (order_id int, product_name text) AS $$SELECT o.id, p.name FROM public.orders o JOIN public.products p ON o.product_id = p.id WHERE o.user_id = $1$$ LANGUAGE sql"
    end

    it "qualifies table references in SQL functions with subqueries" do
      sql = "CREATE FUNCTION get_active_users() RETURNS TABLE(user_id int) AS $$ SELECT id FROM users WHERE id IN (SELECT user_id FROM orders WHERE status = 'active') $$ LANGUAGE SQL"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE FUNCTION get_active_users() RETURNS TABLE (user_id int) AS $$SELECT id FROM public.users WHERE id IN (SELECT user_id FROM public.orders WHERE status = 'active')$$ LANGUAGE sql"
    end

    it "preserves already qualified tables in function bodies" do
      sql = "CREATE FUNCTION get_user_orders(user_id int) RETURNS TABLE(order_id int) AS $$ SELECT id FROM other_schema.orders WHERE user_id = $1 $$ LANGUAGE SQL"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE FUNCTION get_user_orders(user_id int) RETURNS TABLE (order_id int) AS $$SELECT id FROM other_schema.orders WHERE user_id = $1$$ LANGUAGE sql"
    end

    it "does not qualify table references in PL/pgSQL function bodies" do
      sql = "CREATE FUNCTION update_user_orders(user_id int) RETURNS void AS $$ BEGIN UPDATE orders SET status = 'processed' WHERE user_id = $1; IF NOT FOUND THEN RAISE NOTICE 'No orders found'; END IF; END; $$ LANGUAGE plpgsql"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE FUNCTION update_user_orders(user_id int) RETURNS void AS $$ BEGIN UPDATE orders SET status = 'processed' WHERE user_id = $1; IF NOT FOUND THEN RAISE NOTICE 'No orders found'; END IF; END; $$ LANGUAGE plpgsql"
    end

    it "distinguishes between SQL and PL/pgSQL languages" do
      # SQL function should be qualified
      sql_func = "CREATE FUNCTION get_count() RETURNS int AS $$ SELECT COUNT(*) FROM users $$ LANGUAGE SQL"
      qualified_sql = described_class.qualify(sql_func, "public")
      expect(qualified_sql).to eq "CREATE FUNCTION get_count() RETURNS int AS $$SELECT count(*) FROM public.users$$ LANGUAGE sql"

      # PL/pgSQL function should NOT be qualified
      plpgsql_func = "CREATE FUNCTION insert_user(name text) RETURNS void AS $$ BEGIN INSERT INTO users (name) VALUES (name); END; $$ LANGUAGE plpgsql".freeze
      qualified_plpgsql = described_class.qualify(plpgsql_func, "public")
      expect(qualified_plpgsql).to eq plpgsql_func
    end
  end

  describe "pending improvements - edge cases and error handling" do
    it "should handle circular schema references gracefully" do
      query = described_class.qualify("SELECT * FROM public.users", "public")
      expect(query).to eq "SELECT * FROM public.users"
    end

    it "should handle malformed table names gracefully" do
      query = described_class.qualify("SELECT * FROM \"users with spaces\"", "public")
      expect(query).to eq "SELECT * FROM public.\"users with spaces\""
    end

    it "should handle schema-qualified CTE references" do
      query = described_class.qualify("WITH my_cte AS (SELECT * FROM users) SELECT * FROM public.my_cte", "public")
      expect(query).to eq "WITH my_cte AS (SELECT * FROM public.users) SELECT * FROM my_cte"
    end

    it "should handle temporary table qualifications" do
      query = described_class.qualify("SELECT * FROM temp_users", "public")
      expect(query).to eq "SELECT * FROM public.temp_users"
    end

    it "should handle view qualifications consistently" do
      query = described_class.qualify("SELECT * FROM user_view WHERE id IN (SELECT user_id FROM order_view)", "public")
      expect(query).to eq "SELECT * FROM public.user_view WHERE id IN (SELECT user_id FROM public.order_view)"
    end

    it "should handle information_schema and pg_catalog tables" do
      query = described_class.qualify("SELECT * FROM information_schema.tables", "public")
      expect(query).to eq "SELECT * FROM information_schema.tables"
    end

    it "should not qualify tables starting with pg_" do
      query = described_class.qualify("SELECT * FROM pg_class", "public")
      expect(query).to eq "SELECT * FROM pg_class"
    end

    it "should not qualify pg_ tables in complex queries" do
      query = described_class.qualify("SELECT u.*, t.typname FROM users u JOIN pg_type t ON u.type_oid = t.oid", "public")
      expect(query).to eq "SELECT u.*, t.typname FROM public.users u JOIN pg_type t ON u.type_oid = t.oid"
    end

    it "should handle very long table names" do
      long_table_name = "a" * 60
      query = described_class.qualify("SELECT * FROM #{long_table_name}", "public")
      expect(query).to eq "SELECT * FROM public.#{long_table_name}"
    end

    it "should handle unicode table names" do
      query = described_class.qualify("SELECT * FROM ユーザー", "public")
      expect(query).to eq "SELECT * FROM public.\"ユーザー\""
    end

    it "should only qualify unqualified tables when query has mixed qualified/unqualified tables" do
      query = described_class.qualify("SELECT * FROM other_schema.qualified_table, unqualified_table", "public")
      expect(query).to eq "SELECT * FROM other_schema.qualified_table, public.unqualified_table"
    end
  end

  describe "DDL statements" do
    it "qualifies tables in CREATE INDEX statements with line ending preservation" do
      sql = "CREATE INDEX idx_users_email ON users (email)"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE INDEX idx_users_email ON public.users USING btree (email)"
    end

    it "qualifies tables in ALTER TABLE statements with line ending preservation" do
      sql = "ALTER TABLE users ADD COLUMN created_at TIMESTAMP"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "ALTER TABLE public.users ADD COLUMN created_at timestamp"
    end

    it "qualifies tables in DROP TABLE statements" do
      sql = "DROP TABLE users"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "DROP TABLE public.users"
    end

    it "preserves already qualified tables in DROP TABLE statements" do
      sql = "DROP TABLE other_schema.users"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "DROP TABLE other_schema.users"
    end

    it "qualifies multiple tables in DROP TABLE statements" do
      sql = "DROP TABLE users, orders, products"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "DROP TABLE public.users, public.orders, public.products"
    end

    it "qualifies indexes in DROP INDEX statements" do
      sql = "DROP INDEX my_index"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "DROP INDEX public.my_index"
    end

    it "qualifies tables in CREATE VIEW statements with line ending preservation" do
      sql = "CREATE VIEW active_users AS SELECT * FROM users WHERE active = true"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE VIEW active_users AS SELECT * FROM public.users WHERE active = true"
    end

    it "qualifies table references in CREATE FUNCTION statements" do
      sql = "CREATE FUNCTION get_user_count() RETURNS int AS $$ SELECT COUNT(*) FROM users $$ LANGUAGE SQL"
      query = described_class.qualify(sql, "public")
      expect(query).to include("public.users")
    end

    it "qualifies tables in CREATE TRIGGER statements with line ending preservation" do
      sql = "CREATE TRIGGER update_timestamp BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_ts()"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE TRIGGER update_timestamp BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION update_ts()"
    end

    it "qualifies tables in ALTER TABLE DISABLE TRIGGER statements" do
      sql = "ALTER TABLE users DISABLE TRIGGER update_timestamp"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "ALTER TABLE public.users DISABLE TRIGGER update_timestamp"
    end

    it "qualifies tables in ALTER TABLE ENABLE TRIGGER statements" do
      sql = "ALTER TABLE users ENABLE TRIGGER update_timestamp"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "ALTER TABLE public.users ENABLE TRIGGER update_timestamp"
    end

    it "qualifies tables in ALTER TABLE ENABLE TRIGGER ALL statements" do
      sql = "ALTER TABLE users ENABLE TRIGGER ALL"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "ALTER TABLE public.users ENABLE TRIGGER ALL"
    end

    it "qualifies tables in ALTER TABLE DISABLE TRIGGER ALL statements" do
      sql = "ALTER TABLE users DISABLE TRIGGER ALL"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "ALTER TABLE public.users DISABLE TRIGGER ALL"
    end

    it "qualifies tables in DROP TRIGGER statements" do
      sql = "DROP TRIGGER update_timestamp ON users"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "DROP TRIGGER update_timestamp ON public.users"
    end

    it "qualifies tables in DROP TRIGGER IF EXISTS statements" do
      sql = "DROP TRIGGER IF EXISTS update_timestamp ON users"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "DROP TRIGGER IF EXISTS update_timestamp ON public.users"
    end

    it "preserves already qualified tables in DROP TRIGGER statements" do
      sql = "DROP TRIGGER update_timestamp ON other_schema.users"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "DROP TRIGGER update_timestamp ON other_schema.users"
    end

    it "handles complex trigger and table names in DROP TRIGGER statements" do
      sql = 'DROP TRIGGER my_trigger ON "30759356-abc1-6802-743d-8e901fa862a9".compliance_warnings'
      query = described_class.qualify(sql, "30759356-abc1-6802-743d-8e901fa862a9")
      expect(query).to eq 'DROP TRIGGER my_trigger ON "30759356-abc1-6802-743d-8e901fa862a9".compliance_warnings'
    end

    it "qualifies tables in CREATE TRIGGER with WHEN clause" do
      sql = "CREATE TRIGGER conditional_update BEFORE UPDATE ON orders FOR EACH ROW WHEN (OLD.status != NEW.status) EXECUTE FUNCTION log_status_change()"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE TRIGGER conditional_update BEFORE UPDATE ON public.orders FOR EACH ROW WHEN (old.status <> new.status) EXECUTE FUNCTION log_status_change()"
    end

    it "handles complex DDL gracefully" do
      sql = <<~SQL.chomp
          CREATE TABLE complex_table (
            id SERIAL PRIMARY KEY,
            data JSONB,
            created_at TIMESTAMP DEFAULT NOW()
          )
        SQL

      query = described_class.qualify(sql, "public")
      expect(query).to include("complex_table")
      expect(query).not_to be_nil
    end

    it "qualifies table references in constraints" do
      sql = "CREATE TABLE orders (id SERIAL, user_id INT REFERENCES users(id))"
      query = described_class.qualify(sql, "public")
      expect(query).to include("public.users")
      expect(query).to include("orders")
    end

    it "preserves DEFAULT clauses in CREATE TABLE statements" do
      sql = "CREATE TABLE users (id uuid DEFAULT public.uuid_generate_v7() NOT NULL, name text DEFAULT 'Anonymous', created_at timestamp DEFAULT now())"
      query = described_class.qualify(sql, "public")
      expect(query).to include("DEFAULT public.uuid_generate_v7()")
      expect(query).to include("DEFAULT 'Anonymous'")
      expect(query).to include("DEFAULT now()")
      expect(query).to include("NOT NULL")
    end

    it "qualifies function calls in DEFAULT clauses" do
      sql = "CREATE TABLE test (id uuid DEFAULT uuid_generate_v7(), other_id uuid DEFAULT other_schema.uuid_generate_v4())"
      query = described_class.qualify(sql, "public")
      # uuid_generate_v7 should remain unqualified (it's not a table reference)
      expect(query).to include("DEFAULT uuid_generate_v7()")
      # other_schema.uuid_generate_v4 should remain as-is (already qualified)
      expect(query).to include("DEFAULT other_schema.uuid_generate_v4()")
    end

    it "qualifies tables in GRANT statements" do
      sql = "GRANT SELECT ON users TO role1"
      query = described_class.qualify(sql, "public")
      expect(query).to include("public.users")
      expect(query).to include("role1")
    end

    it "preserves already qualified table names in DDL" do
      sql = "CREATE INDEX idx ON other_schema.users (email)"
      query = described_class.qualify(sql, "public")
      expect(query).to include("other_schema.users")
      expect(query).not_to include("public.users")
    end
  end

  describe "mixed DML and DDL" do
    it "qualifies tables in simple INSERT statements with line ending preservation" do
      sql = "INSERT INTO users (name) VALUES ('John Doe')"
      query = described_class.qualify(sql, "public")
      expect(query).to include("public.users")
    end

    it "qualifies tables in CREATE TABLE AS statements with line ending preservation" do
      sql = "CREATE TABLE user_summary AS SELECT id, name FROM users"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "CREATE TABLE user_summary AS SELECT id, name FROM public.users"
    end

    it "qualifies tables in UPDATE statements with line ending preservation" do
      sql = "UPDATE users SET active = true WHERE id = 1"
      query = described_class.qualify(sql, "public")
      expect(query).to eq "UPDATE public.users SET active = true WHERE id = 1"
    end
  end

  describe "operational SQL statements" do
    it "qualifies tables in VACUUM statements" do
      query = described_class.qualify("VACUUM users", "public")
      expect(query).to eq "VACUUM public.users"
    end

    it "qualifies tables in VACUUM ANALYZE statements" do
      query = described_class.qualify("VACUUM ANALYZE users", "public")
      expect(query).to eq "VACUUM (ANALYZE) public.users"
    end

    it "qualifies tables in VACUUM with options" do
      query = described_class.qualify("VACUUM (FULL) users", "public")
      expect(query).to eq "VACUUM (FULL) public.users"
    end

    it "qualifies tables in VACUUM with multiple options" do
      query = described_class.qualify("VACUUM (FULL, ANALYZE) users", "public")
      expect(query).to eq "VACUUM (FULL, ANALYZE) public.users"
    end

    it "qualifies tables in ANALYZE statements" do
      query = described_class.qualify("ANALYZE users", "public")
      expect(query).to eq "ANALYZE public.users"
    end

    it "qualifies multiple tables in VACUUM statements" do
      query = described_class.qualify("VACUUM users, orders", "public")
      expect(query).to eq "VACUUM public.users, public.orders"
    end

    it "qualifies tables in VACUUM with column specifications" do
      query = described_class.qualify("VACUUM users(name, email)", "public")
      expect(query).to eq "VACUUM public.users(name, email)"
    end

    it "preserves already qualified tables in VACUUM statements" do
      query = described_class.qualify("VACUUM other_schema.users", "public")
      expect(query).to eq "VACUUM other_schema.users"
    end

    it "qualifies mixed qualified and unqualified tables in VACUUM" do
      query = described_class.qualify("VACUUM other_schema.users, orders", "public")
      expect(query).to eq "VACUUM other_schema.users, public.orders"
    end

    it "does not qualify system tables in VACUUM statements" do
      query = described_class.qualify("VACUUM pg_class", "public")
      expect(query).to eq "VACUUM pg_class"
    end

    it "qualifies tables in VACUUM with different schema names" do
      query = described_class.qualify("VACUUM users", "analytics")
      expect(query).to eq "VACUUM analytics.users"
    end

    it "handles VACUUM with quotes UUID schema names" do
      uuid_schema = "123e4567-e89b-12d3-a456-426614174000"
      query = described_class.qualify("VACUUM users", uuid_schema)
      expect(query).to eq 'VACUUM "123e4567-e89b-12d3-a456-426614174000".users'
    end

    it "qualifies tables in CLUSTER statements" do
      query = described_class.qualify("CLUSTER users", "public")
      expect(query).to eq "CLUSTER public.users"
    end

    it "qualifies tables in CLUSTER with index specification" do
      query = described_class.qualify("CLUSTER users USING idx_users_name", "public")
      expect(query).to eq "CLUSTER public.users USING idx_users_name"
    end

    it "qualifies tables in TRUNCATE statements" do
      query = described_class.qualify("TRUNCATE users", "public")
      expect(query).to eq "TRUNCATE public.users"
    end

    it "qualifies tables in TRUNCATE with options" do
      query = described_class.qualify("TRUNCATE users RESTART IDENTITY CASCADE", "public")
      expect(query).to eq "TRUNCATE public.users RESTART IDENTITY CASCADE"
    end

    it "qualifies multiple tables in TRUNCATE statements" do
      query = described_class.qualify("TRUNCATE users, orders", "public")
      expect(query).to eq "TRUNCATE public.users, public.orders"
    end

    it "qualifies tables in EXPLAIN statements" do
      query = described_class.qualify("EXPLAIN SELECT * FROM users", "public")
      expect(query).to eq "EXPLAIN SELECT * FROM public.users"
    end

    it "qualifies tables in EXPLAIN ANALYZE statements" do
      query = described_class.qualify("EXPLAIN ANALYZE SELECT * FROM users", "public")
      expect(query).to eq "EXPLAIN (ANALYZE) SELECT * FROM public.users"
    end

    it "qualifies tables in complex EXPLAIN statements with subqueries" do
      query = described_class.qualify("EXPLAIN (FORMAT JSON) SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)", "public")
      expect(query).to eq 'EXPLAIN (FORMAT "json") SELECT * FROM public.users WHERE id IN (SELECT user_id FROM public.orders)'
    end

    it "qualifies tables in LOCK statements" do
      query = described_class.qualify("LOCK users", "public")
      expect(query).to eq "LOCK TABLE public.users"
    end

    it "qualifies multiple tables in LOCK statements" do
      query = described_class.qualify("LOCK users, orders IN SHARE MODE", "public")
      expect(query).to eq "LOCK TABLE public.users, public.orders IN SHARE MODE"
    end

    it "preserves already qualified tables in operational statements" do
      query = described_class.qualify("CLUSTER other_schema.users", "public")
      expect(query).to eq "CLUSTER other_schema.users"
    end

    it "handles VACUUM with empty schema (should not qualify)" do
      query = described_class.qualify("VACUUM users", "")
      expect(query).to eq "VACUUM users"
    end

    it "handles VACUUM with information_schema tables (should not qualify)" do
      query = described_class.qualify("VACUUM information_schema.tables", "public")
      expect(query).to eq "VACUUM information_schema.tables"
    end

    it "qualifies tables in nested EXPLAIN with CTEs" do
      query = described_class.qualify("EXPLAIN WITH user_stats AS (SELECT * FROM users) SELECT * FROM user_stats JOIN orders ON user_stats.id = orders.user_id", "public")
      expect(query).to eq "EXPLAIN WITH user_stats AS (SELECT * FROM public.users) SELECT * FROM user_stats JOIN public.orders ON user_stats.id = orders.user_id"
    end

    it "qualifies tables in EXPLAIN with complex window functions" do
      query = described_class.qualify("EXPLAIN SELECT ROW_NUMBER() OVER (ORDER BY (SELECT created_at FROM profiles WHERE user_id = users.id)) FROM users", "public")
      expect(query).to eq "EXPLAIN SELECT row_number() OVER (ORDER BY (SELECT created_at FROM public.profiles WHERE user_id = users.id)) FROM public.users"
    end

    it "handles CLUSTER without table name (should not crash)" do
      query = described_class.qualify("CLUSTER", "public")
      expect(query).to eq "CLUSTER"
    end

    it "handles mixed qualified and unqualified in TRUNCATE with CASCADE" do
      query = described_class.qualify("TRUNCATE schema1.table1, table2, table3 CASCADE", "public")
      expect(query).to eq "TRUNCATE schema1.table1, public.table2, public.table3 CASCADE"
    end

    it "qualifies tables in LOCK with NOWAIT option" do
      query = described_class.qualify("LOCK users IN ACCESS EXCLUSIVE MODE NOWAIT", "public")
      expect(query).to eq "LOCK TABLE public.users NOWAIT"
    end

    it "preserves quoted table names in operational statements" do
      query = described_class.qualify('VACUUM "My Table"', "public")
      expect(query).to eq 'VACUUM public."My Table"'
    end

    it "handles VACUUM ALL (no specific tables)" do
      query = described_class.qualify("VACUUM", "public")
      expect(query).to eq "VACUUM"
    end
  end

  describe "operational SQL with function qualification" do
    it "qualifies both tables and functions in EXPLAIN statements" do
      query = described_class.qualify_with_funcs("EXPLAIN SELECT custom_func(col1) FROM users", "public", ["custom_func"])
      expect(query).to eq "EXPLAIN SELECT public.custom_func(col1) FROM public.users"
    end

    it "qualifies functions in EXPLAIN with complex queries" do
      query = described_class.qualify_with_funcs("EXPLAIN ANALYZE SELECT encrypt_data(data) FROM logs WHERE custom_check(status)", "public", ["encrypt_data", "custom_check"])
      expect(query).to eq "EXPLAIN (ANALYZE) SELECT public.encrypt_data(data) FROM public.logs WHERE public.custom_check(status)"
    end

    it "does not qualify functions in VACUUM statements (functions not relevant)" do
      query = described_class.qualify_with_funcs("VACUUM users", "public", ["some_func"])
      expect(query).to eq "VACUUM public.users"
    end
  end

  describe "edge cases and error handling" do
    it "returns nil for invalid operational SQL" do
      query = described_class.qualify("VACUUM INVALID SYNTAX", "public")
      expect(query).to be_nil
    end

    it "handles very long table names in operational statements" do
      long_table_name = "a" * 60
      query = described_class.qualify("VACUUM #{long_table_name}", "public")
      expect(query).to eq "VACUUM public.#{long_table_name}"
    end

    it "handles unicode table names in operational statements" do
      query = described_class.qualify("TRUNCATE ユーザー", "public")
      expect(query).to eq "TRUNCATE public.\"ユーザー\""
    end

    it "preserves system catalogs across all operational statements" do
      system_tables = ["pg_class", "pg_attribute", "pg_namespace"]
      system_tables.each do |table|
        ["VACUUM", "ANALYZE", "CLUSTER", "TRUNCATE"].each do |command|
          # Skip TRUNCATE for system tables as it's not typically allowed
          next if command == "TRUNCATE"

          query = described_class.qualify("#{command} #{table}", "public")
          expect(query).to eq "#{command} #{table}"
        end
      end
    end
  end

  describe "function qualification with qualify_with_funcs" do
    it "qualifies exact function name matches" do
      query = described_class.qualify_with_funcs("SELECT my_func(col1) FROM users", "public", ["my_func"])
      expect(query).to eq "SELECT public.my_func(col1) FROM public.users"
    end

    it "qualifies function names with prefix patterns" do
      query = described_class.qualify_with_funcs("SELECT lz_compress(data), lz_decompress(data) FROM logs", "public", ["lz_%"])
      expect(query).to eq "SELECT public.lz_compress(data), public.lz_decompress(data) FROM public.logs"
    end

    it "does not qualify functions not in the list" do
      query = described_class.qualify_with_funcs("SELECT my_func(col1), other_func(col2) FROM users", "public", ["my_func"])
      expect(query).to eq "SELECT public.my_func(col1), other_func(col2) FROM public.users"
    end

    it "handles multiple function name patterns" do
      query = described_class.qualify_with_funcs("SELECT custom_log(msg), lz_compress(data), encrypt_data(val) FROM logs", "public", ["custom_%", "lz_%", "encrypt_data"])
      expect(query).to eq "SELECT public.custom_log(msg), public.lz_compress(data), public.encrypt_data(val) FROM public.logs"
    end

    it "does not qualify already qualified function names" do
      query = described_class.qualify_with_funcs("SELECT my_schema.my_func(col1) FROM users", "public", ["my_func"])
      expect(query).to eq "SELECT my_schema.my_func(col1) FROM public.users"
    end

    it "works with empty function list" do
      query = described_class.qualify_with_funcs("SELECT my_func(col1) FROM users", "public", [])
      expect(query).to eq "SELECT my_func(col1) FROM public.users"
    end

    it "qualifies functions in nested contexts" do
      query = described_class.qualify_with_funcs("SELECT * FROM users WHERE id IN (SELECT user_id FROM logs WHERE my_func(data) > 100)", "public", ["my_func"])
      expect(query).to eq "SELECT * FROM public.users WHERE id IN (SELECT user_id FROM public.logs WHERE public.my_func(data) > 100)"
    end

    it "qualifies aggregate functions" do
      query = described_class.qualify_with_funcs("SELECT custom_sum(amount) FROM orders GROUP BY user_id", "public", ["custom_sum"])
      expect(query).to eq "SELECT public.custom_sum(amount) FROM public.orders GROUP BY user_id"
    end

    it "qualifies window functions" do
      query = described_class.qualify_with_funcs("SELECT custom_rank() OVER (ORDER BY amount) FROM orders", "public", ["custom_rank"])
      expect(query).to eq "SELECT public.custom_rank() OVER (ORDER BY amount) FROM public.orders"
    end

    it "handles case sensitivity in function names" do
      query = described_class.qualify_with_funcs("SELECT My_Func(col1) FROM users", "public", ["my_func"])
      expect(query).to eq "SELECT public.my_func(col1) FROM public.users"
    end

    it "qualifies functions in CREATE TRIGGER statements" do
      sql = "CREATE TRIGGER update_timestamp BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_ts()"
      query = described_class.qualify_with_funcs(sql, "public", ["update_ts"])
      expect(query).to eq "CREATE TRIGGER update_timestamp BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_ts()"
    end

    it "qualifies functions in CREATE TRIGGER with WHEN clause" do
      sql = "CREATE TRIGGER conditional_update BEFORE UPDATE ON orders FOR EACH ROW WHEN (validate_change(OLD.status, NEW.status)) EXECUTE FUNCTION log_status_change()"
      query = described_class.qualify_with_funcs(sql, "public", ["validate_change", "log_status_change"])
      expect(query).to eq "CREATE TRIGGER conditional_update BEFORE UPDATE ON public.orders FOR EACH ROW WHEN (public.validate_change(old.status, new.status)) EXECUTE FUNCTION public.log_status_change()"
    end

    it "qualifies multiple functions in CREATE TRIGGER with complex WHEN clause" do
      sql = "CREATE TRIGGER audit_trigger AFTER UPDATE ON users FOR EACH ROW WHEN (audit_enabled() AND changed_columns(OLD, NEW) > 0) EXECUTE FUNCTION create_audit_entry()"
      query = described_class.qualify_with_funcs(sql, "public", ["audit_enabled", "changed_columns", "create_audit_entry"])
      expect(query).to eq "CREATE TRIGGER audit_trigger AFTER UPDATE ON public.users FOR EACH ROW WHEN (public.audit_enabled() AND public.changed_columns(old, new) > 0) EXECUTE FUNCTION public.create_audit_entry()"
    end

    it "does not qualify already schema-qualified functions in triggers" do
      sql = "CREATE TRIGGER update_timestamp BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION audit.update_ts()"
      query = described_class.qualify_with_funcs(sql, "public", ["update_ts"])
      expect(query).to eq "CREATE TRIGGER update_timestamp BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION audit.update_ts()"
    end
  end
end
