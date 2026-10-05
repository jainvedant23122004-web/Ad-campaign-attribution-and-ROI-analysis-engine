-- Manual read-only inspection, not a test suite or benchmark.
-- Run inside a read-only transaction with a short statement_timeout.

-- Expected: zero rows (one acquisition source per user).
SELECT user_id, COUNT(*) AS acquisition_rows
FROM user_acquisition
GROUP BY user_id
HAVING COUNT(*) > 1;

-- Expected: zero negative or missing LTV values.
SELECT COUNT(*) AS invalid_ltv_users
FROM user_ltv
WHERE lifetime_revenue < 0 OR lifetime_revenue IS NULL;

-- Expected: zero wrong first-click mappings or earlier attributable conversions.
SELECT COUNT(*) AS invalid_acquisition_users
FROM user_acquisition AS a
WHERE NOT EXISTS (
    SELECT 1
    FROM conversions AS c
    JOIN attribution_results AS r ON r.conversion_id = c.conversion_id
    WHERE c.conversion_id = a.first_conversion_id AND c.user_id = a.user_id
      AND c.conversion_time = a.acquisition_time
      AND r.attribution_model = 'first_click'
      AND r.campaign_id = a.acquisition_campaign_id
      AND r.channel_id = a.acquisition_channel_id
) OR EXISTS (
    SELECT 1
    FROM conversions AS c
    JOIN attribution_results AS r ON r.conversion_id = c.conversion_id
    WHERE c.user_id = a.user_id AND r.attribution_model = 'first_click'
      AND (c.conversion_time, c.conversion_id) < (a.acquisition_time, a.first_conversion_id)
);

-- Reconcile only the acquired population; explicitly report excluded receipts.
-- Both equality flags should be true, even when excluded revenue is positive.
WITH source AS (
    SELECT COALESCE(SUM(r.revenue_amount), 0) AS all_source_revenue,
           COALESCE(SUM(r.revenue_amount) FILTER (WHERE a.user_id IS NOT NULL), 0)
               AS acquired_source_revenue,
           COALESCE(SUM(r.revenue_amount) FILTER (WHERE a.user_id IS NULL), 0)
               AS nonacquired_source_revenue,
           COUNT(*) FILTER (WHERE a.user_id IS NOT NULL) AS acquired_source_events,
           COUNT(DISTINCT r.user_id) FILTER (WHERE a.user_id IS NULL) AS excluded_revenue_users
    FROM user_revenue AS r
    LEFT JOIN user_acquisition AS a ON a.user_id = r.user_id
), ltv AS (
    SELECT COUNT(*) AS acquired_users,
           COALESCE(SUM(lifetime_revenue), 0) AS represented_ltv,
           COALESCE(SUM(revenue_event_count), 0) AS represented_events
    FROM user_ltv
)
SELECT ltv.*, source.*,
       represented_ltv = acquired_source_revenue AS acquired_revenue_matches,
       represented_events = acquired_source_events AS revenue_events_match,
       all_source_revenue = represented_ltv + nonacquired_source_revenue AS full_partition_matches,
       acquired_users = (SELECT COUNT(DISTINCT c.user_id)
           FROM conversions AS c JOIN attribution_results AS r USING (conversion_id)
           WHERE r.attribution_model = 'first_click') AS acquisition_population_matches
FROM ltv CROSS JOIN source;

-- Spend must equal the official ledger once, not once per attributed model.
-- Acquired users and revenue must reconcile at both aggregation levels.
WITH expected AS (
    SELECT (SELECT COALESCE(SUM(spend), 0) FROM campaign_spend) AS source_spend,
           (SELECT COUNT(*) FROM user_ltv) AS source_users,
           (SELECT COALESCE(SUM(lifetime_revenue), 0) FROM user_ltv) AS source_ltv
), actual AS (
    SELECT 'campaign' AS level, COUNT(*) AS entities,
           COALESCE(SUM(spend), 0) AS spend,
           COALESCE(SUM(acquired_users), 0) AS acquired_users,
           COALESCE(SUM(total_lifetime_revenue), 0) AS total_lifetime_revenue
    FROM campaign_ltv
    UNION ALL
    SELECT 'channel', COUNT(*), COALESCE(SUM(spend), 0),
           COALESCE(SUM(acquired_users), 0), COALESCE(SUM(total_lifetime_revenue), 0)
    FROM channel_ltv
)
SELECT actual.*, spend = source_spend AS spend_matches,
       acquired_users = source_users AS users_match,
       total_lifetime_revenue = source_ltv AS ltv_matches
FROM actual CROSS JOIN expected;

-- Inspect the coverage assumption and any difference between all-receipt LTV
-- and post-acquisition cohorts. Empty or incomplete coverage must be investigated
-- before interpreting horizons; do not infer coverage from the last receipt.
WITH coverage AS (
    SELECT MIN(spend_date) AS first_date, MAX(spend_date) AS last_date,
           COUNT(DISTINCT spend_date) AS observed_dates,
           ((MAX(spend_date) + 1)::TIMESTAMP AT TIME ZONE 'UTC') AS observation_end
    FROM campaign_spend
)
SELECT coverage.*,
       observed_dates = last_date - first_date + 1 AS continuous_date_coverage,
       (SELECT COUNT(*) FROM user_revenue AS r JOIN user_acquisition AS a USING (user_id)
        WHERE r.revenue_time < a.acquisition_time) AS preacquisition_receipts,
       (SELECT COUNT(*) FROM user_revenue AS r
        WHERE r.revenue_time >= coverage.observation_end) AS receipts_after_observation_end
FROM coverage;

-- Cumulative monotonicity requires the SAME users at both horizons. Each view
-- horizon has its own mature population, so its published totals/averages can
-- legitimately decrease when the population changes. Inspect common populations
-- by cohort instead; do not compare different eligibility denominators.
WITH observation AS (
    SELECT ((MAX(spend_date) + 1)::TIMESTAMP AT TIME ZONE 'UTC') AS observation_end
    FROM campaign_spend
), cumulative AS (
    SELECT a.user_id, a.acquisition_channel_id,
           DATE_TRUNC('month', a.acquisition_time AT TIME ZONE 'UTC')::DATE AS acquisition_month,
           a.acquisition_time, o.observation_end,
           COALESCE(SUM(r.revenue_amount) FILTER (
               WHERE r.revenue_time < a.acquisition_time + INTERVAL '168 hours'), 0) AS d7,
           COALESCE(SUM(r.revenue_amount) FILTER (
               WHERE r.revenue_time < a.acquisition_time + INTERVAL '720 hours'), 0) AS d30,
           COALESCE(SUM(r.revenue_amount) FILTER (
               WHERE r.revenue_time < a.acquisition_time + INTERVAL '1440 hours'), 0) AS d60,
           COALESCE(SUM(r.revenue_amount), 0) AS d90
    FROM user_acquisition AS a CROSS JOIN observation AS o
    LEFT JOIN user_revenue AS r ON r.user_id = a.user_id
        AND r.revenue_time >= a.acquisition_time
        AND r.revenue_time < a.acquisition_time + INTERVAL '2160 hours'
    GROUP BY a.user_id, a.acquisition_channel_id, a.acquisition_time, o.observation_end
), common_populations AS (
    SELECT c.acquisition_month, c.acquisition_channel_id, h.horizon_days,
           COUNT(*) AS eligible_users, SUM(h.earlier_revenue) AS earlier_revenue,
           SUM(h.later_revenue) AS later_revenue,
           COUNT(*) FILTER (WHERE h.earlier_revenue > h.later_revenue) AS decreasing_users
    FROM cumulative AS c
    CROSS JOIN LATERAL (VALUES
        (30, c.d7, c.d30), (60, c.d30, c.d60), (90, c.d60, c.d90)
    ) AS h(horizon_days, earlier_revenue, later_revenue)
    WHERE c.acquisition_time + h.horizon_days * INTERVAL '24 hours' <= c.observation_end
    GROUP BY c.acquisition_month, c.acquisition_channel_id, h.horizon_days
)
SELECT *, earlier_revenue <= later_revenue AND decreasing_users = 0 AS monotonic
FROM common_populations
ORDER BY acquisition_month, acquisition_channel_id, horizon_days;

-- Expected: zero inconsistent cohort rows. NULL means no mature population,
-- not zero observed revenue. Average uses eligible users, not all acquired users.
SELECT COUNT(*) AS invalid_cohort_rows
FROM acquisition_cohort_ltv AS c
WHERE NOT (acquired_users >= eligible_users_d7 AND eligible_users_d7 >= eligible_users_d30
       AND eligible_users_d30 >= eligible_users_d60 AND eligible_users_d60 >= eligible_users_d90)
   OR EXISTS (
       SELECT 1 FROM (VALUES
           (eligible_users_d7, revenue_d7, average_ltv_d7),
           (eligible_users_d30, revenue_d30, average_ltv_d30),
           (eligible_users_d60, revenue_d60, average_ltv_d60),
           (eligible_users_d90, revenue_d90, average_ltv_d90)
       ) AS h(eligible_users, revenue, average_ltv)
       WHERE (eligible_users = 0 AND (revenue IS NOT NULL OR average_ltv IS NOT NULL))
          OR (eligible_users > 0 AND (revenue IS NULL OR average_ltv IS NULL
              OR revenue < 0 OR average_ltv <> revenue / eligible_users))
   );
