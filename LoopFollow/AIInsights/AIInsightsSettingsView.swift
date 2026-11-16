// LoopFollow
// AIInsightsSettingsView.swift

import SwiftUI

struct AIInsightsSettingsView: View {
    @ObservedObject private var model = Storage.shared.aiInsightsModel
    @ObservedObject private var consent = Storage.shared.aiInsightsConsent

    @State private var apiKeyInput = ""
    @State private var hasKey = ClaudeAPIKeyStore.hasKey
    @State private var saveMessage: String?

    var body: some View {
        Form {
            Section {
                if hasKey {
                    HStack {
                        Label("API key saved", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            ClaudeAPIKeyStore.delete()
                            hasKey = false
                            saveMessage = nil
                        }
                    }
                }
                SecureField(hasKey ? "Replace API key" : "sk-ant-…", text: $apiKeyInput)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Button("Save API Key") {
                    let ok = ClaudeAPIKeyStore.save(apiKeyInput)
                    hasKey = ClaudeAPIKeyStore.hasKey
                    apiKeyInput = ""
                    saveMessage = ok ? "Saved to the Keychain." : "Could not save the key."
                }
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if let saveMessage {
                    Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Anthropic API Key")
            } footer: {
                Text("Create a key at console.anthropic.com → API Keys. Usage is billed to your Anthropic account. The key is stored only in this device's Keychain and is not included in settings exports.")
            }

            Section {
                Picker("Model", selection: $model.value) {
                    ForEach(ClaudeInsightsService.Model.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
            } header: {
                Text("Model")
            }

            Section {
                Toggle("Allow sending data to Claude", isOn: $consent.value)
            } header: {
                Text("Privacy")
            } footer: {
                Text("""
                When you tap Generate, LoopFollow sends a summary of the selected period to Anthropic's API: \
                glucose statistics, hourly and daily summaries, low/high episodes, carb and bolus entries, \
                and your Nightscout profile settings. Your Nightscout URL, token and name are not sent. \
                Insights are informational only and are not medical advice — discuss any changes with your care team.
                """)
            }
        }
        .navigationTitle("AI Insights")
        .navigationBarTitleDisplayMode(.inline)
    }
}
