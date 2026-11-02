// ============================================================================
// FILE 2: 2_VideoSourceManager.swift
// NHIỆM VỤ: Nhận luồng hình ảnh từ PS5 (Chiaki) hoặc Bộ phát khung hình giả lập,
// sau đó cắt đúng vùng chọn (ROI) để đưa cho bộ chống nóng và OCR xử lý.
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine

class VideoSourceManager: ObservableObject {
    // Hình ảnh toàn màn hình 16:9 hiện tại để hiển thị lên màn hình iPhone
    @Published var currentFullFrame: CGImage?
    
    // Chế độ nguồn phát: true = Đang dùng bộ giả lập để test, false = Luồng Chiaki PS5
    @Published var isUsingTestSimulator: Bool = true
    
    // Callback bắn khung hình mới sang bộ chống nóng (File 3)
    var onNewROICroppedFrame: ((CGImage, CGRect) -> Void)?
    
    private var timer: Timer?
    private var currentSampleIndex: Int = 0
    
    // Danh sách các câu thoại tiếng Anh giả lập trên màn hình PS5 để bạn bấm nút Test ngay trên Xcode
    private let samplePS5Scenes: [String] = [
        "Where is the key to the ancient basement?",
        "Follow the blood trail through the dark forest.",
        "Wait! Someone is watching us from the shadows.",
        "Take this healing potion before the boss fight begins.",
        "" // Khung hình không có phụ đề (để test tính năng tự xoá chữ trên TV)
    ]
    
    init() {
        startTestStream()
    }
    
    // MARK: - 1. Bộ phát hình ảnh PS5 giả lập (Dùng để test khi chưa ghép Chiaki)
    func startTestStream() {
        timer?.invalidate()
        // Phát khung hình ở tốc độ 30 FPS giống hệt luồng Remote Play thật
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isUsingTestSimulator else { return }
            if let cgImage = self.generateSimulatedPS5Frame(dialogue: self.samplePS5Scenes[self.currentSampleIndex]) {
                DispatchQueue.main.async {
                    self.currentFullFrame = cgImage
                }
            }
        }
    }
    
    /// Chuyển sang câu thoại mẫu tiếp theo (Gắn với nút bấm "Đổi câu thoại mẫu" trên màn hình)
    func nextSampleDialogue() {
        currentSampleIndex = (currentSampleIndex + 1) % samplePS5Scenes.count
    }
    
    // MARK: - 2. Cổng nhận hình ảnh thật từ lõi Chiaki PS5 Remote Play (Dùng ở Chặng 4)
    /// Khi ghép thư viện Chiaki, chỉ cần gọi hàm này mỗi khi có CVPixelBuffer mới
    func receiveChiakiPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            DispatchQueue.main.async {
                self.currentFullFrame = cgImage
            }
        }
    }
    
    // MARK: - 3. Cắt vùng ảnh theo khung quét phụ đề (ROI Crop)
    /// Cắt chỉ lấy phần hộp thoại để giảm 70-80% tải cho chip AI của iPhone
    func cropFrameToROI(fullImage: CGImage, roiRect: CGRect) -> CGImage? {
        let width = CGFloat(fullImage.width)
        let height = CGFloat(fullImage.height)
        
        let cropZone = CGRect(
            x: roiRect.origin.x * width,
            y: roiRect.origin.y * height,
            width: roiRect.size.width * width,
            height: roiRect.size.height * height
        ).integral
        
        return fullImage.cropping(to: cropZone)
    }
    
    // MARK: - Hàm phụ trợ vẽ khung hình giả lập PS5 1280x720
    private func generateSimulatedPS5Frame(dialogue: String) -> CGImage? {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            let cgContext = context.cgContext
            
            // Vẽ nền cảnh game giả lập
            UIColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 1.0).setFill()
            cgContext.fill(CGRect(origin: .zero, size: size))
            
            // Vẽ chữ báo hiệu màn hình PS5 ở góc trên
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 28),
                .foregroundColor: UIColor.white.withAlphaComponent(0.35)
            ]
            let headerText = "PS5 REMOTE PLAY STREAM (1280x720)"
            headerText.draw(at: CGPoint(x: 40, y: 40), withAttributes: headerAttrs)
            
            // Vẽ phụ đề tiếng Anh gốc của game ở cạnh dưới màn hình (nếu có)
            if !dialogue.isEmpty {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 40),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraphStyle
                ]
                let subRect = CGRect(x: 160, y: 560, width: 960, height: 100)
                dialogue.draw(in: subRect, withAttributes: subAttrs)
            }
        }
        return image.cgImage
    }
}