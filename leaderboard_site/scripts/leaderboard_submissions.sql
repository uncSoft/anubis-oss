-- phpMyAdmin SQL Dump
-- version 5.2.2
-- https://www.phpmyadmin.net/
--
-- Host: localhost:3306
-- Generation Time: Feb 23, 2026 at 09:39 PM
-- Server version: 11.4.9-MariaDB-cll-lve-log
-- PHP Version: 8.3.29

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `devpqyqg_leaderboard`
--

-- --------------------------------------------------------

--
-- Table structure for table `leaderboard_submissions`
--

CREATE TABLE `leaderboard_submissions` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `machine_id` char(64) NOT NULL COMMENT 'SHA256 of IOPlatformUUID + salt',
  `display_name` varchar(64) NOT NULL,
  `app_version` varchar(32) NOT NULL,
  `submitted_at` datetime NOT NULL DEFAULT current_timestamp(),
  `model_id` varchar(255) NOT NULL,
  `model_name` varchar(255) NOT NULL,
  `model_quantization` varchar(32) DEFAULT NULL COMMENT 'e.g. Q4_K_M, FP16, 4-bit',
  `model_format` varchar(16) DEFAULT NULL COMMENT 'GGUF, MLX, or Unknown',
  `backend` varchar(64) NOT NULL,
  `started_at` datetime NOT NULL,
  `ended_at` datetime DEFAULT NULL,
  `prompt` text NOT NULL,
  `status` varchar(32) NOT NULL DEFAULT 'completed',
  `total_tokens` int(10) UNSIGNED DEFAULT NULL,
  `prompt_tokens` int(10) UNSIGNED DEFAULT NULL,
  `completion_tokens` int(10) UNSIGNED DEFAULT NULL,
  `tokens_per_second` double DEFAULT NULL,
  `total_duration` double DEFAULT NULL,
  `prompt_eval_duration` double DEFAULT NULL,
  `eval_duration` double DEFAULT NULL,
  `time_to_first_token` double DEFAULT NULL,
  `load_duration` double DEFAULT NULL,
  `context_length` int(10) UNSIGNED DEFAULT NULL,
  `peak_memory_bytes` bigint(20) UNSIGNED DEFAULT NULL,
  `avg_token_latency_ms` double DEFAULT NULL,
  `avg_gpu_power_watts` double DEFAULT NULL,
  `peak_gpu_power_watts` double DEFAULT NULL,
  `avg_system_power_watts` double DEFAULT NULL,
  `peak_system_power_watts` double DEFAULT NULL,
  `avg_gpu_frequency_mhz` double DEFAULT NULL,
  `peak_gpu_frequency_mhz` double DEFAULT NULL,
  `avg_watts_per_token` double DEFAULT NULL,
  `backend_process_name` varchar(128) DEFAULT NULL,
  `chip_name` varchar(128) DEFAULT NULL,
  `chip_core_count` int(10) UNSIGNED DEFAULT NULL,
  `chip_p_cores` int(10) UNSIGNED DEFAULT NULL,
  `chip_e_cores` int(10) UNSIGNED DEFAULT NULL,
  `chip_gpu_cores` int(10) UNSIGNED DEFAULT NULL,
  `chip_neural_cores` int(10) UNSIGNED DEFAULT NULL,
  `chip_memory_gb` int(10) UNSIGNED DEFAULT NULL,
  `chip_bandwidth_gbs` double DEFAULT NULL,
  `chip_mac_model` varchar(255) DEFAULT NULL,
  `chip_mac_model_id` varchar(64) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `leaderboard_submissions`
--

INSERT INTO `leaderboard_submissions` (`id`, `machine_id`, `display_name`, `app_version`, `submitted_at`, `model_id`, `model_name`, `backend`, `started_at`, `ended_at`, `prompt`, `status`, `total_tokens`, `prompt_tokens`, `completion_tokens`, `tokens_per_second`, `total_duration`, `prompt_eval_duration`, `eval_duration`, `time_to_first_token`, `load_duration`, `context_length`, `peak_memory_bytes`, `avg_token_latency_ms`, `avg_gpu_power_watts`, `peak_gpu_power_watts`, `avg_system_power_watts`, `peak_system_power_watts`, `avg_gpu_frequency_mhz`, `peak_gpu_frequency_mhz`, `avg_watts_per_token`, `backend_process_name`, `chip_name`, `chip_core_count`, `chip_p_cores`, `chip_e_cores`, `chip_gpu_cores`, `chip_neural_cores`, `chip_memory_gb`, `chip_bandwidth_gbs`, `chip_mac_model`, `chip_mac_model_id`) VALUES
(1, '6c9c1ed0633c777f87abec4ba92cc66678e80ffcb5a19def955122eaa5a3d1b2', 'uncSoft', '2 (1)', '2026-02-23 20:10:49', 'gemma:7b', 'gemma:7b', 'Ollama (Local)', '2026-02-24 01:05:21', '2026-02-24 01:05:46', 'Explain the concept of recursion in programming with a simple example.', 'completed', 427, 34, 393, 17.376164931119, 24.766903125, 0.967565542, 22.617188635, 2.0430880784988, 1.098809625, 425, 9567785144, 57.550098307888, 9.779270409367, 13.544824995131, 9.7792751752489, 13.544828384021, 1054.0777686615, 1058.3888433076, 0.60497213956056, 'Ollama', 'Apple M4', 10, 4, 6, 10, 16, 24, 120, 'MacBook Air (15-inch, M4, 2025)', 'Mac16,13'),
(2, '6c9c1ed0633c777f87abec4ba92cc66678e80ffcb5a19def955122eaa5a3d1b2', 'uncSoft', '2 (1)', '2026-02-23 20:19:26', 'llama3.2:3b', 'llama3.2:3b', 'Ollama (Local)', '2026-02-24 01:18:57', '2026-02-24 01:19:11', 'Explain the concept of recursion in programming with a simple example.', 'completed', 524, 38, 486, 41.453794936519, 13.830664083, 0.416699541, 11.723896467, 1.9332890510559, 1.565748041, 522, 3540122880, 24.123243759259, 9.6083844907717, 11.782944199088, 9.608389596135, 11.782949150052, 1062.6505746702, 1087.2581615871, 0.26392556463694, 'Ollama', 'Apple M4', 10, 4, 6, 10, 16, 24, 120, 'MacBook Air (15-inch, M4, 2025)', 'Mac16,13'),
(3, '6c9c1ed0633c777f87abec4ba92cc66678e80ffcb5a19def955122eaa5a3d1b2', 'cyberpunk69420', '2 (1)', '2026-02-23 20:20:46', 'qwen2.5:7b', 'qwen2.5:7b', 'Ollama (Local)', '2026-02-24 01:19:48', '2026-02-24 01:20:19', 'Explain the concept of recursion in programming with a simple example.', 'completed', 577, 42, 535, 19.80030641969, 31.174378584, 0.430902167, 27.019783869, 3.9560329914093, 3.555630375, 576, 6052222528, 50.504268914019, 10.969070133799, 13.387347364891, 10.969076239983, 13.387352709579, 1055.0230398696, 1071.2073588267, 0.63573690933101, 'Ollama', 'Apple M4', 10, 4, 6, 10, 16, 24, 120, 'MacBook Air (15-inch, M4, 2025)', 'Mac16,13'),
(4, '6c9c1ed0633c777f87abec4ba92cc66678e80ffcb5a19def955122eaa5a3d1b2', 'daddy_dom', '2 (1)', '2026-02-23 21:21:53', 'mlx-community/Llama-3.2-3B-Instruct-4bit', 'mlx-community/Llama-3.2-3B-Instruct-4bit', 'mlx', '2026-02-24 02:21:11', '2026-02-24 02:21:22', 'Explain the concept of recursion in programming with a simple example.', 'completed', 434, 0, 434, 43.923839696878, 9.8807390928268, 0, 9.8807390928268, 0.8320609331131, 0, 0, 2230848128, 22.766679937389, 8.2666822631936, 9.5140505413218, 8.2666874486401, 9.5140557528843, 1058.6326878161, 1069.2670529631, 0.19102412653182, 'mlx-lm', 'Apple M4', 10, 4, 6, 10, 16, 24, 120, 'MacBook Air (15-inch, M4, 2025)', 'Mac16,13');

--
-- Indexes for dumped tables
--

--
-- Indexes for table `leaderboard_submissions`
--
ALTER TABLE `leaderboard_submissions`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_model_tps` (`model_id`,`tokens_per_second` DESC),
  ADD KEY `idx_submitted` (`submitted_at` DESC),
  ADD KEY `idx_machine` (`machine_id`),
  ADD KEY `idx_chip_tps` (`chip_name`,`tokens_per_second` DESC);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `leaderboard_submissions`
--
ALTER TABLE `leaderboard_submissions`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
