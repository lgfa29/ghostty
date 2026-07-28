//
//  GhosttySplitZoomTests.swift
//  Ghostty
//
//  Reproduces the blank/frozen split reported in:
//  https://github.com/ghostty-org/ghostty/discussions/11689
//  https://github.com/ghostty-org/ghostty/discussions/11753
//

import AppKit
import XCTest

final class GhosttySplitZoomTests: GhosttyCustomConfigCase {
    /// Opt out of the Xcode-IDE-only gate in `GhosttyCustomConfigCase` so this
    /// runs under `xcodebuild test` too, which is how the repro gets exercised
    /// outside of the IDE.
    override class var defaultTestSuite: XCTestSuite {
        XCTestSuite(forTestCaseClass: Self.self)
    }

    /// Text we fill the surface with so we can (a) find the right surface in the
    /// accessibility hierarchy and (b) know that the surface has content that
    /// MUST be visible on screen.
    private let marker = "GHOSTTYZOOMMARKER"

    /// How many times we toggle the zoom. The bug is intermittent, the reports
    /// say "a couple of times", so we give it a decent number of attempts.
    private let toggleCount = 20

    /// Toggling split zoom via a *sequence* keybind (e.g. `ctrl+a>z`) eventually
    /// leaves the split blank and unresponsive: the surface stops rendering
    /// entirely even though the terminal contents are still there.
    ///
    /// https://github.com/ghostty-org/ghostty/discussions/11689
    /// https://github.com/ghostty-org/ghostty/discussions/11753
    @MainActor
    func testSplitZoomWithSequenceKeybindKeepsSurfaceRendered() async throws {
        let app = try await zoomableSplitApp(keybind: "keybind = ctrl+a>z=toggle_split_zoom")
        try await assertZoomTogglesKeepSurfaceUsable(app) {
            // The sequence keybind: `ctrl+a` then `z`.
            app.typeKey("a", modifierFlags: .control)
            app.typeKey("z", modifierFlags: [])
        }
    }

    /// The control case for the above: the reports are explicit that a plain
    /// (non-sequence) keybind for the same action does not trigger the bug, so
    /// this test is expected to pass. It exists to keep the sequence test honest
    /// - if both fail, the problem isn't about key sequences.
    @MainActor
    func testSplitZoomWithDirectKeybindKeepsSurfaceRendered() async throws {
        let app = try await zoomableSplitApp(keybind: "keybind = ctrl+shift+z=toggle_split_zoom")
        try await assertZoomTogglesKeepSurfaceUsable(app) {
            app.typeKey("z", modifierFlags: [.control, .shift])
        }
    }

    // MARK: Setup

    /// Launches Ghostty with the given zoom keybind, creates a second split, and
    /// fills that (focused) split with text that must remain visible.
    @MainActor
    private func zoomableSplitApp(keybind: String) async throws -> XCUIApplication {
        // A black background and white foreground makes "is anything drawn?" a
        // simple luminance question. Blinking is disabled so that a blinking
        // cursor can't be the thing that saves us on any given frame.
        try updateConfig(
            """
            title = GhosttySplitZoomTests
            \(keybind)
            background = 000000
            foreground = ffffff
            cursor-style-blink = false
            confirm-close-surface = false
            window-save-state = never
            """
        )

        let app = try ghosttyApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "New window should appear")

        // Create a split. The new split takes focus, and it's the focused split
        // that we're going to zoom in and out of.
        app.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .seconds(1))

        // Fill the focused split with text. We `cat` a file rather than `echo` so
        // this doesn't depend on the user's shell, and so the marker never shows
        // up on screen just from us typing the command.
        let file = NSTemporaryDirectory() + "ghostty_zoom_test.txt"
        let lines = (1...40).map { _ in String(repeating: "\(marker) ", count: 4) }
        try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: file) }
        app.typeText("clear; cat \(file)\r")

        guard let surface = try await waitForSurface(in: app, containing: marker) else {
            XCTFail("Terminal contents never showed up, test setup failed")
            return app
        }
        XCTAssertGreaterThan(
            drawnFraction(of: surface),
            Self.minimumDrawnFraction,
            "Terminal contents were never rendered, test setup failed")

        return app
    }

    // MARK: Assertions

    /// Toggles the zoom repeatedly and fails as soon as the zoomed split stops
    /// being a usable terminal: gone from the accessibility hierarchy, not
    /// drawing its contents, or not responding to keys.
    @MainActor
    private func assertZoomTogglesKeepSurfaceUsable(
        _ app: XCUIApplication,
        toggleZoom: () -> Void
    ) async throws {
        for toggle in 1...toggleCount {
            toggleZoom()

            // Give the zoom (and the SwiftUI rebuild it triggers) time to settle
            // and the renderer time to draw a frame.
            try await Task.sleep(for: .seconds(0.5))

            let state = toggle.isMultiple(of: 2) ? "unzoomed" : "zoomed"

            // Re-resolve the surface every time: the zoom toggle tears down and
            // rebuilds the split view hierarchy, so the element from the previous
            // iteration is stale.
            guard let surface = try await waitForSurface(in: app, containing: marker) else {
                attachScreenshot(of: app, name: "surface-missing-after-\(toggle)-toggles")
                XCTFail("""
                    Surface disappeared from the accessibility hierarchy after \(toggle) zoom toggle(s) (\(state)). \
                    A surface that is no longer in the view hierarchy can neither draw nor receive events. \
                    Panes: \(app.groups.matching(NSPredicate(format: "label == %@", "Terminal pane")).count), \
                    surfaces: \(surfaceValues(in: app))
                    """)
                return
            }

            let drawn = drawnFraction(of: surface)
            if drawn <= Self.minimumDrawnFraction {
                attachScreenshot(of: app, name: "surface-blank-after-\(toggle)-toggles")
            }
            XCTAssertGreaterThan(
                drawn,
                Self.minimumDrawnFraction,
                "Surface went blank after \(toggle) zoom toggle(s) (\(state)): only \(drawn) of its pixels were drawn")
        }

        // The reports also say the blank split stops responding to input, so make
        // sure the surface still reacts to key events. The two arguments are
        // concatenated by printf so the text we look for can only come from the
        // command actually running, not from the shell echoing what we typed.
        app.typeText("printf '%s%s\\n' \(marker) ALIVE\r")
        let alive = try await waitForSurface(in: app, containing: "\(marker)ALIVE") != nil
        XCTAssertTrue(alive, "Surface stopped responding to key events after \(toggleCount) zoom toggles")
    }

    // MARK: Helpers

    /// The fraction of a surface's pixels that must be non-background for us to
    /// consider it drawn. Screen-filling text is far above this; a blank surface
    /// is at (or very near) zero.
    private static let minimumDrawnFraction: Double = 0.005

    /// Finds the terminal surface whose contents contain the given text, polling
    /// until the deadline because terminal output is asynchronous.
    ///
    /// The surface exposes its screen contents as its accessibility value, so
    /// this finds the surface using state from the terminal core, independent of
    /// whether anything is actually being rendered.
    @MainActor
    private func waitForSurface(
        in app: XCUIApplication,
        containing text: String,
        timeout: TimeInterval = 5
    ) async throws -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let surfaces = app.descendants(matching: .textView)
            for index in 0..<surfaces.count {
                let surface = surfaces.element(boundBy: index)
                guard let value = surface.value as? String else { continue }
                if value.contains(text) { return surface }
            }

            try await Task.sleep(for: .seconds(0.25))
        } while Date() < deadline

        return nil
    }

    /// Attaches a screenshot of the window to the test results so the failure can
    /// be eyeballed after the fact.
    @MainActor
    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A short summary of every terminal surface currently in the accessibility
    /// hierarchy, for diagnosing failures.
    @MainActor
    private func surfaceValues(in app: XCUIApplication) -> [String] {
        let surfaces = app.descendants(matching: .textView)
        return (0..<surfaces.count).map { index in
            let value = surfaces.element(boundBy: index).value as? String ?? "<no value>"
            return String(value.replacingOccurrences(of: "\n", with: "⏎").prefix(60))
        }
    }

    /// The fraction of the surface's pixels that differ from the (black)
    /// background, i.e. how much of it Ghostty actually drew.
    @MainActor
    private func drawnFraction(of surface: XCUIElement) -> Double {
        guard let cgImage = surface.screenshot().image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else { return 0 }

        let rep = NSBitmapImageRep(cgImage: cgImage)

        // Sampling every 4th pixel keeps this fast enough to run once per toggle
        // while still catching text-sized features.
        let step = 4
        var sampled = 0
        var drawn = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                sampled += 1
                if color.luminance > 0.1 { drawn += 1 }
            }
        }

        guard sampled > 0 else { return 0 }
        return Double(drawn) / Double(sampled)
    }
}
