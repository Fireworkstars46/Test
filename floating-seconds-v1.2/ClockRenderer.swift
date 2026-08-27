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
        context.setFillColor(settings.backgroundColor.uiColor.cgColor)
        context.fill(canvasRect)

        let requestedBorder = CGFloat(settings.borderWidth)
        let maxBorder = max(0, min(CGFloat(min(width, height)) / 2.0 - 0.5, requestedBorder))
        if maxBorder > 0 {
            context.setStrokeColor(settings.borderColor.uiColor.cgColor)
            context.setLineWidth(maxBorder)
            let inset = maxBorder / 2.0
            context.stroke(canvasRect.insetBy(dx: inset, dy: inset))
        }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let text = settings.formattedTime(for: date)
        let fontSize = max(1.0, CGFloat(height) * CGFloat(settings.textScale))
        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: settings.fontWeight.uiWeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping

        let attributesText: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: settings.textColor.uiColor,
            .paragraphStyle: paragraph
        ]

        let safeInset = max(0, maxBorder + 1)
        let contentWidth = max(1, CGFloat(width) - safeInset * 2)
        let verticalInset = max(safeInset, (CGFloat(height) - font.lineHeight) / 2.0)
        let rect = CGRect(
            x: safeInset,
            y: verticalInset,
            width: contentWidth,
            height: max(1, CGFloat(height) - verticalInset - safeInset)
        )
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributesText, context: nil)

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
}
