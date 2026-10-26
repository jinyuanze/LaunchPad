import Cocoa
import CoreGraphics
import os.log

private let gestureLogger = Logger(subsystem: "app.remixdesign.LaunchOS", category: "Gesture")

public enum TrackpadGestureState: Int {
    case idle = 0
    case began = 1
    case tracking = 2
    case completed = 3
    case cancelled = 4
}

@_silgen_name("CoreDockSendNotification")
private func CoreDockSendNotification(_ notification: CFString, _ userInfo: UnsafeMutableRawPointer?)

/// Replicates trackpad multi-touch gesture monitor (`TrackpadGesture`, `GestureConfig`, `TouchSnapshot`)
/// Uses private MultitouchSupport framework direct hardware hooks + CGEventTap session listener (mask 1 << 29).
public final class TrackpadGestureMonitor {
    public static let shared = TrackpadGestureMonitor()

    public static func restoreDesktopIfNeeded() {
        let notificationName: CFString
        if #available(macOS 14.0, *) {
            notificationName = "com.apple.showdesktop.set" as CFString
        } else {
            notificationName = "com.apple.showdesktop.awake" as CFString
        }
        CoreDockSendNotification(notificationName, nil)
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mtDevice: UnsafeMutableRawPointer?
    private var mtStopFunc: (@convention(c) (UnsafeMutableRawPointer) -> Void)?

    private var state: TrackpadGestureState = .idle
    private var initialDistance: CGFloat = 0
    private var lastDistance: CGFloat = 0
    private var lastTriggerTime: Date = .distantPast
    private let cooldown: TimeInterval = 0.45
    private let pinchThreshold: CGFloat = 0.016
    private let maxPinchDistance: CGFloat = 0.18

    private var prefObserver: Any?

    private init() {
        prefObserver = NotificationCenter.default.addObserver(
            forName: .preferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.start()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if self?.eventTap == nil && AXIsProcessTrusted() {
                self?.startEventTap()
            }
        }
    }

    deinit {
        if let observer = prefObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stop()
    }

    public func start() {
        stop()
        let pref = AppState.shared.trackpadGesture
        guard pref != .off else {
            gestureLogger.info("Trackpad listeners stopped (gesture disabled in settings).")
            return
        }

        gestureLogger.info("Trackpad listeners starting. mode: \(pref.rawValue, privacy: .public)")
        startMultitouchSupport()
        startEventTap()
    }

    public func stop() {
        stopEventTap()
        stopMultitouchSupport()
        resetTouchState()
        gestureLogger.info("Trackpad listeners stopped.")
    }

    // MARK: - Event Tap (CGEventType.gesture / 1 << 29)

    private func startEventTap() {
        // Silently check if process is trusted; never pop up intrusive system prompts on launch.
        guard AXIsProcessTrusted() else {
            gestureLogger.info("Accessibility permission not enabled; CGEventTap skipped. MultitouchSupport will handle gestures without prompts.")
            return
        }

        // Mask: (1 << 29) kCGEventGesture, (1 << 30) kCGEventMagnify
        let mask: CGEventMask = (1 << 29) | (1 << 30)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                if type.rawValue == 0xFFFFFFFE || type.rawValue == 0xFFFFFFFF {
                    // Tap disabled by timeout / user input: re-enable
                    if let tapPort = TrackpadGestureMonitor.shared.eventTap {
                        CGEvent.tapEnable(tap: tapPort, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                if type.rawValue == 29 || type.rawValue == 30 {
                    if let nsEvent = NSEvent(cgEvent: event) {
                        let touches = nsEvent.touches(matching: [.began, .moved, .stationary], in: nil)
                        if !touches.isEmpty {
                            var sumX: CGFloat = 0
                            var sumY: CGFloat = 0
                            for t in touches {
                                sumX += t.normalizedPosition.x
                                sumY += t.normalizedPosition.y
                            }
                            let count = CGFloat(touches.count)
                            let cx = sumX / count
                            let cy = sumY / count
                            var sumDist: CGFloat = 0
                            for t in touches {
                                let dx = t.normalizedPosition.x - cx
                                let dy = t.normalizedPosition.y - cy
                                sumDist += hypot(dx, dy)
                            }
                            let avgDist = sumDist / count
                            TrackpadGestureMonitor.shared.processTouchFrame(
                                fingerCount: touches.count,
                                averageDistance: avgDist
                            )
                        } else if nsEvent.phase == .ended || nsEvent.phase == .cancelled {
                            TrackpadGestureMonitor.shared.resetTouchState()
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let tap = tap else {
            gestureLogger.error("Gesture tap create failed.")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        gestureLogger.info("CGEventTap gesture listener started.")
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
        }
    }

    // MARK: - MultitouchSupport (Hardware Trackpad Driver Callback)

    private typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    private func startMultitouchSupport() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            gestureLogger.warning("MultitouchSupport.framework could not be opened.")
            return
        }

        typealias MTDeviceCreateDefaultFunc = @convention(c) () -> UnsafeMutableRawPointer?
        typealias MTRegisterCallbackFunc = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
        typealias MTDeviceStartFunc = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        typealias MTDeviceStopFunc = @convention(c) (UnsafeMutableRawPointer) -> Void

        guard let createSym = dlsym(handle, "MTDeviceCreateDefault"),
              let regSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let stopSym = dlsym(handle, "MTDeviceStop") else {
            gestureLogger.warning("Failed to resolve MultitouchSupport symbols.")
            return
        }

        let createDefault = unsafeBitCast(createSym, to: MTDeviceCreateDefaultFunc.self)
        let registerCallback = unsafeBitCast(regSym, to: MTRegisterCallbackFunc.self)
        let deviceStart = unsafeBitCast(startSym, to: MTDeviceStartFunc.self)
        self.mtStopFunc = unsafeBitCast(stopSym, to: MTDeviceStopFunc.self)

        guard let dev = createDefault() else {
            gestureLogger.warning("MTDeviceCreateDefault returned nil.")
            return
        }
        self.mtDevice = dev

        let cb: MTContactCallback = { dev, touchesPtr, count, timestamp, frame in
            guard let touchesPtr = touchesPtr, count >= 3 else {
                if count < 3 {
                    TrackpadGestureMonitor.shared.resetTouchState()
                }
                return 0
            }

            var activeCount = 0
            var sumX: Float = 0
            var sumY: Float = 0
            var points: [(Float, Float)] = []

            for i in 0..<Int(count) {
                let offset = i * 96
                let stateVal = touchesPtr.load(fromByteOffset: offset + 20, as: Int32.self)
                // Active touching states: began (1), moving (3), stationary (4)
                if stateVal == 1 || stateVal == 3 || stateVal == 4 {
                    let x = touchesPtr.load(fromByteOffset: offset + 32, as: Float.self)
                    let y = touchesPtr.load(fromByteOffset: offset + 36, as: Float.self)
                    sumX += x
                    sumY += y
                    points.append((x, y))
                    activeCount += 1
                }
            }

            if activeCount >= 3 {
                let cx = sumX / Float(activeCount)
                let cy = sumY / Float(activeCount)
                var sumDist: Float = 0
                for pt in points {
                    let dx = pt.0 - cx
                    let dy = pt.1 - cy
                    sumDist += sqrtf(dx * dx + dy * dy)
                }
                let avgDist = CGFloat(sumDist / Float(activeCount))
                TrackpadGestureMonitor.shared.processTouchFrame(
                    fingerCount: activeCount,
                    averageDistance: avgDist
                )
            } else {
                TrackpadGestureMonitor.shared.resetTouchState()
            }
            return 0
        }

        registerCallback(dev, cb)
        deviceStart(dev, 0)
        gestureLogger.info("MultitouchSupport hardware trackpad listener started.")
    }

    private func stopMultitouchSupport() {
        if let dev = mtDevice, let stop = mtStopFunc {
            stop(dev)
            self.mtDevice = nil
        }
    }

    // MARK: - Gesture Processing Engine

    private func processTouchFrame(fingerCount: Int, averageDistance: CGFloat) {
        let pref = AppState.shared.trackpadGesture
        let matches: Bool
        switch pref {
        case .off:
            matches = false
        case .three:
            matches = fingerCount == 3
        case .four:
            matches = fingerCount >= 4 // 4 or 5 fingers
        case .five:
            matches = fingerCount >= 5
        }

        guard matches else {
            resetTouchState()
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastTriggerTime) > cooldown else { return }

        if state == .idle {
            state = .began
            initialDistance = averageDistance
            lastDistance = averageDistance
            gestureLogger.info("[CustomGesture]: 手指数符合(\(fingerCount))，进入预备状态")
            return
        }

        state = .tracking
        let delta = averageDistance - initialDistance
        lastDistance = averageDistance

        let progress = min(1.0, max(0.0, abs(delta) / maxPinchDistance))
        gestureLogger.debug("[CustomGesture]: 进度 \(progress, format: .fixed(precision: 3))")

        // delta < 0 means fingers are closing together (pinch in)
        if delta < -pinchThreshold {
            if !LaunchpadWindowController.shared.isVisible {
                gestureLogger.info("[CustomGesture]: 完成 (四指捏合唤出)")
                lastTriggerTime = now
                state = .completed
                initialDistance = 0
                DispatchQueue.main.async {
                    TrackpadGestureMonitor.restoreDesktopIfNeeded()
                    LaunchpadWindowController.shared.show()
                }
            }
        } else if delta > pinchThreshold {
            // delta > 0 means fingers are spreading apart (pinch out)
            if LaunchpadWindowController.shared.isVisible {
                gestureLogger.info("[CustomGesture]: 完成 (张开收起)")
                lastTriggerTime = now
                state = .completed
                initialDistance = 0
                DispatchQueue.main.async {
                    LaunchpadWindowController.shared.hide()
                }
            }
        }
    }

    private func resetTouchState() {
        if state != .idle {
            state = .idle
            initialDistance = 0
            lastDistance = 0
        }
    }
}
