-- SQLAlchemy binds :window_days; no event data is pulled into Python.
-- Each conversion has an independent eligibility window. An event can qualify
-- for multiple conversions, and repeated events are retained by source ID.
INSERT INTO conversion_touchpoints (
    conversion_id, user_id, campaign_id, creative_id, channel_id,
    impression_id, click_id, touchpoint_type, touchpoint_time,
    conversion_time, seconds_before_conversion, attribution_window_days
)
SELECT
    c.conversion_id, c.user_id, i.campaign_id, i.creative_id, ca.channel_id,
    i.impression_id, NULL::BIGINT, 'impression', i.impression_time,
    c.conversion_time,
    EXTRACT(EPOCH FROM (c.conversion_time - i.impression_time)),
    :window_days
FROM conversions AS c
JOIN impressions AS i
    ON i.user_id = c.user_id
    AND i.impression_time >= c.conversion_time - :window_days * INTERVAL '24 hours'
    AND i.impression_time < c.conversion_time
JOIN campaigns AS ca ON ca.campaign_id = i.campaign_id

UNION ALL

SELECT
    c.conversion_id, c.user_id, cl.campaign_id, cl.creative_id, ca.channel_id,
    NULL::BIGINT, cl.click_id, 'click', cl.click_time,
    c.conversion_time,
    EXTRACT(EPOCH FROM (c.conversion_time - cl.click_time)),
    :window_days
FROM conversions AS c
JOIN clicks AS cl
    ON cl.user_id = c.user_id
    AND cl.click_time >= c.conversion_time - :window_days * INTERVAL '24 hours'
    AND cl.click_time < c.conversion_time
JOIN campaigns AS ca ON ca.campaign_id = cl.campaign_id;
