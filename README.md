<p align="center">
  <img src="native/Resources/MacScopeIcon.png" width="128" alt="MacScope icon">
</p>

<h1 align="center">MacScope</h1>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <strong>A lightweight system monitor and maintenance app built exclusively for macOS</strong>
</p>

<p align="center">
  Understand resource usage, manage processes, reclaim disk space, and uninstall apps thoroughly.
</p>

<p align="center">
  <a href="https://github.com/shenmuoso/mac-scope/releases"><strong>Download the latest release</strong></a>
  ·
  <a href="#features">Features</a>
  ·
  <a href="https://github.com/shenmuoso/mac-scope/issues">Report an issue</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.4.13-1677ff" alt="Version 0.4.13">
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/SwiftUI%20%2B%20AppKit-Native-f05138?logo=swift" alt="SwiftUI and AppKit">
  <img src="https://img.shields.io/badge/language-English%20%7C%20简体中文-34c759" alt="App languages: English and Simplified Chinese">
</p>

> [!TIP]
> **0.4.13: native grouped views and display control.** System information, displays, battery, performance, and memory use native grouped forms. Change resolution, HiDPI, and refresh rate, and adjust brightness, contrast, volume, and ICC profiles on supported hardware.

MacScope brings your Mac's essential information together in a clear, native interface. Built with SwiftUI and AppKit, it includes no Electron, embedded browser, or additional runtime. No Terminal, Python, or Homebrew is needed to use the app.

![MacScope 0.4.13 in light mode: live system overview](.github/assets/macscope-overview.png)

![MacScope 0.4.13 in dark mode: display control and HiDPI modes](.github/assets/macscope-displays.png)

## Why MacScope

| | What you get |
| --- | --- |
| **Native throughout** | Standard macOS windows, menus, tables, settings, authorization dialogs, and light and dark appearances |
| **Lightweight** | A small app with no extra runtime or heavyweight web container |
| **Everything together** | CPU, power, temperature, fans, memory, disks, network, processes, and maintenance tools in one app |
| **Transparent actions** | Clear scan results, file paths, progress, and failure reasons; you choose what to delete |
| **Local first** | Monitoring and file analysis run on your Mac; system data and scan results are not uploaded |

<a id="features"></a>

## Features

### Native menu bar monitoring

Keep an eye on your Mac without keeping the main window open.

- Show only a monochrome icon, or display up to three compact live metrics.
- Choose CPU, GPU (Apple Silicon), memory, disk, network, temperature, system power, and charging power, and arrange their order. GPU and power metrics are off by default.
- Upload and download rates appear on separate lines. Fixed metric widths prevent changing values from shifting other menu bar icons.
- Click the icon to view the last minute of activity in the dashboard.
- View top processes sorted by CPU, memory, disk, or network usage.
- Customize dashboard modules and process counts; monitoring continues after the main window closes.
- The dashboard is monochrome by default. Optional Color Mode adds color to charts and live status indicators.
- After the pointer enters the dashboard, leaving it closes the panel after about 0.25 seconds. Turn this off in Settings > Menu Bar.
- Main, settings, and help windows share a continuous translucent sidebar and a solid content background. On macOS 26+, sidebars, the menu bar dashboard, and result dialogs use native Liquid Glass with appearance-aware backgrounds. Choose Glass, Balanced, or Frosted in Settings > Appearance > Liquid Glass; changes apply immediately and are saved automatically.
- Native title bars and gray grouped sections organize detail pages. Information views use SwiftUI grouped forms, while table workspaces share consistent spacing and status bars with fewer borders and dividers.
- Earlier macOS versions use native blur materials. All materials respect Reduce Transparency and Increase Contrast.
- Hide the Dock icon in Settings > Appearance. Windows and settings remain accessible from the menu bar, but the app leaves the app switcher. At least one of the Dock or menu bar entries must remain enabled.
- The Dock icon follows the app's appearance by default, including system changes when using Follow System. Override it with Light or Dark in Settings > Appearance > Dock Icon. Finder icon appearance is controlled by macOS icon style settings.

### Live resource monitoring

Find out what is happening when your Mac gets hot, fans speed up, or the network slows down.

- **CPU:** total, user, and system usage, plus SoC temperature.
- **GPU (Apple Silicon only):** total usage and 60-second history; renderer and tiler usage when available, without administrator access.
- **Memory:** used, total, available, and live utilization.
- **Disk:** data volume capacity, read rate, and write rate.
- **Network:** live download and upload rates.
- **Overview:** circular indicators show current values on the left; combined charts compare system load, disk, and network activity over the last 60 seconds on the right.
- **Status colors:** quickly identify utilization, network speed, and temperature ranges.
- **Refresh controls:** pause, refresh immediately, or choose `0.5`, `1`, `2`, or `5` second intervals.

### Performance, power, and cooling

Compare heavy workloads, temperature changes, and fan behavior in one place.

- View CPU and GPU usage, system power, charging power, adapter input, SoC temperature, and fan speed together.
- Separate 60-second charts show CPU, GPU, power, temperature, and cooling trends.
- Inspect each available fan's current, minimum, and maximum RPM. Fanless hardware and unavailable telemetry are identified explicitly.
- Fan controls are hidden on Macs detected as fanless. Older Intel MacBook Air models with fans retain the controls.
- On supported hardware with verifiable fan targets, enable Maximum Cooling for 15, 30, or 60 minutes through the native macOS administrator authorization dialog.
- Maximum Cooling raises all fans together to their hardware-reported maximum. It does not provide arbitrary RPM control or lower the speed selected by macOS.
- Add system power and charging power to compact menu bar metrics or the dashboard as needed; both are off by default.

### Process monitoring and management

A dedicated process table shows what is consuming resources and lets you take action.

- View process names, PIDs, CPU, memory, disk I/O, network traffic, thread counts, and running time.
- Click column headers to sort in either direction. Precomputed sort values keep large process lists responsive, including memory sorting.
- Distinguish system software and services, installed apps, plug-ins and tools, and other sources; filter by source.
- Group processes by app, compare aggregate CPU, memory, disk, and network usage, and sort child processes within expanded groups.
- Search by process or app name, bundle ID, or PID; choose the top 5, 10, 20, or 50 entries.
- Double-click a process to inspect its last minute of CPU, memory, and I/O activity.
- Quit or force quit a process after confirmation.

### Hardware information and battery health

Inspect hardware, displays, and connections without navigating multiple System Report sections.

- View Mac model, chip, architecture, CPU cores, memory, macOS version, uptime, and thermal state.
- List built-in and external displays, logical and pixel resolutions, and main display status.
- Inspect USB devices, Bluetooth controllers and connected devices, and Wi-Fi interfaces, signal strength, rates, and channels.
- On MacBooks, view charge level, maximum and design capacity, cycle count, battery condition, temperature, voltage, and current.
- Unsupported fields remain unavailable rather than showing estimated readings.

### Display control

- Switch displays in the Hardware group. A single native grouped form organizes the current mode, mode selection, hardware adjustments, and color profiles. Filters stay on one row and modes use pagination.
- Combine logical resolution, HiDPI, refresh type, and refresh rate filters. Rows show resolution, scaling, aspect ratio, and refresh labels; modes matching a built-in notched display are labeled Notch. A 15-second confirmation timer automatically restores the previous mode unless confirmed.
- Include native HiDPI modes missing from the public mode list, even when starting at a lower resolution. Verify actual output after switching and retain the original mode for retry if restoration fails.
- Distinguish ProMotion, other variable refresh modes, and fixed rates using system mode data. Fixed 120 Hz is not labeled ProMotion; fractional rates such as 59.94 Hz retain their precision.
- Adjust raw built-in backlight and supported external displays' brightness, contrast, and volume through DDC/CI. Dragging updates percentages immediately; background writes are coalesced and verified. Failed adjustments revert to the confirmed value, and controls without valid replies remain unavailable.
- Switch installed RGB display ICC profiles or restore the display's system default profile.
- Complete mode enumeration and switching, ProMotion detection, built-in backlight, and Apple Silicon DDC use private system interfaces detected at runtime and may be affected by macOS updates. ICC uses ColorSync; Intel DDC uses IOKit I2C. Displays, cables, and adapters can affect DDC support.

### Ports and downloads

- **Ports:** inspect TCP and UDP listening ports, addresses, PIDs, processes, and owning apps. Filter, copy, open local addresses, or terminate processes.
- **Downloads Cleanup:** categorize installers, archives, duplicate downloads, incomplete downloads, large files, and old files.
- Content hashes verify duplicate downloads, and at least one copy per group is preserved.
- Recommended Selection selects only incomplete downloads, older installers and archives, and older duplicate copies.
- Downloads always move to Trash after confirmation; they are never automatically deleted permanently.

### Startup items

Separate Open at Login items, background tasks, and stale startup configurations without confusing running status with startup permission.

- Read macOS Open at Login items, and add, remove, or locate their apps.
- Scan user and third-party `launchd` tasks, showing permission, running state, triggers, and owning apps.
- Review missing targets, invalid configurations, and entries left by removed apps in Needs Attention before disabling or removing them.
- System items, shared configurations, and uncertain associations are handled conservatively and are not selected for deletion by default.

### Junk scanning and cleanup

See what was found before deciding what to remove.

- Scan user caches, logs, diagnostic reports, and developer files.
- Inspect sizes, paths, and individual items by category, and select items separately.
- Watch the current file and overall progress during cleanup. A compact summary shows completion; a separate results window lists each item's status, path, and failure reason.
- Move caches to Trash or delete them permanently. Trash is the default.
- Failed items retain clear explanations and can be retried after resolving permission issues.

### App uninstallation and leftovers

Review an app and its associated data in one confirmation flow.

- Scan standard app directories and show app status, location, and size.
- Identify bundle IDs, associated data, and other registered copies of an app.
- Analyze related login items, launch agents, and background configurations, distinguishing confirmed, possible, and shared associations.
- Review the app, individual leftover files, and removable startup configurations in a dedicated confirmation view.
- Follow removal paths and live progress. A separate results window gathers successes, failures, and permission actions.
- Removing protected apps from `/Applications` presents the native macOS administrator authorization dialog immediately after confirmation, without requiring an initial failed attempt.
- Confirm that the app itself can be removed before processing its data, avoiding an app left installed with its data deleted.

### Disk and resource tools

Find out where your space is going.

| Tool | Purpose |
| --- | --- |
| **Large Files** | Find files above a chosen size in selected folders and sort them by size |
| **Duplicates** | Verify duplicates by size and content hash, preserving at least one copy per group |
| **Quick Memory Release** | Use native macOS administrator authorization to request reclamation of eligible inactive file caches without closing running apps |

Large file and duplicate scans default to your `Downloads`, `Desktop`, `Documents`, and `Movies` folders. Add or remove scan folders in Settings.

## Common workflows

- **Mac getting hot:** sort by CPU, find consistently busy processes, and inspect their last minute of activity.
- **Memory pressure rising:** sort by memory to identify the main consumers; use Quick Memory Release when needed.
- **Disk running low:** review junk, large files, and duplicates to identify reclaimable space.
- **App leftovers:** review an app's data and other copies before confirming removal.
- **A quick status check:** show CPU, memory, or network speed in the menu bar.
- **Port already in use:** search its number, identify the app, and open its local address or stop the process.
- **Heat or loud fans:** compare CPU, system power, temperature, and fan charts to relate workload to cooling.
- **Stale startup entries:** review login items and background configurations with missing targets in Needs Attention.
- **Messy downloads:** review installers, archives, duplicate downloads, and old files by category.
- **Hardware checks:** inspect chip, memory, displays, wireless connections, and battery health together.

## Download and installation

1. Download the latest `MacScope-*.dmg` from [GitHub Releases](https://github.com/shenmuoso/mac-scope/releases).
2. Open the DMG and drag `MacScope.app` into `Applications`.
3. Launch MacScope from Applications.

> [!IMPORTANT]
> Current releases use an ad-hoc development signature and are not notarized with an Apple Developer ID. Only open packages downloaded from this repository's Releases page. MacScope never asks you to type an administrator password into its own interface.

### Opening MacScope for the first time

If macOS cannot verify the developer or blocks the app:

1. Make sure `MacScope.app` is in Applications and try opening it once.
2. Click Done or dismiss the system alert.
3. Open Apple menu > System Settings > Privacy & Security.
4. Scroll to Security and find the notice about MacScope being blocked.
5. Click Open Anyway and confirm with Touch ID or an administrator password.
6. Click Open in the final confirmation dialog. The same build usually needs no further confirmation.

You can also right-click `MacScope.app` in Finder's Applications folder, choose Open, and confirm Open again. Replacing it with a different ad-hoc signed build may require another confirmation.

## Preferences

Interface preferences are persisted with macOS `UserDefaults`. Login startup and privacy permissions are managed by macOS.

| Category | Options |
| --- | --- |
| **Monitoring** | 0.5/1/2/5-second refresh intervals, top 5/10/20/50 processes, Celsius or Fahrenheit |
| **Menu Bar** | Enable or disable, icon or compact metrics, up to three metrics, power metrics, module order, process sorting and count, Color Mode |
| **Appearance** | System/light/dark, accent colors, Glass/Balanced/Frosted materials, translucent sidebar, Dock icon visibility and appearance |
| **Cleanup** | Cache handling, confirmation, large file and duplicate thresholds, download age ranges, scan folders |
| **Permissions** | Open at login, Full Disk Access settings, and on-demand administrator authorization information |
| **App Language** | English or Simplified Chinese; English is the default |

The system stores preferences at:

```text
~/Library/Preferences/com.shenmuoso.macscope.plist
```

## Privacy, permissions, and safety

- System metrics, process data, and scan results are processed locally and are not uploaded.
- Update checks request only the latest GitHub release metadata. A download entry appears at the bottom of the sidebar when a newer version is available.
- Files move to Trash by default; MacScope never empties Trash automatically.
- Apps, app leftovers, large files, and duplicates always move to Trash rather than being permanently deleted.
- Downloads Cleanup scans only your `Downloads` folder and always shows categories, paths, sizes, and modification dates before cleanup.
- Only rebuildable caches and developer files may be permanently deleted when allowed in Settings.
- Some Library folders require Full Disk Access. Open the relevant system settings from Settings > Permissions.
- Removing protected apps or releasing file caches immediately presents the standard macOS administrator authorization dialog before execution.
- Starting or restoring fan control uses the same macOS dialog. A hash-verified temporary helper runs from `/var/tmp` and is removed afterward; no persistent root service is installed.
- MacScope does not read, receive, or store administrator passwords.
- Scans skip symbolic links and app bundle contents to stay within the selected directory boundaries.

### Enabling Full Disk Access

1. In MacScope, open Settings > Permissions > Open Full Disk Access Settings.
2. Enable the switch next to MacScope in System Settings.
3. If already enabled but access still fails, remove MacScope with the `−` button, then use `+` to add `/Applications/MacScope.app` again.
4. Quit and reopen MacScope.

With ad-hoc signing, replacing a test build can change the app's identity while macOS retains the old permission entry. Removing and adding the app again may be necessary.

## Requirements

- macOS 13 Ventura or later.
- Current GitHub release DMGs target Apple Silicon. Intel Macs can build from source with a compatible Swift toolchain.
- The native app does not require Python, Textual, Homebrew, or another runtime.
- Temperature readings depend on the IOHID sensors exposed by your Mac and macOS. Other monitoring features continue working when temperature is unavailable.

## FAQ

### Why are CPU, disk, or network rates initially zero?

Rates are calculated from the difference between two samples. Wait one refresh interval for live values.

### Why do some files require Full Disk Access?

macOS protects some user Library folders. MacScope reports the permission issue without bypassing system protections; grant access and rescan.

If the switch is already on but scans remain restricted, remove the permission entry, add `/Applications/MacScope.app` again, and restart MacScope.

### Can MacScope see my administrator password?

No. macOS provides the password dialog and handles authentication. MacScope receives only the authorization result.

### Why is temperature unavailable?

Sensors vary between Macs and macOS releases. CPU, memory, disk, network, and process monitoring are unaffected.

### Why are power or fan readings unavailable?

MacScope shows only telemetry actually exposed by your hardware and macOS. It does not substitute estimates when the Mac is fanless, power is disconnected, or a sensor reading is unavailable.

### Why is Maximum Cooling unavailable?

Control is enabled only when MacScope can read fan count, hardware maximum RPM, and target RPM, then verify writes after authorization. Fanless Macs hide the controls; unknown SMC formats or rejected writes leave controls read-only. This experimental feature uses private Apple SMC interfaces and may be unavailable on some models or after macOS updates.

## Build from source

Requires macOS 13+, Xcode Command Line Tools, and preferably a Swift 6 toolchain.

```bash
git clone git@github.com:shenmuoso/mac-scope.git
cd mac-scope
native/scripts/run_app.sh debug
```

Build only the native app:

```bash
native/scripts/build_app.sh release
```

Build a release DMG:

```bash
native/scripts/build_dmg.sh release
```

Default output:

```text
native/build/MacScope-0.4.13.dmg
```

The earlier Python/Textual terminal version remains in the repository for compatibility and historical reference. It is not a runtime dependency of the native app.

## Project and feedback

- [Downloads and release history](https://github.com/shenmuoso/mac-scope/releases)
- [Report bugs or request features](https://github.com/shenmuoso/mac-scope/issues)
- [Project homepage](https://github.com/shenmuoso/mac-scope)
- [Author](https://github.com/shenmuoso)
