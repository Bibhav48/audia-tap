# audia-tap 🎧

**A driverless, zero-bot macOS audio tap for real-time AI transcription.**

[![macOS](https://img.shields.io/badge/macOS-15.0%2B-black?logo=apple)](#)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

*`audia-tap` is the open-source audio routing engine extracted from **[Audia](https://github.com/Bibhav48/audia-dist/)**, our upcoming zero-bot AI meeting transcriber for macOS.*

Most local AI transcription tools on macOS force users to install clunky virtual audio drivers (like BlackHole or Loopback) or invite awkward AI bots into their Zoom meetings. 

`audia-tap` is a standalone Swift CLI that completely bypasses the macOS system mixer. It uses a native Hardware Abstraction Layer (HAL) tap to hook directly into any running application's process ID (PID), extracts the raw 16-bit PCM audio, and pipes it directly to `stdout`.

100% local. Zero virtual routing. Zero bots.

### 🎥 See it in action
*(Insert a link to your 60-second Loom video here showing the terminal transcribing a Safari YouTube video while the Mac Sound Preferences clearly show NO virtual drivers installed).*

---

## ✨ Features
* **Driverless Capture:** No BlackHole, Soundflower, or Loopback required.
* **App-Specific Targeting:** Hooks directly to a specific PID (Safari, Zoom, QuickTime) without capturing your Slack notification sounds.
* **Sequoia Ready:** Successfully navigates the strict macOS 15+ TCC (Transparency, Consent, and Control) security model using an invisible background agent, ensuring resilient Screen & System Audio Recording permission handling natively.
* **UNIX Philosophy:** It does one thing well—spits out raw PCM data to `stdout` so you can pipe it into Whisper, FFmpeg, or any AI model.

## 🚀 Quick Start

### 1. Build and Install the CLI
Clone the repo and install the CLI globally. (Requires Xcode command-line tools).

```bash
git clone [https://github.com/Bibhav48/audia-tap.git](https://github.com/Bibhav48/audia-tap.git)
cd audia-tap
# Build and install the app to /Applications and link the CLI to /usr/local/bin
./install.sh
```
*Note: On your first run, the tool will auto-anchor to handle macOS Screen & System Audio Recording permissions.*

### 2. Find your Target PID
Find the process ID of the app you want to transcribe:
```bash
pgrep Safari
# Example output: 83419
```

### 3. Run the Tap
```bash
audia-tap --pid 83419
```
*You will immediately see raw binary PCM data flowing into your terminal.*

## 🧠 Python Integration & Examples
The true power of `audia-tap` is piping it into local LLMs. We have included two sample scripts in the `Scripts/` directory that read the `stdout` buffer and feed it into AI models in real-time.

### Setup Environment (using `uv`)
We highly recommend using `uv` to manage your virtual environment.

```bash
# Create and activate a virtual environment
uv venv
source .venv/bin/activate
```

### Option 1: Whisper Integration
```bash
# Install dependencies
uv pip install openai-whisper numpy

# Run the script with your target PID
python3 Scripts/whisper_demo.py <PID>
```

### Option 2: Parakeet MLX (Apple Silicon Native)
```bash
# Install dependencies
uv pip install "mlx>=0.19.0" "parakeet-mlx>=1.0.1" numpy soundfile

# Run the script with your target PID
python3 Scripts/parakeet_mlx_demo.py <PID>
```

## 🗺️ Roadmap (Coming Soon)
We built the core engine, but we are actively expanding this to be the ultimate macOS audio routing CLI. **Pull Requests are highly encouraged!**

- [ ] **Zero-config mode:** Target apps by name (`--app "Spotify"`) instead of PID.
- [ ] **Process discovery UX:** `audia-tap --list` to view all active audio processes.
- [ ] **Advanced streaming:** Native support for `--format wav|aac` and `--rtp`.
- [x] **Stability:** Auto-restarts and headless background daemonization (via `--agent`).

## 🤝 Authors
Built by [Bibhav Adhikari](https://github.com/Bibhav48) and [Arjav Lamsal](https://github.com/arjavlamsal). We originally engineered this HAL tap for **[Audia](https://github.com/Bibhav48/audia-dist/)** and decided to open-source the core engine for the macOS community.

## ⚖️ License
MIT License