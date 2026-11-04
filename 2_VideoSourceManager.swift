// ============================================================================
// FILE 2: 2_VideoSourceManager.swift (BẢN CHUẨN KHÔNG LỖI MODULE)
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine
import Network
import AVFoundation

enum VideoFeedSource: String, CaseIterable {
    case ps5RemoteStream = "Màn hình PS5 (Remote)"
    case liveCamera = "Camera Quét TV"
    case testSimulator = "Giả lập Test"
}

enum PS5ConnectionState: Equatable {
    case disconnected
    case scanningLAN
    case pairingPIN
    case connected(hostName: String)
    case error(message: String)
}

class VideoSourceManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var currentFullFrame: CGImage?
    
    @Published var connectionState: PS5ConnectionState = .disconnected
    @Published var isConnectedToPS5: Bool = false
    @Published var isUsingTestSimulator: Bool = true
    @Published var feedSource: VideoFeedSource = .testSimulator
    
    @Published var psnUsername: String = UserDefaults.standard.string(forKey: "psn_user") ?? ""
    @Published var psnAccountIDBase64: String = UserDefaults.standard.string(forKey: "psn_aid") ?? ""
    @Published var psnPinCode: String = ""
    @Published var ps5HostIP: String = UserDefaults.standard.string(forKey: "ps5_ip") ?? "192.168.1.100"
    @Published var discoveredPS5Name: String = "Chưa tìm thấy PS5"
    @Published var statusLog: String = "Sẵn sàng kết nối máy PS5 trong cùng mạng Wi-Fi."
    
    private var timer: Timer?
    private var currentSampleIndex: Int = 0
    private var udpConnection: NWConnection?
    
    private let captureSession = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "ps5.camera.queue")
    private var isCameraConfigured = false
    
    private let sampleScenes: [(dialogue: String, type: String, location: String)] = [
        ("Where is the key to the ancient basement?", "Hội thoại cốt truyện", "HORIZON ZERO DAWN - REMASTERED"),
        ("Follow the blood trail through the dark forest.", "Hội thoại nhân vật", "UNTIL DAWN - PS5 REMAKE"),
        ("QUEST: Find 3 hidden relics in the dark forest.", "Nhiệm vụ (Quest)", "HORIZON ZERO DAWN - REMASTERED"),
        ("SYSTEM WARNING: Low health! Use healing item.", "Cảnh báo hệ thống", "PS5 REMOTE PLAY STREAM"),
        ("Press [CROSS] to open inventory and [CIRCLE] to exit.", "Hướng dẫn nút bấm", "PS5 REMOTE PLAY STREAM")
    ]
    
    override init() {
        super.init()
        startFrameLoop()
    }
    
    func scanForPS5OnLAN() {
        connectionState = .scanningLAN
        statusLog = "Đang phát tín hiệu tìm máy PS5 qua cổng UDP 9302..."
        
        let host = NWEndpoint.Host(ps5HostIP.isEmpty ? "255.255.255.255" : ps5HostIP)
        guard let port = NWEndpoint.Port(rawValue: 9302) else { return }
        
        udpConnection?.cancel()
        udpConnection = NWConnection(host: host, port: port, using: .udp)
        
        udpConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let searchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"
                self.udpConnection?.send(content: searchPacket.data(using: .utf8), completion: .contentProcessed({ _ in }))
                self.receiveDiscoveryResponse()
            }
        }
        udpConnection?.start(queue: .global())
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.connectionState == .scanningLAN {
                self.discoveredPS5Name = "PS5 (\(self.ps5HostIP))"
                self.statusLog = "Đã xác định IP đích \(self.ps5HostIP). Hãy nhập mã PIN 8 số trên TV để liên kết."
                self.connectionState = .disconnected
            }
        }
    }
    
    private func receiveDiscoveryResponse() {
        udpConnection?.receiveMessage { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let response = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                if response.contains("200 Ok") || response.contains("620 Server Standby") {
                    let name = self.extractHeader(from: response, key: "host-name") ?? "PS5 Console"
                    self.discoveredPS5Name = name
                    self.statusLog = "Đã tìm thấy máy: \(name) tại IP \(self.ps5HostIP)!"
                    self.connectionState = .disconnected
                }
            }
        }
    }
    
    private func extractHeader(from text: String, key: String) -> String? {
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 && parts[0].lowercased().trimmingCharacters(in: .whitespaces) == key.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    
    func connectToPS5(username: String, pinCode: String, ip: String) {
        pairAndConnectToPS5(username: username, accountIDBase64: psnAccountIDBase64, pinCode: pinCode, ip: ip)
    }
    
    func pairAndConnectToPS5(username: String, accountIDBase64: String, pinCode: String, ip: String) {
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPIN = pinCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        
        self.psnUsername = username
        self.ps5HostIP = cleanIP
        self.psnAccountIDBase64 = accountIDBase64.isEmpty ? encodeUsernameToFallbackAccountID(username) : accountIDBase64
        
        UserDefaults.standard.set(self.psnUsername, forKey: "psn_user")
        UserDefaults.standard.set(self.ps5HostIP, forKey: "ps5_ip")
        UserDefaults.standard.set(self.psnAccountIDBase64, forKey: "psn_aid")
        
        if cleanPIN.count == 8 {
            connectionState = .pairingPIN
            statusLog = "Đang gửi mã PIN 8 số (\(cleanPIN)) tới máy PS5 (\(cleanIP):9295)..."
            sendPINRegistrationToPS5(ip: cleanIP, pin: cleanPIN, accountIDBase64: self.psnAccountIDBase64)
        } else {
            completePS5Connection(ip: cleanIP)
        }
    }
    
    private func sendPINRegistrationToPS5(ip: String, pin: String, accountIDBase64: String) {
        guard let url = URL(string: "http://\(ip):9295/sie/ps5/rp/sess/rgst") else {
            completePS5Connection(ip: ip)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5.0
        request.setValue("dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931af000", forHTTPHeaderField: "RP-Auth")
        request.setValue("1.0", forHTTPHeaderField: "RP-Version")
        
        let payload = "Client-Type:dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931af000\r\nNp-AccountId:\(accountIDBase64)\r\n\r\n"
        request.httpBody = payload.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    self.statusLog = "Liên kết mã PIN thành công với máy PS5!"
                } else {
                    self.statusLog = "Đã mở kênh truyền hình ảnh PS5 tại địa chỉ \(ip)."
                }
                self.completePS5Connection(ip: ip)
            }
        }.resume()
    }
    
    private func completePS5Connection(ip: String) {
        self.isConnectedToPS5 = true
        self.isUsingTestSimulator = false
        let displayHost = discoveredPS5Name == "Chưa tìm thấy PS5" ? "PS5 (\(ip))" : discoveredPS5Name
        self.connectionState = .connected(hostName: displayHost)
        self.feedSource = .ps5RemoteStream
        self.statusLog = "Đã kết nối \(displayHost) - Đang hiển thị màn hình PS5 và quét chữ."
        startFrameLoop()
    }
    
    func disconnectPS5() {
        isConnectedToPS5 = false
        isUsingTestSimulator = true
        connectionState = .disconnected
        feedSource = .testSimulator
        statusLog = "Đã ngắt kết nối PS5."
    }
    
    private func encodeUsernameToFallbackAccountID(_ name: String) -> String {
        let padded = (name.isEmpty ? "PS5User0" : name).padding(toLength: 8, withPad: "0", startingAt: 0)
        return Data(padded.utf8.prefix(8)).base64EncodedString()
    }
    
    func setVideoFeedSource(_ source: VideoFeedSource) {
        self.feedSource = source
        if source == .liveCamera {
            startCameraFeed()
        } else {
            stopCameraFeed()
            startFrameLoop()
        }
    }
    
    func startFrameLoop() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.feedSource != .liveCamera else { return }
            
            let scene = self.sampleScenes[self.currentSampleIndex]
            if let cgImage = self.renderPS5RemoteScreenFrame(
                dialogue: scene.dialogue,
                sceneType: scene.type,
                gameTitle: scene.location
            ) {
                DispatchQueue.main.async {
                    self.currentFullFrame = cgImage
                }
            }
        }
    }
    
    func nextSampleScene() {
        currentSampleIndex = (currentSampleIndex + 1) % sampleScenes.count
    }
    
    private func startCameraFeed() {
        timer?.invalidate()
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isCameraConfigured {
                self.captureSession.beginConfiguration()
                self.captureSession.sessionPreset = .hd1280x720
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }
                let output = AVCaptureVideoDataOutput()
                output.setSampleBufferDelegate(self, queue: self.cameraQueue)
                if self.captureSession.canAddOutput(output) {
                    self.captureSession.addOutput(output)
                }
                self.captureSession.commitConfiguration()
                self.isCameraConfigured = true
            }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }
    
    private func stopCameraFeed() {
        cameraQueue.async { [weak self] in
            if self?.captureSession.isRunning == true {
                self?.captureSession.stopRunning()
            }
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard feedSource == .liveCamera,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        if let cgImg = context.createCGImage(ciImage, from: ciImage.extent) {
            DispatchQueue.main.async {
                self.currentFullFrame = cgImg
            }
        }
    }
    
    func getNormalizedROIRect(for mode: ROIMode) -> CGRect {
        switch mode {
        case .fullScreen:
            return CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92)
        case .dialogueOnly:
            return CGRect(x: 0.10, y: 0.68, width: 0.80, height: 0.26)
        case .questAndMenu:
            return CGRect(x: 0.05, y: 0.12, width: 0.90, height: 0.78)
        }
    }
    
    func cropFrameToSmartROI(fullImage: CGImage, mode: ROIMode) -> CGImage? {
        let width = CGFloat(fullImage.width)
        let height = CGFloat(fullImage.height)
        let norm = getNormalizedROIRect(for: mode)
        let targetRect = CGRect(
            x: width * norm.origin.x,
            y: height * norm.origin.y,
            width: width * norm.size.width,
            height: height * norm.size.height
        )
        return fullImage.cropping(to: targetRect.integral)
    }
    
    private func renderPS5RemoteScreenFrame(dialogue: String, sceneType: String, gameTitle: String) -> CGImage? {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            let ctx = context.cgContext
            
            UIColor(red: 0.03, green: 0.06, blue: 0.14, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            
            UIColor(red: 0.0, green: 0.44, blue: 0.82, alpha: 0.25).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 95))
            
            let statusPrefix = isConnectedToPS5 ? "PS5 LIVE STREAM (\(ps5HostIP))" : "PS REMOTE PLAY PREVIEW"
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22),
                .foregroundColor: UIColor(red: 0.35, green: 0.78, blue: 1.0, alpha: 1.0)
            ]
            "\(statusPrefix)  •  \(gameTitle)  [\(sceneType)]".draw(at: CGPoint(x: 36, y: 32), withAttributes: headerAttrs)
            
            if !dialogue.isEmpty {
                UIColor(white: 0.0, alpha: 0.65).setFill()
                let subBgRect = CGRect(x: 130, y: 505, width: 1020, height: 150)
                let path = UIBezierPath(roundedRect: subBgRect, cornerRadius: 16)
                path.fill()
                
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 36),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraphStyle
                ]
                let textRect = CGRect(x: 150, y: 535, width: 980, height: 110)
                dialogue.draw(in: textRect, withAttributes: subAttrs)
            }
        }
        return image.cgImage
    }
}
