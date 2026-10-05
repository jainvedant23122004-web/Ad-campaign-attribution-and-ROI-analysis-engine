-- Ordinary views over all currently loaded data, with decimal ratios and no rounding.
-- Spend comes exclusively from campaign_spend; user_revenue is reserved for LTV.
CREATE OR REPLACE VIEW campaign_performance AS
WITH models (attribution_model) AS (
    VALUES ('first_click'), ('last_click'), ('linear')
), impression_metrics AS (
    SELECT campaign_id, COUNT(*) AS impressions
    FROM impressions
    GROUP BY campaign_id
), click_metrics AS (
    SELECT campaign_id, COUNT(*) AS clicks
    FROM clicks
    GROUP BY campaign_id
), spend_metrics AS (
    SELECT campaign_id, SUM(spend) AS spend
    FROM campaign_spend
    GROUP BY campaign_id
), journey_metrics AS (
    -- Distinct click-associated conversions, not credit or exclusive ownership.
    -- This count is model-independent and must not be summed across campaigns.
    SELECT campaign_id, COUNT(DISTINCT conversion_id) AS raw_conversions
    FROM conversion_touchpoints
    WHERE touchpoint_type = 'click'
    GROUP BY campaign_id
), attribution_metrics AS (
    SELECT campaign_id, attribution_model,
           SUM(attribution_weight) AS attributed_conversions,
           SUM(attributed_conversion_value) AS attributed_revenue
    FROM attribution_results
    GROUP BY campaign_id, attribution_model
), totals AS (
    SELECT ca.campaign_id, ca.campaign_name, ch.channel_id, ch.channel_name,
           m.attribution_model,
           COALESCE(i.impressions, 0::BIGINT) AS impressions,
           COALESCE(cl.clicks, 0::BIGINT) AS clicks,
           COALESCE(s.spend, 0::NUMERIC) AS spend,
           COALESCE(j.raw_conversions, 0::BIGINT) AS raw_conversions,
           COALESCE(a.attributed_conversions, 0::NUMERIC) AS attributed_conversions,
           COALESCE(a.attributed_revenue, 0::NUMERIC) AS attributed_revenue
    FROM campaigns AS ca
    JOIN channels AS ch ON ch.channel_id = ca.channel_id
    CROSS JOIN models AS m
    LEFT JOIN impression_metrics AS i ON i.campaign_id = ca.campaign_id
    LEFT JOIN click_metrics AS cl ON cl.campaign_id = ca.campaign_id
    LEFT JOIN spend_metrics AS s ON s.campaign_id = ca.campaign_id
    LEFT JOIN journey_metrics AS j ON j.campaign_id = ca.campaign_id
    LEFT JOIN attribution_metrics AS a
        ON a.campaign_id = ca.campaign_id AND a.attribution_model = m.attribution_model
)
SELECT campaign_id, campaign_name, channel_id, channel_name, attribution_model,
       impressions, clicks,
       clicks::NUMERIC / NULLIF(impressions, 0) AS ctr,
       spend, raw_conversions, attributed_conversions, attributed_revenue,
       spend / NULLIF(clicks, 0) AS cpc,
       spend / NULLIF(attributed_conversions, 0) AS cpa,
       attributed_revenue / NULLIF(spend, 0) AS roas,
       (attributed_revenue - spend) / NULLIF(spend, 0) AS roi
FROM totals;

CREATE OR REPLACE VIEW channel_performance AS
WITH models (attribution_model) AS (
    VALUES ('first_click'), ('last_click'), ('linear')
), campaign_totals AS (
    -- Add campaign totals within each model, then recompute ratios below.
    -- Never average campaign ratios or sum spend across attribution models.
    SELECT channel_id, attribution_model,
           SUM(impressions)::BIGINT AS impressions,
           SUM(clicks)::BIGINT AS clicks,
           SUM(spend) AS spend,
           SUM(attributed_conversions) AS attributed_conversions,
           SUM(attributed_revenue) AS attributed_revenue
    FROM campaign_performance
    GROUP BY channel_id, attribution_model
), journey_metrics AS (
    -- A conversion can touch multiple campaigns in one channel: deduplicate here
    -- instead of adding campaign raw_conversions, which would double-count it.
    SELECT ca.channel_id, COUNT(DISTINCT t.conversion_id) AS raw_conversions
    FROM conversion_touchpoints AS t
    JOIN campaigns AS ca ON ca.campaign_id = t.campaign_id
    WHERE t.touchpoint_type = 'click'
    GROUP BY ca.channel_id
), totals AS (
    SELECT ch.channel_id, ch.channel_name, m.attribution_model,
           COALESCE(c.impressions, 0::BIGINT) AS impressions,
           COALESCE(c.clicks, 0::BIGINT) AS clicks,
           COALESCE(c.spend, 0::NUMERIC) AS spend,
           COALESCE(j.raw_conversions, 0::BIGINT) AS raw_conversions,
           COALESCE(c.attributed_conversions, 0::NUMERIC) AS attributed_conversions,
           COALESCE(c.attributed_revenue, 0::NUMERIC) AS attributed_revenue
    FROM channels AS ch
    CROSS JOIN models AS m
    LEFT JOIN campaign_totals AS c
        ON c.channel_id = ch.channel_id AND c.attribution_model = m.attribution_model
    LEFT JOIN journey_metrics AS j ON j.channel_id = ch.channel_id
)
SELECT channel_id, channel_name, attribution_model,
       impressions, clicks,
       clicks::NUMERIC / NULLIF(impressions, 0) AS ctr,
       spend, raw_conversions, attributed_conversions, attributed_revenue,
       spend / NULLIF(clicks, 0) AS cpc,
       spend / NULLIF(attributed_conversions, 0) AS cpa,
       attributed_revenue / NULLIF(spend, 0) AS roas,
       (attributed_revenue - spend) / NULLIF(spend, 0) AS roi
FROM totals;

-- Long format preserves model filtering/comparison without hardcoded pivot columns.
CREATE OR REPLACE VIEW attribution_model_comparison AS
SELECT channel_id, channel_name, attribution_model,
       attributed_conversions, attributed_revenue, roas, roi
FROM channel_performance;
