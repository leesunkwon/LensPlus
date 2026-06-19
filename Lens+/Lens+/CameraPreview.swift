import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let controller: CameraController
    let isMirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        controller.attachPreviewLayer(view.videoPreviewLayer)
        view.setMirrored(isMirrored)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        controller.attachPreviewLayer(uiView.videoPreviewLayer)
        uiView.setMirrored(isMirrored)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoPreviewLayer.frame = bounds
    }

    func setMirrored(_ isMirrored: Bool) {
        transform = isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }
}
