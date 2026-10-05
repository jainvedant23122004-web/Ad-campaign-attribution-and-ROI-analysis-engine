# Manual local Metabase setup

Dashboard preparation is complete. Metabase installation, connection, saved questions, and dashboard configuration remain manual and pending. Follow [DASHBOARD_SPEC.md](DASHBOARD_SPEC.md) using [metabase_queries.sql](../sql/metabase_queries.sql). No new PostgreSQL views are needed.

## 1. Run Metabase locally

Use the Metabase OSS JAR for this college project. Download it using the [official JAR instructions](https://www.metabase.com/docs/latest/installation-and-operation/running-the-metabase-jar-file). The current instructions specify Java 25; install the runtime required by your downloaded release if it is absent. Place `metabase.jar` in a dedicated folder outside this repository, such as a `metabase-local` folder in your Windows user directory.

Open PowerShell in that folder and run:

```powershell
java -version
java --add-opens java.base/java.nio=ALL-UNNAMED -jar metabase.jar
```

Wait for initialization, open `http://localhost:3000/setup`, and complete the local setup wizard. Keep the terminal running while using Metabase. Its local application database stores saved questions/dashboard settings in this folder; retain those files between sessions. PostgreSQL remains the analytics data source. These are instructions for the user; Metabase was not installed or started during preparation.

## 2. Connect PostgreSQL

In the setup wizard, or **Admin > Databases > Add a database**, select PostgreSQL and enter these local placeholders:

| Setting | Value |
| --- | --- |
| Display name | Ad Attribution Analytics |
| Host | `localhost` |
| Port | `5432` |
| Database | `ad_attribution` |
| Username | `postgres` |
| Password | `<local password>` |
| Schemas | Only these: `public` |

Use your actual local connection settings privately if they differ. Save the connection and wait for schema sync. The [PostgreSQL connection guide](https://www.metabase.com/docs/latest/databases/connections/postgresql) describes these fields. Confirm `campaign_performance`, `channel_performance`, `attribution_model_comparison`, `campaign_ltv`, `channel_ltv`, `acquisition_cohort_ltv`, and `acquisition_cohort_materialized` are visible. If missing, check the schema/read permissions and use **Admin > Databases > your database > Sync database schema**, as described in the [sync guide](https://www.metabase.com/docs/latest/databases/sync-scan).

## 3. Save Native Questions

Create a collection named **Ad Attribution Analytics**. Choose **New > SQL query**, select the PostgreSQL connection, and paste one named query from `sql/metabase_queries.sql`, including its `{{variables}}` and `[[optional clauses]]`. Save it with the query ID and descriptive card name. Do not paste the entire file into one question or run its template syntax directly in psql. See the [SQL editor guide](https://www.metabase.com/docs/latest/questions/native-editor/writing-sql).

Configure basic variables in the editor sidebar:

| Variable | Type | Required/default | Widget |
| --- | --- | --- | --- |
| `attribution_model` | Text | Required; UI default `linear` | Single-value dropdown: `first_click`, `last_click`, `linear` |
| `channel_name` | Text | Optional; no default | Single-value dropdown |
| `campaign_id` | Number | Optional; no default | Single-value selection |
| `acquisition_month` | Date | Optional; no default | Single date |

The SQL requires `attribution_model` and has **no SQL default**. Set `linear` in the question's variable settings and in the Campaign Overview dashboard filter settings. Enable **Always require a value** for the model. Leave the other variables optional. These templates use basic variables rather than Field Filters; preserve the existing comparison operators and do not add quotes around placeholders. See [variable widgets and defaults](https://www.metabase.com/docs/latest/questions/native-editor/filter-widgets).

Save F1 and F2 as lookup questions. Configure Channel dropdown values from **F1: `channel_name`**. Configure Campaign values from **F2: `campaign_id`**, with **`campaign_label`** as the displayed label. F3 lists available acquisition months for reference. The Date picker passes a single date; CA1/CA2 normalize any selected day to its UTC acquisition month. There is no date-range or multi-select support in these templates and no automatic cascading of Channel/Campaign choices.

For CO1, save seven Number questions using the same SQL, choosing a different **Field to show** for each card. Do the same for the five AE1 Number cards. The [Number visualization guide](https://www.metabase.com/docs/latest/questions/visualizations/numbers) explains that setting. Use the specification's fields for the remaining tables/charts; do not add extra averaging in Metabase.

## 4. Create dashboards and connect filters

Create exactly the four dashboards named in the specification. Add the saved questions, choose the specified axes/series, and arrange summary cards above charts and tables.

In dashboard edit mode, add the filters below. Click each filter and connect it to the named variable on **every applicable saved card**, including every copy of CO1/AE1:

| Dashboard | Filter -> card variable | Cards |
| --- | --- | --- |
| Campaign Overview | Attribution Model -> `attribution_model`; Channel -> `channel_name`; Campaign -> `campaign_id` | All CO1/CO2/CO3 cards |
| Attribution Model Comparison | Channel -> `channel_name` | All MC1/MC2/MC3 cards |
| LTV & Acquisition Economics | Channel -> `channel_name` | All AE1/AE2/AE3 cards |
| Acquisition Cohort Analysis | Channel -> `channel_name`; Acquisition Month -> `acquisition_month` | CA1 and CA2 |

Make **Attribution Model** required with dashboard default **`linear`**, using the three exact allowed values above. Comparison intentionally shows all models; LTV/cohorts have a fixed first-click acquisition policy. Choose single-value filters; the cohort month uses a **Single date** dashboard filter. See the [dashboard filter guide](https://www.metabase.com/docs/latest/dashboards/filters). Save, then manually check the model changes, filter connections, number-field selections, and chart labels. An incompatible Channel/Campaign selection can produce empty results; clear one selection.

## 5. Cohort freshness and completion

CA1/CA2 default to the live `acquisition_cohort_ltv` view. To use the optional faster snapshot, manually change the source in **both** questions to `acquisition_cohort_materialized`. After relevant data/attribution/cohort changes, the database maintainer must manually run:

```sql
REFRESH MATERIALIZED VIEW acquisition_cohort_materialized;
```

Ordinary refresh blocks snapshot readers and recomputes the report. No dashboard query refreshes it automatically. The existing `sql/optimization_checks.sql` can reconcile the snapshot when needed; no benchmark rerun is required. Display which source is being used and the last manual refresh time when using the snapshot. `observation_end` is dataset coverage, not the snapshot refresh time.

Keep unavailable horizons as NULL. D90 currently has no eligible users. In the line chart's missing-value setting choose **Nothing**, rather than zero or interpolation, as supported by the [chart settings](https://www.metabase.com/docs/latest/questions/visualizations/line-bar-and-area-charts).

Finish by saving all four dashboards, confirming their default filters, and capturing screenshots plus a brief interpretation based on actual displayed data. The preparation used read-only SQL inspection before these guides were written; no Metabase UI configuration has been performed.
