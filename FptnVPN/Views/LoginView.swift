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
                Color(Color.appBackground)
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: 32) {
                    Spacer()

                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 150, height: 150)
                        .foregroundColor(.white)

                    HStack(spacing: 0) {
                        Text("Use the Telegram-bot ")
                            .foregroundColor(.white)
                        Link("@fptn_bot", destination: URL(string: AppLinks.telegramBot)!)
                            .foregroundColor(Color.cian)
                            .underline()
                        Text(" to get a token")
                            .foregroundColor(.white)
                    }

                    TextField("Paste your token here...", text: $viewModel.token)
                        .padding()
                        .background(Color.white)
                        .cornerRadius(24)
                        .padding(.horizontal, 15)
                        .foregroundColor(.black)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button {
                        Task {
                            await viewModel.login()
                            if viewModel.errorMessage != nil {
                                showingAlert = true
                            }
                        }
                    } label: {
                        Text("Login")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(viewModel.isLoginButtonEnabled ? Color.cian : Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(24)
                            .padding(.horizontal, 15)
                    }
                    .disabled(!viewModel.isLoginButtonEnabled)
                    .alert("Error", isPresented: $showingAlert) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text(viewModel.errorMessage ?? "Unknown error")
                    }

                    Spacer()
                }
            }
            .navigationDestination(isPresented: $viewModel.isLoggedIn) {
                HomeView(viewModel: HomeViewModel(vpnService: VPNService()))
            }
        }
    }
}

#Preview {
    LoginView()
}
