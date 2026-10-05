-- Exact, duplicate-sensitive equivalence across every report column, including
-- NULL horizons, eligible-user counts, timestamps, and unrounded numeric values.
-- EXCEPT ALL treats matching NULLs alike and preserves row multiplicity.
-- Expected: equal row counts and zero missing/extra rows. A stale snapshot
-- must be refreshed before any speed comparison is accepted.
WITH baseline AS MATERIALIZED (
    SELECT * FROM acquisition_cohort_ltv
), optimized AS MATERIALIZED (
    SELECT * FROM acquisition_cohort_materialized
), missing AS (
    SELECT * FROM baseline EXCEPT ALL SELECT * FROM optimized
), extra AS (
    SELECT * FROM optimized EXCEPT ALL SELECT * FROM baseline
)
SELECT (SELECT COUNT(*) FROM baseline) AS baseline_rows,
       (SELECT COUNT(*) FROM optimized) AS optimized_rows,
       (SELECT COUNT(*) FROM missing) AS missing_rows,
       (SELECT COUNT(*) FROM extra) AS extra_rows;
