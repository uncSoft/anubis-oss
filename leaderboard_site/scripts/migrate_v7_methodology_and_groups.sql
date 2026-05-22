-- Migration v7: Persist methodology_version + N-rep group context
-- Run this on the live database BEFORE deploying the updated submit.php.
--
-- Two things this migration captures that previous server versions were
-- silently dropping on the floor:
--
-- 1. `methodology_version` — added to the client in v3.4 (per-channel
--    power scale fix) but never wired into the server schema, so every
--    v3.4+ submission to date is unlabelled with respect to which
--    methodology era produced it. Backfill: NULL means pre-fix (v1).
--
-- 2. Run-group context — when a submission comes from one rep of an
--    N-rep group, `run_group_id` ties siblings together and the
--    group_* aggregate fields carry mean / 95% CI / stdev for the
--    headline metrics. A future leaderboard view can group by
--    (machine_id, run_group_id) to display mean ± CI instead of
--    individual rows.
--
-- All columns are nullable so historical rows stay valid without
-- backfill, and pre-v3.5 clients (which don't send these fields) keep
-- inserting cleanly.

ALTER TABLE `leaderboard_submissions`
  ADD COLUMN `methodology_version` int DEFAULT NULL
    COMMENT 'Methodology era (1=pre-v3.4 power undercount, 2=v3.4+ per-channel scale fix). NULL = pre-fix.'
    AFTER `reasoning_duration`,

  -- Group identity
  ADD COLUMN `run_group_id` bigint(20) UNSIGNED DEFAULT NULL
    COMMENT 'Client-local group rowid. (machine_id, run_group_id) uniquely identifies a group.'
    AFTER `methodology_version`,
  ADD COLUMN `group_sample_count` int DEFAULT NULL
    COMMENT 'Total completed reps in the group (>= group_repetition_index).'
    AFTER `run_group_id`,
  ADD COLUMN `group_repetition_index` int DEFAULT NULL
    COMMENT '1-based position of this rep within its group.'
    AFTER `group_sample_count`,
  ADD COLUMN `group_seed_strategy` varchar(16) DEFAULT NULL
    COMMENT '"random" (per-rep seed) or "fixed" (deterministic sampler across reps).'
    AFTER `group_repetition_index`,

  -- Tokens/sec aggregate (headline metric)
  ADD COLUMN `group_mean_tokens_per_second` double DEFAULT NULL
    AFTER `group_seed_strategy`,
  ADD COLUMN `group_stdev_tokens_per_second` double DEFAULT NULL
    AFTER `group_mean_tokens_per_second`,
  ADD COLUMN `group_ci_low_tokens_per_second` double DEFAULT NULL
    COMMENT '95% bootstrap CI lower bound (1000 resamples).'
    AFTER `group_stdev_tokens_per_second`,
  ADD COLUMN `group_ci_high_tokens_per_second` double DEFAULT NULL
    COMMENT '95% bootstrap CI upper bound.'
    AFTER `group_ci_low_tokens_per_second`,

  -- TTFT aggregate
  ADD COLUMN `group_mean_time_to_first_token` double DEFAULT NULL
    AFTER `group_ci_high_tokens_per_second`,
  ADD COLUMN `group_ci_low_time_to_first_token` double DEFAULT NULL
    AFTER `group_mean_time_to_first_token`,
  ADD COLUMN `group_ci_high_time_to_first_token` double DEFAULT NULL
    AFTER `group_ci_low_time_to_first_token`,

  -- J/Tok aggregate
  ADD COLUMN `group_mean_watts_per_token` double DEFAULT NULL
    AFTER `group_ci_high_time_to_first_token`,
  ADD COLUMN `group_ci_low_watts_per_token` double DEFAULT NULL
    AFTER `group_mean_watts_per_token`,
  ADD COLUMN `group_ci_high_watts_per_token` double DEFAULT NULL
    AFTER `group_ci_low_watts_per_token`;

-- Index for "fetch all reps of a group" and "deduplicate groups across
-- the leaderboard". Composite (machine_id, run_group_id) because
-- run_group_id is only unique per machine — two different machines can
-- both have a group with id=42.
ALTER TABLE `leaderboard_submissions`
  ADD KEY `idx_run_group` (`machine_id`, `run_group_id`);
