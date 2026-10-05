-- Rank eligible clicks once. Impressions and conversions without clicks produce
-- no results. Credit remains at conversion + click + model granularity.
WITH ranked_clicks AS (
    SELECT
        t.conversion_id, t.campaign_id, t.channel_id, t.creative_id, t.click_id,
        c.conversion_value,
        ROW_NUMBER() OVER (
            PARTITION BY t.conversion_id
            ORDER BY t.touchpoint_time ASC, t.click_id ASC
        ) AS first_rank,
        ROW_NUMBER() OVER (
            PARTITION BY t.conversion_id
            ORDER BY t.touchpoint_time DESC, t.click_id DESC
        ) AS last_rank,
        COUNT(*) OVER (PARTITION BY t.conversion_id) AS eligible_click_count
    FROM conversion_touchpoints AS t
    JOIN conversions AS c ON c.conversion_id = t.conversion_id
    WHERE t.touchpoint_type = 'click'
), weighted_clicks AS (
    SELECT conversion_id, campaign_id, channel_id, creative_id, click_id,
           conversion_value, 'first_click' AS attribution_model,
           1::NUMERIC(38, 24) AS attribution_weight
    FROM ranked_clicks
    WHERE first_rank = 1

    UNION ALL

    SELECT conversion_id, campaign_id, channel_id, creative_id, click_id,
           conversion_value, 'last_click', 1::NUMERIC(38, 24)
    FROM ranked_clicks
    WHERE last_rank = 1

    UNION ALL

    SELECT conversion_id, campaign_id, channel_id, creative_id, click_id,
           conversion_value, 'linear',
           CAST(1::NUMERIC(38, 24) / eligible_click_count AS NUMERIC(38, 24))
    FROM ranked_clicks
)
INSERT INTO attribution_results (
    conversion_id, campaign_id, channel_id, creative_id, click_id,
    attribution_model, attribution_weight, attributed_conversion_value
)
SELECT conversion_id, campaign_id, channel_id, creative_id, click_id,
       attribution_model, attribution_weight,
       conversion_value * attribution_weight
FROM weighted_clicks;
