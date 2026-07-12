import ScreenSaver

// Verifies the .saver bundle loads and its principal class instantiates,
// approximating what legacyScreenSaver does.
let path = CommandLine.arguments[1]
guard let bundle = Bundle(path: path) else { fatalError("no bundle at \(path)") }
guard bundle.load() else { fatalError("bundle failed to load") }
guard let cls = bundle.principalClass as? ScreenSaverView.Type else {
    fatalError("principal class missing or not a ScreenSaverView: \(String(describing: bundle.principalClass))")
}
guard let view = cls.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500), isPreview: false) else {
    fatalError("init returned nil")
}
for _ in 0..<90 { view.animateOneFrame() }
print("OK: \(cls) loaded, instantiated, animated 90 frames")
