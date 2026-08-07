# Ink Note

Ink Note is a responsive Flutter note-taking app for Android and iOS. The UI is
platform-neutral and adapts from phones to tablets and desktop-sized windows.

## Included features

- Notes, nested folders, search, sorting, favorites, grid/list views and cover colors
- Pen, highlighter, eraser, straight-line tool, text and selection/move tool
- Multiple pages, undo/redo, pen presets, pressure input and palm-rejection settings
- System, light and dark appearance modes
- Local autosave and PNG page sharing
- Navigation rail on wide screens and bottom navigation on compact screens

## Run on Windows

Flutter must be installed before the project can be checked or run.

PowerShell:

```powershell
.\run_flutter.ps1
```

The script searches PATH, `FLUTTER_HOME`, and common Flutter installation
locations. To only download packages, analyze and run tests:

```powershell
.\run_flutter.ps1 -CheckOnly
```

Manual commands:

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

## iOS

iOS builds require macOS with Xcode. From the project directory run
`flutter pub get`, then `flutter run` with an iPhone/iPad connected or open the
Runner workspace in Xcode after Flutter has generated the iOS plugin files.

## Storage note

The current version stores note data locally with `shared_preferences`. This is
suitable for a prototype and modest note libraries. A future version should move
large drawing data to a database or files for better scalability.
"# jklkl-" 
"# ink" 
