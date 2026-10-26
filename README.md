# BatteryTime 4.1

A native, local-only battery dashboard and menu bar app for macOS 13 or later. Built with SwiftUI, AppKit, Swift Charts, and public IOKit APIs. Supports Apple Silicon and Intel Macs.

## Open the completed app

The delivery includes a universal `BatteryTime.app`. Move it to `/Applications` or your personal `~/Applications` folder, then open it. BatteryTime stays in the menu bar when you close its dashboard. Click its battery item to see the popover, reopen the dashboard, open Settings, or quit. Reopening the app in Finder also opens its dashboard.

Keyboard shortcuts while BatteryTime is active: **⌘1** opens the dashboard, **⌘B** opens the battery popover, **⌘,** opens Settings, and **⌘Q** quits.

The app is locally ad-hoc signed. It is not Developer ID signed or notarized for internet distribution. If macOS blocks a downloaded copy, build from the included source on your own Mac using the steps below. If you have verified and trust a downloaded copy, use Apple's supported **System Settings → Privacy & Security → Open Anyway** workflow if macOS offers it. Never disable Gatekeeper or System Integrity Protection, and do not remove quarantine attributes to bypass the warning. Public distribution requires your own Developer ID signature and Apple notarization.

## Build without Xcode

You need a Mac with Swift 6 tools (Xcode 16 or later, or compatible Apple Command Line Tools) and a macOS SDK. The app's deployment target is macOS 13; the machine used to compile must support your selected tools. No third-party packages or network downloads are needed.

1. If tools are missing, run `xcode-select --install` in Terminal and finish Apple's installer.
2. Unzip the source into a regular writable folder.
3. Double-click **Build BatteryTime.command**, or run:

   ```sh
   cd /path/to/BatteryTime
   ./build.sh
   ```

The script compiles both `arm64` and `x86_64`, creates `build/BatteryTime.app`, validates metadata, Mach-O executable types, architectures, macOS deployment targets, icon, permissions, and every architecture's code signature, and runs the native executable's diagnostics before opening the app. A destination lock prevents overlapping builds. Existing apps are preserved until validation succeeds, and failed publication restores the previous bundle. Source, build, and signature resources receive normal readable/executable permissions even under a restrictive umask. The full error log is `.build/build.log`.

`BATTERYTIME_BUILD_CACHE=/absolute/writable/path` optionally places all compiler/test intermediates outside the source folder. No developer cache is included in the delivered archive.

Options:

```sh
./build.sh --no-open
./build.sh --arch native
./build.sh --output /absolute/path/BatteryTime.app
./install.sh                       # builds into ~/Applications and opens the app
./install.sh --no-open             # builds and installs without opening
```

Quit a running old version before replacing it. To choose a different installed developer toolchain, use `xcode-select` as documented by Apple. The script gives Swift an explicit writable module cache, including on machines whose default compiler cache is restricted.

## Build in Xcode

Open `BatteryTime.xcodeproj`, select the shared **BatteryTime** scheme, and choose **My Mac**. Build and run. Debug builds use the local architecture; Release builds use both standard Mac architectures. The project uses local ad-hoc signing and has no team or paid developer account dependency. Change signing to your own Developer ID configuration when preparing a notarized release.

The included Swift Package contains the independent `BatteryCore` library and its XCTest suite. Open `Package.swift` in full Xcode to run those tests. The app itself is built from the Xcode project or `build.sh`.

## Features

- Large battery percentage, animated battery visualization, status, estimated remaining hours and minutes, and the estimated time the battery reaches empty.
- Automatically updating menu bar percentage/time and a native transient popover.
- Dashboard with battery-level history and recorded remaining-time estimates; selectable 1-, 6-, and 24-hour ranges and chart hover values.
- System light/dark appearance, system fonts, SF Symbols, native materials, and reduced-motion support.
- Optional notifications at 20%, 10%, and 5%, with macOS permission requested only when you enable alerts.
- Native Settings with 15-, 30-, 60-, or 120-second refresh, menu-bar time visibility, startup dashboard preference, history clearing, and launch at login.
- Low Power Mode detection and optional macOS-reported battery health, cycle count, and consistent capacity information.
- Safe states for desktop Macs, missing readings, unknown power sources, charging, and externally powered but paused charging.

Launch at login uses `SMAppService.mainApp`. It is off unless you enable it. The toggle reads the actual system registration status, reports errors, and offers Login Items settings when macOS requires approval. Move the app to its permanent Applications location before enabling it.

## How estimation works

Battery percentage by itself is never treated as a time estimate. While discharging, BatteryTime keeps up to 30 minutes of contiguous samples. A measured rate requires at least five minutes of observations, four samples, and two percentage points of actual drain, to limit noise from rounded percentages.

Least-squares discharge slopes from the last 8 and 30 minutes are combined, favoring recent activity more strongly when consumption changes. After initial learning, a recent slope can use a smaller observed drop so a change to light usage doesn't have to wait for another two points of drain. Observations are spaced by at least 15 seconds so rapid events or repeated Refresh clicks don't bias the regression. A two-minute time-based exponential filter smooths measured rates consistently at all refresh intervals. The current charge is divided by that rate.

A valid per-battery macOS time-to-empty reading (minutes converted to seconds), or the global time API (seconds) if needed, supplies an initial signal. System estimates are also filtered in consumption-rate space, preventing an immediate jump from four hours to 24 hours when the system signal changes. When system and observed estimates broadly agree they are blended with 80% weight on observed use; grossly contradictory system signals are excluded after learning.

A long plateau in a rounded percentage limits the rate that can reasonably be inferred; it does not establish zero consumption. After ten minutes without measurable drain the old observed rate expires. The app then uses a current system signal or displays Calculating… until new evidence is available. CPU/GPU workload changes are detected through battery drain and the system signal, without extra CPU/GPU polling.
The estimator resets on external power, a battery identity change, a significant upward capacity correction, Low Power Mode changes, sleep/wake, missing data, and long sampling gaps. Saved history is kept for charts; a new process starts fresh learning rather than assuming the Mac's activity while BatteryTime was closed. Nonmonotonic timestamps begin a new learning session rather than reusing an estimate dated in the future. Unknown, zero, negative, nonfinite, and implausibly long time signals are rejected. With insufficient signals, the app displays **Calculating…**.

Time is explicitly an estimate. Workload, temperature, battery aging, and macOS shutdown reserves affect real runtime; the empty time is not a promise. The visible countdown updates every minute, and the underlying measurement refresh defaults to 30 seconds. The first power-source notification refreshes immediately; chatter within two seconds is combined into one trailing read. A refresh arriving during an in-flight read is retained, and superseded results are discarded. Canceled reads cannot repopulate a cleared session or resurrect pre-sleep/pre-mode-change estimates.

## Data, API scope, and performance

BatteryTime does not use a server, analytics, shell battery queries, private SMC APIs, or writable battery-management interfaces. It never changes charging or energy policy. It reads `IOPowerSources` and documented `IOPMPowerSource` registry keys, releasing all owned IOKit/CF objects. Hardware-dependent fields are optional.

macOS often reports current/max capacity in percentage units. These values are never labeled mAh or compared with a physical design capacity. The app shows a capacity ratio only when macOS supplies consistent physical-capacity-scale values; it labels the units as reported. It does not fabricate a health percentage when this information is missing. Cycle count is read from the documented registry key if available.

History lives at `~/Library/Application Support/BatteryTime/history.json`, capped at 24 hours and 3,000 samples. Loading and writes run off the main actor. Normal dirty-history writes occur at most once per minute; explicit clearing, sleep, and final shutdown can flush immediately. Writes are atomic and ordered by revisions, so clock changes cannot suppress a newer write. The final write is awaited when quitting. New samples use an incremental bounded append instead of sorting the full history on every refresh. Charts retain all stored history while drawing at most 240 actual first/last/extreme observations per chart; hover values continue to use the full selected history. Settings are stored in the app's UserDefaults domain, `dk.batterytime.menubar`. No battery serial number is read or stored. The transient registry identity helps detect hardware changes and is not a personal identifier.

One tolerant sampling timer runs while awake, and it is invalidated during sleep and shutdown. IOKit reads run at utility priority outside the main actor. Visible charts/countdowns use a minute timeline; the dashboard and popover do not add battery polling timers. Closed windows release their SwiftUI hosting trees. Status symbols are cached, unchanged status presentations are skipped, and notification-settings queries are deduplicated. Notification callbacks are explicitly delivered on the main queue before accessing actor-isolated state. History and estimator storage are bounded.

## Tests and diagnostics

```sh
./scripts/test.sh
./scripts/test-build.sh ../BatteryTime.app       # packaged app alongside Source/
./scripts/validate-bundle.sh ../BatteryTime.app arm64 x86_64
../BatteryTime.app/Contents/MacOS/BatteryTime --diagnostics
```

After building to the default folder, substitute `./build/BatteryTime.app` for `../BatteryTime.app`.

`test.sh` discovers every core regression method from the shared XCTest source and executes it through a Foundation-only runner; it also compiles and runs native IOKit decoding, menu presentation, actor/lifecycle, persistence, event, and permission-race scenarios. Tests use private temporary history and dedicated preference suites and do not change the user's battery history or notification/login preferences. Full Xcode can also run the core XCTest suite through `Package.swift`; the app's Xcode scheme remains a build/run scheme.

`test-build.sh` checks the real bundle, then confines destructive corruption and rollback tests to a private temporary directory. Small **actually compiled** Swift fixtures exercise packaging failures without repeatedly rebuilding the entire GUI. It tests missing/corrupted executables, metadata, signature tampering, permissions, real compiler failures, build locking, publication rollback, and restrictive umasks. These packaging fixtures are never delivered as the application.

Diagnostics print one real IOKit snapshot as JSON and exit without starting the GUI, registering login/notification settings, or writing history. Missing fields are omitted. `--background` starts the menu bar app without showing the startup dashboard.

See `TESTING.md` for actual test counts, runtime checks, exact environment limits, and signing assessment. `REVIEW.md` records the bugs fixed, performance changes, and the investigation into “damaged or incomplete” launch errors. `CHANGELOG.md` summarizes this release.

## Icon source

`Resources/AppIcon.icns` contains the original application icon at standard and Retina sizes. `Resources/AppIcon.png` and the complete `.iconset` are included. `scripts/GenerateIcon.swift` reproduces the artwork and ICNS container. The final ICNS container embeds PNG representations and requires no asset compiler at build time.

## Apple references

- [Power-source descriptions and optional keys](https://developer.apple.com/documentation/iokit/1523867-iopsgetpowersourcedescription)
- [System time-remaining units and sentinel values](https://developer.apple.com/documentation/iokit/1523835-iopsgettimeremainingestimate)
- [Registering a login service](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29)
- [Safely opening apps and the Open Anyway workflow](https://support.apple.com/en-us/102445)
