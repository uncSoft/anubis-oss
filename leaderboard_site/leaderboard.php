<?php
// Anubis OSS Leaderboard — Fetch Rankings
require_once __DIR__ . '/config.php';

setCORSHeaders();

// GET only
if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    jsonError(405, 'Method not allowed');
}

// Parse limit
$limit = isset($_GET['limit']) ? min(max(intval($_GET['limit']), 1), 500) : 100;

$db = getDB();

$sql = 'SELECT
    id, display_name, model_id, model_name, backend, app_version,
    started_at, ended_at, status,
    total_tokens, prompt_tokens, completion_tokens,
    tokens_per_second, total_duration, prompt_eval_duration, eval_duration,
    time_to_first_token, load_duration, context_length, peak_memory_bytes, avg_token_latency_ms,
    avg_gpu_power_watts, peak_gpu_power_watts, avg_system_power_watts, peak_system_power_watts,
    avg_gpu_frequency_mhz, peak_gpu_frequency_mhz, avg_watts_per_token,
    backend_process_name,
    chip_name, chip_core_count, chip_p_cores, chip_e_cores,
    chip_gpu_cores, chip_neural_cores, chip_memory_gb, chip_bandwidth_gbs,
    chip_mac_model, chip_mac_model_id,
    submitted_at
FROM leaderboard_submissions
WHERE status = :status
ORDER BY tokens_per_second DESC
LIMIT :limit';

$stmt = $db->prepare($sql);
$stmt->bindValue(':status', 'completed', PDO::PARAM_STR);
$stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
$stmt->execute();

$entries = $stmt->fetchAll();

// Cast numeric fields
$intFields = ['id', 'total_tokens', 'prompt_tokens', 'completion_tokens', 'context_length',
              'chip_core_count', 'chip_p_cores', 'chip_e_cores', 'chip_gpu_cores', 'chip_neural_cores', 'chip_memory_gb'];
$floatFields = ['tokens_per_second', 'total_duration', 'prompt_eval_duration', 'eval_duration',
                'time_to_first_token', 'load_duration', 'avg_token_latency_ms',
                'avg_gpu_power_watts', 'peak_gpu_power_watts', 'avg_system_power_watts', 'peak_system_power_watts',
                'avg_gpu_frequency_mhz', 'peak_gpu_frequency_mhz', 'avg_watts_per_token', 'chip_bandwidth_gbs'];
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
