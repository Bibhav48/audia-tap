import subprocess
import numpy as np
from parakeet_mlx import from_pretrained
import os
import tempfile
import soundfile as sf
import sys
import time
import threading
import queue

if len(sys.argv) < 2:
    print("Usage: python3 parakeet_mlx_demo.py <PID>")
    sys.exit(1)

TARGET_PID = sys.argv[1]
BINARY_PATH = "audia-tap"

print("Loading Parakeet MLX model directly onto Apple Silicon (Metal)...")                                                                           
model = from_pretrained("mlx-community/parakeet-tdt-0.6b-v2")                                                                                
print("Model loaded into Unified Memory.")

print(f"Hooking into PID {TARGET_PID} via HAL tap...")

process = subprocess.Popen(
    [BINARY_PATH, "--pid", TARGET_PID], 
    stdout=subprocess.PIPE
)

CHUNK_SECONDS = 1
BYTES_PER_CHUNK = 16000 * 2 * CHUNK_SECONDS
MAX_BUFFER_SECONDS = 30 

# Create a Thread-Safe Bucket for our audio
audio_bucket = queue.Queue()

# --- THREAD 1: The Audio Drainer ---
# This runs in the background. Its ONLY job is to read stdout instantly
# so the CLI tool NEVER backs up and glitches the audio.
def audio_reader():
    while True:
        raw_audio = process.stdout.read(BYTES_PER_CHUNK)
        if not raw_audio:
            print("\n[Audio Thread] Stream ended or CLI crashed.")
            break
        # Toss the raw audio into the bucket
        audio_bucket.put(raw_audio)

# Start the background thread
reader_thread = threading.Thread(target=audio_reader, daemon=True)
reader_thread.start()

# --- MAIN THREAD: AI & UI ---
audio_buffer = np.array([], dtype=np.float32)
full_transcript = ""
live_text = ""
last_live_text = ""
temp_wav_path = os.path.join(tempfile.gettempdir(), "parakeet_live_buffer.wav")

def get_volume_bar(audio_chunk):
    rms = np.sqrt(np.mean(audio_chunk**2))
    level = min(10, int(rms * 100))
    bar = "=" * level + " " * (10 - level)
    return f"[{bar}]"

try:
    while True:
        # 1. Grab audio from the bucket (blocks until audio is ready)
        raw_audio = audio_bucket.get()
        
        # Catch-up optimization: If the AI fell behind, grab ALL pending audio in the bucket
        while not audio_bucket.empty():
            raw_audio += audio_bucket.get()

        audio_int16 = np.frombuffer(raw_audio, dtype=np.int16)
        new_chunk_float32 = audio_int16.astype(np.float32) / 32768.0

        audio_buffer = np.concatenate((audio_buffer, new_chunk_float32))

        # 2. Transcribe
        sf.write(temp_wav_path, audio_buffer, 16000)
        live_result = model.transcribe(temp_wav_path)
        live_text = live_result.text.strip()

        # 3. Calculate Diff
        prefix_len = 0
        for i in range(min(len(last_live_text), len(live_text))):
            if last_live_text[i] == live_text[i]:
                prefix_len += 1
            else:
                break

        stable_live = live_text[:prefix_len]
        new_live = live_text[prefix_len:]

        # --- THE SMART UI THRESHOLD ---
        # How many characters of our old text got destroyed/rewritten?
        rewritten_chars = len(last_live_text) - prefix_len
        
        # If it rewrote more than 15 characters, bypass the streaming effect 
        # to save time and instantly snap the new correction to the screen.
        instant_snap = rewritten_chars > 15 

        # 4. Render UI
        os.system('cls' if os.name == 'nt' else 'clear')
        
        vol_bar = get_volume_bar(new_chunk_float32)
        print(f"🔴 RECORDING LIVE WITH PARAKEET... {vol_bar} (Press Ctrl+C to stop)")
        print("-" * 50)
        
        DISPLAY_TAIL = 800
        if len(full_transcript) > DISPLAY_TAIL:
            visible_history = "..." + full_transcript[-DISPLAY_TAIL:]
        else:
            visible_history = full_transcript
            
        if instant_snap:
            # Huge rewrite happened. Print the whole thing instantly.
            sys.stdout.write(f"🗣️: {visible_history} {live_text}")
            sys.stdout.flush()
        else:
            # Normal continuation. Print history + stable text, stream the new words.
            sys.stdout.write(f"🗣️: {visible_history} {stable_live}")
            sys.stdout.flush()
            
            if new_live:
                max_typing_time = 0.3
                type_speed = min(0.015, max_typing_time / len(new_live))
                for char in new_live:
                    sys.stdout.write(char)
                    sys.stdout.flush()
                    time.sleep(type_speed)

        print()

        last_live_text = live_text

        # 5. Buffer Reset
        if len(audio_buffer) >= 16000 * MAX_BUFFER_SECONDS:
            full_transcript += (" " + live_text) if full_transcript else live_text
            audio_buffer = np.array([], dtype=np.float32)
            last_live_text = "" 

except KeyboardInterrupt:
    print("\n\nShutting down tap... Gathering final words...")
    process.terminate()
    
    if len(audio_buffer) > 0:
        print("Processing the last few seconds of audio...")
        sf.write(temp_wav_path, audio_buffer, 16000)
        final_result = model.transcribe(temp_wav_path)
        live_text = final_result.text.strip()
    
    final_output = f"{full_transcript} {live_text}".strip()
    filename = f"meeting_notes_PID_{TARGET_PID}.txt"
    
    with open(filename, "w", encoding="utf-8") as file:
        file.write(final_output)
        
    if os.path.exists(temp_wav_path):
        os.remove(temp_wav_path)
        
    print(f"✅ Successfully saved complete transcription to: {filename}")
