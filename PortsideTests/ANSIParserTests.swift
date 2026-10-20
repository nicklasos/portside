import AppKit
import XCTest
@testable import Portside

final class ANSIParserTests: XCTestCase {
    private typealias Style = ANSIParser.Style

    func testPlainTextIsOneDefaultRun() {
        XCTAssertEqual(ANSIParser.runs("hello world"), [.init(text: "hello world", style: Style())])
    }

    func testBasicAndBrightForegroundsAndReset() {
        let runs = ANSIParser.runs("\u{1B}[31merror\u{1B}[0m ok \u{1B}[92mgreen\u{1B}[39m plain")
        XCTAssertEqual(runs.map(\.text), ["error", " ok ", "green", " plain"])
        XCTAssertEqual(runs[0].style.foreground, ANSIParser.palette[1])
        XCTAssertNil(runs[1].style.foreground)
        XCTAssertEqual(runs[2].style.foreground, ANSIParser.palette[10])
        XCTAssertNil(runs[3].style.foreground)
    }

    func testBoldCombinesWithColorAndTwentyTwoClearsIt() {
        let runs = ANSIParser.runs("\u{1B}[1;33mWARN\u{1B}[22m rest")
        XCTAssertEqual(runs[0], .init(text: "WARN", style: Style(foreground: ANSIParser.palette[3], bold: true)))
        XCTAssertEqual(runs[1], .init(text: " rest", style: Style(foreground: ANSIParser.palette[3], bold: false)))
    }

    func testEmptySGRMeansReset() {
        let runs = ANSIParser.runs("\u{1B}[35ma\u{1B}[mb")
        XCTAssertEqual(runs.map(\.text), ["a", "b"])
        XCTAssertNil(runs[1].style.foreground)
    }

    func test256AndTrueColor() {
        let runs = ANSIParser.runs("\u{1B}[38;5;196mred\u{1B}[38;2;10;20;30mrgb\u{1B}[38;5;9mbright")
        XCTAssertEqual(runs[0].style.foreground, ANSIParser.color256(196))
        XCTAssertEqual(runs[1].style.foreground, NSColor(srgbRed: 10 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1))
        XCTAssertEqual(runs[2].style.foreground, ANSIParser.palette[9])
    }

    func testBackgroundColorsAreConsumedWithoutLeakingIntoForeground() {
        let runs = ANSIParser.runs("\u{1B}[48;5;21;32mx")
        XCTAssertEqual(runs, [.init(text: "x", style: Style(foreground: ANSIParser.palette[2]))])
    }

    func testCursorAndOSCSequencesAreStripped() {
        let line = "\u{1B}[2K\u{1B}[1Gbuilt\u{1B}]0;title\u{07} in \u{1B}]8;;http://x\u{1B}\\1s\u{1B}(B"
        XCTAssertEqual(ANSIParser.runs(line).map(\.text).joined(), "built in 1s")
    }

    func testCarriageReturnKeepsTheLastRedraw() {
        XCTAssertEqual(ANSIParser.runs("10%\r50%\r100% done").map(\.text).joined(), "100% done")
        XCTAssertEqual(ANSIParser.runs("done\r").map(\.text).joined(), "done")
    }

    func testTruncatedEscapeDoesNotCrashOrLeak() {
        XCTAssertEqual(ANSIParser.runs("abc\u{1B}[31").map(\.text).joined(), "abc")
        XCTAssertEqual(ANSIParser.runs("abc\u{1B}").map(\.text).joined(), "abc")
        XCTAssertEqual(ANSIParser.runs("\u{1B}[38;5mx").map(\.text).joined(), "x")
    }

    func testAttributedStringCarriesFontsAndColors() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let s = ANSIParser.attributedString("\u{1B}[1;31mfail\u{1B}[0m ok", font: font, boldFont: bold)
        XCTAssertEqual(s.string, "fail ok")
        XCTAssertEqual(s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, bold)
        XCTAssertEqual(s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, ANSIParser.palette[1])
        XCTAssertEqual(s.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, ANSIParser.defaultForeground)
    }
}
