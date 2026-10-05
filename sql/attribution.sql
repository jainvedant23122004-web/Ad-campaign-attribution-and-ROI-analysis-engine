-- Conversion/click/model results only; no campaign aggregation or business metrics.
CREATE TABLE IF NOT EXISTS attribution_results (
    attribution_result_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversion_id BIGINT NOT NULL REFERENCES conversions (conversion_id) ON DELETE RESTRICT,
    campaign_id BIGINT NOT NULL REFERENCES campaigns (campaign_id) ON DELETE RESTRICT,
    channel_id BIGINT NOT NULL REFERENCES channels (channel_id) ON DELETE RESTRICT,
    creative_id BIGINT NOT NULL,
    click_id BIGINT NOT NULL REFERENCES clicks (click_id) ON DELETE RESTRICT,
    attribution_model TEXT NOT NULL,
    attribution_weight NUMERIC(38, 24) NOT NULL,
    attributed_conversion_value NUMERIC(38, 24) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT attribution_results_creative_campaign_fk
        FOREIGN KEY (creative_id, campaign_id)
        REFERENCES creatives (creative_id, campaign_id) ON DELETE RESTRICT,
    CONSTRAINT attribution_results_valid_model CHECK (
        attribution_model IN ('first_click', 'last_click', 'linear')
    ),
    CONSTRAINT attribution_results_valid_weight CHECK (
        attribution_weight > 0 AND attribution_weight <= 1
    ),
    CONSTRAINT attribution_results_nonnegative_value CHECK (
        attributed_conversion_value >= 0
        AND attributed_conversion_value <> 'NaN'::NUMERIC
    ),
    CONSTRAINT attribution_results_conversion_model_click_unique
        UNIQUE (conversion_id, attribution_model, click_id)
);

-- First/last click can each credit at most one click per conversion.
CREATE UNIQUE INDEX IF NOT EXISTS attribution_results_single_winner_idx
    ON attribution_results (conversion_id, attribution_model)
    WHERE attribution_model IN ('first_click', 'last_click');

-- Support the next milestone's campaign/channel summaries by model.
CREATE INDEX IF NOT EXISTS attribution_results_campaign_model_idx
    ON attribution_results (campaign_id, attribution_model);
CREATE INDEX IF NOT EXISTS attribution_results_channel_model_idx
    ON attribution_results (channel_id, attribution_model);

-- The uniqueness index already supports conversion/model lookup; do not duplicate it.
-- No FK to intermediate journey rows: journeys can be rebuilt independently.
-- The runner validates eligibility and source mappings before committing results.
