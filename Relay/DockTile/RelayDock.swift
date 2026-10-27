import AppKit

/// Loaded by the Dock (Info.plist NSDockTilePlugIn) so Relay's icon follows Light/Dark even while Relay is closed.
/// macOS 26's "Default" icon style always shows an app's light icon; this draws the dark one after sunset.
@objc(RelayDockPlugIn)
final class RelayDockPlugIn: NSObject, NSDockTilePlugIn {
    private var tile: NSDockTile?
    private var observer: NSObjectProtocol?

    func setDockTile(_ dockTile: NSDockTile?) {
        tile = dockTile
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        guard dockTile != nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        guard let tile else { return }
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let dark = (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String) == "Dark"
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: dark ? "AppIcon-Dark" : "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = view
        tile.display()
    }
}
