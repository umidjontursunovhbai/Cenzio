import SwiftUI

/// Picked photo inside a circle: pinch to zoom, drag to move, then Choose saves the
/// part inside the circle as the profile photo. The photo always covers the circle.
struct ProfilePhotoCropView: View {
    let image: UIImage
    let onChoose: (Data) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width - 40, 340)
            let base = d / min(image.size.width, image.size.height)
            let k = base * scale
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: image.size.width * k, height: image.size.height * k)
                    .offset(offset)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                // dim everything outside the circle
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .mask {
                        Rectangle()
                            .overlay(Circle().frame(width: d, height: d).blendMode(.destinationOut))
                            .compositingGroup()
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                Circle()
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                    .frame(width: d, height: d)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            scale = min(5, max(1, lastScale * v.magnification))
                            offset = clamp(offset, k: base * scale, d: d)
                        }
                        .onEnded { _ in lastScale = scale; lastOffset = offset },
                    DragGesture()
                        .onChanged { v in
                            let next = CGSize(width: lastOffset.width + v.translation.width,
                                              height: lastOffset.height + v.translation.height)
                            offset = clamp(next, k: k, d: d)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
            )
            .overlay(alignment: .bottom) {
                HStack {
                    Button("cancel".localized, action: onCancel)
                    Spacer()
                    Button("account_photo_use".localized) {
                        // the circle in image points: center minus offset, side d / k
                        let side = d / k
                        let cx = image.size.width / 2 - offset.width / k
                        let cy = image.size.height / 2 - offset.height / k
                        let crop = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
                        if let data = ProfilePhoto.make(from: image, crop: crop) { onChoose(data) }
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("crop.choose")
                }
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }

    /// Keeps the photo covering the circle.
    private func clamp(_ o: CGSize, k: CGFloat, d: CGFloat) -> CGSize {
        let mx = max(0, (image.size.width * k - d) / 2)
        let my = max(0, (image.size.height * k - d) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }
}
