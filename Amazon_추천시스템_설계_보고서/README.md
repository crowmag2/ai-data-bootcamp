# Amazon 데이터셋 기반 추천 시스템 설계 보고서

---

## 0. 데이터 준비 및 품질 검증

### 0-1. 데이터셋의 구조적 문제

Amazon Sales Dataset(1,465행)은 분석 전 세 가지 문제를 해결해야 했다.

| 문제 | 내용 | 영향 |
| --- | --- | --- |
| 전 컬럼 VARCHAR | `rating`, `rating_count`, `discounted_price` 등 수치형 컬럼이 모두 문자열. 가격에 `₹`·콤마, 할인율에 `%` 포함 | 캐스팅 없이 `ORDER BY rating_count DESC` 실행 시 문자열 정렬로 순위가 왜곡됨 |
| 불량 값 혼입 | `rating` 값이 `\|` 인 행 존재 | `CAST` 사용 시 쿼리 전체 실패 → `TRY_CAST` 필요 |
| 상품 중복 등재 | 동일 상품명이 서로 다른 `product_id` 로 중복 수록 | 집계·평균·JOIN 결과가 특정 상품 쪽으로 편향 |

### 0-2. 3계층 전처리 구조

```
amazon (원본, 전 컬럼 VARCHAR)
  └─ amazon_clean      : 정규식 기반 수치 캐스팅 + 카테고리 경로 분해
       └─ product_master : rating 불량 행 제거 + 상품명 중복 제거  ← 모든 추천 쿼리의 기준
```

**amazon_clean** — 통화기호·콤마·퍼센트를 정규식으로 제거한 뒤 `TRY_CAST` 하여, 눈에 보이지 않는 문자(BOM, non-breaking space, 따옴표 잔여물)까지 무력화했다.

```sql
CREATE OR REPLACE VIEW amazon_clean AS
SELECT
  product_id, product_name, category,
  str_split(category, '|')     AS cat_path,
  str_split(category, '|')[1]  AS cat_top,
  str_split(category, '|')[-1] AS cat_leaf,
  TRY_CAST(regexp_replace(discounted_price,    '[^0-9.]', '', 'g') AS DOUBLE) AS price,
  TRY_CAST(regexp_replace(actual_price,        '[^0-9.]', '', 'g') AS DOUBLE) AS list_price,
  TRY_CAST(regexp_replace(discount_percentage, '[^0-9.]', '', 'g') AS DOUBLE) / 100.0 AS disc_rate,
  TRY_CAST(regexp_replace(rating,              '[^0-9.]', '', 'g') AS DOUBLE) AS rating,
  TRY_CAST(regexp_replace(rating_count,        '[^0-9]',  '', 'g') AS DOUBLE) AS rating_cnt,
  user_id               AS user_ids,
  lower(review_title)   AS review_title_l,
  lower(review_content) AS review_content_l,
  product_link
FROM amazon;
```

**product_master** — 상품명을 파티션 키로 삼아 중복을 제거했다. 상품명 기준으로 묶으면 `product_id` 중복과 동일명 다중 등재가 한 번에 처리된다.

```sql
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
```

### 0-3. 품질 검증 결과

| 단계 | 행 수 | 제거 내역 |
| --- | --- | --- |
| 원본 `amazon` | 1,465 | — |
| `amazon_clean` | 1,465 | 0 (필터 없이 캐스팅만 수행) |
| `product_master` | **1,336** | 129 (rating 불량 1건 + 상품명 중복 128건) |

캐스팅 검산 결과 `rating` 파싱 성공 1,464건, `price` 1,465건, `rating_count` 1,463건이며 평점 범위는 2.0～5.0, 최고가 ₹77,990으로 모두 정상 범위였다.

**중복 128건은 전체의 8.7%에 해당한다.** 이를 제거하지 않았다면 추천 시스템 1의 전체 평균, 2의 카테고리 중앙값, 4의 리뷰 텍스트 집계가 모두 중복 상품 쪽으로 기울었을 것이다. 실제로 추천 시스템 3에서는 중복 제거 전후 상품 쌍 수가 305 → 271로 감소했으며, 사라진 34쌍은 중복 등재로 생성된 허위 쌍이었다.

---

## 추천 시스템 1

### 1. 추천 시스템 이름

**"리뷰가 충분히 쌓인, 진짜 인기 상품이에요"**

### 2. 추천 시스템의 테마

리뷰 수로 정렬하거나 평점으로 정렬하는 단순 인기도 추천에는 구조적 결함이 있다. 리뷰 3개에 평점 5.0인 상품이 리뷰 2만 개에 평점 4.5인 상품보다 상위에 노출되는 것이다. 전자의 평점은 표본이 부족해 신뢰할 수 없다.

이 추천 시스템은 **베이지안 축소(Bayesian shrinkage)** 를 적용해 리뷰 수가 적은 상품의 평점을 전체 평균 쪽으로 끌어당긴다. 표본 신뢰도를 순위에 직접 반영하는 방식이다.

```
보정 평점 = (n × r + m × C) / (n + m)
```

- `n`: 해당 상품 리뷰 수, `r`: 해당 상품 평점
- `C`: 전체 상품 평균 평점 (사전 평균)
- `m`: 전체 리뷰 수의 중앙값 (사전 가중치)

리뷰 수 `n` 이 `m` 보다 크면 자기 평점이 지배하고, 작으면 전체 평균에 수렴한다.

### 3. 구현 로직

```sql
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
```

**주요 로직 설명**

- `prior` CTE에서 전체 평균 평점 `C` = 4.091, 리뷰 수 중앙값 `m` = 4,703을 계산해 사전 분포로 사용
- `축소량` = 원 평점 − 보정 평점. 이 컬럼이 축소가 실제로 작동했음을 증명하는 근거
- `QUALIFY` 절의 `round(rating_cnt / 100)` — 색상 변형 상품은 평점과 리뷰 수를 공유하지만 값이 1 단위로 미세하게 어긋나는 경우가 있어(예: 74,976 / 74,977), 100 단위로 뭉개서 동일 상품 변형을 하나로 통합

### 4. 결과

> 실행 결과 전문: [`1번.csv`](1번.csv) · 실행 쿼리: [`1번.sql`](1번.sql)

축소량 컬럼이 로직의 작동을 명확히 보여준다.

| 상품 | 원 평점 | 리뷰 수 | 축소량 |
| --- | --- | --- | --- |
| SanDisk Extreme SD 64GB | 4.5 | 205,052 | **0.0092** |
| AmazonBasics HDMI Cable 3-Foot | 4.4 | 426,973 | **0.0034** |
| Sony Bravia 65인치 4K TV | 4.7 | 5,935 | 0.2692 |
| Instant Pot Air Fryer Vortex 2QT | 4.8 | 3,964 | **0.3847** |

리뷰 20만～43만 건 상품은 보정 폭이 0.01 미만으로 자기 평점을 거의 유지한다. 반면 평점 4.8이지만 리뷰가 3,964건인 에어프라이어는 0.38점이나 하향 조정되어, 원 평점만으로는 1위였을 상품이 25위로 내려갔다. 표본 신뢰도가 순위에 반영된 것이다.

---

## 추천 시스템 2

### 1. 추천 시스템 이름

**"가성비템: 같은 카테고리에서 값싸고 평 좋은 상품이에요"**
- 실무적 우선 순위 높음: 개인적으로 추천. 실무적으로 카테고리 내에서 가격이 싼 가성비 상품이므로 판매가 제일 많이 이루어질 가능성이 높음.
- 몰에서 카테고리 입장 시 상단에 공간 할애하여 직접 추천 가능
- 락인 효과와 몰 정체성 전달, 구매 경험 늘리기에 제일 직접적인 실무 쿼리라고 생각함.
- 실제로 몰에서는 가격이 싼 상품 위주로 정렬하고 그 중에서 품질이 적절한 상품이 압도적으로 구매건수가 많이 잡히고 베스트 상품이 되는 경우가 있으므로
- 다이소 가성비템 처럼 마케팅에 유용
- 비싼 제품을 파는 것도 좋지만, 구매 건수를 늘리는 것과 구매자를 늘리는 것도 중요.
- 사용자 락인과 가성비템을 주기적으로 구매 유도하여 락인 효과 가능 (실제로 본인도 가성비템을 주기적으로 구매함)
- 평소에 같은 기능의 상대적으로 비싼 제품을 써온 사용자가 평점이 좋고 가격 경쟁력이 있는 제품을 새로 알게 된다면 지속적으로 몰에 찾아오고 몰에 대한 인식도 바뀌는 경우가 많음
- 사용자가 일단 모여야 그 후에 비싼 상품도 팔리는 것이므로, 럭셔리 몰이 아닌 아마존의 경우 가성비템도 중요하다고 생각함
- 다이소 인기 상품들의 트렌드를 인터넷에서 검색해보면 강력한 트렌드로 자리 잡았음을 알 수 있음

### 2. 추천 시스템의 테마

`discount_percentage` 필드를 그대로 신뢰하는 할인율 추천은 정가를 부풀리면 얼마든지 조작 가능하다. 또한 평점 4.0 이상 같은 절대 기준은 카테고리별 평점 인플레 차이를 무시한다. USB 케이블의 4.2점과 스마트TV의 4.2점은 같은 의미가 아니다.

이 추천 시스템은 **가격과 평점을 모두 카테고리 내 백분위로 환산**한 뒤, 두 백분위의 격차가 큰 상품을 추천한다. "표시 할인율"이 아니라 "동급 상품 대비 실질 저렴함"을, "절대 평점"이 아니라 "동급 상품 대비 상대 품질"을 측정한다.

```
value_gap = 평점 백분위 - 가격 백분위
```

### 3. 구현 로직

```sql
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
dedup AS (
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
```

**각 조건의 설계 근거**

| 조건 | 근거 |
| --- | --- |
| `price_pct >= 0.05` | 최하위 5%는 본체가 아닌 소모품·부속품일 가능성이 높음. 초기 설계에서 정수기 카테고리(중앙값 ₹6,797)에 교체용 카트리지(₹698)가 1위로 올라오는 오류가 발생해 도입 |
| `price_pct <= 0.35` | 카테고리 가격 하위 35% 이내여야 "저렴하다"는 주장이 성립 |
| `rating_pct >= 0.65` | 평점을 절대값 대신 카테고리 상대 순위로 판정하여 카테고리별 평점 인플레 차이를 보정 |
| `regexp_matches` 제외 | 소모품 키워드로 부속품을 2차 차단 |
| `cat_n >= 10` | 표본 10개 미만 카테고리에서는 백분위가 무의미 |
| `QUALIFY <= 2` | 카테고리당 최대 2건. 도입 전 USBCables가 상위 30개 중 6개를 점유 |
| `dedup` CTE | 가격·평점·리뷰 수가 동일한 색상 변형은 대표 1건만 노출 |

### 4. 결과

> 실행 결과 전문: [`2번.csv`](2번.csv) · 실행 쿼리: [`2번.sql`](2번.sql)

상위 30건이 20개 카테고리에 분산되었고, `value_gap` 은 0.400～0.909로 충분히 벌어져 순위가 유의미하다.

| 상품 | 카테고리 | 가격 | 카테고리 중앙값 | 가격 백분위 | 평점 백분위 | value_gap |
| --- | --- | --- | --- | --- | --- | --- |
| Philips GC1905 다림질기 | SteamIrons | ₹1,614 | ₹3,047 | 9.1% | **100%** | 0.909 |
| boAt Bassheads 102 이어폰 | In-Ear | ₹399 | ₹889 | 14.0% | **100%** | 0.860 |
| AmazonBasics USB 2.0 연장 케이블 | USBCables | ₹199 | ₹299 | 22.8% | 98.1% | 0.753 |

1위 Philips GC1905는 다림질기 카테고리에서 **가격은 하위 9.1%인데 평점은 카테고리 1위**다. 리뷰 37,974건으로 표본도 충분하다. "가장 싼 편에 속하면서 평점은 최고"라는 추천 문구가 두 개의 백분위 수치로 직접 증명된다.

---

## 추천 시스템 3

### 1. 추천 시스템 이름

**"똑같은 상품인데, 색상만 다르면 더 저렴해요"**

### 2. 추천 시스템의 테마

이 추천 시스템은 **협업 필터링 시도 → 실패 진단 → 설계 전환**의 4단계 검증을 거쳐 도출되었다. 설계 과정 자체가 데이터의 성질을 규명하는 과정이었으므로 순서대로 기술한다.

> **협업 필터링(Collaborative Filtering)** — 상품의 속성(가격·카테고리·스펙)을 보지 않고, "같은 사용자들이 함께 선택했다"는 행동 기록만으로 상품 간 유사도를 구하는 추천 방법론이다. 여러 사용자의 행동 데이터가 서로 협력해 추천을 만든다는 뜻에서 붙은 이름이다.

**1단계 — 아이템 기반 협업 필터링 시도.** `user_id` 필드를 콤마로 분해하면 유저-상품 관계를 복원할 수 있다. 유저 9,050명, 유저-상품 쌍 11,503건으로 유저당 상품 수 1.271이므로 상품 간 유저 겹침이 존재했다. 자카드 유사도로 "이 상품을 본 사람이 함께 본 상품"을 구현했다.

**2단계 — 실패 진단.** 유저 겹침 상품 쌍 652건 중 **296건(45%)이 유저 집합이 완전히 동일**했고, `common >= 2` 인 305건에서 그 296건을 빼면 부분 겹침 쌍은 9건뿐이었다. 그 9건의 상품명을 확인하니 Samsung EVO Plus 64GB↔128GB, boAt Wave Lite Active Black↔Scarlet Red 등 **모두 같은 상품의 색상·용량 변형**이었다. 이 데이터셋의 `user_id` 는 변형 리스팅끼리 유저 목록을 공유하는 구조이므로, 유저 겹침은 "다른 상품 간 유사성"이 아니라 "동일 상품 라인"을 의미한다. 범용 협업 필터링은 불가능하다.

**3단계 — 품질 통제 조건 확인.** 상품명 토큰 자카드 게이트(0.5 이상)를 통과한 189쌍을 검증하니 **189쌍 전체에서 평점이 완전히 일치**했다. 예외가 한 건도 없었다. 즉 이 관계는 품질이 통제된 상태에서 가격만 비교할 수 있는 조건을 만족한다.

**4단계 — 사양 차이 배제.** 가격차가 있는 133쌍을 추천에 그대로 쓰자 55인치 TV를 보는 사용자에게 32인치 TV를, 256GB 메모리카드에 64GB를 "₹23,500 절약"으로 추천하는 결과가 나왔다. 같은 제품 라인에서 싼 물건은 사양이 낮기 때문에 싼 것이므로, 절약이 가짜였다. 상품명의 **숫자 토큰 집합 일치**와 **차집합 토큰이 색상어로만 구성**될 것을 요구해 사양 차이를 완전히 배제했다.

최종 컨셉은 **사양·품질·평점이 완전히 통제된 상태에서 색상만 다른 더 저렴한 옵션**을 제시하는 것이다. 사용자가 이 추천을 수락할 때 발생하는 손실이 0이므로 트레이드오프 없는 순수 절약이다.

### 3. 구현 로직

```sql
WITH ur AS (   -- user_id 분해: 유저-상품 관계 복원
  SELECT m.product_id, trim(u) AS uid
  FROM product_master m, UNNEST(str_split(m.user_ids, ',')) AS t(u)
  WHERE trim(u) <> ''
),
prod_n AS (
  SELECT product_id, count(DISTINCT uid) AS n_users FROM ur GROUP BY 1
),
pairs AS (     -- 유저를 공유하는 상품 쌍
  SELECT x.product_id AS p1, y.product_id AS p2, count(DISTINCT x.uid) AS common
  FROM ur x
  JOIN ur y ON x.uid = y.uid AND x.product_id < y.product_id
  GROUP BY 1, 2
),
spec AS (      -- 상품명 토큰 집합 + 사양 숫자 집합
  SELECT product_id,
    list_distinct(list_filter(
      str_split(regexp_replace(lower(product_name), '[^a-z0-9]', ' ', 'g'), ' '),
      x -> length(x) >= 3)) AS tk,
    list_sort(list_distinct(
      regexp_extract_all(product_name, '[0-9]+(\.[0-9]+)?'))) AS nums
  FROM product_master
),
cand AS (      -- 사양 숫자 일치 쌍만 + 상품명 차집합 토큰 추출
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
gated AS (     -- 차집합 토큰이 색상어로만 구성된 쌍만 통과
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
bidir AS (     -- 관계가 대칭이므로 양방향 확장
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
```

**3중 게이트의 역할**

| 게이트 | 배제 대상 | 실제 배제 사례 |
| --- | --- | --- |
| 사양 숫자 집합 일치 (`s1.nums = s2.nums`) | 용량·크기·규격 등급 차이 | Acer 55인치→32인치, SanDisk 256GB→64GB, MI 20000mAh→10000mAh |
| 차집합에 색상어 1개 이상 | 색상 변형이 아닌 관계 | — (양성 조건) |
| 차집합에 사양 키워드·모델 코드 없음 | 숫자는 같으나 단어가 사양을 바꾸는 경우 | pTron TB301→MB301(Type-C↔Micro USB), OnePlus 32Y1S→32Y1, Belkin Braided→일반 |

모델 코드 배제 조건(`영문+숫자 혼합 토큰`)이 특히 효과적이었다. 모델 코드는 사양이 다르면 반드시 변경되므로, 정규식 한 줄로 등급 차이를 포괄적으로 차단한다.

### 4. 결과

> 실행 결과 전문: [`3번.csv`](3번.csv) · 실행 쿼리: [`3번.sql`](3번.sql)

단계별 필터링 결과는 다음과 같다.

| 단계 | 쌍 수 |
| --- | --- |
| 유저 겹침 상품 쌍 (`common >= 2`) | 271 |
| 상품명 토큰 자카드 게이트 통과 | 189 |
| ㄴ 이 중 평점이 완전히 일치하는 쌍 | **189 (100%)** |
| ㄴ 이 중 가격차가 존재하는 쌍 | 133 (70.4%) |
| 사양 숫자 + 색상어 게이트 통과 후 최종 추천 | **12** |

최종 12건 전체가 순수 색상 변형이다.

| 보고 있는 상품 | 추천 옵션 | 절약 | 차이 토큰 |
| --- | --- | --- | --- |
| boAt Bassheads 242 (Active Black) ₹599 | (Blue) ₹455 | ₹144 (24.0%) | `[black, active, blue]` |
| Noise Pulse Buzz (Jet Black) ₹2,499 | (Rose Pink) ₹1,999 | ₹500 (20.0%) | `[jet, black, pink, rose]` |
| Noise ColorFit Pulse Grand (Electric Blue) ₹1,999 | (Jet Black) ₹1,599 | ₹400 (20.0%) | `[electric, blue, black, jet]` |
| boAt Wave Electra (Charcoal Black) ₹2,999 | (Cherry Blossom) ₹2,499 | ₹500 (16.7%) | `[charcoal, black, blossom, cherry]` |

`차이_토큰` 컬럼을 결과에 노출한 것이 핵심이다. 두 상품명의 차집합이 색상어만으로 구성되어 있음이 눈으로 확인되므로, 구현 로직과 출력 결과가 서로를 검증한다.

**설계상의 트레이드오프 명시** — 게이트를 보수적으로 설정한 결과 Elv 스탠드(`aluminium`/`aluminum` 철자 차이)나 boAt Bassheads 100(`headphones`/`earphones` 표기 차이) 같은 실제 색상 변형도 일부 탈락했다. 거짓 추천 1건이 놓친 추천 5건보다 사용자 신뢰에 치명적이라는 판단에 따라 재현율보다 정밀도를 우선했다.

---

## 추천 시스템 4

### 1. 추천 시스템 이름

**"이런 용도로 쓴다는 후기가 많은 상품이에요"**

### 2. 추천 시스템의 테마

평점과 리뷰 수는 "얼마나 좋은가"만 알려주고 "무엇에 좋은가"는 알려주지 않는다. 선물용으로 산 사람과 아이 학습용으로 산 사람은 같은 4.2점 상품에서 전혀 다른 가치를 얻는다.

이 추천 시스템은 **리뷰 본문에서 용도 키워드 클러스터를 추출**해 상품에 용도 태그를 부여한다. 정량 지표가 아닌 리뷰 텍스트를 정보원으로 삼는다는 점에서 다른 네 시스템과 축이 완전히 다르다.

용도 클러스터는 5종을 정의했다.

| 태그 | 키워드 패턴 |
| --- | --- |
| 선물용 | `gift`, `gifting`, `present for`, `birthday` |
| 아이·학생용 | `kids`, `child`, `children`, `school`, `student` |
| 여행·휴대용 | `travel`, `trip`, `portable`, `carry` |
| 사무·재택용 | `office`, `work from home`, `wfh`, `meeting` |
| 내구성 중시 | `durable`, `sturdy`, `long lasting`, `build quality`, `solid` |

**초기 설계의 실패와 수정** — 최초에는 부정 표현(`stopped working`, `defective` 등)의 밀도로 품질 리스크를 측정하려 했으나, 상위 30건 전체에서 부정 신호가 0건이었다. `review_content` 필드가 상품당 리뷰 8건만 담고 있어 부정 표현이 출현할 확률 자체가 낮았기 때문이다. 더 심각한 문제는 텍스트 길이로 정규화한 결과 **리뷰 텍스트가 짧은 상품이 상위를 점령**한 것이다. 1위 상품은 리뷰 본문이 199자에 불과했다. 이에 길이 정규화를 폐기하고 **최소 텍스트 길이 게이트(1,500자) + 절대 언급 횟수** 방식으로 전환했다.

### 3. 구현 로직

```sql
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
    AND length(review_content_l) >= 1500   -- 텍스트 부족 상품 배제
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
```

**주요 로직 설명**

- `greatest()` 로 5개 클러스터 중 최다 언급 용도를 판정하고 `CASE greatest(...) WHEN` 구문으로 태그를 부여
- `용도집중도` = 해당 용도 언급 / 전체 용도 언급. 특정 용도로 얼마나 쏠려 있는지를 나타내며, 태그 부여의 신뢰도 지표로 기능
- `top_h >= 3` — 언급 3회 미만은 우연일 가능성이 높아 배제
- 키워드 설계 시 `desk` 를 제외했다. `desk` 는 `desktop` 에 부분 일치하여 "for PC Desktop"이라는 제품 설명 문구가 재택근무 신호로 오분류되는 문제가 있었다

### 4. 결과

> 실행 결과 전문: [`4번.csv`](4번.csv) · 실행 쿼리: [`4번.sql`](4번.sql)

| 용도 태그 | 상품 | 카테고리 | 해당 용도 언급 | 용도 집중도 |
| --- | --- | --- | --- | --- |
| 아이·학생용 | Camlin Elegante 만년필 | FountainPens | 9 | 0.56 |
| 아이·학생용 | Xiaomi Pad 5 | Tablets | 6 | 0.86 |
| 사무·재택용 | Logitech H111 헤드셋 | On-Ear | 9 | 0.75 |
| 사무·재택용 | TP-Link Archer A6 라우터 | Routers | 3 | 1.00 |
| 여행·휴대용 | Ambrane 20000mAh 보조배터리 | PowerBanks | 9 | 0.56 |
| 내구성 중시 | Philips GC1905 다림질기 | SteamIrons | 7 | 0.88 |

Camlin 만년필이 학생용, Logitech 헤드셋과 TP-Link 라우터가 재택근무용, 보조배터리가 여행용으로 분류된 결과는 상품 특성과 정확히 부합한다. 특히 Philips 다림질기는 내구성 언급 7회에 집중도 0.88로, 추천 시스템 2에서도 가성비 1위였던 상품이 서로 다른 두 방법론에서 각각 최상위로 검증되었다.

**한계** — `선물용` 태그는 결과에 나타나지 않았다. 선물 관련 언급이 최다 용도인 상품이 하나도 없었으며, 이는 이 데이터셋 리뷰의 특성이다. 5개 클러스터 중 4개만 유효한 결과를 산출했다.

---

## 추천 시스템 5

### 1. 추천 시스템 이름

**"이 제품 사실 때 같이 챙기면 좋아요"**

### 2. 추천 시스템의 테마

앞의 네 시스템이 모두 "무엇을 살까"에 답한다면, 이 시스템은 **이미 고른 상품에 붙는 크로스셀**을 담당한다. 고가 본체 구매 시점에 소액 보완재를 함께 제시하여 구매 완결성을 높인다.

**경로 기반 추론의 실패** — 최초 설계는 카테고리 경로 상위 2단계(`cat_path[1]`, `cat_path[2]`)를 공유하는 저가 상품을 보완재로 간주했다. 그러나 `Home&Kitchen > Kitchen&HomeAppliances` 같은 광역 버킷 때문에 **로봇청소기에 린트 셰이버, 에어프라이어에 믹서 여분 병**이 추천되었다. 결과 40건 중 35건이 동일한 보완재 2개였다. 경로 2단계는 너무 넓고, 3단계까지 일치시키면 동일 카테고리가 되어버린다.

**설계 전환** — 데이터셋에 제품 호환·보완 정보가 존재하지 않으므로, **보완 관계는 규칙으로 선언하고 규칙 내 상품 선택은 데이터가 결정**하도록 역할을 분리했다. 실무의 큐레이션 기반 크로스셀과 동일한 구조다. 규칙 테이블에는 카테고리 쌍뿐 아니라 **상품명 정규식 조건**을 함께 선언하여 규격 불일치까지 차단했다.

### 3. 구현 로직

```sql
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
```

**주요 로직 설명**

- `rules` CTE의 `name_pat` 컬럼이 규격을 제약한다. 도입 전에는 USBCables 카테고리에서 평점이 가장 높은 상품이 선택되어 **스마트폰에 A-to-B 프린터 케이블**이, MicroSD 카테고리에서 **풀사이즈 SD 카드**가 추천되었다
- `b.price < a.price * 0.3` — 보완재는 본체 가격의 30% 미만이어야 한다는 상대 조건. 절대 가격 상한 대신 사용해 카테고리별 가격대 차이에 자동 대응
- `PARTITION BY a.product_id, b.cat_leaf` — 기준상품당 보완재 카테고리별 1개만 노출. 도입 전 HDMI 케이블 3종이 한 TV의 추천 슬롯을 모두 점유
- `ScreenProtectors`, 케이스류는 규칙에서 의도적으로 제외했다. 데이터셋에 기종 호환 정보가 없어 **안드로이드 폰에 iPhone 강화유리**가 추천되는 문제를 막을 수 없었기 때문이다. 같은 이유로 `RemoteControls` 규칙도 제거했다(Redmi TV에 "for All Sony TV" 리모컨이 매칭됨)

### 4. 결과

> 실행 결과 전문: [`5번.csv`](5번.csv) · 실행 쿼리: [`5번.sql`](5번.sql)

기준 카테고리 7종, 보완 사유 12종으로 분산된 결과가 산출되었다. 앵커 단계에 색상 변형 제거를 추가한 결과, 동일 상품의 색상 변형이 점유했던 슬롯이 다른 카테고리로 배분되어 다양성이 개선되었다.

| 기준상품 | 기준가 | 보완 사유 | 추천 보완재 | 보완재가 | 부가비용 |
| --- | --- | --- | --- | --- | --- |
| Samsung Galaxy S20 FE 5G | ₹37,990 | 충전 어댑터 | Goldmedal 유니버설 트래블 어댑터 | ₹99 | **0.3%** |
| Samsung Galaxy S20 FE 5G | ₹37,990 | 저장공간 확장 | SanDisk Extreme microSD 128GB | ₹1,329 | 3.5% |
| Redmi 50인치 4K TV | ₹32,999 | 기기 연결 | HDMI 2.1 인증 케이블 | ₹999 | 3.0% |
| Seagate One Touch 2TB HDD | ₹5,799 | 보관·운반 | AirCase Rugged 하드 케이스 | ₹299 | 5.2% |
| Sujata Powermatic Plus 믹서 | ₹6,525 | 여분 용기 | Sujata 처트니 스틸 자 400ml | ₹688 | 10.5% |
| TP-Link Archer C6 라우터 | ₹2,499 | 유선 연결 | Quantum RJ45 이더넷 패치 케이블 | ₹238 | 9.5% |

`보완_사유` 컬럼이 결과에 포함되어 "왜 이 조합인가"가 출력 자체에 명시된다. 특히 Sujata 믹서 → Sujata 처트니 자, 정수기 → 정수기 부속품처럼 동일 브랜드·직접 부속 관계가 정확히 매칭되었다.

**한계** — `Routers` 카테고리 앵커에 RESONATE RouterUPS(라우터가 아닌 UPS)가 포함되었다. 원본 데이터의 카테고리 라벨 오류이며 SQL 수준에서는 상품명 정규식으로만 대응 가능하다. TV 벽걸이 마운트가 24인치 TV에 추천된 사례도 있었는데, 마운트 지원 크기(32～55인치)를 데이터에서 구조적으로 얻을 수 없어 발생한 문제다.

---

## 종합: 5개 시스템의 설계 축

| 시스템 | 정보원 | 핵심 기법 | 답하는 질문 |
| --- | --- | --- | --- |
| 1 | 평점 + 리뷰 수 | 베이지안 축소 | 통계적으로 신뢰할 만한 인기 상품은? |
| 2 | 가격 + 평점 (카테고리 상대) | `percent_rank()` 이중 백분위 | 동급 대비 값싸고 평 좋은 상품은? |
| 3 | 유저-상품 그래프 + 상품명 토큰 | 자카드 유사도 + 3중 게이트 | 똑같은 상품인데 더 싼 옵션은? |
| 4 | 리뷰 본문 텍스트 | 키워드 클러스터 분류 | 이 용도로 검증된 상품은? |
| 5 | 카테고리 + 큐레이션 규칙 | 규칙 테이블 조인 + 상대 가격 | 이 상품과 함께 살 것은? |

다섯 시스템은 정보원과 기법이 모두 다르며, 조건절 변경으로 파생된 관계가 아니다. 시스템 1·2는 정량 지표를, 3은 관계 그래프를, 4는 비정형 텍스트를, 5는 도메인 규칙을 각각 활용한다.

## 전체 프로젝트의 한계 및 향후 과제

1. **시계열 정보 부재** — 데이터셋에 타임스탬프가 없어 "시간대별 인기 상품", "최근 급상승 상품" 등의 추천은 원리적으로 구현 불가능하다.
2. **개인화 불가** — `user_id` 는 변형 리스팅 간 공유되는 구조여서 실질적인 개인 구매 이력을 복원할 수 없다. 따라서 5개 시스템 모두 상품 단위 추천이며 사용자 단위 개인화는 별도의 행동 로그 데이터가 필요하다.
3. **카테고리 라벨의 한계** — `cat_leaf` 가 본체와 액세서리를 분리하지 않아(정수기 카테고리에 교체 카트리지, RemoteControls에 리모컨 케이스) 일부 부속품이 잔존한다. 완전한 해결에는 상품명 기반 제품 유형 분류기가 필요하다.
4. **호환성 정보 부재** — 기종 호환 정보가 없어 추천 시스템 5에서 케이스·강화유리 등 모델 특정 액세서리를 추천 대상에서 제외해야 했다. 별도의 호환성 매핑 테이블 구축이 선행 과제다.

## 부록: 실행 순서 및 첨부 파일

쿼리와 실행 결과는 본 저장소에 파일로 첨부하였다. 아래 순서대로 실행하면 보고서의 모든 결과를 재현할 수 있다.

| 순서 | 내용 | 쿼리 | 결과 |
| --- | --- | --- | --- |
| 1 | `amazon_clean` 뷰 생성 (수치 캐스팅·카테고리 분해) | [`전 처리.sql`](<전 처리.sql>) | — |
| 2 | `product_master` 뷰 생성 (중복 제거) | [`중복 제거 마스터 뷰.sql`](<중복 제거 마스터 뷰.sql>) | — |
| 3 | 행 수 품질 검증 (1,465 → 1,336) | — | [`전처리.csv`](전처리.csv) |
| 4 | 추천 1 · 베이지안 인기도 | [`1번.sql`](1번.sql) | [`1번.csv`](1번.csv) |
| 5 | 추천 2 · 카테고리 백분위 가성비 | [`2번.sql`](2번.sql) | [`2번.csv`](2번.csv) |
| 6 | 추천 3 · 동일 사양 최저가 옵션 | [`3번.sql`](3번.sql) | [`3번.csv`](3번.csv) |
| 7 | 추천 4 · 리뷰 기반 용도 태그 | [`4번.sql`](4번.sql) | [`4번.csv`](4번.csv) |
| 8 | 추천 5 · 보완재 크로스셀 | [`5번.sql`](5번.sql) | [`5번.csv`](5번.csv) |

실행 환경은 브라우저 DuckDB(WASM)이며, 뷰 2개는 세션당 한 번만 생성하면 이후 추천 쿼리 5개를 순서와 무관하게 실행할 수 있다.
