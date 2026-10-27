import SwiftUI

/// First run: pair with Relay on the Mac by scanning its code with the Camera, or look around with sample cards.
struct PairView: View {
    let link: MacLink
    @State private var manual = false
    @State private var code = ""

    var body: some View {
        ZStack {
            Wallpaper()
            VStack(spacing: 22) {
                Spacer()
                Image("relay-mark").resizable().scaledToFit().frame(width: 92, height: 92)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                VStack(spacing: 10) {
                    Text("Relay on your iPhone").font(.system(size: 30, weight: .bold))
                    Text("Your cards keep running on your Mac. From here you can follow them, answer them, and start new ones.")
                        .font(.body).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "On your Mac, open Relay and choose Relay › Pair iPhone…")
                    step(2, "Open the Camera here and point it at the code.")
                    step(3, "Tap the Relay link that appears. You're paired.")
                }
                .padding(18)
                .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                Spacer()
                Button("Try it with sample cards") { link.startDemo() }
                    .buttonStyle(.glass).controlSize(.large)
                Button("Paste a pairing link") { manual = true }
                    .font(.footnote).foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
        .alert("Paste the pairing link", isPresented: $manual) {
            TextField("relay://pair?…", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Pair") { if let url = URL(string: code.trimmingCharacters(in: .whitespacesAndNewlines)) { _ = link.pair(with: url) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The link is under the code in Relay › Pair iPhone… on the Mac.")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.subheadline.weight(.bold)).frame(width: 24, height: 24)
                .background(.white.opacity(0.2), in: .circle)
            Text(text).font(.subheadline)
        }
    }
}
