# Third-party notices

The screen-status detector in `src/status.zig` adapts selected visible UI signals and the separation of detection from completion tracking from [Herdr](https://github.com/herdrdev/herdr), revision `b9ce96869e89937278d673d70ae4c135dd318469`.

Reference files: `src/detect/manifests/codex.toml`, `src/detect/manifests/claude.toml`, `src/pane/agent_detection.rs`, and the published agent-state documentation. Herdr is licensed under Apache License 2.0; a copy is in `licenses/Herdr-Apache-2.0.txt`.

The Zig detector is a limited adaptation, not Herdr's manifest engine. It uses explicit recent-screen controls, conservative unknown results, two-sample idle confirmation, and controller-local receipt acknowledgement. It does not implement remote manifest updates, OSC progress detection, or Herdr lifecycle integrations.
