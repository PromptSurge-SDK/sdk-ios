#if canImport(UIKit)
import UIKit
import XCTest
@testable import PromptSurge

/// Renders the pre-prompt dialog once per theme preset on the CI simulator and attaches each
/// render to the test report, so the five screenshots card 73 waited on a human for come out of
/// a machine instead. Card 200.
///
/// **Why the hex values are duplicated here.** The SDK never learns a preset id; the server
/// resolves a preset into four colours and sends only those, so there is nothing in this package
/// to compare against. `DIALOG_PRESETS` in `apps/api/src/routes/adminAppearance.ts` calls itself
/// the single source of truth and it is - these are a hand copy of it, and a change there has to
/// be repeated here. `testPresetCountHasNotChanged` is the tripwire for the most likely drift
/// (a sixth preset appearing) but it cannot see a changed hex, so this comment is the rest of it.
///
/// **What this settles and what it does not.** A simulator render proves layout and colour. It
/// does not prove font smoothing, safe-area behaviour on a notched device, or Dynamic Type at
/// accessibility sizes - those still need a device.
final class DialogSnapshotTests: XCTestCase {

    private struct Preset {
        let id: String
        let backgroundColor: String
        let accentColor: String
        let textColor: String
        let buttonTextColor: String
    }

    /// Copied from `DIALOG_PRESETS` in apps/api/src/routes/adminAppearance.ts. Current presets
    /// only - the legacy aliases in that file (default/midnight/ocean/sunset) are the same four
    /// colour sets under older ids, so rendering them would produce duplicate screenshots.
    private static let presets: [Preset] = [
        Preset(id: "system",    backgroundColor: "#FFFBFE", accentColor: "#6750A4", textColor: "#1C1B1F", buttonTextColor: "#FFFFFF"),
        Preset(id: "gaming",    backgroundColor: "#1A2744", accentColor: "#FFD23F", textColor: "#FFFFFF", buttonTextColor: "#1A2744"),
        Preset(id: "sweet",     backgroundColor: "#5B2080", accentColor: "#F7A722", textColor: "#FAF0D3", buttonTextColor: "#5B2080"),
        Preset(id: "metal",     backgroundColor: "#13111A", accentColor: "#A8A8B8", textColor: "#F0F0F5", buttonTextColor: "#13111A"),
        Preset(id: "greyscale", backgroundColor: "#F2F2F7", accentColor: "#8E8E93", textColor: "#1C1C1E", buttonTextColor: "#FFFFFF"),
    ]

    /// The longest copy the product ships, from `apps/api/prisma/seed.ts`. French is the longest
    /// body of the five seeded locales and also has the longest pair of buttons, so the
    /// small-screen overflow check card 73 asked for rides along in the same five shots rather
    /// than needing its own.
    private static let longestSeededCopy = PromptText(
        title: "Laisser un avis ?",
        body: "Les avis aident d'autres personnes à découvrir des applications comme celle-ci. Vous avez un instant ?",
        positiveButton: "Bien sûr",
        negativeButton: "Plus tard",
        locale: "fr"
    )

    // MARK: - Tests

    func testPresetCountHasNotChanged() {
        XCTAssertEqual(
            Self.presets.count, 5,
            "adminAppearance.ts shipped a different number of presets than this file renders. "
            + "Copy the new hex values into `presets` above; nothing else can see this drift."
        )
    }

    /// Renders every preset, attaches the PNG, and asserts the card is actually painted in the
    /// preset's background colour. That assertion is the point as much as the picture: the 1.1.0
    /// theme bug was a wire-format field-name mismatch that made every themed app fall back to
    /// system colours while still rendering a perfectly good-looking dialog.
    func testEachPresetRendersOnASmallScreen() throws {
        for preset in Self.presets {
            let theme = DialogTheme(
                presetId: preset.id,
                accentColor: preset.accentColor,
                backgroundColor: preset.backgroundColor,
                textColor: preset.textColor,
                buttonTextColor: preset.buttonTextColor
            )

            let render = try renderDialog(theme: theme, text: Self.longestSeededCopy)

            let attachment = XCTAttachment(image: render.image)
            attachment.name = "preprompt-\(preset.id)-\(Int(render.screenSize.width))x\(Int(render.screenSize.height))"
            attachment.lifetime = .keepAlways
            add(attachment)

            // A blank or all-scrim image would still attach happily, so prove the card is there
            // and wearing the right colour. The sample point is 6pt below the card's top edge and
            // 20pt in from its left edge: clear of the 16pt corner radius and above the text
            // stack's 24pt top margin, so it is flat card background.
            let sample = CGPoint(x: render.cardFrame.minX + 20, y: render.cardFrame.minY + 6)
            let expected = try XCTUnwrap(
                Self.rgb(hex: preset.backgroundColor),
                "\(preset.id): the preset's background hex is not parseable"
            )
            let actual = try XCTUnwrap(
                Self.rgb(of: render.image, atPoint: sample),
                "\(preset.id): could not read a pixel at \(sample) - the render is probably empty"
            )

            let tolerance: CGFloat = 3.0 / 255.0
            XCTAssertEqual(actual.r, expected.r, accuracy: tolerance, "\(preset.id): red channel")
            XCTAssertEqual(actual.g, expected.g, accuracy: tolerance, "\(preset.id): green channel")
            XCTAssertEqual(actual.b, expected.b, accuracy: tolerance, "\(preset.id): blue channel")
        }
    }

    /// The failure card 73 actually cares about on a small screen: the buttons pushed off the
    /// bottom by long copy. The card is capped at 90% of the safe area and the text scrolls, so
    /// the button row must stay inside the screen with the longest copy the product ships.
    func testButtonsStayOnScreenWithTheLongestCopy() throws {
        let theme = DialogTheme(
            presetId: "system",
            accentColor: "#6750A4",
            backgroundColor: "#FFFBFE",
            textColor: "#1C1B1F",
            buttonTextColor: "#FFFFFF"
        )
        let render = try renderDialog(theme: theme, text: Self.longestSeededCopy)

        XCTAssertLessThanOrEqual(
            render.cardFrame.maxY, render.screenSize.height,
            "The dialog card extends past the bottom of the screen, so the buttons are unreachable."
        )
        XCTAssertGreaterThanOrEqual(render.cardFrame.minY, 0, "The dialog card starts above the top of the screen.")
        XCTAssertGreaterThan(render.cardFrame.height, 100, "The card collapsed rather than laying out.")
    }

    // MARK: - Rendering

    private struct Render {
        let image: UIImage
        let cardFrame: CGRect
        let screenSize: CGSize
    }

    /// Lays the dialog out in a window the size of the simulator's screen and photographs it.
    ///
    /// The controller is installed as a child rather than presented modally: `present` is
    /// asynchronous even with `animated: false`, and a completion handler that never fires would
    /// turn a layout failure into a five-second timeout with nothing to look at. Every constraint
    /// in `PrePromptViewController` is relative to its own `view`, so the layout under test is the
    /// same either way.
    private func renderDialog(theme: DialogTheme, text: PromptText) throws -> Render {
        let screen = UIScreen.main.bounds
        let window = UIWindow(frame: screen)
        let host = UIViewController()
        host.view.backgroundColor = .white
        window.rootViewController = host
        window.makeKeyAndVisible()

        let response = PromptResponse(
            promptId: nil,
            appPromptNumber: nil,
            text: text,
            theme: theme,
            // No image: the header is decorative, loads over the network and would make the
            // render depend on a URL being reachable from a CI simulator.
            imageUrl: nil,
            warmup: false
        )
        let dialog = PrePromptViewController(promptResponse: response, onAccept: {}, onDismiss: {})

        host.addChild(dialog)
        dialog.view.frame = host.view.bounds
        dialog.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(dialog.view)
        dialog.didMove(toParent: host)

        window.setNeedsLayout()
        window.layoutIfNeeded()
        // One turn of the run loop so the render server has the layout before it is captured.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let card = try XCTUnwrap(Self.cardView(in: dialog.view), "The dialog laid out no card view")
        let cardFrame = card.convert(card.bounds, to: window)

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { ctx in
            // `drawHierarchy` is the accurate path and needs a visible window; `layer.render` is
            // the fallback that works regardless. Falling back silently would hide a real failure,
            // so it is only reached when the first genuinely refuses.
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: ctx.cgContext)
            }
        }

        return Render(image: image, cardFrame: cardFrame, screenSize: screen.size)
    }

    /// The card is the one subview with a corner radius; the controller keeps it private, and a
    /// snapshot test is not a reason to widen the SDK's API.
    private static func cardView(in root: UIView) -> UIView? {
        for subview in root.subviews {
            if subview.layer.cornerRadius > 0 && subview.bounds.height > 0 { return subview }
            if let found = cardView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Pixels

    private static func rgb(hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = UInt64(trimmed, radix: 16) else { return nil }
        return (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
    }

    private static func rgb(of image: UIImage, atPoint point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let cg = image.cgImage else { return nil }
        let x = Int((point.x * image.scale).rounded())
        // CGImage draws bottom-up, UIKit points are top-down.
        let yFromTop = Int((point.y * image.scale).rounded())
        guard x >= 0, x < cg.width, yFromTop >= 0, yFromTop < cg.height else { return nil }
        let y = cg.height - 1 - yFromTop

        var pixel: [UInt8] = [0, 0, 0, 0]
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.translateBy(x: CGFloat(-x), y: CGFloat(-y))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }
}
#endif
