import SwiftUI

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText: String = ""
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logText.isEmpty ? "No logs yet." : logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(AppColors.background)
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = logText
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(logText.isEmpty)
                }
            }
            .onAppear {
                logText = AppLog.fullText
            }
        }
    }
}
