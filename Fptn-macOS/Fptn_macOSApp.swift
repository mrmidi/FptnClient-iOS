//
//  Fptn_macOSApp.swift
//  Fptn-macOS
//
//  Created by Aleksandr Shabelnikov on 02.03.2026.
//

import SwiftUI

enum MacWindowID {
    static let main = "fptn.main"
}

@main
struct Fptn_macOSApp: App {

    // Owned here, not in a view: the Settings scene and the menu bar item are
    // sibling Scenes and cannot reach into another scene's @State.
    @StateObject private var model = MacAppModel()
    @StateObject private var vpn = MacVPNService()
    @StateObject private var selection = MacServerSelectionService()

    var body: some Scene {
        // Window, not WindowGroup: WindowGroup is a multi-window scene, so the
        // menu bar item's openWindow(id:) spawned a fresh window on every
        // click instead of surfacing the existing one. Window is single
        // instance, so openWindow activates what is already there.
        Window("FPTN", id: MacWindowID.main) {
            RootView()
                .environmentObject(model)
                .environmentObject(vpn)
                .environmentObject(selection)
                .task {
                    // Observe iCloud KVS for a token added on another device.
                    CloudTokenSync.startObserving { [weak model] in
                        Task { @MainActor in model?.loadPersistedToken() }
                    }
                    model.loadPersistedToken()
                    vpn.syncWithSystem()
                }
        }
        .windowStyle(.titleBar)
        // contentMinSize, not contentSize: a wrapped error label must be able
        // to grow the window rather than clip inside it.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 420, height: 460)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            MacSettingsView()
                .environmentObject(model)
                .environmentObject(vpn)
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
                .environmentObject(vpn)
        } label: {
            Image(systemName: vpn.isConnected ? "lock.shield.fill" : "lock.shield")
        }
        .menuBarExtraStyle(.window)
    }
}
