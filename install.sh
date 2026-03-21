#!/bin/bash
set -e

echo "🎙️  Building audia-tap (Release mode)..."

# Build the Xcode project
xcodebuild build \
  -project audia-tap.xcodeproj \
  -scheme audia-tap \
  -configuration Release \
  > /dev/null

echo "📦 Installing audia-tap.app to /Applications/..."
# Remove any existing installation
sudo rm -rf /Applications/audia-tap.app
# Copy the freshly built release app to Applications
sudo cp -R dist/Release/audia-tap.app /Applications/

echo "🔗 Setting up CLI command..."
# Create a global symlink so the user can just type `audia-tap` anywhere
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/audia-tap.app/Contents/MacOS/audia-tap /usr/local/bin/audia-tap

echo "✨ Installation complete!"
echo "You can now run 'audia-tap' from any terminal."
echo "Example: audia-tap --pid 1234"
