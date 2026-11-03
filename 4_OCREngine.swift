// ============================================================================
// FILE 4: 4_OCREngine.swift
// NHIỆM VỤ:
// 1. Quét OCR toàn màn hình hoặc khung ROI bằng Apple Vision (.fast).
// 2. LỌC BỎ hiệu ứng màn hình (Số sát thương 9999, +EXP, 60 FPS, CRITICAL, SLASH...).
// 3. BẢO VỆ NÚT BẤM TAY CẦM ([X], (O), L1, R1, △, □): Không dịch nút bấm và tự động
//    dịch chuyển toạ độ hộp chữ sang phải để KHÔNG ĐÈ LÊN biểu tượng nút bấm.
// 4. Tự động phân loại vùng chữ: Thoại nhân vật / Nhiệm vụ / Menu game.
// ============================================================================

import Foundation
import Vision
import CoreGraphics

class OCREngine {
    private let ocrQueue = DispatchQueue(label: "com.ps5translator.ocrqueue", qos: .userInteractive)
    private var isBusy: Bool = false
    
    // Cho phép người dùng bật/tắt từng loại chữ muốn dịch trên màn hình
    var enableDialogueTranslation: Bool = true
    var enableQuestTranslation: Bool = true
    var enableMenuTranslation: Bool = true
    
    func recognizeAndClassifyText(
        in image: CGImage,
        effectiveROIRect: CGRect,
        completion: @escaping ([RawOCRResult]) -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        
        ocrQueue.async { [weak self] in
            guard let self = self else { return }
            
            let request = VNRecognizeTextRequest { request, error in
                defer { self.isBusy = false }
                
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    completion([])
                    return
                }
                
                var validResults: [RawOCRResult] = []
                
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let rawLine = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Bước 1: Kiểm tra và bỏ qua nếu là hiệu ứng màn hình, sát thương nhảy số hoặc nút bấm đứng một mình
                    if self.isScreenEffectOrNoise(rawLine) {
                        continue
                    }
                    
                    // Bước 2: Tách nút bấm tay cầm ở đầu câu (Ví dụ: "[X] Examine altar" -> giữ lại "Examine altar")
                    let (cleanedText, hadButtonPrefix) = self.stripControllerButtonPrompts(from: rawLine)
                    if cleanedText.count < 2 || self.isScreenEffectOrNoise(cleanedText) {
                        continue
                    }
                    
                    // Bước 3: Tính toạ độ chuẩn (0.0 -> 1.0) trên màn hình 16:9
                    let visionBox = obs.boundingBox
                    let localTopY = 1.0 - visionBox.origin.y - visionBox.size.height
                    
                    var fullX = effectiveROIRect.origin.x + (visionBox.origin.x * effectiveROIRect.size.width)
                    let fullY = effectiveROIRect.origin.y + (localTopY * effectiveROIRect.size.height)
                    var fullW = visionBox.size.width * effectiveROIRect.size.width
                    let fullH = visionBox.size.height * effectiveROIRect.size.height
                    
                    // NẾU ĐẦU CÂU CÓ NÚT BẤM ([X], (O), L1...): Dịch lùi hộp chữ sang phải 4.5% để KHÔNG ĐÈ LÊN NÚT BẤM
                    if hadButtonPrefix {
                        let buttonIconSafeOffset: CGFloat = 0.045
                        fullX = min(0.92, fullX + buttonIconSafeOffset)
                        fullW = max(0.06, fullW - buttonIconSafeOffset)
                    }
                    
                    let rect = CGRect(
                        x: max(0.0, min(0.95, fullX)),
                        y: max(0.0, min(0.95, fullY)),
                        width: max(0.06, min(0.96, fullW)),
                        height: max(0.038, min(0.30, fullH))
                    )
                    
                    // Bước 4: Phân loại ngữ cảnh dựa vào vị trí trên màn hình
                    let category = self.classifyRegion(rect: rect)
                    if !self.isCategoryEnabled(category) {
                        continue
                    }
                    
                    validResults.append(
                        RawOCRResult(
                            cleanTextForTranslation: cleanedText,
                            normalizedRect: rect,
                            category: category,
                            hadLeadingButtonPrompt: hadButtonPrefix
                        )
                    )
                }
                
                completion(validResults)
            }
            
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                self.isBusy = false
                completion([])
            }
        }
    }
    
    // MARK: - 1. Bộ lọc chống dịch hiệu ứng màn hình, số sát thương, FPS, thanh máu
    private func isScreenEffectOrNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 1 { return true }
        
        let lower = trimmed.lowercased()
        if AppConfig.controllerButtonTokens.contains(lower) { return true }
        if AppConfig.ignoredScreenEffects.contains(lower) { return true }
        
        // Bỏ qua chuỗi chỉ toàn số, dấu cộng/trừ/phần trăm (sát thương nhảy số: +450, 9999, 100%)
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.count < 2 { return true }
        
        // Bỏ qua thông số FPS, LV, EXP hoặc sát thương kèm chữ CRITICAL / SLASH
        let words = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if words.allSatisfy({ AppConfig.ignoredScreenEffects.contains($0) || AppConfig.controllerButtonTokens.contains($0) || Int($0.filter { $0.isNumber }) != nil }) {
            return true
        }
        
        return false
    }
    
    // MARK: - 2. Tách ký hiệu nút bấm tay cầm để không dịch và không che nút bấm
    private func stripControllerButtonPrompts(from text: String) -> (String, Bool) {
        var tokens = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return (text, false) }
        
        var hadLeadingButton = false
        
        // Kiểm tra từ đầu tiên xem có phải là nút bấm ([X], (O), L1, R1, △, □...) không
        if let first = tokens.first?.lowercased(),
           AppConfig.controllerButtonTokens.contains(first) {
            tokens.removeFirst()
            hadLeadingButton = true
        }
        
        // Loại bỏ các nút bấm đứng xen kẽ
        tokens.removeAll { AppConfig.controllerButtonTokens.contains($0.lowercased()) }
        
        return (tokens.joined(separator: " "), hadLeadingButton)
    }
    
    // MARK: - 3. Phân biệt Thoại nhân vật, Thông tin nhiệm vụ và Menu game
    private func classifyRegion(rect: CGRect) -> TextRegionCategory {
        let centerY = rect.midY
        let centerX = rect.midX
        
        // Vùng cạnh dưới màn hình (y >= 0.65) và nằm gần giữa -> Thoại nhân vật (Subtitle)
        if centerY >= 0.65 && centerX >= 0.20 && centerX <= 0.80 {
            return .dialogue
        }
        
        // Vùng nửa trên màn hình ở góc trái hoặc góc phải -> Thông tin nhiệm vụ (Quest HUD)
        if centerY <= 0.42 && (centerX <= 0.40 || centerX >= 0.55) {
            return .quest
        }
        
        // Các vị trí còn lại -> Menu game / Hộp tương tác vật phẩm
        return .menu
    }
    
    private func isCategoryEnabled(_ category: TextRegionCategory) -> Bool {
        switch category {
        case .dialogue: return enableDialogueTranslation
        case .quest:    return enableQuestTranslation
        case .menu:     return enableMenuTranslation
        }
    }
}
