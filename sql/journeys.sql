-- Intermediate eligibility only: no attribution credit or revenue allocation.
-- Applied transactionally by scripts/build_journeys.py; source tables are unchanged.
CREATE TABLE IF NOT EXISTS conversion_touchpoints (
    conversion_touchpoint_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversion_id BIGINT NOT NULL REFERENCES conversions (conversion_id) ON DELETE RESTRICT,
    user_id BIGINT NOT NULL REFERENCES users (user_id) ON DELETE RESTRICT,
    campaign_id BIGINT NOT NULL REFERENCES campaigns (campaign_id) ON DELETE RESTRICT,
    creative_id BIGINT NOT NULL,
    channel_id BIGINT NOT NULL REFERENCES channels (channel_id) ON DELETE RESTRICT,
    -- Exactly one original event ID preserves provenance and repeated exposures.
    impression_id BIGINT REFERENCES impressions (impression_id) ON DELETE RESTRICT,
    click_id BIGINT REFERENCES clicks (click_id) ON DELETE RESTRICT,
    touchpoint_type TEXT NOT NULL,
    touchpoint_time TIMESTAMPTZ NOT NULL,
    conversion_time TIMESTAMPTZ NOT NULL,
    seconds_before_conversion NUMERIC(20, 6) NOT NULL,
    attribution_window_days INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT conversion_touchpoints_creative_campaign_fk
        FOREIGN KEY (creative_id, campaign_id)
        REFERENCES creatives (creative_id, campaign_id) ON DELETE RESTRICT,
    CONSTRAINT conversion_touchpoints_source_type CHECK (
        (touchpoint_type = 'impression' AND impression_id IS NOT NULL AND click_id IS NULL)
        OR (touchpoint_type = 'click' AND click_id IS NOT NULL AND impression_id IS NULL)
    ),
    CONSTRAINT conversion_touchpoints_positive_window CHECK (attribution_window_days > 0),
    CONSTRAINT conversion_touchpoints_before_conversion CHECK (touchpoint_time < conversion_time),
    CONSTRAINT conversion_touchpoints_within_window CHECK (
        touchpoint_time >= conversion_time - attribution_window_days * INTERVAL '24 hours'
    ),
    CONSTRAINT conversion_touchpoints_exact_duration CHECK (
        seconds_before_conversion >= 0
        AND seconds_before_conversion = EXTRACT(EPOCH FROM (conversion_time - touchpoint_time))
    ),
    -- Nullable source IDs permit one row per conversion/event in each source table.
    CONSTRAINT conversion_touchpoints_impression_unique UNIQUE (conversion_id, impression_id),
    CONSTRAINT conversion_touchpoints_click_unique UNIQUE (conversion_id, click_id)
);

-- Supports either chronological direction for a conversion without storing ranks.
CREATE INDEX IF NOT EXISTS conversion_touchpoints_conversion_time_idx
    ON conversion_touchpoints (conversion_id, touchpoint_time);

-- Supports inspecting a user's eligible history across conversions.
CREATE INDEX IF NOT EXISTS conversion_touchpoints_user_time_idx
    ON conversion_touchpoints (user_id, touchpoint_time);

-- Denormalized user/channel/creative IDs and conversion timestamps make the
-- intermediate rows understandable without repeatedly joining raw events.
-- The build query supplies these consistently from the source relationships.
