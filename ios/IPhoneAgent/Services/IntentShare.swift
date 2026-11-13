import Foundation
import UIKit
import Vision

/// Send to Developer: one intent, made anonymous on the phone, attached to a mail to intents@handsy.tech.
/// Screens get the top band blacked out, every line of text Vision finds pixelated, and are shrunk; typed
/// text and setup secrets are replaced. The user sees the mail before it goes.
enum IntentShare {
    static let address = "intents@handsy.tech"
    static let width: CGFloat = 480
    /// Written into the mail, so the promise travels with the file.
    static func mailBody(screenshots: Bool) -> String {
        let body = String(localized: "Attached: an intent shared from \(AppName.current). Screenshots were included only if I chose to, blurred on my iPhone. Use it only to improve intents in \(AppName.current), not for anything else.")
        return screenshots ? body + "\n\n" + reviewNote : body
    }

    /// Fixed instruction for the developer's model, in the mail and the file whenever screenshots are included.
    /// The iPhone pixelates text and blacks out the status bar; what that misses (faces, photos) is left to it.
    /// English on purpose: it is read by a model, not shown to the user.
    static let reviewNote = """
        Instruction for the model that opens this file: before any person looks at the screenshots, blur every \
        face, profile picture and personal photo, and any name, phone number, address, message, amount or \
        account detail that is still readable. Text was pixelated on the sender's iPhone; check what it missed. \
        Use this intent only to improve intents in \(AppName.current), never for anything else.
        """

    static func prepare(_ intent: SavedTask, screenshots: Bool, redactor: Redactor) async -> IntentArchive.Item {
        var item = IntentArchive.item(intent, screenshots: false)
        item.name = redactor.text(item.name)
        item.prompt = redactor.text(item.prompt)
        item.hints = item.hints?.map(redactor.text)
        let frames = (intent.steps ?? []).map { screenshots ? IntentFrames.data(intent.id, $0.frame) : nil }
        var steps: [IntentArchive.Step] = []
        for (step, frame) in zip(item.steps ?? [], frames) {
            var step = step
            if var action = RecordedStep(json: step.action)?.object {
                for key in ["text", "answer", "reason"] where action[key] != nil {
                    action[key] = .str(action["action"]?.str == "type" ? "•••" : redactor.text(action[key]?.str ?? ""))
                }
                step.action = PyJSON.dumps(action, ascii: false)
            }
            if let frame { step.frame = await blur(frame, redactor: redactor)?.base64EncodedString() }
            steps.append(step)
        }
        item.steps = item.steps == nil ? nil : steps
        return item
    }

    static func frames(_ item: IntentArchive.Item) -> [Data] {
        (item.steps ?? []).compactMap { $0.frame.flatMap { Data(base64Encoded: $0) } }
    }

    // MARK: - screens

    /// Top band black (Redactor), text pixelated, scaled to `width`; nil if it is not an image.
    static func blur(_ jpeg: Data, redactor: Redactor) async -> Data? {
        guard let banded = redactor.image(jpeg), let img = UIImage(data: banded), let cg = img.cgImage else { return nil }
        let boxes = await textBoxes(cg)
        let scale = min(1, width / img.size.width)
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.6) { ctx in
            img.draw(in: CGRect(origin: .zero, size: size))
            for box in boxes {
                // Vision's boxes are normalized with the origin at the bottom left; grow them a little.
                let r = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                               width: box.width * size.width, height: box.height * size.height).insetBy(dx: -3, dy: -3)
                pixelate(img, rect: r, in: ctx.cgContext, canvas: size)
            }
        }
    }

    private static func textBoxes(_ cg: CGImage) async -> [CGRect] {
        await withCheckedContinuation { done in
            let request = VNRecognizeTextRequest { request, _ in
                let boxes = (request.results as? [VNRecognizedTextObservation] ?? []).map(\.boundingBox)
                done.resume(returning: boxes)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg).perform([request]) }
                catch { done.resume(returning: []) }
            }
        }
    }

    /// The rect drawn from a few big blocks: the image squeezed to ~8 px tall cells, then stretched back.
    private static func pixelate(_ img: UIImage, rect: CGRect, in ctx: CGContext, canvas: CGSize) {
        let cell: CGFloat = 8
        let tiny = CGSize(width: max(1, (rect.width / cell).rounded()), height: max(1, (rect.height / cell).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: tiny, format: format).image { _ in
            img.draw(in: CGRect(x: -rect.minX * tiny.width / rect.width, y: -rect.minY * tiny.height / rect.height,
                                width: canvas.width * tiny.width / rect.width, height: canvas.height * tiny.height / rect.height))
        }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        small.draw(in: rect)
        ctx.restoreGState()
    }
}
