// ============================================================================
// FILE 13: 13_GameCovers.swift
// PHIÊN BẢN: PS5Translator 1.22
//
// ẢNH BÌA GAME (AVATAR) + DANH SÁCH GAME CÓ SẴN
// - Mỗi game có mã trang PlayStation Store (concept). App tự tải ảnh bìa vuông
//   (giống ảnh trên màn hình PS5) từ trang đó 1 lần, lưu thành cover.jpg trong thư mục game.
// - Game tự thêm (không có trong bảng): tìm trên PlayStation Store theo tên.
// - Không tải được thì hiện chữ viết tắt; có thể chọn ảnh bìa từ thư viện Ảnh.
// ============================================================================

import SwiftUI
import UIKit
import PhotosUI

// MARK: - Game có sẵn trong máy (thêm sẵn vào Thư viện Game)

struct GamePreset {
    let name: String
    let conceptID: String
}

enum GamePresets {
    /// Game của người dùng (không gồm Netflix, Kingdom Come). Mã = store.playstation.com/concept/<mã>
    static let all: [GamePreset] = [
        GamePreset(name: "Until Dawn", conceptID: "10007897"),
        GamePreset(name: "Grand Theft Auto VI", conceptID: "10000730"),
        GamePreset(name: "Ghost of Tsushima", conceptID: "235227"),
        GamePreset(name: "Black Myth: Wukong", conceptID: "10007144"),
        GamePreset(name: "Horizon Zero Dawn Remastered", conceptID: "221727"),
        GamePreset(name: "SILENT HILL 2", conceptID: "10005529"),
        GamePreset(name: "Fallout 4", conceptID: "201511"),
        GamePreset(name: "Wo Long: Fallen Dynasty", conceptID: "10004116"),
        GamePreset(name: "Resident Evil 7 biohazard", conceptID: "220037"),
        GamePreset(name: "Resident Evil 2", conceptID: "229500"),
        GamePreset(name: "Resident Evil Village", conceptID: "235235"),
        GamePreset(name: "Cyberpunk 2077", conceptID: "234567"),
        GamePreset(name: "The Witcher 3: Wild Hunt", conceptID: "204794"),
        GamePreset(name: "eFootball", conceptID: "10002427"),
        GamePreset(name: "Alan Wake 2", conceptID: "10002065"),
        GamePreset(name: "It Takes Two", conceptID: "234689"),
        GamePreset(name: "Sekiro: Shadows Die Twice", conceptID: "232898"),
        GamePreset(name: "A Way Out", conceptID: "227061"),
        GamePreset(name: "Red Dead Redemption 2", conceptID: "209441"),
        GamePreset(name: "Middle-earth: Shadow of War", conceptID: "216695"),
        GamePreset(name: "Middle-earth: Shadow of Mordor", conceptID: "202761"),
    ]

    /// Chuẩn hoá tên để so khớp: chữ thường, bỏ ký tự đặc biệt / ™ ®
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    /// Tên thư mục game có khớp với game có sẵn không ("The Witcher 3: Wild Hunt — Remastered" ~ "The Witcher 3: Wild Hunt")
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard x.count >= 4, y.count >= 4 else { return x == y }
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    static func preset(for folderName: String) -> GamePreset? {
        all.first { matches($0.name, folderName) }
    }
}

// MARK: - Kho ảnh bìa

final class GameCoverStore: ObservableObject {
    static let shared = GameCoverStore()

    @Published private(set) var images: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    private var failedAt: [String: Date] = [:]

    static let coverFileName = "cover.jpg"

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Ảnh bìa đã có (bộ nhớ hoặc file cover.jpg). Không tải mạng.
    func cachedCover(name: String, folderURL: URL) -> UIImage? {
        if let img = images[name] { return img }
        let file = folderURL.appendingPathComponent(Self.coverFileName)
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            DispatchQueue.main.async { self.images[name] = img }
            return img
        }
        return nil
    }

    /// Tải ảnh bìa nếu chưa có (chạy nền, 1 lần; lỗi thì 10 phút sau mới thử lại)
    func ensureCover(name: String, folderURL: URL, force: Bool = false) {
        if !force {
            if images[name] != nil { return }
            if FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(Self.coverFileName).path) {
                _ = cachedCover(name: name, folderURL: folderURL)
                return
            }
            if let failed = failedAt[name], Date().timeIntervalSince(failed) < 600 { return }
        }
        guard !inFlight.contains(name) else { return }
        inFlight.insert(name)

        Task.detached(priority: .utility) { [weak self] in
            let image = await GameCoverStore.downloadCover(for: name)
            await MainActor.run {
                guard let self = self else { return }
                self.inFlight.remove(name)
                if let image = image {
                    if let jpg = image.jpegData(compressionQuality: 0.88) {
                        try? jpg.write(to: folderURL.appendingPathComponent(GameCoverStore.coverFileName), options: .atomic)
                    }
                    self.images[name] = image
                    self.failedAt[name] = nil
                } else {
                    self.failedAt[name] = Date()
                }
            }
        }
    }

    /// Đặt ảnh bìa do người dùng chọn từ thư viện Ảnh
    func setCustomCover(_ image: UIImage, name: String, folderURL: URL) {
        let square = Self.squareCrop(image, side: 512)
        if let jpg = square.jpegData(compressionQuality: 0.9) {
            try? jpg.write(to: folderURL.appendingPathComponent(Self.coverFileName), options: .atomic)
        }
        images[name] = square
        failedAt[name] = nil
    }

    /// Xoá ảnh cũ và tải lại từ PlayStation Store
    func reloadCover(name: String, folderURL: URL) {
        try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(Self.coverFileName))
        images[name] = nil
        failedAt[name] = nil
        ensureCover(name: name, folderURL: folderURL, force: true)
    }

    func forget(name: String) {
        images[name] = nil
        failedAt[name] = nil
    }

    // MARK: Tải từ PlayStation Store

    private static func downloadCover(for name: String) async -> UIImage? {
        var imageURL: String?
        if let preset = GamePresets.preset(for: name) {
            imageURL = await coverURL(conceptID: preset.conceptID)
        }
        if imageURL == nil {
            imageURL = await searchCoverURL(name: name)
        }
        guard let raw = imageURL else { return nil }
        let base = raw.components(separatedBy: "?").first ?? raw
        guard let url = URL(string: base + "?w=512&thumb=false"),
              let data = await fetch(url),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    private static func coverURL(conceptID: String) async -> String? {
        guard let url = URL(string: "https://store.playstation.com/en-us/concept/\(conceptID)"),
              let data = await fetch(url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return extractCoverURL(from: html)
    }

    /// Game không có trong bảng: tìm theo tên trên PlayStation Store
    private static func searchCoverURL(name: String) async -> String? {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://store.playstation.com/en-us/search/\(query)"),
              let data = await fetch(url),
              let html = String(data: data, encoding: .utf8) else { return nil }
        if let concept = firstMatch(#"/concept/(\d+)"#, in: html) {
            if let cover = await coverURL(conceptID: concept) { return cover }
        }
        return firstMatch(#"(https://image\.api\.playstation\.com/vulcan/[^"'\s?\\]+\.(?:png|jpg|jpeg))"#, in: html)
    }

    /// Ảnh bìa vuông trên trang concept: ưu tiên ảnh sản phẩm / vai trò MASTER, cuối cùng lấy ảnh vulcan đầu tiên
    static func extractCoverURL(from rawHTML: String) -> String? {
        let html = rawHTML.replacingOccurrences(of: "\\u002F", with: "/")
        let imagePattern = #"https://image\.api\.playstation\.com/vulcan/[^"'\s?\\]+\.(?:png|jpg|jpeg)"#
        for anchor in ["productImage#image", "\"role\":\"MASTER\"", "GAMEHUB_COVER_ART"] {
            if let range = html.range(of: anchor) {
                let end = html.index(range.upperBound, offsetBy: 2500, limitedBy: html.endIndex) ?? html.endIndex
                let start = html.index(range.lowerBound, offsetBy: -600, limitedBy: html.startIndex) ?? html.startIndex
                // ảnh nằm ngay sau mốc (thẻ img) hoặc ngay trước (JSON "url":..., "role":"MASTER")
                if let after = firstMatch("(" + imagePattern + ")", in: String(html[range.upperBound..<end])) {
                    return after
                }
                if let before = lastMatch("(" + imagePattern + ")", in: String(html[start..<range.lowerBound])) {
                    return before
                }
            }
        }
        return firstMatch("(" + imagePattern + ")", in: html)
    }

    private static func fetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func lastMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func squareCrop(_ image: UIImage, side: CGFloat) -> UIImage {
        let s = min(image.size.width, image.size.height)
        guard s > 0 else { return image }
        let scale = side / s
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

// MARK: - Ảnh bìa game (avatar) dùng trong Thư viện Game và tab Game

struct GameCoverView: View {
    let name: String
    let folderURL: URL
    var size: CGFloat = 54
    var cornerRatio: CGFloat = 0.24
    @ObservedObject private var store = GameCoverStore.shared

    var body: some View {
        Group {
            if let img = store.images[name] ?? store.cachedCover(name: name, folderURL: folderURL) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * cornerRatio, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * cornerRatio, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            } else {
                GameMonogram(name: name, size: size)
            }
        }
        .onAppear { store.ensureCover(name: name, folderURL: folderURL) }
    }
}

/// 1.22: Ảnh bìa lớn, hiện rõ (không làm mờ) ở thẻ "Đang chơi"
struct GameCoverBanner: View {
    let name: String
    let folderURL: URL
    @ObservedObject private var store = GameCoverStore.shared

    var body: some View {
        // Khung gần vuông theo chiều rộng thẻ (ảnh bìa vuông chỉ bị cắt rất ít hai bên trên/dưới);
        // ảnh phủ kín bên trong rồi cắt gọn, không đẩy lệch bố cục
        Color.black
            .aspectRatio(1.2, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                Group {
                    if let img = store.images[name] ?? store.cachedCover(name: name, folderURL: folderURL) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.08)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            GameMonogram(name: name, size: 96)
                        }
                    }
                }
            )
            .clipped()
            .onAppear { store.ensureCover(name: name, folderURL: folderURL) }
    }
}

/// Nút chọn ảnh bìa từ thư viện Ảnh (iOS 16+)
struct CoverPhotoPicker<PickerLabel: View>: View {
    let name: String
    let folderURL: URL
    @ViewBuilder var label: () -> PickerLabel
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
            label()
        }
        .onChange(of: item) { newItem in
            guard let newItem = newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        GameCoverStore.shared.setCustomCover(img, name: name, folderURL: folderURL)
                    }
                }
                await MainActor.run { item = nil }
            }
        }
    }
}

extension GameProfileFolder {
    /// Thư mục của game (chứa data .sqlite và cover.jpg)
    var folderURL: URL { fullSQLiteURL.deletingLastPathComponent() }
}
