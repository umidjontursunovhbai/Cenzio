import UIKit

/// Turns a picked photo into the small square JPEG stored on `User.photo`, and back
/// into an image. Decoded images are cached by content so list rows stay cheap.
enum ProfilePhoto {
    static let side: CGFloat = 256

    /// Center-crops to a square, scales to 256 px and encodes JPEG (about 20 KB).
    static func make(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let edge = min(size.width, size.height)
        guard edge > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let scaled = renderer.image { _ in
            let k = side / edge
            let w = size.width * k, h = size.height * k
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        }
        return scaled.jpegData(compressionQuality: 0.75)
    }

    /// Draws the `crop` square (in image points) into a 256 px JPEG.
    static func make(from image: UIImage, crop: CGRect) -> Data? {
        guard crop.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let f = side / crop.width
        let out = renderer.image { _ in
            image.draw(in: CGRect(x: -crop.minX * f, y: -crop.minY * f,
                                  width: image.size.width * f, height: image.size.height * f))
        }
        return out.jpegData(compressionQuality: 0.75)
    }

    @MainActor private static var cache: (key: Int, image: UIImage)?

    @MainActor static func image(from data: Data?) -> UIImage? {
        guard let data else { return nil }
        let key = data.hashValue
        if let cache, cache.key == key { return cache.image }
        guard let image = UIImage(data: data) else { return nil }
        cache = (key, image)
        return image
    }
}
