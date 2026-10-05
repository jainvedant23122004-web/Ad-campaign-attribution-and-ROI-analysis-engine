-- Business report: acquisition-month/channel cumulative D7/D30/D60/D90 revenue
-- and average LTV, with observation cutoff and mature-user denominators.
-- The existing live view recomputes acquisition ranking and revenue windows.
-- Both forms below answer the same question without an artificial slow path.
-- JSON preserves PostgreSQL timings and buffers for the scoped Python script.

-- BEGIN QUERY
SELECT *
FROM acquisition_cohort_ltv
ORDER BY acquisition_month, channel_name;
-- END QUERY

-- BEGIN EXPLAIN
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT *
FROM acquisition_cohort_ltv
ORDER BY acquisition_month, channel_name;
-- END EXPLAIN
