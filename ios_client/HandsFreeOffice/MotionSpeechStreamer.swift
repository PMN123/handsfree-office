import Foundation
import SwiftUI
import Combine
import AVFAudio
import AVFoundation
import Speech
import CoreMotion

class MotionSpeechStreamer: NSObject, ObservableObject {
    @Published var connectionStatus: String = "disconnected"
    @Published var isListening: Bool = false
    @Published var isMotionActive: Bool = false

    private var webSocket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let motion = CMMotionManager()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?

    // Set this to your Mac's IP and port
    private let serverURL = URL(string: "ws://172.20.10.2:8765")!

    // Debounce and de-dup helpers
    private var partialDebounce: Timer?
    private var lastHeard: String = ""
    private var lastSent: String = ""
    private var lastSentAt: Date = .distantPast

    // MARK: - WebSocket

    func connect() {
        disconnect()
        print("WS connecting to:", serverURL.absoluteString)
        webSocket = session.webSocketTask(with: serverURL)
        webSocket?.resume()
        connectionStatus = "connecting"
        receiveLoop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.connectionStatus = "connected"
            print("WS connected (optimistic flag set)")
        }
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        connectionStatus = "disconnected"
    }

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self.connectionStatus = "error: \(error.localizedDescription)" }
            case .success:
                break // ignore acks
            }
            self.receiveLoop()
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let ws = webSocket else { return }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []) {
            ws.send(.data(data)) { err in
                if let err { print("ws send error:", err) }
            }
        }
    }

    // MARK: - Speech

    func startListening() {
        SFSpeechRecognizer.requestAuthorization { auth in
            guard auth == .authorized else { return }

            let askMic: (@escaping (Bool) -> Void) -> Void = { completion in
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { granted in completion(granted) }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in completion(granted) }
                }
            }

            askMic { granted in
                guard granted else { return }
                DispatchQueue.main.async { self.beginSpeech() }
            }
        }
    }

    private func beginSpeech() {
        isListening = true

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            self.request.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            guard error == nil else {
                print("speech error:", error!.localizedDescription)
                return
            }
            guard let result = result else { return }

            let heard = result.bestTranscription.formattedString.lowercased()
            self.lastHeard = heard
            print("heard:", heard, "final:", result.isFinal)
            DispatchQueue.main.async { self.connectionStatus = "heard: \(heard)" }

            if result.isFinal {
                self.processHeard(heard)
                self.restartRecognitionSoon()
                return
            }

            // Debounce partials: treat 700 ms pause as end of utterance
            self.partialDebounce?.invalidate()
            self.partialDebounce = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { _ in
                self.processHeard(self.lastHeard)
                self.restartRecognitionSoon()
            }
        }
    }

    private func restartRecognitionSoon() {
        stopListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.startListening() }
    }

    func stopListening() {
        isListening = false
        recognitionTask?.cancel()
        recognitionTask = nil
        request.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func processHeard(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Normalization and intent extraction
        var cmd = text
            .replacingOccurrences(of: "g mail", with: "gmail")
            .replacingOccurrences(of: "g-mail", with: "gmail")

        if cmd.contains("open gmail") || cmd.contains("open mail") || cmd.contains("open email") {
            cmd = "open gmail"
        } else if cmd.hasPrefix("type ") || cmd.contains(" type ") {
            if let r = cmd.range(of: "type ") { cmd = String(cmd[r.lowerBound...]) } // keep from "type ..."
        } else if cmd.contains("send email") || cmd == "send" || cmd.contains("send it") {
            cmd = "send email"
        } else if cmd.contains("open presentation") || cmd.contains("start presentation") {
            cmd = "open presentation"
        } else if cmd.contains("next slide") || cmd == "next" || cmd.contains("next") {
            cmd = "next slide"
        } else if cmd.contains("previous slide") || cmd.contains("prev") || cmd.contains("back") {
            cmd = "previous slide"
        } else if cmd.contains("scroll down") || cmd.contains("scroll") {
            cmd = "scroll down"
        } else if cmd.contains("scroll up") || cmd.contains("top") {
            cmd = "scroll up"
        } else {
            return
        }

        // De-dupe within 1 second
        if cmd == lastSent && Date().timeIntervalSince(lastSentAt) < 1.0 {
            return
        }
        lastSent = cmd
        lastSentAt = Date()

        print("sending command:", cmd)
        sendJSON(["type": "command", "text": cmd])
    }

    // MARK: - Motion

    func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        isMotionActive = true
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(to: .main) { dm, _ in
            guard let dm else { return }
            let roll = dm.attitude.roll
            if abs(roll) > 0.35 {
                self.sendJSON([
                    "type": "gesture",
                    "kind": "tilt",
                    "roll": roll,
                    "pitch": dm.attitude.pitch,
                    "yaw": dm.attitude.yaw
                ])
            }
        }
    }

    func stopMotion() {
        isMotionActive = false
        motion.stopDeviceMotionUpdates()
    }

    // MARK: - Debug helper

    func debugSend(_ text: String) {
        print("debugSend:", text)
        sendJSON(["type": "command", "text": text])
    }
}
