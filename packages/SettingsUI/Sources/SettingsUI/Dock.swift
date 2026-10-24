import AppKit

public final class Dock {
    private static let iconQueue = DispatchQueue(label: "org.telegram.custom-app-icon", qos: .utility)
    private static var iconUpdate: DispatchWorkItem?
    private static var appliedPath: String?
    private static var hasAppliedIcon = false
    private static var animationSource: (path: String?, source: DockIconAnimationSource)?
    private static var animation: DockIconAnimation?
    private static var animationPath: String?

    static func animateNextIconChange(path: String?, from view: NSView, rect: CGRect, contents: Any) {
        assert(Thread.isMainThread)
        animation?.cancel(animated: true)
        animation = nil
        animationSource = (path, DockIconAnimationSource(view: view, rect: rect, contents: contents))
    }

    public static func setCustomAppIcon(path: String?) {
        assert(Thread.isMainThread)

        if let pending = animationSource, pending.source.isRecent, pending.path != path { return }
        if animation != nil, animationPath == path { return }

        let image: NSImage?
        if let path {
            guard let customIcon = NSImage(contentsOfFile: path), customIcon.isValid else {
                return
            }
            image = customIcon
        } else {
            image = nil
        }

        animation?.cancel(animated: true)
        animation = nil
        let source = animationSource?.path == path ? animationSource?.source : nil
        animationSource = nil
        if hasAppliedIcon && appliedPath == path {
            return
        }

        if let source {
            let animation = DockIconAnimation(source: source)
            self.animation = animation
            animationPath = path
            animation.start(onLanding: { [weak animation] in
                guard let animation, self.animation === animation else { return }
                applyIcon(image, path: path)
            }, completion: { [weak animation] in
                guard let animation, self.animation === animation else { return }
                self.animation = nil
            })
        } else {
            applyIcon(image, path: path)
        }
    }

    private static func applyIcon(_ image: NSImage?, path: String?) {
        NSApplication.shared.applicationIconImage = image
        appliedPath = path
        hasAppliedIcon = true

        iconUpdate?.cancel()
        let bundlePath = Bundle.main.bundlePath
        let persistentImage = image?.copy() as? NSImage
        let update = DispatchWorkItem {
            if !NSWorkspace.shared.setIcon(persistentImage, forFile: bundlePath, options: []) {
                NSLog("Failed to persist the custom application icon at %@", bundlePath)
            }
        }
        iconUpdate = update
        iconQueue.asyncAfter(deadline: .now() + 0.2, execute: update)
    }
}
