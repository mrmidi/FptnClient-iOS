//
//  Fptn_macOSApp.swift
//  Fptn-macOS
//
//  Created by Aleksandr Shabelnikov on 02.03.2026.
//

import SwiftUI

@main
struct Fptn_macOSApp: App {
    init() {
        // Begin observing iCloud KVS for cross-device token sync.
        // The onChange callback is not needed here — ContentView polls on appear.
        CloudTokenSync.startObserving {}
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 860, height: 600)
    }
}
