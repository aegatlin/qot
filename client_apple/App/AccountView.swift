import AuthenticationServices
import CryptoKit
import QotKit
import SwiftUI

/// The session: sign in (the device sign-in, like `qot login`), or see the
/// account, sync, export, sign out and delete the account.
struct AccountView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let session = model.session {
                    SignedInView(model: model, session: session)
                } else {
                    SignInView(model: model)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SignedInView: View {
    let model: AppModel
    let session: Credentials
    @State private var confirmingDelete = false
    @State private var confirmation = ""
    @State private var deleteError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Email", value: session.email)
                LabeledContent("Server", value: serverText)
                LabeledContent("Notes not synced", value: "\(model.unsynced)")
                if let problem = model.syncProblem {
                    Text(problem).foregroundStyle(.secondary)
                }
                Button(model.syncing ? "Syncing…" : "Sync now") {
                    Task { await model.sync() }
                }
                .disabled(model.syncing)
            }
            Section {
                if let data = model.export() {
                    ShareLink(
                        item: ExportFile(data: data),
                        preview: SharePreview("qot notes.json")
                    ) {
                        Label("Export notes", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("Your notes as JSON, the same as `qot export`.")
            }
            Section {
                Button("Sign out") { Task { await model.signOut() } }
            } footer: {
                Text("Your notes stay on this device.")
            }
            Section {
                Button("Delete account", role: .destructive) {
                    confirmation = ""
                    confirmingDelete = true
                }
            } footer: {
                Text("Deletes your account and its notes on the server. Notes on this device stay.")
            }
        }
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            TextField(session.email, text: $confirmation)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await model.deleteAccount(confirm: confirmation)
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type \(session.email) to confirm.")
        }
        .alert(
            "Couldn't delete the account",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var serverText: String {
        switch ServerLabel.of(session.server) {
        case .production: "production"
        case let label: "\(label.rawValue) (\(session.server.absoluteString))"
        }
    }
}

/// The export as a shareable `.json` file.
private struct ExportFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("qot notes.json")
    }
}

/// Sign in with Apple, or the email device sign-in (email, then the code to
/// type on the emailed page; waits for approval).
private struct SignInView: View {
    let model: AppModel
    @State private var email = ""
    @State private var server = ServerChoice.production
    @State private var customServer = "http://localhost:4000"
    @State private var started: DeviceStart?
    @State private var working = false
    @State private var problem: String?
    @State private var waiting: Task<Void, Never>?
    /// The raw nonce of the Apple request in flight; Apple gets its SHA-256.
    @State private var nonce = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            if let started {
                Section {
                    Text(started.userCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    HStack {
                        ProgressView()
                        Text("Waiting for you to type the code…").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Your code")
                } footer: {
                    Text(
                        "We emailed a sign-in link to \(email). Open it and type this code there. The code is never in the email."
                    )
                }
                Section {
                    Button("Start over", role: .cancel) { reset() }
                }
            } else {
                Section {
                    SignInWithAppleButton(.signIn, onRequest: appleRequest, onCompletion: appleDone)
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                        .listRowInsets(EdgeInsets())
                        .disabled(working)
                } footer: {
                    Text(
                        "To use qot on your other devices, share your email with qot rather than hiding it: the app on the web and the command line sign in with that email."
                    )
                }
                Section {
                    TextField("you@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(start)
                    Button(working ? "Sending…" : "Email me a sign-in link", action: start)
                        .disabled(working || !email.contains("@"))
                } header: {
                    Text("Or use your email")
                } footer: {
                    Text("We email you a link to approve this iPhone, as `qot login` does.")
                }
                Section("Server") {
                    Picker("Server", selection: $server) {
                        ForEach(ServerChoice.allCases) { Text($0.label).tag($0) }
                    }
                    if server == .custom {
                        TextField("http://localhost:4000", text: $customServer)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        .onDisappear { waiting?.cancel() }
    }

    private var serverURL: URL? {
        switch server {
        case .production: ServerLabel.productionURL
        case .staging: URL(string: "https://staging-api.quantumofthought.com")
        case .custom: URL(string: customServer)
        }
    }

    private func start() {
        guard let url = serverURL, email.contains("@") else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                let start = try await model.startSignIn(email: email, server: url)
                started = start
                waiting = Task {
                    do {
                        try await model.finishSignIn(start, server: url)
                    } catch is CancellationError {
                    } catch {
                        problem = error.localizedDescription
                        started = nil
                    }
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func appleRequest(_ request: ASAuthorizationAppleIDRequest) {
        nonce = Self.randomNonce()
        request.requestedScopes = [.email]
        request.nonce = Self.sha256(nonce)
    }

    private func appleDone(_ result: Result<ASAuthorization, Error>) {
        problem = nil
        switch result {
        case .failure(let error as ASAuthorizationError) where error.code == .canceled:
            return
        case .failure(let error):
            problem = error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8),
                let url = serverURL
            else {
                problem = "Apple didn't return a sign-in token. Try again."
                return
            }
            // Lets the server revoke Sign in with Apple if the account is deleted.
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            working = true
            Task {
                defer { working = false }
                do {
                    try await model.signInWithApple(
                        identityToken: token, nonce: nonce, authorizationCode: code, server: url)
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func reset() {
        waiting?.cancel()
        started = nil
        problem = nil
    }
}

private enum ServerChoice: String, CaseIterable, Identifiable {
    case production, staging, custom
    var id: Self { self }
    var label: String {
        switch self {
        case .production: "Production"
        case .staging: "Staging"
        case .custom: "Other"
        }
    }
}
