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
                    Text("3. Go to Settings → General → Keyboard → Keyboards → Add New Keyboard → VoiceKing.")
                    Text("4. Enable Allow Full Access for VoiceKing.")
                    Text("5. In any text field, switch to VoiceKing, choose a mode, and tap the microphone.")
                }

                Section("Transcription modes") {
                    Text("Smart Cleanup (default): adds punctuation and paragraphs, removes filler and repetition, and fixes obvious wording problems without changing meaning or adding information.")
                    Text("Verbatim: returns the transcription with no second-pass rewriting.")
                }

                Section("Privacy & limitations") {
                    Text("VoiceKing closes the microphone about 10 seconds after its keyboard is dismissed or you switch to another keyboard.")
                    Text("If iOS suspends the service, tapping the keyboard microphone briefly opens VoiceKing, starts the service, returns to the previous input field, and begins recording automatically.")
                    Text("Smart Cleanup sends the raw transcription through a second ChatGPT/Codex text request. If that request is unavailable, VoiceKing safely returns the raw transcription instead.")
                    Text("The current ChatGPT/Codex transcription endpoint is undocumented and may change.")
                }

                if let error = model.lastError {
                    Section("Error") {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("VoiceKing")
        }
    }
}
