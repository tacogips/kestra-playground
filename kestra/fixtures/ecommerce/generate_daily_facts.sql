DELETE FROM ecommerce_support_tickets WHERE ticket_date = '{{ inputs.business_date }}'::date;
DELETE FROM ecommerce_payments
WHERE order_id IN (
  SELECT order_id FROM ecommerce_orders WHERE order_date = '{{ inputs.business_date }}'::date
);
DELETE FROM ecommerce_order_items
WHERE order_id IN (
  SELECT order_id FROM ecommerce_orders WHERE order_date = '{{ inputs.business_date }}'::date
);
DELETE FROM ecommerce_orders WHERE order_date = '{{ inputs.business_date }}'::date;
DELETE FROM ecommerce_inventory_snapshots WHERE snapshot_date = '{{ inputs.business_date }}'::date;

WITH order_seed AS (
  SELECT
    ('{{ inputs.business_date }}'::date - DATE '2020-01-01')::bigint * 100000 + order_no AS order_id,
    '{{ inputs.business_date }}'::date AS order_date,
    1 + (order_no * 17 % 120) AS customer_id,
    (ARRAY['web', 'mobile_app', 'marketplace'])[1 + (order_no % 3)] AS channel,
    CASE
      WHEN order_no % 31 = 0 THEN 'cancelled'
      WHEN order_no % 17 = 0 THEN 'returned'
      ELSE 'completed'
    END AS status,
    1 + (order_no * 7 % 8) AS product_id,
    1 + (order_no % 4) AS quantity,
    CASE WHEN order_no % 9 = 0 THEN 0.10 ELSE 0.00 END AS discount_rate
  FROM generate_series(1, 80) AS order_no
),
priced AS (
  SELECT
    order_seed.*,
    products.unit_price,
    ROUND(products.unit_price * order_seed.quantity, 2) AS gross_amount
  FROM order_seed
  JOIN ecommerce_products AS products USING (product_id)
),
inserted_orders AS (
  INSERT INTO ecommerce_orders (
    order_id,
    order_date,
    customer_id,
    channel,
    status,
    gross_amount,
    discount_amount,
    net_amount
  )
  SELECT
    order_id,
    order_date,
    customer_id,
    channel,
    status,
    gross_amount,
    ROUND(gross_amount * discount_rate, 2),
    ROUND(gross_amount * (1 - discount_rate), 2)
  FROM priced
  RETURNING order_id
)
INSERT INTO ecommerce_order_items (
  order_item_id,
  order_id,
  product_id,
  quantity,
  unit_price,
  line_amount
)
SELECT
  priced.order_id * 10 + 1,
  priced.order_id,
  priced.product_id,
  priced.quantity,
  priced.unit_price,
  priced.gross_amount
FROM priced
JOIN inserted_orders USING (order_id);

INSERT INTO ecommerce_payments (
  payment_id,
  order_id,
  payment_method,
  payment_status,
  paid_amount,
  processed_at
)
SELECT
  order_id,
  order_id,
  (ARRAY['credit_card', 'konbini', 'wallet', 'bank_transfer'])[1 + (order_id % 4)],
  CASE WHEN status = 'completed' THEN 'captured' ELSE 'voided' END,
  CASE WHEN status = 'completed' THEN net_amount ELSE 0 END,
  order_date::timestamptz + make_interval(hours => (order_id % 24)::integer)
FROM ecommerce_orders
WHERE order_date = '{{ inputs.business_date }}'::date;

INSERT INTO ecommerce_inventory_snapshots (
  snapshot_date,
  product_id,
  stock_on_hand,
  reserved_quantity,
  reorder_point
)
SELECT
  '{{ inputs.business_date }}'::date,
  product_id,
  35 + ((product_id * 23 + EXTRACT(DOY FROM '{{ inputs.business_date }}'::date)::integer) % 120),
  3 + (product_id * 5 % 18),
  30
FROM ecommerce_products;

INSERT INTO ecommerce_support_tickets (
  ticket_id,
  order_id,
  ticket_date,
  reason,
  priority,
  resolved
)
SELECT
  order_id + 900000000,
  order_id,
  order_date,
  (ARRAY['delivery_delay', 'return_request', 'payment_question', 'damaged_item'])[1 + (order_id % 4)],
  CASE WHEN order_id % 19 = 0 THEN 'high' ELSE 'normal' END,
  order_id % 5 <> 0
FROM ecommerce_orders
WHERE order_date = '{{ inputs.business_date }}'::date
  AND order_id % 6 = 0;
