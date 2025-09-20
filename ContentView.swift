import SwiftUI

struct ContentView: View {
    @StateObject var streamer = MotionSpeechStreamer()

    var body: some View {
        VStack(spacing: 16) {
            Text("Hands-Free Office")
                .font(.title2)
                .bold()

            Text(streamer.connectionStatus)
                .font(.footnote)

            Button(streamer.isListening ? "Stop listening" : "Start listening") {
                if streamer.isListening {
                    streamer.stopListening()
                } else {
                    streamer.startListening()
                }
            }
            .buttonStyle(.borderedProminent)

            Button(streamer.isMotionActive ? "Stop motion" : "Start motion") {
                if streamer.isMotionActive {
                    streamer.stopMotion()
                } else {
                    streamer.startMotion()
                }
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 8) {
                Text("Say examples:")
                Text("• open gmail")
                Text("• type hello team meeting at 3 pm")
                Text("• send email")
                Text("• open presentation")
                Text("• next slide / previous slide")
            }
            .font(.callout)
            .padding(.top, 8)

            Spacer()
        }
        .padding()
        .onAppear {
            streamer.connect()
        }
        .onDisappear {
            streamer.disconnect()
        }
    }
}