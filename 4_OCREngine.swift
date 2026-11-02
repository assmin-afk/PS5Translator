// ============================================================================
// FILE 4: 4_OCREngine.swift
// NHIỆM VỤ: Sử dụng chip AI (Apple Vision) ở chế độ siêu tốc (.fast) để quét
// các từ khoá trên màn hình và tính toán lại toạ độ chuẩn (0.0 -> 1.0).
// ============================================================================

import Foundation
import Vision
import CoreGraphics

class OCREngine {
    private let ocrQueue = DispatchQueue(label: "com.ps5translator.ocrqueue", qos: .userInteractive)
    private var isBusy: Bool = false
    
    /// Quét ảnh vùng ROI và trả về danh sách các dòng chữ kèm toạ độ toàn màn hình
    func recognizeTextFast(
        in croppedROIImage: CGImage,
        roiRect: CGRect,
        completion: @escaping ([RawOCRResult]) -> Void
    ) {
        // Tránh dồn ứ hàng đợi nếu lần quét trước chưa xong
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
                
                var extractedResults: [RawOCRResult] = []
                
                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }
                    let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    
                    // Chuyển đổi hệ toạ độ của Apple Vision (gốc dưới-trái) sang hệ toạ độ màn hình TV/iPhone (gốc trên-trái)
                    let visionBox = observation.boundingBox
                    let roiLocalTopY = 1.0 - visionBox.origin.y - visionBox.size.height
                    
                    let fullScreenX = roiRect.origin.x + (visionBox.origin.x * roiRect.size.width)
                    let fullScreenY = roiRect.origin.y + (roiLocalTopY * roiRect.size.height)
                    let fullScreenW = visionBox.size.width * roiRect.size.width
                    let fullScreenH = visionBox.size.height * roiRect.size.height
                    
                    let normalizedRect = CGRect(
                        x: max(0.0, min(1.0, fullScreenX)),
                        y: max(0.0, min(1.0, fullScreenY)),
                        width: max(0.05, min(1.0, fullScreenW)),
                        height: max(0.04, min(1.0, fullScreenH))
                    )
                    
                    extractedResults.append(RawOCRResult(rawText: text, normalizedRect: normalizedRect))
                }
                
                completion(extractedResults)
            }
            
            // BẬT CHẾ ĐỘ SIÊU TỐC (.fast) ĐỂ MÁT MÁY VÌ ĐÃ CÓ BỘ ĐOÁN CÂU Ở FILE 5 HỖ TRỢ
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            
            let handler = VNImageRequestHandler(cgImage: croppedROIImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                self.isBusy = false
                completion([])
            }
        }
    }
}