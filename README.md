![anubis_splash](https://github.com/user-attachments/assets/bc7c9c25-6750-40f4-add7-3f60fb24c1a3)

#Anubis
<img width="183" height="200" alt="anubis_icon (1)" src="https://github.com/user-attachments/assets/4369ce8d-8f3a-4502-9c49-6f3a82372e00" />

**Local LLM Testing & Benchmarking for Apple Silicon**

Anubis is a native macOS app for benchmarking, comparing, and managing local large language models. Built with SwiftUI for Apple Silicon, it provides real-time hardware telemetry correlated with inference performance — something no CLI tool or chat wrapper offers.

Named after the Egyptian deity who weighs the heart against the feather of truth, Anubis evaluates local LLMs with precision and transparency.

<img width="806" height="901" alt="anubis6" src="https://github.com/user-attachments/assets/5848a476-d577-405b-8830-52f751fd4b74" />

---

## Why Anubis?

The local LLM ecosystem on macOS is fragmented:

- **Chat wrappers** (Ollama, LM Studio, Jan) focus on conversation, not systematic testing
- **Performance monitors** (asitop, macmon, mactop) are CLI-only and lack LLM context
- **Evaluation frameworks** (promptfoo) require YAML configs and terminal expertise
- **No tool** correlates hardware metrics (GPU / CPU / ANE / memory) with inference speed in real time

Anubis fills that gap with three integrated modules — all in a native, sandboxed macOS app.

<img width="908" height="829" alt="anubis5" src="https://github.com/user-attachments/assets/6c71d7c7-8c62-4b4a-b0f4-60db98c0e802" />
<img width="889" height="988" alt="anubis2" src="https://github.com/user-attachments/assets/2bf8d79e-cb9f-4fbf-a449-f34a16308cf5" />
<img width="911" height="593" alt="anubis1" src="https://github.com/user-attachments/assets/d6a36d43-892e-4e7f-8028-4915d268c206" />
---

## Features

### Benchmark

Real-time performance dashboard for single-model testing.

- Select any model from any configured backend
- Stream responses with live metrics overlay
- **6 metric cards**: Tokens/sec, GPU %, CPU %, Time to First Token, Model Memory, Thermal State
- **4 live charts**: Tokens/sec, GPU utilization, CPU utilization, Ollama memory — all updating in real time
- Detailed session stats: peak tokens/sec, average token latency, model load time, context length, eval duration
- Configurable parameters: temperature, top-p, max tokens, system prompt
- **Prompt presets** organized by category (Quick, Reasoning, Coding, Creative, Benchmarking)
- **Session history** with full replay, CSV export, and Markdown reports
- Expanded full-screen metrics dashboard

### Arena

Side-by-side A/B model comparison with the same prompt.

- Dual model selectors with independent backend selection
- **Sequential** mode (memory-safe, one at a time) or **Parallel** mode (both simultaneously)
- Shared prompt, system prompt, and generation parameters
- Real-time streaming in both panels
- **Voting system**: pick Model A, Model B, or Tie — votes are persisted
- Per-panel stats grid (9 metrics each)
- Model manager: view loaded models and unload to free memory
- Comparison history with voting records

### Vault

Unified model management across all backends.

- Aggregated model list with search and backend filter chips
- Running models section with live VRAM usage
- Model inspector: size, parameters, quantization, family, context window, architecture details
- Pull new models, delete existing ones, unload from memory
- Popular model suggestions for quick setup
- Total disk usage display

---

## Supported Backends

| Backend | Type | Default Port | Setup |
|---------|------|--------------|-------|
| **Ollama** | Native support | 11434 | Install from [ollama.ai](https://ollama.ai) — auto-detected on launch |
| **LM Studio** | OpenAI-compatible | 1234 | Enable local server in LM Studio settings |
| **mlx-lm** | OpenAI-compatible | 8080 | `pip install mlx-lm && mlx_lm.server --model <model>` |
| **vLLM** | OpenAI-compatible | 8000 | Add in Settings |
| **LocalAI** | OpenAI-compatible | 8080 | Add in Settings |

Any OpenAI-compatible server can be added through **Settings > Add OpenAI-Compatible Server** with a name, URL, and optional API key.

---

## Hardware Metrics

Anubis captures Apple Silicon telemetry during inference via IOReport and system APIs:

| Metric | Source | Description |
|--------|--------|-------------|
| GPU Utilization | IOReport | GPU active residency percentage |
| CPU Utilization | `host_processor_info` | Usage across all cores |
| Model Memory | Ollama `/api/ps` | VRAM consumed by loaded model |
| Thermal State | `ProcessInfo.thermalState` | System thermal pressure level |
| ANE Power | IOReport | Neural Engine power consumption (watts) |

Metrics degrade gracefully — if IOReport access is unavailable (e.g., in a VM), Anubis still shows inference-derived metrics.

---

## Requirements

- **macOS 15.0** (Sequoia) or later
- **Apple Silicon** (M1 / M2 / M3 / M4 / M5 +) — Intel is not supported
- **8 GB** unified memory minimum (16 GB+ recommended for larger models)
- At least one inference backend installed (Ollama recommended)

---

## Getting Started

### 1. Install Ollama (or another backend)

```bash
# macOS — install Ollama
brew install ollama

# Start the server
ollama serve

# Pull a model
ollama pull llama3.2:3b
```

### 2. Build & Run Anubis

```bash
git clone https://github.com/Cyberpunk69420/anubis-oss.git
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

---

## Building from Source

```bash
# Clone
git clone https://github.com/Cyberpunk69420/anubis-oss.git
cd anubis-oss/anubis

# Build via command line
xcodebuild -scheme anubis -configuration Debug build

# Run tests
xcodebuild -scheme anubis -configuration Debug test

# Or just open in Xcode
open anubis.xcodeproj
```

### Dependencies

Resolved automatically by Swift Package Manager on first build:

| Package | Purpose | License |
|---------|---------|---------|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite database | MIT |
| Swift Charts | Data visualization | Apple |

---

## Architecture

Anubis follows MVVM with a layered service architecture:

```
┌─────────────────────────────────────────────────────────────┐
│                    PRESENTATION LAYER                        │
│   BenchmarkView    ArenaView    VaultView    SettingsView    │
├─────────────────────────────────────────────────────────────┤
│                      SERVICE LAYER                           │
│   MetricsService   InferenceService   ModelService   Export  │
├─────────────────────────────────────────────────────────────┤
│                    INTEGRATION LAYER                         │
│   OllamaClient   OpenAICompatibleClient   IOReportBridge    │
├─────────────────────────────────────────────────────────────┤
│                    PERSISTENCE LAYER                         │
│   SQLite (GRDB)              File System                     │
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
├── Integrations/           # OllamaClient, OpenAICompatibleClient, IOReportBridge
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

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+1` | Switch to Benchmark |
| `Cmd+2` | Switch to Arena |
| `Cmd+3` | Switch to Vault |
| `Cmd+R` | Run benchmark / comparison |
| `Cmd+.` | Stop current operation |
| `Cmd+E` | Export results |
| `Cmd+,` | Open Settings |

---

## Data Storage

All data is stored locally — nothing leaves your machine.

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

1. **Follow the existing patterns** — MVVM, async/await, guard-let over force-unwrap
2. **Keep files under 300 lines** — split if larger
3. **One feature per PR** — small, focused changes are easier to review
4. **Test services and integrations** — views are harder to unit test, but services should have coverage
5. **Handle errors gracefully** — always provide `errorDescription` and `recoverySuggestion`

### Adding a New Backend

1. Create a new file in `Integrations/` implementing `InferenceBackend`
2. Register it in `InferenceService`
3. Add configuration UI in `Settings/`
4. That's it — the rest of the app works through the protocol

---

## License

MIT License — see [LICENSE](LICENSE) for details.
