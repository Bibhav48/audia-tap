<p align="center">
  <img src="assets/icon-light.png" width="170" height="170" alt="Audia Tap icon"/>
</p>

<h1 align="center">audia-tap</h1>

<p align="center">
  <a href="https://github.com/Bibhav48/audia-tap"><img src="https://img.shields.io/badge/Swift-5.9-F05138.svg?style=for-the-badge&logo=swift&logoColor=white" alt="Swift"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-15%2B-3a3a3c?style=for-the-badge&labelColor=1c1c1e&logo=apple&logoColor=white" alt="macOS 15+"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-3a3a3c?style=for-the-badge&labelColor=1c1c1e" alt="License: MIT"></a>
  <a href="https://github.com/Bibhav48/audia-tap"><img src="https://img.shields.io/badge/Status-Beta-3a3a3c?style=for-the-badge&labelColor=1c1c1e" alt="Status: Beta"></a>
</p>

<p align="center">
  <b>A native, open-source CLI for tapping per-app macOS audio.</b><br>
  <i>The foundational extraction engine behind Audia. Extract raw PCM audio directly from any process and pipe it anywhere.</i>
</p>

<p align="justify">
  <strong>audia-tap</strong> is a standalone Swift CLI that bypasses the macOS system mixer entirely. It uses a native Hardware Abstraction Layer (HAL) tap to hook directly into any running application's process ID (PID), extracting raw 16-bit PCM audio and piping it straight to <code>stdout</code>.
  <br><br>
  Originally built as the core audio routing engine for <strong><a href="https://github.com/Bibhav48/audia-dist/">Audia</a></strong>, we've open-sourced this fundamental building block for the community. Capture application audio without clunky virtual drivers (like BlackHole). 100% local. Zero virtual routing.
</p>

<p align="center">
  <img src="assets/Audia-tap-demo.gif" alt="Audia Tap Demo" width="100%"/>
</p>

<br>

## ⚡ Features

- **Driverless Capture** — No BlackHole, Soundflower, or Loopback required. Runs entirely natively.
- **App-Specific Targeting** — Tap any app by PID or by name with `--app`. Captures exactly what you want without notifications bleeding into transcription.
- **Process Discovery** — `--list` shows every active audio process in a formatted table with bundle IDs and status.
- **Multi-Format Output** — Raw PCM16, streaming WAV (with header), or Float32 — pipe into anything.
- **Configurable DSP** — Volume gain, silence gating, sample rate, and channel count — all configurable via flags.
- **Sequoia Ready (macOS 15+)** — Successfully navigates the strict macOS TCC (Transparency, Consent, and Control) security model using an invisible background agent, ensuring resilient Screen & System Audio Recording permission handling.
- **UNIX Philosophy** — Does one thing well: pipes raw PCM data to `stdout` so you can effortlessly pipe it into Whisper, FFmpeg, Parakeet, or any AI model downstream.

<br>

## 🚀 Quick Start

### 1. Build and Install

Clone the repository and install the CLI globally. _(Requires Xcode command-line tools)_.

```bash
git clone https://github.com/Bibhav48/audia-tap.git
cd audia-tap

# Build and install the app to /Applications and link the CLI to /usr/local/bin
./install.sh
```

> **Permission Note:** On your first run, the tool will auto-anchor to handle macOS Screen & System Audio Recording permissions cleanly.

### 2. Find your Target PID

Identify the process ID of the application you want to transcribe:

```bash
audia-tap --list
```

This prints a table of every process currently producing (or registered for) audio:

```
────────────────────────────────────────────────────────────────────
  PID    NAME              BUNDLE ID                      ACTIVE
────────────────────────────────────────────────────────────────────
  471    coreaudiod                                         no
  1234   Safari            com.apple.Safari               ▶ yes
  5678   Spotify           com.spotify.client             ▶ yes
────────────────────────────────────────────────────────────────────
  3 process(es) listed. Use audia-tap --pid <PID> to tap one.
────────────────────────────────────────────────────────────────────
```

### 3. Run the Tap

Execute `audia-tap` with the targeted PID. You can tap by PID directly:

```bash
audia-tap --pid 1234
```

Or by app name (no `pgrep` needed):

```bash
audia-tap --app Safari
```

_You will immediately see raw binary PCM data flowing into your terminal's standard output._

<br>

## 📋 Complete Flag Reference

### Target Selection

| Flag           | Description                                                                          |
| -------------- | ------------------------------------------------------------------------------------ |
| `--pid <PID>`  | Tap the process with this process ID                                                 |
| `--app <NAME>` | Tap the first audio process whose name or bundle ID contains NAME (case-insensitive) |
| `--list`, `-l` | Print all active audio processes as a table and exit                                 |

### Output Format

| Flag                 | Default | Description                                                                                                      |
| -------------------- | ------- | ---------------------------------------------------------------------------------------------------------------- |
| `--format <fmt>`     | `pcm16` | Output format: `pcm16` (raw signed 16-bit PCM), `wav` (streaming RIFF/WAV with header), `f32` (raw 32-bit float) |
| `--sample-rate <hz>` | `16000` | Destination sample rate in Hz. Whisper uses 16000; FFmpeg and music apps may prefer 44100 or 48000               |
| `--channels <n>`     | `1`     | `1` = mono (down-mixed), `2` = stereo pass-through                                                               |

### Output Destination

| Flag                           | Description                                                             |
| ------------------------------ | ----------------------------------------------------------------------- |
| `--output <path>`, `-o <path>` | Write audio to a file instead of stdout (e.g. `--output recording.wav`) |
| `--duration <secs>`            | Automatically stop after N seconds (e.g. `--duration 60`)               |

### Audio Processing

| Flag                        | Default   | Description                                                                                                                                  |
| --------------------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `--volume <gain>`           | `1.0`     | Linear gain multiplier applied before conversion. `2.0` doubles volume; `0.5` halves it                                                      |
| `--silence-threshold <rms>` | `0` (off) | Drop audio chunks whose RMS level is below this value. Prevents silence from being piped to Whisper (which causes hallucination). Try `0.01` |

### Metadata

| Flag          | Description                                                                                                                             |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `--json-info` | Print a JSON object to stderr before audio begins: `pid`, `name`, `bundleID`, `format`, `sampleRate`, `channels`, `tapSourceSampleRate` |

### Agent & Daemon

| Flag                    | Default                     | Description                                                                     |
| ----------------------- | --------------------------- | ------------------------------------------------------------------------------- |
| `--agent`               | —                           | Run as a background permission-anchoring agent (normally started automatically) |
| `--via-agent`           | —                           | Connect directly to a running agent without auto-launching one                  |
| `--agent-socket <path>` | `/tmp/audia-tap-<uid>.sock` | Override the Unix socket path used for agent communication                      |
| `--timeout <secs>`      | `8.0`                       | How long to wait for the agent socket to appear before giving up                |

### Debugging

| Flag              | Description                                                                             |
| ----------------- | --------------------------------------------------------------------------------------- |
| `--verbose`, `-v` | Enable verbose debug output on stderr (equivalent to `AUDIA_TAP_DEBUG=1`)               |
| `--quiet`, `-q`   | Suppress all informational `[audia-tap]` stderr messages for clean pipeline integration |

### Miscellaneous

| Flag                   | Description                                                                                                                |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `--request-permission` | Request Audio Capture permission and exit                                                                                  |
| `--chunk-frames <n>`   | Internal ring-buffer chunk size in frames (default: `4096`). Lower values reduce latency; higher values improve throughput |
| `--help`, `-h`         | Show the full help message and exit                                                                                        |
| `--version`            | Print the version string and exit                                                                                          |

---

## 📖 Usage Examples

```bash
# List all audio-producing processes
audia-tap --list

# Tap Safari and pipe directly into Whisper
audia-tap --app Safari | python3 Scripts/whisper_demo.py /dev/stdin

# Save Spotify output as a stereo WAV at 44.1 kHz
audia-tap --app Spotify --format wav --sample-rate 44100 --channels 2 --output spotify.wav

# Tap Zoom for 60 seconds, boost quiet audio, suppress silence
audia-tap --app Zoom --volume 1.5 --silence-threshold 0.01 --duration 60

# Inspect stream metadata as JSON before audio begins
audia-tap --pid 1234 --json-info --quiet 2>info.json | python3 my_model.py

# Tap any app with verbose debug output
audia-tap --app Spotify --verbose

# Run quietly without any [audia-tap] status messages
audia-tap --pid 1234 --quiet > my_recording.pcm

# Override the default 16kHz to 48kHz float32 for FFmpeg
audia-tap --pid 1234 --format f32 --sample-rate 48000 | ffmpeg -f f32le -ar 48000 -ac 1 -i - out.mp3
```

---

## 🧠 Python AI Integration

The true power of `audia-tap` lies in piping the audio stream directly into local LLMs. We provide sample scripts in the `Scripts/` directory that read the `stdout` buffer and feed it into AI models in real-time.

### Setup Environment (Using `uv`)

We highly recommend using `uv` to manage your virtual environment for peak performance.

```bash
uv venv
source .venv/bin/activate
```

### Option A: Whisper (OpenAI)

```bash
# Install required dependencies
uv pip install openai-whisper numpy

# Run the real-time tap script with your target PID
python3 Scripts/whisper_demo.py <PID>
```

### Option B: Parakeet MLX (Apple Silicon Native)

```bash
# Install native dependencies for blazing fast Apple Silicon performance
uv pip install "mlx>=0.19.0" "parakeet-mlx>=1.0.1" numpy soundfile

# Run the script
python3 Scripts/parakeet_mlx_demo.py <PID>
```

<br>

## 🗺️ Roadmap

- [x] **Stability:** Auto-restarts and headless background daemonization (via `--agent`)
- [x] **Process discovery UX:** `audia-tap --list` to view all active audio processes
- [x] **Zero-config mode:** Target apps by name (`--app "Spotify"`) instead of PID
- [x] **Advanced streaming:** Native support for `--format wav|f32`
- [x] **Configurable DSP:** `--sample-rate`, `--channels`, `--volume`, `--silence-threshold`
- [x] **Output routing:** `--output <file>` and `--duration`
- [ ] **RTP streaming:** `--rtp <host:port>` for network audio routing

---

## 🤝 Authors

Built with ❤️ by [Bibhav Adhikari](https://github.com/Bibhav48) and [Arjav Lamsal](https://github.com/arjavlamsal).

_audia-tap is the open-source audio routing engine extracted from **[Audia](https://github.com/Bibhav48/audia-dist/)**, our upcoming zero-bot AI meeting transcriber for macOS._

## ⚖️ License

Distributed under the [MIT License](https://opensource.org/licenses/MIT).
