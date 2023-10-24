//
//  ExtensionProvider.swift
//  Extension
//
//  Created by Halle Winkler on 10.08.22.
//

import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

let kWhiteStripeHeight: Int = 10
let kFrameRate: Int = 1

// MARK: - ExtensionDeviceSource

let logger = Logger(subsystem: "com.politepix.offcutscam",
                    category: "Extension")

// MARK: - ExtensionDeviceSourceDelegate

protocol ExtensionDeviceSourceDelegate: NSObject {
    func bufferReceived(_ buffer: CMSampleBuffer)
}

// MARK: - ExtensionDeviceSource

class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    // MARK: Lifecycle

    init(localizedName: String) {
        super.init()
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        if bundleID.contains("EndToEnd") {
            _isExtension = false
        }
        let deviceID = UUID() // replace this with your device UUID
        self.device = CMIOExtensionDevice(localizedName: localizedName,
                                          deviceID: deviceID,
                                          legacyDeviceID: nil, source: self)

        let dims = CMVideoDimensions(width: 1080, height: 720)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: dims.width, height: dims.height,
                                       extensions: nil,
                                       formatDescriptionOut: &_videoDescription)

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: dims.width,
            kCVPixelBufferHeightKey: dims.height,
            kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes,
                                &_bufferPool)

        let videoStreamFormat =
            CMIOExtensionStreamFormat(formatDescription: _videoDescription,
                                      maxFrameDuration: CMTime(value: 1,
                                                               timescale: Int32(kFrameRate)),
                                      minFrameDuration: CMTime(value: 1,
                                                               timescale: Int32(kFrameRate)),
                                      validFrameDurations: nil)
        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        let videoID = UUID() // replace this with your video UUID
        _streamSource = ExtensionStreamSource(localizedName: "OffcutsCam.Video",
                                              streamID: videoID,
                                              streamFormat: videoStreamFormat,
                                              device: device)
        do {
            try device.addStream(_streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    // MARK: Public

    public weak var extensionDeviceSourceDelegate: ExtensionDeviceSourceDelegate?

    // MARK: Internal

    private(set) var device: CMIOExtensionDevice!

    var imageIsClean = true

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "OffcutsCam Model"
        }

        return deviceProperties
    }

    func setDeviceProperties(_: CMIOExtensionDeviceProperties) throws {
        // Handle settable properties here.
    }

    func startStreaming() {
        guard let _ = _bufferPool else {
            return
        }

        let Filename = imageIsClean ? "Clean" : "Dirty"

        guard let bundleURL = Bundle.main.url(forResource: Filename,
                                              withExtension: "jpg") else {
            logger.debug("Clean.jpg wasn't found in bundle, returning.")
            return
        }

        guard let imageData = NSData(contentsOf: bundleURL) else {
            logger.debug("Couldn't get data from image at URL, returning.")
            return
        }

        guard let dataProvider = CGDataProvider(data: imageData) else {
            logger.debug("Couldn't get dataProvider of URL, returning")
            return
        }

        guard let techDiffCGImage =
            CGImage(jpegDataProviderSource: dataProvider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent) else {
            logger.debug("Couldn't get CG image from dataProvider, returning")
            return
        }

        guard let techDiffBuffer = pixelBufferFromImage(techDiffCGImage) else {
            logger
                .debug("It wasn't possible to get pixelBuffer from the techDiffCGImage, exiting.")
            return
        }

        _streamingCounter += 1

        _timer = DispatchSource.makeTimerSource(flags: .strict,
                                                queue: _timerQueue)
        _timer!.schedule(deadline: .now(), repeating: Double(1 / kFrameRate),
                         leeway: .seconds(0))

        _timer!.setEventHandler {
            var err: OSStatus = 0
            let now = CMClockGetTime(CMClockGetHostTimeClock())

            var sbuf: CMSampleBuffer!
            var timingInfo = CMSampleTimingInfo()
            timingInfo
                .presentationTimeStamp =
                CMClockGetTime(CMClockGetHostTimeClock())

            var formatDescription: CMFormatDescription?

            let status =
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                             imageBuffer: techDiffBuffer,
                                                             formatDescriptionOut: &formatDescription)
            if status != 0 {
                logger
                    .debug("Couldn't make video format description from techDiffBuffer, exiting.")
            }
            if let formatDescription = formatDescription {
                err =
                    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                             imageBuffer: techDiffBuffer,
                                                             formatDescription: formatDescription,
                                                             sampleTiming: &timingInfo,
                                                             sampleBufferOut: &sbuf)
            } else {
                logger
                    .debug("Couldn't create sample buffer from techDiffBuffer, exiting.")
            }

            if self
                ._isExtension { // If I'm the extension, send to output stream
                self._streamSource.stream.send(sbuf, discontinuity: [],
                                               hostTimeInNanoseconds: UInt64(timingInfo
                                                   .presentationTimeStamp
                                                   .seconds *
                                                   Double(NSEC_PER_SEC)))
            } else {
                self.extensionDeviceSourceDelegate?
                    .bufferReceived(sbuf) // If I'm the end to end testing app, send to delegate method.
            }

            if err == 0 {
                if self
                    ._isExtension {
                    // If I'm the extension, send to output stream
                    self._streamSource.stream.send(sbuf, discontinuity: [],
                                                   hostTimeInNanoseconds: UInt64(timingInfo
                                                       .presentationTimeStamp
                                                       .seconds *
                                                       Double(NSEC_PER_SEC)))
                } else {
                    self.extensionDeviceSourceDelegate?
                        .bufferReceived(sbuf) // If I'm the end to end testing app, send to delegate method.
                }
            } else {
                os_log(.info,
                       "video time \(timingInfo.presentationTimeStamp.seconds) now \(now.seconds) err \(err)")
            }
        }

        _timer!.setCancelHandler {}
        _timer!.resume()
    }

    func pixelBufferFromImage(_ image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        let region = CGRect(x: 0, y: 0, width: width, height: height)

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]

        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32ARGB,
                                         pixelBufferAttributes as CFDictionary,
                                         &pixelBuffer)

        guard result == kCVReturnSuccess, let pixelBuffer = pixelBuffer,
              let colorspace = image.colorSpace else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer,
                                     CVPixelBufferLockFlags(rawValue: 0))
        guard let context =
            CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                      width: width,
                      height: height,
                      bitsPerComponent: image.bitsPerComponent,
                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                      space: colorspace,
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst
                          .rawValue)
        else {
            return nil
        }

        var transform = CGAffineTransform(scaleX: -1,
                                          y: 1) // Flip on vertical axis
        transform = transform.translatedBy(x: -CGFloat(image.width), y: 0)
        context.concatenate(transform)

        context.draw(image, in: region)

        CVPixelBufferUnlockBaseAddress(pixelBuffer,
                                       CVPixelBufferLockFlags(rawValue: 0))

        return pixelBuffer
    }

    func stopStreaming() {
        if _streamingCounter > 1 {
            _streamingCounter -= 1
        } else {
            _streamingCounter = 0
            if let timer = _timer {
                timer.cancel()
                _timer = nil
            }
        }
    }

    // MARK: Private

    private var _isExtension: Bool = true
    private var _streamSource: ExtensionStreamSource!

    private var _streamingCounter: UInt32 = 0

    private var _timer: DispatchSourceTimer?

    private let _timerQueue = DispatchQueue(label: "timerQueue",
                                            qos: .userInteractive,
                                            attributes: [],
                                            autoreleaseFrequency: .workItem,
                                            target: .global(qos: .userInteractive))

    private var _videoDescription: CMFormatDescription!

    private var _bufferPool: CVPixelBufferPool!

    private var _bufferAuxAttributes: NSDictionary!

    private var _whiteStripeStartRow: UInt32 = 0

    private var _whiteStripeIsAscending: Bool = false
}

// MARK: - ExtensionStreamSource

class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
    // MARK: Lifecycle

    init(localizedName: String, streamID: UUID,
         streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName,
                                          streamID: streamID,
                                          direction: .source,
                                          clockType: .hostTime, source: self)
    }

    // MARK: Internal

    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice

    var formats: [CMIOExtensionStreamFormat] {
        return [_streamFormat]
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Invalid index")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
            streamProperties.frameDuration = frameDuration
        }

        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for _: CMIOExtensionClient) -> Bool {
        // An opportunity to inspect the client info and decide if it should be allowed to start the stream.
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreaming()
    }

    // MARK: Private

    private let _streamFormat: CMIOExtensionStreamFormat
}

// MARK: - ExtensionProviderSource

class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    // MARK: Lifecycle

    // CMIOExtensionProviderSource protocol methods (all are required)

    init(clientQueue: DispatchQueue?) {
        super.init()

        startNotificationListeners()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = ExtensionDeviceSource(localizedName: "OffcutsCam")

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    deinit {
        stopNotificationListeners()
    }

    // MARK: Internal

    private(set) var provider: CMIOExtensionProvider!

    var deviceSource: ExtensionDeviceSource!

    var availableProperties: Set<CMIOExtensionProperty> {
        // See full list of CMIOExtensionProperty choices in CMIOExtensionProperties.h
        return [.providerManufacturer]
    }

    func connect(to _: CMIOExtensionClient) throws {
        // Handle client connect
    }

    func disconnect(from _: CMIOExtensionClient) {
        // Handle client disconnect
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let providerProperties =
            CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "OffcutsCam Manufacturer"
        }
        return providerProperties
    }

    func setProviderProperties(_: CMIOExtensionProviderProperties) throws {
        // Handle settable properties here.
    }

    // MARK: Private

    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    private var notificationListenerStarted = false

    private func notificationReceived(notificationName: String) {
        guard let name = NotificationName(rawValue: notificationName) else {
            return
        }

        switch name {
        case .changeImage:
            self.deviceSource.imageIsClean.toggle()
            logger.debug("The camera extension has received a notification")
            logger.debug("The notification is: \(name.rawValue)")
            self.deviceSource.stopStreaming()
            self.deviceSource.startStreaming()
        }
    }

    private func startNotificationListeners() {
        for notificationName in NotificationName.allCases {
            let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, name, _, _ in
                if let observer = observer, let name = name {
                    let extensionProviderSourceSelf = Unmanaged<ExtensionProviderSource>.fromOpaque(observer).takeUnretainedValue()
                    extensionProviderSourceSelf.notificationReceived(notificationName: name.rawValue as String)
                }
            },
            notificationName.rawValue as CFString, nil, .deliverImmediately)
        }
    }

    private func stopNotificationListeners() {
        if notificationListenerStarted {
            CFNotificationCenterRemoveEveryObserver(notificationCenter,
                                                    Unmanaged.passRetained(self)
                                                        .toOpaque())
            notificationListenerStarted = false
        }
    }
}
