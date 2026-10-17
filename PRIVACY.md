# Privacy

- The app processes downsampled display frames in memory to calculate a colour. It does not save or upload screenshots or video and disables audio capture.
- Only lighting commands are sent to the configured light. UDP session tokens stay in memory and are not included in logs or screenshots.
- The last successful device IP is stored in local macOS preferences under the app's bundle identifier. Discovery results and display names are not persisted by this project.
- There is no project-hosted backend, login, telemetry, advertising SDK or analytics code.
- `--demo` uses synthetic state, does not load the stored device address, and performs no network or screen operations.
- Source releases exclude local preferences, `.env` files, keys, app bundles, build caches, logs and Finder metadata. Documentation screenshots come only from demo mode.
- The Yeelight LAN protocol is unencrypted. It relies on the security of the local network and does not provide cloud-style account authentication.

The README links to external documentation and GitHub badges. Viewing that web page is separate from running the app. macOS itself manages permissions and may maintain its own system diagnostics.
