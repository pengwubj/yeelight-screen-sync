# Pre-publication code review

The initial local prototype was reviewed before creating the public repository. This is a source review and regression-test record, not an independent security audit.

| Priority | Finding | Remediation | Evidence |
| --- | --- | --- | --- |
| Release blocker | The prototype contained a specific device address and a personal bundle identifier. | Removed the address fallback, adopted a neutral identifier, used only offline demo data in screenshots, and excluded local artifacts. | `scripts/privacy_check.py`, `ModelCheck` demo isolation |
| P2 | Concurrent sync-stop paths could restore a stale busy flag and leave controls disabled. | Made cleanup idempotent and derived busy state from operation and cleanup ownership. | `ModelCheck`: concurrent stop and overlapping operation |
| P2 | A delayed manual colour command could outlive a device change. | Cancel queued colour work on endpoint change/start, and verify the original endpoint before sending. | `ModelCheck`: device-switch regression |
| P2 | Repeated partial TCP traffic could extend a response beyond its intended deadline. | Poll against one monotonic response deadline before every receive. | `TransportTests.test_deadline` |
| P2 | Unrelated UDP result packets could incorrectly count as successful keep-alives. | Correlate heartbeat IDs; validate handshake tokens; bound datagram draining per tick. | `test_unrelated_ack`, `test_bad_token`, `test_stream` |
| P2 | A capture failure during startup could be missed before the UI marked sync active. | Record startup capture errors and check before entering the running state. | Source review; actual capture needs macOS permission and manual testing |
| P2 | The first test server could leave a blocking accept alive after a client failure. | Use timed loopback sockets, bounded joins and explicit teardown. | Test suite exercises early-error paths |
| P3 | A local build used an overly broad custom signing requirement. | Use the standard ad hoc requirement or a supplied signing identity, with a deployment target matching the plist. | Build, `codesign --verify --deep --strict` |

## Validation boundary

- Colour self-checks cover channel order, neutral and black frames, dominant colour versus averaging, smoothing convergence, padded row stride, exact sRGB presets and empty dimensions.
- Model tests use injected transport/capture mocks and verify that demo mode performs no device or screen operations.
- Transport integration uses ephemeral loopback ports and a synthetic token, including 400 colour commands over 40 seconds.
- Python CLI tests cover discovery parsing, background command mapping, multi-device selection and fragmented replies with notifications.
- The original `lamp15`/firmware 38 hardware path was exercised for basic controls and red/blue screen matching. Changes to transport are checked with loopback regression tests; that does not establish compatibility with every firmware.
- Screen permission denial/re-grant, protected content, HDR, display removal and sleep/wake remain manual platform checks. Public screenshots use demo state and are not proof of hardware operation.

## Known limits

The vendor LAN protocol remains unencrypted. The app does not authenticate the physical lamp beyond the protocol's local endpoint/session exchange. Model support beyond the tested device identifier is unverified. Network errors stop sync; automatic reconnection is not implemented. Local ad hoc builds are not Apple-notarized and may require permission renewal after rebuilding.
