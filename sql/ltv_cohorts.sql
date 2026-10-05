-- Observed acquisition-source LTV only; conversion-value ROAS stays separate.
-- These ordinary views read existing data and never rebuild attribution.

CREATE OR REPLACE VIEW user_acquisition AS
WITH ranked_conversions AS (
    SELECT c.user_id, c.conversion_id, c.conversion_time,
           r.campaign_id, r.channel_id,
           ROW_NUMBER() OVER (
               PARTITION BY c.user_id
               ORDER BY c.conversion_time, c.conversion_id, r.click_id
           ) AS acquisition_rank
    FROM conversions AS c
    JOIN attribution_results AS r ON r.conversion_id = c.conversion_id
    WHERE r.attribution_model = 'first_click'
)
SELECT r.user_id,
       r.conversion_id AS first_conversion_id,
       r.campaign_id AS acquisition_campaign_id,
       ca.campaign_name AS acquisition_campaign_name,
       r.channel_id AS acquisition_channel_id,
       ch.channel_name AS acquisition_channel_name,
       r.conversion_time AS acquisition_time
FROM ranked_conversions AS r
JOIN campaigns AS ca ON ca.campaign_id = r.campaign_id
JOIN channels AS ch ON ch.channel_id = r.channel_id
WHERE r.acquisition_rank = 1;

CREATE OR REPLACE VIEW user_ltv AS
WITH revenue_by_user AS (
    SELECT user_id, SUM(revenue_amount) AS lifetime_revenue,
           COUNT(*) AS revenue_event_count
    FROM user_revenue
    GROUP BY user_id
)
SELECT a.user_id, a.acquisition_campaign_id, a.acquisition_channel_id,
       a.acquisition_time,
       COALESCE(r.lifetime_revenue, 0::NUMERIC) AS lifetime_revenue,
       COALESCE(r.revenue_event_count, 0::BIGINT) AS revenue_event_count
FROM user_acquisition AS a
LEFT JOIN revenue_by_user AS r ON r.user_id = a.user_id;

CREATE OR REPLACE VIEW campaign_ltv AS
WITH ranked_users AS (
    -- Exact numeric midpoint median, equivalent to continuous percentile 0.5.
    -- Avoid converting monetary NUMERIC values to floating point.
    SELECT u.*,
           ROW_NUMBER() OVER (
               PARTITION BY acquisition_campaign_id
               ORDER BY lifetime_revenue, user_id
           ) AS revenue_rank,
           COUNT(*) OVER (PARTITION BY acquisition_campaign_id) AS population
    FROM user_ltv AS u
), user_totals AS (
    SELECT acquisition_campaign_id,
           COUNT(*) AS acquired_users,
           SUM(lifetime_revenue) AS total_lifetime_revenue,
           AVG(lifetime_revenue) AS average_ltv,
           AVG(lifetime_revenue) FILTER (
               WHERE revenue_rank IN ((population + 1) / 2, (population + 2) / 2)
           ) AS median_ltv
    FROM ranked_users
    GROUP BY acquisition_campaign_id
), spend_totals AS (
    SELECT campaign_id, SUM(spend) AS spend
    FROM campaign_spend
    GROUP BY campaign_id
), base AS (
    SELECT ca.campaign_id, ca.campaign_name, ch.channel_id, ch.channel_name,
           COALESCE(u.acquired_users, 0::BIGINT) AS acquired_users,
           COALESCE(u.total_lifetime_revenue, 0::NUMERIC) AS total_lifetime_revenue,
           u.average_ltv, u.median_ltv,
           COALESCE(s.spend, 0::NUMERIC) AS spend
    FROM campaigns AS ca
    JOIN channels AS ch ON ch.channel_id = ca.channel_id
    LEFT JOIN user_totals AS u ON u.acquisition_campaign_id = ca.campaign_id
    LEFT JOIN spend_totals AS s ON s.campaign_id = ca.campaign_id
), metrics AS (
    SELECT base.*, spend / NULLIF(acquired_users, 0) AS cac
    FROM base
)
SELECT metrics.*, average_ltv / NULLIF(cac, 0) AS ltv_cac_ratio
FROM metrics;

CREATE OR REPLACE VIEW channel_ltv AS
WITH ranked_users AS (
    -- Calculate directly across channel users, never average campaign averages.
    SELECT u.*,
           ROW_NUMBER() OVER (
               PARTITION BY acquisition_channel_id
               ORDER BY lifetime_revenue, user_id
           ) AS revenue_rank,
           COUNT(*) OVER (PARTITION BY acquisition_channel_id) AS population
    FROM user_ltv AS u
), user_totals AS (
    SELECT acquisition_channel_id,
           COUNT(*) AS acquired_users,
           SUM(lifetime_revenue) AS total_lifetime_revenue,
           AVG(lifetime_revenue) AS average_ltv,
           AVG(lifetime_revenue) FILTER (
               WHERE revenue_rank IN ((population + 1) / 2, (population + 2) / 2)
           ) AS median_ltv
    FROM ranked_users
    GROUP BY acquisition_channel_id
), spend_totals AS (
    SELECT ca.channel_id, SUM(s.spend) AS spend
    FROM campaigns AS ca
    JOIN campaign_spend AS s ON s.campaign_id = ca.campaign_id
    GROUP BY ca.channel_id
), base AS (
    SELECT ch.channel_id, ch.channel_name,
           COALESCE(u.acquired_users, 0::BIGINT) AS acquired_users,
           COALESCE(u.total_lifetime_revenue, 0::NUMERIC) AS total_lifetime_revenue,
           u.average_ltv, u.median_ltv,
           COALESCE(s.spend, 0::NUMERIC) AS spend
    FROM channels AS ch
    LEFT JOIN user_totals AS u ON u.acquisition_channel_id = ch.channel_id
    LEFT JOIN spend_totals AS s ON s.channel_id = ch.channel_id
), metrics AS (
    SELECT base.*, spend / NULLIF(acquired_users, 0) AS cac
    FROM base
)
SELECT metrics.*, average_ltv / NULLIF(cac, 0) AS ltv_cac_ratio
FROM metrics;

CREATE OR REPLACE VIEW acquisition_cohort_ltv AS
WITH observation AS (
    -- The synthetic generator writes every UTC observation date to the spend
    -- ledger, including zero-spend days. The end is the next midnight, exclusive.
    -- This assumes a complete ledger; MAX(revenue_time) is not a coverage bound.
    -- An empty ledger gives NULL coverage and no mature horizon values.
    SELECT ((MAX(spend_date) + 1)::TIMESTAMP AT TIME ZONE 'UTC') AS observation_end
    FROM campaign_spend
), user_windows AS (
    SELECT a.user_id, a.acquisition_channel_id, a.acquisition_time,
           o.observation_end,
           COALESCE(SUM(r.revenue_amount) FILTER (
               WHERE r.revenue_time < a.acquisition_time + INTERVAL '168 hours'
           ), 0::NUMERIC) AS revenue_d7,
           COALESCE(SUM(r.revenue_amount) FILTER (
               WHERE r.revenue_time < a.acquisition_time + INTERVAL '720 hours'
           ), 0::NUMERIC) AS revenue_d30,
           COALESCE(SUM(r.revenue_amount) FILTER (
               WHERE r.revenue_time < a.acquisition_time + INTERVAL '1440 hours'
           ), 0::NUMERIC) AS revenue_d60,
           COALESCE(SUM(r.revenue_amount), 0::NUMERIC) AS revenue_d90
    FROM user_acquisition AS a
    CROSS JOIN observation AS o
    LEFT JOIN user_revenue AS r ON r.user_id = a.user_id
        AND r.revenue_time >= a.acquisition_time
        AND r.revenue_time < a.acquisition_time + INTERVAL '2160 hours'
    GROUP BY a.user_id, a.acquisition_channel_id, a.acquisition_time, o.observation_end
), eligible_windows AS (
    SELECT w.*,
           acquisition_time + INTERVAL '168 hours' <= observation_end AS eligible_d7,
           acquisition_time + INTERVAL '720 hours' <= observation_end AS eligible_d30,
           acquisition_time + INTERVAL '1440 hours' <= observation_end AS eligible_d60,
           acquisition_time + INTERVAL '2160 hours' <= observation_end AS eligible_d90
    FROM user_windows AS w
)
SELECT DATE_TRUNC('month', w.acquisition_time AT TIME ZONE 'UTC')::DATE AS acquisition_month,
       ch.channel_id, ch.channel_name, COUNT(*) AS acquired_users,
       w.observation_end,
       COUNT(*) FILTER (WHERE eligible_d7) AS eligible_users_d7,
       COUNT(*) FILTER (WHERE eligible_d30) AS eligible_users_d30,
       COUNT(*) FILTER (WHERE eligible_d60) AS eligible_users_d60,
       COUNT(*) FILTER (WHERE eligible_d90) AS eligible_users_d90,
       SUM(revenue_d7) FILTER (WHERE eligible_d7) AS revenue_d7,
       SUM(revenue_d30) FILTER (WHERE eligible_d30) AS revenue_d30,
       SUM(revenue_d60) FILTER (WHERE eligible_d60) AS revenue_d60,
       SUM(revenue_d90) FILTER (WHERE eligible_d90) AS revenue_d90,
       AVG(revenue_d7) FILTER (WHERE eligible_d7) AS average_ltv_d7,
       AVG(revenue_d30) FILTER (WHERE eligible_d30) AS average_ltv_d30,
       AVG(revenue_d60) FILTER (WHERE eligible_d60) AS average_ltv_d60,
       AVG(revenue_d90) FILTER (WHERE eligible_d90) AS average_ltv_d90
FROM eligible_windows AS w
JOIN channels AS ch ON ch.channel_id = w.acquisition_channel_id
GROUP BY DATE_TRUNC('month', w.acquisition_time AT TIME ZONE 'UTC')::DATE,
         ch.channel_id, ch.channel_name, w.observation_end;
