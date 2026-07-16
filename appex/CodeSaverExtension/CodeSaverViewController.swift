//
//  CodeSaverViewController.swift
//  CodeSaverExtension
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  Main view controller for the screensaver. Specified as
//  ScreenSaverViewControllerClass in Info.plist as
//  `$(PRODUCT_MODULE_NAME).CodeSaverViewController`.
//
//  Mirrors Apple's Arabesque.appex pattern: only override the standard
//  init(nibName:bundle:), init(coder:), and loadView(); let the framework
//  drive everything else.
//

import AppKit
import ScreenSaver

private let logger = AppexLog.logger("ViewController")

@objc(CodeSaverViewController)
class CodeSaverViewController: ScreenSaverViewController {

    /// Strong reference so the framework can't drop our view while we still own it.
    private var saverView: CodeSaverView?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        logger.info("init(nibName:bundle:)")
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        logger.info("init(coder:)")
        super.init(coder: coder)
    }

    deinit {
        logger.info("deinit")
    }

    /// Called by the framework to create the view.
    ///
    /// Deliberately the plain loadView() override, matching Apple's own appex
    /// savers (Arabesque et al.) — overriding the private
    /// loadView(forFrame:isPreview:) hook instead replaces framework hosting
    /// setup its base implementation performs, and the saver renders black
    /// (learned the hard way). The cost: the System Settings preview renders
    /// at full-screen metrics rather than as a true miniature.
    override func loadView() {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        logger.notice("loadView() — initial frame \(Double(frame.width), privacy: .public)×\(Double(frame.height), privacy: .public)")
        let view = CodeSaverView(frame: frame, isPreview: false)
        saverView = view
        self.view = view ?? NSView(frame: frame)
    }
}
