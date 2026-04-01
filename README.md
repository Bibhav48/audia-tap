# audia-tap 🎧

**A driverless, zero-bot macOS audio tap for real-time AI transcription.**

[![macOS](https://img.shields.io/badge/macOS-15.0%2B-black?logo=apple)](#)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

*`audia-tap` is the open-source audio routing engine extracted from **[Audia](https://github.com/Bibhav48/audia-dist/)**, our upcoming zero-bot AI meeting transcriber for macOS.*

Most local AI transcription tools on macOS force users to install clunky virtual audio drivers (like BlackHole or Loopback) or invite awkward AI bots into their Zoom meetings.

`audia-tap` is a standalone Swift CLI that completely bypasses the macOS system mixer. It uses a native Hardware Abstraction Layer (HAL) tap to hook directly into any running application's process ID (PID), extracts the raw audio, and pipes it directly to `stdout`.

**100% local. Zero virtual routing. Zero bots.**

---

## ✨ Features
* **Driverless Capture:** No BlackHole, Soundflower, or Loopback required.
* **App-Specific Targeting:** Tap any app by PID *or* by name — no manual `pgrep` required.
* **Process Discovery:** `--list` shows every active audio process in a formatted table.
* **Multi-Format Output:** Raw PCM16, streaming WAV (with header), or Float32 — pipe into anything.
* **Configurable DSP:** Volume gain, silence gating, sample rate, and channel count — all flags.
* **Sequoia Ready:** Navigates the strict macOS 15+ TCC security model using an invisible background agent.
* **UNIX Philosophy:** Pipes raw audio to `stdout` so you can feed Whisper, FFmpeg, or any AI model downstream.

---

## 🚀 Quick Start

### 1. Build and Install the CLI
```bash
git clone https://github.com/Bibhav48/audia-tap.git
cd audia-tap
# Build the .app and symlink the CLI to /usr/local/bin
./install.sh
```
> On your first run, the tool will auto-anchor the macOS Screen & System Audio Recording permission.

### 2. Discover Audio Processes
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

### 3. Tap a Process

By PID:
```bash
audia-tap --pid 1234
```

By name (no `pgrep` needed):
```bash
audia-tap --app Safari
```

You will immediately see raw binary PCM data streaming to your terminal.

---

## 📋 Complete Flag Reference

### Target Selection

| Flag | Description |
|------|-------------|
| `--pid <PID>` | Tap the process with this process ID |
| `--app <NAME>` | Tap the first audio process whose name or bundle ID contains NAME (case-insensitive) |
| `--list`, `-l` | Print all active audio processes as a table and exit |

### Output Format

| Flag | Default | Description |
|------|---------|-------------|
| `--format <fmt>` | `pcm16` | Output format: `pcm16` (raw signed 16-bit PCM), `wav` (streaming RIFF/WAV with header), `f32` (raw 32-bit float) |
| `--sample-rate <hz>` | `16000` | Destination sample rate in Hz. Whisper uses 16000; FFmpeg and music apps may prefer 44100 or 48000 |
| `--channels <n>` | `1` | `1` = mono (down-mixed), `2` = stereo pass-through |

### Output Destination

| Flag | Description |
|------|-------------|
| `--output <path>`, `-o <path>` | Write audio to a file instead of stdout (e.g. `--output recording.wav`) |
| `--duration <secs>` | Automatically stop after N seconds (e.g. `--duration 60`) |

### Audio Processing

| Flag | Default | Description |
|------|---------|-------------|
| `--volume <gain>` | `1.0` | Linear gain multiplier applied before conversion. `2.0` doubles volume; `0.5` halves it |
| `--silence-threshold <rms>` | `0` (off) | Drop audio chunks whose RMS level is below this value. Prevents silence from being piped to Whisper (which causes hallucination). Try `0.01` |

### Metadata

| Flag | Description |
|------|-------------|
| `--json-info` | Print a JSON object to stderr before audio begins: `pid`, `name`, `bundleID`, `format`, `sampleRate`, `channels`, `tapSourceSampleRate` |

### Agent & Daemon

| Flag | Default | Description |
|------|---------|-------------|
| `--agent` | — | Run as a background permission-anchoring agent (normally started automatically) |
| `--via-agent` | — | Connect directly to a running agent without auto-launching one |
| `--agent-socket <path>` | `/tmp/audia-tap-<uid>.sock` | Override the Unix socket path used for agent communication |
| `--timeout <secs>` | `8.0` | How long to wait for the agent socket to appear before giving up |

### Debugging

| Flag | Description |
|------|-------------|
| `--verbose`, `-v` | Enable verbose debug output on stderr (equivalent to `AUDIA_TAP_DEBUG=1`) |
| `--quiet`, `-q` | Suppress all informational `[audia-tap]` stderr messages for clean pipeline integration |

### Miscellaneous

| Flag | Description |
|------|-------------|
| `--request-permission` | Request Audio Capture permission and exit |
| `--chunk-frames <n>` | Internal ring-buffer chunk size in frames (default: `4096`). Lower values reduce latency; higher values improve throughput |
| `--help`, `-h` | Show the full help message and exit |
| `--version` | Print the version string and exit |

---

## 🧠 Python Integration & Examples

The true power of `audia-tap` is piping it into local AI models. Two sample scripts are included in `Scripts/`.

### Setup Environment (using `uv`)
```bash
uv venv
source .venv/bin/activate
```

### Option 1: Whisper (OpenAI)
```bash
uv pip install openai-whisper numpy
python3 Scripts/whisper_demo.py <PID>
```

### Option 2: Parakeet MLX (Apple Silicon Native)
```bash
uv pip install "mlx>=0.19.0" "parakeet-mlx>=1.0.1" numpy soundfile
python3 Scripts/parakeet_mlx_demo.py <PID>
```

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

Built by [Bibhav Adhikari](https://github.com/Bibhav48) and [Arjav Lamsal](https://github.com/arjavlamsal). We originally engineered this HAL tap for **[Audia](https://github.com/Bibhav48/audia-dist/)** and decided to open-source the core engine for the macOS community.

## ⚖️ License

MIT License