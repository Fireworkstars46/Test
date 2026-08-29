import UIKit
import CoreMedia
import CoreVideo

struct ClockRenderer {
    static func makeSampleBuffer(settings: SettingsStore, date: Date = Date()) -> CMSampleBuffer? {
        let size = settings.canvasSize
        let width = max(2, Int(size.width.rounded()))
        let height = max(2, Int(size.height.rounded()))

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(canvasRect)

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let fontSize = max(1.0, CGFloat(height) * CGFloat(settings.textScale))
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: settings.fontWeight.uiWeight)
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: settings.textColor.uiColor
        ]

        draw(
            settings.formattedSeconds(for: date),
            in: canvasRect,
            x: settings.clockX,
            y: settings.clockY,
            attributes: textAttributes
        )

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
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
        ) == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
            let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            CFDictionarySetValue(dictionary, key, value)
        }
        return sampleBuffer
    }

    private static func draw(
        _ text: String,
        in drawable: CGRect,
        x: Double,
        y: Double,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard !text.isEmpty, drawable.width > 0, drawable.height > 0 else { return }

        let nsText = text as NSString
        let measured = nsText.size(withAttributes: attributes)
        let clampedX = max(-1.0, min(1.0, x))
        let clampedY = max(-1.0, min(1.0, y))

        let maxShiftX = max(0, (drawable.width - measured.width) / 2)
        let maxShiftY = max(0, (drawable.height - min(measured.height, drawable.height)) / 2)
        let centerX = drawable.midX + CGFloat(clampedX) * maxShiftX
        let centerY = drawable.midY + CGFloat(clampedY) * maxShiftY
        let origin = CGPoint(
            x: centerX - measured.width / 2,
            y: centerY - measured.height / 2
        )

        nsText.draw(at: origin, withAttributes: attributes)
    }
}
