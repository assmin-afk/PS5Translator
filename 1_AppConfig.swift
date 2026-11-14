// ============================================================================
// FILE 1: 1_AppConfig.swift
// NHIỆM VỤ: Lưu trữ cấu hình toàn cục, cấu trúc Hồ sơ Game, cấu hình Liên kết PS5,
// phân loại vùng chữ (Thoại / Nhiệm vụ / Menu) và bộ lọc nút bấm / hiệu ứng.
// ============================================================================

import Foundation
import CoreGraphics
import SwiftUI

struct AppConfig {
    // 1. CẤU HÌNH QUÉT & CHỐNG NÓNG MÁY
    static let defaultScanFPS: Double = 5.0
    static let defaultPixelDiffThreshold: Double = 0.022
    
    // 2. CHẾ ĐỘ QUÉT MẶC ĐỊNH (true = Quét toàn màn hình, false = Quét theo khung ROI)
    static let defaultFullScreenScan: Bool = true
    static let defaultROIRect = CGRect(x: 0.08, y: 0.68, width: 0.84, height: 0.25)
    
    // 3. CẤU HÌNH ĐOÁN CÂU VIỆT HOÁ & DỊCH AI APPLE
    static let minimumMatchScore: Double = 0.45
    static let sequentialLookaheadWindow: Int = 15
    static let enableAppleAIFallback: Bool = true
    
    // 4. CỔNG WEBSOCKET KẾT NỐI TV SAMSUNG
    static let webSocketPort: UInt16 = 8080
    
    // 5. DANH SÁCH NÚT BẤM TAY CẦM PS5 CẦN BẢO VỆ (KHÔNG DỊCH & KHÔNG ĐÈ LÊN)
    static let controllerButtonTokens: Set<String> = [
        "x", "o", "□", "△", "l1", "r1", "l2", "r2", "l3", "r3",
        "[x]", "[o]", "[□]", "[△]", "(x)", "(o)", "(□)", "(△)",
        "<x>", "<o>", "options", "share", "touchpad", "d-pad"
    ]
    
    // 6. DANH SÁCH HIỆU ỨNG MÀN HÌNH / THÔNG SỐ HUD CẦN BỎ QUA
    static let ignoredScreenEffects: Set<String> = [
        "critical", "critical!", "miss", "dodge", "parry", "block",
        "slash", "slash!!", "boom", "bam", "combo", "hit", "hits",
        "fps", "hp", "mp", "sp", "exp", "xp", "lv", "lvl", "loading..."
    ]
}

// MARK: - Phân loại vùng chữ trên màn hình Game
enum TextRegionCategory: String, Codable, CaseIterable {
    case dialogue = "dialogue" // Thoại nhân vật (Cạnh dưới màn hình)
    case quest    = "quest"    // Thông tin nhiệm vụ (Góc trên trái/phải)
    case menu     = "menu"     // Menu game / Vật phẩm / Tương tác
    
    var displayName: String {
        switch self {
        case .dialogue: return "Thoại nhân vật"
        case .quest:    return "Nhiệm vụ (HUD)"
        case .menu:     return "Menu / Tương tác"
        }
    }
    
    var textColor: Color {
        switch self {
        case .dialogue: return Color(red: 1.0, green: 0.92, blue: 0.15) // Vàng phụ đề
        case .quest:    return Color(red: 0.35, green: 0.95, blue: 1.0) // Xanh ngọc nhiệm vụ
        case .menu:     return Color.white                              // Trắng sáng cho Menu
        }
    }
    
    var borderColor: Color {
        switch self {
        case .dialogue: return Color.yellow.opacity(0.6)
        case .quest:    return Color.cyan.opacity(0.7)
        case .menu:     return Color.white.opacity(0.45)
        }
    }
}

// MARK: - Cấu trúc Hồ sơ Game (Game Profile)
struct GameProfile: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var sqliteFileName: String
    var sentenceCount: Int
    var updatedAt: String
}

// MARK: - Cấu hình Liên kết Tài khoản PS5 Remote Play
struct PS5AccountConfig: Codable {
    var psnAccountName: String = ""
    var psnAccountIDBase64: String = ""
    var pairingPIN: String = ""
    var ps5LocalIP: String = "192.168.1.100"
    var useSecondaryAccountMode: Bool = true
    var isLinked: Bool = false
}

// ============================================================================
// CẤU TRÚC GÓI TIN CHUẨN BẮN SANG TV SAMSUNG (GIỮ NGUYÊN TƯƠNG THÍCH 100%)
// ============================================================================

struct TranslatedBox: Codable, Identifiable, Equatable {
    // 1.11: ID ổn định theo khung chữ đang theo dõi -> SwiftUI không vẽ lại / khung không nhảy
    var id: String { stableID.isEmpty ? "\(text)_\(x)_\(y)" : stableID }
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    var category: String = TextRegionCategory.dialogue.rawValue
    var isAITranslated: Bool = false
    // 1.11: kiểu chữ khớp chữ gốc
    var stableID: String = ""
    /// Cỡ chữ = tỉ lệ so với CHIỀU CAO khung hình (0 = tự tính như bản cũ)
    var fontSizeNorm: Double = 0
    var textColorHex: String = ""
    var backgroundColorHex: String = ""
    var isBold: Bool = true
    /// 1.13: lời thoại căn giữa như phụ đề game
    var textAlignCenter: Bool = false
}

struct TVTextItem: Codable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct TVPayload: Codable {
    let status: String
    let boxes: [TranslatedBox]
    var texts: [TVTextItem] = []
}

struct RawOCRResult {
    let cleanTextForTranslation: String
    let normalizedRect: CGRect
    let category: TextRegionCategory
    let hadLeadingButtonPrompt: Bool
}
