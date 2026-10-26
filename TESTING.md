# BatteryTime 4.1 verification

Performed 26 October 2026 on an Apple Silicon Mac running macOS 27.0, using Apple Swift 6.4 and macOS SDK 27.0 from Command Line Tools. Full Xcode, Rosetta, physical Intel hardware, and a macOS 13 machine were unavailable.

## Automated results

**101 checks passed, zero failures:**

- **52 core regression tests**, discovered from the shared XCTest source and executed as compiled Swift through the Foundation runner. Covers real timed discharge/rounded percentages, changing load, idle, system-time smoothing, invalid/missing signals, zero/full/low battery, charging, external/unknown power, gaps, battery replacement, low-power changes, backwards timestamps, countdown freshness, formatting overflow, notification thresholds, chart bounds/extrema, persistence corruption, and file limits.
- **25 native app scenarios**, compiling the production reader, menu presenter, monitor, and persistence actor. Covers native IOKit reads; typed/missing/malformed source data; time units/fallback; charging/full/inconsistent state; menu formatting and stale time; request coalescing; canceled/late reads; clear/read races; simulated sleep/wake and mode changes; startup history merge and final write; revision ordering despite clock rollback; write/read failures; interval validation; notification-approval/off races; permission errors; freshness while a read is pending; bounded notification bursts; cancellation of trailing events; and release of a stopped monitor. A background thread also posts through the actual main-queue observer relay and exercises sleep/wake handlers without putting the Mac to sleep.
- **24 build/bundle checks**, validating the real app and using isolated corruption/fault injection. Covers missing/corrupt/non-executable binaries, mismatched metadata, invalid deployment metadata, missing icons, broken signatures, bad CLI arguments, symlink destinations, destination locking, actual Swift compiler failures, no incomplete published output, preservation of the previous app, failed final moves, failed post-publication validation and rollback, cleanup, and restrictive umask including signature-resource permissions. Small genuinely compiled Swift fixtures test packaging mechanics; the delivered GUI is compiled independently from the complete source.

Logs are included under `Verification/`. Test history is confined to temporary directories; dedicated test preference domains are cleaned. Actual notification/login preferences and the user's recorded history were not cleared for testing.

## Build, static, and native runtime checks

- Complete app compiled for **arm64 and x86_64**, with Swift 6, complete concurrency checking, and compiler warnings treated as errors. Both Mach-O executable slices declare **macOS 13.0**.
- Validated the actual executable type, plist fields, icon, executable/resource permissions, and strict signatures for all architectures. Native `--diagnostics` was executed before publication; the bundle was checked again after publication.
- Validated all shell scripts with `bash -n`, Xcode project source/resource references and plist syntax, shared-scheme XML, every PNG representation, and the ICNS container. Icon generation ran successfully; a missing argument returned usage/exit 2 rather than crashing.
- Ran a compiled reproduction against 4.0: a four-hour macOS signal changed directly to 24 hours after 30 seconds, and an observed drain estimate persisted after twelve minutes at unchanged charge. New tests exercise the corrected cases.
- Launched the reviewed real `.app` through macOS, inspected the dashboard, refreshed readings, opened Settings and confirmed version 4.1, closed/recreated windows, opened the menu popover, and verified live remaining time. Actual charging was also observed during the review; the interface cleared the discharge countdown and displayed Charging. Real cycle count and missing-health handling remained intact.
- Quit through the real app and verified it terminated cleanly; startup restored earlier recorded history. The original interface and useful functionality remain present.

## Signing and historical launch error

The supplied 4.0 app had a valid executable, matching metadata, and an intact local signature; native diagnostics ran. A missing executable in that supplied archive was not reproduced as the cause of the historical “damaged or incomplete” message.

The new script checks and rejects the concrete malformed-bundle cases above and retains/rolls back the previous complete app on tested failures. It also normalizes permissions, including files created by codesign, instead of relying on the caller's umask.

The build is **ad-hoc signed with hardened runtime, not Developer ID signed or notarized**. Strict signature-integrity validation passes, while Gatekeeper assessment returns **rejected**, consistent with the absence of a trusted distribution signature/notarization. It was launched normally on this Mac; that does not establish trust for downloaded copies on other Macs. README links Apple's supported first-open process and provides local source-build instructions. Gatekeeper/SIP were not disabled and quarantine attributes were not stripped.

The agent's restricted shell has separate GUI-registration restrictions, so real GUI launching/inspection used the native UI tool. Command-line diagnostics, compilation, and bundle verification run without opening Xcode.

## Remaining limitations

- **Intel and macOS 13 runtime are untested.** Both slices compile/link and have the correct minimum OS. This toolchain warns that `libswiftCompatibilityPacks.a` lacks x86_64; the warning is preserved in the compiler log. No direct undefined pack-helper references were found by an Intel `nm` inspection, but that does not replace an Intel/macOS 13 run. Use a complete Xcode toolchain and physical supported Macs before public distribution.
- **Full Xcode build/XCTest UI execution was unavailable.** The app's exact source compiled through swiftc; the project/scheme references were validated. Core XCTest is available through Package.swift in full Xcode; native scenarios use the supplied CLI runner.
- **Physical sleep/wake, battery replacement, desktop-Mac operation, and repeated charger stress were not performed.** Those state transitions are covered by injected native/core scenarios. A live charging state and a real discharging state were observed without forcing changes to the user's hardware or energy settings.
- **Actual notification delivery and next-login launching remain untested.** Existing notification/login choices were preserved; no fabricated low-battery reading was used to send a real alert. Permission-race/error logic and threshold behavior were executed with controlled inputs.
- **Light appearance and accessibility variations were not exhaustively inspected.** The current native appearance was reviewed; adaptive styling and reduced-motion behavior remain implemented.
- **No full discharge calibration or multi-day CPU/GPU/energy/leak benchmark.** Synthetic traces establish bounded smoothing/adaptation behavior, not guaranteed real-world remaining-time accuracy. Battery age, temperature, voltage, macOS reserves, and sudden workload changes still affect runtime. Any process spot measurements are not a long-term performance guarantee.
- **Power-source health/capacity fields are hardware dependent.** This Mac did not supply consistent health/capacity data through the selected public API; Unavailable/omitted fields remain intentional. Cycle count was reported.

REVIEW.md lists the complete findings and performance changes. The final ZIP is checked after extraction for signature integrity, executable permissions, and source/binary equality; no compiler caches or test fixture apps are included.
