import subprocess
import numpy as np
import whisper
import os
import sys

if len(sys.argv) < 2:
    print("Usage: python3 whisper_demo.py <PID>")
    sys.exit(1)

TARGET_PID = sys.argv[1]
BINARY_PATH = "audia-tap"

print("Loading local Whisper model...")                                                                           
model = whisper.load_model("base")                                                                                
print("Model loaded.")

print(f"Hooking into PID {TARGET_PID} via HAL tap...")

process = subprocess.Popen(
    [BINARY_PATH, "--pid", TARGET_PID], 
    stdout=subprocess.PIPE
)

# Increased chunk size to give Whisper more context per pass
CHUNK_SECONDS = 3
BYTES_PER_CHUNK = 16000 * 2 * CHUNK_SECONDS

# Increased max buffer to prevent the "guillotine" effect slicing words in half
MAX_BUFFER_SECONDS = 30 

audio_buffer = np.array([], dtype=np.float32)
full_transcript = ""
live_text = ""

try:
    while True:
        raw_audio = process.stdout.read(BYTES_PER_CHUNK)
        
        if not raw_audio:
            print("\nAudio stream ended or CLI crashed. Check for errors above.")
            break
            
        audio_int16 = np.frombuffer(raw_audio, dtype=np.int16)
        new_chunk_float32 = audio_int16.astype(np.float32) / 32768.0

        # Append the new audio chunk to our running buffer
        audio_buffer = np.concatenate((audio_buffer, new_chunk_float32))

        # Transcribe the current live buffer
        live_result = model.transcribe(audio_buffer, fp16=False)
        live_text = live_result["text"].strip()

        # Clear the terminal screen for a clean UI refresh
        os.system('cls' if os.name == 'nt' else 'clear')
        
        # Print the header and the continuous paragraph
        print("🔴 RECORDING LIVE... (Press Ctrl+C to stop and save)")
        print("-" * 50)
        
        # Combine the locked-in history with the current live guess
        current_display = f"{full_transcript} {live_text}".strip()
        print(f"🗣️: {current_display}")

        # Once the buffer hits our limit, "lock in" the text and clear the audio buffer
        if len(audio_buffer) >= 16000 * MAX_BUFFER_SECONDS:
            full_transcript += " " + live_text
            audio_buffer = np.array([], dtype=np.float32)

except KeyboardInterrupt:
    # 1. Immediately terminate the audio capture process
    print("\n\nShutting down tap... Gathering final words...")
    process.terminate()
    
    # 2. Do ONE FINAL Whisper pass on whatever is lingering in the buffer
    if len(audio_buffer) > 0:
        print("Processing the last few seconds of audio...")
        final_result = model.transcribe(audio_buffer, fp16=False)
        live_text = final_result["text"].strip()
    
    # 3. Save the final continuous paragraph to a file
    final_output = f"{full_transcript} {live_text}".strip()
    filename = f"meeting_notes_PID_{TARGET_PID}.txt"
    
    with open(filename, "w", encoding="utf-8") as file:
        file.write(final_output)
        
    print(f"✅ Successfully saved complete transcription to: {filename}")
