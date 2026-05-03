-- Migration v5: Add model quantization and format columns
-- Run this on the live database to support the new fields

ALTER TABLE `leaderboard_submissions`
  ADD COLUMN `model_quantization` varchar(32) DEFAULT NULL COMMENT 'e.g. Q4_K_M, FP16, 4-bit' AFTER `model_name`,
  ADD COLUMN `model_format` varchar(16) DEFAULT NULL COMMENT 'GGUF, MLX, or Unknown' AFTER `model_quantization`;

-- Optional: Add index for filtering by format
ALTER TABLE `leaderboard_submissions`
  ADD KEY `idx_model_format` (`model_format`);
