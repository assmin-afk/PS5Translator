# PS5Translator
## Bản 1.19 – Giao diện mới (iOS 27: đen mờ & trắng, bo tròn) + logo MQ

- **Logo MQ** (chữ MQ ở giữa tay cầm): icon app iPhone (`icon.png`), icon app TV (`TVApp/tv_app_icon.png`),
  logo trên thanh đầu app (`app_logo.png`), file gốc vector `design/logo_mq.svg`.
- **3 tab dưới:** Trang chủ · Game (game đang chơi) · Thư viện Game. Bỏ tab Cài đặt (cài đặt TV / kết nối nằm ở nút bánh răng).
- **Bỏ "Vùng quét chữ"** (Toàn màn / Chỉ phụ đề / Nhiệm vụ) và khung căn ROI: app luôn dịch toàn màn hình.
- **Gộp "Kết nối PS5" và "Liên kết máy PS5"** thành 1 nút.
- **Log quét chữ cỡ lớn** thay dòng "Quét (0 vùng)": mỗi câu có nhãn DATA (khớp data Việt hoá), AI (dịch AI),
  RÁC (bị bỏ qua, ghi lý do), kèm bộ đếm. Xem / xuất toàn bộ ở "Lịch sử câu đã dịch".
- File mới: `12_ModernUI.swift` (theme, thanh tab, log, tab Game, cài đặt).

## Bản 1.18 – Cài app TV Samsung ngay từ iPhone, sửa kết nối và vị trí phụ đề trên TV

- **Cài app TV không cần máy tính** (`11_TVInstaller.swift`, mã nguồn app TV ở thư mục `TVApp/`):
  Thư viện game → TV Samsung → "Cài / cập nhật app lên TV Samsung".
  iPhone tự nói chuyện với TV qua SDB (cổng 26101), đăng nhập tài khoản Samsung, xin chứng chỉ cho đúng DUID của TV,
  ký gói .wgt, cài và mở app. IP Wi-Fi của iPhone được ghi sẵn vào app TV.
  TV cần: Developer Mode ON, Host PC IP = IP iPhone, tắt hẳn rồi bật lại TV.
  Chứng chỉ + khoá ký được lưu trong Keychain để lần sau cập nhật không bị lỗi "author mismatch".
- **Kết nối iPhone ↔ TV:** iPhone gửi "hello" + phụ đề cuối khi TV kết nối, "ping" mỗi 3 giây, tự khởi động lại máy chủ khi mạng đổi.
  App TV hết lỗi tự ngắt–nối lại mỗi 3 giây, nhập được IP bằng remote, tự quét mạng tìm iPhone khi sai IP.
- **Vị trí phụ đề trên TV khớp iPhone:** TV vẽ theo `boxes` (toạ độ 0..1, cỡ chữ, màu, căn giữa/neo đáy) bằng đúng công thức của iPhone.

## Bản 1.11 – Quét chữ thông minh

File mới: `7_SmartSubtitleEngine.swift`

- **Lọc chữ rác:**
  - OCR dùng chế độ chính xác (`.accurate`) và nhận cả tiếng Việt; chữ đã là tiếng Việt (ví dụ giao diện PS5) thì bỏ qua.
  - Bỏ ký tự lạ, từ trộn chữ với số hoặc hoa/thường lộn xộn, số liệu HUD, chữ đơn lẻ vô nghĩa, và từ game cơ bản (OK, BACK, HP...).
  - Dòng chữ chỉ được nhận nếu đa số từ trong đó là từ tiếng Anh thật (kiểm tra bằng UITextChecker).
- **Khung dịch ổn định:** mỗi khung có ID cố định. Vị trí chỉ đổi khi chữ gốc thật sự di chuyển. Chữ có độ tin cậy thấp phải xuất hiện ở 2–3 lần quét mới được hiện. Khung ẩn ngay khi chữ gốc biến mất.
- **Kiểu chữ khớp chữ gốc:** cỡ chữ tính theo chiều cao dòng gốc. Màu chữ và màu nền lấy từ chính khung hình (tách bằng ngưỡng Otsu). Thoại nhân vật luôn màu vàng.
- **Bố cục:** khung neo ở góc trái-trên của chữ gốc, kéo dài sang phải, tự xuống dòng, tự thu nhỏ chữ để không đè lên khung khác.
- **Nút bấm tay cầm:** câu được tách ra quanh L1/R2/✕/○/△/□ và quanh khoảng trống có icon nút, nên khung dịch không che nút.
- **Tên riêng:** tên có sẵn trong danh sách, cộng với bảng `glossary` trong data, được giữ nguyên. Khi dịch AI, tên riêng được thay bằng mã giữ chỗ trước khi gửi đi.
- **Người nói:** nhận ra `[Ashley]`, kể cả khi OCR đọc thành `IAshleyl`. Tên người nói được giữ nguyên, chỉ phần lời thoại được dịch.

### Data Việt hoá
Chạy `python tools/vietsub_db_tool.py check <file.sqlite>` để kiểm tra một file data.
Để tạo data chuẩn, dùng `build` (từ CSV, hoặc TXT dạng `Anh ||| Việt`) hoặc `build-parallel` (từ 2 file Anh và Việt có thứ tự dòng khớp nhau).

## Bản 1.12 – Tab Dịch YouTube, xoay ngang, Apple Intelligence, Thư viện game

- **Tab "Dịch YouTube"** (`8_YouTubeTranslator.swift`)
  - Mở m.youtube.com ngay trong app.
  - Chặn các tên miền quảng cáo, tự bỏ qua quảng cáo video và ẩn khung quảng cáo.
  - Dùng chung bộ máy quét chữ với màn hình PS5.
  - Khung hình được lấy từ thẻ `<video>` bằng canvas. Nếu bị chặn, app chuyển sang chụp ảnh trình duyệt. Thanh trạng thái cho biết đang dùng cách nào.
- **Xoay ngang toàn màn hình** cho cả YouTube và PS5.
  - Nút toàn màn hình của YouTube được chuyển thành chế độ xoay ngang của app, nên khung dịch vẫn hiện.
- **Apple Intelligence** (`10_AppleIntelligenceTranslator.swift`)
  - Dịch trên iPhone bằng Foundation Models (cần iOS 26, máy hỗ trợ Apple Intelligence, và đã bật Apple Intelligence).
  - Có ngữ cảnh: tên game, loại chữ, người nói, 3 câu thoại trước đó, tên riêng cần giữ nguyên.
  - Chọn bộ dịch trong Thư viện game: Apple → Google / chỉ Apple / chỉ Google / chỉ data.
- **Thư viện game** (`9_GameLibraryView.swift`)
  - Thẻ game đang chơi và lưới danh sách game.
  - "Thêm game mới": nhập tên và chọn file data trong cùng một màn hình.
  - Nhập được .sqlite / .db / .csv / .tsv / .txt (dạng Anh ||| Việt).
- **Workflow**: tự chọn Xcode mới nhất; weak-link FoundationModels để app vẫn chạy trên iOS < 26.

## Bản 1.13 – Ghép data theo đoạn câu, chống chớp tắt, nền đen

- **Ghép data:** game (ví dụ Until Dawn) chia một câu dài thành nhiều đoạn hiện lần lượt. App giờ tìm câu trong data chứa liền mạch đoạn đang hiện, và ưu tiên câu vừa khớp cùng các câu kế tiếp theo thứ tự kịch bản.
  - Đoạn tiếp theo của cùng một câu dùng lại đúng khung cũ, nên khung không chớp.
  - Khi data giữ đúng thứ tự kịch bản, khâu ghép đoạn chạy tốt nhất. Hãy tạo data từ `until_dawn_full_report.csv`, đừng dùng bản đã sắp xếp theo ABC.
- **Thời gian giữ chữ:** câu lấy từ data giữ thêm 0,35 giây sau khi chữ gốc biến mất. Câu dịch AI giữ 1,6–4,5 giây tuỳ độ dài. Câu mới hiện ở cùng chỗ sẽ thay ngay.
- **Cỡ chữ thoại cố định:** lấy trung vị nhiều lần đo, chỉ đổi khi khác trên 12%. Lời thoại căn giữa, đáy khung cố định. Cỡ chữ của menu được khoá theo từng khung.
- **Kiểu khung:** nền đen cho mọi khung dịch, chữ đậm.
- **Tên người nói và lựa chọn:**
  - "(Dr. Hill)   Interesting." không còn bị cắt đôi; các dòng cùng hàng được gộp lại.
  - Lựa chọn câu trả lời ngắn (1–4 từ hợp lệ) không còn bị coi là chữ rác.
  - Chữ có trong data luôn được chấp nhận.
- **Dòng "Chữ gốc"** ghi rõ nguồn dịch của từng câu: 📗Data / 🤖AI / ⏳AI (đang chờ) / ✗ (không dịch được).

## Bản 1.14 – Dịch từng câu, cố định cỡ chữ, sửa AI cho lựa chọn

- **Dịch từng câu:** mỗi dòng data (nhiều khi là cả một đoạn văn) được tách thành từng câu Anh và câu Việt, rồi ghép cặp theo độ dài (kiểu Gale-Church). Khi game hiện đoạn nào, app chỉ hiện đúng câu Việt của đoạn đó, ẩn và hiện cùng câu gốc.
  - Chạy thử trên 13 đoạn phụ đề lấy từ video: cả 13 đều ra đúng câu.
- **Cỡ chữ cố định:**
  - Cỡ chữ thoại chỉ đổi khi phụ đề game đổi cỡ trên 25%.
  - SwiftUI không còn tự thu nhỏ chữ (đã bỏ `minimumScaleFactor`). Nếu chữ dài hơn dự tính, khung tự giãn thêm dòng.
  - Khung thoại neo đáy và căn giữa; khung menu/lựa chọn neo góc trái-trên.
- **Lựa chọn câu trả lời:**
  - Bản dịch AI được giao đúng về khung đã gửi, kể cả khi OCR đọc chữ hơi khác ở lần quét sau. Đây chính là lỗi khiến "IT MAKES ME HAPPY" không được dịch.
  - Icon nút bị OCR đọc lệch (`[12]`, `(2)`, `(r2)`…) được nhận là nút bấm; khung dịch không che lên các icon này.
  - Chữ IN HOA được gửi AI dưới dạng câu thường, rồi bản dịch được in hoa lại.
  - Nếu Apple Intelligence chưa trả kết quả sau 1,2 giây, app gửi Google song song; bản nào về trước thì hiện.
- Data Until Dawn hiện có: các lựa chọn câu trả lời chỉ có tiếng Việt, thiếu tiếng Anh, nên luôn được dịch bằng AI.

## Bản 1.15 – Bộ dịch "Dùng chung tất cả"
- Chế độ mặc định mới: **Data Việt hoá → Apple Intelligence → Google Dịch**.
  - Câu có trong data thì lấy từ data.
  - Câu không có trong data thì dịch bằng Apple Intelligence trên iPhone.
  - Nếu Apple Intelligence không dịch được, quá 1,2 giây chưa trả kết quả, hoặc máy không có Apple Intelligence, thì dùng Google Dịch.
- Cả 4 chế độ đều ưu tiên data trước. Chế độ "Chỉ data Việt hoá" ghi rõ là lựa chọn và câu thiếu trong data sẽ KHÔNG được dịch.
- Lựa chọn bộ dịch cũ được đặt lại về "Dùng chung tất cả" khi cập nhật lên bản này.

## Bản 1.16 – Không dịch chữ trên vật phẩm, chữ to, tên riêng; đọc chữ nhỏ nhanh hơn
- **Chữ dính vào vật thể trong game** (lá thư, biển báo, chữ viết tay): bị bỏ qua khi
  1. dòng chữ nghiêng quá 3° hoặc méo phối cảnh (cạnh trái lệch quá 22% chiều cao chữ), hoặc
  2. chữ di chuyển theo máy quay ở phần lớn các lần quét.
  Chữ giao diện (bảng chữ bên phải, phụ đề, lựa chọn) thì thẳng và đứng yên, nên vẫn được dịch.
- **Chữ to** (cao trên 50px ở thang 720, ví dụ "SAM", "MEMENTO MORI"): không dịch, để không che màn hình game.
- **Dòng chỉ gồm tên riêng** ("SAM", "Dr. Hill"): không dịch. Tên có đuôi sở hữu ("HANNAH'S") vẫn được nhận là tên riêng và giữ nguyên ("BẠN THÂN NHẤT CỦA HANNAH").
- **Chữ IN HOA không có người nói** ("TEN HOURS UNTIL DAWN") không còn bị coi là lời thoại, nên khung dịch nằm đúng chỗ chữ gốc ngay từ lần đầu.
- **Đọc chữ nhỏ** (nhãn địa điểm khoảng 10px): ngưỡng `minimumTextHeight` của Vision hạ từ 0.018 xuống 0.011, nên những chữ này được đọc ngay thay vì phải chờ vài giây.

## Bản 1.17 – Không dịch chữ trên giấy / thư / biển báo
- **Mực tối trên nền sáng:** chữ trên giấy, thư, biển báo luôn tối hơn mặt giấy. Chữ giao diện game (phụ đề, bảng chữ bên phải, lựa chọn) thì sáng hơn nền.
  - App so sánh tương đối (mực tối hơn nền ít nhất 1,5 lần), nên vẫn đúng ở cảnh đêm, khi tờ giấy rất tối.
  - Vùng quanh khối chữ cũng phải là mặt giấy (phần mực tối chiếm thiểu số).
- **Cùng nội dung xuất hiện 2 lần** (tờ thư cùng bảng chữ giao diện): app chỉ dịch bản chữ sáng.
- Lời thoại có người nói và phụ đề luôn được dịch, để phụ đề trên nền tuyết trắng không bị bỏ nhầm.
- Công tắc trong Thư viện game: "Không dịch chữ trên giấy, thư, biển báo" (mặc định bật). Tắt đi nếu game có menu chữ đen trên nền trắng.
- Kết hợp với bộ lọc của bản 1.16 (chữ nghiêng/méo và chữ trôi theo máy quay).
