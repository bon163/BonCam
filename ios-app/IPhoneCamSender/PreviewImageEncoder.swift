import AVFoundation
import CoreImage
import Foundation
import QuartzCore
import UIKit

protocol PreviewImageEncoderDelegate: AnyObject {
    func previewImageEncoder(_ encoder: PreviewImageEncoder, didEncode data: Data, timestampUS: UInt64)
}

final class PreviewImageEncoder {
    weak var delegate: PreviewImageEncoderDelegate?

    private let context = CIContext()
    private var lastPreviewTime: CFTimeInterval = 0
    private let minimumInterval: CFTimeInterval = 1.0 / 12.0

    func maybeEncode(sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastPreviewTime >= minimumInterval else { return }
        lastPreviewTime = now

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let targetWidth: CGFloat = 720
        let width = ciImage.extent.width
        if width > targetWidth {
            let scale = targetWidth / width
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        guard let jpeg = image.jpegData(compressionQuality: 0.45) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUS = UInt64((pts.seconds * 1_000_000.0).rounded())
        delegate?.previewImageEncoder(self, didEncode: jpeg, timestampUS: timestampUS)
    }
}
