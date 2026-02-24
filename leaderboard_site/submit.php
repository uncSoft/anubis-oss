<?php
// Anubis OSS Leaderboard — Submit Benchmark
require_once __DIR__ . '/config.php';

setCORSHeaders();

// POST only
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    jsonError(405, 'Method not allowed');
}

// Read and validate body
$body = file_get_contents('php://input');
if (empty($body)) {
    jsonError(400, 'Empty request body');
}

// Validate HMAC signature
if (!validateHMAC($body)) {
    // Temporary debug — remove after testing
    $sig = $_SERVER['HTTP_X_ANUBIS_SIGNATURE'] ?? '(missing)';
    $ts  = $_SERVER['HTTP_X_ANUBIS_TIMESTAMP'] ?? '(missing)';
    $expected = hash_hmac('sha256', $ts . $body, HMAC_SECRET);
    $timeDiff = abs(time() - intval($ts));
    error_log("HMAC DEBUG: ts=$ts, timeDiff={$timeDiff}s, sig=$sig, expected=$expected, secretLen=" . strlen(HMAC_SECRET));
    jsonError(403, 'Invalid or expired signature');
}

// Parse JSON
$data = json_decode($body, true);
if ($data === null) {
    jsonError(400, 'Invalid JSON');
}

// Required fields
$required = ['machine_id', 'display_name', 'app_version', 'model_id', 'model_name', 'backend', 'started_at', 'prompt', 'status'];
foreach ($required as $field) {
    if (empty($data[$field])) {
        jsonError(400, "Missing required field: {$field}");
    }
}

// Only accept completed benchmarks
if ($data['status'] !== 'completed') {
    jsonError(400, 'Only completed benchmarks can be submitted');
}

// Sanitize display name
$data['display_name'] = mb_substr(trim($data['display_name']), 0, 64);
if (empty($data['display_name'])) {
    jsonError(400, 'Display name cannot be empty');
}

// Validate machine_id format (should be 64-char hex)
if (!preg_match('/^[a-f0-9]{64}$/', $data['machine_id'])) {
    jsonError(400, 'Invalid machine ID format');
}

$db = getDB();

// Rate limiting: max submissions per machine per hour
$stmt = $db->prepare(
    'SELECT COUNT(*) FROM leaderboard_submissions WHERE machine_id = ? AND submitted_at > DATE_SUB(NOW(), INTERVAL 1 HOUR)'
);
$stmt->execute([$data['machine_id']]);
$count = (int)$stmt->fetchColumn();

if ($count >= RATE_LIMIT_PER_HOUR) {
    jsonError(429, 'Rate limit exceeded. Maximum ' . RATE_LIMIT_PER_HOUR . ' submissions per hour.');
}

// Insert
$sql = 'INSERT INTO leaderboard_submissions (
    machine_id, display_name, app_version,
    model_id, model_name, backend, started_at, ended_at, prompt, status,
    total_tokens, prompt_tokens, completion_tokens,
    tokens_per_second, total_duration, prompt_eval_duration, eval_duration,
    time_to_first_token, load_duration, context_length, peak_memory_bytes, avg_token_latency_ms,
    avg_gpu_power_watts, peak_gpu_power_watts, avg_system_power_watts, peak_system_power_watts,
    avg_gpu_frequency_mhz, peak_gpu_frequency_mhz, avg_watts_per_token,
    backend_process_name,
    chip_name, chip_core_count, chip_p_cores, chip_e_cores,
    chip_gpu_cores, chip_neural_cores, chip_memory_gb, chip_bandwidth_gbs,
    chip_mac_model, chip_mac_model_id
) VALUES (
    :machine_id, :display_name, :app_version,
    :model_id, :model_name, :backend, :started_at, :ended_at, :prompt, :status,
    :total_tokens, :prompt_tokens, :completion_tokens,
    :tokens_per_second, :total_duration, :prompt_eval_duration, :eval_duration,
    :time_to_first_token, :load_duration, :context_length, :peak_memory_bytes, :avg_token_latency_ms,
    :avg_gpu_power_watts, :peak_gpu_power_watts, :avg_system_power_watts, :peak_system_power_watts,
    :avg_gpu_frequency_mhz, :peak_gpu_frequency_mhz, :avg_watts_per_token,
    :backend_process_name,
    :chip_name, :chip_core_count, :chip_p_cores, :chip_e_cores,
    :chip_gpu_cores, :chip_neural_cores, :chip_memory_gb, :chip_bandwidth_gbs,
    :chip_mac_model, :chip_mac_model_id
)';

$stmt = $db->prepare($sql);

// Helper: get value or null
$v = fn(string $key) => $data[$key] ?? null;

$stmt->execute([
    ':machine_id'             => $data['machine_id'],
    ':display_name'           => $data['display_name'],
    ':app_version'            => $data['app_version'],
    ':model_id'               => $data['model_id'],
    ':model_name'             => $data['model_name'],
    ':backend'                => $data['backend'],
    ':started_at'             => $data['started_at'],
    ':ended_at'               => $v('ended_at'),
    ':prompt'                 => $data['prompt'],
    ':status'                 => $data['status'],
    ':total_tokens'           => $v('total_tokens'),
    ':prompt_tokens'          => $v('prompt_tokens'),
    ':completion_tokens'      => $v('completion_tokens'),
    ':tokens_per_second'      => $v('tokens_per_second'),
    ':total_duration'         => $v('total_duration'),
    ':prompt_eval_duration'   => $v('prompt_eval_duration'),
    ':eval_duration'          => $v('eval_duration'),
    ':time_to_first_token'    => $v('time_to_first_token'),
    ':load_duration'          => $v('load_duration'),
    ':context_length'         => $v('context_length'),
    ':peak_memory_bytes'      => $v('peak_memory_bytes'),
    ':avg_token_latency_ms'   => $v('avg_token_latency_ms'),
    ':avg_gpu_power_watts'    => $v('avg_gpu_power_watts'),
    ':peak_gpu_power_watts'   => $v('peak_gpu_power_watts'),
    ':avg_system_power_watts' => $v('avg_system_power_watts'),
    ':peak_system_power_watts'=> $v('peak_system_power_watts'),
    ':avg_gpu_frequency_mhz'  => $v('avg_gpu_frequency_mhz'),
    ':peak_gpu_frequency_mhz' => $v('peak_gpu_frequency_mhz'),
    ':avg_watts_per_token'    => $v('avg_watts_per_token'),
    ':backend_process_name'   => $v('backend_process_name'),
    ':chip_name'              => $v('chip_name'),
    ':chip_core_count'        => $v('chip_core_count'),
    ':chip_p_cores'           => $v('chip_p_cores'),
    ':chip_e_cores'           => $v('chip_e_cores'),
    ':chip_gpu_cores'         => $v('chip_gpu_cores'),
    ':chip_neural_cores'      => $v('chip_neural_cores'),
    ':chip_memory_gb'         => $v('chip_memory_gb'),
    ':chip_bandwidth_gbs'     => $v('chip_bandwidth_gbs'),
    ':chip_mac_model'         => $v('chip_mac_model'),
    ':chip_mac_model_id'      => $v('chip_mac_model_id'),
]);

$insertId = (int)$db->lastInsertId();

jsonSuccess([
    'id'      => $insertId,
    'message' => 'Benchmark submitted successfully',
]);
