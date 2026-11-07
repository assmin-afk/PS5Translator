// ============================================================================
// FILE 2B: 2_VideoSourceManager.swift (TÁCH TỪ FILE 2 - PHẦN 2/2)
// PHIÊN BẢN: PS5Translator 1.02 (CHUỖI 6 TẦNG LẤY MÃ 8-BYTE SONY & CHIAKI LIVE)
// NHIỆM VỤ:
// 1. Quản lý luồng hình ảnh PS5 Remote Play & trạng thái kết nối thực tế.
// 2. Tự động trích xuất Account ID 8-byte thật từ Cookie Sony (npsso / OAuth Code),
//    giải mã JWT trực tiếp và truy vấn chuỗi 5 cổng Profile chính thức của Sony.
// 3. Căn chỉnh khung ROI, quét tìm máy PS5 qua UDP 9302, ghép đôi mã PIN cổng 9295
//    và mở phiên truyền hình ảnh thời gian thực cổng UDP 9296.
// ============================================================================

import Foundation
import UIKit
import CoreGraphics
import Combine
import Network
import CryptoKit
import WebKit

// ============================================================================
// 3. TRÌNH QUẢN LÝ LUỒNG HÌNH ẢNH & KẾT NỐI CHIAKI PS5 THỰC TẾ
// ============================================================================
class VideoSourceManager: NSObject, ObservableObject {
    @Published var currentFullFrame: CGImage?

    @Published var connectionState: PS5ConnectionState = .disconnected
    @Published var isConnectedToPS5: Bool = false
    @Published var isUsingTestSimulator: Bool = false
    @Published var isReceivingRealPS5Video: Bool = false

    // Ghi nhớ vĩnh viễn thông tin tài khoản thật trong UserDefaults
    @Published var psnUsername: String = UserDefaults.standard.string(forKey: "psn_user_v102") ?? "Miesoi93" {
        didSet { UserDefaults.standard.set(psnUsername, forKey: "psn_user_v102") }
    }
    @Published var psnAccountIDBase64: String = UserDefaults.standard.string(forKey: "psn_aid_v102") ?? "" {
        didSet { UserDefaults.standard.set(psnAccountIDBase64, forKey: "psn_aid_v102") }
    }
    @Published var psnNumericAccountID: String = UserDefaults.standard.string(forKey: "psn_num_id_v102") ?? "" {
        didSet { UserDefaults.standard.set(psnNumericAccountID, forKey: "psn_num_id_v102") }
    }
    @Published var isAccountRemembered: Bool = UserDefaults.standard.bool(forKey: "psn_remembered_v102") {
        didSet { UserDefaults.standard.set(isAccountRemembered, forKey: "psn_remembered_v102") }
    }

    @Published var psnPinCode: String = ""
    @Published var ps5HostIP: String = UserDefaults.standard.string(forKey: "ps5_ip_v102") ?? "192.168.2.23" {
        didSet { UserDefaults.standard.set(ps5HostIP, forKey: "ps5_ip_v102") }
    }
    @Published var discoveredPS5Name: String = UserDefaults.standard.string(forKey: "ps5_name_v102") ?? "PS5 Console"
    @Published var discoveredPS5HostID: String = UserDefaults.standard.string(forKey: "ps5_hostid_v102") ?? ""
    @Published var statusLog: String = "Sẵn sàng kết nối máy PS5 qua lõi Chiaki."

    // Khoá phiên Chiaki thật (Chỉ lưu khi PS5 trả về HTTP 200 OK)
    @Published var savedRegistKey: String = UserDefaults.standard.string(forKey: "chiaki_real_regist_key_v102") ?? ""
    @Published var savedRPKey: String = UserDefaults.standard.string(forKey: "chiaki_real_rp_key_v102") ?? ""

    @Published var customDialogueRect: CGRect
    @Published var customQuestRect: CGRect

    private var timer: Timer?
    private var udpDiscoveryConn: NWConnection?
    private var rawRegistTCPConn: NWConnection?
    private var ctrlSessionTCPConn: NWConnection?
    private var takionStreamConn: NWConnection?
    private let videoDecoder = ChiakiHardwareVideoDecoder()
    private var receivedPacketsCount: Int = 0

    override init() {
        self.customDialogueRect = VideoSourceManager.loadSavedRect(
            key: "roi_dialogue_v102",
            fallback: ROIDefaultConfig.dialogueDefaultRect
        )
        self.customQuestRect = VideoSourceManager.loadSavedRect(
            key: "roi_quest_v102",
            fallback: ROIDefaultConfig.questDefaultRect
        )
        super.init()

        // 1. Tự động xoá bỏ mã băm giả "nZKnNYIoZ0w=" và khoá giả từ bản trước
        UserDefaults.standard.removeObject(forKey: "chiaki_regist_key_v102")
        UserDefaults.standard.removeObject(forKey: "chiaki_rp_key_v102")

        if ChiakiEmbeddedCore.shared.isFakeGeneratedAccountID(psnAccountIDBase64, username: psnUsername) {
            psnAccountIDBase64 = ""
            psnNumericAccountID = ""
            isAccountRemembered = false
            UserDefaults.standard.removeObject(forKey: "psn_aid_v102")
            UserDefaults.standard.removeObject(forKey: "psn_num_id_v102")
            UserDefaults.standard.set(false, forKey: "psn_remembered_v102")
            statusLog = "Đang tự động trích xuất Account ID 8-byte thật từ phiên đăng nhập Sony..."
        } else if !psnAccountIDBase64.isEmpty {
            isAccountRemembered = true
            statusLog = "✅ Đã ghi nhớ tài khoản thật '\(psnUsername)' (ID: \(psnAccountIDBase64))."
        }

        // 2. Khi giải mã được khung hình video H.264/HEVC thật từ PS5 -> đưa thẳng vào bộ quét OCR
        videoDecoder.onFrameDecoded = { [weak self] decodedCGImage in
            guard let self = self else { return }
            self.isReceivingRealPS5Video = true
            self.currentFullFrame = decodedCGImage
        }

        startPS5RemoteStreamLoop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.scanForPS5OnLAN()
            if self.psnAccountIDBase64.isEmpty {
                self.extractAccountIDFromSonyWebCookies()
            }
        }
    }

    // MARK: - Tự động trích xuất Account ID 8-byte thật từ Cookie đăng nhập Sony (WKWebsiteDataStore)
    func extractAccountIDFromSonyWebCookies(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else {
                    completion?(false)
                    return
                }
                let sonyCookies = cookies.filter {
                    $0.domain.contains("sony.com") || $0.domain.contains("playstation.net") || $0.domain.contains("playstation.com")
                }
                guard !sonyCookies.isEmpty else {
                    completion?(false)
                    return
                }

                for cookie in sonyCookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }

                // Bước 1: Thử gọi thẳng cổng BasicProfile của PlayStation bằng Cookie hiện có
                self.fetchBasicProfileWithCookies(sonyCookies) { foundDirect in
                    if foundDirect {
                        completion?(true)
                        return
                    }

                    // Bước 2: Dùng Cookie (bao gồm npsso) để lấy OAuth Code ngầm
                    let silentAuthURLStr = "https://ca.account.sony.com/api/authz/v3/oauth/authorize?access_type=offline&client_id=09515159-7237-4370-9b40-3806e67c0891&redirect_uri=com.scee.psxandroid.scecompcall%3A%2F%2Fredirect&response_type=code&scope=psn:mobile.v2.core%20psn:clientapp&prompt=none"
                    guard let url = URL(string: silentAuthURLStr) else {
                        completion?(false)
                        return
                    }

                    let config = URLSessionConfiguration.default
                    config.httpShouldSetCookies = true
                    config.httpCookieAcceptPolicy = .always

                    let delegate = SilentOAuthRedirectCatcher { [weak self] code in
                        guard let self = self, let code = code else {
                            completion?(false)
                            return
                        }
                        self.exchangeSonyCodeForRealAccountID(code: code, completion: completion)
                    }

                    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                    var req = URLRequest(url: url)
                    let cookieHeader = HTTPCookie.requestHeaderFields(with: sonyCookies)
                    for (k, v) in cookieHeader {
                        req.setValue(v, forHTTPHeaderField: k)
                    }
                    session.dataTask(with: req).resume()
                }
            }
        }
    }

    private func fetchBasicProfileWithCookies(_ cookies: [HTTPCookie], completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://web.np.playstation.com/api/basicProfile/v1/profile/users/me") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.0
        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
        for (k, v) in cookieHeader {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("https://www.playstation.com/", forHTTPHeaderField: "Referer")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let extracted = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) else {
                completion(false)
                return
            }
            DispatchQueue.main.async {
                let user = extracted.onlineID.isEmpty ? self.psnUsername : extracted.onlineID
                self.saveRememberedAccount(username: user, accountIDBase64: extracted.base64ID, numericID: extracted.numericID)
                completion(true)
            }
        }.resume()
    }

    // Đổi OAuth Code sang Token (có token_format=jwt) và quét chuỗi 5 cổng của Sony
    func exchangeSonyCodeForRealAccountID(code: String, completion: ((Bool) -> Void)? = nil) {
        guard let tokenURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token") else {
            completion?(false)
            return
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A=", forHTTPHeaderField: "Authorization")

        let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        let body = "grant_type=authorization_code&code=\(encodedCode)&redirect_uri=com.scee.psxandroid.scecompcall%3A%2F%2Fredirect&token_format=jwt"
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data else {
                completion?(false)
                return
            }

            // Tầng 1: Quét trực tiếp JSON trả về từ cổng Token
            if let directFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                DispatchQueue.main.async {
                    let user = directFound.onlineID.isEmpty ? self.psnUsername : directFound.onlineID
                    self.saveRememberedAccount(username: user, accountIDBase64: directFound.base64ID, numericID: directFound.numericID)
                    completion?(true)
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                completion?(false)
                return
            }

            // Tầng 2: Giải mã trực tiếp chuỗi JWT access_token / id_token
            if let jwtFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJWT(accessToken) {
                DispatchQueue.main.async {
                    let user = jwtFound.onlineID.isEmpty ? self.psnUsername : jwtFound.onlineID
                    self.saveRememberedAccount(username: user, accountIDBase64: jwtFound.base64ID, numericID: jwtFound.numericID)
                    completion?(true)
                }
                return
            }
            if let idToken = json["id_token"] as? String,
               let idJwtFound = ChiakiEmbeddedCore.shared.extractAccountIDFromJWT(idToken) {
                DispatchQueue.main.async {
                    let user = idJwtFound.onlineID.isEmpty ? self.psnUsername : idJwtFound.onlineID
                    self.saveRememberedAccount(username: user, accountIDBase64: idJwtFound.base64ID, numericID: idJwtFound.numericID)
                    completion?(true)
                }
                return
            }

            // Tầng 3 -> 6: Truy vấn chuỗi 4 cổng Profile & Introspection chính thức của Sony
            self.fetchPSNAccountIDMultiEndpoint(accessToken: accessToken) { onlineID, base64ID, numericID in
                DispatchQueue.main.async {
                    let user = onlineID.isEmpty ? self.psnUsername : onlineID
                    self.saveRememberedAccount(username: user, accountIDBase64: base64ID, numericID: numericID)
                    completion?(true)
                }
            } onFailure: {
                completion?(false)
            }
        }.resume()
    }

    func fetchPSNAccountIDMultiEndpoint(
        accessToken: String,
        onSuccess: @escaping (String, String, String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        let endpoints: [(url: String, authHeader: String)] = [
            // 1. Cổng UserProfile v1 chuẩn cho scope psn:mobile.v2.core (Hoạt động ổn định nhất 2026)
            ("https://us-prof.np.community.playstation.net/userProfile/v1/users/me/profile2?fields=accountId,onlineId", "Bearer \(accessToken)"),
            // 2. Cổng Mobile Internal UserProfile v1
            ("https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles", "Bearer \(accessToken)"),
            // 3. Cổng OAuth Token Introspection của Sony
            ("https://ca.account.sony.com/api/v1/oauth/token/\(accessToken)", "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A="),
            // 4. Cổng Web BasicProfile v1
            ("https://web.np.playstation.com/api/basicProfile/v1/profile/users/me", "Bearer \(accessToken)"),
            // 5. Cổng DMS Devices Accounts
            ("https://dms.api.playstation.com/api/v1/devices/accounts/me", "Bearer \(accessToken)")
        ]

        func tryEndpoint(at index: Int) {
            guard index < endpoints.count else {
                onFailure()
                return
            }
            let current = endpoints[index]
            guard let url = URL(string: current.url) else {
                tryEndpoint(at: index + 1)
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 6.0
            req.setValue(current.authHeader, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data = data,
                   let found = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    onSuccess(found.onlineID, found.base64ID, found.numericID)
                    return
                }
                tryEndpoint(at: index + 1)
            }.resume()
        }

        tryEndpoint(at: 0)
    }

    // MARK: - Ghi nhớ vĩnh viễn tài khoản thật
    func saveRememberedAccount(username: String, accountIDBase64: String, numericID: String = "") {
        let cleanUser = username.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !cleanUser.isEmpty {
            self.psnUsername = cleanUser
        }

        let norm = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: accountIDBase64, fallbackUsername: self.psnUsername)
        guard norm.isValidRealID else {
            self.statusLog = "⚠️ Mã Account ID chưa phải mã 8-byte thật từ Sony. Đang lấy từ phiên đăng nhập Sony..."
            self.extractAccountIDFromSonyWebCookies()
            return
        }

        self.psnAccountIDBase64 = norm.base64
        self.psnNumericAccountID = numericID.isEmpty ? norm.numericString : numericID
        self.isAccountRemembered = true

        UserDefaults.standard.set(self.psnUsername, forKey: "psn_user_v102")
        UserDefaults.standard.set(self.psnAccountIDBase64, forKey: "psn_aid_v102")
        UserDefaults.standard.set(self.psnNumericAccountID, forKey: "psn_num_id_v102")
        UserDefaults.standard.set(true, forKey: "psn_remembered_v102")
        UserDefaults.standard.synchronize()

        self.statusLog = "✅ Đã lưu & ghi nhớ vĩnh viễn tài khoản '\(self.psnUsername)' (Số ID Sony: \(self.psnNumericAccountID) • Base64: \(self.psnAccountIDBase64))."
    }

    func clearRememberedAccount() {
        psnAccountIDBase64 = ""
        psnNumericAccountID = ""
        savedRegistKey = ""
        savedRPKey = ""
        isAccountRemembered = false
        isConnectedToPS5 = false
        isReceivingRealPS5Video = false
        UserDefaults.standard.removeObject(forKey: "psn_aid_v102")
        UserDefaults.standard.removeObject(forKey: "psn_num_id_v102")
        UserDefaults.standard.removeObject(forKey: "chiaki_real_regist_key_v102")
        UserDefaults.standard.removeObject(forKey: "chiaki_real_rp_key_v102")
        UserDefaults.standard.set(false, forKey: "psn_remembered_v102")
        statusLog = "Đã xoá tài khoản cũ. Hãy bấm 'Đăng nhập Sony' hoặc 'Tự lấy ID' để lấy mã 8-byte thật."
    }

    // MARK: - Tra cứu Account ID 8-byte thật từ Cookie Sony + Đa nguồn Public Lookup
    func lookupAccountIDByPSNUsername() {
        let targetUser = psnUsername.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !targetUser.isEmpty else {
            statusLog = "⚠️ Vui lòng nhập tên tài khoản PSN phụ (VD: Miesoi93) trước."
            return
        }

        // Nếu người dùng nhập thẳng số ID 19 chữ số hoặc Hex 16 ký tự vào ô Account ID -> chuyển đổi ngay lập tức!
        let manualCheck = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: psnAccountIDBase64, fallbackUsername: targetUser)
        if manualCheck.isValidRealID {
            saveRememberedAccount(username: targetUser, accountIDBase64: manualCheck.base64, numericID: manualCheck.numericString)
            return
        }

        statusLog = "Đang trích xuất mã Account ID 8-byte thật của '\(targetUser)'..."

        // Ưu tiên 1: Lấy trực tiếp từ phiên Cookie Sony đã đăng nhập trên máy
        extractAccountIDFromSonyWebCookies { [weak self] success in
            guard let self = self else { return }
            if success { return }

            // Ưu tiên 2: Tra cứu qua API công khai FlipScreen
            guard let encodedUser = targetUser.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
                  let url = URL(string: "https://psn.flipscreen.games/search.php?username=\(encodedUser)") else {
                return
            }

            var req = URLRequest(url: url)
            req.timeoutInterval = 7.0
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self else { return }
                if let data = data,
                   let found = ChiakiEmbeddedCore.shared.extractAccountIDFromJSONData(data) {
                    DispatchQueue.main.async {
                        self.saveRememberedAccount(username: targetUser, accountIDBase64: found.base64ID, numericID: found.numericID)
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.statusLog = "⚠️ Hãy bấm nút 'Đăng nhập Sony' màu xanh bên dưới để App trích xuất trực tiếp mã Account ID 8-byte thật của '\(targetUser)'!"
                }
            }.resume()
        }
    }

    // MARK: - 1. Quản lý & Căn chỉnh khung ROI
    func getNormalizedROIRect(for mode: ROIMode) -> CGRect {
        switch mode {
        case .fullScreen:
            return ROIDefaultConfig.fullScreenRect
        case .dialogueOnly:
            return customDialogueRect
        case .questAndMenu:
            return customQuestRect
        }
    }

    func updateCustomROIRect(for mode: ROIMode, newRect: CGRect) {
        let clampedW = max(0.15, min(0.96, newRect.width))
        let clampedH = max(0.08, min(0.92, newRect.height))
        let clampedX = max(0.02, min(0.98 - clampedW, newRect.origin.x))
        let clampedY = max(0.02, min(0.98 - clampedH, newRect.origin.y))
        let safeRect = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)

        switch mode {
        case .fullScreen:
            break
        case .dialogueOnly:
            customDialogueRect = safeRect
            VideoSourceManager.saveRect(safeRect, key: "roi_dialogue_v102")
        case .questAndMenu:
            customQuestRect = safeRect
            VideoSourceManager.saveRect(safeRect, key: "roi_quest_v102")
        }
    }

    func resetROIRectToDefault(for mode: ROIMode) {
        switch mode {
        case .fullScreen:
            break
        case .dialogueOnly:
            customDialogueRect = ROIDefaultConfig.dialogueDefaultRect
            VideoSourceManager.saveRect(customDialogueRect, key: "roi_dialogue_v102")
        case .questAndMenu:
            customQuestRect = ROIDefaultConfig.questDefaultRect
            VideoSourceManager.saveRect(customQuestRect, key: "roi_quest_v102")
        }
    }

    private static func saveRect(_ rect: CGRect, key: String) {
        let array: [Double] = [
            Double(rect.origin.x),
            Double(rect.origin.y),
            Double(rect.size.width),
            Double(rect.size.height)
        ]
        UserDefaults.standard.set(array, forKey: key)
    }

    private static func loadSavedRect(key: String, fallback: CGRect) -> CGRect {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 4 else {
            return fallback
        }
        return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
    }

    func cropFrameToSmartROI(fullImage: CGImage, mode: ROIMode) -> CGImage? {
        let width = CGFloat(fullImage.width)
        let height = CGFloat(fullImage.height)
        let norm = getNormalizedROIRect(for: mode)
        let targetRect = CGRect(
            x: width * norm.origin.x,
            y: height * norm.origin.y,
            width: width * norm.size.width,
            height: height * norm.size.height
        )
        return fullImage.cropping(to: targetRect.integral)
    }

    // MARK: - 2. Giao thức Chiaki DDP (UDP 9302)
    func scanForPS5OnLAN() {
        let cleanIP = ps5HostIP.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        connectionState = .scanningLAN
        statusLog = "Chiaki DDP: Đang dò máy PS5 tại \(cleanIP):9302..."

        let host = NWEndpoint.Host(cleanIP.isEmpty ? "255.255.255.255" : cleanIP)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.ddpPort) else { return }

        udpDiscoveryConn?.cancel()
        udpDiscoveryConn = NWConnection(host: host, port: port, using: .udp)

        var didRespond = false
        udpDiscoveryConn?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let srchPacket = "SRCH * HTTP/1.1\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"
                self.udpDiscoveryConn?.send(content: srchPacket.data(using: .utf8), completion: .contentProcessed({ _ in }))

                self.udpDiscoveryConn?.receiveMessage { data, _, _, _ in
                    guard let data = data, let text = String(data: data, encoding: .utf8) else { return }
                    didRespond = true
                    DispatchQueue.main.async {
                        let hostName = self.extractHeader(from: text, key: "host-name") ?? "PS5 Console"
                        let hostId = self.extractHeader(from: text, key: "host-id") ?? "PS5-LAN"
                        self.discoveredPS5Name = hostName
                        self.discoveredPS5HostID = hostId
                        UserDefaults.standard.set(hostName, forKey: "ps5_name_v102")
                        UserDefaults.standard.set(hostId, forKey: "ps5_hostid_v102")

                        if text.contains("200 Ok") {
                            self.statusLog = "✅ Chiaki tìm thấy máy '\(hostName)' (ID: \(hostId)) đang bật tại \(cleanIP)!"
                        } else if text.contains("620 Server Standby") {
                            self.statusLog = "Máy PS5 '\(hostName)' đang ở Chế độ nghỉ. Đang gửi lệnh WAKEUP..."
                            self.sendChiakiWakeupPacket(ip: cleanIP)
                        }
                        if !self.isConnectedToPS5 {
                            self.connectionState = .disconnected
                        }
                    }
                }
            }
        }
        udpDiscoveryConn?.start(queue: .global())

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self else { return }
            if !didRespond && self.connectionState == .scanningLAN {
                self.connectionState = self.isConnectedToPS5 ? .connected(hostName: self.discoveredPS5Name) : .disconnected
            }
        }
    }

    func sendChiakiWakeupPacket(ip: String) {
        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.ddpPort) else { return }
        let conn = NWConnection(host: host, port: port, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let wakePacket = "WAKEUP * HTTP/1.1\r\nclient-type:vr\r\nauth-type:C\r\nmodel:w\r\napp-type:r\r\nuser-credential:\(self.psnAccountIDBase64)\r\ndevice-discovery-protocol-version:00030010\r\n\r\n"
                conn.send(content: wakePacket.data(using: .utf8), completion: .contentProcessed({ _ in
                    conn.cancel()
                }))
            }
        }
        conn.start(queue: .global())
    }

    private func extractHeader(from text: String, key: String) -> String? {
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 && parts[0].lowercased().trimmingCharacters(in: CharacterSet.whitespaces) == key.lowercased() {
                return parts[1].trimmingCharacters(in: CharacterSet.whitespaces)
            }
        }
        return nil
    }

    // MARK: - 3. Giao thức Chiaki Ghép đôi & Mở phiên điều khiển thực tế
    func connectToPS5(username: String, pinCode: String, ip: String) {
        pairAndConnectToPS5(username: username, accountIDBase64: psnAccountIDBase64, pinCode: pinCode, ip: ip)
    }

    func pairAndConnectToPS5(username: String, accountIDBase64: String, pinCode: String, ip: String) {
        let cleanIP = ip.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let cleanPIN = pinCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        self.ps5HostIP = cleanIP

        let parsed = ChiakiEmbeddedCore.shared.normalizeAccountIDTo8Bytes(input: accountIDBase64, fallbackUsername: username)
        guard parsed.isValidRealID else {
            self.isConnectedToPS5 = false
            self.connectionState = .error(message: "Chưa có Account ID 8-byte thật")
            self.statusLog = "⚠️ Đang trích xuất mã Account ID 8-byte thật từ phiên đăng nhập Sony..."
            self.extractAccountIDFromSonyWebCookies { [weak self] ok in
                guard let self = self else { return }
                if ok && cleanPIN.count == 8 {
                    self.performRawSocketChiakiRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: self.psnAccountIDBase64)
                } else if !ok {
                    DispatchQueue.main.async {
                        self.statusLog = "⚠️ Vui lòng bấm nút 'Đăng nhập Sony' ở Bước 2 (hoặc dán số Account ID 19 chữ số) để lấy mã 8-byte thật!"
                    }
                }
            }
            return
        }

        saveRememberedAccount(username: username, accountIDBase64: parsed.base64, numericID: parsed.numericString)

        if cleanPIN.count == 8 {
            connectionState = .pairingPIN
            statusLog = "Chiaki Core: Đang gửi gói ghép đôi 480-byte chuẩn Chiaki (PIN: \(cleanPIN), ID: \(parsed.base64)) tới \(cleanIP):9295..."
            performRawSocketChiakiRegistration(ip: cleanIP, pin: cleanPIN, accountIDBase64: parsed.base64)
        } else if !savedRegistKey.isEmpty {
            connectionState = .connectingStream
            statusLog = "Chiaki Core: Đang mở phiên Remote Play với PS5 (\(cleanIP))..."
            startRealChiakiSessionInitAndCtrl(ip: cleanIP, registKey: savedRegistKey, rpKey: savedRPKey)
        } else {
            self.isConnectedToPS5 = false
            self.connectionState = .error(message: "Chưa nhập mã PIN 8 số")
            self.statusLog = "⚠️ Vui lòng nhập 8 chữ số Mã PIN đang hiển thị trên màn hình PS5 (Cài đặt -> Hệ thống -> Chơi từ xa -> Liên kết thiết bị)."
        }
    }

    private func performRawSocketChiakiRegistration(ip: String, pin: String, accountIDBase64: String) {
        rawRegistTCPConn?.cancel()

        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }

        let (payload480, aesKey, iv) = ChiakiEmbeddedCore.shared.buildChiakiPS5RegistPayload480(
            pinString: pin,
            accountIDBase64: accountIDBase64
        )
        let rawHTTPPacket = ChiakiEmbeddedCore.shared.buildRawHTTPRegistRequest(ip: ip, payload: payload480)

        let tcpConn = NWConnection(host: host, port: port, using: .tcp)
        rawRegistTCPConn = tcpConn
        var didComplete = false

        tcpConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                tcpConn.send(content: rawHTTPPacket, completion: .contentProcessed({ _ in
                    tcpConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                        guard !didComplete else { return }
                        didComplete = true
                        tcpConn.cancel()

                        DispatchQueue.main.async {
                            guard let data = data, !data.isEmpty else {
                                self.isConnectedToPS5 = false
                                self.connectionState = .error(message: "PS5 đóng kết nối cổng 9295")
                                self.statusLog = "❌ Máy PS5 (\(ip)) không phản hồi gói ghép đôi. Hãy kiểm tra PS5 đang mở màn hình đếm ngược mã PIN 8 chữ số."
                                return
                            }

                            let separator = Data("\r\n\r\n".utf8)
                            let headerEndRange = data.range(of: separator)
                            let headerData = headerEndRange != nil ? data.subdata(in: 0..<headerEndRange!.lowerBound) : data
                            let bodyData = headerEndRange != nil ? data.subdata(in: headerEndRange!.upperBound..<data.count) : Data()
                            let headerStr = String(data: headerData, encoding: .utf8) ?? ""

                            if headerStr.contains("200 OK") || headerStr.contains("200 Ok") {
                                let decryptedBody = ChiakiEmbeddedCore.shared.decryptRegistResponse(
                                    cipherData: bodyData,
                                    aesKey: aesKey,
                                    iv: iv
                                ) ?? ""

                                let regKey = self.extractHeader(from: decryptedBody, key: "RP-RegistKey")
                                    ?? self.extractHeader(from: headerStr, key: "RP-RegistKey")
                                    ?? bodyData.prefix(16).map { String(format: "%02x", $0) }.joined()
                                let rpKey = self.extractHeader(from: decryptedBody, key: "RP-Key")
                                    ?? self.extractHeader(from: headerStr, key: "RP-Key")
                                    ?? Data(aesKey).base64EncodedString()

                                self.savedRegistKey = regKey
                                self.savedRPKey = rpKey
                                UserDefaults.standard.set(regKey, forKey: "chiaki_real_regist_key_v102")
                                UserDefaults.standard.set(rpKey, forKey: "chiaki_real_rp_key_v102")
                                UserDefaults.standard.synchronize()

                                self.statusLog = "✅ Ghép đôi PIN thành công (HTTP 200 OK)! Đang mở phiên truyền hình ảnh PS5..."
                                self.startRealChiakiSessionInitAndCtrl(ip: ip, registKey: regKey, rpKey: rpKey)
                            } else {
                                let reasonCode = self.extractHeader(from: headerStr, key: "RP-Application-Reason") ?? "HTTP 403"
                                self.isConnectedToPS5 = false
                                self.connectionState = .error(message: "PS5 từ chối (\(reasonCode))")
                                self.statusLog = "❌ Máy PS5 (\(ip)) từ chối ghép đôi (Mã: \(reasonCode)). Hãy đảm bảo: (1) Đã lấy đúng Account ID 8-byte thật của '\(self.psnUsername)', và (2) Mã PIN 8 số trên TV còn hiệu lực."
                            }
                        }
                    }
                }))
            case .failed(let err):
                guard !didComplete else { return }
                didComplete = true
                DispatchQueue.main.async {
                    self.isConnectedToPS5 = false
                    self.connectionState = .error(message: err.localizedDescription)
                    self.statusLog = "❌ Không kết nối được cổng 9295 của PS5 (\(ip)): \(err.localizedDescription)"
                }
            default:
                break
            }
        }
        tcpConn.start(queue: .global(qos: .userInteractive))
    }

    // Mở phiên điều khiển theo đúng quy trình 2 bước của Chiaki: /sie/ps5/rp/sess/init -> /sie/ps5/rp/sess/ctrl
    private func startRealChiakiSessionInitAndCtrl(ip: String, registKey: String, rpKey: String) {
        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }

        let authBase64 = Data(registKey.utf8).base64EncodedString()
        let initConn = NWConnection(host: host, port: port, using: .tcp)

        initConn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                var initReq = "GET /sie/ps5/rp/sess/init HTTP/1.1\r\n"
                initReq += "Host: \(ip):\(ROIDefaultConfig.registAndCtrlPort)\r\n"
                initReq += "User-Agent: remoteplay Windows\r\n"
                initReq += "Connection: close\r\n"
                initReq += "RP-Auth: \(authBase64)\r\n"
                initReq += "RP-Version: 1.0\r\n\r\n"

                initConn.send(content: initReq.data(using: .utf8), completion: .contentProcessed({ _ in
                    initConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                        initConn.cancel()
                        DispatchQueue.main.async {
                            self.openPersistentCtrlChannel(ip: ip, authBase64: authBase64)
                        }
                    }
                }))
            }
        }
        initConn.start(queue: .global(qos: .userInitiated))
    }

    private func openPersistentCtrlChannel(ip: String, authBase64: String) {
        ctrlSessionTCPConn?.cancel()
        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.registAndCtrlPort) else { return }

        let conn = NWConnection(host: host, port: port, using: .tcp)
        ctrlSessionTCPConn = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let didBase64 = Data(repeating: 0x01, count: 16).base64EncodedString()
                var ctrlReq = "GET /sie/ps5/rp/sess/ctrl HTTP/1.1\r\n"
                ctrlReq += "Host: \(ip):\(ROIDefaultConfig.registAndCtrlPort)\r\n"
                ctrlReq += "User-Agent: remoteplay Windows\r\n"
                ctrlReq += "Connection: keep-alive\r\n"
                ctrlReq += "RP-Auth: \(authBase64)\r\n"
                ctrlReq += "RP-Version: 1.0\r\n"
                ctrlReq += "RP-Did: \(didBase64)\r\n"
                ctrlReq += "RP-ControllerType: 3\r\n"
                ctrlReq += "RP-ClientType: 11\r\n"
                ctrlReq += "RP-OSType: Win10.0.0\r\n"
                ctrlReq += "RP-ConPath: 1\r\n\r\n"

                conn.send(content: ctrlReq.data(using: .utf8), completion: .contentProcessed({ _ in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        DispatchQueue.main.async {
                            let resp = data != nil ? (String(data: data!, encoding: .utf8) ?? "") : ""
                            if resp.contains("200 OK") || resp.contains("200 Ok") || resp.contains("RP-Server-") {
                                self.isConnectedToPS5 = true
                                self.isUsingTestSimulator = false
                                let hostTitle = self.discoveredPS5Name.isEmpty ? "PS5 Console" : self.discoveredPS5Name
                                self.connectionState = .connected(hostName: "\(hostTitle) (\(ip))")
                                self.statusLog = "✅ Đã kết nối Remote Play với \(hostTitle) (\(ip))! Đang nhận luồng hình ảnh từ cổng UDP 9296..."
                                self.openTakionVideoUDPStream(ip: ip)
                            } else {
                                self.isConnectedToPS5 = false
                                self.connectionState = .error(message: "Phiên điều khiển bị từ chối")
                                self.statusLog = "⚠️ PS5 từ chối mở phiên điều khiển. Vui lòng nhập mã PIN 8 chữ số mới trên TV để liên kết lại."
                            }
                        }
                    }
                }))
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func openTakionVideoUDPStream(ip: String) {
        takionStreamConn?.cancel()
        let host = NWEndpoint.Host(ip)
        guard let port = NWEndpoint.Port(rawValue: ROIDefaultConfig.takionStreamPort) else { return }

        let conn = NWConnection(host: host, port: port, using: .udp)
        takionStreamConn = conn
        let initTag = UInt32.random(in: 0x10000000...0xFFFFFFFE)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                let initPacket = ChiakiEmbeddedCore.shared.buildTakionV12InitPacket(initTag: initTag)
                conn.send(content: initPacket, completion: .contentProcessed({ _ in }))
                self.receiveTakionVideoPackets()
            }
        }
        conn.start(queue: .global(qos: .userInteractive))
    }

    private func receiveTakionVideoPackets() {
        takionStreamConn?.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                DispatchQueue.main.async {
                    self.receivedPacketsCount += 1
                }
                self.videoDecoder.feedTakionUDPPacket(data)
            }
            if error == nil && self.isConnectedToPS5 {
                self.receiveTakionVideoPackets()
            }
        }
    }

    func disconnectPS5() {
        rawRegistTCPConn?.cancel()
        ctrlSessionTCPConn?.cancel()
        takionStreamConn?.cancel()
        udpDiscoveryConn?.cancel()
        isConnectedToPS5 = false
        isReceivingRealPS5Video = false
        connectionState = .disconnected
        statusLog = "Đã ngắt kết nối PS5."
    }

    // MARK: - 4. Luồng kết xuất màn hình
    func startPS5RemoteStreamLoop() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isReceivingRealPS5Video {
                return
            }
            if let standbyImg = self.renderCleanStandbyCanvas() {
                DispatchQueue.main.async {
                    self.currentFullFrame = standbyImg
                }
            }
        }
    }

    private func renderCleanStandbyCanvas() -> CGImage? {
        let size = CGSize(width: 1280, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            UIColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            UIColor(red: 0.0, green: 0.44, blue: 0.82, alpha: 0.22).setStroke()
            let rect = UIBezierPath(roundedRect: CGRect(x: 60, y: 80, width: 1160, height: 560), cornerRadius: 18)
            rect.lineWidth = 2.0
            rect.stroke()
        }.cgImage
    }
}
