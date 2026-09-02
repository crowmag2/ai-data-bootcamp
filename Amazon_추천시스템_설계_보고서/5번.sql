WITH rules(anchor_cat, acc_cat, reason, name_pat) AS (
  VALUES
    ('SmartTelevisions',       'HDMICables',                      '기기 연결',      'hdmi'),
    ('SmartTelevisions',       'TVWall&CeilingMounts',            '벽걸이 설치',    '.'),
    ('SmartTelevisions',       'RCACables',                       '구형 기기 연결', 'rca'),
    ('StandardTelevisions',    'HDMICables',                      '기기 연결',      'hdmi'),
    ('StandardTelevisions',    'TVWall&CeilingMounts',            '벽걸이 설치',    '.'),
    ('Smartphones',            'USBCables',                       '충전·데이터',    'type.?c|lightning|micro.?usb'),
    ('Smartphones',            'WallChargers',                    '충전 어댑터',    '.'),
    ('Smartphones',            'PowerBanks',                      '외출 충전',      '.'),
    ('Smartphones',            'Stands',                          '거치',           '.'),
    ('Smartphones',            'MicroSD',                         '저장공간 확장',  'microsd|micro sd'),
    ('Tablets',                'StylusPens',                      '필기·드로잉',    '.'),
    ('Tablets',                'Stands',                          '거치',           '.'),
    ('Tablets',                'WallChargers',                    '충전 어댑터',    '.'),
    ('WaterFilters&Purifiers', 'WaterPurifierAccessories',        '필터·부속 교체', '.'),
    ('MixerGrinders',          'SmallApplianceParts&Accessories', '여분 용기',      '.'),
    ('JuicerMixerGrinders',    'SmallApplianceParts&Accessories', '여분 용기',      '.'),
    ('ExternalHardDisks',      'HardDiskBags',                    '보관·운반',      '.'),
    ('ExternalHardDisks',      'USBCables',                       '연결 케이블',    'micro.?b|usb 3|type.?c'),
    ('Routers',                'EthernetCables',                  '유선 연결',      'ethernet|rj45|lan|cat6')
),
anchor AS (
  SELECT * FROM (
    SELECT * FROM product_master
    WHERE price >= 1500 AND rating >= 4.2 AND rating_cnt >= 500
    QUALIFY row_number() OVER (
      PARTITION BY cat_leaf, round(rating_cnt / 100) ORDER BY price
    ) = 1
  )
  QUALIFY row_number() OVER (PARTITION BY cat_leaf ORDER BY rating_cnt DESC) <= 3
),
acc AS (
  SELECT * FROM (
    SELECT * FROM product_master
    WHERE rating >= 4.2 AND rating_cnt >= 200
  )
  QUALIFY row_number() OVER (
    PARTITION BY cat_leaf, round(rating_cnt / 100) ORDER BY price
  ) = 1
)
SELECT
  a.product_name                    AS 기준상품,
  round(a.price)                    AS 기준가,
  a.cat_leaf                        AS 기준_카테고리,
  r.reason                          AS 보완_사유,
  b.product_name                    AS 추천_보완재,
  round(b.price)                    AS 보완재가,
  b.cat_leaf                        AS 보완재_카테고리,
  b.rating                          AS 보완재_평점,
  CAST(b.rating_cnt AS BIGINT)      AS 보완재_리뷰수,
  round(b.price / a.price * 100, 1) AS 부가비용_pct
FROM anchor a
JOIN rules  r ON r.anchor_cat = a.cat_leaf
JOIN acc    b ON b.cat_leaf   = r.acc_cat
             AND regexp_matches(lower(b.product_name), r.name_pat)
WHERE b.price < a.price * 0.3
QUALIFY row_number() OVER (
  PARTITION BY a.product_id, b.cat_leaf ORDER BY b.rating DESC, b.rating_cnt DESC
) = 1
ORDER BY a.cat_leaf, a.price DESC, 부가비용_pct
LIMIT 40;