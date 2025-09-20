import Foundation
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
    private let speechRecognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?

    // Replace with your Mac IP
    private let serverURL = URL(string: "ws://192.168.1.23:8765")!

    func connect() {
        disconnect()
        webSocket = session.webSocketTask(with: serverURL)
        webSocket?.resume()
        connectionStatus = "connecting"

        receiveLoop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.connectionStatus = "connected"
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
                // ignore server acks
                break
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

    // MARK: Speech

    func startListening() {
        SFSpeechRecognizer.requestAuthorization { auth in
            guard auth == .authorized else { return }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                guard granted else { return }

                DispatchQueue.main.async {
                    self.beginSpeech()
                }
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
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.request.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            guard error == nil else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                // Simple trigger on final result
                if result.isFinal {
                    self.handleRecognizedCommand(text: text)
                }
            }
        }
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

    private func handleRecognizedCommand(text: String) {
        // Minimal postprocessing
        var command = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize common variants
        if command.hasPrefix("type") == false, command.hasPrefix("write ") {
            command = command.replacingOccurrences(of: "write ", with: "type ")
        }

        // Send to server
        let payload: [String: Any] = ["type": "command", "text": command]
        sendJSON(payload)
    }

    // MARK: Motion

    func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        isMotionActive = true
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(to: .main) { dm, _ in
            guard let dm else { return }
            // Use roll for left/right tilts
            let roll = dm.attitude.roll // radians
            // Only send when outside deadzone to keep traffic light
            if abs(roll) > 0.35 {
                let payload: [String: Any] = [
                    "type": "gesture",
                    "kind": "tilt",
                    "roll": roll,
                    "pitch": dm.attitude.pitch,
                    "yaw": dm.attitude.yaw
                ]
                self.sendJSON(payload)
            }
        }
    }

    func stopMotion() {
        isMotionActive = false
        motion.stopDeviceMotionUpdates()
    }
}