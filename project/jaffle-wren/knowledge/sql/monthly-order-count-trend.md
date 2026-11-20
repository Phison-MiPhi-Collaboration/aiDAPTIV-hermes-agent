---
nl: monthly order count trend
sql: SELECT date_trunc('month', order_date) AS month, count(order_id) AS order_count
  FROM orders GROUP BY month ORDER BY month;
source: user
---
