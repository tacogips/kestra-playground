CREATE TABLE IF NOT EXISTS ecommerce_customer_segments (
  business_date date NOT NULL,
  customer_id integer NOT NULL REFERENCES ecommerce_customers(customer_id),
  region text NOT NULL,
  source_segment text NOT NULL,
  completed_order_count integer NOT NULL,
  gross_order_count integer NOT NULL,
  net_sales numeric(14, 2) NOT NULL,
  support_ticket_count integer NOT NULL,
  lifecycle_segment text NOT NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_date, customer_id)
);

DELETE FROM ecommerce_customer_segments
WHERE business_date = '{{ inputs.business_date }}'::date;

INSERT INTO ecommerce_customer_segments (
  business_date,
  customer_id,
  region,
  source_segment,
  completed_order_count,
  gross_order_count,
  net_sales,
  support_ticket_count,
  lifecycle_segment
)
SELECT
  '{{ inputs.business_date }}'::date,
  customers.customer_id,
  customers.region,
  customers.segment,
  COUNT(orders.order_id) FILTER (WHERE orders.status = 'completed')::integer,
  COUNT(orders.order_id)::integer,
  COALESCE(SUM(orders.net_amount) FILTER (WHERE orders.status = 'completed'), 0),
  COUNT(tickets.ticket_id)::integer,
  CASE
    WHEN COALESCE(SUM(orders.net_amount) FILTER (WHERE orders.status = 'completed'), 0) >= 10000
      THEN 'high_value'
    WHEN COUNT(orders.order_id) FILTER (WHERE orders.status = 'completed') >= 2
      THEN 'repeat_buyer'
    WHEN COUNT(tickets.ticket_id) > 0
      THEN 'needs_attention'
    ELSE 'prospect'
  END
FROM ecommerce_customers AS customers
LEFT JOIN ecommerce_orders AS orders
  ON orders.customer_id = customers.customer_id
  AND orders.order_date = '{{ inputs.business_date }}'::date
LEFT JOIN ecommerce_support_tickets AS tickets
  ON tickets.order_id = orders.order_id
  AND tickets.ticket_date = '{{ inputs.business_date }}'::date
GROUP BY customers.customer_id, customers.region, customers.segment;
