INSERT INTO ecommerce_products (product_id, sku, category, product_name, unit_price, active)
VALUES
  (1, 'APP-TSHIRT-BLK', 'apparel', 'Black Logo T-Shirt', 2800, true),
  (2, 'APP-HOODIE-GRY', 'apparel', 'Gray Hoodie', 7200, true),
  (3, 'HOME-MUG-WHT', 'home', 'Ceramic Coffee Mug', 1600, true),
  (4, 'HOME-TOTE-NAT', 'home', 'Canvas Tote Bag', 2200, true),
  (5, 'ELEC-CHARGER-65W', 'electronics', '65W USB-C Charger', 5400, true),
  (6, 'ELEC-CABLE-2M', 'electronics', 'Braided USB-C Cable', 1800, true),
  (7, 'BEAUTY-SOAP-YUZU', 'beauty', 'Yuzu Handmade Soap', 900, true),
  (8, 'FOOD-COFFEE-200G', 'food', 'Single Origin Coffee 200g', 2400, true)
ON CONFLICT (product_id) DO UPDATE SET
  sku = EXCLUDED.sku,
  category = EXCLUDED.category,
  product_name = EXCLUDED.product_name,
  unit_price = EXCLUDED.unit_price,
  active = EXCLUDED.active;

INSERT INTO ecommerce_customers (customer_id, segment, region, signup_date)
SELECT
  customer_id,
  (ARRAY['new', 'returning', 'vip'])[1 + (customer_id % 3)],
  (ARRAY['hokkaido', 'kanto', 'chubu', 'kansai', 'kyushu'])[1 + (customer_id % 5)],
  DATE '2025-01-01' + (customer_id % 365)
FROM generate_series(1, 120) AS customer_id
ON CONFLICT (customer_id) DO UPDATE SET
  segment = EXCLUDED.segment,
  region = EXCLUDED.region,
  signup_date = EXCLUDED.signup_date;
