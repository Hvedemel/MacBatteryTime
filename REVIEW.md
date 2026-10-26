# BatteryTime 4.1 review and fixes

Reviewed every Swift source, test source, shell script, package manifest, Xcode project/shared scheme, plist, and documentation file in the supplied 4.0 source. Checked the ICNS container and every PNG representation. Source was extracted from the user-specified ZIP; the original archive/application was preserved. Attached documentation was treated as project context, not an independent instruction to execute commands.

## Bugs and correctness fixes

1. **Abrupt system-time changes.** Version 4.0 published a changed macOS estimate directly. A compiled reproduction showed 14,400 seconds becoming 86,400 seconds in 30 seconds. System time now passes through a two-minute consumption-rate filter, with tests for upward/downward jumps. Missing signals are never replaced by a cached system time.
2. **Slow adaptation after reduced load or idle.** The old recent regression needed another two percentage points of discharge, often falling back to an older high-load slope. The new recent window adapts after a smaller measured change once learning is established, favors recent rates when workload changes, bounds rates during a rounded-percent plateau, and expires old observed consumption after ten flat minutes. A compiled 4.0 reproduction still produced a measured consumption rate after twelve flat minutes. This is now covered by an idle-expiry test.
3. **Sampling bias from event bursts.** Repeated notifications/Refresh clicks added unevenly dense observations to regression. Learning samples are now spaced by at least 15 seconds, bounded at 128 entries, and power-notification chatter produces one immediate and one trailing read rather than an unbounded burst.
4. **Dropped refresh requests and stale read results.** A request during a native read was discarded. The monitor now coalesces and retains that request and discards the superseded result. Read generations also reject results canceled by stop, sleep, mode changes, or clearing history.
5. **Main-actor notification risk.** Selector observers did not explicitly establish a delivery queue before entering actor-isolated methods. All native power/sleep/wake observers now use the main queue with explicit token teardown. A background-posting test runs the actual relay and lifecycle code, so a runtime actor violation would fail the test process.
6. **Startup/UI blocking and write ordering.** History loading previously decoded/pruned up to 2 MB synchronously in model initialization. It now runs in the persistence actor and merges safely with newly received samples. Writes use revisions rather than dates, so a backwards clock cannot cause newer data to be ignored. Stale write completions cannot overwrite current error state, and failed saves are marked dirty for retry. Clear-versus-load and shutdown races are handled.
7. **Stale/inconsistent menu time.** Menu time did not share view freshness checks, and tooltips used original rather than decremented duration. A single tested presentation function now hides stale/expired/future-dated estimates, suppresses discharge time on external power, and refreshes freshness even while a read is pending. Views use real current time rather than a prior timeline entry that could clip the newest chart point.
8. **Unavailable battery mistaken for a desktop.** Missing/malformed source descriptions now yield Unavailable instead of claiming there is no battery. Missing capacities remain unavailable; Boolean NSNumber values cannot become 1%/100% readings, and contradictory battery/charging fields yield Unknown power state. Per-source minutes/global seconds and sentinel handling have direct native-decoder tests.
9. **Unsafe numeric conversions.** Nonfinite/oversized time inputs could trap converting to Int; nonfinite timestamps or extreme capacity values could also reach formatting. Validation and safe formatting now reject those values. Invalid data never becomes a fabricated measurement.
10. **Notification preference races.** An outstanding permission request could re-enable alerts after a later off choice. Request revisions now ensure the latest choice wins; queued alert work is guarded and settings queries are deduplicated. Real notification delivery/permission UI was not changed for testing.
11. **Window lifetime/positioning.** Closed hosting trees were retained with charts/timelines, and centering could override a restored frame. Closed windows release their content and are recreated on demand; saved positioning is restored before falling back to centering.
12. **Defensive lifecycle/input handling.** Invalid refresh intervals are normalized. Wake after stop cannot restart monitoring; delayed power work is canceled. Ordinary additional copies activate an existing instance in the current user's session before initializing a second GUI. The icon generator now reports usage with exit 2 rather than indexing a missing argument.

## Build and “damaged or incomplete” investigation

The supplied 4.0 bundle's executable, plist and local signature were valid; its native diagnostics ran. Therefore the historical launch message cannot honestly be attributed to a reproduced missing executable in that archive.

However, the old script mainly checked plist syntax and slice existence. It could sign a plist whose executable name disagreed with the generated executable, inherit restrictive resource/signature permissions, permit concurrent replacement, and remove the only backup if rollback itself failed. The new build:

- Checks executable metadata, app type, identifier, deployment metadata, icon, actual Mach-O executable types, every requested architecture, and strict signatures across all slices.
- Sets readable bundle/resource/signature permissions explicitly, including resources created by codesign under `umask 077`.
- Compiles the real source before reporting success, signs with the hardened-runtime option, runs native diagnostics, validates the staged bundle, publishes on the same volume, and validates again.
- Uses a destination lock, cleans staging/locks after success/failure, restores the previous app after a publication failure, and preserves the backup directory if restoration cannot complete.
- Rejects symlink output paths and missing arguments, records compiler/validation errors, and never publishes a half-built result after a compiler failure.

The failure suite corrupts copies of the real app and injects real compiler errors and publication failures into isolated, actually compiled Swift packaging fixtures. Successful rollback and no-incomplete-output behavior were exercised. The current agent shell's GUI launch restrictions remain separate from bundle validity; normal macOS launching was tested through the native UI tool.

Gatekeeper assessment rejected the local ad-hoc-signed build. That is consistent with having no Developer ID/notarization and does **not** mean code-signature integrity verification failed. A trusted downloaded build may still need Apple's supported first-open approval, or the user can compile locally. Security protections were not disabled and quarantine attributes were not removed. Public distribution still needs the owner's Developer ID signing/notarization.

## Performance changes

- No new runtime dependencies and no CPU/GPU polling. Workload adaptation uses battery observations and macOS's signal.
- Single tolerant polling timer, invalidated during sleep/stop; a short-lived trailing task exists only during notification bursts and is canceled on session reset/shutdown.
- No extra x/y regression arrays; samples capped and time-spaced.
- No full-history sort on each normal append. History remains capped at 24 hours/3,000 readings, with background atomic writes only when dirty.
- Charts render at most 240 actual observations per chart, preserving first/last/extreme observations while hover queries retain full history.
- Status symbols are cached and identical presentations skipped; repeated notification-settings queries are avoided.
- Closing a window releases its hosting hierarchy instead of retaining its chart/timeline content.

These are structural reductions backed by bounds/lifecycle tests. No claim of a specific percentage improvement in battery runtime or memory is made. See TESTING.md for actual process measurements and hardware limits.
