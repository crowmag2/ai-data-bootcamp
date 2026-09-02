WITH txt AS (
  SELECT
    product_name, cat_leaf, rating, rating_cnt, price,
    length(review_content_l) AS txt_len,
    len(regexp_extract_all(review_content_l, 'gift|gifting|present for|birthday')) AS gift_h,
    len(regexp_extract_all(review_content_l, 'kids|child|children|school|student')) AS kid_h,
    len(regexp_extract_all(review_content_l, 'travel|trip|portable|carry')) AS travel_h,
    len(regexp_extract_all(review_content_l, 'office|work from home|wfh|meeting')) AS office_h,
    len(regexp_extract_all(review_content_l, 'durable|sturdy|long lasting|build quality|solid')) AS durable_h
  FROM product_master
  WHERE review_content_l IS NOT NULL
    AND rating_cnt IS NOT NULL
    AND length(review_content_l) >= 1500
    AND rating >= 4.0
    AND rating_cnt >= 500
),
best AS (
  SELECT *,
    greatest(gift_h, kid_h, travel_h, office_h, durable_h) AS top_h,
    gift_h + kid_h + travel_h + office_h + durable_h       AS total_h,
    CASE greatest(gift_h, kid_h, travel_h, office_h, durable_h)
      WHEN gift_h    THEN '선물용'
      WHEN kid_h     THEN '아이·학생용'
      WHEN travel_h  THEN '여행·휴대용'
      WHEN office_h  THEN '사무·재택용'
      ELSE '내구성 중시'
    END AS use_tag
  FROM txt
),
dedup AS (
  SELECT * FROM best
  QUALIFY row_number() OVER (
    PARTITION BY rating, round(rating_cnt / 100) ORDER BY price
  ) = 1
)
SELECT
  use_tag                           AS 용도태그,
  product_name                      AS 상품명,
  cat_leaf                          AS 카테고리,
  round(price)                      AS 가격,
  rating                            AS 평점,
  CAST(rating_cnt AS BIGINT)        AS 리뷰수,
  top_h                             AS 해당용도_언급,
  total_h - top_h                   AS 기타용도_언급,
  txt_len                           AS 리뷰길이,
  round(top_h::DOUBLE / total_h, 2) AS 용도집중도
FROM dedup
WHERE top_h >= 3
QUALIFY row_number() OVER (
  PARTITION BY use_tag ORDER BY top_h DESC, top_h::DOUBLE / total_h DESC, rating_cnt DESC
) <= 5
ORDER BY use_tag, 해당용도_언급 DESC;