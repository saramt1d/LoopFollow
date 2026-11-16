// LoopFollow
// AIInsightsView.swift

import SwiftUI

/// Sends a summary of the period shown on the Statistics screen to Claude and
/// renders the streamed answer.
struct AIInsightsView: View {
    let statsViewModel: AggregatedStatsViewModel

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var consent = Storage.shared.aiInsightsConsent
    @ObservedObject private var modelSetting = Storage.shared.aiInsightsModel
    @ObservedObject private var focusSetting = Storage.shared.aiInsightsFocus

    @State private var output = ""
    @State private var errorText: String?
    @State private var isRunning = false
    @State private var task: Task<Void, Never>?
    @State private var showDataPreview = false
    @State private var showSettings = false
    @State private var hasKey = ClaudeAPIKeyStore.hasKey

    private var focus: Set<ClaudeInsightsService.Focus> {
        Set(focusSetting.value.compactMap(ClaudeInsightsService.Focus.init(rawValue:)))
    }

    private var model: ClaudeInsightsService.Model {
        ClaudeInsightsService.Model(rawValue: modelSetting.value) ?? .opus
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    periodHeader
                    focusPicker
                    actionButtons

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }

                    if !output.isEmpty {
                        InsightsMarkdownView(text: output)
                            .textSelection(.enabled)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Text("AI-generated insights can be wrong and are not medical advice. Review any therapy changes with your diabetes care team.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("AI Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Preview data sent", systemImage: "doc.text.magnifyingglass") { showDataPreview = true }
                        Button("AI Insights settings", systemImage: "gearshape") { showSettings = true }
                        if !output.isEmpty {
                            ShareLink(item: output) { Label("Share insights", systemImage: "square.and.arrow.up") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showDataPreview) {
                NavigationStack {
                    ScrollView {
                        Text(buildSummary())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                    .navigationTitle("Data sent to Claude")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { showDataPreview = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { hasKey = ClaudeAPIKeyStore.hasKey }) {
                NavigationStack {
                    AIInsightsSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
            .onDisappear { task?.cancel() }
        }
        .preferredColorScheme(Storage.shared.appearanceMode.value.colorScheme)
    }

    // MARK: - Subviews

    private var periodHeader: some View {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = dateTimeUtils.displayTimeZone()
        let service = statsViewModel.dataService
        return VStack(alignment: .leading, spacing: 4) {
            Text("Analyzing \(formatter.string(from: service.startDate)) – \(formatter.string(from: service.endDate))")
                .font(.headline)
            Text("\(service.getBGData().count) CGM readings · \(model.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Change the dates on the Statistics screen to analyze a different period.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var focusPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ClaudeInsightsService.Focus.allCases) { item in
                Toggle(item.title, isOn: Binding(
                    get: { focus.contains(item) },
                    set: { on in
                        var current = focus
                        if on { current.insert(item) } else { current.remove(item) }
                        focusSetting.value = ClaudeInsightsService.Focus.allCases.filter { current.contains($0) }.map(\.rawValue)
                    }
                ))
            }
        }
        .disabled(isRunning)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !hasKey || !consent.value {
            VStack(alignment: .leading, spacing: 8) {
                Text(!hasKey
                    ? "Add your Anthropic API key to get started."
                    : "Allow LoopFollow to send a data summary to Claude to continue.")
                    .font(.callout)
                Button("Open AI Insights settings") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if isRunning {
            HStack {
                ProgressView()
                Text(output.isEmpty ? "Claude is analyzing your data…" : "Writing…")
                Spacer()
                Button("Stop", role: .cancel) {
                    task?.cancel()
                    isRunning = false
                }
            }
        } else {
            Button {
                generate()
            } label: {
                Label(output.isEmpty ? "Generate Insights" : "Regenerate", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(focus.isEmpty || statsViewModel.dataService.getBGData().count < 12)
        }
    }

    // MARK: - Actions

    private func buildSummary() -> String {
        let service = statsViewModel.dataService
        let stats = statsViewModel.simpleStats
        let input = InsightsDataSummaryBuilder.Input(
            bg: service.getBGData(),
            boluses: service.getBolusData(),
            smbs: service.getSMBData(),
            carbs: service.getCarbData(),
            start: service.startDate,
            end: service.endDate,
            averageDailyDose: stats.totalDailyDose,
            averageDailyBolus: stats.avgBolus,
            averageDailyCarbs: stats.avgCarbs,
            averageProgrammedBasal: stats.programmedBasal,
            averageActualBasal: stats.actualBasal
        )
        return InsightsDataSummaryBuilder(input: input).build()
    }

    private func generate() {
        errorText = nil
        output = ""
        isRunning = true
        let summary = buildSummary()
        let unit = UnitSettingsStore.shared.glucoseUnit.rawValue
        let focus = focus
        let model = model

        task = Task { @MainActor in
            do {
                for try await text in ClaudeInsightsService.streamInsights(dataSummary: summary, focus: focus, unit: unit, model: model) {
                    output = text
                }
            } catch is CancellationError {
                // Stopped by the user.
            } catch let error as URLError where error.code == .cancelled {
                // Stopped by the user.
            } catch {
                errorText = error.localizedDescription
                LogManager.shared.log(category: .general, message: "AI Insights failed: \(error.localizedDescription)")
            }
            isRunning = false
        }
    }
}

/// Minimal renderer for the Markdown subset the prompt asks for:
/// "### " headings, "- " bullets and inline emphasis.
struct InsightsMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, rawLine in
                line(rawLine.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    @ViewBuilder
    private func line(_ line: String) -> some View {
        if line.isEmpty {
            Spacer().frame(height: 2)
        } else if line.hasPrefix("#") {
            Text(inline(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                .font(.headline)
                .padding(.top, 6)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(line.dropFirst(2))))
            }
        } else {
            Text(inline(line))
        }
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }
}
