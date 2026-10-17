# Contributing

Run `./test.sh` on macOS 14+ with Xcode Command Line Tools before submitting changes. Tests use loopback and mocks, not real hardware. Run `python3 scripts/privacy_check.py` after staging new files.

Keep UI changes reviewable with demo screenshots. Never include real IP addresses, device IDs, tokens, desktop captures, personal paths or preference files. Use documentation addresses for fixtures.

For hardware compatibility reports, include the model identifier, firmware version and supported method names, with identifying headers removed. A successful build does not establish hardware compatibility.

Explain what changed, why, and how it was verified. Add regression tests for protocol or state-management changes. Do not include signing keys, provisioning files or Apple credentials.
