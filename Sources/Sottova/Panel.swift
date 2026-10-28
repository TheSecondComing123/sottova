import SwiftUI
import SottovaCore

struct Panel: View {
    let controller: Controller
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("sottova").font(.headline)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Play", action: play)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func play() {
        guard let path = ProcessInfo.processInfo.environment["SOTTOVA_TEST_FILE"] else {
            error = "no test file. set SOTTOVA_TEST_FILE and rerun"
            return
        }
        Task {
            do {
                try await controller.play(URL(filePath: path))
                error = nil
            } catch {
                self.error = "couldn't play that file: \(error.localizedDescription)"
            }
        }
    }
}
