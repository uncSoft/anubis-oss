-- Migration v6: Add reasoning/thinking token split (issues #17, #18)
-- Run this on the live database before deploying the updated submit.php / leaderboard.php.
--
-- Background: prior to this migration, reasoning models that stream their
-- thoughts via `delta.reasoning_content` (DeepSeek-R1, Qwen3-thinking, GLM,
-- gpt-oss, etc.) had their thinking time charged against TTFT, and their
-- thinking tokens counted as output tokens — inflating tokens_per_second.
--
-- The client now decodes reasoning separately, so reasoning_tokens and
-- reasoning_duration carry the split. tokens_per_second on incoming
-- submissions excludes reasoning. Historical rows have NULL reasoning_*.

ALTER TABLE `leaderboard_submissions`
  ADD COLUMN `reasoning_tokens` int DEFAULT NULL COMMENT 'Tokens emitted as reasoning/thinking (subset of completion_tokens)' AFTER `avg_watts_per_token`,
  ADD COLUMN `reasoning_duration` double DEFAULT NULL COMMENT 'Seconds spent producing reasoning tokens' AFTER `reasoning_tokens`;
