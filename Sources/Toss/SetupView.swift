import SwiftUI

/// First-run login: API credentials, phone, code, and 2FA password.
struct SetupView: View {
    @ObservedObject var telegram: Telegram
    var preview: Telegram.Step?
    var onDone: () -> Void

    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var email = ""

    private var step: Telegram.Step { preview ?? telegram.step }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white, Color(nsColor: NSColor(hex: 0x2A9EF1)))
            Text(title)
                .font(.title2.weight(.semibold))
            content
                .frame(maxWidth: 300)
            if let error = telegram.errorMessage, preview == nil {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("setupError")
            }
        }
        .padding(32)
        .frame(width: 420)
        .frame(minHeight: 400)
        .disabled(telegram.busy)
    }

    private var title: LocalizedStringKey {
        switch step {
        case .credentials: "Connect Telegram"
        case .phone: "Your Phone Number"
        case .code: "Enter Code"
        case .password: "Two-Step Verification"
        case .email, .emailCode: "Email"
        case .ready: "All Set"
        case .starting, .loggingOut, .blocked: "Toss"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .credentials:
            VStack(spacing: 10) {
                Link("my.telegram.org", destination: URL(string: "https://my.telegram.org/apps")!)
                    .font(.callout)
                TextField("API ID", text: $apiID)
                    .accessibilityIdentifier("apiIDField")
                TextField("API Hash", text: $apiHash)
                    .accessibilityIdentifier("apiHashField")
                primaryButton("Continue", enabled: Int32(apiID.trimmingCharacters(in: .whitespaces)) != nil
                              && apiHash.trimmingCharacters(in: .whitespaces).count >= 16) {
                    telegram.saveCredentials(apiID: Int32(apiID.trimmingCharacters(in: .whitespaces)) ?? 0,
                                             apiHash: apiHash.trimmingCharacters(in: .whitespaces))
                }
            }
            .textFieldStyle(.roundedBorder)
        case .starting, .loggingOut:
            ProgressView().controlSize(.large).padding(.top, 20)
        case .phone:
            VStack(spacing: 10) {
                TextField("+1 555 010 0000", text: $phone)
                    .textContentType(.telephoneNumber)
                    .accessibilityIdentifier("phoneField")
                primaryButton("Continue", enabled: phone.filter(\.isNumber).count >= 7) {
                    telegram.submitPhone(phone)
                }
                connectionHint
                Button("Change API ID") { telegram.changeCredentials() }
                    .buttonStyle(.link)
                    .font(.footnote)
            }
            .textFieldStyle(.roundedBorder)
        case .code(let hint):
            VStack(spacing: 10) {
                if !hint.isEmpty { Text(hint).foregroundStyle(.secondary) }
                TextField("Code", text: $code)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("codeField")
                primaryButton("Continue", enabled: code.filter(\.isNumber).count >= 4) {
                    telegram.submitCode(code)
                }
                Button("Resend Code") { telegram.resendCode() }
                    .buttonStyle(.link)
                    .font(.footnote)
            }
            .textFieldStyle(.roundedBorder)
        case .password(let hint):
            VStack(spacing: 10) {
                SecureField(hint.isEmpty ? String(localized: "Password") : hint, text: $password)
                    .accessibilityIdentifier("passwordField")
                primaryButton("Continue", enabled: !password.isEmpty) {
                    telegram.submitPassword(password)
                }
            }
            .textFieldStyle(.roundedBorder)
        case .email:
            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                primaryButton("Continue", enabled: email.contains("@")) { telegram.submitEmail(email) }
            }
            .textFieldStyle(.roundedBorder)
        case .emailCode(let pattern):
            VStack(spacing: 10) {
                if !pattern.isEmpty { Text(pattern).foregroundStyle(.secondary) }
                TextField("Code", text: $code)
                primaryButton("Continue", enabled: !code.isEmpty) { telegram.submitEmailCode(code) }
            }
            .textFieldStyle(.roundedBorder)
        case .blocked(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center)
                Button("Start Over") { telegram.logOut() }
            }
        case .ready:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                primaryButton("Choose Chats", enabled: true, action: onDone)
            }
        }
    }

    @ViewBuilder
    private var connectionHint: some View {
        if preview == nil, !telegram.isConnected {
            Text("Connecting…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func primaryButton(_ title: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if telegram.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!enabled)
        .accessibilityIdentifier("continueButton")
    }
}
