// ============================================================================
// FILE 2: 2_VideoSourceManager.swift
// NHIỆM VỤ:
// 1. Quản lý Liên kết Tài khoản PS5 (PSN ID, Mã PIN 8 số, IP PS5, Wake-up/Connect).
// 2. Nhận hình ảnh từ PS5 hoặc Bộ giả lập đa vùng (có đủ Thoại, Nhiệm vụ, Menu
//    kèm nút bấm [X] và Hiệu ứng sát thương 9999 để kiểm tra bộ lọc).
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine

enum PS5ConnectionState: String {
    case disconnected = "Chưa kết nối PS5 (Đang chạy Giả lập)"
    case searching    = "Đang tìm máy PS5 trong mạng LAN..."
    case pairing      = "Đang xác thực mã PIN Remote Play..."
    case streaming    = "Đã kết nối PS5 Remote Play (Trực tiếp)"
}

class VideoSourceManager: ObservableObject {
    @Published var currentFullFrame: CGImage?
    @Published var connectionState: PS5ConnectionState = .disconnected
    @Published var accountConfig: PS5AccountConfig = PS5AccountConfig()
    @Published var isUsingTestSimulator: Bool = true
    
    private var timer: Timer?
    private var currentSceneIndex: Int = 0
    private let accountStorageKey = "ps5_saved_account_config_v2"
    
    // Kịch bản giả lập màn hình PS5 thực tế gồm đủ 4 thành phần:
    // (1) Nhiệm vụ góc trên, (2) Menu có nút bấm [X], (3) Hiệu ứng sát thương (để lọc bỏ), (4) Thoại nhân vật
    struct SimulatedPS5Scene {
        let questText: String
        let menuPromptText: String
        let screenEffectText: String
        let dialogueText: String
    }
    
    private let sampleScenes: [SimulatedPS5Scene] = [
        SimulatedPS5Scene(
            questText: "Find the ancient key in the dark forest",
            menuPromptText: "[X] Examine the mysterious altar",
            screenEffectText: "9999 CRITICAL!",
            dialogueText: "Where is the key to the ancient basement?"
        ),
        SimulatedPS5Scene(
            questText: "Defeat the Shadow Guardian",
            menuPromptText: "(O) Open Inventory",
            screenEffectText: "SLASH!! +450 EXP",
            dialogueText: "Follow the blood trail through the dark forest."
        ),
        SimulatedPS5Scene(
            questText: "Escape from the collapsing temple",
            menuPromptText: "L1 Guard   R1 Heavy Attack",
            screenEffectText: "60 FPS   LV. 99",
            dialogueText: "The northern gate is sealed by ancient magic." // Câu chưa có trong DB mẫu -> Sẽ kích hoạt Dịch AI của Apple!
        ),
        SimulatedPS5Scene(
            questText: "",
            menuPromptText: "",
            screenEffectText: "",
            dialogueText: "" // Cảnh trống để test tự xoá chữ trên TV
        )
    ]
    
    init() {
        loadSavedAccountConfig()
        startTestStream()
    }
    
    // MARK: - 1. Quản lý Liên kết Tài khoản PS5 & Kết nối Remote Play
    func loadSavedAccountConfig() {
        if let data = UserDefaults.standard.data(forKey: accountStorageKey),
           let decoded = try? JSONDecoder().decode(PS5AccountConfig.self, from: data) {
            self.accountConfig = decoded
        }
    }
    
    func saveAndLinkPS5Account(name: String, psnID: String, pin: String, ip: String, secondaryMode: Bool) {
        accountConfig.psnAccountName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accountConfig.psnAccountIDBase64 = psnID.trimmingCharacters(in: .whitespacesAndNewlines)
        accountConfig.pairingPIN = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        accountConfig.ps5LocalIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        accountConfig.useSecondaryAccountMode = secondaryMode
        accountConfig.isLinked = !accountConfig.ps5LocalIP.isEmpty
        
        if let encoded = try? JSONEncoder().encode(accountConfig) {
            UserDefaults.standard.set(encoded, forKey: accountStorageKey)
        }
    }
    
    func connectToPS5RemotePlay() {
        guard !accountConfig.ps5LocalIP.isEmpty else { return }
        connectionState = .searching
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.connectionState = .pairing
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.accountConfig.isLinked = true
                self.connectionState = .streaming
            }
        }
    }
    
    func disconnectPS5() {
        connectionState = .disconnected
        isUsingTestSimulator = true
    }
    
    // MARK: - 2. Cổng nhận luồng hình ảnh từ lõi Chiaki hoặc Giả lập
    func receiveChiakiPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            DispatchQueue.main.async {
                self.currentFullFrame = cgImage
            }
        }
    }
    
    func startTestStream() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isUsingTestSimulator else { return }
            let scene = self.sampleScenes[self.currentSceneIndex]
            if let cgImage = self.renderSimulatedPS5Frame(scene: scene) {
                DispatchQueue.main.async {
                    self.currentFullFrame = cgImage
                }
            }
        }
    }
    
    func nextSampleDialogue() {
        currentSceneIndex = (currentSceneIndex + 1) % sampleScenes.count
    }
    
    // MARK: - 3. Cắt vùng ảnh (Hỗ trợ cả Quét Toàn Màn Hình 100% và Khung ROI)
    func cropFrame(fullImage: CGImage, isFullScreen: Bool, roiRect: CGRect) -> (image: CGImage, effectiveRect: CGRect)? {
        let targetRect = isFullScreen ? CGRect(x: 0, y: 0, width: 1, height: 1) : roiRect
        if isFullScreen {
            return (fullImage, targetRect)
        }
        
        let width = CGFloat(fullImage.width)
        let height = CGFloat(fullImage.height)
        let cropZone = CGRect(
            x: targetRect.origin.x * width,
            y: targetRect.origin.y * height,
            width: targetRect.size.width * width,
            height: targetRect.size.height * height
        ).integral
        
        guard let cropped = fullImage.cropping(to: cropZone) else { return nil }
        return (cropped, targetRect)
    }
    
    // MARK: - Vẽ khung hình PS5 giả lập 1280x720 có đủ Thoại, Nhiệm vụ, Nút tay cầm, Hiệu ứng
    private func renderSimulatedPS5Frame(scene: SimulatedPS5Scene) -> CGImage? {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            let cg = context.cgContext
            
            // Nền cảnh game tối
            UIColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 1.0).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            
            // 1. Vẽ Thông tin nhiệm vụ (Góc trên bên phải)
            if !scene.questText.isEmpty {
                let questAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 28),
                    .foregroundColor: UIColor(red: 0.85, green: 0.95, blue: 1.0, alpha: 1.0)
                ]
                scene.questText.draw(in: CGRect(x: 720, y: 65, width: 520, height: 60), withAttributes: questAttrs)
            }
            
            // 2. Vẽ Hiệu ứng sát thương / Thông số HUD (Giữa màn hình bên trái - Cần bị lọc bỏ!)
            if !scene.screenEffectText.isEmpty {
                let sfxAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 34),
                    .foregroundColor: UIColor.orange
                ]
                scene.screenEffectText.draw(at: CGPoint(x: 90, y: 240), withAttributes: sfxAttrs)
            }
            
            // 3. Vẽ Menu tương tác kèm nút bấm tay cầm [X] hoặc (O) (Giữa màn hình)
            if !scene.menuPromptText.isEmpty {
                let menuAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 30),
                    .foregroundColor: UIColor.white
                ]
                scene.menuPromptText.draw(in: CGRect(x: 420, y: 390, width: 560, height: 55), withAttributes: menuAttrs)
            }
            
            // 4. Vẽ Thoại nhân vật (Cạnh dưới màn hình)
            if !scene.dialogueText.isEmpty {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 36),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: style
                ]
                scene.dialogueText.draw(in: CGRect(x: 160, y: 575, width: 960, height: 90), withAttributes: subAttrs)
            }
        }
        return image.cgImage
    }
}
