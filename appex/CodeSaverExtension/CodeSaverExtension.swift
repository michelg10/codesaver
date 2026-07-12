//
//  CodeSaverExtension.swift
//  CodeSaverExtension
//
//  Copyright © 2026 Guillaume Louel. Licensed under the MIT License.
//
//  Principal class for the screensaver extension. Specified as
//  NSExtensionPrincipalClass in Info.plist as
//  `$(PRODUCT_MODULE_NAME).CodeSaverExtension`.
//
//  Following Apple's own screensavers (e.g. Arabesque.appex) we keep this
//  minimal — only implement init() and let the framework drive lifecycle.
//

import Foundation
import ScreenSaver

private let logger = AppexLog.logger("Extension")

@objc(CodeSaverExtension)
class CodeSaverExtension: ScreenSaverExtension {

    @objc override init() {
        logger.info("CodeSaverExtension.init() PID=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        super.init()
    }

    deinit {
        logger.info("CodeSaverExtension.deinit")
    }
}
