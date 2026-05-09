import AppKit

// Private CoreGraphics ("SkyLight") spaces API. NSWindow.level alone is
// capped by the macOS menu bar compositor — even .screenSaver and
// CGShieldingWindowLevel get composited beneath it. The only sanctioned
// path that doesn't auto-hide the menu bar is to create a custom CGS
// "space" at maximum absolute level and put our window into it.
//
// Apps like boring.notch and several other notch utilities use this exact
// pattern. It's a private API, so don't ship to the Mac App Store with
// it — fine for self-distribution / personal tooling.
//
// Source pattern: https://github.com/avaidyam/Parrot, adapted by
// boring.notch (MPL-2.0). Re-typed here for RefVault.

public final class CGSSpace {
    private let identifier: CGSSpaceID

    public var windows: Set<NSWindow> = [] {
        didSet {
            let remove = oldValue.subtracting(windows)
            let add = windows.subtracting(oldValue)

            CGSRemoveWindowsFromSpaces(
                _CGSDefaultConnection(),
                remove.map { $0.windowNumber } as NSArray,
                [identifier]
            )
            CGSAddWindowsToSpaces(
                _CGSDefaultConnection(),
                add.map { $0.windowNumber } as NSArray,
                [identifier]
            )
        }
    }

    public init(level: Int = 0) {
        // Flag MUST be 1 — otherwise Finder draws desktop icons inside our
        // custom space.
        let flag = 0x1
        identifier = CGSSpaceCreate(_CGSDefaultConnection(), flag, nil)
        CGSSpaceSetAbsoluteLevel(_CGSDefaultConnection(), identifier, level)
        CGSShowSpaces(_CGSDefaultConnection(), [identifier])
    }

    deinit {
        CGSHideSpaces(_CGSDefaultConnection(), [identifier])
        CGSSpaceDestroy(_CGSDefaultConnection(), identifier)
    }
}

fileprivate typealias CGSConnectionID = UInt
fileprivate typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
fileprivate func _CGSDefaultConnection() -> CGSConnectionID

@_silgen_name("CGSSpaceCreate")
fileprivate func CGSSpaceCreate(
    _ cid: CGSConnectionID, _ unknown: Int, _ options: NSDictionary?
) -> CGSSpaceID

@_silgen_name("CGSSpaceDestroy")
fileprivate func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)

@_silgen_name("CGSSpaceSetAbsoluteLevel")
fileprivate func CGSSpaceSetAbsoluteLevel(
    _ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int
)

@_silgen_name("CGSAddWindowsToSpaces")
fileprivate func CGSAddWindowsToSpaces(
    _ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray
)

@_silgen_name("CGSRemoveWindowsFromSpaces")
fileprivate func CGSRemoveWindowsFromSpaces(
    _ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray
)

@_silgen_name("CGSHideSpaces")
fileprivate func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

@_silgen_name("CGSShowSpaces")
fileprivate func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

/// Singleton notch space — initialized once for the lifetime of the app at
/// `Int32.max` so windows added to it draw above everything, including the
/// menu bar.
final class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    let notchSpace: CGSSpace

    private init() {
        // boring.notch / SkyLightWindow use Int32.max - 2, not Int32.max.
        // The exact reason isn't documented, but the offset has been the
        // tested-stable value across the lineage of notch utilities. Using
        // Int32.max itself can interact poorly with AppKit's window-level
        // arithmetic for nearby system windows.
        notchSpace = CGSSpace(level: Int(Int32.max) - 2)
    }
}
