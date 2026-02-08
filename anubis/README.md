# Anubis

**Local LLM Testing & Benchmarking for Apple Silicon**

Anubis is a native macOS application for benchmarking, comparing, and managing local large language models. Built for Apple Silicon, it provides real-time performance metrics and hardware telemetry during inference.

---

## Features

### Benchmark
Real-time performance dashboard for single-model testing.

### Arena
Side-by-side A/B comparison of two models with the same prompt.

### Vault
Unified view of all available models across backends.

---

## Supported Backends

| Backend | Description | Default Port | Setup |
|---------|-------------|--------------|-------|
| **Ollama** | Local model server | 11434 | Install from [ollama.ai](https://ollama.ai) |
| **mlx-lm** | MLX-based inference server | 8080 | `pip install mlx-lm && mlx_lm.server --model <model>` |
| **LM Studio** | Desktop app with OpenAI API | 1234 | Enable server in LM Studio settings |
| **vLLM** | High-throughput inference | 8000 | Configure in Settings |
| **LocalAI** | OpenAI-compatible server | 8080 | Configure in Settings |

### Adding Backends

1. **Ollama**: Install and run Ollama. Anubis auto-detects it on startup.
2. **mlx-lm**: Start the server with `mlx_lm.server --model <model-path>`, then add as OpenAI-compatible with URL `http://localhost:8080`.
3. **Other OpenAI-Compatible**: Go to **Settings** → **Add OpenAI-Compatible Server** → Enter name, URL, and optional API key.

The current backend is shown in the sidebar. Click to switch between configured backends.

---

## Benchmark

The Benchmark module runs inference on a single model while capturing performance metrics.

### Running a Benchmark

1. Select a model from the dropdown
2. Enter a prompt (or choose from **Presets**)
3. Optionally configure:
   - **System Prompt**: Instructions for the model
   - **Parameters**: Temperature, Top-P, Max Tokens
4. Click **Run**

### Metrics Cards

| Metric | Description | Source |
|--------|-------------|--------|
| **Avg Tokens/sec** | Average generation speed | `completion_tokens ÷ generation_time` |
| **GPU** | GPU utilization percentage | IOReport |
| **CPU** | CPU utilization across all cores | `host_processor_info` |
| **Time to First Token** | Latency before first token appears | Includes model load time if not cached |
| **Process Mem** | Memory used by backend process tree | `phys_footprint` via `proc_pid_rusage` |
| **Model Memory** | VRAM used by loaded model | Ollama `/api/ps` endpoint |
| **Thermal** | System thermal state | `ProcessInfo.thermalState` |
| **GPU Freq** | Current GPU frequency | IOReport GPU Stats P-state residency |

Click the **(?)** on any card to see a detailed explanation of the metric.

### Charts

- **Tokens per Second**: Real-time generation speed over time
- **GPU Utilization**: GPU usage percentage (when available)
- **CPU Utilization**: CPU usage across cores
- **Process Memory**: Memory consumption of the backend process (uses `phys_footprint` — includes Metal/GPU allocations)
- **Power**: GPU, CPU, ANE, and DRAM power consumption in watts
- **GPU Frequency**: Real-time GPU clock speed

### Process Monitoring

Anubis automatically detects the backend process serving your model via port-based detection (`lsof`). Supports Ollama, LM Studio, mlx-lm, vLLM, LocalAI, and llama.cpp. Use the **Process** picker in session details to manually select a different process if needed.

### Session Details

Additional metrics shown after a run completes:
- Time to First Token
- Average Token Latency
- Peak Tokens/sec
- Model Load Time
- Context Length
- Peak Memory
- Prompt/Completion Tokens
- Eval Duration

### Viewing History

Click the **History** button in the toolbar to view past benchmark sessions:
- See all previous runs with model name, backend, and tokens/sec
- Click a session to view full details and charts
- Export sessions as CSV or individual reports as Markdown
- Delete individual sessions or clear all history

### Expanded View

Click the **Expand** button to open a full-screen metrics dashboard with larger charts and more detailed statistics.

---

## Arena

The Arena module compares two models side-by-side with the same prompt.

### Running a Comparison

1. Select **Model A** (left panel) - choose backend and model
2. Select **Model B** (right panel) - choose backend and model
3. Enter a shared prompt
4. Choose execution mode:
   - **Sequential**: Runs one model at a time (memory-safe)
   - **Parallel**: Runs both simultaneously (faster, uses more memory)
5. Click **Compare**

### Voting

After both models complete, vote for a winner:
- **Model A** / **Model B** / **Tie**

Votes are saved with the comparison for later review.

### Session Details

Each panel shows a detailed stats grid after completion:
- **Avg Tokens/sec**: Generation speed
- **Time to First Token**: Latency before first token
- **Avg Token Latency**: Average time per token
- **Completion Tokens**: Tokens generated
- **Prompt Tokens**: Tokens in the prompt
- **Total Duration**: Wall-clock time
- **Model Load Time**: Time to load model (Ollama only)
- **Eval Duration**: Backend evaluation time (Ollama only)
- **Context Length**: Context window used (Ollama only)

### Model Management

Click **Models** in the toolbar to see currently loaded models and unload them to free memory.

### Viewing History

Click **History** to see past comparisons with:
- Models compared
- Winner (if voted)
- Execution mode
- Prompt used

---

## Vault

The Vault provides a unified view of all models across all configured backends.

### Model List

- Filter by backend using chips at the top
- Search by model name
- See model size, parameter count, and quantization
- Green dot indicates model is currently loaded

### Model Details

Click a model to see:
- Full name and family
- Size on disk
- Parameter count
- Quantization type
- Format and backend

### Running Models

The **Running** section at the top shows models currently loaded in memory with their VRAM usage.

---

## Settings

### Backend Configuration

- **Ollama**: Edit the base URL (default: `http://localhost:11434`)
- **MLX**: Shows availability status
- **OpenAI-Compatible**: Add, edit, or remove servers

### Actions

- **Check All Backends**: Test connectivity to all configured backends
- **Refresh Models**: Reload model lists from all backends

---

## Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon Mac (M1/M2/M3/M4)
- [Ollama](https://ollama.ai) installed (for local models)

---

## Troubleshooting

### "Disconnected" status for Ollama
- Ensure Ollama is running: `ollama serve`
- Check it's accessible: `curl http://localhost:11434/api/tags`

### No GPU metrics showing
- GPU metrics require IOReport access
- Some metrics may not be available on all hardware configurations

### High memory usage
- Use **Sequential** mode in Arena to run one model at a time
- Unload unused models via Arena → Models → Unload All
- Choose smaller quantized models (Q4_K_M vs Q8)

### Model not appearing
- Click **Refresh Models** in Settings
- Ensure the model is downloaded: `ollama pull <model>`

---

## Data Storage

- **Database**: `~/Library/Application Support/Anubis/anubis.db`
- **Benchmark sessions and Arena comparisons are persisted locally**

---

## License

MIT License - See LICENSE file for details.
