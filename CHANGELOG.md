# Changelog

## [0.1.0] — 2026-11-23

- Connection errors: `DeviceStreamSession.onError` / `lastError` with reasons `credentials_unavailable`, `connection_refused`, `token_rejected` (upgrade 401), `disconnected`, `device_unavailable` and `unknown`, and a `final` flag.
- `StreamCredentials.tokenProvider` is recommended: a fresh key before every connect attempt. The static token is legacy and deprecated (reconnects reuse it; one log warning per session).
- `StreamLabels.disconnected` for reconnecting after a dropped session.
- Live iOS device streaming with automatic reconnect and audio controls.
- SwiftUI and UIKit video with touch, pointer, keyboard and system-key input.
- Default stream controls, customizable labels, themes and Liquid Glass chrome.
- Backend-driven task approvals with polling and custom actions.
- Read-only stream statistics and connection timing.
- Visibility and wake lifecycle integration.
- Screenshots with cancellation and timeout handling.
