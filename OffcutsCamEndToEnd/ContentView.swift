//
//  ContentView.swift
//  OffcutsCamEndToEnd
//
//  Created by Halle Winkler on 05.08.22.
//

import CoreMediaIO
import SwiftUI

// MARK: - ContentView

struct ContentView {
    @ObservedObject var endToEndStreamProvider: EndToEndStreamProvider
    let noVideoImage = NSImage(
        systemSymbolName: "video.slash",
        accessibilityDescription: "Image to indicate no video feed available"
    )!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

extension ContentView: View {
    var body: some View {
        VStack {
            Image(
                self.endToEndStreamProvider
                    .videoExtensionStreamOutputImage ?? noVideoImage,
                scale: 1.0,
                label: Text("Video Feed")
            )
        }
    }
}

// MARK: - ContentView_Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(endToEndStreamProvider: EndToEndStreamProvider())
    }
}

// MARK: - EndToEndStreamProvider

class EndToEndStreamProvider: NSObject, ObservableObject,
    ExtensionDeviceSourceDelegate {
    // MARK: Lifecycle

    override init() {
        providerSource = ExtensionProviderSource(clientQueue: nil)
        super.init()
        providerSource
            .deviceSource = ExtensionDeviceSource(localizedName: "OffcutsCam")
        providerSource.deviceSource.extensionDeviceSourceDelegate = self
        providerSource.deviceSource.startStreaming()
    }

    // MARK: Internal

    @Published var videoExtensionStreamOutputImage: CGImage?
    let providerSource: ExtensionProviderSource

    func bufferReceived(_ buffer: CMSampleBuffer) {
        guard let cvImageBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            print("Couldn't get image buffer, returning.")
            return
        }

        guard let ioSurface = CVPixelBufferGetIOSurface(cvImageBuffer) else {
            print("Pixel buffer had no IOSurface") // The camera uses IOSurface so we want image to break if there is none.
            return
        }

        let ciImage = CIImage(ioSurface: ioSurface.takeUnretainedValue())
            .oriented(.upMirrored)

        let context = CIContext(options: nil)

        guard let cgImage = context
            .createCGImage(ciImage, from: ciImage.extent) else { return }

        DispatchQueue.main.async {
            self.videoExtensionStreamOutputImage = cgImage
        }
    }
}
