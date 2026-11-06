# Bred Animation Engine 1.0.2

English interface for macOS 13 and later. Existing libraries, settings, media and prepared frame caches remain compatible.

## Build and launch

Install Apple Command Line Tools if needed: `xcode-select --install`.
Quit the previous app using its menu bar icon, extract this project and run:

```bash
bash ~/Downloads/BredAnimationEngine/build.command
```

Use the actual project path if extracted elsewhere. The result is `build/Bred Animation Engine.app`. Move it to Applications if desired.

## Controls

Import APNG/PNG/GIF files, select to preview, double-click to launch. Playback FPS, size, rotation and flips update live. Right-click a character for controls. Command + right-click attempts to open controls in click-through mode; macOS permissions may affect global mouse monitoring. You can always use Animation controls in the library.

The app stays out of the Dock and Command-Tab. Use its menu bar icon to show the library or quit.

Audio starts with the desktop character and supports volume and looping. It does not synchronize to each animation loop. Preview audio is muted.

The first preview prepares raw RGBA frames on disk, with a maximum longest edge of 768 px. Subsequent playback reuses them. Raw frames can use substantial disk space. Clear animation cache stops characters and deletes prepared frames; source media is preserved.

Settings export contains configuration only, not media. Import restores matching items in the current library. Files live in `~/Library/Application Support/BredAnimationEngine`.

Workshop, OBS, external AnimaEngine companion apps, AI tools and MP4 conversion are not included. Startup at login is configured through macOS System Settings.

This English update changes interface text and build messages only. The project was prepared on Linux without the macOS SDK; compilation and UI behavior require verification on a Mac. The earlier Polish README contains additional implementation details.

Version 1.0.2: desktop rotation and flips now target a dedicated image sublayer rather than the AppKit-managed view layer. Frame updates replace only the image contents and preserve orientation. Requires verification on macOS.
