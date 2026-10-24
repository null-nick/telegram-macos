import AppKit
import ApplicationServices
import QuartzCore

struct DockIconAnimationSource {
    weak var view: NSView?
    let rect: CGRect
    let contents: Any
    var createdAt = CACurrentMediaTime()

    var isRecent: Bool { CACurrentMediaTime() - createdAt < 1.0 }

    var screenRect: CGRect? {
        guard isRecent,
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
    var screenFrames: [CGRect] = []

    var controlPoint: CGPoint {
        let distance = hypot(destination.midX - source.midX, destination.midY - source.midY)
        let highestCenter = max(source.midY, destination.midY)
        var height = highestCenter + min(110, max(36, distance * 0.14))
        if let ceiling = screenFrames.filter({
            $0.contains(CGPoint(x: source.midX, y: source.midY)) || $0.contains(CGPoint(x: destination.midX, y: destination.midY))
        }).map(\.maxY).max() {
            let clearance = max(hypot(source.width, source.height), hypot(destination.width, destination.height)) / 2 + 8
            height = max(highestCenter, min(height, ceiling - clearance))
        }
        return CGPoint(x: (source.midX + destination.midX) / 2,
                       y: height)
    }

    var duration: TimeInterval {
        let distance = hypot(destination.midX - source.midX, destination.midY - source.midY)
        return min(0.58, max(0.28, 0.24 + sqrt(Double(distance)) * 0.009))
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
        let extent = max(hypot(source.width, source.height), hypot(destination.width, destination.height)) / 2 + 2
        return path().boundingBoxOfPath.insetBy(dx: -extent, dy: -extent)
    }

    func animation(relativeTo origin: CGPoint, beginTime: CFTimeInterval) -> CAAnimationGroup {
        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path(relativeTo: origin)
        position.duration = duration
        let size = CABasicAnimation(keyPath: "bounds")
        size.fromValue = NSValue(rect: CGRect(origin: .zero, size: source.size))
        size.toValue = NSValue(rect: CGRect(origin: .zero, size: destination.size))
        size.duration = duration
        let tilt = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        tilt.values = [0, min(0.08, max(-0.08, (destination.midX - source.midX) / 6000)), 0]
        tilt.keyTimes = [0, 0.3, 1]
        tilt.duration = duration
        let group = CAAnimationGroup()
        group.animations = [position, size, tilt]
        group.duration = duration
        group.beginTime = beginTime
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.4, 0.3, 1)
        group.fillMode = .backwards
        return group
    }
}

struct DockIconLandingEffect {
    let destination: CGRect

    var diameter: CGFloat { max(destination.width, destination.height) * 1.6 }

    var bounds: CGRect {
        return CGRect(x: destination.midX - diameter / 2, y: destination.midY - diameter / 2,
                      width: diameter, height: diameter).insetBy(dx: -4, dy: -4)
    }

    func addWaves(to layer: CALayer, relativeTo origin: CGPoint, beginTime: CFTimeInterval) {
        let wave = CAShapeLayer()
        wave.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        wave.position = CGPoint(x: destination.midX - origin.x, y: destination.midY - origin.y)
        wave.path = CGPath(ellipseIn: wave.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        wave.fillColor = NSColor.clear.cgColor
        wave.strokeColor = NSColor.white.cgColor
        wave.lineWidth = 0.5
        wave.opacity = 0
        wave.contentsScale = layer.contentsScale
        wave.shadowColor = NSColor.black.cgColor
        wave.shadowOffset = CGSize(width: 0, height: -0.5)
        wave.shadowOpacity = 0.12
        wave.shadowRadius = 1
        layer.insertSublayer(wave, at: 0)

        let duration = 0.28
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = min(destination.width, destination.height) * 0.9 / diameter
        scale.toValue = 1
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.32, 0.1, 0]
        opacity.keyTimes = [0, 0.12, 0.45, 1]
        opacity.duration = duration
        let width = CABasicAnimation(keyPath: "lineWidth")
        width.fromValue = 1.4
        width.toValue = wave.lineWidth
        width.duration = duration
        let group = CAAnimationGroup()
        group.animations = [scale, opacity, width]
        group.duration = duration
        group.beginTime = beginTime
        group.fillMode = .backwards
        wave.add(group, forKey: "dockIconShockwave")
    }

    func settle(_ icon: CALayer, beginTime: CFTimeInterval) {
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [1, 1, 0]
        opacity.keyTimes = [0, 0.35, 1]
        opacity.duration = 0.18
        opacity.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        opacity.beginTime = beginTime
        opacity.fillMode = .backwards
        icon.opacity = 0
        icon.add(opacity, forKey: "dockIconLanding")
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
    private var surfaces: [(panel: NSPanel, icon: CALayer)] = []
    private var onLanding: (() -> Void)?
    private var completion: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(source: DockIconAnimationSource) {
        self.source = source
    }

    func start(onLanding: @escaping () -> Void, completion: @escaping () -> Void) {
        self.onLanding = onLanding
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
                self.animate(to: destination)
            }
        }
    }

    func cancel(animated: Bool = false) {
        onLanding = nil
        completion = nil
        removeObservers()
        guard animated, !surfaces.isEmpty, NSApplication.shared.isActive,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            removePanels()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { self.removePanels() }
        for (panel, _) in surfaces {
            guard let layer = panel.contentView?.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = 0
            fade.duration = 0.1
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.opacity = 0
            layer.add(fade, forKey: "dockIconCancellation")
        }
        CATransaction.commit()
    }

    private func animate(to rect: CGRect) {
        let screens = NSScreen.screens
        guard NSApplication.shared.isActive, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let sourceRect = source.screenRect, let primaryScreen = screens.first else {
            finish()
            return
        }
        let destination = DockIconPosition.screenRect(from: rect, primaryScreenHeight: primaryScreen.frame.maxY)
        guard AXIsProcessTrusted(), DockIconPosition.isVisible(destination, screens: screens.map(\.frame)) else {
            finish()
            return
        }
        let flight = DockIconFlightPath(source: sourceRect, destination: destination, screenFrames: screens.map(\.frame))
        let landing = DockIconLandingEffect(destination: destination)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.land(with: landing) }
        for screen in screens {
            let frame = flight.bounds.union(landing.bounds).intersection(screen.frame)
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
            view.layer?.contentsScale = screen.backingScaleFactor
            view.setAccessibilityElement(false)
            panel.contentView = view
            let layer = CALayer()
            layer.contents = source.contents
            layer.contentsGravity = .resizeAspect
            layer.contentsScale = screen.backingScaleFactor
            layer.minificationFilter = .trilinear
            layer.allowsEdgeAntialiasing = true
            layer.bounds = CGRect(origin: .zero, size: destination.size)
            layer.position = CGPoint(x: destination.midX - frame.minX, y: destination.midY - frame.minY)
            view.layer?.addSublayer(layer)
            surfaces.append((panel, layer))
        }
        let startTime = CACurrentMediaTime() + 1.0 / 120.0
        for (panel, layer) in surfaces {
            layer.add(flight.animation(relativeTo: panel.frame.origin, beginTime: startTime), forKey: "dockIconFlight")
            panel.orderFrontRegardless()
        }
        CATransaction.commit()
        if surfaces.isEmpty { finish() }
    }

    private func land(with effect: DockIconLandingEffect) {
        guard let onLanding, completion != nil else { return }
        guard NSApplication.shared.isActive, AXIsProcessTrusted(), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }
        self.onLanding = nil
        onLanding()
        guard completion != nil else { return }
        let startTime = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        for (panel, icon) in surfaces {
            guard panel.frame.intersects(effect.bounds), let layer = panel.contentView?.layer else {
                panel.orderOut(nil)
                continue
            }
            effect.addWaves(to: layer, relativeTo: panel.frame.origin, beginTime: startTime)
            effect.settle(icon, beginTime: startTime)
        }
        CATransaction.commit()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    private func finish() {
        guard let completion else { return }
        let onLanding = self.onLanding
        self.onLanding = nil
        self.completion = nil
        removePanels()
        onLanding?()
        completion()
    }

    private func removeObservers() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func removePanels() {
        removeObservers()
        for (panel, _) in surfaces {
            panel.contentView?.layer?.sublayers?.forEach { $0.removeAllAnimations() }
            panel.close()
        }
        surfaces.removeAll()
    }

    deinit {
        removePanels()
    }
}
