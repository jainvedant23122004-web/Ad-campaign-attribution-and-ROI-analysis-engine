-- Isolated precomputation of the chosen cohort report, not unrelated analytics.
-- The inspected live plan repeats acquisition ranking, 898 indexed revenue
-- lookups, sorting, and user/cohort aggregation to return 15 rows.
-- Existing user_id/revenue_time and attribution indexes are already present.
-- A full-report scan needs no additional index on this small materialization.
-- Original ordinary views remain live; reports must explicitly use this snapshot.

CREATE MATERIALIZED VIEW IF NOT EXISTS acquisition_cohort_materialized AS
SELECT * FROM acquisition_cohort_ltv
WITH NO DATA;

-- Populate on setup, or manually repeat this command after changes to source
-- data, attribution, or cohort definitions. There is no automatic refresh job.
-- Ordinary refresh recomputes the whole report and blocks concurrent readers
-- of this materialized view. Run during a quiet period; no concurrent refresh
-- or supporting unique index is needed for this local experiment.
REFRESH MATERIALIZED VIEW acquisition_cohort_materialized;

-- IF NOT EXISTS does not migrate an existing incompatible definition. The
-- benchmark refuses mismatched results; inspect the definition if that occurs.
