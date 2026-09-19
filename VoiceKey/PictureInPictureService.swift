import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

@MainActor
final class PictureInPictureService: NSObject,
                                     @preconcurrency AVPictureInPictureControllerDelegate,
                                     @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()

    var onActiveChanged: (@MainActor (Bool) -> Void)?
    var onError: (@MainActor (String) -> Void)?

    private var controller: AVPictureInPictureController?
    private(set) var isActive = false

    var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        renderStatus(
            title: "VoiceKing Ready",
            subtitle: "Microphone off until you tap Speak"
        )
    }

    func attachPreview(to host: UIView) {
        if displayLayer.superlayer !== host.layer {
            displayLayer.removeFromSuperlayer()
            host.layer.addSublayer(displayLayer)
        }
        layoutPreview(in: host.bounds)
    }

    func layoutPreview(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func start() async throws {
        guard isSupported else {
            throw PiPError.unsupported
        }

        showReady()

        if controller == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.requiresLinearPlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            self.controller = controller
        }

        guard let controller else {
            throw PiPError.unavailable
        }

        for _ in 0..<15 {
            if controller.isPictureInPicturePossible {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        guard controller.isPictureInPicturePossible else {
            throw PiPError.notReady
        }

        controller.startPictureInPicture()
    }

    func stop() {
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        } else {
            setActive(false)
        }
    }

    func showReady() {
        renderStatus(
            title: "VoiceKing Ready",
            subtitle: "Mic turns on only after Speak"
        )
    }

    func showRecording() {
        renderStatus(
            title: "VoiceKing Recording",
            subtitle: "Tap Stop in the keyboard when finished"
        )
    }

    func showTranscribing() {
        renderStatus(
            title: "VoiceKing",
            subtitle: "Transcribing…"
        )
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            showReady()
        }
        onActiveChanged?(active)
    }

    private func renderStatus(title: String, subtitle: String) {
        let width = 640
        let height = 360
        let size = CGSize(width: width, height: height)

        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let titleStyle = NSMutableParagraphStyle()
            titleStyle.alignment = .center
            let subtitleStyle = NSMutableParagraphStyle()
            subtitleStyle.alignment = .center

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 42, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: titleStyle
            ]
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .regular),
                .foregroundColor: UIColor.lightGray,
                .paragraphStyle: subtitleStyle
            ]

            (title as NSString).draw(
                in: CGRect(x: 32, y: 122, width: 576, height: 60),
                withAttributes: titleAttributes
            )
            (subtitle as NSString).draw(
                in: CGRect(x: 32, y: 198, width: 576, height: 80),
                withAttributes: subtitleAttributes
            )
        }

        guard let cgImage = image.cgImage else { return }

        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess,
        let pixelBuffer else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return
        }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else {
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?

        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
        let sampleBuffer else {
            return
        }

        displayLayer.flush()
        displayLayer.enqueue(sampleBuffer)
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        setActive(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        setActive(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        setActive(false)
        onError?(error.localizedDescription)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    enum PiPError: LocalizedError {
        case unsupported
        case unavailable
        case notReady

        var errorDescription: String? {
            switch self {
            case .unsupported:
                "Picture in Picture is not supported on this device."
            case .unavailable:
                "VoiceKing could not create Picture in Picture."
            case .notReady:
                "Picture in Picture is not ready yet. Keep VoiceKing visible and try again."
            }
        }
    }
}
