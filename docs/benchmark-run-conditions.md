# Recording the conditions a benchmark ran under

A benchmark result is only comparable to another one if you know what was asked
for and what the machine was doing at the time. Anubis recorded what a run
produced; migration v12 adds what it ran under.

| Field | Why it has to be recorded |
|---|---|
| `max_tokens_requested` | Output length drives throughput. Runs of differing length are not comparable, and nothing in an export said how long each was allowed to be. |
| `finish_reason` | Distinguishes a run that stopped on its own from one truncated at the cap. Already parsed by `OpenAICompatibleClient` as a stream terminator, then discarded. |
| `temperature`, `top_p`, `seed` | Sampling settings change output length and content, and were not exported. |
| `thermal_state_at_start`, `thermal_non_nominal_fraction` | See below. |

## Why thermal state belongs on the run

Sustained decode heats a laptop enough to cut throughput several-fold, and the
effect is invisible in the numbers Anubis previously stored.

Measured on an M5 Max MacBook Pro, oMLX 0.5.4rc1, a dense 31B model at a pinned
`max_tokens=512`, identical prompt, ten runs back to back:

| run | tok/s | mean GPU W |
|---|---|---|
| 1 | 48.82 | 48.7 |
| 5 | 36.69 | 21.8 |
| 10 | 5.82 | 2.2 |

An 8.4x spread within about three minutes, on AC power with Low Power Mode off.
The same battery on an M3 Ultra Studio is flat — 1.12x across 30 consecutive
runs with GPU power held at 68–72 W — so this is a property of the machine, not
of the model, the prompt or the backend.

Three things make it hard to notice without recording it:

- **No backend reset recovers it.** Hot-cache clear, SSD-cache clear, model
  unload/reload and a full server restart were each run from a degraded state
  and none recovered anything. Only letting the machine cool does, repeatably.
- **The work per run does not change.** The server's own decode accounting
  shows a constant number of speculation cycles per 512 tokens and constant
  acceptance across the whole collapse. The same computation simply takes
  longer, so nothing in the token counts reveals it.
- **`ProcessInfo.thermalState` lags.** In the run above, GPU power had already
  halved between runs 1 and 2, two runs before the flag left `.nominal`. A
  policy that samples the flag only at run start still lets runs execute hot,
  which is why the fraction across the whole run is recorded rather than a
  single state.

## What this means for a reader of the data

A run with a non-zero `thermal_non_nominal_fraction` competed with thermal
management and should not be compared against a run at zero. The Benchmark tab
marks such runs with a thermometer badge, and both fields are in the CSV export.

For context on how large the contamination is relative to a real signal: a
quantisation comparison across oQ4e / oQ6e / oQ8e of the same model spans about
1.15x end to end. Uncooled, the variance above exceeds that signal several times
over, which means an uninstrumented battery can rank quantisations by nothing
but the order they happened to run in.
