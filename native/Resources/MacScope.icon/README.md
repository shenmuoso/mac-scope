# MacScope Icon

The icon combines a glass processor silhouette, a blue core, and a single white activity signal to represent system performance monitoring. The default background is a pale neutral; Icon Composer supplies the dark rendition, Liquid Glass material, lighting, and platform mask.

The SVGs contain flat geometry only. Groups in `icon.json` are ordered front to back: signal, core, processor. Keep these layers separate so the system can render their overlapping glass surfaces. The menu bar uses a monochrome version of the processor and activity signal for legibility at 16 points.

Open `MacScope.icon` in Xcode 27 Icon Composer to edit the design. Run `native/scripts/generate_app_icons.sh` from the repository root to regenerate `Assets.car`, the legacy `MacScope.icns`, and the README preview `MacScopeIcon.png`. These compiled resources are included so ordinary builds do not require Icon Composer.

The script also exports `MacScopeDockLight.png` and `MacScopeDockDark.png`, with the standard macOS icon inset. The running app selects these native-rendered images using its effective appearance or the user's Dock icon override. `Assets.car` remains the layered icon used by the system outside the running app; Finder's icon style is independent of the app's window appearance.
