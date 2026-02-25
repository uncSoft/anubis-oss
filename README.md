# Anubis <img width="70" height="80" alt="anubis_icon (1)" src="https://github.com/user-attachments/assets/4369ce8d-8f3a-4502-9c49-6f3a82372e00" />

[![macOS 15+](https://img.shields.io/badge/macOS-15.0%2B-blue?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift&logoColor=white)](https://swift.org)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/uncSoft/anubis-oss?label=Download&color=brightgreen)](https://github.com/uncSoft/anubis-oss/releases/latest)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Tip%20Jar-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/jtatuncsoft/tip)

**Local LLM Testing & Benchmarking for Apple Silicon** | [Community Leaderboard](https://devpadapp.com/leaderboard.html)

Anubis is a native macOS app for benchmarking, comparing, and managing local large language models using any OpenAI-compatible endpoint - Ollama, MLX, LM Studio Server, OpenWebUI, Docker Models, etc. Built with SwiftUI for Apple Silicon, it provides real-time hardware telemetry correlated with full, history-saved inference performance - something no CLI tool or chat wrapper offers. Export benchmarks directly without having to screenshot, and export the raw data as .MD or .CSV from the history. You can even `OLLAMA PULL` models directly within the app.

<img width="780" height="1100" alt="image" src="https://github.com/user-attachments/assets/c4b81dca-1a81-4b1e-8bbb-109a99a7e7bb" />

<img width="950" height="600" alt="image" src="https://github.com/user-attachments/assets/5da02ee4-ef48-4785-9c46-1803b07d553f" />

---

## Why Anubis?

The local LLM ecosystem on macOS is fragmented:

- **Chat wrappers** (Ollama, LM Studio, Jan) focus on conversation, not systematic testing
- **Performance monitors** (asitop, macmon, mactop) are CLI-only and lack LLM context
- **Evaluation frameworks** (promptfoo) require YAML configs and terminal expertise
- **No tool** correlates hardware metrics (GPU / CPU / ANE / power / memory) with inference speed in real time

Anubis fills that gap with three integrated modules - all in a native macOS app.

---

## Leaderboard Submissions Now Available! Submit directly through the app
### The dataset is robut and open source - [check it out here](https://devpadapp.com/explorer.html), please contribute! 

## Features

### Benchmark

Real-time performance dashboard for single-model testing.

- Select any model from any configured backend
- Stream responses with live metrics overlay
- **8 metric cards**: Tokens/sec, GPU %, CPU %, Time to First Token, Process Memory, Model Memory, Thermal State, GPU Frequency
- **7 live charts**: Tokens/sec, GPU utilization, CPU utilization, process memory, GPU/CPU/ANE/DRAM power, GPU frequency - all updating in real time
- **Power telemetry**: Real-time GPU, CPU, ANE, and DRAM power consumption in watts via IOReport
- **Process monitoring**: Auto-detects backend process by port (Ollama, LM Studio, mlx-lm, vLLM, etc.) with manual process picker
- Detailed session stats: peak tokens/sec, average token latency, model load time, context length, eval duration, power averages
- Configurable parameters: temperature, top-p, max tokens, system prompt
- **Prompt presets** organized by category (Quick, Reasoning, Coding, Creative, Benchmarking)
- **Session history** with full replay, CSV export, and Markdown reports
- Expanded full-screen metrics dashboard
- **Image export**: Copy to clipboard, save as PNG, or share - 2x retina rendering with watermark, respects light/dark mode

### Arena

Side-by-side A/B model comparison with the same prompt.

- Dual model selectors with independent backend selection
- **Sequential** mode (memory-safe, one at a time) or **Parallel** mode (both simultaneously)
- Shared prompt, system prompt, and generation parameters
- Real-time streaming in both panels
- **Voting system**: pick Model A, Model B, or Tie - votes are persisted
- Per-panel stats grid (9 metrics each)
- Model manager: view loaded models and unload to free memory
- Comparison history with voting records

### Leaderboard *(New in 2.1)*

Upload your benchmark results to the [community leaderboard](https://devpadapp.com/leaderboard.html) and see how your Mac stacks up against other Apple Silicon machines.

- **One-click upload** from the benchmark toolbar after a completed run
- **Community rankings** sorted by tokens/sec with full drill-down into performance, power, and hardware details
- **Filter by chip or model** to compare like-for-like (e.g. all M4 Max results, or all Llama 3.2 runs)
- **[Data Explorer](https://devpadapp.com/explorer.html)** — interactive pivot table and charting powered by FINOS Perspective
- **Privacy-first**: no accounts, no response text uploaded — just metrics and a display name
- HMAC-signed submissions with server-side rate limiting

### Auto-Update *(New in 2.3)*

Anubis checks for updates automatically via [Sparkle](https://sparkle-project.org/) and notifies you when a new version is available.

- **Automatic checks** on launch with user-controlled frequency
- **Manual check** via the app menu (**Anubis OSS > Check for Updates...**) or **Settings > About**
- Updates are code-signed, notarized, and verified with EdDSA before installation

### Vault

Unified model management across all backends.

- Aggregated model list with search and backend filter chips
- Running models section with live VRAM usage
- Model inspector: size, parameters, quantization, family, context window, architecture details, file path
- **Automatic metadata enrichment** for OpenAI-compatible models - parses model IDs for family and parameter count, scans `~/.lmstudio/models/` and `~/.cache/huggingface/hub/` for disk size, quantization, and path
- Pull new models, delete existing ones, unload from memory
- Popular model suggestions for quick setup
- Total disk usage display

---
## Screenshots

GPU Core detail
<img width="1282" height="830" alt="Screenshot 2026-02-25 at 4 08 44 PM" src="https://github.com/user-attachments/assets/7cf7d6f2-bcb5-4f96-b04b-19d96df29e87" />

Arena Mode
<img width="1282" height="830" alt="Screenshot 2026-02-25 at 4 21 50 PM" src="https://github.com/user-attachments/assets/c364bd43-4300-4565-8e6b-7fcae9e8dcd8" />

Settings (add connections with quick presets)
<img width="1282" height="830" alt="Screenshot 2026-02-25 at 4 24 00 PM" src="https://github.com/user-attachments/assets/ff9bb9fa-aa6e-472a-a787-5583a3883105" />

Vault - View model details, unload, and Pull models directly for Ollama
<img width="1282" height="830" alt="Screenshot 2026-02-25 at 4 14 57 PM" src="https://github.com/user-attachments/assets/795157b5-efe8-4895-b499-beef25de9683" />

## Supported Backends

| Backend | Type | Default Port | Setup |
|---------|------|--------------|-------|
| **Ollama** | Native support | 11434 | Install from [ollama.com](https://ollama.com) - auto-detected on launch |
| **LM Studio** | OpenAI-compatible | 1234 | Enable local server in LM Studio settings |
| **mlx-lm** | OpenAI-compatible | 8080 | `pip install mlx-lm && mlx_lm.server --model <model>` |
| **vLLM** | OpenAI-compatible | 8000 | Add in Settings |
| **LocalAI** | OpenAI-compatible | 8080 | Add in Settings |
| **Docker ModelRunner** | OpenAI-compatible | user selected | Add in Settings |

Any OpenAI-compatible server can be added through **Settings > Add OpenAI-Compatible Server** with a name, URL, and optional API key.

---

## Hardware Metrics

Anubis captures Apple Silicon telemetry during inference via IOReport and system APIs:

| Metric | Source | Description |
|--------|--------|-------------|
| GPU Utilization | IOReport | GPU active residency percentage |
| CPU Utilization | `host_processor_info` | Usage across all cores |
| GPU Power | IOReport Energy Model | GPU power consumption in watts |
| CPU Power | IOReport Energy Model | CPU (E-cores + P-cores) power in watts |
| ANE Power | IOReport Energy Model | Neural Engine power consumption |
| DRAM Power | IOReport Energy Model | Memory subsystem power |
| GPU Frequency | IOReport GPU Stats | Weighted average from P-state residency |
| Process Memory | `proc_pid_rusage` | Backend process `phys_footprint` (includes Metal/GPU allocations) |
| Thermal State | `ProcessInfo.thermalState` | System thermal pressure level |

### Process Monitoring

Anubis automatically detects which process is serving your model:

- **Port-based detection**: Uses `lsof` to find the PID listening on the inference port (called once per benchmark start)
- **Backend identification**: Matches process path and command-line args to identify Ollama, LM Studio, mlx-lm, vLLM, LocalAI, llama.cpp
- **Memory accounting**: Uses `phys_footprint` (same as Activity Monitor) which includes Metal/GPU buffer allocations - critical for MLX and other GPU-accelerated backends
- **LM Studio support**: Walks Electron app bundle descendants to find the model-serving process
- **Manual override**: Process picker lets you select any process by name, sorted by memory usage

Metrics degrade gracefully - if IOReport access is unavailable (e.g., in a VM), Anubis still shows inference-derived metrics.

---

## Requirements

- **macOS 15.0** (Sequoia) or later
- **Apple Silicon** (M1 / M2 / M3 / M4 / M5 +) - Intel is not supported
- **8 GB** unified memory minimum (16 GB+ recommended for larger models)
- At least one inference backend installed (Ollama recommended)

---

## Getting Started

### 1. Install Ollama (or another backend)

```bash
# macOS - install Ollama
brew install ollama

# Start the server
ollama serve

# Pull a model
ollama pull llama3.2:3b
```

### 2. Build & Run Anubis

```bash
git clone https://github.com/uncSoft/anubis-oss.git
cd anubis-oss/anubis
open anubis.xcodeproj
```

In Xcode:
1. Set your development team in **Signing & Capabilities**
2. Build and run (`Cmd+R`)

Anubis will auto-detect Ollama on launch. Other backends can be added in Settings.

### 3. Run Your First Benchmark

1. Select a model from the dropdown
2. Type a prompt or pick one from **Presets**
3. Click **Run**
4. Watch the metrics light up in real time

### 4. Submit to the Leaderboard

After a benchmark completes, click the **Upload** button in the benchmark toolbar to submit your results to the [community leaderboard](https://devpadapp.com/leaderboard.html). Enter a display name and your run will appear in the rankings — no account required. Only performance metrics and hardware info are submitted; response text is never uploaded.

---

## Building from Source

```bash
# Clone
git clone https://github.com/uncSoft/anubis-oss.git
cd anubis-oss/anubis

# Build via command line
xcodebuild -scheme anubis-oss -configuration Debug build

# Run tests
xcodebuild -scheme anubis-oss -configuration Debug test

# Or just open in Xcode
open anubis.xcodeproj
```

### Dependencies

Resolved automatically by Swift Package Manager on first build:

| Package | Purpose | License |
|---------|---------|---------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite database | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Auto-update framework | MIT |
| Swift Charts | Data visualization | Apple |

---

## Architecture

Anubis follows MVVM with a layered service architecture:

```
┌─────────────────────────────────────────────────────────────┐
│                    PRESENTATION LAYER                       │
│   BenchmarkView    ArenaView    VaultView    SettingsView   │
├─────────────────────────────────────────────────────────────┤
│                      SERVICE LAYER                          │
│   MetricsService   InferenceService   ModelService   Export │
├─────────────────────────────────────────────────────────────┤
│                    INTEGRATION LAYER                        │
│  OllamaClient  OpenAICompatibleClient  IOReportBridge  ProcessMonitor │
├─────────────────────────────────────────────────────────────┤
│                    PERSISTENCE LAYER                        │
│   SQLite (GRDB)              File System                    │
└─────────────────────────────────────────────────────────────┘
```

**Views** display data and delegate to **ViewModels**. ViewModels coordinate **Services**. Services are stateless and use async/await. **Integrations** are thin adapters wrapping external systems (Ollama API, IOReport, etc.).

### Project Structure

```
anubis/
├── App/                    # Entry point, app state, navigation
├── Features/
│   ├── Benchmark/          # Performance dashboard
│   ├── Arena/              # A/B model comparison
│   ├── Vault/              # Model management
│   └── Settings/           # Backend config, about, help, contact
├── Services/               # MetricsService, InferenceService, ExportService
├── Integrations/           # OllamaClient, OpenAICompatibleClient, IOReportBridge, ProcessMonitor
├── Models/                 # Data models (BenchmarkSession, ModelInfo, etc.)
├── Database/               # GRDB setup & migrations
├── DesignSystem/           # Theme, colors, reusable components
├── Demo/                   # Demo mode for App Store review
└── Utilities/              # Formatters, constants, logger
```

### Backend Abstraction

All inference backends implement a shared protocol, making it straightforward to add new ones:

```swift
protocol InferenceBackend {
    var id: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get async }

    func listModels() async throws -> [ModelInfo]
    func generate(prompt: String, parameters: GenerationParameters)
        -> AsyncThrowingStream<InferenceChunk, Error>
}
```

---

## Data Storage

All data is stored locally - nothing leaves your machine.

| Data | Location |
|------|----------|
| Database | `~/Library/Application Support/Anubis/anubis.db` |
| Exports | Generated on demand (CSV, Markdown) |
| Preferences | UserDefaults |

---

## Troubleshooting

### Ollama shows "Disconnected"
```bash
# Make sure Ollama is running
ollama serve

# Verify it's accessible
curl http://localhost:11434/api/tags
```

### No GPU metrics
- GPU metrics require IOReport access via IOKit
- Some configurations or VMs may not expose these APIs
- Anubis will still show inference-derived metrics (tokens/sec, TTFT, etc.)

### High memory usage
- Use **Sequential** mode in Arena to run one model at a time
- Unload unused models via Arena > Models > Unload All
- Choose smaller quantized models (Q4_K_M over Q8_0)

### Model not appearing
- Click **Refresh Models** in Settings
- Ensure the model is pulled: `ollama pull <model-name>`
- For OpenAI-compatible backends, verify the server is running and the URL is correct

---

## Contributing

Contributions are welcome. A few guidelines:

1. **Follow the existing patterns** - MVVM, async/await, guard-let over force-unwrap
2. **Keep files under 300 lines** - split if larger
3. **One feature per PR** - small, focused changes are easier to review
4. **Test services and integrations** - views are harder to unit test, but services should have coverage
5. **Handle errors gracefully** - always provide `errorDescription` and `recoverySuggestion`

### Adding a New Backend

1. Create a new file in `Integrations/` implementing `InferenceBackend`
2. Register it in `InferenceService`
3. Add configuration UI in `Settings/`
4. That's it - the rest of the app works through the protocol

---

## Support the Project

If Anubis is useful to you, consider [buying me a coffee on Ko-fi](https://ko-fi.com/jtatuncsoft/tip) or [sponsoring on GitHub](https://github.com/sponsors/uncSoft). It helps fund continued development and new features.

A sandboxed, less feature rich version is also available on the [Mac App Store](https://apps.apple.com/us/app-bundle/the-architects-toolkit/id1874965091?mt=12) if you prefer a managed install.

---

## License

GPL-3.0 License — see [LICENSE](LICENSE) for details.

**Other projects:** [DevPad](https://www.devpadapp.com) · [Nabu](https://www.devpadapp.com/nabu.html)
