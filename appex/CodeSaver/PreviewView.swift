//
//  PreviewView.swift
//  CodeSaver
//
//  NSView that embeds the same CodeSaverView the screensaver extension uses,
//  so the host app's Preview window matches what the screensaver displays.
//  CodeSaverView drives its own animation once it lands in a window.
//

import AppKit

final class PreviewView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        guard let saver = CodeSaverView(frame: bounds, isPreview: false) else { return }
        saver.autoresizingMask = [.width, .height]
        addSubview(saver)
    }
}
