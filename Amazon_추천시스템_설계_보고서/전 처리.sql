CREATE OR REPLACE VIEW amazon_clean AS
SELECT
  product_id,
  product_name,
  category,
  str_split(category, '|')     AS cat_path,
  str_split(category, '|')[1]  AS cat_top,
  str_split(category, '|')[-1] AS cat_leaf,
  TRY_CAST(regexp_replace(discounted_price,    '[^0-9.]', '', 'g') AS DOUBLE) AS price,
  TRY_CAST(regexp_replace(actual_price,        '[^0-9.]', '', 'g') AS DOUBLE) AS list_price,
  TRY_CAST(regexp_replace(discount_percentage, '[^0-9.]', '', 'g') AS DOUBLE) / 100.0 AS disc_rate,
  TRY_CAST(regexp_replace(rating,              '[^0-9.]', '', 'g') AS DOUBLE) AS rating,
  TRY_CAST(regexp_replace(rating_count,        '[^0-9]',  '', 'g') AS DOUBLE) AS rating_cnt,
  user_id                 AS user_ids,
  lower(review_title)     AS review_title_l,
  lower(review_content)   AS review_content_l,
  product_link
FROM amazon;

SELECT
  count(*)                                    AS n,
  count(rating)                               AS rating_ok,
  count(price)                                AS price_ok,
  count(rating_cnt)                           AS cnt_ok,
  round(min(rating), 2) AS r_min, round(max(rating), 2) AS r_max,
  round(max(price))     AS p_max
FROM amazon_clean;