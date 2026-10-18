<p align="center"><img src="AppIcon.png" width="128" alt="NotchPilot icon"></p>

# NotchPilot

An AI copilot that lives in your Mac's notch. Hover the notch, tap the camera or mic, and read the answer like a teleprompter.

- **📸 Camera:** reads the question on your screen and answers it
- **🎙 Mic:** hears the question (speech-to-text runs on your Mac), then answers with your screen as context
- **Teleprompter:** answers scroll by themselves; scroll with your trackpad or use ▶︎/⏸
- **Your resume:** answers draw on your real experience, in situation → action → result form

Works with OpenAI, Anthropic, Google Gemini, any OpenAI-compatible API (Groq, OpenRouter, Ollama), or your Claude subscription through Claude Code.

## Screen sharing
NotchPilot keeps itself out of the screenshots it takes. On macOS 15 and later, Apple gives apps no way to hide a window from screen-sharing apps like Zoom and Google Meet, so **if you share your entire screen, others can see NotchPilot.** Share a single window or tab instead.

## Requirements
macOS 14 Sonoma or later. Best on a Mac with a notch; on other Macs it sits at the top center of the screen.

## Install
Download the latest `NotchPilot-x.y.dmg`, open it, and drag NotchPilot into Applications. A short setup walks you through your AI key, your resume, and permissions.

If macOS says it can't verify the developer, open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to NotchPilot. You only need to do this once.

## Build from source
```
xcode-select --install   # once
bash build.sh
open NotchPilot.app
```
`bash release.sh` makes a DMG in `dist/`. See the top of that script for signing and notarizing with an Apple Developer ID.

## Privacy
NotchPilot has no server and collects nothing. When you tap the camera or mic, it sends that screenshot and question straight from your Mac to the AI provider you chose, under that provider's terms. API keys are stored in your macOS Keychain. Your resume and settings stay on your Mac.

## License
MIT
