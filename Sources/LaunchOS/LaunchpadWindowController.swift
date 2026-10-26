import Foundation
import AppKit
import SwiftUI
import QuartzCore
import CoreImage
import UniformTypeIdentifiers

// MARK: - Private SkyLight / CoreAnimation Declarations (from LaunchOS binary 0x100009198..0x10000a210)

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSHWCaptureWindowList")
private func CGSHWCaptureWindowList(
    _ cid: UInt32,
    _ windowList: UnsafePointer<UInt32>,
    _ count: Int32,
    _ options: UInt32
) -> Unmanaged<CFArray>?

private struct CAColorMatrix {
    var m11: Float, m12: Float, m13: Float, m14: Float, m15: Float
    var m21: Float, m22: Float, m23: Float, m24: Float, m25: Float
    var m31: Float, m32: Float, m33: Float, m34: Float, m35: Float
    var m41: Float, m42: Float, m43: Float, m44: Float, m45: Float
}

/// Replicates `LaunchOS.BackgroundViewController` (`0x100005588`–`0x10000a500`)
/// Captures the active Desktop / Space's live `"Wallpaper"` window via `CGWindowListCopyWindowInfo` + `CGSHWCaptureWindowList`,
/// applies hardware-accelerated `CAFilter` (`gaussianBlur`, `colorSaturate`, `colorMatrix`), and cross-fades (`wallpaperFadeIn`, `0.36s`, `.easeInEaseOut`)
/// across Desktop/Space switches (`NSWorkspace.activeSpaceDidChangeNotification`).
public final class WallpaperBackdropController {
    public static let shared = WallpaperBackdropController()

    private let wallpaperQueue = DispatchQueue(label: "app.remixdesign.LaunchOS.wallpaper", qos: .userInitiated)
    private var requestGeneration: Int = 0
    private var spaceChangeObserver: NSObjectProtocol?
    private var cachedWallpaper: (image: CGImage?, scale: CGFloat, useBlur: Bool, blurRadius: CGFloat, generation: Int)?
    fileprivate weak var backdropView: WallpaperBackdropNSView? {
        didSet {
            if let view = backdropView, let cached = cachedWallpaper {
                view.applyWallpaperImage(
                    cached.image,
                    scale: cached.scale,
                    useBlur: cached.useBlur,
                    blurRadius: cached.blurRadius,
                    generation: cached.generation,
                    animated: false
                )
            }
        }
    }

    private init() {
        // Observe active Desktop / Space switches (`0x1000069e8`–`0x100006be4`)
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let screen = LaunchpadWindowController.shared.currentTargetScreen()
            self.refreshWallpaper(for: screen, synchronous: false, animated: true)
        }
    }

    deinit {
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    public func refreshWallpaper(for screen: NSScreen, synchronous: Bool, animated: Bool) {
        let state = AppState.shared
        guard state.backgroundType == .wallpaper else {
            backdropView?.clearWallpaperLayers()
            return
        }

        requestGeneration &+= 1
        let capturedGen = requestGeneration
        let backingScale = max(1.0, screen.backingScaleFactor)
        let blurRadius = max(0.0, state.wallpaperBlurRadius)
        let useBlur = blurRadius > 0.5
        let ownPID = ProcessInfo.processInfo.processIdentifier

        if synchronous {
            // Synchronous capture on `"app.remixdesign.LaunchOS.wallpaper"` queue (`0x100005ab4`..`0x100005da0`)
            var capturedImage: CGImage?
            let caFilterAvailable = Self.canCreateCAFilters()
            wallpaperQueue.sync {
                autoreleasepool {
                    if let rawImage = Self.captureActiveSpaceWallpaper(for: screen, excludingPID: ownPID) {
                        if useBlur && !caFilterAvailable {
                            capturedImage = Self.applyCIFilterBlur(to: rawImage, radius: blurRadius) ?? rawImage
                        } else {
                            capturedImage = rawImage
                        }
                    }
                }
            }
            guard requestGeneration == capturedGen else { return }
            cachedWallpaper = (capturedImage, backingScale, useBlur, blurRadius, capturedGen)
            backdropView?.applyWallpaperImage(
                capturedImage,
                scale: backingScale,
                useBlur: useBlur,
                blurRadius: blurRadius,
                generation: capturedGen,
                animated: false
            )
        } else {
            // Asynchronous capture + `0.36s` `wallpaperFadeIn` cross-fade (`0x1000060fc`..`0x100006984`)
            let caFilterAvailable = Self.canCreateCAFilters()
            wallpaperQueue.async { [weak self] in
                var capturedImage: CGImage?
                autoreleasepool {
                    if let rawImage = Self.captureActiveSpaceWallpaper(for: screen, excludingPID: ownPID) {
                        if useBlur && !caFilterAvailable {
                            capturedImage = Self.applyCIFilterBlur(to: rawImage, radius: blurRadius) ?? rawImage
                        } else {
                            capturedImage = rawImage
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self = self, self.requestGeneration == capturedGen else { return }
                    self.cachedWallpaper = (capturedImage, backingScale, useBlur, blurRadius, capturedGen)
                    self.backdropView?.applyWallpaperImage(
                        capturedImage,
                        scale: backingScale,
                        useBlur: useBlur,
                        blurRadius: blurRadius,
                        generation: capturedGen,
                        animated: animated
                    )
                }
            }
        }
    }

    // MARK: - Live Per-Space Wallpaper Window Capture (`0x100009ea4` & `0x100006bf8`)

    private static func captureActiveSpaceWallpaper(for screen: NSScreen, excludingPID: pid_t) -> CGImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return fallbackDesktopImage(for: screen)
        }
        let screenBounds = CGDisplayBounds(displayID)
        guard screenBounds.width > 0, screenBounds.height > 0 else {
            return fallbackDesktopImage(for: screen)
        }
        let screenArea = screenBounds.width * screenBounds.height

        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return fallbackDesktopImage(for: screen)
        }

        var bestWindowID: UInt32?
        var bestScore: Double = -Double.infinity

        for dict in windowList {
            if let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t, ownerPID == excludingPID {
                continue
            }
            guard let windowNumber = dict[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }
            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let w = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let h = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0
            let windowBounds = CGRect(x: x, y: y, width: w, height: h)

            let intersection = screenBounds.intersection(windowBounds)
            guard !intersection.isNull else { continue }
            let coverage = (intersection.width * intersection.height) / screenArea
            // Original threshold `0.90` (`0x3feccccccccccccd` at `0x100006dbc`)
            guard coverage > 0.90 else { continue }

            let windowName = dict[kCGWindowName as String] as? String ?? ""
            let hasWallpaperPrefix = windowName.hasPrefix("Wallpaper")
            let windowLayer = dict[kCGWindowLayer as String] as? Int ?? 0
            let isNegativeLayer = windowLayer < 0

            // Original scoring formula (`0x100006f38`–`0x100006f6c`):
            // `score = coverage + (hasWallpaperPrefix ? 2.0 : 0.0) + (isNegativeLayer ? 1.0 : 0.0)`
            var score = Double(coverage)
            if hasWallpaperPrefix { score += 2.0 }
            if isNegativeLayer { score += 1.0 }

            if score > bestScore {
                bestScore = score
                bestWindowID = windowNumber
            }
        }

        if var winID = bestWindowID {
            let cid = CGSMainConnectionID()
            // Hardware capture options `0x80a00` (`0x10000a204`–`0x10000a20c`)
            if let cfArray = CGSHWCaptureWindowList(cid, &winID, 1, 0x80a00)?.takeRetainedValue() as? [AnyObject],
               let first = cfArray.first {
                let cgImage = first as! CGImage
                return cgImage
            }
        }

        return fallbackDesktopImage(for: screen)
    }

    private static func fallbackDesktopImage(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let nsImage = NSImage(contentsOf: url) else {
            return nil
        }
        var rect = NSRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - CoreImage Fallback Blur (`0x1000081e8`)

    fileprivate static func applyCIFilterBlur(to image: CGImage, radius: CGFloat) -> CGImage? {
        let context = CIContext(options: [.cacheIntermediates: false])
        let ciInput = CIImage(cgImage: image)
        let clamped = ciInput.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: Double(max(2.0, radius))), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: ciInput.extent) else { return nil }
        return context.createCGImage(output, from: ciInput.extent)
    }

    // MARK: - Private CAFilter Helper (`0x100009198`–`0x1000097c0`)

    fileprivate static func canCreateCAFilters() -> Bool {
        return createCAFilter(type: "colorMatrix") != nil
    }

    fileprivate static func createCAFilter(type: String) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        guard let method = class_getClassMethod(cls, sel) else { return nil }
        typealias FilterWithTypeIMP = @convention(c) (AnyClass, Selector, NSString) -> AnyObject?
        let imp = unsafeBitCast(method_getImplementation(method), to: FilterWithTypeIMP.self)
        return imp(cls, sel, type as NSString) as? NSObject
    }

    fileprivate static func makeColorMatrixValue(isBlurred: Bool) -> NSValue {
        // `0x10000931c`–`0x100009334`: `0.7` (`0x3f333333`) when blurred, `0.8` (`0x3f4ccccd`) when unblurred
        let factor: Float = isBlurred ? 0.7 : 0.8
        var matrix = CAColorMatrix(
            m11: factor, m12: 0, m13: 0, m14: 0, m15: 0,
            m21: 0, m22: factor, m23: 0, m24: 0, m25: 0,
            m31: 0, m32: 0, m33: factor, m34: 0, m35: 0,
            m41: 0, m42: 0, m43: 0, m44: 1.0, m45: 0
        )
        return NSValue(bytes: &matrix, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
    }

    @discardableResult
    fileprivate static func configureCAFilters(
        on layer: CALayer,
        blurRadius: CGFloat,
        useBlur: Bool,
        backingScale: CGFloat
    ) -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let colorMatrixFilter = createCAFilter(type: "colorMatrix") else {
            layer.filters = nil
            layer.shouldRasterize = false
            return false
        }
        colorMatrixFilter.setValue(makeColorMatrixValue(isBlurred: useBlur), forKey: "inputColorMatrix")

        if useBlur {
            guard let saturateFilter = createCAFilter(type: "colorSaturate"),
                  let blurFilter = createCAFilter(type: "gaussianBlur") else {
                layer.filters = nil
                layer.shouldRasterize = false
                return false
            }
            // `0x100009614`: `inputAmount = 1.4` (`0x3ff6666666666666`)
            saturateFilter.setValue(NSNumber(value: 1.4), forKey: "inputAmount")
            // `0x10000966c`: `inputHardEdges = true`
            blurFilter.setValue(NSNumber(value: true), forKey: "inputHardEdges")
            // `0x1000096c0`: `inputRadius = blurRadius`
            blurFilter.setValue(NSNumber(value: Double(blurRadius)), forKey: "inputRadius")
            layer.filters = [blurFilter, saturateFilter, colorMatrixFilter]
        } else {
            layer.filters = [colorMatrixFilter]
        }

        layer.shouldRasterize = true
        layer.rasterizationScale = backingScale
        return true
    }
}

/// Double-buffered `CALayer` host view replicating `LaunchOS.BackgroundViewController` (`0x100005600`–`0x100008668`)
public final class WallpaperBackdropNSView: NSView {
    private let wallpaperContainerLayer = CALayer()
    private var primaryWallpaperLayer = CALayer()
    private var secondaryWallpaperLayer = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        guard let rootLayer = self.layer else { return }

        // Configure container layer (`0x1000076b8`–`0x100007824`)
        wallpaperContainerLayer.masksToBounds = true
        wallpaperContainerLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]

        // Configure double-buffered wallpaper layers (`0x100008fa8`–`0x100009194`)
        Self.configureWallpaperSublayer(primaryWallpaperLayer)
        Self.configureWallpaperSublayer(secondaryWallpaperLayer)
        primaryWallpaperLayer.opacity = 1.0
        secondaryWallpaperLayer.opacity = 0.0

        wallpaperContainerLayer.addSublayer(primaryWallpaperLayer)
        wallpaperContainerLayer.addSublayer(secondaryWallpaperLayer)
        rootLayer.addSublayer(wallpaperContainerLayer)

        WallpaperBackdropController.shared.backdropView = self
    }

    private static func configureWallpaperSublayer(_ layer: CALayer) {
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.actions = [
            "contents": NSNull(),
            "filters": NSNull(),
            "opacity": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
    }

    public override func layout() {
        super.layout()
        updateLayerFrames()
    }

    private func updateLayerFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        wallpaperContainerLayer.frame = b
        primaryWallpaperLayer.frame = b
        secondaryWallpaperLayer.frame = b
        CATransaction.commit()
    }

    fileprivate func clearWallpaperLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        primaryWallpaperLayer.removeAllAnimations()
        secondaryWallpaperLayer.removeAllAnimations()
        primaryWallpaperLayer.contents = nil
        secondaryWallpaperLayer.contents = nil
        primaryWallpaperLayer.opacity = 1.0
        secondaryWallpaperLayer.opacity = 0.0
        CATransaction.commit()
    }

    /// Applies captured `CGImage` to the active/inactive wallpaper layer and optionally cross-fades (`wallpaperFadeIn`, `0.36s`, `.easeInEaseOut`, `0x100007828`)
    fileprivate func applyWallpaperImage(
        _ cgImage: CGImage?,
        scale: CGFloat,
        useBlur: Bool,
        blurRadius: CGFloat,
        generation: Int,
        animated: Bool
    ) {
        guard let cgImage = cgImage else {
            clearWallpaperLayers()
            return
        }

        primaryWallpaperLayer.removeAllAnimations()
        secondaryWallpaperLayer.removeAllAnimations()

        let hasExistingContents = (primaryWallpaperLayer.contents != nil)
        let targetLayer = hasExistingContents ? secondaryWallpaperLayer : primaryWallpaperLayer

        WallpaperBackdropController.configureCAFilters(
            on: targetLayer,
            blurRadius: blurRadius,
            useBlur: useBlur,
            backingScale: scale
        )

        if hasExistingContents {
            let oldPrimary = primaryWallpaperLayer
            let newLayer = secondaryWallpaperLayer

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            newLayer.removeAllAnimations()
            newLayer.contents = cgImage
            newLayer.contentsScale = scale
            newLayer.frame = bounds
            newLayer.opacity = 1.0
            oldPrimary.opacity = 1.0
            wallpaperContainerLayer.insertSublayer(newLayer, above: oldPrimary)
            CATransaction.commit()

            if animated {
                // `0x100007a10`–`0x100007bb8`: `CABasicAnimation(keyPath: "opacity")` `"wallpaperFadeIn"`, `0.36s`, `.easeInEaseOut`
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = NSNumber(value: 0)
                fade.toValue = NSNumber(value: 1)
                fade.duration = 0.36
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self, weak oldPrimary, weak newLayer] in
                    guard let self = self,
                          let oldPrimary = oldPrimary,
                          let newLayer = newLayer,
                          self.primaryWallpaperLayer === oldPrimary else { return }
                    self.finalizeLayerSwap(oldPrimary: oldPrimary, newPrimary: newLayer)
                }
                newLayer.add(fade, forKey: "wallpaperFadeIn")
                CATransaction.commit()
            } else {
                // Immediate swap (`0x100007cfc` / `0x100007ea0`)
                finalizeLayerSwap(oldPrimary: oldPrimary, newPrimary: newLayer)
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            primaryWallpaperLayer.contents = cgImage
            primaryWallpaperLayer.contentsScale = scale
            primaryWallpaperLayer.frame = bounds
            primaryWallpaperLayer.opacity = 1.0
            secondaryWallpaperLayer.contents = nil
            secondaryWallpaperLayer.opacity = 0.0
            CATransaction.commit()
        }
    }

    private func finalizeLayerSwap(oldPrimary: CALayer, newPrimary: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newPrimary.removeAllAnimations()
        oldPrimary.removeAllAnimations()
        oldPrimary.contents = nil
        oldPrimary.opacity = 0.0
        primaryWallpaperLayer = newPrimary
        secondaryWallpaperLayer = oldPrimary
        CATransaction.commit()
    }
    fileprivate var lastBlurRadius: CGFloat = -1
    fileprivate var lastBackgroundType: BackgroundStyleType? = nil
}

public struct WallpaperBackdropRepresentable: NSViewRepresentable {
    public var blurRadius: CGFloat
    public var backgroundType: BackgroundStyleType

    public func makeNSView(context: Context) -> WallpaperBackdropNSView {
        let view = WallpaperBackdropNSView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        view.lastBlurRadius = blurRadius
        view.lastBackgroundType = backgroundType
        if WallpaperBackdropController.shared.backdropView == nil {
            WallpaperBackdropController.shared.backdropView = view
        }
        return view
    }

    public func updateNSView(_ nsView: WallpaperBackdropNSView, context: Context) {
        if WallpaperBackdropController.shared.backdropView !== nsView {
            WallpaperBackdropController.shared.backdropView = nsView
        }
        if nsView.lastBlurRadius != blurRadius || nsView.lastBackgroundType != backgroundType {
            nsView.lastBlurRadius = blurRadius
            nsView.lastBackgroundType = backgroundType
            let screen = LaunchpadWindowController.shared.currentTargetScreen()
            WallpaperBackdropController.shared.refreshWallpaper(for: screen, synchronous: false, animated: false)
        }
    }
}

/// Replicates `AlwaysKeyPanel` from LaunchOS binary (`LaunchpadWindowController.swift`)
/// Overrides `constrainFrameRect` so macOS never clips the fullscreen panel to avoid MenuBar or Dock.
public final class AlwaysKeyPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if AppState.shared.displayMode == .fullScreen {
            return screen?.frame ?? frameRect
        }
        return super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Observable pager & window transition state replicating LaunchOS binary's `CAAnimationGroup` parameters:
/// - Show: duration `0.24s * (1 - alpha)`, timing `.easeOut`, foreground scale `1.05 -> 1.0`, opacity `0.0 -> 1.0`
/// - Hide: duration `0.24s * alpha`, timing `.easeOut`, foreground scale `1.0 -> 1.05`, opacity `1.0 -> 0.0`
public final class PagerInteractionState: ObservableObject {
    public static let shared = PagerInteractionState()
    @Published public var dragOffset: CGFloat = 0
    @Published public var isDragging: Bool = false
    @Published public var transitionScale: CGFloat = 1.0
    @Published public var transitionOpacity: Double = 1.0
    private init() {}
}

/// Window transition state machine (`0 = idle`, `1 = showing`, `2 = hiding` at offset `0xb88` in original binary)
public enum WindowTransitionState: UInt8 {
    case idle = 0
    case showing = 1
    case hiding = 2
}

/// Replicates `LaunchpadWindowController` from LaunchOS binary (`LaunchpadWindowController.swift`)
public final class LaunchpadWindowController: NSObject, NSWindowDelegate {
    public static let shared = LaunchpadWindowController()

    /// Base transition duration `0.24` (`0x3fceb851eb851eb8` in `LaunchOS` binary at `0x1000155d8` / `0x1000164f0`)
    private static let baseTransitionDuration: TimeInterval = 0.24
    /// Zoom-out scale factor `1.05` (`0x3ff0cccccccccccd` in `LaunchOS` binary at `0x100016858` / `0x100017268`)
    private static let hiddenForegroundScale: CGFloat = 1.05

    public private(set) var panel: AlwaysKeyPanel?
    public private(set) var isVisible: Bool = false
    public private(set) var transitionState: WindowTransitionState = .idle
    private var animationGeneration: UInt64 = 0
    private var lastShowDate: Date = .distantPast
    private var lastHideDate: Date = .distantPast
    private var desktopWallpaperImage: NSImage?

    private override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.launchos.debug.openFirstFolder"),
            object: nil,
            queue: .main
        ) { _ in
            if let folder = ApplicationManager.shared.allGroups.first(where: { $0.isFolder }) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    ApplicationManager.shared.openedFolderID = folder.id
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.launchos.debug.closeFolder"),
            object: nil,
            queue: .main
        ) { _ in
            withAnimation(.easeInOut(duration: 0.28)) {
                ApplicationManager.shared.openedFolderID = nil
            }
        }
    }

    public func setupWindowIfNeeded() {
        guard panel == nil else { return }
        let screen = targetScreen()
        let mode = AppState.shared.displayMode
        let rect = windowFrame(for: screen, mode: mode)

        let styleMask: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        let newPanel = AlwaysKeyPanel(
            contentRect: rect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.animationBehavior = .none
        newPanel.appearance = NSAppearance(named: .darkAqua)
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = (mode == .window)
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovable = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        newPanel.acceptsMouseMovedEvents = true
        newPanel.delegate = self

        let rootView = LaunchpadRootView()
            .ignoresSafeArea(.all)
        let hostingView = ScrollWheelInterceptingHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: rect.size)
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        newPanel.contentView = hostingView

        self.panel = newPanel
    }

    public func reconfigureWindowMode() {
        guard let panel = panel else { return }
        let screen = targetScreen()
        let mode = AppState.shared.displayMode
        let rect = windowFrame(for: screen, mode: mode)

        panel.hasShadow = (mode == .window)
        panel.level = windowLevel(for: mode)
        panel.setFrame(rect, display: true, animate: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: rect.size)
    }

    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    public func show() {
        setupWindowIfNeeded()
        guard let panel = panel else { return }
        if isVisible && transitionState == .showing {
            return
        }

        let appMgr = ApplicationManager.shared
        let pager = PagerInteractionState.shared
        if !panel.isVisible,
           let delay = AppState.shared.returnToHome.seconds,
           Date().timeIntervalSince(lastHideDate) >= delay {
            AppState.shared.currentPage = 0
            appMgr.openedFolderID = nil
            appMgr.currentSearchQuery = ""
            appMgr.isUninstallJiggleMode = false
            appMgr.selectedGroupIDs.removeAll()
        }
        pager.dragOffset = 0
        pager.isDragging = false

        captureCurrentWallpaper()
        let screen = targetScreen()
        let mode = AppState.shared.displayMode
        let rect = windowFrame(for: screen, mode: mode)

        panel.level = windowLevel(for: mode)
        panel.hasShadow = (mode == .window)
        panel.setFrame(rect, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: rect.size)

        // Compute current alpha and proportional duration `0.24 * (1.0 - currentAlpha)` (`0x1000155d0` / `0x100015a68`)
        let wasVisible = panel.isVisible && transitionState == .hiding
        let startAlpha: CGFloat = wasVisible ? max(0.0, min(1.0, panel.alphaValue)) : 0.0
        let duration = max(0.06, Self.baseTransitionDuration * Double(1.0 - startAlpha))

        animationGeneration &+= 1
        let capturedGen = animationGeneration
        transitionState = .showing
        isVisible = true
        lastShowDate = Date()

        if !wasVisible {
            panel.alphaValue = 0.0
            pager.transitionScale = Self.hiddenForegroundScale
            pager.transitionOpacity = 0.0
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        // Animate foreground scale `1.05 -> 1.0` & opacity `0.0 -> 1.0` (`0x100015d78`..`0x100015f70`)
        withAnimation(.easeOut(duration: duration)) {
            pager.transitionScale = 1.0
            pager.transitionOpacity = 1.0
        }

        // Animate window & background backdrop opacity `0.0 -> 1.0` (`0x100015668` / `0x100015c68`)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            guard let self = self,
                  self.transitionState == .showing,
                  self.animationGeneration == capturedGen else { return }
            self.transitionState = .idle
            panel.alphaValue = 1.0
        })
    }

    public func hide(completion: (() -> Void)? = nil) {
        guard let panel = panel, (isVisible || transitionState == .showing) else {
            completion?()
            return
        }

        let pager = PagerInteractionState.shared
        let startAlpha: CGFloat = max(0.05, min(1.0, panel.alphaValue))
        // Proportional fade-out duration `0.24 * currentAlpha` (`0x1000161a8` / `0x1000164f0`)
        let duration = max(0.06, Self.baseTransitionDuration * Double(startAlpha))

        animationGeneration &+= 1
        let capturedGen = animationGeneration
        transitionState = .hiding
        isVisible = false
        lastHideDate = Date()

        ApplicationManager.shared.isUninstallJiggleMode = false
        pager.dragOffset = 0
        pager.isDragging = false

        // Animate foreground scale `1.0 -> 1.05` & opacity `1.0 -> 0.0` (`0x1000167f0`..`0x100016a08`)
        withAnimation(.easeOut(duration: duration)) {
            pager.transitionScale = Self.hiddenForegroundScale
            pager.transitionOpacity = 0.0
        }

        // Animate window & background backdrop opacity `1.0 -> 0.0` (`0x1000161f0` / `0x100016664`),
        // then `orderOut(nil)` in completion handler (`0x1000171d8`..`0x100017310`)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            guard let self = self,
                  self.transitionState == .hiding,
                  self.animationGeneration == capturedGen else { return }
            self.transitionState = .idle
            panel.alphaValue = 0.0
            panel.orderOut(nil)
            completion?()
        })
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard Date().timeIntervalSince(lastShowDate) > 0.5 else { return }
        let uninstallerVisible = UninstallWindowController.shared.window?.isVisible ?? false
        let prefsVisible = PreferencesWindowController.shared.window?.isVisible ?? false
        let reorgVisible = ReorganizeLayoutWindowController.shared.window?.isVisible ?? false
        if isVisible && !uninstallerVisible && !prefsVisible && !reorgVisible && !NSApp.isActive {
            hide()
        }
    }

    public var currentWallpaper: NSImage? {
        desktopWallpaperImage
    }

    private func windowLevel(for mode: DisplayMode) -> NSWindow.Level {
        if mode == .fullScreen {
            // Above MenuBar (24) and Dock (20) so all 4 edges are completely covered
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        } else {
            return .floating
        }
    }

    private func captureCurrentWallpaper() {
        let screen = targetScreen()
        WallpaperBackdropController.shared.refreshWallpaper(for: screen, synchronous: true, animated: false)
    }

    public func currentTargetScreen() -> NSScreen {
        if let panelScreen = panel?.screen {
            return panelScreen
        }
        return targetScreen()
    }

    private func targetScreen() -> NSScreen {
        switch AppState.shared.showOn {
        case .cursor, .active:
            let mouseLoc = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first!
        case .primary, .dock:
            return NSScreen.screens.first ?? NSScreen.main!
        }
    }

    private func windowFrame(for screen: NSScreen, mode: DisplayMode) -> NSRect {
        switch mode {
        case .fullScreen:
            return screen.frame
        case .window:
            let visible = screen.visibleFrame
            let width = round(min(max(visible.width * 0.80, 980), 1480))
            let height = round(min(max(visible.height * 0.82, 680), 960))
            let x = round(visible.origin.x + (visible.width - width) / 2.0)
            let y = round(visible.origin.y + (visible.height - height) / 2.0)
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }
}

/// Captures two-finger horizontal/vertical scroll wheel gestures on macOS trackpad & mouse wheel for interactive animated page switching
public final class ScrollWheelInterceptingHostingView<Content: View>: NSHostingView<Content> {
    private var accumulatedDelta: CGFloat = 0
    private var lastDiscreteTurnTime: Date = .distantPast
    private var gestureHasTurnedPage: Bool = false

    public override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)

        let state = AppState.shared
        let appMgr = ApplicationManager.shared
        let pager = PagerInteractionState.shared

        guard state.browsingStyle == .paged,
              appMgr.currentSearchQuery.isEmpty,
              appMgr.openedFolderID == nil else {
            return
        }

        let totalPages = max(1, appMgr.totalPages)

        if event.hasPreciseScrollingDeltas {
            // Continuous trackpad two-finger swipe with live drag offset
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX
                : event.scrollingDeltaY

            switch event.phase {
            case .began:
                accumulatedDelta = 0
                gestureHasTurnedPage = false
                pager.isDragging = true
                pager.dragOffset = 0

            case .changed:
                guard !gestureHasTurnedPage else { return }
                accumulatedDelta += delta

                // Apply rubber-band resistance on first and last page
                let atFirst = state.currentPage <= 0 && accumulatedDelta > 0
                let atLast = state.currentPage >= totalPages - 1 && accumulatedDelta < 0
                let resistance: CGFloat = (atFirst || atLast) ? 0.25 : 1.0
                pager.dragOffset = accumulatedDelta * resistance

                let triggerThreshold: CGFloat = 46.0
                if accumulatedDelta < -triggerThreshold && state.currentPage < totalPages - 1 {
                    gestureHasTurnedPage = true
                    pager.isDragging = false
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        pager.dragOffset = 0
                        state.currentPage += 1
                    }
                } else if accumulatedDelta > triggerThreshold && state.currentPage > 0 {
                    gestureHasTurnedPage = true
                    pager.isDragging = false
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        pager.dragOffset = 0
                        state.currentPage -= 1
                    }
                }

            case .ended, .cancelled:
                if !gestureHasTurnedPage {
                    let commitThreshold: CGFloat = 18.0
                    let targetPage: Int
                    if accumulatedDelta < -commitThreshold && state.currentPage < totalPages - 1 {
                        targetPage = state.currentPage + 1
                    } else if accumulatedDelta > commitThreshold && state.currentPage > 0 {
                        targetPage = state.currentPage - 1
                    } else {
                        targetPage = state.currentPage
                    }
                    pager.isDragging = false
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        pager.dragOffset = 0
                        state.currentPage = targetPage
                    }
                }
                accumulatedDelta = 0
                gestureHasTurnedPage = false

            default:
                break
            }
        } else {
            // Discrete mouse scroll wheel
            guard Date().timeIntervalSince(lastDiscreteTurnTime) > 0.20 else { return }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX
                : event.scrollingDeltaY
            if delta < -0.3 && state.currentPage < totalPages - 1 {
                lastDiscreteTurnTime = Date()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    state.currentPage += 1
                }
            } else if delta > 0.3 && state.currentPage > 0 {
                lastDiscreteTurnTime = Date()
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    state.currentPage -= 1
                }
            }
        }
    }
}

/// Visual Effect wrapper replicating `BackgroundViewController`
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Main Launchpad interactive interface replicating `LaunchpadContentView`, `LaunchpadAppView`, `LaunchpadFolderView`
public struct LaunchpadRootView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @ObservedObject var pager = PagerInteractionState.shared
    @FocusState private var isSearchFocused: Bool
    @LocalState private var draggedGroupID: String? = nil
    @LocalState private var dropTargetGroupID: String? = nil

    public var body: some View {
        GeometryReader { geo in
            let cols = max(4, state.columnsPerPage)
            let rows = max(3, state.rowsPerPage)
            let pageCount = max(1, appManager.totalPages)
            let isFullScreen = (state.displayMode == .fullScreen)

            let topHeaderHeight: CGFloat = isFullScreen ? 106 : 80
            let bottomFooterHeight: CGFloat = isFullScreen ? 84 : 64
            let gridAreaHeight = max(320, geo.size.height - topHeaderHeight - bottomFooterHeight)

            ZStack {
                // 1. Edge-to-Edge Fullscreen Background Layer (No vignette/border gap; opacity-only fade)
                backgroundLayer(size: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(pager.transitionOpacity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBlankAreaTap()
                    }

                // 2. Symmetrical Main Foreground Layout (1.0 <-> 1.05 scale + opacity fade matching original LaunchOS)
                VStack(spacing: 0) {
                    // Top Bar: Search Bar strictly centered in ZStack; controls symmetric on right
                    topBarView(width: geo.size.width, isFullScreen: isFullScreen)
                        .frame(width: geo.size.width, height: topHeaderHeight)

                    // 3. Grid Content (Animated Horizontal Pager, Dedicated Search Results Grid, or Symmetrical Vertical Scroll)
                    ZStack {
                        if appManager.filteredGroups.isEmpty {
                            emptySearchPlaceholder
                        } else if !appManager.currentSearchQuery.isEmpty {
                            searchResultsGridContent(
                                cols: cols,
                                rows: rows,
                                containerWidth: geo.size.width,
                                gridHeight: gridAreaHeight
                            )
                        } else if state.browsingStyle == .paged {
                            animatedPagedGridContent(
                                cols: cols,
                                rows: rows,
                                pageCount: pageCount,
                                containerWidth: geo.size.width,
                                gridHeight: gridAreaHeight
                            )
                        } else {
                            verticalScrollGridContent(
                                cols: cols,
                                rows: rows,
                                containerWidth: geo.size.width,
                                gridHeight: gridAreaHeight
                            )
                        }

                        if !appManager.selectedGroupIDs.isEmpty {
                            VStack {
                                multiSelectToolbar
                                    .padding(.top, 4)
                                Spacer()
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: gridAreaHeight)

                    // 4. Strictly Centered Bottom Page Dots
                    bottomBarView(pageCount: pageCount)
                        .frame(width: geo.size.width, height: bottomFooterHeight)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect((appManager.openedFolderID != nil ? 0.94 : 1.0) * pager.transitionScale, anchor: .center)
                .opacity((appManager.openedFolderID != nil ? 0.001 : 1.0) * pager.transitionOpacity)
                .allowsHitTesting(appManager.openedFolderID == nil)
                .animation(.easeInOut(duration: 0.28), value: appManager.openedFolderID != nil)

                // 5. Opened Folder Overlay (`LaunchpadContentView+Folder.swift` `0x10011c578`–`0x100128488`)
                if let folderID = appManager.openedFolderID,
                   let folder = appManager.allGroups.first(where: { $0.id == folderID }) {
                    OpenedFolderOverlayView(
                        group: folder,
                        containerSize: geo.size,
                        gridAreaHeight: gridAreaHeight
                    )
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 0 : 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isFullScreen ? 0 : 24, style: .continuous)
                    .stroke(Color.white.opacity(isFullScreen ? 0 : 0.22), lineWidth: isFullScreen ? 0 : 1)
            )
            .onChange(of: pageCount) { _, newPageCount in
                if state.currentPage >= newPageCount {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        state.currentPage = max(0, newPageCount - 1)
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFocused = true
                }
            }
        }
        .ignoresSafeArea(.all)
    }

    // MARK: - Blank Area Click Dismissal Handler
    private func handleBlankAreaTap() {
        if appManager.openedFolderID != nil {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                appManager.openedFolderID = nil
            }
        } else if appManager.isUninstallJiggleMode {
            appManager.isUninstallJiggleMode = false
        } else if !appManager.selectedGroupIDs.isEmpty {
            appManager.selectedGroupIDs.removeAll()
        } else {
            LaunchpadWindowController.shared.hide()
        }
    }

    // MARK: - Edge-to-Edge Background Layer
    /// Replicates `LaunchOS.BackgroundViewController` (`0x100005588`–`0x10000a500`):
    /// - Captures live per-Space `"Wallpaper"` window via `CGWindowListCopyWindowInfo` + `CGSHWCaptureWindowList`
    /// - Applies `CAFilter` (`gaussianBlur` with `inputHardEdges = true`, `colorSaturate = 1.4`, `colorMatrix = 0.7/0.8`)
    /// - Cross-fades (`wallpaperFadeIn`, `0.36s`, `.easeInEaseOut`) when switching Desktops/Spaces (`NSWorkspace.activeSpaceDidChangeNotification`)
    @ViewBuilder
    private func backgroundLayer(size: CGSize) -> some View {
        ZStack {
            VisualEffectBackground(
                material: state.glassMaterial.nsMaterial,
                blendingMode: .behindWindow
            )
            .frame(width: size.width, height: size.height)

            if state.backgroundType == .wallpaper {
                WallpaperBackdropRepresentable(
                    blurRadius: state.wallpaperBlurRadius,
                    backgroundType: state.backgroundType
                )
                .frame(width: size.width, height: size.height)
            } else {
                Color.black.opacity(0.22)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea(.all)
    }

    // MARK: - Strictly Symmetrical Top Bar
    private func topBarView(width: CGFloat, isFullScreen: Bool) -> some View {
        let horizontalMargin = round(max(48.0, width * 0.085))
        return ZStack(alignment: .top) {
            // Blank space in top bar dismisses LaunchOS
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleBlankAreaTap()
                }

            // Controls shifted downwards for notch / top bezel clearance
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: isFullScreen ? 48 : 24)

                ZStack {
                    // Center: Search Input Box at exact horizontal center of screen
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white.opacity(0.75))
                            .font(.system(size: 13, weight: .medium))

                        TextField("搜索应用", text: $appManager.currentSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .focused($isSearchFocused)
                            .onSubmit {
                                appManager.launchSelectedSearchApp()
                            }

                        if !appManager.currentSearchQuery.isEmpty {
                            Button {
                                appManager.currentSearchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 260, height: 32)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                            )
                    )

                    // Left & Right symmetric action bar aligned with grid margins
                    HStack(spacing: 10) {
                        // Left: Page / App count badge for visual balance
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.3x3.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(appManager.allGroups.reduce(0) { $0 + $1.apps.count }) 个应用")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.10)))

                        Spacer()
                            .allowsHitTesting(false)

                        // Right: Quick Action Buttons
                        HStack(spacing: 10) {
                            Button {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    state.browsingStyle = (state.browsingStyle == .paged) ? .scroll : .paged
                                }
                            } label: {
                                Image(systemName: state.browsingStyle == .paged ? "rectangle.grid.3x2" : "scroll")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("切换分页 / 垂直滚动模式")

                            Button {
                                state.displayMode = (state.displayMode == .fullScreen) ? .window : .fullScreen
                                LaunchpadWindowController.shared.reconfigureWindowMode()
                            } label: {
                                Image(systemName: state.displayMode == .fullScreen ? "macwindow" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("切换全屏 / 悬浮窗口模式")

                            Button {
                                ReorganizeLayoutWindowController.shared.showWindow()
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("智能整理布局")

                            Button {
                                PreferencesWindowController.shared.showWindow()
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .help("打开 LaunchPad 偏好设置")
                        }
                    }
                    .padding(.horizontal, horizontalMargin)
                }

                Spacer()
            }
        }
    }

    // MARK: - Multi-Select Action Bar
    private var multiSelectToolbar: some View {
        HStack(spacing: 14) {
            Label("已选中 \(appManager.selectedGroupIDs.count) 项", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)

            Button("合并新建文件夹") {
                appManager.createFolder(withGroupIDs: appManager.selectedGroupIDs)
            }
            .buttonStyle(.borderedProminent)
            .disabled(appManager.selectedGroupIDs.count < 2)

            Button("取消选择") {
                appManager.selectedGroupIDs.removeAll()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    // MARK: - Empty Search State
    private var emptySearchPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.white.opacity(0.40))
            Text("暂无结果")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Text("未找到与“\(appManager.currentSearchQuery)”匹配的应用程序")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            handleBlankAreaTap()
        }
    }

    // MARK: - Animated Horizontal Sliding Pager with Symmetric Fixed Matrix
    private func animatedPagedGridContent(
        cols: Int,
        rows: Int,
        pageCount: Int,
        containerWidth: CGFloat,
        gridHeight: CGFloat
    ) -> some View {
        let safePage = min(max(0, state.currentPage), pageCount - 1)
        let horizontalMargin = round(max(48.0, containerWidth * 0.085))
        let usableWidth = max(400.0, containerWidth - horizontalMargin * 2)
        let cellWidth = usableWidth / CGFloat(cols)
        let cellHeight = gridHeight / CGFloat(rows)

        return HStack(spacing: 0) {
            ForEach(0..<pageCount, id: \.self) { pageIndex in
                let pageGroups = appManager.groups(forPage: pageIndex)
                symmetricPageMatrix(
                    pageGroups: pageGroups,
                    cols: cols,
                    rows: rows,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    horizontalMargin: horizontalMargin
                )
                .frame(width: containerWidth, height: gridHeight)
            }
        }
        .frame(width: containerWidth * CGFloat(pageCount), height: gridHeight, alignment: .leading)
        .offset(x: -CGFloat(safePage) * containerWidth + pager.dragOffset)
        .animation(
            pager.isDragging
                ? .interactiveSpring(response: 0.15, dampingFraction: 0.95)
                : .spring(response: 0.38, dampingFraction: 0.86),
            value: safePage
        )
        .animation(
            .interactiveSpring(response: 0.15, dampingFraction: 0.95),
            value: pager.dragOffset
        )
        .frame(width: containerWidth, height: gridHeight, alignment: .leading)
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    pager.isDragging = true
                    let atFirst = safePage <= 0 && value.translation.width > 0
                    let atLast = safePage >= pageCount - 1 && value.translation.width < 0
                    pager.dragOffset = value.translation.width * ((atFirst || atLast) ? 0.25 : 1.0)
                }
                .onEnded { value in
                    pager.isDragging = false
                    let threshold: CGFloat = max(45.0, containerWidth * 0.05)
                    var nextPage = safePage
                    let predicted = value.predictedEndTranslation.width
                    let translation = value.translation.width
                    if (predicted < -threshold || translation < -threshold) && safePage < pageCount - 1 {
                        nextPage = safePage + 1
                    } else if (predicted > threshold || translation > threshold) && safePage > 0 {
                        nextPage = safePage - 1
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                        pager.dragOffset = 0
                        state.currentPage = nextPage
                    }
                }
        )
    }

    /// Renders an exact `rows × cols` matrix where every slot has identical `(cellWidth, cellHeight)`
    /// and only the tight icon+label region inside each slot captures app clicks; all surrounding blank space exits LaunchOS.
    @ViewBuilder
    private func symmetricPageMatrix(
        pageGroups: [LaunchpadGroup],
        cols: Int,
        rows: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        horizontalMargin: CGFloat
    ) -> some View {
        ZStack {
            // Blank space in horizontal margins & between cells dismisses LaunchOS
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleBlankAreaTap()
                }

            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<cols, id: \.self) { c in
                            let idx = r * cols + c
                            ZStack(alignment: .center) {
                                Color.white.opacity(0.001)
                                    .frame(width: cellWidth, height: cellHeight)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleBlankAreaTap()
                                    }

                                if idx < pageGroups.count {
                                    gridCell(for: pageGroups[idx])
                                }
                            }
                            .frame(width: cellWidth, height: cellHeight)
                        }
                    }
                    .frame(height: cellHeight)
                }
            }
            .padding(.horizontal, horizontalMargin)
        }
    }

    // MARK: - Search Results Dedicated Grid View (Native LaunchOS Symmetrical Layout)
    private func searchResultsGridContent(
        cols: Int,
        rows: Int,
        containerWidth: CGFloat,
        gridHeight: CGFloat
    ) -> some View {
        let horizontalMargin = round(max(48.0, containerWidth * 0.085))
        let usableWidth = max(400.0, containerWidth - horizontalMargin * 2)
        let cellWidth = usableWidth / CGFloat(cols)
        let cellHeight = gridHeight / CGFloat(rows)
        let allItems = appManager.filteredGroups
        let totalRows = Int(ceil(Double(allItems.count) / Double(cols)))
        let needsScroll = totalRows > rows

        return ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .top) {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBlankAreaTap()
                    }

                VStack(spacing: 0) {
                    ForEach(0..<totalRows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<cols, id: \.self) { c in
                                let idx = r * cols + c
                                ZStack(alignment: .center) {
                                    Color.white.opacity(0.001)
                                        .frame(width: cellWidth, height: cellHeight)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            handleBlankAreaTap()
                                        }

                                    if idx < allItems.count {
                                        gridCell(for: allItems[idx])
                                    }
                                }
                                .frame(width: cellWidth, height: cellHeight)
                            }
                        }
                        .frame(height: cellHeight)
                    }
                }
                .padding(.horizontal, horizontalMargin)
            }
            .frame(minHeight: gridHeight, alignment: .top)
        }
        .frame(width: containerWidth, height: gridHeight)
        .disabled(!needsScroll)
    }

    // MARK: - Vertical Scroll Grid Content (Symmetrical Margins)
    private func verticalScrollGridContent(
        cols: Int,
        rows: Int,
        containerWidth: CGFloat,
        gridHeight: CGFloat
    ) -> some View {
        let horizontalMargin = round(max(48.0, containerWidth * 0.085))
        let usableWidth = max(400.0, containerWidth - horizontalMargin * 2)
        let cellWidth = usableWidth / CGFloat(cols)
        let cellHeight = gridHeight / CGFloat(rows)
        let allItems = appManager.filteredGroups
        let totalRows = Int(ceil(Double(allItems.count) / Double(cols)))

        return ScrollView(.vertical, showsIndicators: true) {
            ZStack {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBlankAreaTap()
                    }

                VStack(spacing: 0) {
                    ForEach(0..<totalRows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<cols, id: \.self) { c in
                                let idx = r * cols + c
                                ZStack(alignment: .center) {
                                    Color.white.opacity(0.001)
                                        .frame(width: cellWidth, height: cellHeight)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            handleBlankAreaTap()
                                        }

                                    if idx < allItems.count {
                                        gridCell(for: allItems[idx])
                                    }
                                }
                                .frame(width: cellWidth, height: cellHeight)
                            }
                        }
                        .frame(height: cellHeight)
                    }
                }
                .padding(.horizontal, horizontalMargin)
                .padding(.vertical, 12)
            }
            .frame(minHeight: gridHeight, alignment: .top)
        }
        .frame(width: containerWidth, height: gridHeight)
    }

    // MARK: - Individual Grid Cell (Single App Group or Folder Group)
    @ViewBuilder
    private func gridCell(for group: LaunchpadGroup) -> some View {
        Group {
            if group.isFolder {
                LaunchpadFolderCellView(
                    group: group,
                    isDropTarget: dropTargetGroupID == group.id
                )
            } else if let app = group.primaryApp {
                LaunchpadAppCellView(
                    group: group,
                    app: app,
                    isDropTarget: dropTargetGroupID == group.id
                )
            }
        }
        .onDrag {
            self.draggedGroupID = group.id
            return NSItemProvider(object: group.id as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: GridGroupDropDelegate(
                targetGroupID: group.id,
                draggedGroupID: $draggedGroupID,
                dropTargetGroupID: $dropTargetGroupID
            )
        )
    }

    // MARK: - Bottom Page Indicator Dots
    @ViewBuilder
    private func bottomBarView(pageCount: Int) -> some View {
        ZStack {
            // Blank space in bottom bar dismisses LaunchOS
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleBlankAreaTap()
                }

            if state.browsingStyle == .paged && appManager.currentSearchQuery.isEmpty && pageCount > 1 {
                HStack(spacing: 10) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == state.currentPage ? Color.white : Color.white.opacity(0.32))
                            .frame(width: 8, height: 8)
                            .scaleEffect(index == state.currentPage ? 1.18 : 1.0)
                            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: state.currentPage)
                            .contentShape(Rectangle().inset(by: -6))
                            .onTapGesture {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                    state.currentPage = index
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.22)))
            }
        }
    }
}

/// Drop delegate supporting drag-and-drop reorder and folder creation
struct GridGroupDropDelegate: DropDelegate {
    let targetGroupID: String
    @Binding var draggedGroupID: String?
    @Binding var dropTargetGroupID: String?

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedGroupID, dragged != targetGroupID else { return }
        dropTargetGroupID = targetGroupID
    }

    func dropExited(info: DropInfo) {
        if dropTargetGroupID == targetGroupID {
            dropTargetGroupID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dropTargetGroupID = nil
            draggedGroupID = nil
        }
        guard let dragged = draggedGroupID, dragged != targetGroupID else { return false }

        let modifiers = NSEvent.modifierFlags
        let targetIsFolder = ApplicationManager.shared.allGroups.first(where: { $0.id == targetGroupID })?.isFolder ?? false
        let mergeIntoFolder = targetIsFolder || modifiers.contains(.command) || modifiers.contains(.shift)

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            ApplicationManager.shared.moveGroup(
                draggedID: dragged,
                toTargetID: targetGroupID,
                mergeIntoFolder: mergeIntoFolder
            )
        }
        return true
    }
}

/// Replicates `LaunchpadAppView` with tight icon+label hit-test region, hover, jiggle animation, multi-select, and context menu
public struct LaunchpadAppCellView: View {
    public let group: LaunchpadGroup
    public let app: LaunchpadApp
    public var isDropTarget: Bool = false

    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @LocalState private var isHovered: Bool = false

    private let iconDimension: CGFloat = 96.0

    private var isSelected: Bool {
        appManager.selectedGroupIDs.contains(group.id)
    }

    private var isSearchSelected: Bool {
        !appManager.currentSearchQuery.isEmpty && appManager.selectedSearchAppID == app.id
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: AppIconRepository.shared.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconDimension, height: iconDimension)
                    .scaleEffect(isSearchSelected ? 1.05 : (isHovered ? 1.05 : (isDropTarget ? 1.12 : 1.0)))
                    .shadow(
                        color: isSearchSelected ? Color.accentColor.opacity(0.45) : .black.opacity(0.35),
                        radius: isSearchSelected ? 10 : (isHovered ? 8 : 5),
                        x: 0,
                        y: 4
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: iconDimension * 0.22)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )

                // Option-key Jiggle Uninstall Button
                if appManager.isUninstallJiggleMode {
                    Button {
                        UninstallWindowController.shared.present(for: app)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                }
            }
            .rotationEffect(.degrees(appManager.isUninstallJiggleMode ? -2.2 : 0))
            .animation(
                appManager.isUninstallJiggleMode
                    ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true)
                    : .spring(response: 0.22, dampingFraction: 0.8),
                value: appManager.isUninstallJiggleMode
            )

            if !state.hideNames {
                Text(app.displayName)
                    .font(.system(size: 13.5, weight: isSearchSelected ? .semibold : .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, isSearchSelected ? 10 : 0)
                    .padding(.vertical, isSearchSelected ? 3 : 0)
                    .background(
                        Group {
                            if isSearchSelected {
                                Capsule()
                                    .fill(Color.black.opacity(0.60))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                                    )
                            }
                        }
                    )
                    .shadow(color: isSearchSelected ? .clear : .black.opacity(0.65), radius: 2, x: 0, y: 1)
                    .frame(width: iconDimension + 16, height: 22, alignment: .center)
            }
        }
        .frame(width: iconDimension + 16)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
                if hovering && !appManager.currentSearchQuery.isEmpty {
                    appManager.selectedSearchAppID = app.id
                }
            }
        }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if appManager.selectedGroupIDs.contains(group.id) {
                    appManager.selectedGroupIDs.remove(group.id)
                } else {
                    appManager.selectedGroupIDs.insert(group.id)
                }
            } else if appManager.isUninstallJiggleMode {
                UninstallWindowController.shared.present(for: app)
            } else {
                LaunchpadWindowController.shared.hide()
                appManager.launchApp(app)
            }
        }
        .contextMenu {
            Button {
                LaunchpadWindowController.shared.hide()
                appManager.launchApp(app)
            } label: {
                Label("打开 \(app.displayName)", systemImage: "arrow.up.forward.app")
            }

            Button {
                appManager.revealInFinder(app)
            } label: {
                Label("在访达 (Finder) 中显示", systemImage: "folder")
            }

            Button {
                appManager.showFinderGetInfo(app)
            } label: {
                Label("显示简介 (Get Info)", systemImage: "info.circle")
            }

            Button {
                appManager.addAppToDock(app)
            } label: {
                Label("添加到程序坞 (Dock)", systemImage: "dock.rectangle")
            }

            Divider()

            Button {
                if appManager.selectedGroupIDs.contains(group.id) {
                    appManager.selectedGroupIDs.remove(group.id)
                } else {
                    appManager.selectedGroupIDs.insert(group.id)
                }
            } label: {
                Label(isSelected ? "取消多选" : "多选以合并文件夹 (⌘点击)", systemImage: "checkmark.circle")
            }

            let folders = appManager.allGroups.filter(\.isFolder)
            if !folders.isEmpty {
                Menu("移入现有文件夹") {
                    ForEach(folders) { targetFolder in
                        Button(targetFolder.name) {
                            appManager.moveGroup(draggedID: group.id, toTargetID: targetFolder.id, mergeIntoFolder: true)
                        }
                    }
                }
            }

            if appManager.totalPages > 1 {
                Menu("移动到指定页面") {
                    ForEach(0..<appManager.totalPages, id: \.self) { p in
                        Button("第 \(p + 1) 页") {
                            appManager.moveGroupToPage(group.id, targetPage: p)
                        }
                    }
                }
            }

            Divider()

            Button {
                appManager.hideApp(app)
            } label: {
                Label("在启动台中隐藏此应用", systemImage: "eye.slash")
            }

            Button(role: .destructive) {
                UninstallWindowController.shared.present(for: app)
            } label: {
                Label("彻底卸载 \(app.displayName)...", systemImage: "trash")
            }
        }
    }
}

/// Replicates `LaunchpadGroupView` (3x3 miniature folder preview cell with tight hit-test region)
public struct LaunchpadFolderCellView: View {
    public let group: LaunchpadGroup
    public var isDropTarget: Bool = false

    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @LocalState private var isHovered: Bool = false

    private let iconDimension: CGFloat = 96.0
    /// macOS app icons have an 824/1024 (80.47%) visible squircle body inside their canvas;
    /// matching this ratio makes the folder squircle identical in visual size to regular app icons.
    private var folderBoxDimension: CGFloat { round(iconDimension * 0.805) }

    public var body: some View {
        let boxSize = folderBoxDimension
        let boxCornerRadius = boxSize * 0.225
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: boxCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isDropTarget ? 0.34 : 0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: boxCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.32), lineWidth: 1)
                    )
                    .frame(width: boxSize, height: boxSize)
                    .shadow(color: .black.opacity(0.28), radius: isHovered ? 10 : 5, x: 0, y: 4)

                let previewApps = Array(group.apps.prefix(9))
                let miniSpacing: CGFloat = 3.0
                let miniSize = floor((boxSize * 0.78 - miniSpacing * 2) / 3.0)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(miniSize), spacing: miniSpacing), count: 3),
                    alignment: .leading,
                    spacing: miniSpacing
                ) {
                    ForEach(previewApps) { app in
                        Image(nsImage: AppIconRepository.shared.icon(for: app, pointSize: 48))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: miniSize, height: miniSize)
                    }
                }
                .frame(
                    width: miniSize * 3 + miniSpacing * 2,
                    height: miniSize * 3 + miniSpacing * 2,
                    alignment: .topLeading
                )
            }
            .frame(width: iconDimension, height: iconDimension)
            .scaleEffect(isHovered ? 1.07 : (isDropTarget ? 1.14 : 1.0))

            if !state.hideNames {
                Text(group.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
                    .frame(width: iconDimension + 6, height: 18, alignment: .center)
            }
        }
        .frame(width: iconDimension + 6)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.28)) {
                appManager.openedFolderID = group.id
            }
        }
        .contextMenu {
            Button {
                withAnimation(.easeInOut(duration: 0.28)) {
                    appManager.openedFolderID = group.id
                }
            } label: {
                Label("打开文件夹", systemImage: "folder")
            }

            Button(role: .destructive) {
                appManager.ungroupFolder(groupID: group.id)
            } label: {
                Label("解散文件夹 (平铺内部应用)", systemImage: "folder.badge.minus")
            }
        }
    }
}

/// Replicates `LaunchOS.OpenedFolderGlassView` (`0x10011e584`–`0x10011e920` & `0x10011cc70`):
/// Wraps `NSGlassEffectView` on macOS 26+ with `_variant` (1/3/2), `_adaptiveAppearance = 1`, `FolderTint`, and `cornerRadius`.
public struct OpenedFolderGlassRepresentable: NSViewRepresentable {
    public let cornerRadius: CGFloat
    public let material: GlassMaterialLevel

    public func makeNSView(context: Context) -> NSView {
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glassView = glassClass.init(frame: .zero)
            glassView.wantsLayer = true
            configureGlassView(glassView)
            return glassView
        } else {
            let effectView = NSVisualEffectView(frame: .zero)
            effectView.wantsLayer = true
            effectView.blendingMode = .withinWindow
            effectView.state = .active
            effectView.material = material.nsMaterial
            effectView.layer?.cornerRadius = cornerRadius
            effectView.layer?.masksToBounds = true
            return effectView
        }
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if NSStringFromClass(type(of: nsView)).contains("GlassEffectView") {
            configureGlassView(nsView)
        } else if let effectView = nsView as? NSVisualEffectView {
            effectView.material = material.nsMaterial
            effectView.layer?.cornerRadius = cornerRadius
        }
    }

    private func configureGlassView(_ view: NSView) {
        view.wantsLayer = true
        // `0x10011cc70`: GlassMaterial 0 (.regular) -> 1, 1 (.clear/ultraThin/thin) -> 3, 2 (.thick/ultraThick) -> 2
        let variant: Int
        switch material {
        case .regular: variant = 1
        case .ultraThin, .thin: variant = 3
        case .thick, .ultraThick: variant = 2
        }
        view.setValue(NSNumber(value: variant), forKey: "_variant")
        view.setValue(NSNumber(value: 1), forKey: "_adaptiveAppearance")

        // `0x10011e638`: FolderTint from Assets.car (P3 0.0667, 0.0667, 0.0667, 0.05 in Aqua; 0,0,0,0 in DarkAqua)
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let folderTint = isDark
            ? NSColor.clear
            : NSColor(displayP3Red: 0.0667, green: 0.0667, blue: 0.0667, alpha: 0.05)
        view.setValue(folderTint, forKey: "tintColor")
        view.setValue(NSNumber(value: Double(cornerRadius)), forKey: "cornerRadius")
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
    }
}

/// Replicates `LaunchpadContentView+Folder.swift` (`0x10011c578`–`0x100128488`):
/// - `openedFolderBackdropView` (`#0x9c8`): full-screen clickable backdrop (`black.opacity(0.20)` in full-screen, `.clear` in window mode)
/// - `openedFolderTitleLabel` (`#0x9e8`): placed **28.0 pt ABOVE** the folder glass card (`15.0 pt` in window mode), centered horizontally, `.largeTitle` (`26pt .regular`), click-to-edit in-place via `openedFolderTitleEditorView` (`#0x9f8`)
/// - `openedFolderBackButton` (`#0x9f0`): `32×32` button with `"chevron.left"` (`17pt .regular`) at `cardMinX + 16`, visible in window mode
/// - `openedFolderClipView` / `openedFolderBlurView` (`#0x9d0` / `#0x9d8`): `NSGlassEffectView` card sized to `cols * cellWidth` wide and `visibleRows * cellHeight + 2 * vPad` tall (`visibleRows = max(1, min(totalRows, maxRows))`), cornerRadius `max(16.0, min(cellWidth, cellHeight) * 0.24)` (`30.0` in window mode), vertically shifted down by `27.0 pt` (`54.0 * 0.5`) to balance the title above
public struct OpenedFolderOverlayView: View {
    public let group: LaunchpadGroup
    public let containerSize: CGSize
    public let gridAreaHeight: CGFloat

    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @LocalState private var folderName: String = ""
    @LocalState private var isEditingTitle: Bool = false
    @FocusState private var isTitleFieldFocused: Bool

    public var body: some View {
        let isWindowMode = (state.displayMode == .window)
        let cols = max(1, state.columnsPerPage)
        let maxRows = max(1, state.rowsPerPage)

        // Exact cellSize matching main Launchpad grid
        let horizontalMargin = round(max(48.0, containerSize.width * 0.085))
        let usableWidth = max(400.0, containerSize.width - horizontalMargin * 2)
        let cellWidth = usableWidth / CGFloat(cols)
        let cellHeight = gridAreaHeight / CGFloat(maxRows)

        // `0x10012013c` & `0x1001202a4`: totalRows and visibleRows
        let totalRows = max(1, Int(ceil(Double(group.apps.count) / Double(cols))))
        let visibleRows = isWindowMode ? maxRows : max(1, min(totalRows, maxRows))

        // `0x100121860`: vPad = min(6.0, round(cellHeight * 0.12))
        let vPad = min(6.0, round(cellHeight * 0.12))

        // `0x10012170c`–`0x100121998`: Folder card dimensions
        let cardWidth: CGFloat = isWindowMode
            ? max(320.0, containerSize.width - 8.0)
            : (cellWidth * CGFloat(cols))
        let scrollHeight: CGFloat = isWindowMode
            ? max(200.0, gridAreaHeight - 4.0 - vPad * 2.0)
            : (cellHeight * CGFloat(visibleRows))
        let cardHeight: CGFloat = scrollHeight + vPad * 2.0

        // `0x100120074`: cornerRadius = isWindowMode ? 30.0 : max(16.0, min(cellWidth, cellHeight) * 0.24)
        let cardCornerRadius: CGFloat = isWindowMode
            ? 30.0
            : max(16.0, min(cellWidth, cellHeight) * 0.24)

        // `0x100128444`: Title sits 28.0 pt above card in full-screen (15.0 pt in window mode)
        let titleBottomGap: CGFloat = isWindowMode ? 15.0 : 28.0
        let titleFontSize: CGFloat = isWindowMode ? 17.0 : 26.0
        let titleHeight: CGFloat = isWindowMode ? 24.0 : 34.0
        let displayTitle = group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名文件夹"
            : group.name

        ZStack {
            // 1. `openedFolderBackdropView` (`#0x9c8`, `0x100122360`–`0x100122470`)
            (isWindowMode ? Color.clear : Color.black.opacity(0.20))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditingTitle {
                        commitRename()
                    } else {
                        closeFolder()
                    }
                }

            // 2. Centered `[Title Above + Gap + Folder Glass Card]` Assembly
            VStack(spacing: titleBottomGap) {
                // Header Row: Back Button (in Windowed Mode) + Centered Title / In-Place Editor (`#0x9e8`, `#0x9f0`, `#0x9f8`)
                ZStack {
                    if isWindowMode {
                        HStack {
                            Button {
                                commitRename()
                                closeFolder()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 16)
                            Spacer()
                        }
                    }

                    if isEditingTitle {
                        TextField("未命名文件夹", text: $folderName)
                            .textFieldStyle(.plain)
                            .font(.system(size: titleFontSize, weight: isWindowMode ? .medium : .regular))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(width: max(120, cardWidth - 12.0), height: titleHeight + 8.0)
                            .focused($isTitleFieldFocused)
                            .onSubmit {
                                commitRename()
                            }
                    } else {
                        Text(displayTitle)
                            .font(.system(size: titleFontSize, weight: isWindowMode ? .medium : .regular))
                            .foregroundColor(.white)
                            .shadow(
                                color: isWindowMode ? .clear : .black.opacity(0.26),
                                radius: 2.0,
                                x: 0,
                                y: 1
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 8)
                            .frame(height: titleHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                folderName = group.name
                                isEditingTitle = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    isTitleFieldFocused = true
                                }
                            }
                    }
                }
                .frame(width: cardWidth, height: titleHeight)

                // 3. `openedFolderClipView` + `openedFolderBlurView` (`NSGlassEffectView`) + `openedFolderScrollView`
                ZStack {
                    OpenedFolderGlassRepresentable(
                        cornerRadius: cardCornerRadius,
                        material: state.glassMaterial
                    )
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.32), radius: 26, x: 0, y: 12)
                    .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                    .onTapGesture {
                        // `0x1001205c4`: Clicking inside the folder card while editing title commits rename without closing folder;
                        // clicking empty space inside the card otherwise does not dismiss the folder (`0x100120634`).
                        if isEditingTitle {
                            commitRename()
                        }
                    }

                    // `openedFolderScrollView` (`#0xa00`) & `openedFolderContentView` (`#0xa08`)
                    ScrollView(.vertical, showsIndicators: totalRows > visibleRows) {
                        let contentGridHeight = CGFloat(totalRows) * cellHeight
                        let verticalCenterOffset = max(0.0, (scrollHeight - contentGridHeight) * 0.5)

                        VStack(spacing: 0) {
                            if verticalCenterOffset > 0 {
                                Spacer().frame(height: verticalCenterOffset)
                            }
                            ForEach(0..<totalRows, id: \.self) { r in
                                HStack(spacing: 0) {
                                    ForEach(0..<cols, id: \.self) { c in
                                        let idx = r * cols + c
                                        ZStack(alignment: .center) {
                                            Color.white.opacity(0.001)
                                                .frame(width: cellWidth, height: cellHeight)
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    if isEditingTitle {
                                                        commitRename()
                                                    } else {
                                                        closeFolder()
                                                    }
                                                }

                                            if idx < group.apps.count {
                                                LaunchpadFolderInnerAppCellView(
                                                    folderGroup: group,
                                                    app: group.apps[idx]
                                                )
                                            }
                                        }
                                        .frame(width: cellWidth, height: cellHeight)
                                    }
                                }
                                .frame(width: cellWidth * CGFloat(cols), height: cellHeight)
                            }
                            if verticalCenterOffset > 0 {
                                Spacer().frame(height: verticalCenterOffset)
                            }
                        }
                        .frame(width: cardWidth, height: max(scrollHeight, contentGridHeight), alignment: .top)
                    }
                    .frame(width: cardWidth, height: scrollHeight)
                }
                .frame(width: cardWidth, height: cardHeight)
            }
            // `0x100121944`: Card is shifted slightly downward (`(titleHeight + titleBottomGap - 54.0) * 0.5`) so the card + top title balance visually
            .offset(y: isWindowMode ? 0 : -4.0)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .onAppear {
            folderName = group.name
        }
    }

    private func closeFolder() {
        commitRename()
        withAnimation(.easeInOut(duration: 0.28)) {
            appManager.openedFolderID = nil
        }
    }

    private func commitRename() {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != group.name {
            appManager.renameGroup(groupID: group.id, newName: trimmed)
        } else {
            folderName = group.name
        }
        isEditingTitle = false
        isTitleFieldFocused = false
    }
}

/// App cell inside an opened folder (`openedFolderAppViews`, `0x100121cb8`–`0x100121d54`),
/// sharing the exact `96pt` icon size and typography of `LaunchpadAppCellView`.
public struct LaunchpadFolderInnerAppCellView: View {
    public let folderGroup: LaunchpadGroup
    public let app: LaunchpadApp

    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @LocalState private var isHovered: Bool = false

    private let iconDimension: CGFloat = 96.0

    public var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: AppIconRepository.shared.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconDimension, height: iconDimension)
                    .scaleEffect(isHovered ? 1.07 : 1.0)
                    .shadow(color: .black.opacity(0.35), radius: isHovered ? 10 : 5, x: 0, y: 4)

                if appManager.isUninstallJiggleMode {
                    Button {
                        UninstallWindowController.shared.present(for: app)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain)
                    .offset(x: -6, y: -6)
                }
            }
            .rotationEffect(.degrees(appManager.isUninstallJiggleMode ? -2.2 : 0))
            .animation(
                appManager.isUninstallJiggleMode
                    ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true)
                    : .spring(response: 0.22, dampingFraction: 0.8),
                value: appManager.isUninstallJiggleMode
            )

            if !state.hideNames {
                Text(app.displayName)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: iconDimension + 6, height: 18, alignment: .center)
            }
        }
        .frame(width: iconDimension + 6)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if appManager.isUninstallJiggleMode {
                UninstallWindowController.shared.present(for: app)
            } else {
                LaunchpadWindowController.shared.hide()
                appManager.launchApp(app)
            }
        }
        .contextMenu {
            Button {
                LaunchpadWindowController.shared.hide()
                appManager.launchApp(app)
            } label: {
                Label("打开 \(app.displayName)", systemImage: "arrow.up.forward.app")
            }

            Button {
                appManager.revealInFinder(app)
            } label: {
                Label("在访达 (Finder) 中显示", systemImage: "folder")
            }

            Button {
                appManager.removeAppFromFolder(appID: app.id, folderID: folderGroup.id)
            } label: {
                Label("移出文件夹", systemImage: "folder.badge.minus")
            }

            Button {
                appManager.ungroupFolder(groupID: folderGroup.id)
            } label: {
                Label("解散此文件夹", systemImage: "rectangle.grid.2x2")
            }

            Divider()

            Button(role: .destructive) {
                UninstallWindowController.shared.present(for: app)
            } label: {
                Label("彻底卸载 \(app.displayName)...", systemImage: "trash")
            }
        }
    }
}
