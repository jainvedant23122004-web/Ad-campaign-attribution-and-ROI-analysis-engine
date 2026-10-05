-- Fresh PostgreSQL database initialization; SQL is the schema source of truth.
-- scripts/init_db.py executes this entire file in one transaction.
-- Existing tables cause an error: never drop data or silently accept schema drift.
-- All money uses one project-wide currency with six decimal places for ad costs.

CREATE TABLE users (
    user_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Advertising exposure may precede signup, so this date is optional.
    signup_date DATE,
    country VARCHAR(2) NOT NULL,
    device_type TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE channels (
    channel_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_name TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT channels_name_not_blank CHECK (btrim(channel_name) <> '')
);

CREATE TABLE campaigns (
    campaign_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_id BIGINT NOT NULL REFERENCES channels (channel_id) ON DELETE RESTRICT,
    campaign_name TEXT NOT NULL,
    objective TEXT NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT campaigns_name_not_blank CHECK (btrim(campaign_name) <> ''),
    CONSTRAINT campaigns_date_order CHECK (end_date IS NULL OR end_date >= start_date)
);

CREATE TABLE creatives (
    creative_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_id BIGINT NOT NULL REFERENCES campaigns (campaign_id) ON DELETE RESTRICT,
    creative_name TEXT NOT NULL,
    creative_type TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT creatives_name_not_blank CHECK (btrim(creative_name) <> ''),
    -- Enables event foreign keys to enforce creative/campaign consistency.
    CONSTRAINT creatives_id_campaign_unique UNIQUE (creative_id, campaign_id)
);

CREATE TABLE impressions (
    impression_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (user_id) ON DELETE RESTRICT,
    campaign_id BIGINT NOT NULL REFERENCES campaigns (campaign_id) ON DELETE RESTRICT,
    creative_id BIGINT NOT NULL,
    impression_time TIMESTAMPTZ NOT NULL,
    placement TEXT,
    cost NUMERIC(18, 6) NOT NULL,
    CONSTRAINT impressions_creative_campaign_fk
        FOREIGN KEY (creative_id, campaign_id)
        REFERENCES creatives (creative_id, campaign_id) ON DELETE RESTRICT,
    CONSTRAINT impressions_cost_nonnegative CHECK (cost >= 0)
);

CREATE TABLE clicks (
    click_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (user_id) ON DELETE RESTRICT,
    campaign_id BIGINT NOT NULL REFERENCES campaigns (campaign_id) ON DELETE RESTRICT,
    creative_id BIGINT NOT NULL,
    click_time TIMESTAMPTZ NOT NULL,
    cost NUMERIC(18, 6) NOT NULL,
    CONSTRAINT clicks_creative_campaign_fk
        FOREIGN KEY (creative_id, campaign_id)
        REFERENCES creatives (creative_id, campaign_id) ON DELETE RESTRICT,
    CONSTRAINT clicks_cost_nonnegative CHECK (cost >= 0)
);

CREATE TABLE conversions (
    conversion_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (user_id) ON DELETE RESTRICT,
    conversion_time TIMESTAMPTZ NOT NULL,
    conversion_type TEXT NOT NULL,
    conversion_value NUMERIC(18, 6) NOT NULL,
    CONSTRAINT conversions_value_nonnegative CHECK (conversion_value >= 0)
    -- Campaign credit is calculated later, separately for each attribution model.
);

CREATE TABLE campaign_spend (
    campaign_spend_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_id BIGINT NOT NULL REFERENCES campaigns (campaign_id) ON DELETE RESTRICT,
    spend_date DATE NOT NULL,
    spend NUMERIC(18, 6) NOT NULL,
    CONSTRAINT campaign_spend_campaign_date_unique UNIQUE (campaign_id, spend_date),
    CONSTRAINT campaign_spend_nonnegative CHECK (spend >= 0)
);

CREATE TABLE user_revenue (
    revenue_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users (user_id) ON DELETE RESTRICT,
    revenue_time TIMESTAMPTZ NOT NULL,
    revenue_amount NUMERIC(18, 6) NOT NULL,
    revenue_type TEXT NOT NULL,
    CONSTRAINT user_revenue_amount_nonnegative CHECK (revenue_amount >= 0)
);

-- User/time indexes support ordered journeys and attribution-window lookups.
CREATE INDEX impressions_user_time_idx ON impressions (user_id, impression_time);
CREATE INDEX clicks_user_time_idx ON clicks (user_id, click_time);
CREATE INDEX conversions_user_time_idx ON conversions (user_id, conversion_time);

-- Campaign/time indexes support campaign event summaries for a date range.
CREATE INDEX impressions_campaign_time_idx ON impressions (campaign_id, impression_time);
CREATE INDEX clicks_campaign_time_idx ON clicks (campaign_id, click_time);

-- Supports per-user revenue histories and later LTV observation windows.
CREATE INDEX user_revenue_user_time_idx ON user_revenue (user_id, revenue_time);

-- PRIMARY KEY and UNIQUE constraints already create their supporting indexes.
-- The campaign_spend uniqueness index also supports per-campaign date ranges.
