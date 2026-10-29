# Trace the existing LDN boundary

`DM_LDN_TRACE=1`, set before launch, records the first 64 actual `nn::ldn` hook entries on Mac and iOS. Each line contains a sequence number, the registered mangled symbol and its existing offline outcome. Scan capacity, private-create address count and advertise-data length are the only guest argument values recorded. The trace does not read opaque structures, credentials, advertisement bytes, peer addresses or user data.

Initialization still fails, state stays none, scanning still reports zero results, and the state-change event stays bound without being signaled. Network/security output buffers retain their existing behavior. The diagnostic preserves errno around logging and stops reserving sequence numbers after 64 entries. Under concurrent calls, sequence numbers identify reservation order; stderr line order is not a cross-thread execution guarantee.

## Use the trace

Record the exact `main` and `sdk` build IDs, host revision and source hashes, then launch an isolated game with the flag enabled and enter its local-wireless menu through the authorized test route. Retain the `ldn trace` lines alongside the normal log. A line numbered `64/64` means the budget is exhausted. No new calls are enabled by tracing, so a game that stops at the failed `Initialize` will not produce a discovery or join sequence.

Use the first reached hook and its caller to locate that exact SDK wrapper in the extracted memory image. Confirm argument and output sizes, Result values, state enum transitions, event binding/signaling rules, node membership and security/advertisement layout from the caller and implementation before implementing a service. Existing `DM_IMPORTS` shows linkage, not call order. `DM_HLECOUNT` works only on Mac; it is deliberately a no-op on iOS.

The socket implementation on this branch supplies transport under `DM_NET=1`, but does not implement LDN discovery, connection state or Pia sessions. Leave the game's shipped Pia code in place while establishing its LDN contract. Do not return success or fill unknown `NetworkInfo`/security objects to move past the current failure. A later functional service needs confirmed layouts and two peers to verify discovery, join, membership updates, disconnect and event signaling.

## Verification

`make -C dm/host/tests GAME=<known profile> ldn-trace` invokes all 25 actual registered hooks without game files or a network peer. It checks default-off logging, full symbol/sequence records, the 64-line cap under repeated polling, unchanged failure/state/output/event-binding behavior, no reads through deliberately invalid opaque pointers, scalar-count logging, identity exclusion and errno preservation. Event binding is a test stub; no real kernel event or wireless session is exercised.

`GAME=<known profile> python3 dm/ios/tools/build_ldn_trace_probe.py --output <new scratch directory>` builds the same test in an unsigned native iOS app. It writes `Documents/results.json`, `verification.log` and `errors.log`; the report includes exact source hashes and identifies the stubbed event binding. The probe runs no guest game, sends no discovery packets and cannot establish working multiplayer.
