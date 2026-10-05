# Metabase dashboard specification

Exactly four dashboards are specified below. Preparation is complete; saved questions and dashboards have not yet been configured in Metabase. Query IDs refer to [sql/metabase_queries.sql](../sql/metabase_queries.sql); follow [METABASE_SETUP.md](METABASE_SETUP.md) for installation and filter wiring.

For Number cards, X/Y axes and breakout are not applicable. For tables, use the returned rows/columns with no chart axes or additional aggregation. For charts, use the specified metric directly; the SQL already establishes the grain. Round only for display: money to two decimals, ratios to two or three decimals, CTR/ROI as percentages, and fractional conversion credit to two decimals. Leave NULL values blank or labeled unavailable.

## 1. Campaign Overview

**Purpose:** compare spend, attributed conversion revenue, and advertising efficiency under one selected attribution model. Sources: `campaign_performance`; CO2 recomputes channel totals to support Campaign filtering. Without a Campaign filter, its totals/ratios match `channel_performance`.

**Filters:** required Attribution Model -> `attribution_model`, with **`linear` configured as the Metabase UI default** and allowed values `first_click`, `last_click`, `linear`; optional Channel -> `channel_name`; optional Campaign -> `campaign_id`. Connect all three to every CO card.

| Card | Query | Type | X axis | Y axis / selected field | Series / breakout |
| --- | --- | --- | --- | --- | --- |
| Total Spend | CO1 | Number | — | `total_spend` | — |
| Total Attributed Revenue | CO1 | Number | — | `total_attributed_revenue` | — |
| Overall ROAS | CO1 | Number | — | `overall_roas` | — |
| Overall ROI | CO1 | Number | — | `overall_roi` | — |
| Total Impressions | CO1 | Number | — | `total_impressions` | — |
| Total Clicks | CO1 | Number | — | `total_clicks` | — |
| Total Attributed Conversions | CO1 | Number | — | `total_attributed_conversions` | — |
| Channel Performance | CO2 | Table | — | Returned columns | One row per channel |
| Campaign Performance | CO3 | Table | — | Returned columns | One row per campaign |
| ROAS by Channel | CO2 | Bar | `channel_name` | `roas` | None |
| Spend vs Attributed Revenue | CO2 | Grouped bar | `channel_name` | `spend`, `attributed_revenue` | Two metric series; unstacked |
| Attributed Conversions by Campaign | CO3 | Bar | `campaign_label` | `attributed_conversions` | None |

Show CO2 columns: `channel_name`, `impressions`, `clicks`, `ctr`, `spend`, `attributed_conversions`, `attributed_revenue`, `cpa`, `roas`, `roi`. Show CO3 columns: `campaign_name`, `channel_name`, `spend`, `attributed_conversions`, `attributed_revenue`, `cpa`, `roas`, `roi`; keep `campaign_id`/`campaign_label` available for identification. IDs distinguish campaigns whose names might coincide.

**Interpretation:** model selection redistributes eligible-click conversion credit/value. Spend and event counts are unchanged by model selection. ROAS measures conversion revenue/spend; ROI measures net conversion revenue relative to spend. Positive spend with zero revenue yields ROAS 0 and ROI -100%; zero spend yields unavailable ratios. These are synthetic, observed results rather than causal estimates.

## 2. Attribution Model Comparison

**Purpose:** show how the methodology changes channel and campaign credit. Sources: `attribution_model_comparison` for MC1/MC2 and `campaign_performance` for MC3.

**Filters:** optional Channel -> `channel_name`, connected to every MC card. Keep all three attribution models visible; no Attribution Model filter is used here.

| Card | Query | Type | X axis | Y axis | Series / breakout |
| --- | --- | --- | --- | --- | --- |
| Channel Model Comparison | MC1 | Table | — | Returned columns | Channel + model |
| Attributed Revenue by Channel and Model | MC1 | Grouped bar | `channel_name` | `attributed_revenue` | `attribution_model`; unstacked |
| ROAS by Channel and Model | MC1 | Grouped bar | `channel_name` | `roas` | `attribution_model`; unstacked |
| Attributed Conversions by Channel and Model | MC1 | Grouped bar | `channel_name` | `attributed_conversions` | `attribution_model`; unstacked |
| Model Revenue Differences | MC2 | Table | — | `lowest_model_revenue`, `highest_model_revenue`, `model_revenue_spread` | One row per channel |
| Campaign Model Comparison | MC3 | Table | — | Returned columns | Campaign + model |

MC1 displays `channel_name`, `attribution_model`, `attributed_conversions`, `attributed_revenue`, `roas`, `roi`. Keep `channel_name` in the MC2 table. MC3 displays campaign/channel identifiers, model, credit, revenue, ROAS, and ROI. Use consistent colors for the three model series across charts.

**Interpretation:** MC2 spread is `MAX(model revenue) - MIN(model revenue)` within each channel, showing sensitivity to attribution methodology. It does not identify a universally correct model. Model results are alternative allocations of the same attributable population; summing or stacking models would double/triple-count the alternatives.

## 3. LTV & Acquisition Economics

**Purpose:** compare observed user value and acquisition cost. Sources: `channel_ltv` for AE1/AE2 and `campaign_ltv` for AE3.

**Filters:** optional Channel -> `channel_name`, connected to every AE card. No Attribution Model, Campaign, or Acquisition Month dashboard filter: these templates expose channel-level, full-period economics. Acquisition source is always first-click for the user's earliest attributable conversion.

| Card | Query | Type | X axis | Y axis / selected field | Series / breakout |
| --- | --- | --- | --- | --- | --- |
| Acquired Users | AE1 | Number | — | `acquired_users` | — |
| Total Lifetime Revenue | AE1 | Number | — | `total_lifetime_revenue` | — |
| Average LTV | AE1 | Number | — | `average_ltv` | — |
| Overall CAC (Average Acquisition Cost) | AE1 | Number | — | `cac` | — |
| LTV:CAC | AE1 | Number | — | `ltv_cac_ratio` | — |
| Average LTV by Channel | AE2 | Bar | `channel_name` | `average_ltv` | None |
| CAC by Channel | AE2 | Bar | `channel_name` | `cac` | None |
| LTV:CAC by Channel | AE2 | Bar | `channel_name` | `ltv_cac_ratio` | None |
| Channel Economics | AE2 | Table | — | Returned columns | One row per channel |
| Campaign LTV/CAC Comparison | AE3 | Table | — | Returned columns | One row per campaign |

Show acquisition counts, revenue, average/median LTV, spend, CAC, and LTV:CAC in the tables, with campaign/channel identifiers where returned.

**Interpretation:** LTV uses observed `user_revenue`, including zero-receipt acquired users; it is not a prediction. CAC uses official full-period spend divided by acquired users. The overall CAC card is computed from totals, not averaged channel CAC values. Initial conversion value and its initial revenue receipt represent the same transaction and must not be added together. There is no hardcoded “good” LTV:CAC benchmark.

## 4. Acquisition Cohort Analysis

**Purpose:** show how channel/month cohorts monetize after acquisition while exposing follow-up eligibility. Default source: live `acquisition_cohort_ltv`; optional source: `acquisition_cohort_materialized`, consistently substituted in both CA1 and CA2 after manual refresh/reconciliation.

**Filters:** optional Channel -> `channel_name`; optional Acquisition Month -> `acquisition_month`, using a single Date value. Connect both to CA1/CA2. Any selected day is normalized to its UTC acquisition month. No Campaign or Attribution Model filter is supported at this view's grain.

| Card | Query | Type | X axis | Y axis | Series / breakout |
| --- | --- | --- | --- | --- | --- |
| Cohort Revenue and Eligibility | CA1 | Table | — | Returned columns | Acquisition month + channel |
| Average Cumulative LTV by Horizon | CA2 | Line | Numeric `horizon_days`, ascending: 7, 30, 60, 90 | `average_ltv` | `cohort_series` = month + channel |
| Observation and Freshness Note | — | Text | — | — | — |

CA1 must show `acquisition_month`, `channel_name`, `acquired_users`, `observation_end`, all four `eligible_users_d*` counts, and all four `average_ltv_d*` values. The returned cumulative `revenue_d*` columns provide supporting totals. CA2 returns one row per cohort/horizon; retain `eligible_users` alongside the plotted metric for inspection. Select only `average_ltv` as the Y metric, not every numeric column. Filter to a month/channel when the chart has too many series.

Use an ordinary cohort table; optional cell coloring can help scanning. Set line-chart missing values to **Nothing**, with no zero-fill or interpolation. Do not merge month/channel series or average their averages.

**Interpretation and text card:** “Cumulative revenue covers [acquisition time, acquisition time + N elapsed days). Each horizon includes only users with complete follow-up. Eligible populations differ, so averages can fall across horizons. D90 is currently unavailable because no user has complete 90-day follow-up. NULL is unavailable, not zero revenue. These are monetization cohorts, not behavioral retention.”

Also label the source **Live** or **Materialized snapshot**. For a snapshot, manually record the last refresh time; `observation_end` is the dataset cutoff, not refresh time. The existing measured optimization reduced median warm read execution from 6.063 ms to 0.037 ms (99.389741%); this excludes refresh cost and does not predict Metabase page latency. See [OPTIMIZATION_RESULTS.md](OPTIMIZATION_RESULTS.md). Refresh after relevant changes using `REFRESH MATERIALIZED VIEW acquisition_cohort_materialized;`; there is no automated refresh.

## Shared lookup questions and aggregation rules

F1 supplies Channel dropdown `channel_name` values. F2 supplies Campaign `campaign_id` values with `campaign_label` display text for Campaign Overview. F3 is an available-month reference table for the cohort Date picker. These are supporting saved questions, not additional dashboards; they have no dashboard filter connections or chart axes.

| Metric across selected entities | Correct calculation |
| --- | --- |
| ROAS | `SUM(attributed_revenue) / SUM(spend)` |
| ROI | `(SUM(attributed_revenue) - SUM(spend)) / SUM(spend)` |
| CTR | `SUM(clicks) / SUM(impressions)` using numeric division |
| CPA | `SUM(spend) / SUM(attributed_conversions)` |
| Average LTV | `SUM(total_lifetime_revenue) / SUM(acquired_users)` |
| Overall CAC | `SUM(spend) / SUM(acquired_users)` |
| LTV:CAC | Overall average LTV / overall CAC |
| Cohort horizon average if intentionally combining cohorts | `SUM(revenue_dN) / SUM(eligible_users_dN)` over that horizon's eligible population |

The provided cards already calculate totals/ratios correctly. Do not use Metabase `AVG(roas)`, `AVG(roi)`, `AVG(ctr)`, `AVG(cac)`, or `AVG(ltv_cac_ratio)` to create overall cards. Do not average channel averages or medians. Zero denominators produce NULL; empty eligible populations remain unavailable. Filter to one model before totaling repeated spend/events, and keep attribution conversion revenue separate from lifetime receipts. No activity/date filter is supported by the full-period performance views.

## Questions to investigate after manual configuration

These are analytical questions, not findings:

- Does a channel receive more value under first-click than last-click?
- Do search campaigns receive more late-funnel credit, or awareness campaigns more linear credit?
- Are the highest-ROAS sources also the highest-LTV sources?
- Does low CAC correspond to the strongest LTV:CAC?
- How do mature acquisition cohorts differ in cumulative monetization, considering eligibility counts?

Preparation inspected the seven existing reporting views and executed all 14 templates with rendered parameters using short read-only SELECTs before writing these guides. Selected filter combinations also ran successfully; CO2 matched `channel_performance` under all three models. Native-question rendering, visualizations, and filter connections still require manual verification in Metabase.
