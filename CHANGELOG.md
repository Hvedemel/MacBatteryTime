# BatteryTime 4.1

A correctness, lifecycle, performance, and packaging update to the supplied 4.0 source. The dashboard, menu popover, charts, settings, notifications, launch-at-login integration, and optional hardware fields remain available. No runtime dependency or interface redesign was added.

- Filter macOS time signals as consumption rates, improve adaptation to lower/high workloads, prevent event bursts from biasing regression, expire stale observed drain at idle, and reset on backwards timestamps.
- Retain refresh requests during an in-flight read; reject results canceled by stop, sleep, history clearing, or power-mode changes. Bound power-notification chatter with one trailing read.
- Route native power/sleep/wake notifications explicitly to the main queue; clean up observer tokens and delayed work during shutdown.
- Load history outside the main actor; use monotonic revisions for write ordering and a monotonic clock for write cadence. Append incrementally and limit chart rendering to real extrema/endpoints.
- Apply consistent freshness rules to the dashboard and status item; use current time for countdowns and chart domains. Cache status icons and release closed window hosting views.
- Prevent pending notification authorization from undoing a later off choice; deduplicate settings queries and guard queued alerts.
- Distinguish unavailable source descriptors from absent batteries; reject Boolean charge values, contradictory power states, invalid timestamps, and unsafe numeric formatting/capacity values.
- Validate complete bundles before and after publication, run the native executable, normalize signature/resource permissions, lock concurrent builds, and preserve previous apps on failure.
- Retain the correct main-actor delegate lifetime, preserve saved window positioning, guard ordinary duplicate instances within the user's session, and make icon generation reject a missing argument cleanly.

The original 4.0 ZIP and app remain unchanged. See REVIEW.md and TESTING.md for findings, measured results, and unperformed hardware checks.
