//
//  ContentView.swift
//  HandsFreeOffice
//
//  Created by Praniil Nagaraj on 9/20/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject var streamer = MotionSpeechStreamer()

    var body: some View {
        VStack(spacing: 16) {
            Text("Hands-Free Office").font(.title2).bold()
            Text(streamer.connectionStatus).font(.footnote)

            Button(streamer.isListening ? "Stop listening" : "Start listening") {
                streamer.isListening ? streamer.stopListening() : streamer.startListening()
            }.buttonStyle(.borderedProminent)

            Button(streamer.isMotionActive ? "Stop motion" : "Start motion") {
                streamer.isMotionActive ? streamer.stopMotion() : streamer.startMotion()
            }.buttonStyle(.bordered)

            VStack(alignment: .leading) {
                Text("Say:")
                Text("• open gmail")
                Text("• type hello team meeting at 3 pm")
                Text("• send email")
                Text("• open presentation")
                Text("• next slide / previous slide")
            }.font(.callout).padding(.top, 8)

            Spacer()
        }
        .padding()
        .onAppear { streamer.connect() }
        .onDisappear { streamer.disconnect() }
    }
}
