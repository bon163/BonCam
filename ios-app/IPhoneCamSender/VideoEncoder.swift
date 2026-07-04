import AVFoundation
import Foundation
import VideoToolbox

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, isKeyframe: Bool, timestampUS: UInt64)
}

final class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?

    private var session: VTCompressionSession?

    init(width: Int32, height: Int32, bitrate: Int, fps: Int32) {
        VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &session
        )

        if let session {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [max(1, bitrate / 8), 1] as CFArray)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFTypeRef)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFTypeRef)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CAVLC)
            VTCompressionSessionPrepareToEncodeFrames(session)
        }
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let session else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }
}

private let compressionOutputCallback: VTCompressionOutputCallback = { refCon, _, status, _, sampleBuffer in
    guard status == noErr,
          let refCon,
          let sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer) else { return }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()

    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) else { return }
    let sampleAttachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
    let keyframe = !CFDictionaryContainsKey(
        sampleAttachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
    )

    var dataOut = Data()
    if keyframe,
       let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
        var spsPointer: UnsafePointer<UInt8>?
        var spsLength = 0
        var spsCount = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsLength = 0
        var ppsCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsLength, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsLength, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil)
        if let spsPointer, let ppsPointer, spsCount > 0, ppsCount > 0 {
            dataOut.append(contentsOf: [0, 0, 0, 1])
            dataOut.append(spsPointer, count: spsLength)
            dataOut.append(contentsOf: [0, 0, 0, 1])
            dataOut.append(ppsPointer, count: ppsLength)
        }
    }

    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
    guard let dataPointer else { return }

    var offset = 0
    let avccHeaderLength = 4
    while offset + avccHeaderLength < totalLength {
        let lengthData = Data(bytes: dataPointer + offset, count: avccHeaderLength)
        let nalLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        dataOut.append(contentsOf: [0, 0, 0, 1])
        dataOut.append(Data(bytes: dataPointer + offset + avccHeaderLength, count: Int(nalLength)))
        offset += avccHeaderLength + Int(nalLength)
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampUS = UInt64((pts.seconds * 1_000_000.0).rounded())
    encoder.delegate?.videoEncoder(encoder, didEncode: dataOut, isKeyframe: keyframe, timestampUS: timestampUS)
}
