// ============================================================================
// FILE 1: 1_AppConfig.swift
// NHIỆM VỤ: Bảng điều khiển chứa toàn bộ thông số cài đặt mặc định và cấu trúc
// gói tin chuẩn giao tiếp giữa các file và gửi sang TV Samsung.
// ============================================================================

import Foundation
import CoreGraphics

struct AppConfig {
    // 1. CẤU HÌNH QUÉT & CHỐNG NÓNG MÁY (Có thể chỉnh trực tiếp tại đây)
    /// Tốc độ quét mặc định khi mới mở App (từ 1.0 đến 15.0 khung hình/giây)
    static let defaultScanFPS: Double = 5.0
    
    /// Ngưỡng thay đổi hình ảnh tối thiểu để kích hoạt OCR (0.025 = 2.5%)
    /// Nếu hình ảnh thay đổi ít hơn mức này -> Máy hiểu là câu thoại đang đứng yên -> Ngừng quét để mát máy.
    static let defaultPixelDiffThreshold: Double = 0.025
    
    // 2. CẤU HÌNH VÙNG QUÉT PHỤ ĐỀ MẶC ĐỊNH (ROI - Tính theo tỷ lệ 0.0 -> 1.0)
    /// Mặc định quét vùng phụ đề ở cạnh dưới màn hình (cách lề trái 10%, cách đỉnh 72%, rộng 80%, cao 20%)
    static let defaultROIRect = CGRect(x: 0.10, y: 0.72, width: 0.80, height: 0.20)
    
    // 3. CẤU HÌNH ĐOÁN CÂU VIỆT HOÁ (Predictive Matcher)
    /// Tỷ lệ khớp từ khoá tối thiểu (0.45 = chỉ cần OCR đọc đúng 45% từ khoá là đoán ra cả câu)
    static let minimumMatchScore: Double = 0.45
    
    /// Số lượng câu thoại kế tiếp được ưu tiên cộng điểm theo mạch cốt truyện
    static let sequentialLookaheadWindow: Int = 15
    
    // 4. CẤU HÌNH KẾT NỐI VỚI TV SAMSUNG
    /// Cổng WebSocket cố định để TV Samsung kết nối vào iPhone
    static let webSocketPort: UInt16 = 8080
}

// ============================================================================
// CẤU TRÚC GÓI TIN CHUẨN (TUYỆT ĐỐI KHÔNG ĐỔI TÊN BIẾN ĐỂ KHỚP VỚI TV SAMSUNG)
// ============================================================================

/// Một khung chữ đã dịch kèm toạ độ tỷ lệ phần trăm (0.0 -> 1.0) trên màn hình 16:9
struct TranslatedBox: Codable, Identifiable, Equatable {
    var id: String { "\(text)_\(x)_\(y)" }
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

/// Gói tin JSON tổng bắn từ iPhone sang TV Samsung qua cổng 8080
struct TVPayload: Codable {
    /// Nhận giá trị "show" (hiện chữ) hoặc "clear" (xoá chữ)
    let status: String
    let boxes: [TranslatedBox]
}

/// Kết quả thô do bộ OCR quét được trước khi đưa vào bộ đoán câu
struct RawOCRResult {
    let rawText: String
    let normalizedRect: CGRect // Toạ độ (x, y, w, h) tính từ góc trên bên trái toàn màn hình (0.0 -> 1.0)
}