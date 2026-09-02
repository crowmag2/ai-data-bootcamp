WITH ur AS (
  SELECT m.product_id, trim(u) AS uid
  FROM product_master m, UNNEST(str_split(m.user_ids, ',')) AS t(u)
  WHERE trim(u) <> ''
),
prod_n AS (
  SELECT product_id, count(DISTINCT uid) AS n_users FROM ur GROUP BY 1
),
pairs AS (
  SELECT x.product_id AS p1, y.product_id AS p2, count(DISTINCT x.uid) AS common
  FROM ur x
  JOIN ur y ON x.uid = y.uid AND x.product_id < y.product_id
  GROUP BY 1, 2
),
spec AS (
  SELECT product_id,
    list_distinct(list_filter(
      str_split(regexp_replace(lower(product_name), '[^a-z0-9]', ' ', 'g'), ' '),
      x -> length(x) >= 3)) AS tk,
    list_sort(list_distinct(
      regexp_extract_all(product_name, '[0-9]+(\.[0-9]+)?'))) AS nums
  FROM product_master
),
cand AS (
  SELECT
    pr.p1, pr.p2, pr.common,
    pr.common::DOUBLE / (n1.n_users + n2.n_users - pr.common) AS user_jaccard,
    len(list_intersect(s1.tk, s2.tk))::DOUBLE
      / len(list_distinct(list_concat(s1.tk, s2.tk)))         AS name_jaccard,
    list_concat(
      list_filter(s1.tk, x -> NOT list_contains(s2.tk, x)),
      list_filter(s2.tk, x -> NOT list_contains(s1.tk, x))
    )                                                          AS diff_tk
  FROM pairs pr
  JOIN prod_n n1 ON n1.product_id = pr.p1
  JOIN prod_n n2 ON n2.product_id = pr.p2
  JOIN spec   s1 ON s1.product_id = pr.p1
  JOIN spec   s2 ON s2.product_id = pr.p2
  WHERE pr.common >= 2
    AND s1.nums = s2.nums
),
gated AS (
  SELECT * FROM cand
  WHERE name_jaccard >= 0.5
    AND len(list_filter(diff_tk, x -> list_contains(
          ['black','blue','red','white','pink','green','grey','gray','silver',
           'gold','golden','purple','mauve','beige','brown','orange','yellow',
           'ivory','charcoal','midnight','navy','teal','cyan','magenta','maroon',
           'rose','coral','olive','lavender','burgundy','bronze','copper',
           'champagne','graphite','platinum','turquoise','crimson','scarlet',
           'emerald','sapphire','amber','jet','active','matte','glossy',
           'metallic','electric','cherry','blossom','taffy','furious','martian',
           'mercurial','moonlight','stardust','aqua','onyx','pearl','slate',
           'sandstone','carbon'], x))) >= 1
    AND len(list_filter(diff_tk, x -> list_contains(
          ['type','micro','pro','max','plus','lite','series','braided',
           'unbreakable','tough','combo','pack','ultra','mini','wireless',
           'nylon','premium','advanced'], x))) = 0
    AND len(list_filter(diff_tk,
          x -> regexp_matches(x, '[a-z]') AND regexp_matches(x, '[0-9]'))) = 0
),
bidir AS (
  SELECT p1 AS anchor, p2 AS sibling, common, user_jaccard, name_jaccard, diff_tk FROM gated
  UNION ALL
  SELECT p2 AS anchor, p1 AS sibling, common, user_jaccard, name_jaccard, diff_tk FROM gated
),
scored AS (
  SELECT
    d.anchor, d.common, d.user_jaccard, d.name_jaccard, d.diff_tk,
    a.product_name AS anchor_name, a.cat_leaf, a.price AS a_price,
    a.rating AS a_rating, CAST(a.rating_cnt AS BIGINT) AS a_cnt,
    b.product_name AS sib_name, b.price AS b_price, b.rating AS b_rating,
    a.price - b.price AS saving
  FROM bidir d
  JOIN product_master a ON a.product_id = d.anchor
  JOIN product_master b ON b.product_id = d.sibling
  WHERE a.rating_cnt >= 100 AND b.rating_cnt >= 100
    AND a.product_name <> b.product_name
    AND a.price > b.price
)
SELECT
  anchor_name                      AS 보고있는_상품,
  cat_leaf                         AS 카테고리,
  round(a_price)                   AS 현재가,
  a_rating                         AS 평점,
  a_cnt                            AS 리뷰수,
  sib_name                         AS 추천_동일사양_옵션,
  round(b_price)                   AS 옵션가,
  round(saving)                    AS 절약액,
  round(saving / a_price * 100, 1) AS 절약률_pct,
  diff_tk                          AS 차이_토큰,
  round(name_jaccard, 3)           AS name_jaccard
FROM scored
QUALIFY row_number() OVER (PARTITION BY anchor ORDER BY saving DESC) = 1
ORDER BY 절약률_pct DESC, 절약액 DESC
LIMIT 30;