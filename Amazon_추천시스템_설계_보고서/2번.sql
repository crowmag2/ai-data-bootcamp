WITH base AS (
  SELECT * FROM product_master
  WHERE price IS NOT NULL AND rating_cnt IS NOT NULL
),
catstat AS (
  SELECT cat_leaf, count(*) AS cat_n, median(price) AS cat_median
  FROM base GROUP BY 1 HAVING count(*) >= 10
),
ranked AS (
  SELECT
    b.product_name, b.cat_leaf, c.cat_n, c.cat_median,
    b.price, b.rating, b.rating_cnt,
    percent_rank() OVER (PARTITION BY b.cat_leaf ORDER BY b.price) AS price_pct,
    percent_rank() OVER (PARTITION BY b.cat_leaf ORDER BY b.rating, b.rating_cnt) AS rating_pct
  FROM base b
  JOIN catstat c USING (cat_leaf)
),
filtered AS (
  SELECT * FROM ranked
  WHERE rating >= 4.0
    AND rating_cnt >= 500
    AND price_pct BETWEEN 0.05 AND 0.35
    AND rating_pct >= 0.65
    AND NOT regexp_matches(lower(product_name),
          'cartridge|refill|replacement|spare|combo of|pack of')
),
dedup AS (   -- 가격·평점·리뷰수가 동일한 색상 변형은 대표 1건만
  SELECT * FROM filtered
  QUALIFY row_number() OVER (
    PARTITION BY cat_leaf, price, rating, rating_cnt
    ORDER BY length(product_name), product_name
  ) = 1
)
SELECT
  product_name                     AS 상품명,
  cat_leaf                         AS 카테고리,
  cat_n                            AS 카테고리_상품수,
  round(price)                     AS 가격,
  round(cat_median)                AS 카테고리_중앙값,
  round(price_pct * 100, 1)        AS 가격_백분위,
  rating                           AS 평점,
  CAST(rating_cnt AS BIGINT)       AS 리뷰수,
  round(rating_pct * 100, 1)       AS 평점_백분위,
  round(rating_pct - price_pct, 3) AS value_gap
FROM dedup
QUALIFY row_number() OVER (
  PARTITION BY cat_leaf ORDER BY rating_pct - price_pct DESC
) <= 2
ORDER BY value_gap DESC
LIMIT 30;