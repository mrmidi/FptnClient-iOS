import SwiftUI

/// Token gate. There is nothing meaningful to show before a token exists, and
/// nothing worth hiding after.
struct RootView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        Group {
            if model.hasToken {
                ConnectionView()
            } else {
                TokenView()
            }
        }
        .frame(minWidth: 420, minHeight: 460)
    }
}
