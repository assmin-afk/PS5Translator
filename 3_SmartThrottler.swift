// ============================================================================
// FILE 3: 3_SmartThrottler.swift
// NHIỆM VỤ: Bộ điều tiết chống nóng máy.
// 1. Khoá tốc độ quét theo thanh trượt FPS người dùng chọn (1 - 15 FPS).
// 2. Thu nhỏ vùng phụ đề về kích thước siêu nhỏ (32x8 pixel) để đo độ lệch điểm ảnh.
//    Nếu nhân vật chưa nói sang câu mới (ảnh đứng yên) -> Bỏ qua không gọi OCR.
// ============================================================================

import Foundation
import CoreGraphics
import Combine

class SmartThrottler: ObservableObject {
    // Tốc độ FPS quét tối đa (người dùng kéo thanh trượt trên màn hình để chỉnh)
    @Published var targetScanFPS: Double = AppConfig.defaultScanFPS
    
    // Ngưỡng nhạy phát hiện đổi câu thoại
    @Published var pixelDiffThreshold: Double = AppConfig.defaultPixelDiffThreshold
    
    // Thông số thống kê hiển thị lên màn hình để theo dõi độ mát của máy
    @Published var skippedStaticFramesCount: Int = 0
    @Published var actualOCRScansCount: Int = 0
    @Published var lastDiffValue: Double = 0.0
    
    private var lastScanTimestamp: TimeInterval = 0
    private var previousThumbnailPixels: [UInt8] = []
    
    // Kích thước ảnh thu nhỏ để so sánh siêu tốc (chỉ mất 0.1 mili-giây CPU)
    private let thumbWidth = 32
    private let thumbHeight = 8
    
    /// Hàm kiểm tra: Trả về true nếu CẦN chạy OCR, trả về false nếu NÊN NGHỈ để mát máy
    func shouldPerformOCR(on croppedROIImage: CGImage, forceScan: Bool = false) -> Bool {
        let now = Date().timeIntervalSince1970
        let minInterval = 1.0 / max(1.0, targetScanFPS)
        
        // Tầng 1: Kiểm tra giới hạn thời gian giữa 2 lần quét (FPS Limiter)
        if !forceScan && (now - lastScanTimestamp) < minInterval {
            return false
        }
        lastScanTimestamp = now
        
        // Tầng 2: Đo độ thay đổi điểm ảnh (Pixel Diff Gate)
        let currentPixels = extractGrayscaleThumbnail(from: croppedROIImage)
        
        if previousThumbnailPixels.count == currentPixels.count && !forceScan {
            var totalDiff: Int = 0
            for i in 0..<currentPixels.count {
                totalDiff += abs(Int(currentPixels[i]) - Int(previousThumbnailPixels[i]))
            }
            let maxPossibleDiff = Double(currentPixels.count * 255)
            let normalizedDiff = Double(totalDiff) / maxPossibleDiff
            
            DispatchQueue.main.async {
                self.lastDiffValue = normalizedDiff
            }
            
            // Nếu hình ảnh trong vùng phụ đề gần như đứng yên -> Nghỉ quét!
            if normalizedDiff < pixelDiffThreshold {
                DispatchQueue.main.async {
                    self.skippedStaticFramesCount += 1
                }
                return false
            }
        }
        
        // Cập nhật mẫu ảnh mới và cho phép chạy OCR
        previousThumbnailPixels = currentPixels
        DispatchQueue.main.async {
            self.actualOCRScansCount += 1
        }
        return true
    }
    
    /// Đặt lại bộ nhớ ảnh khi người dùng di chuyển khung ROI
    func resetDiffMemory() {
        previousThumbnailPixels.removeAll()
    }
    
    /// Thu nhỏ ảnh vùng ROI về 32x8 điểm ảnh đen trắng
    private func extractGrayscaleThumbnail(from image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: thumbWidth * thumbHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        if let context = CGContext(
            data: &pixels,
            width: thumbWidth,
            height: thumbHeight,
            bitsPerComponent: 8,
            bytesPerRow: thumbWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) {
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
        }
        return pixels
    }
}