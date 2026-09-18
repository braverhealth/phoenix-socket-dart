# Audit fixes and regression coverage

This document maps the connection, channel, routing, and configuration fixes
to the 15 findings in the September 17, 2026 audit of `1.0.0-alpha` at `791d2ac`.

| Finding | Corrected behavior | Regression coverage |
| --- | --- | --- |
| 1. Connection work outlives close/dispose | Connection generations invalidate queued events and cancel parameter/retry waits; handshake transports and callers are closed together. | `connection_manager_test.dart`: cancellation before connect dispatch, during handshake, parameters, retry, and reentrant callbacks; E2E explicit close during retry. |
| 2. Handshake timeout hangs | Readiness failures enter retry/terminal failure handling without requiring a transport close code. | `connection_manager_test.dart`: timeout failure/retry/late readiness; E2E real stalled handshake. |
| 3. Join timeout prevents recovery | Push reset refreshes completed attempts while preserving retry callbacks and ignoring stale replies. | `channel_lifecycle_test.dart`: timeout then successful retry; E2E delayed first join followed by successful echo. |
| 4. Channel close abandons requests | Separate disposal state makes close idempotent, including before first join; closure settles join, buffered, and sent requests. | `channel_lifecycle_test.dart`: explicit/server close and close before join; E2E server closes pending request. |
| 5. Setup failures escape and strand connect | Parameter/factory failures emit socket errors and follow bounded retry/completion handling. | `connection_manager_test.dart`: rejected provider, throwing factory, concurrent callers, automatic reconnect exhaustion. |
| 6. Leave before join does not close | Both leave branches perform cleanup and invalidate the pending join; an in-flight connected join sends leave with its original join reference so the server subscription is closed too. | `channel_lifecycle_test.dart`: leave during join/offline and close during leave; E2E verifies delayed join acknowledgement, matching leave acknowledgement, and server channel closure. |
| 7. Closed channel retries | Closure cancels the retry timer and retry checks channel lifetime. | `channel_lifecycle_test.dart`: close after rejection; E2E verifies no later join reply. |
| 8. Caught push errors escape again | Channel reply waiters have one owned completion path without an ignored error-propagating cleanup future. | `push_lifecycle_test.dart`: handled disconnect and callback-only cancellation. |
| 9. Topic routes detach or steal replies | Socket topic streams independently filter the broadcast source; channel removal is identity-aware. Reusable router streams retain route registration. | `socket_routing_test.dart`, `stream_router_test.dart`; E2E topic relistening and channel replacement. |
| 10. Push timeouts retain transport waiters | Push uses its channel waiter for reply, timeout, and error completion; no duplicate manager waiter is allocated. | `push_lifecycle_test.dart`: send completion after timeout and zero transport waits; E2E request timeout followed by successful echo. |
| 11. Buffering loses reply mode | Buffered pushes retain whether a reply is expected. | `channel_lifecycle_test.dart`; E2E buffered no-reply request delivered once without a timeout callback. |
| 12. Custom reply-prefix events disappear | Only the exact protocol reply and internal synthetic namespace count as replies. | `events_test.dart`, `channel_lifecycle_test.dart`; E2E `phx_reply_custom`. |
| 13. CI SDK is incompatible | Minimum is Dart 3.4 so WebSocket and mock-generation dependencies resolve together; CI tests Dart 3.4.4 and stable, and builds this checkout's backend. | CI matrix, analysis, dependency resolution, unit/E2E commands. |
| 14. Examples cannot resolve an SDK | All example SDK constraints accept the library's Dart 3 range. | Dart example dependency resolution/analysis; Flutter example dependency resolution/source analysis. |
| 15. Empty retry delays throw | Empty delay lists explicitly mean immediate retries; retry count remains separately configurable. | `socket_options_test.dart`. |

Tests are in [`test/`](../test/); backend fixtures are in
[`example/backend/`](../example/backend/). See the [README](../README.md#testing)
for commands and prerequisites.

The default test command runs in-memory tests. The E2E runner starts the embedded
Phoenix backend on an ephemeral loopback port, disables its administrative
endpoint, and shuts down the process it owns in `finally`. E2E tests also cover
authenticated channel joins, two-client broadcasts, server disconnect/rejoin,
and heartbeat loss through an isolated in-process WebSocket proxy.

The older fixed-port/Toxiproxy suites remain available through the explicit
`legacy` preset. They are not prerequisites for the isolated E2E suite and are
not started by the default unit-test command.

## Initial verification

- All 54 unit/regression tests passed on Dart 3.9.2; all 16 isolated real-backend
  E2E tests passed on Dart 3.9.0. `dart analyze lib test tool` and changed-file
  formatting passed on Dart 3.9.2.
- The Dart example passed dependency resolution and analysis. All three Flutter
  examples passed dependency resolution and source analysis on Flutter 3.44.9
  (informational lints were nonfatal).
- Backend fixture formatting and `git diff --check` passed. The isolated backend
  and proxy were stopped after testing; no existing development service was used.
- Dart 3.3.4 exposed the incompatible code-generation dependency. Dart 3.4 is
  now the declared minimum, with CI jobs for 3.4.4 and stable. The local 3.4.4
  runtime check could not be completed because SDK downloads stalled. Both CI
  test jobs subsequently passed on audit-fix commit `4caecce`, including E2E.
- Legacy fixed-port/Toxiproxy suites were not validated.

## Merge verification

After merging `origin/1.0.0-alpha` at `24bf3f2`, all 101 unit/regression tests
passed on Dart 3.9.0, including the upstream Presence tests and new regressions
covering synchronous leave/close notifications and pending-push settlement.
`dart analyze --fatal-infos lib test tool`, formatting of the manually edited
Dart files, and `git diff --check` passed. No local backend or proxy was started
for this merge; the merged-head E2E validation runs in CI.
