import AppKit

/// Turns one log line with ANSI escape sequences into styled text for a dark background.
/// Each line is parsed on its own, so a rebuilt view renders exactly like an incrementally built one.
enum ANSIParser {
    struct Style: Equatable {
        var foreground: NSColor?
        var bold = false
        var dim = false
        var underline = false
    }

    struct Run: Equatable {
        var text: String
        var style: Style
    }

    static let defaultForeground = NSColor(white: 0.86, alpha: 1)

    static func attributedString(_ line: String, font: NSFont, boldFont: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in runs(line) {
            var color = run.style.foreground ?? defaultForeground
            if run.style.dim { color = color.withAlphaComponent(0.6) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: run.style.bold ? boldFont : font,
                .foregroundColor: color,
            ]
            if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
    }

    /// Text after the last carriage return wins, as a terminal would show a redrawn progress line.
    static func runs(_ line: String) -> [Run] {
        let visible = line.split(separator: "\r", omittingEmptySubsequences: false).last(where: { !$0.isEmpty }).map(String.init) ?? ""
        var runs: [Run] = []
        var style = Style()
        var text = ""
        let scalars = Array(visible.unicodeScalars)
        var i = 0

        func flush() {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, style: style))
            }
            text = ""
        }

        while i < scalars.count {
            let c = scalars[i]
            guard c == "\u{1B}" else {
                if c.value >= 0x20 || c == "\t" { text.unicodeScalars.append(c) }
                i += 1
                continue
            }
            guard i + 1 < scalars.count else { break }
            switch scalars[i + 1] {
            case "[":
                var j = i + 2
                var params = ""
                while j < scalars.count, (0x30...0x3F).contains(scalars[j].value) {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                while j < scalars.count, (0x20...0x2F).contains(scalars[j].value) { j += 1 }
                guard j < scalars.count else { i = scalars.count; continue }
                if scalars[j] == "m" {
                    flush()
                    apply(sgr: params, to: &style)
                }
                i = j + 1
            case "]":
                var j = i + 2
                while j < scalars.count {
                    if scalars[j] == "\u{07}" { j += 1; break }
                    if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 2; break }
                    j += 1
                }
                i = j
            default:
                var j = i + 1
                while j < scalars.count, (0x20...0x2F).contains(scalars[j].value) { j += 1 }
                i = j + 1
            }
        }
        flush()
        return runs
    }

    private static func apply(sgr params: String, to style: inout Style) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var k = 0
        while k < codes.count {
            let code = codes[k]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 22: style.bold = false; style.dim = false
            case 4: style.underline = true
            case 24: style.underline = false
            case 30...37: style.foreground = palette[code - 30]
            case 90...97: style.foreground = palette[code - 90 + 8]
            case 39: style.foreground = nil
            case 38, 48:
                let (color, consumed) = extendedColor(codes, from: k + 1)
                if code == 38, let color { style.foreground = color }
                k += consumed
            default: break
            }
            k += 1
        }
    }

    /// Reads `5;n` or `2;r;g;b` after a 38/48 and returns how many codes it consumed.
    private static func extendedColor(_ codes: [Int], from k: Int) -> (NSColor?, Int) {
        guard k < codes.count else { return (nil, 0) }
        switch codes[k] {
        case 5:
            guard k + 1 < codes.count else { return (nil, 1) }
            return (color256(codes[k + 1]), 2)
        case 2:
            guard k + 3 < codes.count else { return (nil, codes.count - k) }
            let c = codes[k + 1...k + 3].map { CGFloat(min(max($0, 0), 255)) / 255 }
            return (NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1), 4)
        default:
            return (nil, 1)
        }
    }

    static func color256(_ n: Int) -> NSColor? {
        switch n {
        case 0...15:
            return palette[n]
        case 16...231:
            let v = n - 16
            let level = { (x: Int) -> CGFloat in x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
            return NSColor(srgbRed: level(v / 36), green: level(v / 6 % 6), blue: level(v % 6), alpha: 1)
        case 232...255:
            let g = CGFloat(8 + (n - 232) * 10) / 255
            return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
        default:
            return nil
        }
    }

    /// Normal then bright, tuned to read on the log view's near-black background.
    static let palette: [NSColor] = ([
        0x4D4D4D, 0xF2564B, 0x5BD35B, 0xE5C04B, 0x5C9DFF, 0xD072E8, 0x4FC9D8, 0xD0D0D0,
        0x7F7F7F, 0xFF7A70, 0x7CF07C, 0xFFE070, 0x82B6FF, 0xE79AFF, 0x77E5F0, 0xFFFFFF,
    ] as [Int]).map(rgb)

    private static func rgb(_ hex: Int) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
