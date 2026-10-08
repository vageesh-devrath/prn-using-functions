-- Bengaluru | Dry zone
-- Capacity% & Assort% = 7-day AVG (today - 6 .. today)
-- NA Instances        = 7-day SUM of daily distinct NA SKUs (IST dates)

WITH product_master AS (
  SELECT
    LOWER(TRIM(primary_product_variant_id)) AS sku_id,
    UPPER(TRIM(product_sub_classification)) AS product_subclass
  FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (PARTITION BY LOWER(TRIM(primary_product_variant_id)) ORDER BY updated_on DESC) AS rn
    FROM silver.thor_cms.product_variant_vw
  )
  WHERE rn = 1
),
na_base AS (
  SELECT
    DATE(from_utc_timestamp(b.eventTimestamp, 'Asia/Kolkata')) AS event_date,
    b.eventTimestamp,
    sf.store_id,
    sf.city_name,
    sf.store_name,
    LOWER(TRIM(b.skuId)) AS skuId,
    b.totalQtyRequested,
    b.taskType,
    CASE
      WHEN UPPER(TRIM(pm.product_subclass)) IN ('VEG', 'NON_VEG', 'HAZARDOUS', 'NON_HAZARDOUS', 'MIXED')
      THEN UPPER(TRIM(pm.product_subclass))
      ELSE 'NULL'
    END AS subclass_type,
    CASE
      WHEN (sku.weight_in_gms / 1000.0) >= 5
        OR ((sku.length_in_mm * sku.breadth_in_mm * sku.height_in_mm) / 1000.0) >= 14000
      THEN 'BULKY'
      ELSE 'NON_BULKY'
    END AS bulky_class
  FROM gold.product.bin_suggestion_flat AS b
  LEFT JOIN gold.zepto.store_fact AS sf
    ON LOWER(b.storeId) = LOWER(sf.store_id)
  LEFT JOIN gold.zepto.sku_info AS sku
    ON LOWER(b.skuId) = LOWER(sku.product_variant_id)
  LEFT JOIN product_master AS pm
    ON LOWER(TRIM(b.skuId)) = pm.sku_id
  WHERE
    NOT b.zone IN ('Cafe')
    AND UPPER(TRIM(b.zone)) LIKE 'DRY%'
    AND DATE(from_utc_timestamp(b.eventTimestamp, 'Asia/Kolkata')) BETWEEN CURRENT_DATE - 6 AND CURRENT_DATE
    AND b.suggestionAlgo IN ('DEEP_BIN_SUGGESTION')
    AND b.section = 'A'
    AND UPPER(TRIM(sf.city_name)) IN ('BENGALURU', 'BANGALORE')
),
na_latest_sku_request AS (
  SELECT
    event_date, eventTimestamp, store_id, city_name, store_name,
    skuId, totalQtyRequested, taskType, subclass_type, bulky_class
  FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY event_date, store_id, skuId, totalQtyRequested
        ORDER BY eventTimestamp DESC
      ) AS rn
    FROM na_base
  )
  WHERE rn = 1
),
na_no_suggestion AS (
  SELECT event_date, store_id, city_name, store_name, skuId, subclass_type, bulky_class
  FROM na_latest_sku_request
  WHERE taskType IS NULL OR TRIM(taskType) = '' OR UPPER(TRIM(taskType)) IN ('N/A', 'NA')
),
-- NA counts per store per day
na_daily AS (
  SELECT
    ns.store_id,
    ns.event_date,
    COUNT(DISTINCT ns.skuId) AS na_instances,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'VEG'           AND ns.bulky_class = 'BULKY'     THEN ns.skuId END) AS NA_Veg_Bulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'VEG'           AND ns.bulky_class = 'NON_BULKY' THEN ns.skuId END) AS NA_Veg_NonBulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'NON_VEG'       AND ns.bulky_class = 'BULKY'     THEN ns.skuId END) AS NA_NVeg_Bulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'NON_VEG'       AND ns.bulky_class = 'NON_BULKY' THEN ns.skuId END) AS NA_NVeg_NonBulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'HAZARDOUS'     AND ns.bulky_class = 'BULKY'     THEN ns.skuId END) AS NA_Haz_Bulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'HAZARDOUS'     AND ns.bulky_class = 'NON_BULKY' THEN ns.skuId END) AS NA_Haz_NonBulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'NON_HAZARDOUS' AND ns.bulky_class = 'BULKY'     THEN ns.skuId END) AS NA_NonFood_Bulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'NON_HAZARDOUS' AND ns.bulky_class = 'NON_BULKY' THEN ns.skuId END) AS NA_NonFood_NonBulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'MIXED'         AND ns.bulky_class = 'BULKY'     THEN ns.skuId END) AS NA_Mixed_Bulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'MIXED'         AND ns.bulky_class = 'NON_BULKY' THEN ns.skuId END) AS NA_Mixed_NonBulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'NULL'          AND ns.bulky_class = 'BULKY'     THEN ns.skuId END) AS NA_Null_Bulky,
    COUNT(DISTINCT CASE WHEN ns.subclass_type = 'NULL'          AND ns.bulky_class = 'NON_BULKY' THEN ns.skuId END) AS NA_Null_NonBulky
  FROM na_no_suggestion AS ns
  GROUP BY ns.store_id, ns.event_date
),
-- 7-day SUM of NA instances per store
na_quantum AS (
  SELECT
    store_id,
    SUM(na_instances)        AS sum_na_instances,
    SUM(NA_Veg_Bulky)        AS NA_Veg_Bulky,
    SUM(NA_Veg_NonBulky)     AS NA_Veg_NonBulky,
    SUM(NA_NVeg_Bulky)       AS NA_NVeg_Bulky,
    SUM(NA_NVeg_NonBulky)    AS NA_NVeg_NonBulky,
    SUM(NA_Haz_Bulky)        AS NA_Haz_Bulky,
    SUM(NA_Haz_NonBulky)     AS NA_Haz_NonBulky,
    SUM(NA_NonFood_Bulky)    AS NA_NonFood_Bulky,
    SUM(NA_NonFood_NonBulky) AS NA_NonFood_NonBulky,
    SUM(NA_Mixed_Bulky)      AS NA_Mixed_Bulky,
    SUM(NA_Mixed_NonBulky)   AS NA_Mixed_NonBulky,
    SUM(NA_Null_Bulky)       AS NA_Null_Bulky,
    SUM(NA_Null_NonBulky)    AS NA_Null_NonBulky
  FROM na_daily
  GROUP BY store_id
),
-- 7-day AVG capacity & assortment
store_capacity_assort AS (
  SELECT
    u.store_id,
    COUNT(DISTINCT u.report_date)                                AS util_days,
    ROUND(AVG(u.DRY_CAPACITY_PERCENT) * 100, 2)                  AS dry_capacity_pct,
    ROUND(AVG((u.DRY_SKU * 100.0) / NULLIF(d.Dry, 0)), 2)        AS dry_act_vs_design,
    CASE WHEN AVG(u.DRY_CAPACITY_PERCENT) * 100 > 100 THEN 'Yes' ELSE 'No' END AS dry_utl_breach,
    CASE WHEN AVG(u.DRY_SKU) > MAX(d.Dry)             THEN 'Yes' ELSE 'No' END AS assortment_breach
  FROM gold.ops.8am_util_store AS u
  INNER JOIN gold.zepto.store_fact AS sf
    ON u.store_id = sf.store_id
  LEFT JOIN gold.ops.sheet_dh_design_assort_v1 AS d
    ON u.store_id = d.Store_id
  WHERE
    u.report_date BETWEEN CURRENT_DATE - 6 AND CURRENT_DATE
    AND sf.store_type = 'RETAIL_STORE'
    AND sf.store_phase = 'LIVE'
    AND sf.active_flag = 1
    AND UPPER(TRIM(sf.city_name)) IN ('BENGALURU', 'BANGALORE')
  GROUP BY u.store_id
),
plano_store AS (
  SELECT
    store_id,
    MAX(CASE WHEN key = 'DH_PLANOGRAM_V2_ENABLED' AND value = TRUE THEN 1 ELSE 0 END) AS is_v2,
    MAX(CASE WHEN key = 'DH_PLANOGRAM_ENABLED'    AND value = TRUE THEN 1 ELSE 0 END) AS is_v1
  FROM silver.thor_core_dh.store_config
  WHERE
    key IN ('DH_PLANOGRAM_ENABLED', 'DH_PLANOGRAM_V2_ENABLED')
    AND (section IS NULL OR section <> 'B')
  GROUP BY store_id
),
plano_store_final AS (
  SELECT
    store_id,
    CASE WHEN is_v2 = 1 THEN 'V2' WHEN is_v1 = 1 THEN 'V1' END AS plano_version
  FROM plano_store
  WHERE is_v1 = 1 OR is_v2 = 1
),
bin_util AS (
  SELECT
    bin_name AS bin_type_code,
    capacity AS utilization_pct
  FROM (
    SELECT EXPLODE(FROM_JSON(value, 'MAP<STRING,INT>')) AS (bin_name, capacity)
    FROM silver.thor_core_dh.store_config
    WHERE
      key = 'DH_PLANOGRAM_BIN_TYPE_UTILIZATION_MAP'
      AND store_id = '00000000-0000-0000-0000-000000000000'
      AND section IS NULL
  )
),
bin_base AS (
  SELECT
    ps.store_id,
    ps.plano_version,
    sf.city_name,
    sf.store_name,
    b.id AS bin_id,
    btc.bin_type_code,
    rc.rack_code,
    rc.classification AS rack_class,
    rc.rack_sequence,
    UPPER(TRIM(COALESCE(lv.classification, ''))) AS level_class,
    (btc.length * btc.breadth * btc.height * (COALESCE(bu.utilization_pct, 70) / 100.0)) / 1000.0 AS eff_bin_vol
  FROM plano_store_final AS ps
  JOIN silver.thor_core_dh.bins AS b
    ON ps.store_id = b.store_id
  JOIN gold.zepto.store_fact AS sf
    ON b.store_id = sf.store_id
  LEFT JOIN silver.thor_core_dh.bin_type_master AS btc
    ON b.bin_type_master_id = btc.id
  LEFT JOIN silver.thor_core_dh.rack AS rc
    ON b.rack_id = rc.id AND b.store_id = rc.store_id
  LEFT JOIN silver.thor_core_dh.level AS lv
    ON b.level_id = lv.id AND b.store_id = lv.store_id
  LEFT JOIN silver.thor_core_dh.zone AS z
    ON b.zone_id = z.id AND b.store_id = z.store_id
  LEFT JOIN bin_util AS bu
    ON btc.bin_type_code = bu.bin_type_code
  WHERE
    b.current_status = 'Active'
    AND b.bin_type = 'Good'
    AND UPPER(TRIM(z.storage_type)) = 'DRY'
    AND NOT btc.bin_type_code IS NULL
    AND NOT COALESCE(rc.rack_code, '') IN ('1_1', '1_ZZ', '1_SS', '1_UU', '2_UU')
    AND UPPER(TRIM(sf.city_name)) IN ('BENGALURU', 'BANGALORE')
),
current_eligible_bins AS (
  SELECT *
  FROM bin_base
  WHERE NOT bin_type_code IN ('D_FnV_1', 'D_FnV_2', 'Deep', 'D_FNV_CRATE', 'D_BTL_1')
),
denom AS (
  SELECT store_id, city_name, store_name, SUM(eff_bin_vol) AS total_dry_vol
  FROM current_eligible_bins
  GROUP BY store_id, city_name, store_name
),
subclass_tagged AS (
  SELECT
    store_id,
    bin_id,
    eff_bin_vol,
    CASE
      WHEN (plano_version = 'V1' AND bin_type_code IN ('D_LSS', 'D_LSS_600', 'D_XL_1', 'PALLET') AND level_class = 'HAZARDOUS')
        OR (plano_version = 'V2' AND bin_type_code IN ('HDR_HAZ', 'LSS_HAZ'))
      THEN 'HAZARDOUS'
      WHEN (plano_version = 'V1' AND NOT bin_type_code IN ('D_LSS', 'D_LSS_600', 'D_XL_1', 'PALLET') AND level_class = 'HAZARDOUS')
        OR (plano_version = 'V2' AND bin_type_code = 'A1_HAZ_400')
      THEN 'HAZARDOUS'
      WHEN level_class IN ('VEG', 'NON_VEG', 'NON_HAZARDOUS', 'MIXED')
      THEN level_class
      ELSE 'NULL'
    END AS subclass_classification,
    CASE
      WHEN bin_type_code IN ('D_LSS', 'D_LSS_600', 'D_XL_1', 'PALLET', 'HDR_HAZ', 'LSS_HAZ')
      THEN 'BULKY'
      ELSE 'NON_BULKY'
    END AS bulkiness_type
  FROM current_eligible_bins
),
current_pct AS (
  SELECT
    d.store_id,
    d.city_name,
    d.store_name,
    t.subclass_classification,
    t.bulkiness_type,
    ROUND(SUM(t.eff_bin_vol) * 100.0 / NULLIF(d.total_dry_vol, 0), 2) AS current_pct
  FROM denom AS d
  LEFT JOIN subclass_tagged AS t
    ON d.store_id = t.store_id
  GROUP BY d.store_id, d.city_name, d.store_name, d.total_dry_vol, t.subclass_classification, t.bulkiness_type
),
/* AVERAGE COMMINGLING: SUM(SKUs) / COUNT(Bins) */
commingling_blocked_bin AS (
  SELECT DISTINCT store_id, bin_id
  FROM silver.thor_core_dh.dh_planogram
  WHERE is_active = TRUE
),
commingling_bin_master AS (
  SELECT
    b.store_id,
    b.id AS bin_id
  FROM silver.thor_core_dh.bins AS b
  JOIN gold.zepto.store_fact AS sf
    ON b.store_id = sf.store_id
  LEFT JOIN commingling_blocked_bin AS bb
    ON b.store_id = bb.store_id AND b.id = bb.bin_id
  LEFT JOIN silver.thor_core_dh.rack AS r
    ON b.rack_id = r.id AND b.store_id = r.store_id
  LEFT JOIN silver.thor_core_dh.zone AS z
    ON r.zone_id = z.id AND r.store_id = z.store_id
  WHERE
    b.current_status = 'Active'
    AND b.bin_type = 'Good'
    AND UPPER(TRIM(z.storage_type)) = 'DRY'
    AND z.zone_code <> 'Print'
    AND bb.bin_id IS NULL
    AND UPPER(TRIM(sf.city_name)) IN ('BENGALURU', 'BANGALORE')
),
commingling_curr_inventory AS (
  SELECT
    bm.store_id,
    bm.bin_id,
    COUNT(DISTINCT LOWER(inv.sku_id)) AS current_comm
  FROM commingling_bin_master AS bm
  LEFT JOIN silver.thor_core.inventory AS inv
    ON bm.store_id = inv.store_id
    AND bm.bin_id = inv.bin_id
    AND inv.available > 0
    AND NOT inv._____operation_type IN ('d')
  GROUP BY bm.store_id, bm.bin_id
),
commingling_summary AS (
  SELECT
    bm.store_id,
    ROUND(SUM(COALESCE(ci.current_comm, 0)) * 1.0 / NULLIF(COUNT(bm.bin_id), 0), 2) AS good_comm_incl_empty
  FROM commingling_bin_master AS bm
  LEFT JOIN commingling_curr_inventory AS ci
    ON bm.store_id = ci.store_id AND bm.bin_id = ci.bin_id
  GROUP BY bm.store_id
)
SELECT
  ps.plano_version                         AS `Plano Version`,
  sf.city_name                             AS `City`,
  sf.store_name                            AS `store_name`,
  ca.util_days                             AS `Util Days`,
  ca.dry_capacity_pct                      AS `Avg Dry Capacity% (7D)`,
  ca.dry_act_vs_design                     AS `Avg Dry Assort% (7D)`,
  ca.dry_utl_breach                        AS `Dry Capacity Breach`,
  ca.assortment_breach                     AS `Dry Assort Breach`,
  COALESCE(na.sum_na_instances, 0)         AS `NA Instances (7D Sum)`,
  COALESCE(comm.good_comm_incl_empty, 0.0) AS `Good Comm.`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'VEG'           AND cp.bulkiness_type = 'NON_BULKY' THEN cp.current_pct END), 0.0) AS `Veg_NonBulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'NON_VEG'       AND cp.bulkiness_type = 'NON_BULKY' THEN cp.current_pct END), 0.0) AS `NVeg_NonBulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'NON_HAZARDOUS' AND cp.bulkiness_type = 'NON_BULKY' THEN cp.current_pct END), 0.0) AS `NonFood_NonBulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'HAZARDOUS'     AND cp.bulkiness_type = 'NON_BULKY' THEN cp.current_pct END), 0.0) AS `Haz_NonBulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'MIXED'         AND cp.bulkiness_type = 'NON_BULKY' THEN cp.current_pct END), 0.0) AS `Mixed_NonBulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'NULL'          AND cp.bulkiness_type = 'NON_BULKY' THEN cp.current_pct END), 0.0) AS `Null_NonBulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'VEG'           AND cp.bulkiness_type = 'BULKY'     THEN cp.current_pct END), 0.0) AS `Veg_Bulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'HAZARDOUS'     AND cp.bulkiness_type = 'BULKY'     THEN cp.current_pct END), 0.0) AS `Haz_Bulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'NON_HAZARDOUS' AND cp.bulkiness_type = 'BULKY'     THEN cp.current_pct END), 0.0) AS `NonFood_Bulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'NON_VEG'       AND cp.bulkiness_type = 'BULKY'     THEN cp.current_pct END), 0.0) AS `NVeg_Bulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'NULL'          AND cp.bulkiness_type = 'BULKY'     THEN cp.current_pct END), 0.0) AS `Null_Bulky`,
  COALESCE(MAX(CASE WHEN cp.subclass_classification = 'MIXED'         AND cp.bulkiness_type = 'BULKY'     THEN cp.current_pct END), 0.0) AS `Mixed_Bulky`,
  COALESCE(MAX(na.NA_NVeg_NonBulky), 0)    AS `NA_NVeg_NonBulky`,
  COALESCE(MAX(na.NA_Haz_NonBulky), 0)     AS `NA_Haz_NonBulky`,
  COALESCE(MAX(na.NA_Veg_NonBulky), 0)     AS `NA_Veg_NonBulky`,
  COALESCE(MAX(na.NA_NonFood_NonBulky), 0) AS `NA_NonFood_NonBulky`,
  COALESCE(MAX(na.NA_NVeg_Bulky), 0)       AS `NA_NVeg_Bulky`,
  COALESCE(MAX(na.NA_Veg_Bulky), 0)        AS `NA_Veg_Bulky`,
  COALESCE(MAX(na.NA_NonFood_Bulky), 0)    AS `NA_NonFood_Bulky`,
  COALESCE(MAX(na.NA_Haz_Bulky), 0)        AS `NA_Haz_Bulky`
FROM plano_store_final AS ps
JOIN gold.zepto.store_fact AS sf
  ON ps.store_id = sf.store_id
LEFT JOIN current_pct AS cp
  ON ps.store_id = cp.store_id
LEFT JOIN na_quantum AS na
  ON ps.store_id = na.store_id
LEFT JOIN store_capacity_assort AS ca
  ON ps.store_id = ca.store_id
LEFT JOIN commingling_summary AS comm
  ON ps.store_id = comm.store_id
WHERE
  UPPER(TRIM(sf.city_name)) IN ('BENGALURU', 'BANGALORE')
GROUP BY
  ps.plano_version,
  sf.city_name,
  sf.store_name,
  ca.util_days,
  ca.dry_capacity_pct,
  ca.dry_act_vs_design,
  ca.dry_utl_breach,
  ca.assortment_breach,
  na.sum_na_instances,
  comm.good_comm_incl_empty
ORDER BY
  sf.city_name,
  sf.store_name;
