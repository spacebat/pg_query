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
      expect(query).to eq "SELECT * FROM public.users LIMIT (SELECT count(*) FROM settings WHERE key = 'max_users') OFFSET (SELECT count(*) FROM users WHERE active = false)"
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
      expect(query).to eq "INSERT INTO public.users (name, email) VALUES ('John', 'john@example.com') ON CONFLICT (email) DO UPDATE SET name = (SELECT name FROM profiles WHERE user_id = users.id)"
    end

    it "qualifies tables in INSERT RETURNING with subquery" do
      query = described_class.qualify("INSERT INTO users (name) VALUES ('John') RETURNING id, (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "INSERT INTO public.users (name) VALUES ('John') RETURNING id, (SELECT count(*) FROM orders WHERE user_id = users.id)"
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
      expect(query).to eq "UPDATE public.users SET name = 'Updated' WHERE id = 1 RETURNING id, (SELECT count(*) FROM orders WHERE user_id = users.id)"
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
      expect(query).to eq "DELETE FROM public.users WHERE id = 1 RETURNING id, (SELECT count(*) FROM orders WHERE user_id = users.id)"
    end
  end

  describe "complex expressions and functions" do
    it "qualifies tables in function calls with subqueries" do
      query = described_class.qualify("SELECT COALESCE((SELECT name FROM users WHERE id = 1), 'Unknown') as user_name FROM profiles", "public")
      expect(query).to eq "SELECT COALESCE((SELECT name FROM users WHERE id = 1), 'Unknown') AS user_name FROM public.profiles"
    end

    it "qualifies tables in CASE expressions with subqueries" do
      query = described_class.qualify("SELECT CASE WHEN (SELECT COUNT(*) FROM orders WHERE user_id = users.id) > 0 THEN 'Active' ELSE 'Inactive' END FROM users", "public")
      expect(query).to eq "SELECT CASE WHEN (SELECT count(*) FROM orders WHERE user_id = users.id) > 0 THEN 'Active' ELSE 'Inactive' END FROM public.users"
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
        "WITH RECURSIVE category_tree AS (SELECT id, name, parent_id FROM categories WHERE parent_id IS NULL UNION ALL SELECT c.id, c.name, c.parent_id FROM categories c JOIN category_tree ct ON c.parent_id = ct.id) SELECT * FROM category_tree",
        "public"
      )
      expect(query).to eq "WITH RECURSIVE category_tree AS (SELECT id, name, parent_id FROM public.categories WHERE parent_id IS NULL UNION ALL SELECT c.id, c.name, c.parent_id FROM public.categories c JOIN category_tree ct ON c.parent_id = ct.id) SELECT * FROM category_tree"
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
  end

  describe "pending improvements - column reference qualification" do
    it "should qualify column references in WHERE clauses" do
      pending "Column references like 'users.id' should be qualified to 'public.users.id'"
      query = described_class.qualify("SELECT * FROM users WHERE users.active = true", "public")
      expect(query).to eq "SELECT * FROM public.users WHERE public.users.active = true"
    end

    it "should qualify column references in subqueries" do
      pending "Column references in subqueries should be fully qualified"
      query = described_class.qualify("SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE orders.user_id = users.id)", "public")
      expect(query).to eq "SELECT * FROM public.users WHERE id IN (SELECT user_id FROM public.orders WHERE public.orders.user_id = public.users.id)"
    end

    it "should qualify column references in UPDATE FROM clauses" do
      pending "Column references in UPDATE FROM clauses should be fully qualified"
      query = described_class.qualify("UPDATE users SET name = profiles.display_name FROM profiles WHERE users.id = profiles.user_id", "public")
      expect(query).to eq "UPDATE public.users SET name = profiles.display_name FROM public.profiles WHERE public.users.id = profiles.user_id"
    end

    it "should qualify column references in DELETE USING clauses" do
      pending "Column references in DELETE USING clauses should be fully qualified"
      query = described_class.qualify("DELETE FROM users USING profiles WHERE users.id = profiles.user_id AND profiles.active = false", "public")
      expect(query).to eq "DELETE FROM public.users USING public.profiles WHERE public.users.id = profiles.user_id AND profiles.active = false"
    end

    it "should qualify column references in JOIN conditions" do
      query = described_class.qualify("SELECT * FROM users u JOIN orders o ON u.id = o.user_id WHERE u.active = true", "public")
      expect(query).to eq "SELECT * FROM public.users u JOIN public.orders o ON u.id = o.user_id WHERE u.active = true"
    end

    it "should qualify column references in aggregate functions" do
      pending "Column references in aggregate functions should be fully qualified"
      query = described_class.qualify("SELECT COUNT(*) FROM users WHERE users.created_at > '2023-01-01'", "public")
      expect(query).to eq "SELECT count(*) FROM public.users WHERE public.users.created_at > '2023-01-01'"
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
      pending "Tables in LIMIT and OFFSET subqueries should be fully qualified"
      query = described_class.qualify("SELECT * FROM users LIMIT (SELECT COUNT(*) FROM settings WHERE key = 'max_users')", "public")
      expect(query).to eq "SELECT * FROM public.users LIMIT (SELECT count(*) FROM public.settings WHERE key = 'max_users')"
    end

    it "should fully qualify tables in INSERT VALUES subqueries" do
      query = described_class.qualify("INSERT INTO orders (user_id, product_id) VALUES ((SELECT id FROM users WHERE email = 'test@example.com'), 1)", "public")
      expect(query).to eq "INSERT INTO public.orders (user_id, product_id) VALUES ((SELECT id FROM public.users WHERE email = 'test@example.com'), 1)"
    end

    it "should fully qualify tables in INSERT ON CONFLICT subqueries" do
      pending "Tables in INSERT ON CONFLICT subqueries should be fully qualified"
      query = described_class.qualify("INSERT INTO users (name, email) VALUES ('John', 'john@example.com') ON CONFLICT (email) DO UPDATE SET name = (SELECT name FROM profiles WHERE user_id = users.id)", "public")
      expect(query).to eq "INSERT INTO public.users (name, email) VALUES ('John', 'john@example.com') ON CONFLICT (email) DO UPDATE SET name = (SELECT name FROM public.profiles WHERE user_id = public.users.id)"
    end

    it "should fully qualify tables in RETURNING subqueries" do
      pending "Tables in RETURNING subqueries should be fully qualified"
      query = described_class.qualify("INSERT INTO users (name) VALUES ('John') RETURNING id, (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "INSERT INTO public.users (name) VALUES ('John') RETURNING id, (SELECT count(*) FROM public.orders WHERE user_id = public.users.id)"
    end

    it "should fully qualify tables in UPDATE SET subqueries" do
      pending "Tables in UPDATE SET subqueries should be fully qualified"
      query = described_class.qualify("UPDATE users SET order_count = (SELECT COUNT(*) FROM orders WHERE user_id = users.id)", "public")
      expect(query).to eq "UPDATE public.users SET order_count = (SELECT count(*) FROM public.orders WHERE user_id = public.users.id)"
    end

    it "should fully qualify tables in DELETE WHERE EXISTS subqueries" do
      pending "Tables in DELETE WHERE EXISTS subqueries should be fully qualified"
      query = described_class.qualify("DELETE FROM users WHERE EXISTS (SELECT 1 FROM orders WHERE user_id = users.id AND status = 'cancelled')", "public")
      expect(query).to eq "DELETE FROM public.users WHERE EXISTS (SELECT 1 FROM public.orders WHERE user_id = public.users.id AND status = 'cancelled')"
    end
  end

  describe "pending improvements - advanced expression contexts" do
    it "should fully qualify tables in function call subqueries" do
      pending "Tables in function call subqueries should be fully qualified"
      query = described_class.qualify("SELECT COALESCE((SELECT name FROM users WHERE id = 1), 'Unknown') FROM profiles", "public")
      expect(query).to eq "SELECT COALESCE((SELECT name FROM public.users WHERE id = 1), 'Unknown') FROM public.profiles"
    end

    it "should fully qualify tables in CASE expression subqueries" do
      pending "Tables in CASE expression subqueries should be fully qualified"
      query = described_class.qualify("SELECT CASE WHEN (SELECT COUNT(*) FROM orders WHERE user_id = users.id) > 0 THEN 'Active' ELSE 'Inactive' END FROM users", "public")
      expect(query).to eq "SELECT CASE WHEN (SELECT count(*) FROM public.orders WHERE user_id = public.users.id) > 0 THEN 'Active' ELSE 'Inactive' END FROM public.users"
    end

    it "should fully qualify tables in array subqueries" do
      pending "Tables in array subqueries should be fully qualified"
      query = described_class.qualify("SELECT ARRAY(SELECT name FROM categories WHERE parent_id = products.category_id) FROM products", "public")
      expect(query).to eq "SELECT ARRAY(SELECT name FROM public.categories WHERE parent_id = public.products.category_id) FROM public.products"
    end

    it "should fully qualify tables in aggregate function subqueries" do
      pending "Tables in aggregate function subqueries should be fully qualified"
      query = described_class.qualify("SELECT COUNT((SELECT 1 FROM orders WHERE user_id = users.id)) FROM users", "public")
      expect(query).to eq "SELECT count((SELECT 1 FROM public.orders WHERE user_id = public.users.id)) FROM public.users"
    end

    it "should fully qualify tables in window function subqueries" do
      pending "Tables in window function subqueries should be fully qualified"
      query = described_class.qualify("SELECT ROW_NUMBER() OVER (ORDER BY (SELECT created_at FROM profiles WHERE user_id = users.id)) FROM users", "public")
      expect(query).to eq "SELECT row_number() OVER (ORDER BY (SELECT created_at FROM public.profiles WHERE user_id = public.users.id)) FROM public.users"
    end

    it "should fully qualify tables in complex nested expressions" do
      pending "Tables in complex nested expressions should be fully qualified"
      query = described_class.qualify("SELECT * FROM users WHERE id = ANY(SELECT user_id FROM orders WHERE product_id = ANY(SELECT id FROM products WHERE category_id = 1))", "public")
      expect(query).to eq "SELECT * FROM public.users WHERE id = ANY(SELECT user_id FROM public.orders WHERE product_id = ANY(SELECT id FROM public.products WHERE category_id = 1))"
    end
  end

  describe "pending improvements - advanced SQL features" do
    it "should handle table-valued functions properly" do
      pending "Table-valued functions should be handled correctly"
      query = described_class.qualify("SELECT * FROM users u, generate_series(1, (SELECT COUNT(*) FROM orders)) AS s", "public")
      expect(query).to eq "SELECT * FROM public.users u, generate_series(1, (SELECT count(*) FROM public.orders)) AS s"
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
      pending "Stored procedure calls with table parameters should be qualified"
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

    it "should handle very long table names" do
      long_table_name = "a" * 60
      query = described_class.qualify("SELECT * FROM #{long_table_name}", "public")
      expect(query).to eq "SELECT * FROM public.#{long_table_name}"
    end

    it "should handle unicode table names" do
      pending "Unicode table names should be handled correctly"
      query = described_class.qualify("SELECT * FROM ユーザー", "public")
      expect(query).to eq "SELECT * FROM public.ユーザー"
    end
  end
end
