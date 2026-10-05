"""Generate small, reproducible advertising CSVs without a database connection."""

import argparse
import csv
import random
import sys
from bisect import bisect_left
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from pathlib import Path


OUTPUT_DIR = Path(__file__).resolve().parent.parent / "data" / "generated"
MONEY_QUANTUM = Decimal("0.000001")
MONEY_COLUMNS = {"cost", "spend", "conversion_value", "revenue_amount"}
NULLABLE_COLUMNS = {"signup_date", "end_date", "placement"}

# Columns match sql/schema.sql. Order also supplies the foreign-key-safe load order.
TABLE_COLUMNS = {
    "channels": ("channel_id", "channel_name", "created_at"),
    "users": ("user_id", "signup_date", "country", "device_type", "created_at"),
    "campaigns": (
        "campaign_id", "channel_id", "campaign_name", "objective",
        "start_date", "end_date", "created_at",
    ),
    "creatives": (
        "creative_id", "campaign_id", "creative_name", "creative_type", "created_at",
    ),
    "impressions": (
        "impression_id", "user_id", "campaign_id", "creative_id",
        "impression_time", "placement", "cost",
    ),
    "clicks": ("click_id", "user_id", "campaign_id", "creative_id", "click_time", "cost"),
    "conversions": (
        "conversion_id", "user_id", "conversion_time", "conversion_type", "conversion_value",
    ),
    "campaign_spend": ("campaign_spend_id", "campaign_id", "spend_date", "spend"),
    "user_revenue": ("revenue_id", "user_id", "revenue_time", "revenue_amount", "revenue_type"),
}


@dataclass(frozen=True)
class GeneratorConfig:
    seed: int = 42
    users: int = 5_000
    impressions: int = 50_000
    target_clicks: int = 5_000
    target_conversions: int = 1_000
    # 90 UTC days: 2025-01-01 inclusive through 2025-04-01 exclusive.
    start_date: date = date(2025, 1, 1)
    days: int = 90

    def validate(self) -> None:
        if self.users < 1 or self.impressions < self.users:
            raise ValueError("Use at least one user and at least one impression per user.")
        if not 0 <= self.target_clicks <= self.impressions:
            raise ValueError("The click target must be between zero and the impression count.")
        if not 0 <= self.target_conversions <= self.users:
            raise ValueError("The conversion target must be between zero and the user count.")
        if self.days < 7:
            raise ValueError("The observation period must be at least seven days.")


@dataclass(frozen=True)
class ChannelBehavior:
    name: str
    volume_weight: float
    click_tendency: float
    conversion_tendency: float
    early_weight: float
    late_weight: float
    # Integer millionths of one project-wide currency unit; no float money.
    impression_cost_microunits: tuple[int, int]
    click_cost_microunits: tuple[int, int]
    campaigns: tuple[str, str]
    creative_type: str
    placement: str


# Educational assumptions, not estimates of actual platform performance.
CHANNEL_BEHAVIORS = (
    ChannelBehavior("Google Search", .18, .18, .45, .65, 1.60,
                    (0, 0), (800_000, 2_000_000),
                    ("Brand Search", "Generic Search"), "text", "search_results"),
    ChannelBehavior("Meta", .25, .11, .26, 1.00, 1.20,
                    (4_000, 10_000), (150_000, 500_000),
                    ("Prospecting", "Retargeting"), "image", "feed"),
    ChannelBehavior("Programmatic Display", .32, .02, .06, 1.80, .65,
                    (1_000, 4_000), (0, 0),
                    ("Awareness Display", "Retargeting Display"), "image", "in_app_banner"),
    ChannelBehavior("Affiliate", .06, .24, .50, .60, 1.50,
                    (0, 0), (400_000, 1_200_000),
                    ("Partner A", "Partner B"), "text", "partner_link"),
    ChannelBehavior("YouTube", .19, .04, .12, 1.50, .80,
                    (3_000, 8_000), (0, 0),
                    ("Awareness Video", "Product Video"), "video", "video_preroll"),
)


def money(rng: random.Random, bounds: tuple[int, int]) -> Decimal:
    return Decimal(rng.randint(*bounds)) * MONEY_QUANTUM


def generate_dataset(config: GeneratorConfig) -> dict[str, list[dict]]:
    """Simulate exposures and responses; do not calculate attribution or metrics."""
    config.validate()
    rng = random.Random(config.seed)
    start = datetime.combine(config.start_date, time.min, tzinfo=timezone.utc)
    end = start + timedelta(days=config.days)
    created_at = start - timedelta(days=1)
    data = {table: [] for table in TABLE_COLUMNS}
    behavior_by_id = dict(enumerate(CHANNEL_BEHAVIORS, start=1))
    campaigns_by_channel = defaultdict(list)
    creatives_by_campaign = defaultdict(list)

    for channel_id, behavior in behavior_by_id.items():
        data["channels"].append({
            "channel_id": channel_id, "channel_name": behavior.name, "created_at": created_at,
        })
        for campaign_name in behavior.campaigns:
            campaign_id = len(data["campaigns"]) + 1
            campaigns_by_channel[channel_id].append(campaign_id)
            data["campaigns"].append({
                "campaign_id": campaign_id, "channel_id": channel_id,
                "campaign_name": f"{behavior.name} - {campaign_name}",
                "objective": "awareness" if "Awareness" in campaign_name else "acquisition",
                "start_date": config.start_date, "end_date": (end - timedelta(days=1)).date(),
                "created_at": created_at,
            })
            for variant in range(1, 4):
                creative_id = len(data["creatives"]) + 1
                creatives_by_campaign[campaign_id].append(creative_id)
                data["creatives"].append({
                    "creative_id": creative_id, "campaign_id": campaign_id,
                    "creative_name": f"{campaign_name} Variant {variant}",
                    "creative_type": behavior.creative_type, "created_at": created_at,
                })

    campaign_channels = {row["campaign_id"]: row["channel_id"] for row in data["campaigns"]}
    user_behavior = {}
    for user_id in range(1, config.users + 1):
        anchor = start + timedelta(seconds=rng.randrange((config.days - 4) * 86_400))
        max_span = min(18 * 86_400, int((end - anchor).total_seconds()) - 2 * 86_400)
        user_behavior[user_id] = {
            "anchor": anchor, "span": rng.randint(86_400, max_span),
            "interest": rng.uniform(.65, 1.35), "preferred_channel": rng.randint(1, 5),
        }
        data["users"].append({
            "user_id": user_id, "signup_date": None,
            "country": rng.choices(("IN", "US", "GB", "CA", "AU"), (45, 25, 15, 8, 7))[0],
            "device_type": rng.choices(("android", "ios"), (70, 30))[0],
            "created_at": created_at,
        })

    def add_impression(user_id: int, channel_id: int, timestamp: datetime) -> dict:
        behavior = behavior_by_id[channel_id]
        campaign_id = rng.choice(campaigns_by_channel[channel_id])
        row = {
            "impression_id": len(data["impressions"]) + 1, "user_id": user_id,
            "campaign_id": campaign_id,
            "creative_id": rng.choice(creatives_by_campaign[campaign_id]),
            "impression_time": timestamp, "placement": behavior.placement,
            "cost": money(rng, behavior.impression_cost_microunits),
        }
        data["impressions"].append(row)
        return row

    def add_click(impression: dict) -> dict:
        behavior = behavior_by_id[campaign_channels[impression["campaign_id"]]]
        row = {
            "click_id": len(data["clicks"]) + 1, "user_id": impression["user_id"],
            "campaign_id": impression["campaign_id"], "creative_id": impression["creative_id"],
            "click_time": impression["impression_time"] + timedelta(seconds=rng.randint(60, 1_800)),
            "cost": money(rng, behavior.click_cost_microunits),
        }
        data["clicks"].append(row)
        return row

    def add_conversion(user_id: int, timestamp: datetime) -> None:
        kind = rng.choices(("purchase", "subscription"), (80, 20))[0]
        cents = rng.randint(2_000, 22_000) if kind == "purchase" else rng.randint(999, 4_999)
        data["conversions"].append({
            "conversion_id": len(data["conversions"]) + 1, "user_id": user_id,
            "conversion_time": timestamp, "conversion_type": kind,
            "conversion_value": (Decimal(cents) / 100).quantize(MONEY_QUANTUM),
        })

    # A small designed cohort guarantees distinct pre-conversion click channels.
    # These users receive no other touches, keeping this sequence interpretable.
    cohort_size = min(100, config.users // 20, (config.impressions - config.users) // 2,
                      config.target_clicks // 2, config.target_conversions // 4)
    for user_id in range(1, cohort_size + 1):
        anchor = user_behavior[user_id]["anchor"]
        add_impression(user_id, 3, anchor)  # Display awareness, no required click.
        add_click(add_impression(user_id, 2, anchor + timedelta(days=1)))
        last_click = add_click(add_impression(user_id, 1, anchor + timedelta(days=2)))
        add_conversion(user_id, last_click["click_time"] + timedelta(hours=rng.randint(1, 24)))

    general_impressions = []
    click_weights = []
    remaining_users = config.users - cohort_size
    for index in range(config.impressions - 3 * cohort_size):
        # First expose each remaining user, then allow repeated exposures.
        user_id = (cohort_size + index + 1 if index < remaining_users
                   else rng.randint(cohort_size + 1, config.users))
        profile = user_behavior[user_id]
        offset = rng.randint(0, profile["span"])
        progress = offset / profile["span"]
        weights = [
            behavior.volume_weight
            * (behavior.early_weight * (1 - progress) + behavior.late_weight * progress)
            * (1.3 if channel_id == profile["preferred_channel"] else 1)
            for channel_id, behavior in behavior_by_id.items()
        ]
        channel_id = rng.choices(tuple(behavior_by_id), weights=weights)[0]
        impression = add_impression(user_id, channel_id, profile["anchor"] + timedelta(seconds=offset))
        general_impressions.append(impression)
        click_weights.append(behavior_by_id[channel_id].click_tendency * profile["interest"])

    # Scale relative tendencies to an approximate requested volume, then sample.
    click_scale = (config.target_clicks - 2 * cohort_size) / sum(click_weights)
    for impression, weight in zip(general_impressions, click_weights):
        if rng.random() < min(.95, weight * click_scale):
            add_click(impression)

    latest_exposure = {}
    exposure_channels = defaultdict(set)
    clicks_by_user = defaultdict(list)
    for impression in general_impressions:
        user_id = impression["user_id"]
        latest_exposure[user_id] = max(latest_exposure.get(user_id, start), impression["impression_time"])
        exposure_channels[user_id].add(campaign_channels[impression["campaign_id"]])
    for click in data["clicks"]:
        clicks_by_user[click["user_id"]].append(click)

    conversion_weights = {}
    for user_id in range(cohort_size + 1, config.users + 1):
        clicks = clicks_by_user[user_id]
        if clicks:
            tendencies = [behavior_by_id[campaign_channels[row["campaign_id"]]].conversion_tendency
                          for row in clicks]
            weight = sum(tendencies) / len(tendencies) * (1 + .10 * min(len(clicks), 5))
            weight *= 1 + .10 * (len({row["campaign_id"] for row in clicks}) - 1)
        else:
            weight = .008  # A few impression-only conversions are possible.
        # Awareness can assist later conversion without directly receiving credit.
        weight *= 1 + (.15 if 5 in exposure_channels[user_id] else 0)
        weight *= 1 + (.08 if 3 in exposure_channels[user_id] else 0)
        conversion_weights[user_id] = weight * user_behavior[user_id]["interest"]

    conversion_scale = (config.target_conversions - cohort_size) / sum(conversion_weights.values())
    for user_id, weight in conversion_weights.items():
        if rng.random() >= min(.95, weight * conversion_scale):
            continue
        latest_touch = max([latest_exposure[user_id]]
                           + [row["click_time"] for row in clicks_by_user[user_id]])
        max_delay = min(48 * 3_600, int((end - latest_touch).total_seconds()) - 120)
        add_conversion(user_id, latest_touch + timedelta(seconds=rng.randint(3_600, max_delay)))

    for conversion in data["conversions"]:
        data["users"][conversion["user_id"] - 1]["signup_date"] = conversion["conversion_time"].date()

    # Daily spend is precisely the sum of impression and click costs, not extra cost.
    daily_cost = defaultdict(lambda: Decimal("0"))
    for table, timestamp_column in (("impressions", "impression_time"), ("clicks", "click_time")):
        for row in data[table]:
            daily_cost[(row["campaign_id"], row[timestamp_column].date())] += row["cost"]
    for campaign in data["campaigns"]:
        for day_offset in range(config.days):
            spend_date = config.start_date + timedelta(days=day_offset)
            data["campaign_spend"].append({
                "campaign_spend_id": len(data["campaign_spend"]) + 1,
                "campaign_id": campaign["campaign_id"], "spend_date": spend_date,
                "spend": daily_cost[(campaign["campaign_id"], spend_date)].quantize(MONEY_QUANTUM),
            })

    # Only acquired users generate revenue. Every conversion has a matching receipt;
    # higher-value purchasers are more likely to return and may return more often.
    for conversion in data["conversions"]:
        timestamp = conversion["conversion_time"] + timedelta(seconds=60)
        amount = conversion["conversion_value"]
        kind = conversion["conversion_type"]
        data["user_revenue"].append({
            "revenue_id": len(data["user_revenue"]) + 1, "user_id": conversion["user_id"],
            "revenue_time": timestamp, "revenue_amount": amount, "revenue_type": kind,
        })
        high_value = amount >= Decimal("100")
        if rng.random() < (.70 if high_value else .35):
            for _ in range(rng.randint(1, 4 if high_value else 2)):
                timestamp += timedelta(days=rng.randint(3, 20), hours=rng.randint(0, 23))
                if timestamp >= end:
                    break
                repeated_amount = (amount * Decimal(rng.randint(50, 140)) / 100).quantize(MONEY_QUANTUM)
                data["user_revenue"].append({
                    "revenue_id": len(data["user_revenue"]) + 1, "user_id": conversion["user_id"],
                    "revenue_time": timestamp, "revenue_amount": repeated_amount,
                    "revenue_type": "renewal" if kind == "subscription" else "repeat_purchase",
                })

    validate_dataset(data, start, end)
    return data


def validate_dataset(data: dict[str, list[dict]], start: datetime, end: datetime) -> None:
    """Small integrity checks shared by generation and CSV loading, not a test suite."""
    if set(data) != set(TABLE_COLUMNS) or start >= end:
        raise ValueError("The dataset tables or observation bounds are invalid.")
    ids = {}
    for table, columns in TABLE_COLUMNS.items():
        primary_key = columns[0]
        ids[table] = set()
        for row in data[table]:
            if set(row) != set(columns):
                raise ValueError(f"Unexpected columns in {table}.")
            row_id = row[primary_key]
            if not isinstance(row_id, int) or not 0 < row_id < 2**63 - 1 or row_id in ids[table]:
                raise ValueError(f"Invalid or duplicate primary key in {table}.")
            ids[table].add(row_id)
            for column, value in row.items():
                if value is None:
                    if column not in NULLABLE_COLUMNS:
                        raise ValueError(f"Missing required value in {table}.{column}.")
                    continue
                if column in MONEY_COLUMNS:
                    if (not isinstance(value, Decimal) or not value.is_finite()
                            or value < 0 or value >= Decimal("1000000000000")
                            or value != value.quantize(MONEY_QUANTUM)):
                        raise ValueError(f"Invalid monetary value in {table}.{column}.")
                elif column == "created_at" or column.endswith("_time"):
                    if not isinstance(value, datetime) or value.utcoffset() is None:
                        raise ValueError(f"Timezone-aware timestamp required in {table}.{column}.")
                elif column.endswith("_date"):
                    if type(value) is not date:
                        raise ValueError(f"Date required in {table}.{column}.")
                elif not column.endswith("_id") and (not isinstance(value, str) or not value.strip()):
                    raise ValueError(f"Nonblank text required in {table}.{column}.")

    channels = {row["channel_id"]: row for row in data["channels"]}
    campaigns = {row["campaign_id"]: row for row in data["campaigns"]}
    creatives = {row["creative_id"]: row for row in data["creatives"]}
    if len({row["channel_name"] for row in channels.values()}) != len(channels):
        raise ValueError("Channel names must be unique.")
    for user in data["users"]:
        if len(user["country"]) != 2 or user["device_type"] not in {"android", "ios"}:
            raise ValueError("Users need two-letter country codes and android/ios devices.")
        if user["signup_date"] is not None and not start.date() <= user["signup_date"] < end.date():
            raise ValueError("Signup date falls outside the observation period.")
    for campaign in campaigns.values():
        if (campaign["channel_id"] not in channels or campaign["end_date"] is None
                or campaign["end_date"] < campaign["start_date"]):
            raise ValueError("Invalid campaign channel or dates.")
    for creative in creatives.values():
        if creative["campaign_id"] not in campaigns:
            raise ValueError("Creative references an unknown campaign.")

    exposure_times = defaultdict(list)
    first_touch = {}
    event_spend = defaultdict(lambda: Decimal("0"))
    for table, time_column in (("impressions", "impression_time"), ("clicks", "click_time"),
                               ("conversions", "conversion_time"), ("user_revenue", "revenue_time")):
        for row in data[table]:
            user_id, timestamp = row["user_id"], row[time_column]
            if user_id not in ids["users"] or not start <= timestamp < end:
                raise ValueError(f"Invalid user or event timestamp in {table}.")
            if table in {"impressions", "clicks"}:
                campaign = campaigns.get(row["campaign_id"])
                creative = creatives.get(row["creative_id"])
                if (campaign is None or creative is None
                        or creative["campaign_id"] != row["campaign_id"]
                        or not campaign["start_date"] <= timestamp.date() <= campaign["end_date"]):
                    raise ValueError(f"Invalid campaign/creative relationship or dates in {table}.")
                event_spend[(row["campaign_id"], timestamp.date())] += row["cost"]
                if table == "impressions":
                    key = (user_id, row["campaign_id"], row["creative_id"])
                    exposure_times[key].append(timestamp)
                    first_touch[user_id] = min(first_touch.get(user_id, timestamp), timestamp)

    for timestamps in exposure_times.values():
        timestamps.sort()
    for click in data["clicks"]:
        key = (click["user_id"], click["campaign_id"], click["creative_id"])
        if bisect_left(exposure_times[key], click["click_time"]) == 0:
            raise ValueError("A click has no earlier matching impression.")
    first_conversion = {}
    for conversion in data["conversions"]:
        user_id, timestamp = conversion["user_id"], conversion["conversion_time"]
        if (user_id not in first_touch or timestamp <= first_touch[user_id]
                or conversion["conversion_value"] <= 0):
            raise ValueError("A conversion needs a prior exposure and positive value.")
        first_conversion[user_id] = min(first_conversion.get(user_id, timestamp), timestamp)
    for revenue in data["user_revenue"]:
        user_id = revenue["user_id"]
        if user_id not in first_conversion or revenue["revenue_time"] < first_conversion[user_id]:
            raise ValueError("Revenue must follow a conversion for the same user.")

    spend_rows = {}
    for row in data["campaign_spend"]:
        campaign = campaigns.get(row["campaign_id"])
        key = (row["campaign_id"], row["spend_date"])
        if (campaign is None or key in spend_rows
                or not start.date() <= row["spend_date"] < end.date()
                or not campaign["start_date"] <= row["spend_date"] <= campaign["end_date"]):
            raise ValueError("Invalid or duplicate campaign/date spend row.")
        spend_rows[key] = row["spend"]
    if (any(spend_rows.get(key) != amount for key, amount in event_spend.items())
            or any(amount != event_spend[key] for key, amount in spend_rows.items())):
        raise ValueError("Daily campaign spend must equal impression plus click costs.")


def write_csvs(data: dict[str, list[dict]]) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for table, columns in TABLE_COLUMNS.items():
        with (OUTPUT_DIR / f"{table}.csv").open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
            writer.writeheader()
            for row in data[table]:
                writer.writerow({
                    column: ("" if value is None else format(value, ".6f") if isinstance(value, Decimal)
                             else value.isoformat() if isinstance(value, (date, datetime)) else value)
                    for column, value in row.items()
                })


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--users", type=int, default=5_000)
    parser.add_argument("--impressions", type=int, default=50_000)
    parser.add_argument("--clicks", type=int, default=5_000, help="Approximate click target")
    parser.add_argument("--conversions", type=int, default=1_000, help="Approximate conversion target")
    parser.add_argument("--start-date", type=date.fromisoformat, default=date(2025, 1, 1))
    parser.add_argument("--days", type=int, default=90)
    args = parser.parse_args()
    config = GeneratorConfig(args.seed, args.users, args.impressions, args.clicks,
                             args.conversions, args.start_date, args.days)
    try:
        data = generate_dataset(config)
        write_csvs(data)
    except (ValueError, OSError) as error:
        print(f"Generation failed: {error}", file=sys.stderr)
        return 1

    print(f"Synthetic dataset generated successfully (seed {config.seed}).")
    for table in TABLE_COLUMNS:
        print(f"{table:16} {len(data[table]):>8,}")
    campaign_channels = {row["campaign_id"]: row["channel_id"] for row in data["campaigns"]}
    impressions = Counter(campaign_channels[row["campaign_id"]] for row in data["impressions"])
    clicks = Counter(campaign_channels[row["campaign_id"]] for row in data["clicks"])
    print("\nChannel                       Impressions   Clicks")
    for channel in data["channels"]:
        channel_id = channel["channel_id"]
        print(f"{channel['channel_name']:28} {impressions[channel_id]:>11,} {clicks[channel_id]:>8,}")
    print(f"\nCSV directory: {OUTPUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
