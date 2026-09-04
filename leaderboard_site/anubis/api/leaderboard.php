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

// ── Output ───────────────────────────────────────────────────────────
// Default stays JSON so nothing that already reads this endpoint changes.
//
// ?format=csv emits the SAME 44-column projection the data explorer builds
// in the browser: human column names, seconds converted to ms, bytes to GB,
// and the three derived columns. That projection used to exist only inside
// explorer.html, so anything else wanting an analyst-ready table had to
// re-derive it and drift. This is now the one definition.
//
// It is also a lot smaller than the JSON: ~0.85 MB against ~3.0 MB for the
// same rows, because the nesting and the repeated key names are gone.
$format = isset($_GET['format']) ? strtolower($_GET['format']) : 'json';

if ($format !== 'csv') {
    header('Content-Type: application/json');
    echo json_encode([
        'count'   => count($entries),
        'entries' => $entries,
    ]);
    exit;
}

/** Derived: prompt tokens over prompt eval seconds. Null when undefined. */
function prefill_tps(array $e) {
    if ($e['prompt_tokens'] === null) return null;
    if (empty($e['prompt_eval_duration']) || $e['prompt_eval_duration'] <= 0) return null;
    return $e['prompt_tokens'] / $e['prompt_eval_duration'];
}

/** Derived: reasoning tokens over reasoning seconds. */
function reasoning_tps(array $e) {
    if ($e['reasoning_tokens'] === null) return null;
    if (empty($e['reasoning_duration']) || $e['reasoning_duration'] <= 0) return null;
    return $e['reasoning_tokens'] / $e['reasoning_duration'];
}

/**
 * Derived: half-width of a 95% bootstrap CI, the "+/- value" people scan.
 *
 * Rounded to 3dp to match explorer.html's ciHalfWidth() exactly. Without the
 * round the CSV and the explorer disagree in the far decimals for every
 * grouped row, which is the sort of drift this endpoint exists to end.
 */
function ci_half($low, $high) {
    if ($low === null || $high === null) return null;
    return round(($high - $low) / 2, 3);
}

/** Seconds to milliseconds, preserving null. */
function to_ms($v) { return $v === null ? null : $v * 1000; }

/** Bytes to GB, preserving null. */
function to_gb($v) { return $v === null ? null : round($v / 1073741824, 2); }

$columns = [
    // Run ID first. Without it the CSV has no key: 236 of 632 (model, name)
    // pairs in the current data have more than one row, so rows could not be
    // told apart, deduplicated, joined back to the JSON, or cited.
    'Run ID',
    'Name', 'Model', 'Quantization', 'Format', 'Chip', 'Mac',
    'Memory (GB)', 'GPU Cores', 'CPU Cores', 'Bandwidth (GB/s)',
    'Output tok/s', 'Prefill tok/s', 'Reasoning tok/s',
    'Reasoning Tokens', 'Reasoning Duration (s)',
    'TTFT (ms)', 'Avg Latency (ms)', 'Eval Duration (s)', 'Total Duration (s)',
    'Load Time (s)', 'Prompt Tokens', 'Prompt Eval (s)', 'Completion Tokens',
    'Total Tokens', 'Context Length',
    'Avg GPU Power (W)', 'Peak GPU Power (W)', 'Avg System Power (W)',
    'Peak System Power (W)', 'Watts/Token',
    'Avg GPU Freq (MHz)', 'Peak GPU Freq (MHz)', 'Peak Memory (GB)',
    'Backend', 'App Version', 'Methodology',
    'Group Reps', 'Group Rep #', 'Group Mean tok/s', 'Group ±CI tok/s',
    'Group Mean TTFT (ms)', 'Group Mean J/Tok', 'Seed Strategy', 'Submitted',
];

$stamp = gmdate('Y-m-d');
header('Content-Type: text/csv; charset=utf-8');
header('Content-Disposition: attachment; filename="anubis-leaderboard-' . count($entries) . '-runs-' . $stamp . '.csv"');

$out = fopen('php://output', 'w');

// Excel needs a BOM to read UTF-8 model names; pandas and friends would
// rather not have one, so it is opt-in with &bom=1 instead of default.
if (isset($_GET['bom']) && $_GET['bom'] === '1') {
    fwrite($out, "\xEF\xBB\xBF");
}

fputcsv($out, $columns);

foreach ($entries as $e) {
    fputcsv($out, [
        $e['id'],
        $e['display_name'] !== null && $e['display_name'] !== '' ? $e['display_name'] : 'Anonymous',
        $e['model_name'],
        $e['model_quantization'],
        $e['model_format'],
        $e['chip_name'],
        $e['chip_mac_model'],
        $e['chip_memory_gb'],
        $e['chip_gpu_cores'],
        $e['chip_core_count'],
        $e['chip_bandwidth_gbs'],
        $e['tokens_per_second'],
        prefill_tps($e),
        reasoning_tps($e),
        $e['reasoning_tokens'],
        $e['reasoning_duration'],
        to_ms($e['time_to_first_token']),
        $e['avg_token_latency_ms'],
        $e['eval_duration'],
        $e['total_duration'],
        $e['load_duration'],
        $e['prompt_tokens'],
        $e['prompt_eval_duration'],
        $e['completion_tokens'],
        $e['total_tokens'],
        $e['context_length'],
        $e['avg_gpu_power_watts'],
        $e['peak_gpu_power_watts'],
        $e['avg_system_power_watts'],
        $e['peak_system_power_watts'],
        $e['avg_watts_per_token'],
        $e['avg_gpu_frequency_mhz'],
        $e['peak_gpu_frequency_mhz'],
        to_gb($e['peak_memory_bytes']),
        $e['backend'],
        $e['app_version'],
        $e['methodology_version'],
        $e['group_sample_count'],
        $e['group_repetition_index'],
        $e['group_mean_tokens_per_second'],
        ci_half($e['group_ci_low_tokens_per_second'], $e['group_ci_high_tokens_per_second']),
        to_ms($e['group_mean_time_to_first_token']),
        $e['group_mean_watts_per_token'],
        $e['group_seed_strategy'],
        $e['submitted_at'],
    ]);
}

fclose($out);
