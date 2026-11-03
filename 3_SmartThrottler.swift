// ============================================================================
// FILE 3: 3_SmartThrottler.swift
// NHIỆM VỤ: Bộ điều tiết chống nóng máy thế hệ 2.
// Khi quét TOÀN MÀN HÌNH, cảnh nền game (nhân vật chạy, lá bay) thay đổi liên tục.
// Thuật toán này chỉ lọc lấy các điểm ảnh có độ tương phản cao (vùng chữ sáng)
// trên lưới 48x27 để so sánh, giúp máy vẫn tự nghỉ khi chữ trên màn hình đứng yên!
// ============================================================================

import Foundation
import CoreGraphics
import Combine

class SmartThrottler: ObservableObject {
    @Published var targetScanFPS: Double = AppConfig.defaultScanFPS
    @Published var pixelDiffThreshold: Double = AppConfig.defaultPixelDiffThreshold
    
    @Published var skippedStaticFramesCount: Int = 0
    @Published var actualOCRScansCount: Int = 0
    @Published var lastDiffValue: Double = 0.0
    
    private var lastScanTimestamp: TimeInterval = 0
    private var previousHighContrastMask: [UInt8] = []
    
    private let gridWidth = 48
    private let gridHeight = 27
    
    func shouldPerformOCR(on image: CGImage, forceScan: Bool = false) -> Bool {
        let now = Date().timeIntervalSince1970
        let minInterval = 1.0 / max(1.0, targetScanFPS)
        
        if !forceScan && (now - lastScanTimestamp) < minInterval {
            return false
        }
        lastScanTimestamp = now
        
        let currentMask = extractBrightTextMask(from: image)
        
        if previousHighContrastMask.count == currentMask.count && !forceScan {
            var diffPixels = 0
            for i in 0..<currentMask.count {
                if abs(Int(currentMask[i]) - Int(previousHighContrastMask[i])) > 35 {
                    diffPixels += 1
                }
            }
            let normalizedDiff = Double(diffPixels) / Double(currentMask.count)
            
            DispatchQueue.main.async {
                self.lastDiffValue = normalizedDiff
            }
            
            if normalizedDiff < pixelDiffThreshold {
                DispatchQueue.main.async {
                    self.skippedStaticFramesCount += 1
                }
                return false
            }
        }
        
        previousHighContrastMask = currentMask
        DispatchQueue.main.async {
            self.actualOCRScansCount += 1
        }
        return true
    }
    
    func resetDiffMemory() {
        previousHighContrastMask.removeAll()
    }
    
    /// Chỉ giữ lại các điểm ảnh sáng (nơi thường chứa chữ phụ đề, nhiệm vụ, menu)
    private func extractBrightTextMask(from image: CGImage) -> [UInt8] {
        var rawPixels = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        if let context = CGContext(
            data: &rawPixels,
            width: gridWidth,
            height: gridHeight,
            bitsPerComponent: 8,
            bytesPerRow: gridWidth,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) {
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight))
        }
        
        // Lọc bỏ cảnh nền tối, chỉ giữ lại các điểm sáng của chữ (> 165)
        return rawPixels.map { $0 > 165 ? $0 : 0 }
    }
}
