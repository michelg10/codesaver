//
//  CodeSaverConfigurationViewController.swift
//  CodeSaverExtension
//
//  Options sheet shown from System Settings. Backed by ScreenSaverDefaults,
//  which CodeSaverView re-reads while running, so the preview updates live.
//

import AppKit
import ScreenSaver

@objc(CodeSaverConfigurationViewController)
class CodeSaverConfigurationViewController: NSViewController {

    private let defaults = ScreenSaverDefaults(forModuleWithName: CodeSaverView.prefsSuite)
    private var clockCheckbox: NSButton!
    private var formatControl: NSSegmentedControl!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 168))

        let title = NSTextField(labelWithString: "CodeSaver")
        title.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)

        let showClock = defaults?.object(forKey: "showClock") == nil
            ? true : defaults?.bool(forKey: "showClock") ?? true
        clockCheckbox = NSButton(checkboxWithTitle: "Show clock",
                                 target: self, action: #selector(settingChanged))
        clockCheckbox.state = showClock ? .on : .off

        formatControl = NSSegmentedControl(labels: ["12-hour", "24-hour"],
                                           trackingMode: .selectOne,
                                           target: self, action: #selector(settingChanged))
        formatControl.selectedSegment = (defaults?.bool(forKey: "use24HourTime") ?? false) ? 1 : 0
        formatControl.isEnabled = showClock

        let ok = NSButton(title: "OK", target: self, action: #selector(dismissSheet))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"

        for v in [title, clockCheckbox!, formatControl!, ok] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            clockCheckbox.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            clockCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            formatControl.topAnchor.constraint(equalTo: clockCheckbox.bottomAnchor, constant: 10),
            formatControl.leadingAnchor.constraint(equalTo: clockCheckbox.leadingAnchor, constant: 20),
            ok.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            ok.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        self.view = container
        self.preferredContentSize = container.frame.size
    }

    @objc private func settingChanged(_ sender: Any?) {
        defaults?.set(clockCheckbox.state == .on, forKey: "showClock")
        defaults?.set(formatControl.selectedSegment == 1, forKey: "use24HourTime")
        defaults?.synchronize()
        formatControl.isEnabled = clockCheckbox.state == .on
    }

    @objc private func dismissSheet(_ sender: Any?) {
        if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            dismiss(nil)
        }
    }
}
