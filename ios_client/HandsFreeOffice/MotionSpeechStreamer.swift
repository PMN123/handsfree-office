import Foundation
import SwiftUI
import Combine
import AVFAudio
import AVFoundation
import Speech
import CoreMotion

class MotionSpeechStreamer: NSObject, ObservableObject {
    // MARK: - Published UI state
    @Published var connectionStatus: String = "disconnected"
    @Published var isListening: Bool = false
    @Published var isMotionActive: Bool = false

    // MARK: - Networking
    private var webSocket: URLSessionWebSocketTask?
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()
    // ⬇️ update this for your Mac
    private let serverURL = URL(string: "ws://172.20.10.2:8765")!

    private var pingTimer: Timer?
    private var reconnectBackoff: TimeInterval = 0.5
    private let maxBackoff: TimeInterval = 6.0

    // MARK: - Motion
    private let motion = CMMotionManager()

    // MARK: - Speech
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?

    // partial debounce + de-dupe
    private var partialDebounce: Timer?
    private var lastHeard: String = ""
    private var lastSent: String = ""
    private var lastSentAt: Date = .distantPast

    // Optional push-to-talk (hold to speak)
    private var pttEnabled = false

    // MARK: - Lifecycle helpers
    deinit {
        stopListening()
        stopMotion()
        disconnect()
    }

    // MARK: - WebSocket
    func connect() {
        disconnect()
        print("WS connecting to:", serverURL.absoluteString)
        let task = session.webSocketTask(with: serverURL)
        webSocket = task
        task.resume()
        connectionStatus = "connecting"
        startReceiveLoop()
        startPing()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // optimistic status; will be corrected on failure
            self.connectionStatus = "connected"
            self.reconnectBackoff = 0.5
            print("WS connected (optimistic)")
        }
    }

    func disconnect() {
        stopPing()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        connectionStatus = "disconnected"
    }

    private func startReceiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                print("WS receive error:", error.localizedDescription)
                DispatchQueue.main.async {
                    self.connectionStatus = "error: \(error.localizedDescription)"
                }
                self.scheduleReconnect()
            case .success:
                // ignore messages (server acks) in MVP
                break
            }
            // keep looping
            self.startReceiveLoop()
        }
    }

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            guard let self = self, let ws = self.webSocket else { return }
            ws.send(.string("ping")) { err in
                if let err { print("WS ping error:", err.localizedDescription) }
            }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func scheduleReconnect() {
        stopPing()
        webSocket = nil
        connectionStatus = "reconnecting in \(Int(reconnectBackoff*1000))ms"
        let delay = reconnectBackoff
        reconnectBackoff = min(maxBackoff, reconnectBackoff * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let ws = webSocket else { return }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []) {
            ws.send(.data(data)) { err in
                if let err { print("ws send error:", err.localizedDescription) }
            }
        }
    }

    // MARK: - Speech
    /// Toggle a “push-to-talk” style if you want to map to a button.
    func setPushToTalk(enabled: Bool) {
        pttEnabled = enabled
    }

    func startListening() {
        SFSpeechRecognizer.requestAuthorization { auth in
            guard auth == .authorized else {
                print("speech not authorized:", auth.rawValue)
                return
            }
            let askMic: (@escaping (Bool) -> Void) -> Void = { completion in
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { granted in completion(granted) }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in completion(granted) }
                }
            }
            askMic { granted in
                guard granted else {
                    print("mic permission denied")
                    return
                }
                DispatchQueue.main.async { self.beginSpeech() }
            }
        }
    }

    private func beginSpeech() {
        guard recognitionTask == nil else { return }
        isListening = true

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = !pttEnabled  // if push-to-talk, skip partial spam

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            self.request.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let error = error {
                print("speech error:", error.localizedDescription)
                return
            }
            guard let result = result else { return }

            let heard = result.bestTranscription.formattedString.lowercased()
            self.lastHeard = heard
            print("heard:", heard, "final:", result.isFinal)
            DispatchQueue.main.async { self.connectionStatus = "heard: \(heard)" }

            if self.pttEnabled {
                // in push-to-talk, only act on final
                if result.isFinal {
                    self.processHeard(heard)
                    self.restartRecognitionSoon()
                }
                return
            }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.beginSpeech() }
    }

    func stopListening() {
        isListening = false
        recognitionTask?.cancel()
        recognitionTask = nil
        request.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func processHeard(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // lightweight normalization
        var cmd = text
            .replacingOccurrences(of: "g mail", with: "gmail")
            .replacingOccurrences(of: "g-mail", with: "gmail")

        // intent mapping (client-side safety net; server does real routing)
        if cmd.contains("open gmail") || cmd.contains("open mail") || cmd.contains("open email") {
            cmd = "open gmail"
        } else if cmd.hasPrefix("type ") || cmd.contains(" type ") {
            if let r = cmd.range(of: "type ") { cmd = String(cmd[r.lowerBound...]) } // keep from "type ..."
        } else if cmd.contains("send email") || cmd == "send" || cmd.contains("send it") {
            cmd = "send email"
        } else if cmd.contains("open presentation") || cmd.contains("start presentation") || cmd.contains("begin slideshow") {
            cmd = "open presentation"
        } else if cmd.contains("next slide") || cmd == "next" || cmd.contains("go forward") {
            cmd = "next slide"
        } else if cmd.contains("previous slide") || cmd.contains("prev") || cmd.contains("go back slide") {
            cmd = "previous slide"
        } else if cmd.contains("scroll down") || cmd.contains("scroll") {
            cmd = "scroll down"
        } else if cmd.contains("scroll up") || cmd.contains("top") {
            cmd = "scroll up"
        } // else: let server try broader NLU via examples/TF-IDF

        // de-dupe within 1s
        if cmd == lastSent && Date().timeIntervalSince(lastSentAt) < 1.0 { return }
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

    // MARK: - Debug helpers
    func debugSend(_ text: String) {
        print("debugSend:", text)
        sendJSON(["type": "command", "text": text])
    }

    func reconnectNow() {
        scheduleManualReconnect()
    }

    private func scheduleManualReconnect() {
        disconnect()
        reconnectBackoff = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.connect()
        }
    }
}
