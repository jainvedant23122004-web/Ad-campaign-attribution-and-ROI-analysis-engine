-- Manual read-only inspection queries. No benchmarks or source-data changes.
-- All views cover all loaded data; filter by model before totaling baseline metrics.

SELECT * FROM channel_performance
ORDER BY attribution_model, roas DESC NULLS LAST, channel_id;

SELECT * FROM campaign_performance
ORDER BY attribution_model, roas DESC NULLS LAST, campaign_id
LIMIT 30;

SELECT channel_name, attribution_model, attributed_revenue, spend, roas, roi
FROM channel_performance
ORDER BY channel_name, attribution_model;

-- Largest revenue differences across all three models, without fixed results.
SELECT channel_id, channel_name,
       MAX(attributed_revenue) - MIN(attributed_revenue) AS revenue_range,
       MAX(attributed_revenue) FILTER (WHERE attribution_model = 'first_click')
         - MAX(attributed_revenue) FILTER (WHERE attribution_model = 'last_click')
         AS first_minus_last_revenue
FROM attribution_model_comparison
GROUP BY channel_id, channel_name
ORDER BY revenue_range DESC, channel_id
LIMIT 10;

-- Each model allocates the same revenue/credit from conversions with eligible clicks.
-- EXISTS counts each attributable conversion exactly once, even with many clicks.
WITH models (attribution_model) AS (
    VALUES ('first_click'), ('last_click'), ('linear')
), expected AS (
    SELECT COUNT(*) AS attributable_conversions,
           COALESCE(SUM(c.conversion_value), 0::NUMERIC) AS attributable_revenue
    FROM conversions AS c
    WHERE EXISTS (
        SELECT 1 FROM conversion_touchpoints AS t
        WHERE t.conversion_id = c.conversion_id AND t.touchpoint_type = 'click'
    )
), result_totals AS (
    SELECT attribution_model, SUM(attribution_weight) AS credit,
           SUM(attributed_conversion_value) AS revenue
    FROM attribution_results GROUP BY attribution_model
), campaign_totals AS (
    SELECT attribution_model, SUM(attributed_revenue) AS revenue
    FROM campaign_performance GROUP BY attribution_model
), channel_totals AS (
    SELECT attribution_model, SUM(attributed_revenue) AS revenue
    FROM channel_performance GROUP BY attribution_model
)
SELECT m.attribution_model, e.attributable_conversions, e.attributable_revenue,
       COALESCE(r.credit, 0) AS result_conversion_credit,
       COALESCE(r.revenue, 0) AS result_revenue,
       COALESCE(ca.revenue, 0) AS campaign_view_revenue,
       COALESCE(ch.revenue, 0) AS channel_view_revenue,
       ABS(COALESCE(r.credit, 0) - e.attributable_conversions) <= 0.000000000001 AS credit_reconciles,
       ABS(COALESCE(r.revenue, 0) - e.attributable_revenue) <= 0.000001 AS revenue_reconciles,
       COALESCE(ca.revenue, 0) = COALESCE(r.revenue, 0) AS campaign_revenue_reconciles,
       COALESCE(ch.revenue, 0) = COALESCE(r.revenue, 0) AS channel_revenue_reconciles
FROM models AS m CROSS JOIN expected AS e
LEFT JOIN result_totals AS r ON r.attribution_model = m.attribution_model
LEFT JOIN campaign_totals AS ca ON ca.attribution_model = m.attribution_model
LEFT JOIN channel_totals AS ch ON ch.attribution_model = m.attribution_model
ORDER BY m.attribution_model;

-- Spend is the same in each model, and event totals must survive aggregation.
WITH models (attribution_model) AS (
    VALUES ('first_click'), ('last_click'), ('linear')
), expected AS (
    SELECT (SELECT COALESCE(SUM(spend), 0::NUMERIC) FROM campaign_spend) AS spend,
           (SELECT COUNT(*) FROM impressions) AS impressions,
           (SELECT COUNT(*) FROM clicks) AS clicks
), campaign_totals AS (
    SELECT attribution_model, SUM(spend) AS spend,
           SUM(impressions) AS impressions, SUM(clicks) AS clicks
    FROM campaign_performance GROUP BY attribution_model
), channel_totals AS (
    SELECT attribution_model, SUM(spend) AS spend,
           SUM(impressions) AS impressions, SUM(clicks) AS clicks
    FROM channel_performance GROUP BY attribution_model
)
SELECT m.attribution_model, e.spend AS source_spend,
       COALESCE(ca.spend, 0) AS campaign_view_spend,
       COALESCE(ch.spend, 0) AS channel_view_spend,
       COALESCE(ca.spend, 0) = e.spend AS campaign_spend_reconciles,
       COALESCE(ch.spend, 0) = e.spend AS channel_spend_reconciles,
       COALESCE(ca.impressions, 0) = e.impressions
         AND COALESCE(ch.impressions, 0) = e.impressions AS impressions_reconcile,
       COALESCE(ca.clicks, 0) = e.clicks
         AND COALESCE(ch.clicks, 0) = e.clicks AS clicks_reconcile
FROM models AS m CROSS JOIN expected AS e
LEFT JOIN campaign_totals AS ca ON ca.attribution_model = m.attribution_model
LEFT JOIN channel_totals AS ch ON ch.attribution_model = m.attribution_model
ORDER BY m.attribution_model;

-- Per-conversion/model weight/value checks already exist in the README's
-- "Click attribution" section and sql/validate_attribution.sql; reuse those.
