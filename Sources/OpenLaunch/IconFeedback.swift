import AppKit

/// One-shot icon motion and a compositor-only highlight while a launch is pending.
final class IconFeedback {
    private let image: NSImageView
    private let highlight: CALayer
    private(set) var isActive = false
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(image: NSImageView, highlight: CALayer) {
        self.image = image; self.highlight = highlight
        image.wantsLayer = true
    }

    private func transform(scale: CGFloat) -> CATransform3D {
        guard let layer = image.layer else { return CATransform3DIdentity }
        // AppKit owns the backing layer's anchor point; scale around the artwork center.
        let x = layer.bounds.width * (0.5 - layer.anchorPoint.x)
        let y = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        var value = CATransform3DMakeTranslation(x, y, 0)
        value = CATransform3DScale(value, scale, scale, 1)
        return CATransform3DTranslate(value, -x, -y, 0)
    }

    func press() {
        isActive = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        highlight.opacity = 1
        if !reduceMotion, let layer = image.layer {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
            animation.toValue = NSValue(caTransform3D: transform(scale: 0.90))
            animation.duration = 0.07
            layer.transform = transform(scale: 0.90)
            layer.add(animation, forKey: "press")
        }
        CATransaction.commit()
    }

    func launch() {
        isActive = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        highlight.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
        highlight.borderColor = NSColor.white.withAlphaComponent(0.38).cgColor
        highlight.borderWidth = 1.5; highlight.opacity = 1
        if !reduceMotion, let layer = image.layer {
            let bounce = CAKeyframeAnimation(keyPath: "transform")
            bounce.values = [layer.presentation()?.transform ?? layer.transform,
                             transform(scale: 1.12), transform(scale: 0.98), CATransform3DIdentity]
                .map { NSValue(caTransform3D: $0) }
            bounce.keyTimes = [0, 0.38, 0.75, 1]
            bounce.duration = 0.26
            bounce.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut), .init(name: .easeOut)]
            layer.removeAnimation(forKey: "press"); layer.transform = CATransform3DIdentity
            layer.add(bounce, forKey: "launch")
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.40; pulse.duration = 0.55
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            highlight.add(pulse, forKey: "launch-wait")
        }
        CATransaction.commit()
    }

    func reset() {
        isActive = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.layer?.removeAnimation(forKey: "press")
        image.layer?.removeAnimation(forKey: "launch")
        image.layer?.transform = CATransform3DIdentity
        highlight.removeAnimation(forKey: "launch-wait")
        highlight.opacity = 0; highlight.borderWidth = 0
        highlight.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        CATransaction.commit()
    }
}
