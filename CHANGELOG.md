# BatteryTime 4.0 — rebuild notes

## Audit of all original files

The supplied archive contained `main.swift` (a menu-only AppKit prototype), `Byg BatteryTime.command` (a local compiler/bundle script), and `README.txt`. All three were inspected. The original Swift source compiles under this Mac's Swift 6 compiler after supplying a writable compiler module cache; no original compiler error was reproduced. The rewrite retains the correct idea of creating the delegate on the main actor and gives it an explicit lifetime spanning `NSApplication.run()`.

Issues corrected or replaced:

- Missing/invalid capacity values were silently converted into a plausible 0% reading. Invalid data now produces an unavailable state.
- The old estimator used only the oldest/newest integer percentages over as much as an hour. It did not smooth workload changes, persist history, or explicitly reset around sleep. It has been replaced by windowed regression, time-based smoothing, corroborating system estimates, explicit session boundaries, and bounded persistence.
- External power was presented as proof the battery wasn't discharging. The new UI distinguishes charging, externally powered with charging managed/paused, battery operation, and unknown source information.
- No dashboard, popover, charts, native settings, notifications, login registration, cycle/health reporting, or application icon existed. These have been implemented.
- The old script built only the compiler's default architecture and targeted macOS 12. The replacement builds a verified universal binary with a macOS 13 deployment target.
- The old script removed the existing destination before copying the new bundle, so a failed copy could lose the previous app. The new script stages on the destination volume, validates before replacement, and rolls back if the final move fails.
- There was no Xcode project or test suite. Both are provided, together with a command-line regression runner that works without XCTest.

## Concurrency and lifecycle

The app delegate, UI model, windows, status item, settings, and notifications state are main-actor isolated. The IOKit callback is registered on the main run loop and crosses to that actor explicitly. Utility-priority snapshot reads and serialized history writes avoid blocking UI work. Timer and run-loop resources are torn down, in-flight reads are canceled, sleep starts a new estimation session, and termination waits for the final history write. All app sources are compiled in Swift 6 mode with complete concurrency checking and warnings treated as errors.

## Scope

No private battery-control API, SMC access, launch agent workaround, background daemon, or macOS security bypass is included. Health and physical capacity fields depend on public data supplied by the hardware/OS. A valid universal build does not substitute for a physical Intel or macOS 13 runtime test; the actual test limits are recorded in `TESTING.md`.
