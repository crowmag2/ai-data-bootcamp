WITH base AS (
  SELECT * FROM product_master WHERE rating_cnt IS NOT NULL
),
prior AS (
  SELECT avg(rating) AS C, median(rating_cnt) AS m FROM base
),
scored AS (
  SELECT
    a.product_name, a.cat_leaf, a.rating, a.rating_cnt, a.price,
    (a.rating_cnt * a.rating + p.m * p.C) / (a.rating_cnt + p.m) AS bayes_score,
    p.C AS global_avg, p.m AS prior_weight
  FROM base a, prior p
)
SELECT
  product_name                   AS 상품명,
  cat_leaf                       AS 카테고리,
  rating                         AS 원_평점,
  CAST(rating_cnt AS BIGINT)     AS 리뷰수,
  round(bayes_score, 4)          AS 보정_평점,
  round(rating - bayes_score, 4) AS 축소량,
  round(global_avg, 3)           AS 전체평균,
  CAST(prior_weight AS BIGINT)   AS 사전가중
FROM scored
QUALIFY row_number() OVER (PARTITION BY rating, round(rating_cnt / 100) ORDER BY price) = 1
ORDER BY 보정_평점 DESC
LIMIT 30;