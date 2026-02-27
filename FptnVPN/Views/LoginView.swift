/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel = LoginViewModel()
    @State private var showingAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Gradient background
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(Color.appBackground),
                        Color(Color.appBackground).opacity(0.8)
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
                                        colors: [.white, Color.cian.opacity(0.9)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        
                        Text("FPTN VPN")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("Secure your connection")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.bottom, 60)
                    
                    // Login form
                    VStack(spacing: 24) {
                        // Instructions card
                        VStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(Color.cian)
                                    .font(.system(size: 14))
                                
                                Text("Get your free token from")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.9))
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
                                .background(Color.cian.opacity(0.15))
                                .cornerRadius(20)
                            }
                        }
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        
                        // Token input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Token")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.leading, 4)
                            
                            HStack(spacing: 12) {
                                Image(systemName: "key.fill")
                                    .foregroundColor(Color.cian.opacity(0.7))
                                    .frame(width: 20)
                                
                                TextField("", text: $viewModel.token, prompt: Text("Paste your token here").foregroundColor(.white.opacity(0.4)))
                                    .foregroundColor(.white)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                    .textFieldStyle(.plain)
                                
                                if !viewModel.token.isEmpty {
                                    Button {
                                        viewModel.token = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.cian.opacity(viewModel.token.isEmpty ? 0 : 0.5), lineWidth: 1)
                            )
                        }
                        
                        // Login button
                        Button {
                            Task {
                                await viewModel.login()
                                if viewModel.errorMessage != nil {
                                    showingAlert = true
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text("Login")
                                    .fontWeight(.semibold)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                Group {
                                    if viewModel.isLoginButtonEnabled {
                                        LinearGradient(
                                            colors: [Color.cian, Color.cian.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    } else {
                                        Color.gray.opacity(0.3)
                                    }
                                }
                            )
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .shadow(color: viewModel.isLoginButtonEnabled ? Color.cian.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
                        }
                        .disabled(!viewModel.isLoginButtonEnabled)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.isLoginButtonEnabled)
                    }
                    .padding(.horizontal, 32)
                    
                    Spacer()
                    Spacer()
                }
            }
            .alert("Error", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
            .navigationDestination(isPresented: $viewModel.isLoggedIn) {
                HomeView(
                    viewModel: HomeViewModel(vpnService: VPNService()),
                    onLogout: { viewModel.isLoggedIn = false }
                )
            }
        }
    }
}

#Preview {
    LoginView()
}
