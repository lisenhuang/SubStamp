import SwiftUI

struct DevSettingsView: View {
    @ObservedObject private var devSettings = DevSettings.shared

    var body: some View {
        List {
            Section("Device Info") {
                LabeledContent("iOS Version") {
                    Text(UIDevice.current.systemVersion)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }

            Section {
                Toggle(isOn: $devSettings.forceLegacyMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulate iOS 18 (Legacy Mode)")
                            .foregroundStyle(AppColors.primaryText)
                        Text("Uses SFSpeechRecognizer and Translation Framework as on iOS 18, regardless of actual iOS version.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            } header: {
                Text("Feature Flags")
            } footer: {
                Text("Changes take effect on the next pipeline run.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}
