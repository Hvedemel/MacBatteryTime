# Verification of the delivered build

Performed on 25–26 October 2026, Europe/Copenhagen, on an Apple Silicon Mac running macOS 27.0. Tools: Apple Swift 6.4 and macOS SDK 27.0 from Command Line Tools. Full Xcode and Rosetta were not installed.

## Completed checks

| Check | Result |
| --- | --- |
| Original archive audit | All three original files inspected; original Swift source also compiled after setting a writable module cache. |
| Swift 6 compile | All app and core sources compile with complete concurrency checking and warnings treated as errors, for arm64 and x86_64. |
| Universal app | Two executable Mach-O slices; each declares macOS 13.0 as its minimum OS. |
| Bundle validation | Valid Info.plist; matching executable name; executable permission; icon resource; package metadata; strict code-signature validation. |
| Core regression suite | **34 tests passed, 0 failures**, run as real compiled Swift code through the included Foundation runner. |
| Real hardware readings | Live IOKit percentage, battery operation, time-to-empty, Low Power Mode state, and cycle count read successfully. A paired check matched `pmset`: 96% and 7h 04m; cycle count was 494. Later GUI readings updated as the battery discharged. |
| Real power transition | Saved history recorded battery → plugged in → charging during the session, with no discharge estimate on external power. The final dashboard and popover displayed Charging at 93%, matching a live `pmset` check. |
| Dashboard | Opened a real native window, inspected accessibility state and actual rendered dark appearance, verified percentage, remaining time, estimated empty time, real history, and settings navigation. |
| Charts | Changed among 1-, 6-, and 24-hour ranges; verified selection and chart data changed; scrolled through both charts and footer. |
| Menu popover | Opened the native status-item popover using the app's ⌘B command, which calls the same action as the status item. Verified its percentage, state, time, visualization, refresh/settings/quit controls, and used Open Dashboard successfully. |
| Settings | Opened the real native settings window, inspected optional-feature states, changed interval from 30 seconds to 2 minutes and restored 30 seconds; toggled menu time off and back on. |
| Clean termination | Quit through the app; termination completed and history was saved. |
| Persistence/relaunch | Read saved history after quit, relaunched the app, and verified earlier real chart readings remained. Learning starts a new session on relaunch. |
| Failure safety | Injected deliberately invalid Swift in an isolated test copy. Build failed with compiler diagnostics, preserved the previous app marker, and removed all incomplete staging bundles. |
| Xcode project | Project property-list syntax validated; shared scheme and source/resource references checked. The app's exact source files were compiled successfully with the command-line toolchain. |
| Shell scripts | Shell syntax validated; universal build, validation, expected compiler failure, and launch path exercised. |
| Idle spot check | An idle sample showed 0.0% CPU and 33,760 KiB resident memory. This is one observation, not a sustained performance benchmark. |

The regression suite covers rate estimation, system estimates, blended/conflicting signals, percentage quantization, workload adaptation, invalid/missing values, charging/external-power/unknown-source transitions, simulated sleep gaps, explicit wake resets, battery replacement, Low Power Mode changes, out-of-order samples, slower refresh, countdowns, notification threshold deduplication/rearming, and persistent-history bounds/corruption.

## Limits and checks not claimed

- **No physical Intel or macOS 13 runtime test.** Both architectures compile and link and have the correct deployment target. Rosetta was unavailable. The installed toolchain emits an Intel linker warning that its optional `libswiftCompatibilityPacks.a` has only arm64/arm64e slices; the linker still produced a verified x86_64 executable with no undefined-symbol build failure. Validate the Release build on an actual Intel Mac before public distribution, preferably using a complete Xcode toolchain.
- **No Xcode GUI build or XCTest execution here.** Full Xcode is absent. The working command-line build and standalone regression runner were executed; the Xcode project is supplied and syntax validated, but an `xcodebuild` run cannot be claimed.
- **No physical sleep/wake, battery replacement, or desktop-Mac test, and no repeated charger stress test.** A live charger connection and resulting external-power/charging states were observed and verified; additional transitions are covered in the estimation tests. The app registers native power/sleep/wake notifications. The user's live Mac was not put to sleep or otherwise disrupted for testing.
- **No end-to-end notification delivery or next-login test.** The optional settings were left off. The notification-threshold logic was tested. Login status correctly displayed that the build should be moved to Applications; actual registration, user approval, and a login cycle remain to be tested after installation.
- **Only the current dark system appearance was visually inspected.** Light-mode styling is implemented through native adaptive colors/materials; a separate light-mode visual run is not claimed.
- **Health/capacity were unavailable through the selected public power-source fields on this Mac.** The app displayed Unavailable and omitted physical-capacity details. It did not substitute guessed health values or turn a percentage capacity into mAh.
- **Long-term runtime accuracy is not yet field calibrated.** Synthetic discharge/workload tests passed and real readings updated. A full battery discharge, thermal variation, and multi-day energy/memory profiles were not performed.
- **Local signing only.** The included app is ad-hoc signed and verified, not Developer ID signed or notarized. See README for safe local building and Apple's supported first-open process.

## Environment notes

The agent's restricted shell cannot perform normal Launch Services app registration: its initial `open` returned an OS launch error, and a direct GUI-process launch inside that sandbox aborted in Apple's registration code. Launching the same verified app through normal macOS Launch Services outside the restricted shell succeeded, and real UI and quit/relaunch checks then passed. This does not require changing macOS security settings. The delivered build script uses standard `open` when run normally in Terminal.

This SDK also exports an `@State` macro whose implementation is absent from Command Line Tools. The source explicitly aliases the existing SwiftUI state property-wrapper type, preserving compatibility without depending on that macro plugin. The test runner likewise avoids a dependency on XCTest for Command Line Tools installations.

## Suggested physical follow-up

After installing, keep BatteryTime running while unplugged for at least five minutes and two percentage points of discharge. Connect and disconnect the charger, sleep and wake the Mac, and observe that learning resets without a stale countdown. Enable notifications only if wanted, verify macOS permission and one alert per threshold, and approve launch at login if macOS requests it. Repeat on an Intel Mac and macOS 13 before making a public release.
