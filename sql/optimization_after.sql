-- Same report, columns, precision, NULL semantics, and ordering as the baseline.
-- Values are equivalent only while the materialized snapshot is current.

-- BEGIN QUERY
SELECT *
FROM acquisition_cohort_materialized
ORDER BY acquisition_month, channel_name;
-- END QUERY

-- BEGIN EXPLAIN
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT *
FROM acquisition_cohort_materialized
ORDER BY acquisition_month, channel_name;
-- END EXPLAIN
