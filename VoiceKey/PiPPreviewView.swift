import SwiftUI
import UIKit

struct PiPPreviewView: UIViewRepresentable {
    let service: PictureInPictureService

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.backgroundColor = .black
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
        view.service = service
        service.attachPreview(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.service = service
        service.attachPreview(to: uiView)
    }

    final class PreviewHostView: UIView {
        weak var service: PictureInPictureService?

        override func layoutSubviews() {
            super.layoutSubviews()
            service?.layoutPreview(in: bounds)
        }
    }
}
