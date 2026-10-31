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
                    let nextPage = state.currentPage + 1
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        pager.dragOffset = 0
                        state.currentPage = nextPage
                    }
                    LaunchpadDragSession.shared.handlePageSwitchDuringDrag(to: nextPage)
                } else if accumulatedDelta > triggerThreshold && state.currentPage > 0 {
                    gestureHasTurnedPage = true
                    pager.isDragging = false
                    let nextPage = state.currentPage - 1
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        pager.dragOffset = 0
                        state.currentPage = nextPage
                    }
                    LaunchpadDragSession.shared.handlePageSwitchDuringDrag(to: nextPage)
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
                    let didChange = (targetPage != state.currentPage)
                    pager.isDragging = false
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        pager.dragOffset = 0
                        state.currentPage = targetPage
                    }
                    if didChange {
                        LaunchpadDragSession.shared.handlePageSwitchDuringDrag(to: targetPage)
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
                let nextPage = state.currentPage + 1
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    state.currentPage = nextPage
                }
                LaunchpadDragSession.shared.handlePageSwitchDuringDrag(to: nextPage)
            } else if delta > 0.3 && state.currentPage > 0 {
                lastDiscreteTurnTime = Date()
                let nextPage = state.currentPage - 1
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    state.currentPage = nextPage
                }
                LaunchpadDragSession.shared.handlePageSwitchDuringDrag(to: nextPage)
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

/// Interactive Drag, Reorder, Folder Merge, Folder Detach, and Marquee Selection Engine
/// Replicates `LaunchpadContentView` (`0x100105100`–`0x10011c500`), `LaunchpadContentView+MultiDrag` (`0x100140000`–`0x100148000`),
/// and `LaunchpadDragPreviewView` (`0x100145cf0`–`0x10014a500`).
public final class LaunchpadDragSession: ObservableObject {
    public static let shared = LaunchpadDragSession()

    /// Main-grid group cell frames in `"LaunchpadRootSpace"`
    public var cellFrames: [String: CGRect] = [:]
    /// Folder cell icon frames in `"LaunchpadRootSpace"` for `0.28s` open/close hero morph (`openedFolderSourceFrames`)
    public var folderIconFrames: [String: CGRect] = [:]
    /// Last known source rect for the currently opened or closing folder
    @Published public var lastOpenedFolderSourceRect: CGRect? = nil
    /// Opened folder glass card frame in `"LaunchpadRootSpace"` (`openedFolderClipView`)
    public var openedFolderCardFrame: CGRect = .zero
    /// App cell frames inside the opened folder in `"LaunchpadRootSpace"`
    public var openedFolderAppFrames: [String: CGRect] = [:]
    /// Current container size for edge page-flip detection & mathematical slot calculation
    public var containerSize: CGSize = .zero

    /// Press feedback state (`isPressed`, `0.8` alpha at `0x10015b73c`)
    @Published public var pressedItemID: String? = nil
    /// Active drag state (`isDragging`)
    @Published public var isDragging: Bool = false
    /// Drop commit flight animation state (`0x10010c3d8`–`0x10010d7c8`)
    @Published public var isCommittingDrop: Bool = false
    @Published public var dropCommitScale: CGFloat = 1.0

    /// IDs of main-grid groups being dragged (single or multi-drag stack)
    @Published public var draggedGroupIDs: [String] = []
    /// Preview groups rendered in `LaunchpadDragPreviewOverlay`
    @Published public var dragPreviewGroups: [LaunchpadGroup] = []
    /// Non-nil when dragging an app inside an opened folder (`0x10011a428`)
    @Published public var draggedFolderID: String? = nil
    @Published public var draggedFolderApp: LaunchpadApp? = nil

    /// Current pointer position in `"LaunchpadRootSpace"`
    @Published public var cursorLocation: CGPoint = .zero
    /// Hover merge target group ID (`isDraggingMerge` at `0x1000f92b0` & `0x100153cac`)
    @Published public var mergeTargetGroupID: String? = nil
    /// Live incoming app for 3x3 folder preview (`incomingDropAppID` at `0x100154860`)
    @Published public var incomingDropApp: LaunchpadApp? = nil
    /// Screen edge auto-paging direction (`-1` left, `0` none, `+1` right)
    @Published public var activeEdgeDirection: Int = 0

    /// Rubber-band marquee selection (`SelectionMarqueeView` at `0x100140000`)
    @Published public var isMarqueeSelecting: Bool = false
    @Published public var marqueeStartPoint: CGPoint = .zero
    @Published public var marqueeCurrentPoint: CGPoint = .zero

    private var longPressWorkItem: DispatchWorkItem? = nil
    private var reorderHoverWorkItem: DispatchWorkItem? = nil
    private var mergeHoverWorkItem: DispatchWorkItem? = nil
    private var edgeFlipWorkItem: DispatchWorkItem? = nil
    private var lastReorderTargetKey: String? = nil
    private var pendingMergeCandidateID: String? = nil

    /// Window-level mouse continuation state so cross-page moves and folder detaches never cancel an active drag
    private var localMouseMonitor: Any? = nil
    private var activePressGroup: LaunchpadGroup? = nil
    private var activePressFolder: LaunchpadGroup? = nil
    private var activePressFolderApp: LaunchpadApp? = nil
    private var pressStartLocation: CGPoint = .zero

    private init() {
        installWindowMouseContinuationMonitor()
    }

    private func installWindowMouseContinuationMonitor() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            guard (self.isDragging || self.pressedItemID != nil), !self.isCommittingDrop else {
                return event
            }
            guard self.containerSize.height > 0 else { return event }

            // Convert NSWindow bottom-left coordinates into top-left `"LaunchpadRootSpace"` coordinates
            let winPoint = event.locationInWindow
            let rootPoint = CGPoint(x: winPoint.x, y: self.containerSize.height - winPoint.y)

            switch event.type {
            case .leftMouseDragged:
                if self.isDragging {
                    if self.draggedFolderID != nil,
                       let folder = self.activePressFolder,
                       let app = self.activePressFolderApp {
                        self.updateFolderAppDrag(folder: folder, app: app, locationInRoot: rootPoint)
                    } else if let group = self.activePressGroup ?? self.dragPreviewGroups.first {
                        self.updateMainGridDrag(for: group, locationInRoot: rootPoint)
                    }
                } else if self.pressedItemID != nil {
                    let dist = hypot(rootPoint.x - self.pressStartLocation.x, rootPoint.y - self.pressStartLocation.y)
                    if dist > 4.0 {
                        if let folder = self.activePressFolder, let app = self.activePressFolderApp {
                            self.updateFolderAppDrag(folder: folder, app: app, locationInRoot: rootPoint)
                        } else if let group = self.activePressGroup {
                            self.updateMainGridDrag(for: group, locationInRoot: rootPoint)
                        }
                    }
                }

            case .leftMouseUp:
                if self.isDragging {
                    if self.draggedFolderID != nil {
                        self.endFolderAppDrag()
                    } else {
                        self.endMainGridDrag()
                    }
                } else if self.pressedItemID != nil {
                    self.cancelPress()
                }

            default:
                break
            }
            return event
        }
    }

    public var marqueeRect: CGRect {
        CGRect(
            x: min(marqueeStartPoint.x, marqueeCurrentPoint.x),
            y: min(marqueeStartPoint.y, marqueeCurrentPoint.y),
            width: abs(marqueeCurrentPoint.x - marqueeStartPoint.x),
            height: abs(marqueeCurrentPoint.y - marqueeStartPoint.y)
        )
    }

    public func isGroupHiddenAsPlaceholder(_ groupID: String) -> Bool {
        guard isDragging && !isCommittingDrop else { return false }
        return draggedGroupIDs.contains(groupID)
    }

    public func isFolderAppHiddenAsPlaceholder(_ appID: String) -> Bool {
        guard isDragging && !isCommittingDrop else { return false }
        return draggedFolderApp?.id == appID
    }

    // MARK: - Mathematical Main Grid Slot Geometry (`0x10010b33c`–`0x10010c3d0`)

    public func mainGridMetrics() -> (cols: Int, rows: Int, topHeaderHeight: CGFloat, horizontalMargin: CGFloat, cellWidth: CGFloat, cellHeight: CGFloat) {
        let state = AppState.shared
        let cols = max(4, state.columnsPerPage)
        let rows = max(3, state.rowsPerPage)
        let isFullScreen = (state.displayMode == .fullScreen)
        let topHeaderHeight: CGFloat = isFullScreen ? 106 : 80
        let bottomFooterHeight: CGFloat = isFullScreen ? 84 : 64
        let gridAreaHeight = max(320, containerSize.height - topHeaderHeight - bottomFooterHeight)
        let horizontalMargin = round(max(48.0, containerSize.width * 0.085))
        let usableWidth = max(400.0, containerSize.width - horizontalMargin * 2)
        let cellWidth = usableWidth / CGFloat(cols)
        let cellHeight = gridAreaHeight / CGFloat(rows)
        return (cols, rows, topHeaderHeight, horizontalMargin, cellWidth, cellHeight)
    }

    public func mainGridSlotRect(forSlotIndex idx: Int) -> CGRect {
        let m = mainGridMetrics()
        let r = idx / m.cols
        let c = idx % m.cols
        return CGRect(
            x: m.horizontalMargin + CGFloat(c) * m.cellWidth,
            y: m.topHeaderHeight + CGFloat(r) * m.cellHeight,
            width: m.cellWidth,
            height: m.cellHeight
        )
    }

    public func nearestMainGridSlotIndex(at point: CGPoint) -> Int {
        let m = mainGridMetrics()
        let col = min(max(0, Int(floor((point.x - m.horizontalMargin) / max(1.0, m.cellWidth)))), m.cols - 1)
        let row = min(max(0, Int(floor((point.y - m.topHeaderHeight) / max(1.0, m.cellHeight)))), m.rows - 1)
        return row * m.cols + col
    }

    // MARK: - Pointer Down & 0.55s Long-Press Jiggle Trigger (`0x10015d0b0`–`0x10015db44`)

    public func beginPress(
        itemID: String,
        group: LaunchpadGroup? = nil,
        folder: LaunchpadGroup? = nil,
        folderApp: LaunchpadApp? = nil,
        startLocation: CGPoint = .zero
    ) {
        if let group = group {
            activePressGroup = group
        }
        if let folder = folder {
            activePressFolder = folder
        }
        if let folderApp = folderApp {
            activePressFolderApp = folderApp
        }
        if startLocation != .zero {
            pressStartLocation = startLocation
        }
        guard pressedItemID != itemID, !isDragging else { return }
        pressedItemID = itemID
        longPressWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isDragging, self.pressedItemID == itemID else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.68)) {
                ApplicationManager.shared.isUninstallJiggleMode = true
            }
        }
        longPressWorkItem = work
        // Observed at `0x10015d238`: `0.55s` (`0x3fe199999999999a`) long press enters uninstall jiggle mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    public func cancelPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        if pressedItemID != nil {
            pressedItemID = nil
        }
    }

    // MARK: - Cross-Page Transfer Helper (`0x10011064c`–`0x1001124e4`)

    public func handlePageSwitchDuringDrag(to targetPage: Int) {
        guard isDragging, !isCommittingDrop, draggedFolderID == nil, !draggedGroupIDs.isEmpty else { return }
        let appManager = ApplicationManager.shared
        reorderHoverWorkItem?.cancel()
        mergeHoverWorkItem?.cancel()
        lastReorderTargetKey = nil
        pendingMergeCandidateID = nil
        clearMergeTarget()

        let preferredSlot = nearestMainGridSlotIndex(at: cursorLocation)
        withAnimation(.easeInOut(duration: 0.36)) {
            for (offset, id) in draggedGroupIDs.enumerated() {
                appManager.moveGroupToEndOfPage(
                    draggedID: id,
                    targetPage: targetPage,
                    preferredSlotIndex: preferredSlot + offset,
                    save: false
                )
            }
        }
        refreshCurrentPageSlotFrames()
    }

    public func refreshCurrentPageSlotFrames() {
        let state = AppState.shared
        guard state.browsingStyle == .paged, containerSize.width > 200 else { return }
        let pageGroups = ApplicationManager.shared.groups(forPage: state.currentPage)
        for (idx, grp) in pageGroups.enumerated() {
            let rect = mainGridSlotRect(forSlotIndex: idx)
            cellFrames[grp.id] = rect
            if grp.isFolder {
                folderIconFrames[grp.id] = rect
            }
        }
    }

    // MARK: - Main Grid Drag Lifecycle

    public func updateMainGridDrag(for group: LaunchpadGroup, locationInRoot: CGPoint) {
        let appManager = ApplicationManager.shared
        let state = AppState.shared

        if !isDragging {
            cancelPress()
            // Observed at `0x10010f7c4`: Dragging is only allowed in `.custom` sort mode
            guard state.sortBy == .custom, appManager.currentSearchQuery.isEmpty else {
                appManager.showStatusToast("仅在“自定义”排序模式下支持拖拽调整位置")
                return
            }

            activePressGroup = group
            isDragging = true
            isCommittingDrop = false
            dropCommitScale = 1.06
            cursorLocation = locationInRoot

            if appManager.selectedGroupIDs.contains(group.id) && appManager.selectedGroupIDs.count > 1 {
                let orderedSelected = appManager.allGroups
                    .filter { appManager.selectedGroupIDs.contains($0.id) }
                    .sorted { ($0.page, $0.order) < ($1.page, $1.order) }
                // Put the actively grabbed group first in the fanned stack
                var stacked = orderedSelected.filter { $0.id != group.id }
                stacked.insert(group, at: 0)
                draggedGroupIDs = stacked.map { $0.id }
                dragPreviewGroups = stacked
            } else {
                appManager.selectedGroupIDs.removeAll()
                draggedGroupIDs = [group.id]
                dragPreviewGroups = [group]
            }
            refreshCurrentPageSlotFrames()
            return
        }

        cursorLocation = locationInRoot
        evaluateMainGridHover(at: locationInRoot)
    }

    public func endMainGridDrag() {
        guard isDragging, !isCommittingDrop else {
            if !isCommittingDrop {
                cancelPress()
            }
            return
        }
        reorderHoverWorkItem?.cancel()
        mergeHoverWorkItem?.cancel()
        edgeFlipWorkItem?.cancel()
        activeEdgeDirection = 0
        lastReorderTargetKey = nil
        pendingMergeCandidateID = nil

        let appManager = ApplicationManager.shared
        let state = AppState.shared
        let primaryID = draggedGroupIDs.first

        refreshCurrentPageSlotFrames()

        // Determine target destination for smooth drop flight (`0x10010c3d8`–`0x10010d7c8`)
        if let mergeTargetID = mergeTargetGroupID {
            let targetRect = cellFrames[mergeTargetID]
            isCommittingDrop = true
            withAnimation(.easeInOut(duration: 0.24)) {
                if let rect = targetRect {
                    cursorLocation = CGPoint(x: rect.midX, y: rect.midY - 10)
                }
                dropCommitScale = 0.28
            }
            let idsToMerge = draggedGroupIDs
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    appManager.mergeGroups(draggedIDs: idsToMerge, intoTargetID: mergeTargetID)
                }
                self.resetDragState()
            }
        } else {
            // Ensure primary dragged item is on `state.currentPage` if user switched pages before dropping
            if state.browsingStyle == .paged,
               let firstID = primaryID,
               let firstGrp = appManager.allGroups.first(where: { $0.id == firstID }),
               firstGrp.page != state.currentPage {
                let preferredSlot = nearestMainGridSlotIndex(at: cursorLocation)
                withAnimation(.easeInOut(duration: 0.36)) {
                    appManager.moveGroupToEndOfPage(
                        draggedID: firstID,
                        targetPage: state.currentPage,
                        preferredSlotIndex: preferredSlot,
                        save: false
                    )
                }
            }

            // If multi-dragging > 1 items without merging, move all selected items next to the primary dragged item
            if draggedGroupIDs.count > 1, let firstID = primaryID {
                let otherIDs = Array(draggedGroupIDs.dropFirst())
                for otherID in otherIDs.reversed() {
                    appManager.reorderGroup(draggedID: otherID, targetID: firstID, insertAfter: true, save: false)
                }
            }
            appManager.saveLayoutToCoreData()
            refreshCurrentPageSlotFrames()

            let resolvedRect: CGRect? = {
                if let firstID = primaryID {
                    if state.browsingStyle == .paged {
                        let pageGroups = appManager.groups(forPage: state.currentPage)
                        if let idx = pageGroups.firstIndex(where: { $0.id == firstID }) {
                            return mainGridSlotRect(forSlotIndex: idx)
                        }
                    }
                    return cellFrames[firstID]
                }
                return nil
            }()

            if let slotRect = resolvedRect {
                isCommittingDrop = true
                withAnimation(.easeInOut(duration: 0.22)) {
                    cursorLocation = CGPoint(x: slotRect.midX, y: slotRect.midY)
                    dropCommitScale = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    self.resetDragState()
                }
            } else {
                resetDragState()
            }
        }
    }

    // MARK: - Opened Folder Inner App Drag & Detach Lifecycle (`0x10011a428`–`0x10011b708`)

    public func updateFolderAppDrag(folder: LaunchpadGroup, app: LaunchpadApp, locationInRoot: CGPoint) {
        let appManager = ApplicationManager.shared
        let state = AppState.shared

        if !isDragging {
            cancelPress()
            guard state.sortBy == .custom else {
                appManager.showStatusToast("仅在“自定义”排序模式下支持拖拽调整位置")
                return
            }
            activePressFolder = folder
            activePressFolderApp = app
            isDragging = true
            isCommittingDrop = false
            dropCommitScale = 1.06
            cursorLocation = locationInRoot
            draggedFolderID = folder.id
            draggedFolderApp = app
            dragPreviewGroups = [
                LaunchpadGroup(
                    id: "folder-drag-\(app.id)",
                    name: app.displayName,
                    isFolder: false,
                    page: folder.page,
                    order: app.order,
                    apps: [app]
                )
            ]
            return
        }

        cursorLocation = locationInRoot

        // If already detached to the main grid during this drag session, evaluate main grid hover!
        if draggedFolderID == nil && !draggedGroupIDs.isEmpty {
            evaluateMainGridHover(at: locationInRoot)
            return
        }

        guard let activeFolderID = draggedFolderID,
              let activeApp = draggedFolderApp else { return }

        // Check if cursor moved outside `openedFolderClipView` (`0x10011abdc`–`0x10011b584`)
        let detachBounds = openedFolderCardFrame.insetBy(dx: -20, dy: -20)
        if !openedFolderCardFrame.isEmpty && !detachBounds.contains(locationInRoot) {
            reorderHoverWorkItem?.cancel()
            lastReorderTargetKey = nil
            // Detach app from folder, close folder overlay (`0.28s`), and continue dragging on main grid!
            withAnimation(.easeInOut(duration: 0.28)) {
                if let newGroup = appManager.detachAppFromFolder(
                    appID: activeApp.id,
                    folderID: activeFolderID,
                    targetPage: state.currentPage,
                    save: false
                ) {
                    self.draggedFolderID = nil
                    self.draggedFolderApp = nil
                    self.activePressGroup = newGroup
                    self.draggedGroupIDs = [newGroup.id]
                    self.dragPreviewGroups = [newGroup]
                }
                appManager.openedFolderID = nil
            }
            refreshCurrentPageSlotFrames()
            return
        }

        // Otherwise, reorder inside the opened folder (`0x10011a428`–`0x10011ab00`)
        evaluateOpenedFolderHover(folderID: activeFolderID, draggedAppID: activeApp.id, at: locationInRoot)
    }

    public func endFolderAppDrag() {
        if draggedFolderID == nil && !draggedGroupIDs.isEmpty {
            endMainGridDrag()
            return
        }
        guard isDragging, !isCommittingDrop else {
            if !isCommittingDrop {
                cancelPress()
            }
            return
        }
        reorderHoverWorkItem?.cancel()
        lastReorderTargetKey = nil
        ApplicationManager.shared.saveLayoutToCoreData()

        if let appID = draggedFolderApp?.id, let slotRect = openedFolderAppFrames[appID] {
            isCommittingDrop = true
            withAnimation(.easeInOut(duration: 0.20)) {
                cursorLocation = CGPoint(x: slotRect.midX, y: slotRect.midY)
                dropCommitScale = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                self.resetDragState()
            }
        } else {
            resetDragState()
        }
    }

    // MARK: - Hit-Testing & Live Slot Shifting (`0.36s` `.easeInEaseOut`, `0x100111ac8`–`0x100114954`)

    private func scheduleEdgePageFlip(direction: Int) {
        edgeFlipWorkItem?.cancel()
        guard direction != 0 else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isDragging, !self.isCommittingDrop, self.activeEdgeDirection == direction else { return }
            let appManager = ApplicationManager.shared
            let state = AppState.shared
            let currentGroups = appManager.groups(forPage: state.currentPage)
            let canCreateTrailingPage = (direction > 0)
                && (state.currentPage == appManager.totalPages - 1)
                && (currentGroups.count > self.draggedGroupIDs.count)
            let maxReachablePage = canCreateTrailingPage ? appManager.totalPages : (appManager.totalPages - 1)
            let nextPage = max(0, min(maxReachablePage, state.currentPage + direction))

            if nextPage != state.currentPage {
                self.reorderHoverWorkItem?.cancel()
                self.mergeHoverWorkItem?.cancel()
                self.lastReorderTargetKey = nil
                self.pendingMergeCandidateID = nil
                self.clearMergeTarget()

                let preferredSlot = self.nearestMainGridSlotIndex(at: self.cursorLocation)
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                    for (offset, id) in self.draggedGroupIDs.enumerated() {
                        appManager.moveGroupToEndOfPage(
                            draggedID: id,
                            targetPage: nextPage,
                            preferredSlotIndex: preferredSlot + offset,
                            save: false
                        )
                    }
                    state.currentPage = min(nextPage, max(0, appManager.totalPages - 1))
                }
                self.refreshCurrentPageSlotFrames()

                // Continue flipping across multiple pages if pointer remains held at the screen edge
                let edgeMargin: CGFloat = 56.0
                let stillInLeft = (direction < 0 && self.cursorLocation.x < edgeMargin && state.currentPage > 0)
                let stillInRight = (direction > 0 && self.cursorLocation.x > self.containerSize.width - edgeMargin && state.currentPage < appManager.totalPages - 1)
                if stillInLeft || stillInRight {
                    self.scheduleEdgePageFlip(direction: direction)
                } else {
                    self.activeEdgeDirection = 0
                }
            } else {
                self.activeEdgeDirection = 0
            }
        }
        edgeFlipWorkItem = work
        // Observed at `0x100112448`: edge hover page turn trigger
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func evaluateMainGridHover(at point: CGPoint) {
        guard let primaryDraggedID = draggedGroupIDs.first else { return }
        let appManager = ApplicationManager.shared
        let state = AppState.shared

        let pageGroups = state.browsingStyle == .paged
            ? appManager.groups(forPage: state.currentPage)
            : appManager.filteredGroups

        if state.browsingStyle == .paged {
            refreshCurrentPageSlotFrames()
        }

        // 1. Screen-edge hover page flip (`0x10011064c`–`0x1001124e4`)
        if state.browsingStyle == .paged && containerSize.width > 200 {
            let edgeMargin: CGFloat = 56.0
            let canFlipRight = (state.currentPage < appManager.totalPages - 1)
                || (state.currentPage == appManager.totalPages - 1 && pageGroups.count > draggedGroupIDs.count)
            let newEdgeDir: Int
            if point.x < edgeMargin && state.currentPage > 0 {
                newEdgeDir = -1
            } else if point.x > containerSize.width - edgeMargin && canFlipRight {
                newEdgeDir = 1
            } else {
                newEdgeDir = 0
            }

            if newEdgeDir != activeEdgeDirection {
                activeEdgeDirection = newEdgeDir
                scheduleEdgePageFlip(direction: newEdgeDir)
            }
            // While hovering inside the screen-edge page-turn strip, avoid firing edge-cell reorders
            if newEdgeDir != 0 {
                return
            }
        }

        // 2. Hit-test target cells on current page (`0x100111ac8`–`0x100111bbc` & `0x10010f8f0`)
        let draggedGroup = appManager.allGroups.first(where: { $0.id == primaryDraggedID })
        let canMergeIntoTarget = !(draggedGroup?.isFolder ?? false) && draggedGroupIDs.allSatisfy { id in
            !(appManager.allGroups.first(where: { $0.id == id })?.isFolder ?? false)
        }

        for (slotIdx, target) in pageGroups.enumerated() where !draggedGroupIDs.contains(target.id) {
            let frame: CGRect
            if state.browsingStyle == .paged && containerSize.width > 200 {
                frame = mainGridSlotRect(forSlotIndex: slotIdx)
            } else if let recorded = cellFrames[target.id] {
                frame = recorded
            } else {
                continue
            }

            let hitRect = frame.insetBy(dx: -2, dy: -2)
            guard hitRect.contains(point) else { continue }

            // Replicate `LaunchpadContentView` (`0x100111b4c`–`0x100111bbc`):
            // Each cell has an inner `96x96` `iconView` centered horizontally in `cellWidth`.
            // - Center core of `iconView` (`±26pt` horizontally, within icon vertical bounds): `.mergeIntoFolder` (`action = 2`)
            // - Left of center (`point.x < frame.midX`) outside merge core: `.moveBefore` (`action = 0`)
            // - Right of center (`point.x >= frame.midX`) outside merge core: `.moveAfter` (`action = 1`)
            let dxFromCenter = point.x - frame.midX
            let iconTopY = frame.minY + max(6.0, (frame.height - 122.0) * 0.5)
            let iconBottomY = iconTopY + 96.0
            let isInsideIconMergeCore = canMergeIntoTarget
                && abs(dxFromCenter) <= 26.0
                && point.y >= iconTopY + 10.0
                && point.y <= iconBottomY - 8.0

            if isInsideIconMergeCore {
                reorderHoverWorkItem?.cancel()
                lastReorderTargetKey = nil
                if mergeTargetGroupID != target.id && pendingMergeCandidateID != target.id {
                    pendingMergeCandidateID = target.id
                    mergeHoverWorkItem?.cancel()
                    let mergeWork = DispatchWorkItem { [weak self] in
                        guard let self = self, self.isDragging, self.pendingMergeCandidateID == target.id else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            self.mergeTargetGroupID = target.id
                            self.incomingDropApp = self.dragPreviewGroups.first?.primaryApp
                        }
                    }
                    mergeHoverWorkItem = mergeWork
                    // Observed at `0x10010f8f0`: `0.10s` (`0x3fb999999999999a`) dwell before activating merge target
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: mergeWork)
                }
                return
            } else {
                mergeHoverWorkItem?.cancel()
                pendingMergeCandidateID = nil
                clearMergeTarget()

                let insertAfter = dxFromCenter >= 0
                let key = "\(target.id)-\(insertAfter ? "after" : "before")"
                if lastReorderTargetKey != key {
                    lastReorderTargetKey = key
                    reorderHoverWorkItem?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self = self, self.isDragging else { return }
                        // Observed at `0x10010d830`: `0.36s` `CAMediaTimingFunction(name: .easeInEaseOut)`
                        withAnimation(.easeInOut(duration: 0.36)) {
                            appManager.reorderGroup(
                                draggedID: primaryDraggedID,
                                targetID: target.id,
                                insertAfter: insertAfter,
                                save: false
                            )
                        }
                        self.refreshCurrentPageSlotFrames()
                    }
                    reorderHoverWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
                }
                return
            }
        }

        // Not hovering any cell: clear merge target and check `.moveToEnd` (`pendingDropAction == 3`, `0x100113c98`)
        mergeHoverWorkItem?.cancel()
        pendingMergeCandidateID = nil
        clearMergeTarget()

        if let lastIdx = pageGroups.indices.last {
            let lastGroup = pageGroups[lastIdx]
            let lastFrame = (state.browsingStyle == .paged && containerSize.width > 200)
                ? mainGridSlotRect(forSlotIndex: lastIdx)
                : (cellFrames[lastGroup.id] ?? .zero)

            if lastGroup.id != primaryDraggedID && !lastFrame.isEmpty {
                let isAfterLast = (point.y > lastFrame.maxY) || (point.y >= lastFrame.minY && point.x > lastFrame.maxX + 12)
                if isAfterLast {
                    let key = "moveToEnd-\(state.currentPage)"
                    if lastReorderTargetKey != key {
                        lastReorderTargetKey = key
                        reorderHoverWorkItem?.cancel()
                        let work = DispatchWorkItem { [weak self] in
                            guard let self = self, self.isDragging else { return }
                            withAnimation(.easeInOut(duration: 0.36)) {
                                appManager.moveGroupToEndOfPage(
                                    draggedID: primaryDraggedID,
                                    targetPage: state.currentPage,
                                    save: false
                                )
                            }
                            self.refreshCurrentPageSlotFrames()
                        }
                        reorderHoverWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
                    }
                }
            }
        } else if state.browsingStyle == .paged {
            // Empty page: move dragged group onto this page immediately
            let key = "moveToEmptyPage-\(state.currentPage)"
            if lastReorderTargetKey != key {
                lastReorderTargetKey = key
                withAnimation(.easeInOut(duration: 0.36)) {
                    appManager.moveGroupToEndOfPage(
                        draggedID: primaryDraggedID,
                        targetPage: state.currentPage,
                        save: false
                    )
                }
                refreshCurrentPageSlotFrames()
            }
        }
    }

    private func evaluateOpenedFolderHover(folderID: String, draggedAppID: String, at point: CGPoint) {
        let appManager = ApplicationManager.shared
        guard let folder = appManager.allGroups.first(where: { $0.id == folderID }) else { return }

        for targetApp in folder.apps where targetApp.id != draggedAppID {
            guard let frame = openedFolderAppFrames[targetApp.id] else { continue }
            guard frame.insetBy(dx: -4, dy: -4).contains(point) else { continue }
            let insertAfter = (point.x - frame.minX) > frame.width * 0.5
            let key = "folder-\(targetApp.id)-\(insertAfter)"
            if lastReorderTargetKey != key {
                lastReorderTargetKey = key
                reorderHoverWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.isDragging else { return }
                    withAnimation(.easeInOut(duration: 0.36)) {
                        appManager.reorderAppInFolder(
                            folderID: folderID,
                            draggedAppID: draggedAppID,
                            targetAppID: targetApp.id,
                            insertAfter: insertAfter,
                            save: false
                        )
                    }
                }
                reorderHoverWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
            return
        }

        // Check `.moveToEnd` inside folder (`0x10010d830`)
        if let lastApp = folder.apps.last,
           lastApp.id != draggedAppID,
           let lastFrame = openedFolderAppFrames[lastApp.id] {
            if point.y > lastFrame.maxY || (point.y >= lastFrame.minY && point.x > lastFrame.maxX + 10) {
                let key = "folder-moveToEnd"
                if lastReorderTargetKey != key {
                    lastReorderTargetKey = key
                    reorderHoverWorkItem?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self = self, self.isDragging else { return }
                        withAnimation(.easeInOut(duration: 0.36)) {
                            appManager.moveAppToEndOfFolder(folderID: folderID, draggedAppID: draggedAppID, save: false)
                        }
                    }
                    reorderHoverWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
                }
            }
        }
    }

    // MARK: - Rubber-Band Marquee Selection (`SelectionMarqueeView`, `0x100140000`)

    public func updateMarqueeSelection(start: CGPoint, current: CGPoint) {
        let appManager = ApplicationManager.shared
        guard appManager.openedFolderID == nil, !isDragging else { return }
        if !isMarqueeSelecting {
            isMarqueeSelecting = true
            marqueeStartPoint = start
        }
        marqueeCurrentPoint = current
        let rect = marqueeRect
        let pageGroups = AppState.shared.browsingStyle == .paged
            ? appManager.groups(forPage: AppState.shared.currentPage)
            : appManager.filteredGroups

        var selected = Set<String>()
        for (idx, grp) in pageGroups.enumerated() {
            let cellRect = (AppState.shared.browsingStyle == .paged && containerSize.width > 200)
                ? mainGridSlotRect(forSlotIndex: idx)
                : (cellFrames[grp.id] ?? .zero)
            if !cellRect.isEmpty && rect.intersects(cellRect.insetBy(dx: 12, dy: 12)) {
                selected.insert(grp.id)
            }
        }
        appManager.selectedGroupIDs = selected
    }

    public func endMarqueeSelection() {
        isMarqueeSelecting = false
    }

    private func clearMergeTarget() {
        if mergeTargetGroupID != nil || incomingDropApp != nil {
            withAnimation(.easeInOut(duration: 0.18)) {
                mergeTargetGroupID = nil
                incomingDropApp = nil
            }
        }
    }

    public func resetDragState() {
        reorderHoverWorkItem?.cancel()
        mergeHoverWorkItem?.cancel()
        edgeFlipWorkItem?.cancel()
        longPressWorkItem?.cancel()
        activeEdgeDirection = 0
        lastReorderTargetKey = nil
        pendingMergeCandidateID = nil
        activePressGroup = nil
        activePressFolder = nil
        activePressFolderApp = nil
        pressStartLocation = .zero
        pressedItemID = nil
        isDragging = false
        isCommittingDrop = false
        dropCommitScale = 1.0
        draggedGroupIDs = []
        dragPreviewGroups = []
        draggedFolderID = nil
        draggedFolderApp = nil
        mergeTargetGroupID = nil
        incomingDropApp = nil
    }
}

/// Floating Drag Preview replicating `LaunchpadDragPreviewView`, `LaunchpadDragCardView`, and `LaunchpadDragCountBadge`
/// (`0x100145cf0`–`0x10014a500`):
/// - Lifts the dragged icon(s) at `0.85` opacity and `1.06x` scale
/// - In multi-drag (`dragPreviewGroups.count > 1`), fans up to 5 cards with slight rotation/offset and shows a red capsule count badge
public struct LaunchpadDragPreviewOverlay: View {
    @ObservedObject var dragSession = LaunchpadDragSession.shared
    @ObservedObject var state = AppState.shared

    private let iconDimension: CGFloat = 96.0

    public var body: some View {
        let previewItems = Array(dragSession.dragPreviewGroups.prefix(5))
        let totalCount = dragSession.dragPreviewGroups.count

        ZStack(alignment: .topTrailing) {
            ForEach(Array(previewItems.enumerated().reversed()), id: \.element.id) { index, grp in
                let fanAngle: Double = index == 0 ? 0 : (index % 2 == 1 ? Double(index) * 4.5 : -Double(index) * 4.0)
                let fanOffset = CGSize(
                    width: CGFloat(index) * (index % 2 == 1 ? 6.0 : -5.0),
                    height: -CGFloat(index) * 4.0
                )
                dragCardView(for: grp, isPrimary: index == 0 && totalCount == 1)
                    .rotationEffect(.degrees(fanAngle))
                    .offset(fanOffset)
            }

            // `LaunchpadDragCountBadge` (`0x100149800`) when multi-dragging > 1 items
            if totalCount > 1 {
                Text("\(totalCount)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(
                        Capsule()
                            .fill(Color.red)
                            .overlay(Capsule().stroke(Color.white, lineWidth: 1.8))
                    )
                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                    .offset(x: 6, y: -6)
            }
        }
        .scaleEffect(dragSession.dropCommitScale)
        .opacity(0.88)
        .position(x: dragSession.cursorLocation.x, y: dragSession.cursorLocation.y)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func dragCardView(for group: LaunchpadGroup, isPrimary: Bool) -> some View {
        VStack(spacing: 8) {
            if group.isFolder {
                let boxSize = trunc(iconDimension * 0.81)
                let d2 = round(max(4.0, boxSize * 0.26))
                let cornerRadius = round((iconDimension - boxSize) * 0.5 + d2)
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.36), lineWidth: 1)
                        )
                        .frame(width: boxSize, height: boxSize)
                        .shadow(color: .black.opacity(0.38), radius: 12, x: 0, y: 6)

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
            } else if let app = group.primaryApp {
                Image(nsImage: AppIconRepository.shared.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconDimension, height: iconDimension)
                    .shadow(color: .black.opacity(0.42), radius: 14, x: 0, y: 8)
            }

            if isPrimary && !state.hideNames {
                Text(group.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                    .lineLimit(1)
                    .frame(width: iconDimension + 16, height: 20)
            }
        }
    }
}

/// Main Launchpad interactive interface replicating `LaunchpadContentView`, `LaunchpadAppView`, `LaunchpadFolderView`
public struct LaunchpadRootView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @ObservedObject var pager = PagerInteractionState.shared
    @ObservedObject var dragSession = LaunchpadDragSession.shared
    @FocusState private var isSearchFocused: Bool

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

                // 2. Symmetrical Main Foreground Layout (`0.94` scale + `0.001` opacity when folder is open, matching `0x100124dc8`)
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

                        if !appManager.selectedGroupIDs.isEmpty && !dragSession.isDragging {
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

                // 5. Rubber-band Marquee Selection Rectangle (`SelectionMarqueeView` at `0x100140000`)
                if dragSession.isMarqueeSelecting {
                    let mRect = dragSession.marqueeRect
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.75), lineWidth: 1.2)
                        )
                        .frame(width: mRect.width, height: mRect.height)
                        .position(x: mRect.midX, y: mRect.midY)
                        .allowsHitTesting(false)
                        .zIndex(8)
                }

                // 6. Opened Folder Overlay (`LaunchpadContentView+Folder.swift` `0x10011c578`–`0x100128488`)
                if let folderID = appManager.openedFolderID,
                   let folder = appManager.allGroups.first(where: { $0.id == folderID }) {
                    OpenedFolderOverlayView(
                        group: folder,
                        containerSize: geo.size,
                        gridAreaHeight: gridAreaHeight,
                        sourceFolderRect: dragSession.folderIconFrames[folderID] ?? dragSession.lastOpenedFolderSourceRect
                    )
                    .id(folderID)
                    .zIndex(10)
                }

                // 7. Floating Drag Preview (`LaunchpadDragPreviewView` `0x100145cf0`)
                if dragSession.isDragging && !dragSession.dragPreviewGroups.isEmpty {
                    LaunchpadDragPreviewOverlay()
                        .zIndex(20)
                }

                // 7b. Screen-Edge Drag Page-Flip Indicator (`0x10011064c`–`0x1001124e4`)
                if dragSession.isDragging && dragSession.activeEdgeDirection != 0 {
                    HStack {
                        if dragSession.activeEdgeDirection < 0 {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 36, height: 120)
                                Image(systemName: "chevron.compact.left")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(.leading, 10)
                            .transition(.opacity.combined(with: .scale))
                        }
                        Spacer()
                        if dragSession.activeEdgeDirection > 0 {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 36, height: 120)
                                Image(systemName: "chevron.compact.right")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(.trailing, 10)
                            .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.18), value: dragSession.activeEdgeDirection)
                    .zIndex(25)
                }

                // 8. Status Toast (`LaunchpadContentView.showStatusMessage` `0x10010f7c4`)
                if let toast = appManager.statusToastMessage {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.68))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
                            )
                            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
                            .padding(.bottom, bottomFooterHeight + 16)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(30)
                }
            }
            .coordinateSpace(name: "LaunchpadRootSpace")
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 0 : 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isFullScreen ? 0 : 24, style: .continuous)
                    .stroke(Color.white.opacity(isFullScreen ? 0 : 0.22), lineWidth: isFullScreen ? 0 : 1)
            )
            .onChange(of: geo.size) { _, newSize in
                dragSession.containerSize = newSize
            }
            .onChange(of: pageCount) { _, newPageCount in
                if state.currentPage >= newPageCount {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        state.currentPage = max(0, newPageCount - 1)
                    }
                }
            }
            .onAppear {
                dragSession.containerSize = geo.size
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFocused = true
                }
            }
        }
        .ignoresSafeArea(.all)
    }

    // MARK: - Blank Area Click Dismissal Handler
    private func handleBlankAreaTap() {
        if appManager.inlineRenamingGroupID != nil || appManager.inlineRenamingFolderAppID != nil {
            appManager.inlineRenamingGroupID = nil
            appManager.inlineRenamingFolderAppID = nil
        } else if appManager.openedFolderID != nil {
            withAnimation(.easeInOut(duration: 0.28)) {
                appManager.openedFolderID = nil
            }
        } else if appManager.isUninstallJiggleMode {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                appManager.isUninstallJiggleMode = false
            }
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
                    guard !dragSession.isDragging,
                          dragSession.pressedItemID == nil,
                          !dragSession.isMarqueeSelecting else {
                        return
                    }
                    pager.isDragging = true
                    let atFirst = safePage <= 0 && value.translation.width > 0
                    let atLast = safePage >= pageCount - 1 && value.translation.width < 0
                    pager.dragOffset = value.translation.width * ((atFirst || atLast) ? 0.25 : 1.0)
                }
                .onEnded { value in
                    guard pager.isDragging else { return }
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

    /// Renders an exact `rows × cols` matrix where every slot has identical `(cellWidth, cellHeight)`.
    /// Keying `ForEach` by stable `group.id` and positioning each cell at its mathematical `(centerX, centerY)`
    /// replicates `LaunchpadContentView.layout(animated: true)` (`0.36s` `.easeInEaseOut` at `0x10010d830`),
    /// so sibling icons smoothly glide in 2D space (horizontally within a row and diagonally across row boundaries).
    @ViewBuilder
    private func symmetricPageMatrix(
        pageGroups: [LaunchpadGroup],
        cols: Int,
        rows: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        horizontalMargin: CGFloat
    ) -> some View {
        let gridWidth = cellWidth * CGFloat(cols)
        let gridHeight = cellHeight * CGFloat(rows)
        let visibleGroups = Array(pageGroups.prefix(rows * cols))

        ZStack {
            // Blank space in horizontal margins & between cells dismisses LaunchOS or starts marquee selection
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleBlankAreaTap()
                }
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .named("LaunchpadRootSpace"))
                        .onChanged { value in
                            dragSession.updateMarqueeSelection(start: value.startLocation, current: value.location)
                        }
                        .onEnded { _ in
                            dragSession.endMarqueeSelection()
                        }
                )

            ZStack(alignment: .topLeading) {
                ForEach(Array(visibleGroups.enumerated()), id: \.element.id) { idx, group in
                    let r = idx / cols
                    let c = idx % cols
                    let centerX = (CGFloat(c) + 0.5) * cellWidth
                    let centerY = (CGFloat(r) + 0.5) * cellHeight

                    ZStack(alignment: .center) {
                        Color.white.opacity(0.001)
                            .frame(width: cellWidth, height: cellHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                handleBlankAreaTap()
                            }

                        gridCell(for: group)
                    }
                    .frame(width: cellWidth, height: cellHeight)
                    .position(x: centerX, y: centerY)
                    .animation(.easeInOut(duration: 0.36), value: idx)
                }
            }
            .frame(width: gridWidth, height: gridHeight)
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
        let totalRows = max(1, Int(ceil(Double(allItems.count) / Double(cols))))
        let contentHeight = CGFloat(totalRows) * cellHeight

        return ScrollView(.vertical, showsIndicators: true) {
            ZStack {
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBlankAreaTap()
                    }

                ZStack(alignment: .topLeading) {
                    ForEach(Array(allItems.enumerated()), id: \.element.id) { idx, group in
                        let r = idx / cols
                        let c = idx % cols
                        let centerX = (CGFloat(c) + 0.5) * cellWidth
                        let centerY = (CGFloat(r) + 0.5) * cellHeight

                        ZStack(alignment: .center) {
                            Color.white.opacity(0.001)
                                .frame(width: cellWidth, height: cellHeight)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    handleBlankAreaTap()
                                }

                            gridCell(for: group)
                        }
                        .frame(width: cellWidth, height: cellHeight)
                        .position(x: centerX, y: centerY)
                        .animation(.easeInOut(duration: 0.36), value: idx)
                    }
                }
                .frame(width: usableWidth, height: contentHeight)
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
                    isMergeTarget: dragSession.mergeTargetGroupID == group.id,
                    incomingDropApp: dragSession.mergeTargetGroupID == group.id ? dragSession.incomingDropApp : nil
                )
            } else if let app = group.primaryApp {
                LaunchpadAppCellView(
                    group: group,
                    app: app,
                    isMergeTarget: dragSession.mergeTargetGroupID == group.id
                )
            }
        }
        .opacity(dragSession.isGroupHiddenAsPlaceholder(group.id) ? 0.0 : 1.0)
        .background(
            GeometryReader { cellGeo in
                Color.clear
                    .onAppear {
                        let rect = cellGeo.frame(in: .named("LaunchpadRootSpace"))
                        dragSession.cellFrames[group.id] = rect
                        if group.isFolder {
                            dragSession.folderIconFrames[group.id] = rect
                        }
                    }
                    .onChange(of: cellGeo.frame(in: .named("LaunchpadRootSpace"))) { _, newRect in
                        dragSession.cellFrames[group.id] = newRect
                        if group.isFolder {
                            dragSession.folderIconFrames[group.id] = newRect
                        }
                    }
            }
        )
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("LaunchpadRootSpace"))
                .onChanged { value in
                    let dist = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                    if dist <= 4.0 && !dragSession.isDragging {
                        dragSession.beginPress(
                            itemID: group.id,
                            group: group,
                            startLocation: value.startLocation
                        )
                    } else {
                        dragSession.updateMainGridDrag(for: group, locationInRoot: value.location)
                    }
                }
                .onEnded { value in
                    let dist = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                    if dragSession.isDragging {
                        dragSession.endMainGridDrag()
                    } else {
                        dragSession.cancelPress()
                        if dist <= 4.0 {
                            handleCellClick(group: group)
                        }
                    }
                }
        )
    }

    private func handleCellClick(group: LaunchpadGroup) {
        if appManager.inlineRenamingGroupID != nil && appManager.inlineRenamingGroupID != group.id {
            appManager.inlineRenamingGroupID = nil
        }
        if NSEvent.modifierFlags.contains(.command) {
            if appManager.selectedGroupIDs.contains(group.id) {
                appManager.selectedGroupIDs.remove(group.id)
            } else {
                appManager.selectedGroupIDs.insert(group.id)
            }
            return
        }
        if group.isFolder {
            dragSession.lastOpenedFolderSourceRect = dragSession.folderIconFrames[group.id] ?? dragSession.cellFrames[group.id]
            withAnimation(.easeInOut(duration: 0.28)) {
                appManager.openedFolderID = group.id
            }
        } else if let app = group.primaryApp {
            if appManager.isUninstallJiggleMode {
                UninstallWindowController.shared.present(for: app)
            } else {
                LaunchpadWindowController.shared.hide()
                appManager.launchApp(app)
            }
        }
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
                            .onHover { hovering in
                                guard hovering, dragSession.isDragging, index != state.currentPage else { return }
                                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                                    state.currentPage = index
                                }
                                dragSession.handlePageSwitchDuringDrag(to: index)
                            }
                            .onTapGesture {
                                guard index != state.currentPage else { return }
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                                    state.currentPage = index
                                }
                                dragSession.handlePageSwitchDuringDrag(to: index)
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

/// Replicates `LaunchpadAppView` (`0x1000f6c34`–`0x1000fc600`) & `LaunchpadGroupView` (`0x1001599c4`–`0x10015f64c`):
/// - `layout` (`0x1000f6c5c`): `minSide = 96`, `d1 = trunc(minSide * 0.80) = 76`, `d2 = round(max(4.0, d1 * 0.26)) = 20`,
///   `mergeView` cornerRadius = `round((minSide - d1) * 0.5 + d2) = 30`.
/// - `mergeView` (`0x1000f92b0`): Glass merge indicator (`merge.opacity.in` / `merge.opacity.out`) when `isMergeTarget == true`.
/// - `uninstallButton` (`0x1000f9a18`): Size `d9 = min(24.0, max(12.0, floor(minSide * 0.24))) = 23`, top-left spring scale `0.72 <-> 1.0`.
/// - Jiggle animation (`0x10015bbc8`): Rotation `±1.72°` (`0.03 rad`, `0.115s`) + vertical bounce `±1.1px` (`0.13s`).
/// - In-place rename editor (`titleEditorView` at `0x1000f8848`) & full context menu (`0x1000f6f30` / `0x100142c5c`).
public struct LaunchpadAppCellView: View {
    public let group: LaunchpadGroup
    public let app: LaunchpadApp
    public var isMergeTarget: Bool = false

    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @ObservedObject var dragSession = LaunchpadDragSession.shared
    @LocalState private var isHovered: Bool = false
    @LocalState private var editedTitle: String = ""
    @FocusState private var isTitleFocused: Bool

    private let iconDimension: CGFloat = 96.0

    private var isSelected: Bool {
        appManager.selectedGroupIDs.contains(group.id)
    }

    private var isPressed: Bool {
        dragSession.pressedItemID == group.id
    }

    private var isSearchSelected: Bool {
        !appManager.currentSearchQuery.isEmpty && appManager.selectedSearchAppID == app.id
    }

    private var isRenamingInline: Bool {
        appManager.inlineRenamingGroupID == group.id
    }

    /// Observed at `0x1000f6c5c`: `d1 = trunc(minSide * 0.80)`, `d2 = round(max(4.0, d1 * 0.26))`, `r = round((minSide - d1) * 0.5 + d2)`
    private var mergeCornerRadius: CGFloat {
        let d1 = trunc(iconDimension * 0.80)
        let d2 = round(max(4.0, d1 * 0.26))
        return round((iconDimension - d1) * 0.5 + d2)
    }

    /// Observed at `0x1000f9a18`: `d9 = min(24.0, max(12.0, floor(minSide * 0.24)))`
    private var uninstallButtonSize: CGFloat {
        min(24.0, max(12.0, floor(iconDimension * 0.24)))
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                // `mergeView` (`0x1000f92b0`: `merge.opacity.in` / `merge.opacity.out` when hovering center merge zone)
                RoundedRectangle(cornerRadius: mergeCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isMergeTarget ? 0.26 : 0.0))
                    .overlay(
                        RoundedRectangle(cornerRadius: mergeCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(isMergeTarget ? 0.42 : 0.0), lineWidth: 1.2)
                    )
                    .frame(width: iconDimension, height: iconDimension)
                    .scaleEffect(isMergeTarget ? 1.08 : 0.92)
                    .animation(.easeInOut(duration: 0.18), value: isMergeTarget)

                // Selection highlight layer (`highlightLayer`, `#0x150`)
                if isSelected {
                    RoundedRectangle(cornerRadius: mergeCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: mergeCornerRadius, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.9), lineWidth: 2.2)
                        )
                        .frame(width: iconDimension, height: iconDimension)
                }

                Image(nsImage: AppIconRepository.shared.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconDimension, height: iconDimension)
                    .opacity(isPressed ? 0.80 : 1.0)
                    .scaleEffect(isSearchSelected ? 1.05 : (isMergeTarget ? 1.08 : (isHovered && !dragSession.isDragging ? 1.05 : 1.0)))
                    .shadow(
                        color: isSearchSelected ? Color.accentColor.opacity(0.45) : .black.opacity(0.35),
                        radius: isSearchSelected ? 10 : (isHovered ? 8 : 5),
                        x: 0,
                        y: 4
                    )

                // `uninstallButton` (`0x1000f9a18`–`0x1000fa66c`: `uninstallButton.bouncy.scale` spring `0.72 <-> 1.0`)
                if appManager.isUninstallJiggleMode {
                    Button {
                        UninstallWindowController.shared.present(for: app)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.92))
                                .frame(width: uninstallButtonSize, height: uninstallButtonSize)
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: uninstallButtonSize))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red)
                        }
                        .shadow(color: .black.opacity(0.32), radius: 3, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 0, y: -0.2 * uninstallButtonSize)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            }
            // Observed at `0x10015bbc8`: `launchos.uninstall.jiggle.rotation` (`±0.03 rad` = `±1.72°`) + `launchos.uninstall.jiggle.bounce` (`±1.1px`)
            .rotationEffect(.degrees(appManager.isUninstallJiggleMode ? -1.72 : 0))
            .offset(y: appManager.isUninstallJiggleMode ? -1.1 : 0)
            .animation(
                appManager.isUninstallJiggleMode
                    ? .easeInOut(duration: 0.115).repeatForever(autoreverses: true)
                    : .spring(response: 0.22, dampingFraction: 0.8),
                value: appManager.isUninstallJiggleMode
            )

            if !state.hideNames {
                if isRenamingInline {
                    TextField("应用名称", text: $editedTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.0, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.65))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.85), lineWidth: 1)
                                )
                        )
                        .frame(width: iconDimension + 16, height: 22)
                        .focused($isTitleFocused)
                        .onSubmit {
                            commitInlineRename()
                        }
                        .onAppear {
                            editedTitle = app.displayName
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isTitleFocused = true
                            }
                        }
                } else {
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
        .contextMenu {
            appContextMenuContent
        }
    }

    private func commitInlineRename() {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appManager.renameGroup(groupID: group.id, newName: trimmed)
        }
        appManager.inlineRenamingGroupID = nil
        isTitleFocused = false
    }

    @ViewBuilder
    private var appContextMenuContent: some View {
        // Multi-Select Context Menu (`LaunchpadContentView+MultiDrag.contextMenuForItem:` at `0x100142c5c`)
        if isSelected && appManager.selectedGroupIDs.count > 1 {
            let selectedIDs = Array(appManager.selectedGroupIDs)
            Text("已选中 \(selectedIDs.count) 项")

            Button("打开") {
                LaunchpadWindowController.shared.hide()
                let apps = appManager.allGroups.filter { appManager.selectedGroupIDs.contains($0.id) }.flatMap { $0.apps }
                for item in apps {
                    appManager.launchApp(item)
                }
            }

            Button("合并为新文件夹") {
                withAnimation(.easeInOut(duration: 0.28)) {
                    appManager.createFolder(withGroupIDs: appManager.selectedGroupIDs)
                }
            }

            Menu("移动到") {
                ForEach(0..<appManager.totalPages, id: \.self) { p in
                    Button("第 \(p + 1) 页") {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            appManager.moveItemsToPage(groupIDs: selectedIDs, targetPage: p)
                        }
                    }
                    let foldersOnPage = appManager.groups(forPage: p).filter { $0.isFolder && !appManager.selectedGroupIDs.contains($0.id) }
                    ForEach(foldersOnPage) { folder in
                        Button("    ↳ \(folder.name)") {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                appManager.moveAppsToFolder(groupIDs: selectedIDs, targetFolderID: folder.id)
                            }
                        }
                    }
                }
                Divider()
                Button("新建页面") {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        appManager.moveItemsToPage(groupIDs: selectedIDs, targetPage: appManager.totalPages)
                    }
                }
            }

            Divider()

            Button("隐藏") {
                withAnimation(.easeInOut(duration: 0.24)) {
                    appManager.hideApps(inGroupIDs: appManager.selectedGroupIDs)
                }
            }
        } else {
            // Single App Context Menu (`LaunchpadAppView.menu(for:)` at `0x1000f6f30`)
            Button {
                LaunchpadWindowController.shared.hide()
                appManager.launchApp(app)
            } label: {
                Label("打开", systemImage: "arrow.up.forward.app")
            }

            Button {
                appManager.revealInFinder(app)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Button {
                appManager.addAppToDock(app)
            } label: {
                Label("添加到程序坞", systemImage: "dock.rectangle")
            }

            Divider()

            // `Move to` submenu (`0x1000f74d8`–`0x1000f7bc8`: Pages + indented `"    ↳ "` folders + `New Page`)
            Menu("移动到") {
                if state.browsingStyle == .paged {
                    ForEach(0..<appManager.totalPages, id: \.self) { p in
                        Button("第 \(p + 1) 页") {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                appManager.moveGroupToPage(group.id, targetPage: p)
                            }
                        }
                        let foldersOnPage = appManager.groups(forPage: p).filter { $0.isFolder }
                        ForEach(foldersOnPage) { targetFolder in
                            Button("    ↳ \(targetFolder.name)") {
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    appManager.mergeGroups(draggedIDs: [group.id], intoTargetID: targetFolder.id)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("新建页面") {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            appManager.moveGroupToPage(group.id, targetPage: appManager.totalPages)
                        }
                    }
                } else {
                    let folders = appManager.allGroups.filter(\.isFolder)
                    ForEach(folders) { targetFolder in
                        Button(targetFolder.name) {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                appManager.mergeGroups(draggedIDs: [group.id], intoTargetID: targetFolder.id)
                            }
                        }
                    }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.24)) {
                    appManager.hideApp(app)
                }
            } label: {
                Label("隐藏", systemImage: "eye.slash")
            }

            Button {
                editedTitle = app.displayName
                appManager.inlineRenamingGroupID = group.id
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button {
                appManager.showFinderGetInfo(app)
            } label: {
                Label("显示简介", systemImage: "info.circle")
            }

            Divider()

            Button(role: .destructive) {
                UninstallWindowController.shared.present(for: app)
            } label: {
                Label("卸载...", systemImage: "trash")
            }
        }
    }
}

/// Replicates `LaunchpadFolderView` (`0x100153b98`–`0x1001599c0`) & `LaunchpadGroupView`:
/// - `layout` (`0x100154454`): `minSide = 96`, `d0 = trunc(minSide * 0.81) = 77`, `d2 = round(max(4.0, d0 * 0.26)) = 20`.
/// - `folderMergeScale` (`0x100153cac`–`0x100153f80`): Scales `glassView` to `1.24x` (`0x3ff3d70a3d70a3d7`) over `0.18s` when `isMergeTarget == true`.
/// - Live 3x3 Preview Grid (`0x100154630`–`0x100154ad4`): Displays up to 9 icons; when `incomingDropApp` is non-nil (`incomingDropAppID` at `0x100154860`),
///   previews the incoming app icon live in the 9th slot of the 3x3 grid!
/// - Context Menu (`0x100156808`): `Open`, `Rename` (in-place editor), `Move to` (`Page N` / `New Page`), `Ungroup` (`0x1001429c0`).
public struct LaunchpadFolderCellView: View {
    public let group: LaunchpadGroup
    public var isMergeTarget: Bool = false
    public var incomingDropApp: LaunchpadApp? = nil

    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @ObservedObject var dragSession = LaunchpadDragSession.shared
    @LocalState private var isHovered: Bool = false
    @LocalState private var editedTitle: String = ""
    @FocusState private var isTitleFocused: Bool

    private let iconDimension: CGFloat = 96.0
    /// Observed at `0x100154454`: `d0 = trunc(minSide * 0.81)`
    private var folderBoxDimension: CGFloat { trunc(iconDimension * 0.81) }

    private var isSelected: Bool {
        appManager.selectedGroupIDs.contains(group.id)
    }

    private var isPressed: Bool {
        dragSession.pressedItemID == group.id
    }

    private var isRenamingInline: Bool {
        appManager.inlineRenamingGroupID == group.id
    }

    /// Combines the folder's existing apps with `incomingDropApp` in the 3x3 preview (up to 9 slots, `0x100154860`)
    private var previewApps: [LaunchpadApp] {
        var list = Array(group.apps.prefix(9))
        if let incoming = incomingDropApp, !list.contains(where: { $0.id == incoming.id }) {
            if list.count >= 9 {
                list[8] = incoming
            } else {
                list.append(incoming)
            }
        }
        return list
    }

    public var body: some View {
        let boxSize = folderBoxDimension
        let boxCornerRadius = round(max(4.0, boxSize * 0.26))
        VStack(spacing: 8) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: boxCornerRadius + 4, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: boxCornerRadius + 4, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.9), lineWidth: 2.2)
                        )
                        .frame(width: boxSize + 8, height: boxSize + 8)
                }

                // `glassView` (`#0x168`): scales to `1.24x` over `0.18s` (`folderMergeScale` at `0x100153cac`) when `isMergeTarget == true`
                RoundedRectangle(cornerRadius: boxCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isMergeTarget ? 0.34 : 0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: boxCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(isMergeTarget ? 0.52 : 0.32), lineWidth: 1)
                    )
                    .frame(width: boxSize, height: boxSize)
                    .scaleEffect(isMergeTarget ? 1.24 : 1.0)
                    .animation(.easeInOut(duration: 0.18), value: isMergeTarget)
                    .shadow(color: .black.opacity(0.28), radius: isHovered ? 10 : 5, x: 0, y: 4)

                // `contentView` (`FolderPreviewGridView`, `#0x170`): 3x3 icon preview grid
                let currentPreviewApps = previewApps
                let miniSpacing: CGFloat = 3.0
                let miniSize = floor((boxSize * 0.78 - miniSpacing * 2) / 3.0)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(miniSize), spacing: miniSpacing), count: 3),
                    alignment: .leading,
                    spacing: miniSpacing
                ) {
                    ForEach(currentPreviewApps) { app in
                        Image(nsImage: AppIconRepository.shared.icon(for: app, pointSize: 48))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: miniSize, height: miniSize)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(
                    width: miniSize * 3 + miniSpacing * 2,
                    height: miniSize * 3 + miniSpacing * 2,
                    alignment: .topLeading
                )
                .animation(.easeInOut(duration: 0.18), value: currentPreviewApps.map { $0.id })
            }
            .frame(width: iconDimension, height: iconDimension)
            .opacity(isPressed ? 0.80 : 1.0)
            .scaleEffect(isHovered && !dragSession.isDragging && !isMergeTarget ? 1.05 : 1.0)
            .rotationEffect(.degrees(appManager.isUninstallJiggleMode ? -1.72 : 0))
            .offset(y: appManager.isUninstallJiggleMode ? -1.1 : 0)
            .animation(
                appManager.isUninstallJiggleMode
                    ? .easeInOut(duration: 0.115).repeatForever(autoreverses: true)
                    : .spring(response: 0.22, dampingFraction: 0.8),
                value: appManager.isUninstallJiggleMode
            )

            if !state.hideNames {
                if isRenamingInline {
                    TextField("未命名文件夹", text: $editedTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.0, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.65))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.85), lineWidth: 1)
                                )
                        )
                        .frame(width: iconDimension + 16, height: 22)
                        .focused($isTitleFocused)
                        .onSubmit {
                            commitInlineRename()
                        }
                        .onAppear {
                            editedTitle = group.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isTitleFocused = true
                            }
                        }
                } else {
                    Text(group.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                        .frame(width: iconDimension + 6, height: 18, alignment: .center)
                }
            }
        }
        .frame(width: iconDimension + 6)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            // `LaunchpadFolderView.menu(for:)` (`0x100156808`)
            Button {
                dragSession.lastOpenedFolderSourceRect = dragSession.folderIconFrames[group.id] ?? dragSession.cellFrames[group.id]
                withAnimation(.easeInOut(duration: 0.28)) {
                    appManager.openedFolderID = group.id
                }
            } label: {
                Label("打开", systemImage: "folder")
            }

            Button {
                editedTitle = group.name
                appManager.inlineRenamingGroupID = group.id
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            if state.browsingStyle == .paged {
                Menu("移动到") {
                    ForEach(0..<appManager.totalPages, id: \.self) { p in
                        Button("第 \(p + 1) 页") {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                appManager.moveGroupToPage(group.id, targetPage: p)
                            }
                        }
                    }
                    Divider()
                    Button("新建页面") {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            appManager.moveGroupToPage(group.id, targetPage: appManager.totalPages)
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    appManager.ungroupFolder(groupID: group.id)
                }
            } label: {
                Label("解散文件夹", systemImage: "folder.badge.minus")
            }
        }
    }

    private func commitInlineRename() {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appManager.renameGroup(groupID: group.id, newName: trimmed)
        }
        appManager.inlineRenamingGroupID = nil
        isTitleFocused = false
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
/// - `openedFolderClipView` / `openedFolderBlurView` (`#0x9d0` / `#0x9d8`): `NSGlassEffectView` card sized to `cols * cellWidth` wide and `visibleRows * cellHeight + 2 * vPad` tall (`visibleRows = max(1, min(totalRows, maxRows))`), cornerRadius `max(16.0, min(cellWidth, cellHeight) * 0.24)` (`30.0` in window mode)
/// - `0.28s` `.easeInEaseOut` hero morph (`0x10011e950`–`0x100126a14`) from/to the clicked folder cell's exact frame (`sourceFolderRect`)
public struct OpenedFolderOverlayView: View {
    public let group: LaunchpadGroup
    public let containerSize: CGSize
    public let gridAreaHeight: CGFloat
    public var sourceFolderRect: CGRect? = nil

    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @ObservedObject var dragSession = LaunchpadDragSession.shared
    @LocalState private var folderName: String = ""
    @LocalState private var isEditingTitle: Bool = false
    @LocalState private var morphProgress: CGFloat = 0.0
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

        // Hero morph interpolation (`0x10011e950`–`0x100126a14`: `0.28s` `.easeInEaseOut` from folder icon rect)
        let srcRect = sourceFolderRect ?? CGRect(
            x: containerSize.width * 0.5 - 38.0,
            y: containerSize.height * 0.5 - 38.0,
            width: 77.0,
            height: 77.0
        )
        let startOffsetX = srcRect.midX - containerSize.width * 0.5
        let startOffsetY = srcRect.midY - containerSize.height * 0.5
        let startScale = max(0.12, min(0.35, srcRect.width / max(1.0, cardWidth)))
        let currentScale = startScale + (1.0 - startScale) * morphProgress
        let currentOffsetX = startOffsetX * (1.0 - morphProgress)
        let currentOffsetY = startOffsetY * (1.0 - morphProgress) + (isWindowMode ? 0 : -4.0) * morphProgress

        ZStack {
            // 1. `openedFolderBackdropView` (`#0x9c8`, `0x100122360`–`0x100122470`)
            (isWindowMode ? Color.clear : Color.black.opacity(0.20 * Double(morphProgress)))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditingTitle {
                        commitRename()
                    } else if appManager.inlineRenamingFolderAppID != nil {
                        appManager.inlineRenamingFolderAppID = nil
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
                .opacity(Double(morphProgress))

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
                        } else if appManager.inlineRenamingFolderAppID != nil {
                            appManager.inlineRenamingFolderAppID = nil
                        }
                    }

                    // `openedFolderScrollView` (`#0xa00`) & `openedFolderContentView` (`#0xa08`)
                    ScrollView(.vertical, showsIndicators: totalRows > visibleRows) {
                        let contentGridHeight = CGFloat(totalRows) * cellHeight
                        let verticalCenterOffset = max(0.0, (scrollHeight - contentGridHeight) * 0.5)
                        let gridContentWidth = cellWidth * CGFloat(cols)
                        let horizontalGridOffset = max(0.0, (cardWidth - gridContentWidth) * 0.5)

                        ZStack(alignment: .topLeading) {
                            Color.white.opacity(0.001)
                                .frame(width: cardWidth, height: max(scrollHeight, contentGridHeight))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isEditingTitle {
                                        commitRename()
                                    } else if appManager.inlineRenamingFolderAppID != nil {
                                        appManager.inlineRenamingFolderAppID = nil
                                    } else {
                                        closeFolder()
                                    }
                                }

                            ForEach(Array(group.apps.enumerated()), id: \.element.id) { idx, app in
                                let r = idx / cols
                                let c = idx % cols
                                let centerX = horizontalGridOffset + (CGFloat(c) + 0.5) * cellWidth
                                let centerY = verticalCenterOffset + (CGFloat(r) + 0.5) * cellHeight

                                ZStack(alignment: .center) {
                                    Color.white.opacity(0.001)
                                        .frame(width: cellWidth, height: cellHeight)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if isEditingTitle {
                                                commitRename()
                                            } else if appManager.inlineRenamingFolderAppID != nil {
                                                appManager.inlineRenamingFolderAppID = nil
                                            } else {
                                                closeFolder()
                                            }
                                        }

                                    LaunchpadFolderInnerAppCellView(
                                        folderGroup: group,
                                        app: app
                                    )
                                }
                                .frame(width: cellWidth, height: cellHeight)
                                .position(x: centerX, y: centerY)
                                .animation(.easeInOut(duration: 0.36), value: idx)
                            }
                        }
                        .frame(width: cardWidth, height: max(scrollHeight, contentGridHeight), alignment: .topLeading)
                    }
                    .frame(width: cardWidth, height: scrollHeight)
                }
                .frame(width: cardWidth, height: cardHeight)
                .background(
                    GeometryReader { cardGeo in
                        Color.clear
                            .onAppear {
                                dragSession.openedFolderCardFrame = cardGeo.frame(in: .named("LaunchpadRootSpace"))
                            }
                            .onChange(of: cardGeo.frame(in: .named("LaunchpadRootSpace"))) { _, newRect in
                                dragSession.openedFolderCardFrame = newRect
                            }
                    }
                )
            }
            .scaleEffect(currentScale)
            .opacity(Double(max(0.15, morphProgress)))
            .offset(x: currentOffsetX, y: currentOffsetY)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .onAppear {
            folderName = group.name
            withAnimation(.easeInOut(duration: 0.28)) {
                morphProgress = 1.0
            }
        }
    }

    private func closeFolder() {
        commitRename()
        withAnimation(.easeInOut(duration: 0.28)) {
            morphProgress = 0.0
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
/// supporting live drag-reordering inside the folder (`0.36s`), dragging outside the folder card to detach onto the main grid (`0x10011abdc`),
/// `0.55s` long-press uninstall jiggle mode (`±1.72°` rotation + `±1.1px` bounce), in-place renaming, and full context menu.
public struct LaunchpadFolderInnerAppCellView: View {
    public let folderGroup: LaunchpadGroup
    public let app: LaunchpadApp

    @ObservedObject var state = AppState.shared
    @ObservedObject var appManager = ApplicationManager.shared
    @ObservedObject var dragSession = LaunchpadDragSession.shared
    @LocalState private var isHovered: Bool = false
    @LocalState private var editedTitle: String = ""
    @FocusState private var isTitleFocused: Bool

    private let iconDimension: CGFloat = 96.0

    private var isPressed: Bool {
        dragSession.pressedItemID == app.id
    }

    private var isRenamingInline: Bool {
        appManager.inlineRenamingFolderAppID == app.id
    }

    private var uninstallButtonSize: CGFloat {
        min(24.0, max(12.0, floor(iconDimension * 0.24)))
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: AppIconRepository.shared.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconDimension, height: iconDimension)
                    .opacity(isPressed ? 0.80 : 1.0)
                    .scaleEffect(isHovered && !dragSession.isDragging ? 1.05 : 1.0)
                    .shadow(color: .black.opacity(0.35), radius: isHovered ? 10 : 5, x: 0, y: 4)

                if appManager.isUninstallJiggleMode {
                    Button {
                        UninstallWindowController.shared.present(for: app)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.92))
                                .frame(width: uninstallButtonSize, height: uninstallButtonSize)
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: uninstallButtonSize))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .red)
                        }
                        .shadow(color: .black.opacity(0.32), radius: 3, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 0, y: -0.2 * uninstallButtonSize)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
                }
            }
            .rotationEffect(.degrees(appManager.isUninstallJiggleMode ? -1.72 : 0))
            .offset(y: appManager.isUninstallJiggleMode ? -1.1 : 0)
            .animation(
                appManager.isUninstallJiggleMode
                    ? .easeInOut(duration: 0.115).repeatForever(autoreverses: true)
                    : .spring(response: 0.22, dampingFraction: 0.8),
                value: appManager.isUninstallJiggleMode
            )

            if !state.hideNames {
                if isRenamingInline {
                    TextField("应用名称", text: $editedTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.0, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.65))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.85), lineWidth: 1)
                                )
                        )
                        .frame(width: iconDimension + 16, height: 22)
                        .focused($isTitleFocused)
                        .onSubmit {
                            commitInlineRename()
                        }
                        .onAppear {
                            editedTitle = app.displayName
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isTitleFocused = true
                            }
                        }
                } else {
                    Text(app.displayName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: iconDimension + 6, height: 18, alignment: .center)
                }
            }
        }
        .frame(width: iconDimension + 6)
        .opacity(dragSession.isFolderAppHiddenAsPlaceholder(app.id) ? 0.0 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            GeometryReader { cellGeo in
                Color.clear
                    .onAppear {
                        dragSession.openedFolderAppFrames[app.id] = cellGeo.frame(in: .named("LaunchpadRootSpace"))
                    }
                    .onChange(of: cellGeo.frame(in: .named("LaunchpadRootSpace"))) { _, newRect in
                        dragSession.openedFolderAppFrames[app.id] = newRect
                    }
            }
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("LaunchpadRootSpace"))
                .onChanged { value in
                    let dist = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                    if dist <= 4.0 && !dragSession.isDragging {
                        dragSession.beginPress(
                            itemID: app.id,
                            folder: folderGroup,
                            folderApp: app,
                            startLocation: value.startLocation
                        )
                    } else {
                        dragSession.updateFolderAppDrag(folder: folderGroup, app: app, locationInRoot: value.location)
                    }
                }
                .onEnded { value in
                    let dist = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                    if dragSession.isDragging {
                        dragSession.endFolderAppDrag()
                    } else {
                        dragSession.cancelPress()
                        if dist <= 4.0 {
                            if appManager.inlineRenamingFolderAppID != nil && appManager.inlineRenamingFolderAppID != app.id {
                                appManager.inlineRenamingFolderAppID = nil
                            }
                            if appManager.isUninstallJiggleMode {
                                UninstallWindowController.shared.present(for: app)
                            } else {
                                LaunchpadWindowController.shared.hide()
                                appManager.launchApp(app)
                            }
                        }
                    }
                }
        )
        .contextMenu {
            Button {
                LaunchpadWindowController.shared.hide()
                appManager.launchApp(app)
            } label: {
                Label("打开", systemImage: "arrow.up.forward.app")
            }

            Button {
                appManager.revealInFinder(app)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Button {
                appManager.addAppToDock(app)
            } label: {
                Label("添加到程序坞", systemImage: "dock.rectangle")
            }

            Divider()

            Menu("移动到") {
                ForEach(0..<appManager.totalPages, id: \.self) { p in
                    Button("第 \(p + 1) 页") {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            appManager.moveFolderAppToPage(appID: app.id, folderID: folderGroup.id, targetPage: p)
                        }
                    }
                    let foldersOnPage = appManager.groups(forPage: p).filter { $0.isFolder && $0.id != folderGroup.id }
                    ForEach(foldersOnPage) { targetFolder in
                        Button("    ↳ \(targetFolder.name)") {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                appManager.moveFolderAppToAnotherFolder(
                                    appID: app.id,
                                    sourceFolderID: folderGroup.id,
                                    targetFolderID: targetFolder.id
                                )
                            }
                        }
                    }
                }
                Divider()
                Button("新建页面") {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        appManager.moveFolderAppToPage(appID: app.id, folderID: folderGroup.id, targetPage: appManager.totalPages)
                    }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.28)) {
                    appManager.removeAppFromFolder(appID: app.id, folderID: folderGroup.id)
                }
            } label: {
                Label("移出文件夹", systemImage: "folder.badge.minus")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.24)) {
                    appManager.hideApp(app)
                }
            } label: {
                Label("隐藏", systemImage: "eye.slash")
            }

            Button {
                editedTitle = app.displayName
                appManager.inlineRenamingFolderAppID = app.id
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button {
                appManager.showFinderGetInfo(app)
            } label: {
                Label("显示简介", systemImage: "info.circle")
            }

            Divider()

            Button(role: .destructive) {
                UninstallWindowController.shared.present(for: app)
            } label: {
                Label("卸载...", systemImage: "trash")
            }
        }
    }

    private func commitInlineRename() {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appManager.renameAppInFolder(folderID: folderGroup.id, appID: app.id, newName: trimmed)
        }
        appManager.inlineRenamingFolderAppID = nil
        isTitleFocused = false
    }
}
