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
        request.timeoutInterval =
