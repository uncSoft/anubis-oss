<?php
// Anubis OSS Leaderboard — Fetch Rankings
require_once __DIR__ . '/config.php';

setCORSHeaders();

// GET only
if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    jsonError(405, 'Method not allowed');
}

// Parse limit (analysis.html / explorer.html request the full dataset with limit=10000)
$limit = isset($_GET['limit']) ? min(max(intval($_GET['limit']), 1), 10000) : 100;

// Plausibility filter, on by default. Historical submissions from clients with
// the "answer-only tok/s" bug carry impossible speeds (5k-29k tok/s from a
// near-zero denominator) and would otherwise top the ranking, since we ORDER BY
// tokens_per_second. 2000 tok/s matches the analysis digest's is_valid() cap.
// Pass raw=1 to bypass (for audits / data archaeology).
$raw = isset($_GET['raw']) && $_GET['raw'] === '1';

$db = getDB();

$sql = 'SELECT
    id, display_name, model_id, model_name, model_quantization, model_format, backend, app_version,
    started_at, ended_at, status,
    total_tokens, prompt_tokens, completion_tokens,
    tokens_per_second, total_duration, prompt_eval_duration, eval_duration,
    time_to_first_token, load_duration, context_length, peak_memory_bytes, avg_token_latency_ms,
    avg_gpu_power_watts, peak_gpu_power_watts, avg_system_power_watts, peak_system_power_watts,
    avg_gpu_frequency_mhz, peak_gpu_frequency_mhz, avg_watts_per_token,
    reasoning_tokens, reasoning_duration,
    backend_process_name,
    chip_name, chip_core_count, chip_p_cores, chip_e_cores,
    chip_gpu_cores, chip_neural_cores, chip_memory_gb, chip_bandwidth_gbs,
    chip_mac_model, chip_mac_model_id,
    methodology_version,
    run_group_id, group_sample_count, group_repetition_index, group_seed_strategy,
    group_mean_tokens_per_second, group_stdev_tokens_per_second,
    group_ci_low_tokens_per_second, group_ci_high_tokens_per_second,
    group_mean_time_to_first_token,
    group_ci_low_time_to_first_token, group_ci_high_time_to_first_token,
    group_mean_watts_per_token,
    group_ci_low_watts_per_token, group_ci_high_watts_per_token,
    submitted_at
FROM leaderboard_submissions
WHERE status = :status'
. ($raw ? '' : '
  AND tokens_per_second > 0 AND tokens_per_second < 2000
  AND completion_tokens >= 1') . '
ORDER BY tokens_per_second DESC
LIMIT :limit';

$stmt = $db->prepare($sql);
$stmt->bindValue(':status', 'completed', PDO::PARAM_STR);
$stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
$stmt->execute();

$entries = $stmt->fetchAll();

// Cast numeric fields
$intFields = ['id', 'total_tokens', 'prompt_tokens', 'completion_tokens', 'context_length',
              'reasoning_tokens',
              'chip_core_count', 'chip_p_cores', 'chip_e_cores', 'chip_gpu_cores', 'chip_neural_cores', 'chip_memory_gb',
              'methodology_version',
              'run_group_id', 'group_sample_count', 'group_repetition_index'];
$floatFields = ['tokens_per_second', 'total_duration', 'prompt_eval_duration', 'eval_duration',
                'time_to_first_token', 'load_duration', 'avg_token_latency_ms',
                'avg_gpu_power_watts', 'peak_gpu_power_watts', 'avg_system_power_watts', 'peak_system_power_watts',
                'avg_gpu_frequency_mhz', 'peak_gpu_frequency_mhz', 'avg_watts_per_token',
                'reasoning_duration',
                'chip_bandwidth_gbs',
                'group_mean_tokens_per_second', 'group_stdev_tokens_per_second',
                'group_ci_low_tokens_per_second', 'group_ci_high_tokens_per_second',
                'group_mean_time_to_first_token',
                'group_ci_low_time_to_first_token', 'group_ci_high_time_to_first_token',
                'group_mean_watts_per_token',
                'group_ci_low_watts_per_token', 'group_ci_high_watts_per_token'];
$bigintFields = ['peak_memory_bytes'];

foreach ($entries as &$entry) {
    foreach ($intFields as $f) {
        if (isset($entry[$f]) && $entry[$f] !== null) $entry[$f] = (int)$entry[$f];
    }
    foreach ($floatFields as $f) {
        if (isset($entry[$f]) && $entry[$f] !== null) $entry[$f] = (float)$entry[$f];
    }
    foreach ($bigintFields as $f) {
        if (isset($entry[$f]) && $entry[$f] !== null) $entry[$f] = (int)$entry[$f];
    }
}
unset($entry);

header('Content-Type: application/json');
echo json_encode([
    'count'   => count($entries),
    'entries' => $entries,
]);
