# Permissions Plan

## Current Scope

iAgent is a local macOS menu bar voice assistant. In the current implementation, the only system privacy permission it actively needs is microphone access.

Relevant code paths:

- `VoiceService` uses `AVAudioEngine` to capture microphone input.
- `ASRService` and `TTSService` call remote APIs over `URLSession`.
- `AgentService` launches the local `claude` CLI via `Process`.

## Current Configuration

The project currently keeps a minimal permission surface:

- `NSMicrophoneUsageDescription`
- `com.apple.security.device.audio-input = true`
- `LSUIElement = YES`

The app is currently not sandboxed:

- `ENABLE_APP_SANDBOX = NO`
- `com.apple.security.app-sandbox = false`

This is intentional for now because the app depends on:

- launching a local CLI executable
- accessing user-selected local working directories
- reading local configuration from Application Support
- writing temporary audio files

## Permissions To Keep

Keep these enabled in the current release line:

- Microphone access
- Microphone usage description text

## Permissions Not To Add Yet

Do not add these until the product actually uses them:

- `NSSpeechRecognitionUsageDescription`
- `NSAppleEventsUsageDescription`
- camera permission
- screen recording permission
- accessibility permission
- full disk access guidance

Adding unused permissions increases user trust cost and makes release review harder.

## Runtime Behavior

Startup should explicitly verify microphone permission before starting capture.

If microphone access is denied, the app should:

- fail startup gracefully
- show a clear status message
- direct the user to `System Settings -> Privacy & Security -> Microphone`

## Future Expansion Rules

Add permissions only when the feature ships:

- Apple Speech framework: add `NSSpeechRecognitionUsageDescription`
- controlling other apps: add `NSAppleEventsUsageDescription`
- keyboard/mouse automation: add accessibility guidance
- screen understanding or capture: add screen recording permission flow

## App Store / Sandbox Note

If the project later targets Mac App Store distribution, permissions alone will not be enough. The execution model must be revisited because the current `Process + claude + non-sandbox` design is not App Sandbox friendly.
