import AppKit
import ApplicationServices
import QuartzCore

struct DockIconAnimationSource {
    weak var view: NSView?
    let rect: CGRect
    let contents: Any
    let createdAt = CACurrentMediaTime()

    var screenRect: CGRect? {
        guard CACurrentMediaTime() - createdAt < 1.0,
              let view, !view.isHiddenOrHasHiddenAncestor,
              let window = view.window, window.isVisible, !window.isMiniaturized,
              view.visibleRect.contains(rect) else {
            return nil
        }
        return window.convertToScreen(view.convert(rect, to: nil))
    }
}

struct DockIconFlightPath {
    let source: CGRect
    let destination: CGRect

    var controlPoint: CGPoint {
        let distance = hypot(destination.midX - source.midX, destination.midY - source.midY)
        return CGPoint(x: (source.midX + destination.midX) / 2,
                       y: max(source.midY, destination.midY) + min(140, max(60, distance * 0.18)))
    }

    var duration: TimeInterval {
        let distance = hypot(destination.midX - source.midX, destination.midY - source.midY)
        return min(0.65, max(0.4, Double(distance) / 2200))
    }

    func point(at progress: CGFloat) -> CGPoint {
        let t = min(1, max(0, progress))
        let inverse = 1 - t
        return CGPoint(x: inverse * inverse * source.midX + 2 * inverse * t * controlPoint.x + t * t * destination.midX,
                       y: inverse * inverse * source.midY + 2 * inverse * t * controlPoint.y + t * t * destination.midY)
    }

    func path(relativeTo origin: CGPoint = .zero) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: source.midX - origin.x, y: source.midY - origin.y))
        path.addQuadCurve(to: CGPoint(x: destination.midX - origin.x, y: destination.midY - origin.y),
                          control: CGPoint(x: controlPoint.x - origin.x, y: controlPoint.y - origin.y))
        return path
    }

    var bounds: CGRect {
        return path().boundingBoxOfPath.insetBy(dx: -max(source.width, destination.width) / 2 - 2,
                                              dy: -max(source.height, destination.height) / 2 - 2)
    }
}

enum DockIconPosition {
    static func screenRect(from rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        return CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func isVisible(_ rect: CGRect, screens: [CGRect]) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width >= 8, rect.height >= 8, rect.width <= 512, rect.height <= 512 else {
            return false
        }
        return screens.contains(where: { $0.contains(rect) })
    }

    static func find(bundleURL: URL) -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let deadline = CACurrentMediaTime() + 0.25
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.05)
        guard let children = attribute(kAXChildrenAttribute, of: application) as? [AXUIElement] else {
            return nil
        }
        let expectedURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        for child in children {
            guard CACurrentMediaTime() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(child, 0.05)
            guard attribute(kAXRoleAttribute, of: child) as? String == kAXListRole,
                  let items = attribute(kAXChildrenAttribute, of: child) as? [AXUIElement] else {
                continue
            }
            for item in items {
                guard CACurrentMediaTime() < deadline else { return nil }
                AXUIElementSetMessagingTimeout(item, 0.05)
                guard let url = attribute(kAXURLAttribute, of: item) as? URL,
                      url.isFileURL, url.standardizedFileURL.resolvingSymlinksInPath() == expectedURL,
                      let position = attribute(kAXPositionAttribute, of: item), CFGetTypeID(position) == AXValueGetTypeID(),
                      let size = attribute(kAXSizeAttribute, of: item), CFGetTypeID(size) == AXValueGetTypeID() else {
                    continue
                }
                var point = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                      AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
                    return nil
                }
                let rect = CGRect(origin: point, size: dimensions)
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let dockWindows = windows.compactMap { window -> CGRect? in
                    guard window[kCGWindowOwnerPID as String] as? pid_t == dock.processIdentifier,
                          window[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.dockWindow)),
                          let bounds = window[kCGWindowBounds as String] as? NSDictionary else {
                        return nil
                    }
                    return CGRect(dictionaryRepresentation: bounds)
                }
                guard dockWindows.contains(where: { $0.contains(rect) }) else { return nil }
                return rect
            }
        }
        return nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

private final class DockIconAnimationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

final class DockIconAnimation {
    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let positionQueue = DispatchQueue(label: "org.telegram.dock-icon-position", qos: .userInitiated)
    private let source: DockIconAnimationSource
    private var panels: [NSPanel] = []
    private var completion: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(source: DockIconAnimationSource) {
        self.source = source
    }

    func start(image: NSImage?, completion: @escaping () -> Void) {
        self.completion = completion
        guard NSApplication.shared.isActive, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              source.screenRect != nil, AXIsProcessTrusted() else {
            finish()
            return
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            observers.append((.default, NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.finish()
            }))
        }
        observers.append((NSWorkspace.shared.notificationCenter, NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self?.finish() }
        }))
        if let window = source.view?.window {
            observers.append((.default, NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.finish()
            }))
        }
        let bundleURL = Bundle.main.bundleURL
        Self.positionQueue.async { [weak self] in
            let destination = DockIconPosition.find(bundleURL: bundleURL)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.completion != nil else { return }
                guard let destination else {
                    self.finish()
                    return
                }
                self.animate(to: destination, image: image)
            }
        }
    }

    func cancel() {
        completion = nil
        removePanels()
    }

    private func animate(to rect: CGRect, image: NSImage?) {
        guard NSApplication.shared.isActive, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let sourceRect = source.screenRect, let primaryScreen = NSScreen.screens.first else {
            finish()
            return
        }
        let destination = DockIconPosition.screenRect(from: rect, primaryScreenHeight: primaryScreen.frame.maxY)
        guard AXIsProcessTrusted(), DockIconPosition.isVisible(destination, screens: NSScreen.screens.map(\.frame)) else {
            finish()
            return
        }
        let flight = DockIconFlightPath(source: sourceRect, destination: destination)
        var imageRect = CGRect(origin: .zero, size: CGSize(width: 256, height: 256))
        let contents: Any = image?.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) ?? source.contents
        let startTime = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        for screen in NSScreen.screens {
            let frame = flight.bounds.intersection(screen.frame)
            guard !frame.isEmpty, !frame.isNull else { continue }
            let panel = DockIconAnimationPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            panel.animationBehavior = .none
            let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.setAccessibilityElement(false)
            panel.contentView = view
            let layer = CALayer()
            layer.contents = contents
            layer.contentsGravity = .resizeAspect
            layer.contentsScale = screen.backingScaleFactor
            layer.bounds = CGRect(origin: .zero, size: destination.size)
            layer.position = CGPoint(x: destination.midX - frame.minX, y: destination.midY - frame.minY)
            view.layer?.addSublayer(layer)
            let position = CAKeyframeAnimation(keyPath: "position")
            position.path = flight.path(relativeTo: frame.origin)
            position.duration = flight.duration
            let size = CABasicAnimation(keyPath: "bounds")
            size.fromValue = NSValue(rect: CGRect(origin: .zero, size: sourceRect.size))
            size.toValue = NSValue(rect: layer.bounds)
            size.duration = flight.duration
            let group = CAAnimationGroup()
            group.animations = [position, size]
            group.duration = flight.duration
            group.beginTime = startTime
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(group, forKey: "dockIconFlight")
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        CATransaction.commit()
        if panels.isEmpty { finish() }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        completion()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in removePanels() }
    }

    private func removePanels() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        for panel in panels {
            panel.contentView?.layer?.sublayers?.forEach { $0.removeAllAnimations() }
            panel.close()
        }
        panels.removeAll()
    }

    deinit {
        removePanels()
    }
}
