/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct ToolsView: View {
    let initialConnectionMode: VPNConnection.ConnectionMode
    let vpnService: VPNService?
    @Environment(\.dismiss) private var dismiss

    init(initialConnectionMode: VPNConnection.ConnectionMode = .auto, vpnService: VPNService? = nil) {
        self.initialConnectionMode = initialConnectionMode
        self.vpnService = vpnService
    }

    var body: some View {
        NavigationStack {
            SNICheckerView(initialConnectionMode: initialConnectionMode, vpnService: vpnService)
                .navigationTitle("SNI Checker")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(Color.appAccent)
                    }
                }
        }
    }
}

#Preview {
    ToolsView()
}
