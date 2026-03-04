//
//  Fptn_tvOSApp.swift
//  Fptn-tvOS
//
//  Created by Aleksandr Shabelnikov on 04.03.2026.
//

import SwiftUI

@main
struct Fptn_tvOSApp: App {
    init() {
        // Begin observing iCloud KVS for cross-device token sync.
        TvCloudTokenSync.startObserving {
            // ContentView will reload from cloud on notification.
            NotificationCenter.default.post(name: .tvCloudTokenDidChange, object: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

extension Notification.Name {
    static let tvCloudTokenDidChange = Notification.Name("tvCloudTokenDidChange")
}
