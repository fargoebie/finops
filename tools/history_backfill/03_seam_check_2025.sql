-- One-off seam check for the 2025-09-01 seam in focus_billing_history (see README.md, "Seam check").
--
-- Rows from 2025-09-01 on come from the DETAILED export, rows before it from the frozen STANDARD export.
-- Both exports describe September 2025. This query maps the standard export's September 2025 rows
-- and compares them with the table's September 2025 rows (which come from the detailed side).
--
--   cost_grain:   per (billing account, charge category, service): ListCost, ContractedCost, BilledCost
--                 and total credits (sum of x_Credits.Amount).
--   credit_grain: per (billing account, credit Type): sum of credit Amount.
--
-- Pass: no group missing on either side and |delta| < 0.01 on every compared sum.
-- Only the expressions this comparison needs are repeated here, copied verbatim from 02_convert.sql
-- (ChargeCategory, ServiceName, ListCost, ContractedCost, BilledCost, x_Credits); 02_convert.sql stays the
-- single mapping body. Sums are NUMERIC, so they do not depend on summation order.
--
-- Run (se2, scans standard_export_raw plus one month of the history table):
--   bq --project_id=gcp-coe-492507 --location=asia-southeast2 query --nouse_legacy_sql \
--     < tools/history_backfill/03_seam_check_2025.sql

WITH std_rows AS (
  SELECT
    s.billing_account_id                                       AS BillingAccountId,
    CASE s.cost_type
      WHEN 'regular'        THEN 'Usage'
      WHEN 'tax'            THEN 'Tax'
      WHEN 'adjustment'     THEN 'Adjustment'
      WHEN 'rounding_error' THEN 'Adjustment'
    END                                                        AS ChargeCategory,
    s.service.description                                      AS ServiceName,
    CAST(s.cost_at_list AS NUMERIC)                            AS ListCost,
    CAST(s.cost AS NUMERIC)                                    AS ContractedCost,
    CAST(s.cost AS NUMERIC)
      + COALESCE((SELECT SUM(CAST(c.amount AS NUMERIC)) FROM UNNEST(s.credits) AS c), 0) AS BilledCost,
    ARRAY(
      SELECT AS STRUCT c.type AS Type, CAST(c.amount AS NUMERIC) AS Amount
      FROM UNNEST(s.credits) AS c
    )                                                          AS x_Credits
  FROM `gcp-coe-492507.finops_history.standard_export_raw` AS s
  WHERE s.usage_start_time >= TIMESTAMP '2025-09-01'
    AND s.usage_start_time <  TIMESTAMP '2025-10-01'
),

tbl_rows AS (
  SELECT BillingAccountId, ChargeCategory, ServiceName, ListCost, ContractedCost, BilledCost, x_Credits
  FROM `gcp-coe-492507.finops_history.focus_billing_history`
  WHERE ChargePeriodStart >= TIMESTAMP '2025-09-01'
    AND ChargePeriodStart <  TIMESTAMP '2025-10-01'
),

std_cost AS (
  SELECT BillingAccountId, ChargeCategory, COALESCE(ServiceName, '(null)') AS ServiceName,
         SUM(COALESCE(ListCost, 0)) AS list_cost, SUM(ContractedCost) AS contracted_cost,
         SUM(BilledCost) AS billed_cost,
         SUM(COALESCE((SELECT SUM(c.Amount) FROM UNNEST(x_Credits) c), 0)) AS credits
  FROM std_rows GROUP BY 1, 2, 3
),

tbl_cost AS (
  SELECT BillingAccountId, ChargeCategory, COALESCE(ServiceName, '(null)') AS ServiceName,
         SUM(COALESCE(ListCost, 0)) AS list_cost, SUM(ContractedCost) AS contracted_cost,
         SUM(BilledCost) AS billed_cost,
         SUM(COALESCE((SELECT SUM(c.Amount) FROM UNNEST(x_Credits) c), 0)) AS credits
  FROM tbl_rows GROUP BY 1, 2, 3
),

std_credit AS (
  SELECT BillingAccountId, COALESCE(c.Type, '(null)') AS credit_type, SUM(c.Amount) AS credit_amount
  FROM std_rows, UNNEST(x_Credits) c GROUP BY 1, 2
),

tbl_credit AS (
  SELECT BillingAccountId, COALESCE(c.Type, '(null)') AS credit_type, SUM(c.Amount) AS credit_amount
  FROM tbl_rows, UNNEST(x_Credits) c GROUP BY 1, 2
),

cost_diff AS (
  SELECT
    s.BillingAccountId IS NULL AS missing_in_standard,
    t.BillingAccountId IS NULL AS missing_in_table,
    ABS(COALESCE(s.list_cost, 0)       - COALESCE(t.list_cost, 0))       AS d_list,
    ABS(COALESCE(s.contracted_cost, 0) - COALESCE(t.contracted_cost, 0)) AS d_contracted,
    ABS(COALESCE(s.billed_cost, 0)     - COALESCE(t.billed_cost, 0))     AS d_billed,
    ABS(COALESCE(s.credits, 0)         - COALESCE(t.credits, 0))         AS d_credits,
    s.list_cost AS s_list, t.list_cost AS t_list,
    s.contracted_cost AS s_contracted, t.contracted_cost AS t_contracted,
    s.billed_cost AS s_billed, t.billed_cost AS t_billed,
    s.credits AS s_credits, t.credits AS t_credits
  FROM std_cost s
  FULL OUTER JOIN tbl_cost t
    ON  s.BillingAccountId = t.BillingAccountId
    AND s.ChargeCategory   IS NOT DISTINCT FROM t.ChargeCategory
    AND s.ServiceName      = t.ServiceName
),

credit_diff AS (
  SELECT
    s.BillingAccountId IS NULL AS missing_in_standard,
    t.BillingAccountId IS NULL AS missing_in_table,
    ABS(COALESCE(s.credit_amount, 0) - COALESCE(t.credit_amount, 0)) AS d_credit,
    s.credit_amount AS s_credit, t.credit_amount AS t_credit
  FROM std_credit s
  FULL OUTER JOIN tbl_credit t
    ON  s.BillingAccountId = t.BillingAccountId
    AND s.credit_type      = t.credit_type
)

SELECT
  'cost_grain (account x category x service)'                    AS check_name,
  COUNT(*)                                                       AS n_groups,
  COUNTIF(missing_in_standard)                                   AS missing_in_standard,
  COUNTIF(missing_in_table)                                      AS missing_in_table,
  COUNTIF(d_list >= 0.01 OR d_contracted >= 0.01 OR d_billed >= 0.01 OR d_credits >= 0.01) AS groups_over_tol,
  MAX(d_list)                                                    AS max_d_list,
  MAX(d_contracted)                                              AS max_d_contracted,
  MAX(d_billed)                                                  AS max_d_billed,
  MAX(d_credits)                                                 AS max_d_credits,
  CAST(SUM(COALESCE(s_list, 0)) AS STRING)                       AS std_list_total,
  CAST(SUM(COALESCE(t_list, 0)) AS STRING)                       AS tbl_list_total,
  CAST(SUM(COALESCE(s_contracted, 0)) AS STRING)                 AS std_contracted_total,
  CAST(SUM(COALESCE(t_contracted, 0)) AS STRING)                 AS tbl_contracted_total,
  CAST(SUM(COALESCE(s_billed, 0)) AS STRING)                     AS std_billed_total,
  CAST(SUM(COALESCE(t_billed, 0)) AS STRING)                     AS tbl_billed_total,
  CAST(SUM(COALESCE(s_credits, 0)) AS STRING)                    AS std_credits_total,
  CAST(SUM(COALESCE(t_credits, 0)) AS STRING)                    AS tbl_credits_total,
  NOT (COUNTIF(missing_in_standard OR missing_in_table
               OR d_list >= 0.01 OR d_contracted >= 0.01 OR d_billed >= 0.01 OR d_credits >= 0.01) > 0) AS pass
FROM cost_diff
UNION ALL
SELECT
  'credit_grain (account x credit type)',
  COUNT(*),
  COUNTIF(missing_in_standard),
  COUNTIF(missing_in_table),
  COUNTIF(d_credit >= 0.01),
  NULL, NULL, NULL,
  MAX(d_credit),
  NULL, NULL, NULL, NULL, NULL, NULL,
  CAST(SUM(COALESCE(s_credit, 0)) AS STRING),
  CAST(SUM(COALESCE(t_credit, 0)) AS STRING),
  NOT (COUNTIF(missing_in_standard OR missing_in_table OR d_credit >= 0.01) > 0)
FROM credit_diff
