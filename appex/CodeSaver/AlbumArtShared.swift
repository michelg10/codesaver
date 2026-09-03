//
//  AlbumArtShared.swift
//  CodeSaver — compiled into BOTH the host app and the saver extension.
//
//  Three things the app's tuning window and the saver must agree on:
//
//    1. AlbumArtTunable — a renderer parameter's UI descriptor, so the
//       tuning window builds its sliders from the renderers themselves
//       rather than a hand-kept list that silently rots.
//    2. AlbumArtGrid — a rendered art grid plus the ONE drawing routine
//       both sides use. The preview is only worth having if it is
//       pixel-identical to the saver, which means exactly one
//       implementation of "draw this grid".
//    3. AlbumArtTuning — where tuned values live (the app-group
//       container) so the daemon renders with them and the saver shows
//       the result without a rebuild.
//

import AppKit
import Foundation

// MARK: - Parameter descriptor

/// One tunable knob on a renderer: how to reach it (`key`, matching the
/// Params JSON and subscript), what to call it, and a sane slider range.
struct AlbumArtTunable {
    let key: String
    let label: String
    let min: Double
    let max: Double
    /// Coarse grouping for the tuning window's section headers.
    let group: String

    init(_ key: String, _ label: String, _ min: Double, _ max: Double,
         group: String = "") {
        self.key = key
        self.label = label
        self.min = min
        self.max = max
        self.group = group
    }
}

// MARK: - A rendered grid

/// The renderer's JSON output, parsed. Cells are the panel's own monospace
/// glyphs at a 2:1 aspect — the aspect the ramp's sampling assumed — so the
/// grid carries no font metrics of its own and lands on the chrome's
/// character grid wherever it is drawn.
struct AlbumArtGrid {
    var cols = 0
    var rows = 0
    var chars: [String] = []
    var colors: [[String]] = []
    /// The parameters this grid was rendered with, in `AlbumArtTuning.load()`
    /// shape, and the image it was rendered from — both optional. The tuning
    /// window stamps them so a consumer that has to RE-RENDER at a smaller
    /// grid (the saver fitting art to its panel) reproduces the knobs as they
    /// are right now, not as they were last saved, from the image actually
    /// on screen rather than always the current track's.
    var tuning: [String: [String: Double]]?
    var sourcePath: String?

    /// JSON keys for the two optional stamps above — one definition, used by
    /// the publisher and the parser.
    static let tuningKey = "tuning"
    static let sourceKey = "source"

    init?(json o: [String: Any]) {
        guard let cols = o["cols"] as? Int, let rows = o["rows"] as? Int,
              let chars = o["chars"] as? [String],
              let colors = o["colors"] as? [[String]],
              chars.count == rows, colors.count == rows else { return nil }
        self.cols = cols
        self.rows = rows
        self.chars = chars
        self.colors = colors
        tuning = o[Self.tuningKey] as? [String: [String: Double]]
        sourcePath = o[Self.sourceKey] as? String
    }

    /// Row pitch in points: a 2:1 cell, the aspect the ramp's sampling assumed.
    static func rowStep(charW: CGFloat) -> CGFloat { charW * 2 }

    /// Exactly cols × rows cells — no padding fudge. The art is positioned on
    /// the panel's character grid, so any stray point here would offset every
    /// glyph against the chrome around it.
    func size(charW: CGFloat) -> NSSize {
        NSSize(width: charW * CGFloat(cols),
               height: Self.rowStep(charW: charW) * CGFloat(rows))
    }

    static func color(_ hex: String) -> NSColor? {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(deviceRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Lay the grid out once. Callers that redraw every frame (the saver's
    /// panel) cache these and only pay the draw; the layout is identical
    /// either way, so the art lands on the same grid in both.
    func attributedRows(baseFont: NSFont) -> [NSAttributedString] {
        var out: [NSAttributedString] = []
        for (r, line) in chars.enumerated() {
            guard r < colors.count else { break }
            let row = NSMutableAttributedString()
            for (c, ch) in line.enumerated() {
                guard c < colors[r].count else { break }
                row.append(NSAttributedString(string: String(ch), attributes: [
                    .font: baseFont,
                    .foregroundColor: Self.color(colors[r][c]) ?? NSColor.clear,
                ]))
            }
            out.append(row)
        }
        return out
    }

    static func draw(rows: [NSAttributedString], at origin: NSPoint, step: CGFloat) {
        for (r, row) in rows.enumerated() {
            row.draw(at: NSPoint(x: origin.x, y: origin.y + CGFloat(r) * step))
        }
    }

    func draw(baseFont: NSFont, charW: CGFloat, at origin: NSPoint) {
        Self.draw(rows: attributedRows(baseFont: baseFont), at: origin,
                  step: Self.rowStep(charW: charW))
    }
}

// MARK: - Tuned values on disk

/// Tuned parameters live in the app-group container next to the feed, so a
/// slider drag reaches the daemon (which re-renders the current track) and
/// the saver shows it — no rebuild. Absent file = every renderer default.
enum AlbumArtTuning {
    static var url: URL? {
        CorpusStore.widgetsDirectory?.appendingPathComponent("albumart-tuning.json")
    }

    /// `["ramp": [key: value]]`
    static func load() -> [String: [String: Double]] {
        guard let u = url, let d = try? Data(contentsOf: u),
              let o = (try? JSONSerialization.jsonObject(with: d))
                  as? [String: [String: Double]] else { return [:] }
        return o
    }

    static func save(_ v: [String: [String: Double]]) {
        guard let u = url else { return }
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: v,
                                                  options: [.sortedKeys]) else { return }
        let tmp = u.deletingLastPathComponent()
            .appendingPathComponent(".albumart-tuning.json.tmp")
        guard (try? d.write(to: tmp)) != nil else { return }
        // rename(2), not remove+move: the saver keys its re-render cache on
        // this file's mtime and must never catch it absent.
        try? CorpusStore.replaceFile(at: u, with: tmp)
    }
}
