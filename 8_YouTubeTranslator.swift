// ============================================================================
// FILE 8: 8_YouTubeTranslator.swift
// PHIÊN BẢN: PS5Translator 1.12
//
// TAB "DỊCH YOUTUBE": xem YouTube ngay trong app để kiểm tra chất lượng quét + dịch
// (dùng CÙNG bộ máy quét chữ thông minh như màn hình PS5).
// - Trình duyệt m.youtube.com nhúng (WKWebView), chặn tên miền quảng cáo, tự bỏ qua
//   quảng cáo video, ẩn khung quảng cáo.
// - Lấy khung hình video bằng JavaScript (canvas) -> OCR -> dịch -> vẽ khung dịch đè
//   đúng vị trí trên video. Dự phòng: chụp ảnh WKWebView.
// - Nút toàn màn hình của YouTube được chuyển thành chế độ XOAY NGANG của app.
//
// Kèm: OrientationController + AppOrientationDelegate (xoay ngang toàn màn hình cho
// cả YouTube và PS5).
// ============================================================================

import SwiftUI
import WebKit
import UIKit

// MARK: - Xoay màn hình

final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

enum OrientationController {
    static func setLandscape(_ landscape: Bool) {
        AppOrientationDelegate.orientationLock = landscape ? .landscape : .portrait
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        if #available(iOS 16.0, *) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case ps5
    case youtube
    var id: String { rawValue }
    var title: String { self == .ps5 ? "Remote PS5" : "Dịch YouTube" }
    var icon: String { self == .ps5 ? "gamecontroller.fill" : "play.rectangle.fill" }
}

// MARK: - Mô hình trình duyệt YouTube

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

final class YouTubeTranslatorModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let homeURL = URL(string: "https://m.youtube.com")!

    @Published var addressText: String = "https://m.youtube.com"
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    /// Vị trí phần hình video thật (không tính viền đen) trong toạ độ WKWebView (point)
    @Published var videoRect: CGRect = .zero
    @Published var captureStatus: String = "Mở 1 video có phụ đề tiếng Anh để bắt đầu dịch"
    @Published var isTranslating = true {
        didSet { if !isTranslating { coordinator?.youtubeBoxes = [] } }
    }
    @Published var captureMethod: String = "—"

    let webView: WKWebView
    weak var coordinator: PipelineCoordinator?

    private var timer: Timer?
    private var capturing = false
    private var isActive = false
    private var useSnapshotFallback = false
    private var blackSnapshotCount = 0
    private var lastFrameTime = Date.distantPast

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        let handler = WeakScriptHandler(self)
        controller.add(handler, name: "ps5tEvent")
        controller.addUserScript(WKUserScript(source: Self.injectedJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.customUserAgent = nil

        installAdBlockRules { [weak self] in
            self?.webView.load(URLRequest(url: Self.homeURL))
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Chặn quảng cáo (content blocker của WebKit)
    private func installAdBlockRules(then load: @escaping () -> Void) {
        // Biểu thức chính quy cho url-filter của WebKit (tạo JSON bằng JSONSerialization để đúng ký tự thoát)
        let filters = [
            "doubleclick\\.net", "googlesyndication\\.com", "googleadservices\\.com", "google-analytics\\.com",
            "imasdk\\.googleapis\\.com", "adservice\\.google\\.com", "s0\\.2mdn\\.net",
            "youtube\\.com/api/stats/ads", "youtube\\.com/pagead", "youtube\\.com/ptracking",
            "youtube\\.com/get_midroll_info"
        ]
        let rules: [[String: Any]] = filters.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else {
            load()
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ps5t-adblock-v112", encodedContentRuleList: json) { [weak self] list, _ in
            DispatchQueue.main.async {
                if let list = list { self?.webView.configuration.userContentController.add(list) }
                load()
            }
        }
    }

    // MARK: Điều hướng
    func loadAddress() {
        let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            url = URL(string: text)
        } else if text.contains("youtube.com") || text.contains("youtu.be") {
            url = URL(string: "https://" + text)
        } else {
            let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            url = URL(string: "https://m.youtube.com/results?search_query=\(q)")
        }
        if let u = url { webView.load(URLRequest(url: u)) }
    }

    func goHome() { webView.load(URLRequest(url: Self.homeURL)) }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { webView.reload() }

    func setFullscreenCSS(_ on: Bool) {
        webView.evaluateJavaScript("window.__ps5tFullscreen && window.__ps5tFullscreen(\(on ? "true" : "false"))", completionHandler: nil)
    }

    // MARK: Vòng quét
    func setActive(_ active: Bool) {
        isActive = active
        timer?.invalidate()
        timer = nil
        guard active else {
            coordinator?.youtubeBoxes = []
            return
        }
        let fps = min(6.0, max(1.0, coordinator?.scanFPS ?? 4.0))
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            self?.captureTick()
        }
    }

    private func captureTick() {
        guard isActive, isTranslating, !capturing, let coord = coordinator, !coord.isYouTubeOCRBusy else { return }
        capturing = true
        if useSnapshotFallback {
            snapshotCapture()
            return
        }
        webView.evaluateJavaScript("window.__ps5tCapture ? window.__ps5tCapture(960) : null") { [weak self] result, _ in
            guard let self = self else { return }
            guard let dict = result as? [String: Any] else {
                self.capturing = false
                self.captureStatus = "Mở 1 video để bắt đầu dịch"
                return
            }
            self.updateRect(from: dict)
            if (dict["ad"] as? Bool) == true {
                self.capturing = false
                self.captureStatus = "Đang bỏ qua quảng cáo..."
                self.coordinator?.youtubeBoxes = []
                return
            }
            if (dict["ok"] as? Bool) == true, let b64 = dict["data"] as? String {
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = Data(base64Encoded: b64).flatMap { UIImage(data: $0)?.cgImage }
                    DispatchQueue.main.async {
                        self.capturing = false
                        guard let img = image else { return }
                        self.captureMethod = "Canvas video (\(img.width)×\(img.height))"
                        self.captureStatus = "Đang quét video bằng canvas"
                        self.coordinator?.processYouTubeFrame(img)
                    }
                }
                return
            }
            self.capturing = false
            let err = (dict["err"] as? String) ?? ""
            switch err {
            case "novideo": self.captureStatus = "Mở 1 video để bắt đầu dịch"
            case "notready": self.captureStatus = "Video đang tải..."
            default:
                // Canvas bị chặn (SecurityError do video khác tên miền) -> chụp ảnh WKWebView
                self.useSnapshotFallback = true
                self.captureStatus = "Canvas bị chặn (\(err)) → chuyển sang chụp ảnh trình duyệt"
            }
        }
    }

    private func snapshotCapture() {
        // Cập nhật vị trí video trước
        webView.evaluateJavaScript("window.__ps5tRect ? window.__ps5tRect() : null") { [weak self] result, _ in
            guard let self = self else { return }
            if let dict = result as? [String: Any] { self.updateRect(from: dict) }
            let rect = self.videoRect
            guard rect.width > 40, rect.height > 30 else {
                self.capturing = false
                self.captureStatus = "Mở 1 video để bắt đầu dịch"
                return
            }
            let cfg = WKSnapshotConfiguration()
            cfg.rect = rect
            cfg.afterScreenUpdates = false
            cfg.snapshotWidth = NSNumber(value: Double(min(960, rect.width * UIScreen.main.scale)))
            self.webView.takeSnapshot(with: cfg) { image, _ in
                self.capturing = false
                guard let cg = image?.cgImage else { return }
                if Self.isNearlyBlack(cg) {
                    self.blackSnapshotCount += 1
                    if self.blackSnapshotCount >= 6 {
                        self.captureStatus = "⚠️ iOS không cho chụp hình video này (ảnh đen). Thử video khác hoặc tải lại trang."
                        self.useSnapshotFallback = false   // thử lại canvas ở video sau
                        self.blackSnapshotCount = 0
                    }
                    return
                }
                self.blackSnapshotCount = 0
                self.captureMethod = "Chụp ảnh trình duyệt (\(cg.width)×\(cg.height))"
                self.captureStatus = "Đang quét video bằng ảnh chụp"
                self.coordinator?.processYouTubeFrame(cg)
            }
        }
    }

    private func updateRect(from dict: [String: Any]) {
        guard let x = (dict["x"] as? NSNumber)?.doubleValue, let y = (dict["y"] as? NSNumber)?.doubleValue,
              let w = (dict["w"] as? NSNumber)?.doubleValue, let h = (dict["h"] as? NSNumber)?.doubleValue else { return }
        let r = CGRect(x: x, y: y, width: w, height: h)
        if abs(r.minX - videoRect.minX) > 0.5 || abs(r.minY - videoRect.minY) > 0.5
            || abs(r.width - videoRect.width) > 0.5 || abs(r.height - videoRect.height) > 0.5 {
            videoRect = r
        }
    }

    static func isNearlyBlack(_ image: CGImage) -> Bool {
        let w = 16, h = 9
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return false }
        return buf.max().map { $0 < 12 } ?? true
    }

    // MARK: Tin nhắn từ JavaScript
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ps5tEvent", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "rect":
            updateRect(from: body)
        case "fullscreen":
            coordinator?.isLandscapeFullscreen.toggle()
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let u = webView.url?.absoluteString { addressText = u }
        useSnapshotFallback = false
        coordinator?.resetYouTubeTracking()
        if coordinator?.isLandscapeFullscreen == true { setFullscreenCSS(true) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Không mở app YouTube / App Store bên ngoài, giữ người dùng trong app
        if let scheme = navigationAction.request.url?.scheme?.lowercased(), !["http", "https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.cancel)
            return
        }
        // YouTube là web 1 trang: đổi video bằng JS -> cập nhật thanh địa chỉ
        DispatchQueue.main.async {
            self.canGoBack = webView.canGoBack
            self.canGoForward = webView.canGoForward
            if let u = navigationAction.request.url?.absoluteString, navigationAction.targetFrame?.isMainFrame == true {
                self.addressText = u
            }
        }
        decisionHandler(.allow)
    }

    // MARK: JavaScript chèn vào trang YouTube
    static let injectedJS = """
    (function(){
      if (window.__ps5tInstalled) return; window.__ps5tInstalled = true;
      var css = [
        'ytm-promoted-sparkles-web-renderer, ytm-companion-ad-renderer, ad-slot-renderer, ytm-ad-slot-renderer,',
        'ytm-promoted-video-renderer, .ytp-ad-module, .ytp-ad-overlay-container, #player-ads, .ad-container,',
        'ytm-display-ad-renderer, ytm-mealbar-promo-renderer, ytm-statement-banner-renderer, .ytd-ad-slot-renderer,',
        'ytm-paid-content-overlay-renderer, .ytp-paid-content-overlay { display:none !important; }',
        'html.ps5t-fs, html.ps5t-fs body { overflow:hidden !important; background:#000 !important; }',
        'html.ps5t-fs #player-container-id, html.ps5t-fs .player-container, html.ps5t-fs #player {',
        '  position:fixed !important; left:0 !important; top:0 !important; width:100vw !important; height:100vh !important;',
        '  max-height:none !important; z-index:2147483646 !important; background:#000 !important; margin:0 !important;',
        '  padding:0 !important; transform:none !important; }',
        'html.ps5t-fs .html5-video-player, html.ps5t-fs .html5-video-container { width:100% !important; height:100% !important; }',
        'html.ps5t-fs video { width:100vw !important; height:100vh !important; left:0 !important; top:0 !important; object-fit:contain !important; }',
        'html.ps5t-fs ytm-mobile-topbar-renderer, html.ps5t-fs header, html.ps5t-fs ytm-pivot-bar-renderer { display:none !important; }'
      ].join('\\n');
      var st = document.createElement('style'); st.textContent = css;
      (document.head || document.documentElement).appendChild(st);

      function post(obj){ try { window.webkit.messageHandlers.ps5tEvent.postMessage(obj); } catch(e) {} }

      // Nút toàn màn hình của YouTube -> chế độ xoay ngang của app (giữ khung dịch)
      function askFS(){ post({type:'fullscreen'}); }
      try { HTMLVideoElement.prototype.webkitEnterFullscreen = function(){ askFS(); }; } catch(e) {}
      try {
        Element.prototype.requestFullscreen = function(){ askFS(); return Promise.resolve(); };
        Element.prototype.webkitRequestFullscreen = function(){ askFS(); };
      } catch(e) {}

      function mainVideo(){
        var best = null, area = 0;
        var list = document.querySelectorAll('video');
        for (var i = 0; i < list.length; i++) {
          var r = list[i].getBoundingClientRect(), a = r.width * r.height;
          if (a > area && r.width > 40) { area = a; best = list[i]; }
        }
        return best;
      }
      function contentRect(v){
        var r = v.getBoundingClientRect(), vw = v.videoWidth, vh = v.videoHeight;
        if (!vw || !vh) return {x:r.left, y:r.top, w:r.width, h:r.height};
        var s = Math.min(r.width / vw, r.height / vh), w = vw * s, h = vh * s;
        return {x: r.left + (r.width - w) / 2, y: r.top + (r.height - h) / 2, w: w, h: h};
      }
      window.__ps5tRect = function(){ var v = mainVideo(); return v ? contentRect(v) : null; };

      // Bỏ qua quảng cáo video
      setInterval(function(){
        var v = mainVideo();
        if (v) { v.setAttribute('playsinline', ''); v.setAttribute('webkit-playsinline', ''); }
        var ad = document.querySelector('.ad-showing, .ad-interrupting');
        if (ad && v) {
          try { v.muted = true; if (isFinite(v.duration) && v.duration > 0) v.currentTime = v.duration; v.playbackRate = 16; } catch(e) {}
        } else if (v && v.playbackRate === 16) {
          try { v.playbackRate = 1; v.muted = false; } catch(e) {}
        }
        var skips = document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot button');
        for (var i = 0; i < skips.length; i++) { try { skips[i].click(); } catch(e) {} }
      }, 400);

      var lastRect = '';
      function reportRect(){
        var v = mainVideo(); if (!v) return;
        var c = contentRect(v);
        var k = [c.x, c.y, c.w, c.h].map(function(n){ return Math.round(n); }).join(',');
        if (k !== lastRect) { lastRect = k; post({type:'rect', x:c.x, y:c.y, w:c.w, h:c.h}); }
      }
      window.addEventListener('scroll', function(){ requestAnimationFrame(reportRect); }, {passive:true});
      window.addEventListener('resize', function(){ setTimeout(reportRect, 60); });
      setInterval(reportRect, 300);

      var canvas = document.createElement('canvas');
      var ctx = canvas.getContext('2d');
      window.__ps5tCapture = function(maxW){
        var v = mainVideo();
        if (!v) return {ok:false, err:'novideo'};
        var c = contentRect(v);
        var adShowing = !!document.querySelector('.ad-showing, .ad-interrupting');
        if (!v.videoWidth || v.readyState < 2) return {ok:false, err:'notready', x:c.x, y:c.y, w:c.w, h:c.h, ad:adShowing};
        var scale = Math.min(1, maxW / v.videoWidth);
        canvas.width = Math.round(v.videoWidth * scale);
        canvas.height = Math.round(v.videoHeight * scale);
        try {
          ctx.drawImage(v, 0, 0, canvas.width, canvas.height);
          var data = canvas.toDataURL('image/jpeg', 0.8);
          return {ok:true, data:data.substring(data.indexOf(',') + 1), x:c.x, y:c.y, w:c.w, h:c.h, paused:v.paused, ad:adShowing};
        } catch(e) {
          return {ok:false, err:String((e && e.name) || e), x:c.x, y:c.y, w:c.w, h:c.h, ad:adShowing};
        }
      };
      window.__ps5tFullscreen = function(on){
        document.documentElement.classList.toggle('ps5t-fs', !!on);
        window.scrollTo(0, 0);
        setTimeout(reportRect, 120); setTimeout(reportRect, 600);
      };
    })();
    """
}

// MARK: - Giao diện

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        attach(to: host)
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if webView.superview !== uiView { attach(to: uiView) }
    }

    private func attach(to host: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }
}

struct YouTubeTranslatorTab: View {
    @ObservedObject var model: YouTubeTranslatorModel
    @ObservedObject var coord: PipelineCoordinator

    private let accent = Color(red: 0.0, green: 0.44, blue: 0.82)

    var body: some View {
        let fullscreen = coord.isLandscapeFullscreen
        VStack(spacing: 0) {
            if !fullscreen { toolbar }
            ZStack(alignment: .topLeading) {
                WebViewContainer(webView: model.webView)
                if model.isTranslating {
                    subtitleOverlay
                }
                if fullscreen { fullscreenControls }
            }
            .clipped()
            if !fullscreen { statusStrip }
        }
        .background(Color.black)
        .onAppear {
            model.coordinator = coord
            model.setActive(true)
        }
        .onDisappear { model.setActive(false) }
        .onChange(of: coord.isLandscapeFullscreen) { on in
            model.setFullscreenCSS(on)
        }
    }

    private var subtitleOverlay: some View {
        let r = model.videoRect
        return ZStack(alignment: .topLeading) {
            ForEach(coord.youtubeBoxes) { box in
                TranslatedSubtitleBoxView(box: box, frameSize: r.size)
            }
        }
        .frame(width: max(1, r.width), height: max(1, r.height), alignment: .topLeading)
        .offset(x: r.minX, y: r.minY)
        .allowsHitTesting(false)
        .opacity(r.width > 40 ? 1 : 0)
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: model.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                Button(action: model.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                Button(action: model.goHome) { Image(systemName: "house.fill") }
                TextField("Tìm video hoặc dán link YouTube", text: $model.addressText, onCommit: model.loadAddress)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.webSearch)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(9)
                Button(action: model.reload) {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
            }
            .foregroundColor(.white)
            .font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.05, green: 0.10, blue: 0.22))
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.isTranslating) {
                    Label("Quét & dịch video", systemImage: "text.viewfinder")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .tint(.green)
                .fixedSize()
                Spacer()
                Button(action: { coord.isLandscapeFullscreen = true }) {
                    Label("Xoay ngang", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(accent)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
            Text(model.captureStatus + " · " + model.captureMethod)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
            Text("Chữ gốc: \(coord.youtubeSummary)")
                .font(.system(size: 11))
                .foregroundColor(.cyan)
                .lineLimit(2)
            Text("Mẹo: tắt phụ đề CC của YouTube (CC là chữ của trang web, không nằm trong hình video). Chọn video gameplay có phụ đề in sẵn trong hình.")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(10)
        .background(Color(red: 0.05, green: 0.10, blue: 0.22))
    }

    private var fullscreenControls: some View {
        HStack(spacing: 10) {
            Button(action: { coord.isLandscapeFullscreen = false }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .padding(9)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            Button(action: { model.isTranslating.toggle() }) {
                Image(systemName: model.isTranslating ? "character.bubble.fill" : "character.bubble")
                    .padding(9)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
        }
        .foregroundColor(.white.opacity(0.85))
        .padding(10)
    }
}

/// Màn hình PS5 toàn màn hình (xoay ngang): chỉ hình PS5 + khung dịch
struct PS5FullscreenView: View {
    @ObservedObject var coord: PipelineCoordinator
    @ObservedObject var videoMgr: VideoSourceManager

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let img = videoMgr.currentFullFrame {
                Image(uiImage: UIImage(cgImage: img))
                    .resizable()
                    .aspectRatio(CGFloat(img.width) / CGFloat(max(1, img.height)), contentMode: .fit)
                    .overlay(
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                ForEach(coord.translatedBoxes) { box in
                                    TranslatedSubtitleBoxView(box: box, frameSize: geo.size)
                                }
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Chưa có hình từ PS5")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button(action: { coord.isLandscapeFullscreen = false }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .foregroundColor(.white.opacity(0.85))
                    .padding(9)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .padding(10)
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
}
