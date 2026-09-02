CREATE OR REPLACE VIEW product_master AS
SELECT product_id, product_name, category, cat_path, cat_top, cat_leaf,
       price, list_price, disc_rate, rating, rating_cnt,
       user_ids, review_title_l, review_content_l, product_link
FROM (
  SELECT *, row_number() OVER (
    PARTITION BY lower(trim(product_name))
    ORDER BY rating_cnt DESC NULLS LAST, product_id
  ) AS rn
  FROM amazon_clean
  WHERE rating IS NOT NULL
)
WHERE rn = 1;

SELECT
  (SELECT count(*) FROM amazon)         AS 원본,
  (SELECT count(*) FROM amazon_clean)   AS clean,
  (SELECT count(*) FROM product_master) AS master;