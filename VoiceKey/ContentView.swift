import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("ChatGPT") {
                    HStack {
                        Text("Account")
                        Spacer()
                        Text(model.signedIn ? (model.accountEmail ?? "Signed in") : "Not signed in")
                            .foregroundStyle(.secondary)
                    }

                    if model.signedIn {
                        Button("Sign Out", role: .destructive) {
                            model.signOut()
                        }
                    } else {
                        Button("Sign in with ChatGPT") {
                            Task { await model.signIn() }
                        }
                    }
                }

                Section("Keyboard Service") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(model.serviceReady ? "Ready" : "Stopped")
                            .foregroundStyle(model.serviceReady ? Color.green : Color.secondary)
                    }

                    Text(model.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if model.serviceReady {
                        Button("Stop Keyboard Service", role: .destructive) {
                            model.stopService()
                        }
                    } else {
                        Button("Start Keyboard Service") {
                            Task { await model.startService() }
                        }
                        .disabled(!model.signedIn)
                    }
                }

                Section("Setup") {
                    Text("1. Sign in with ChatGPT.")
                    Text("2. Start Keyboard Service once after installing or restarting the phone.")
                    Text("3. Go to Settings → General → Keyboard → Keyboards → Add New Keyboard → VoiceKey.")
                    Text("4. Enable Allow Full Access for VoiceKey.")
                    Text("5. In any text field, switch to VoiceKey with the globe key and tap the microphone.")
                }

                Section("Privacy & limitations") {
                    Text("VoiceKey automatically activates the microphone when its keyboard appears.")
                    Text("VoiceKey closes the microphone 10 seconds after its keyboard is dismissed or you switch to another keyboard, then keeps a silent background audio session so it can reactivate automatically next time.")
                    Text("The silent background session may use a small amount of battery and may appear as audio activity in iOS.")
                    Text("The current ChatGPT/Codex transcription endpoint is undocumented and may change.")
                }

                if let error = model.lastError {
                    Section("Error") {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("VoiceKey")
        }
    }
}
