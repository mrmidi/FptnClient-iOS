/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel = LoginViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                // Gradient background
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.appBackground,
                        Color.appBackground.opacity(0.8)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .edgesIgnoringSafeArea(.all)

                VStack(spacing: 0) {
                    Spacer()
                    
                    // Logo section
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.cian.opacity(0.2))
                                .frame(width: 140, height: 140)
                            
                            Image(systemName: "lock.shield.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 70, height: 70)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color.appPrimaryText, Color.appAccent.opacity(0.9)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        
                        Text("FPTN VPN")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.appPrimaryText)
                        
                        Text("Secure your connection")
                            .font(.subheadline)
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    .padding(.bottom, 60)
                    
                    // Login form
                    VStack(spacing: 24) {
                        // Instructions card
                        VStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color.appAccent)
                                    .font(.system(size: 14))
                                
                                Text("Get your free token from")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.appPrimaryText)
                            }
                            
                            Link(destination: URL(string: AppLinks.telegramBot)!) {
                                HStack(spacing: 6) {
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 12))
                                    Text("@fptn_bot")
                                        .fontWeight(.semibold)
                                    Image(systemName: "arrow.up.forward")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(Color.cian)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.appAccent.opacity(0.16))
                                .cornerRadius(20)
                            }
                        }
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .background(Color.appSurface)
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.appSeparator.opacity(0.45), lineWidth: 1)
                        )
                        
                        // Paste-only entry. A token is hundreds of base64
                        // characters — nobody types one — so there is no text
                        // field here and the keyboard never appears.
                        Button {
                            Task { await viewModel.pasteToken() }
                        } label: {
                            HStack(spacing: 10) {
                                if viewModel.isPasting {
                                    ProgressView()
                                        .tint(Color.black.opacity(0.85))
                                } else {
                                    Image(systemName: "doc.on.clipboard.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                Text("Paste Token")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(
                                    colors: [Color.appAccent, Color.appAccent.opacity(0.82)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundStyle(Color.black.opacity(0.85))
                            .cornerRadius(12)
                            .shadow(color: Color.appAccent.opacity(0.25), radius: 8, x: 0, y: 4)
                        }
                        .disabled(viewModel.isPasting)

                        // Inline, not an alert: the advice is about the thing
                        // they just tapped, and it should stay readable while
                        // they go back to Telegram to re-copy.
                        if let errorMessage = viewModel.errorMessage {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.appWarning)
                                Text(errorMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.appPrimaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.appSurface)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.appWarning.opacity(0.45), lineWidth: 1)
                            )
                            .transition(.opacity)
                        }

                    }
                    .padding(.horizontal, 32)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
                    
                    Spacer()
                    Spacer()
                }
            }
            .navigationDestination(isPresented: $viewModel.isLoggedIn) {
                HomeView(
                    viewModel: HomeViewModel(vpnService: VPNService()),
                    isCloudSynced: viewModel.isCloudSynced,
                    onLogout: {
                        viewModel.isCloudSynced = false
                        viewModel.isLoggedIn = false
                    }
                )
            }
        }
    }
}

#Preview {
    LoginView()
}
