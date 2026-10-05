-- Metabase Native Question templates: copy ONE named query into each question.
-- {{variables}} and [[optional clauses]] are Metabase syntax, not plain psql SQL.
-- Basic variables (single value): attribution_model = Text, REQUIRED in SQL.
-- Configure linear as the default in the Metabase question/dashboard filter UI;
-- SQL itself supplies no attribution_model default.
-- channel_name = Text, optional; campaign_id = Number, optional;
-- acquisition_month = Date, optional/single date (any date within the month).
-- Do not quote {{variables}}; Metabase supplies properly typed values.
-- See docs/METABASE_SETUP.md and docs/DASHBOARD_SPEC.md for card/filter mappings.
-- No DDL, writes, automatic materialized refresh, or benchmark statements.

-- QUERY CO1: Campaign Overview summary (seven Number cards share this SQL).
-- Select the appropriate field in each card's Number visualization settings.
-- Model is required BEFORE aggregating, so spend/events cannot be tripled.
WITH totals AS (
    SELECT COALESCE(SUM(spend), 0) AS total_spend,
           COALESCE(SUM(attributed_revenue), 0) AS total_attributed_revenue,
           COALESCE(SUM(impressions), 0) AS total_impressions,
           COALESCE(SUM(clicks), 0) AS total_clicks,
           COALESCE(SUM(attributed_conversions), 0) AS total_attributed_conversions
    FROM campaign_performance
    WHERE attribution_model = {{attribution_model}}
      [[AND channel_name = {{channel_name}}]]
      [[AND campaign_id = {{campaign_id}}]]
)
SELECT total_spend, total_attributed_revenue,
       total_attributed_revenue / NULLIF(total_spend, 0) AS overall_roas,
       (total_attributed_revenue - total_spend) / NULLIF(total_spend, 0) AS overall_roi,
       total_impressions, total_clicks, total_attributed_conversions,
       total_clicks::NUMERIC / NULLIF(total_impressions, 0) AS overall_ctr
FROM totals;

-- QUERY CO2: Channel performance table and three compatible chart series.
-- Campaign-filtered channel totals must be rolled up from campaign_performance.
-- channel_performance cannot express a campaign filter; without that filter,
-- these additive totals/ratios agree with channel_performance for the model.
WITH totals AS (
    SELECT channel_id, channel_name,
           SUM(impressions) AS impressions, SUM(clicks) AS clicks,
           SUM(spend) AS spend, SUM(attributed_conversions) AS attributed_conversions,
           SUM(attributed_revenue) AS attributed_revenue
    FROM campaign_performance
    WHERE attribution_model = {{attribution_model}}
      [[AND channel_name = {{channel_name}}]]
      [[AND campaign_id = {{campaign_id}}]]
    GROUP BY channel_id, channel_name
)
SELECT channel_name, impressions, clicks,
       clicks::NUMERIC / NULLIF(impressions, 0) AS ctr,
       spend, attributed_conversions, attributed_revenue,
       spend / NULLIF(attributed_conversions, 0) AS cpa,
       attributed_revenue / NULLIF(spend, 0) AS roas,
       (attributed_revenue - spend) / NULLIF(spend, 0) AS roi
FROM totals
ORDER BY roas DESC NULLS LAST, channel_name;

-- QUERY CO3: Campaign performance table / attributed-conversion bar chart.
SELECT campaign_id, campaign_name, channel_name, spend,
       attributed_conversions, attributed_revenue, cpa, roas, roi,
       campaign_name || ' [' || campaign_id::TEXT || ']' AS campaign_label
FROM campaign_performance
WHERE attribution_model = {{attribution_model}}
  [[AND channel_name = {{channel_name}}]]
  [[AND campaign_id = {{campaign_id}}]]
ORDER BY attributed_conversions DESC, campaign_id;

-- QUERY MC1: Channel comparison table / three grouped bar charts.
-- All three models remain visible. Never sum revenue/credit/spend across models.
SELECT channel_name, attribution_model, attributed_conversions,
       attributed_revenue, roas, roi
FROM attribution_model_comparison
WHERE 1 = 1
  [[AND channel_name = {{channel_name}}]]
ORDER BY channel_name, attribution_model;

-- QUERY MC2: Revenue spread between models by channel (no invented winners).
SELECT channel_name, MIN(attributed_revenue) AS lowest_model_revenue,
       MAX(attributed_revenue) AS highest_model_revenue,
       MAX(attributed_revenue) - MIN(attributed_revenue) AS model_revenue_spread
FROM attribution_model_comparison
WHERE 1 = 1
  [[AND channel_name = {{channel_name}}]]
GROUP BY channel_id, channel_name
ORDER BY model_revenue_spread DESC, channel_name;

-- QUERY MC3: Campaign/model comparison detail, retaining all three models.
SELECT campaign_id, campaign_name, channel_name, attribution_model,
       attributed_conversions, attributed_revenue, roas, roi,
       campaign_name || ' [' || campaign_id::TEXT || ']' AS campaign_label
FROM campaign_performance
WHERE 1 = 1
  [[AND channel_name = {{channel_name}}]]
ORDER BY channel_name, campaign_id, attribution_model;

-- QUERY AE1: Acquisition economics summary (five Number cards share this SQL).
-- Overall CAC is spend/users, not AVG(channel cac); users are exclusive by source.
WITH totals AS (
    SELECT COALESCE(SUM(acquired_users), 0) AS acquired_users,
           COALESCE(SUM(total_lifetime_revenue), 0) AS total_lifetime_revenue,
           COALESCE(SUM(spend), 0) AS spend
    FROM channel_ltv
    WHERE 1 = 1
      [[AND channel_name = {{channel_name}}]]
), metrics AS (
    SELECT totals.*,
           total_lifetime_revenue / NULLIF(acquired_users, 0) AS average_ltv,
           spend / NULLIF(acquired_users, 0) AS cac
    FROM totals
)
SELECT acquired_users, total_lifetime_revenue, average_ltv, cac,
       average_ltv / NULLIF(cac, 0) AS ltv_cac_ratio, spend
FROM metrics;

-- QUERY AE2: Channel economics table / average LTV, CAC, LTV:CAC bar charts.
SELECT channel_name, acquired_users, total_lifetime_revenue,
       average_ltv, median_ltv, spend, cac, ltv_cac_ratio
FROM channel_ltv
WHERE 1 = 1
  [[AND channel_name = {{channel_name}}]]
ORDER BY ltv_cac_ratio DESC NULLS LAST, channel_name;

-- QUERY AE3: Campaign LTV/CAC comparison table.
SELECT campaign_id, campaign_name, channel_name, acquired_users,
       total_lifetime_revenue, average_ltv, median_ltv, spend, cac, ltv_cac_ratio
FROM campaign_ltv
WHERE 1 = 1
  [[AND channel_name = {{channel_name}}]]
ORDER BY ltv_cac_ratio DESC NULLS LAST, campaign_id;

-- QUERY CA1: Cohort table, including each horizon's eligible denominator.
-- Default = LIVE view. To use the optimized snapshot, replace the FROM relation
-- in BOTH CA1 and CA2 with acquisition_cohort_materialized after manual refresh
-- and reconciliation. Neither query itself refreshes anything.
SELECT acquisition_month, channel_name, acquired_users, observation_end,
       eligible_users_d7, eligible_users_d30, eligible_users_d60, eligible_users_d90,
       average_ltv_d7, average_ltv_d30, average_ltv_d60, average_ltv_d90,
       revenue_d7, revenue_d30, revenue_d60, revenue_d90
FROM acquisition_cohort_ltv
WHERE 1 = 1
  [[AND channel_name = {{channel_name}}]]
  [[AND acquisition_month = DATE_TRUNC('month', CAST({{acquisition_month}} AS DATE))::DATE]]
ORDER BY acquisition_month, channel_name;

-- QUERY CA2: Long-format line chart, one series per UTC month + channel.
-- D90 rows remain NULL when no user is mature; never zero-fill missing horizons.
-- Populations differ by horizon: a plotted average can decrease legitimately.
WITH cohorts AS (
    SELECT * FROM acquisition_cohort_ltv
    WHERE 1 = 1
      [[AND channel_name = {{channel_name}}]]
      [[AND acquisition_month = DATE_TRUNC('month', CAST({{acquisition_month}} AS DATE))::DATE]]
)
SELECT c.acquisition_month, c.channel_name,
       TO_CHAR(c.acquisition_month, 'YYYY-MM') || ' | ' || c.channel_name AS cohort_series,
       h.horizon_days, h.eligible_users, h.average_ltv,
       h.cumulative_revenue, c.observation_end
FROM cohorts AS c
CROSS JOIN LATERAL (VALUES
    (7, c.eligible_users_d7, c.average_ltv_d7, c.revenue_d7),
    (30, c.eligible_users_d30, c.average_ltv_d30, c.revenue_d30),
    (60, c.eligible_users_d60, c.average_ltv_d60, c.revenue_d60),
    (90, c.eligible_users_d90, c.average_ltv_d90, c.revenue_d90)
) AS h(horizon_days, eligible_users, average_ltv, cumulative_revenue)
ORDER BY c.acquisition_month, c.channel_name, h.horizon_days;

-- QUERY F1: Saved lookup question supplying the Channel dropdown values.
SELECT channel_name FROM channel_ltv ORDER BY channel_name;

-- QUERY F2: Saved lookup question supplying Campaign IDs with friendly labels.
-- IDs avoid assuming campaign names are unique. Lookups do not cascade filters.
SELECT campaign_id,
       campaign_name || ' | ' || channel_name || ' [' || campaign_id::TEXT || ']' AS campaign_label
FROM campaign_ltv
ORDER BY channel_name, campaign_id;

-- QUERY F3: Available UTC acquisition months (reference table for Date picker).
SELECT DISTINCT acquisition_month FROM acquisition_cohort_ltv ORDER BY acquisition_month;
