import UIKit
import Network
import WiFiAware
import DeviceDiscoveryUI

/// Puts up the system's Wi-Fi Aware pairing sheet on demand.
///
/// Pairing is the one step Wi-Fi Aware can't do by itself: a person has to confirm it on both
/// phones, through Apple's own sheet, and the only way to show that sheet without a button of ours
/// is to present its view controller. So this is the one place the app touches UIKit directly.
/// `GameViewModel` decides *when* (see `considerWiFiAwarePairing`); this shows the sheet for the
/// role asked for and reports whether a pairing came of it.
@available(iOS 26, *)
@MainActor
enum WiFiAwarePairingSheet {

    /// Presents the sheet for `role` over whatever is on screen and waits for it to be done.
    /// Returns true if a device was paired.
    static func present(_ role: WiFiAwarePairingRole) async -> Bool {
        guard let presenter = topViewController(),
              let publishable = WAPublishableService.pairForTwo,
              let subscribable = WASubscribableService.pairForTwo else { return false }
        switch role {
        case .pick:
            // The guest picks the host's phone from the devices offering to pair. The picker
            // resolves `endpoint` on a choice and throws on a cancel.
            let provider: WASubscriberBrowser = .wifiAware(.connecting(to: .userSpecifiedDevices, from: subscribable))
            guard let picker = DDDevicePickerViewController(browseDescriptor: provider.makeDescriptor(),
                                                            parameters: provider.configureParameters(nil))
            else { return false }
            picker.modalPresentationStyle = .fullScreen   // as the picker's documentation asks
            presenter.present(picker, animated: true)
            let paired: Bool
            do {
                _ = try await picker.endpoint
                paired = true
            } catch {
                paired = false
            }
            if picker.presentingViewController != nil { picker.dismiss(animated: true) }
            return paired

        case .advertise:
            // The host makes itself discoverable until the guest has paired with it, or the sheet
            // is dismissed. The sheet reports nothing itself, so watch the paired-device list.
            let pairing = DDDevicePairingViewController(
                listenerProvider: .wifiAware(.connecting(to: publishable, from: .userSpecifiedDevices)),
                access: .default)
            presenter.present(pairing, animated: true)
            return await waitForPairing(while: pairing)
        }
    }

    /// Resolves true once the paired-device list grows, false once the sheet has gone away.
    private static func waitForPairing(while sheet: UIViewController) async -> Bool {
        let before = (try? await WAPairedDevice.allDevices.current())?.count ?? 0
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            if let now = (try? await WAPairedDevice.allDevices.current())?.count, now > before {
                if sheet.presentingViewController != nil { sheet.dismiss(animated: true) }
                return true
            }
            if sheet.presentingViewController == nil, !sheet.isBeingPresented { return false }
        }
    }

    /// Whatever is frontmost: the key window's root, or the sheet it is presenting.
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
