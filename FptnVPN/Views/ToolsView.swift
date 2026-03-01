/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct ToolsView: View {
    let initialConnectionMode: VPNConnection.ConnectionMode
    @Environment(\.dismiss) private var dismiss

    init(initialConnectionMode: VPNConnection.ConnectionMode = .auto) {
        self.initialConnectionMode = initialConnectionMode
    }

    var body: some View {
        NavigationStack {
            SNICheckerView(initialConnectionMode: initialConnectionMode)
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
