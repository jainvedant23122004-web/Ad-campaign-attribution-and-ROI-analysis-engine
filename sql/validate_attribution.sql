-- Runtime integrity checks in the runner's transaction, not an automated test suite.
-- A missing group must fail too; validating only existing groups would miss it.
WITH eligible_conversions AS (
    SELECT conversion_id, COUNT(*) AS click_count
    FROM conversion_touchpoints
    WHERE touchpoint_type = 'click'
    GROUP BY conversion_id
), models (attribution_model) AS (
    VALUES ('first_click'), ('last_click'), ('linear')
), totals AS (
    SELECT conversion_id, attribution_model, COUNT(*) AS row_count,
           SUM(attribution_weight) AS total_weight,
           SUM(attributed_conversion_value) AS total_value
    FROM attribution_results
    GROUP BY conversion_id, attribution_model
), violations AS (
    SELECT e.conversion_id, m.attribution_model,
           'Missing model, incorrect row count, or weight/value conservation failed' AS reason
    FROM eligible_conversions AS e
    JOIN conversions AS c ON c.conversion_id = e.conversion_id
    CROSS JOIN models AS m
    LEFT JOIN totals AS r
        ON r.conversion_id = e.conversion_id AND r.attribution_model = m.attribution_model
    WHERE r.conversion_id IS NULL
       OR r.row_count <> CASE WHEN m.attribution_model = 'linear' THEN e.click_count ELSE 1 END
       OR ABS(r.total_weight - 1) > :weight_tolerance
       OR ABS(r.total_value - c.conversion_value) > :value_tolerance

    UNION ALL

    SELECT r.conversion_id, r.attribution_model, 'Credited click is not an eligible matching touchpoint'
    FROM attribution_results AS r
    LEFT JOIN conversion_touchpoints AS t
        ON t.conversion_id = r.conversion_id AND t.click_id = r.click_id
        AND t.touchpoint_type = 'click'
    WHERE t.conversion_touchpoint_id IS NULL
       OR r.campaign_id <> t.campaign_id
       OR r.channel_id <> t.channel_id
       OR r.creative_id <> t.creative_id
)
SELECT conversion_id, attribution_model, reason
FROM violations
LIMIT 10;
