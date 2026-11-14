// PS5 Translator TV 1.0.19
// - Nhận phụ đề từ app iPhone qua WebSocket (cổng 8080) và vẽ đè lên hình HDMI của PS5.
// - Vị trí / cỡ chữ / màu lấy từ "boxes" (toạ độ 0..1 của khung video 16:9 trên iPhone),
//   vẽ theo đúng cách iPhone vẽ: thoại neo ĐÁY + căn giữa, menu neo GÓC TRÁI-TRÊN.
// - Tự kết nối lại, tự tìm iPhone trong mạng nếu sai IP, nhập IP bằng remote.
(function () {
    'use strict';

    var PORT = 8080;
    var STORAGE_IP_KEY = 'ps5_translator_iphone_ip';
    var STORAGE_HDMI_KEY = 'ps5_translator_hdmi_port';
    var STORAGE_BUILD_IP_KEY = 'ps5_translator_build_ip';
    // App iPhone tự ghi IP của iPhone vào dòng dưới khi cài app TV trực tiếp từ iPhone.
    var BUILD_IP = "192.168.2.74"; // @@IPHONE_IP@@

    var ws = null;
    var connected = false;          // đã nhận gói "hello" (hoặc phụ đề) từ iPhone
    var currentIp = '';
    var lastMessageAt = 0;
    var reconnectTimer = null;
    var failingSince = 0;
    var lastScanAt = 0;
    var scanning = false;
    var statusTimeout = null;
    var focusIndex = 0;
    var slots = {};                 // id khung -> phần tử DOM (dùng lại để không chớp)

    function $(id) { return document.getElementById(id); }
    function now() { return new Date().getTime(); }
    function isValidIp(ip) {
        return /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.test(ip) &&
            ip.split('.').every(function (p) { return +p >= 0 && +p <= 255; });
    }
    function store(key, value) { try { localStorage.setItem(key, value); } catch (e) {} }
    function load(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }

    // ------------------------------------------------------------------ khởi động
    window.addEventListener('load', function () {
        document.documentElement.style.background = 'transparent';
        document.body.style.background = 'transparent';

        // IP do iPhone ghi vào lúc cài mới nhất được ưu tiên hơn IP cũ đã lưu.
        if (isValidIp(BUILD_IP) && load(STORAGE_BUILD_IP_KEY) !== BUILD_IP) {
            store(STORAGE_BUILD_IP_KEY, BUILD_IP);
            store(STORAGE_IP_KEY, BUILD_IP);
        }
        var savedIp = load(STORAGE_IP_KEY);
        if (!isValidIp(savedIp || '')) savedIp = isValidIp(BUILD_IP) ? BUILD_IP : '';
        var savedHdmi = load(STORAGE_HDMI_KEY) || 'HDMI 2';

        $('ip-input').value = savedIp;
        $('hdmi-select').value = savedHdmi;
        setFocus(0);

        $('hdmi-select').addEventListener('change', function () {
            store(STORAGE_HDMI_KEY, $('hdmi-select').value);
            launchTvWindow($('hdmi-select').value);
        });
        $('ip-input').addEventListener('keydown', onIpInputKey);
        $('ip-input').addEventListener('blur', function () { commitIpInput(false); });

        launchTvWindow(savedHdmi);
        if (savedIp) connectWebSocket(savedIp); else startScan();

        setInterval(watchdog, 2000);
        document.addEventListener('keydown', onKey);
    });

    // ------------------------------------------------------------------ remote TV
    var focusables = ['hdmi-select', 'ip-input', 'scan-btn'];

    function panelVisible() { return $('setup-panel').style.display !== 'none'; }
    function showPanel(show) {
        $('setup-panel').style.display = show ? 'block' : 'none';
        $('status-bar').style.display = show ? 'block' : 'none';
        if (show) setFocus(0); else if (document.activeElement) document.activeElement.blur();
    }
    function setFocus(i) {
        focusIndex = (i + focusables.length) % focusables.length;
        for (var k = 0; k < focusables.length; k++) {
            $(focusables[k]).className = $(focusables[k]).className.replace(/\s*focused/g, '') + (k === focusIndex ? ' focused' : '');
        }
        if (focusables[focusIndex] === 'hdmi-select') $('hdmi-select').focus();
        else if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    }

    function onKey(e) {
        var code = e.keyCode;
        if (document.activeElement === $('ip-input')) return; // đang gõ IP: để bàn phím TV xử lý
        if (!panelVisible()) {
            if (code === 38) { showPanel(true); e.preventDefault(); }
            else if (code === 10009) { exitApp(); }
            return;
        }
        if (code === 38) {                       // Lên
            if (focusIndex === 0) showPanel(false); else setFocus(focusIndex - 1);
            e.preventDefault();
        } else if (code === 40) {                // Xuống
            setFocus(focusIndex + 1);
            e.preventDefault();
        } else if ((code === 37 || code === 39) && focusIndex === 0) { // Trái/Phải đổi HDMI
            var sel = $('hdmi-select');
            var n = sel.options.length;
            sel.selectedIndex = (sel.selectedIndex + (code === 39 ? 1 : n - 1)) % n;
            var ev = document.createEvent('HTMLEvents');
            ev.initEvent('change', true, false);
            sel.dispatchEvent(ev);
            e.preventDefault();
        } else if (code === 13) {                // OK
            if (focusables[focusIndex] === 'ip-input') { $('ip-input').focus(); }
            else if (focusables[focusIndex] === 'scan-btn') { startScan(true); }
            e.preventDefault();
        } else if (code === 10009) {             // Return: ẩn bảng
            showPanel(false);
        }
    }

    function onIpInputKey(e) {
        // 13 Enter, 65376 Done (bàn phím Tizen), 65385 Cancel, 10009 Return
        if (e.keyCode === 13 || e.keyCode === 65376) { commitIpInput(true); e.preventDefault(); }
        else if (e.keyCode === 65385 || e.keyCode === 10009) { $('ip-input').value = currentIp; $('ip-input').blur(); setFocus(1); e.preventDefault(); }
    }

    function commitIpInput(fromKey) {
        var ip = ($('ip-input').value || '').replace(/[^0-9.]/g, '');
        if (fromKey) { $('ip-input').blur(); setFocus(1); }
        if (!isValidIp(ip)) { if (fromKey) updateStatus('IP không hợp lệ: ' + ip, 'error'); return; }
        if (ip === currentIp && (connected || ws)) return;
        store(STORAGE_IP_KEY, ip);
        connectWebSocket(ip);
    }

    function exitApp() {
        try { tizen.application.getCurrentApplication().exit(); } catch (e) {}
    }

    // ------------------------------------------------------------------ HDMI phía sau
    function parseHdmiNumber(str) {
        var m = String(str).match(/\d+/);
        return m ? parseInt(m[0], 10) : 2;
    }

    function launchTvWindow(hdmiPort) {
        if (typeof tizen === 'undefined' || !tizen.tvwindow) {
            updateStatus('Không có tizen.tvwindow (đang chạy trên PC?)', 'error');
            return;
        }
        var port = parseHdmiNumber(hdmiPort);
        updateStatus('Đang chuyển sang HDMI ' + port + '...', 'connecting');
        function setAndShow(source) {
            tizen.tvwindow.setSource(source,
                function () { showBehindWindow(port); },
                function () { showBehindWindow(port); },
                'MAIN');
        }
        try {
            if (tizen.systeminfo) {
                tizen.systeminfo.getPropertyValue('VIDEOSOURCE', function (vs) {
                    var all = (vs.connected || []).concat(vs.disconnected || []);
                    var match = null;
                    for (var i = 0; i < all.length; i++) {
                        if (all[i].type === 'HDMI' && all[i].number === port) { match = all[i]; break; }
                    }
                    setAndShow(match || { type: 'HDMI', number: port });
                }, function () { showBehindWindow(port); });
            } else {
                showBehindWindow(port);
            }
        } catch (e) {
            updateStatus('Lỗi HDMI: ' + e.message, 'error');
        }
    }

    function showBehindWindow(port) {
        function ok() { updateStatus('Đã hiển thị HDMI ' + port, 'connected', connected); }
        try {
            tizen.tvwindow.show(ok, function () {
                tizen.tvwindow.show(ok, function (err) { updateStatus('Lỗi show: ' + err.message, 'error'); },
                    ['0px', '0px', window.screen.width + 'px', window.screen.height + 'px'], 'MAIN', 'BEHIND');
            }, ['0%', '0%', '100%', '100%'], 'MAIN', 'BEHIND');
        } catch (e) {
            updateStatus('Lỗi gọi show: ' + e.message, 'error');
        }
    }

    // ------------------------------------------------------------------ WebSocket
    function closeSocket() {
        if (!ws) return;
        var old = ws;
        ws = null;
        old.onopen = old.onclose = old.onerror = old.onmessage = null;
        try { old.close(); } catch (e) {}
    }

    function scheduleReconnect(delay) {
        if (reconnectTimer) return;
        reconnectTimer = setTimeout(function () {
            reconnectTimer = null;
            connectWebSocket(load(STORAGE_IP_KEY) || currentIp);
        }, delay);
    }

    function setConnected(value) {
        if (connected === value) return;
        connected = value;
        if (value) {
            failingSince = 0;
            $('ip-display').innerText = 'Đã kết nối ' + currentIp;
            $('ip-display').style.color = '#76ff03';
            updateStatus('Đã kết nối iPhone ' + currentIp, 'connected', true);
        } else {
            if (!failingSince) failingSince = now();
            clearSubtitles();
            $('ip-display').innerText = 'Mất kết nối ' + currentIp + ' — đang thử lại';
            $('ip-display').style.color = '#ff5252';
        }
    }

    function connectWebSocket(ip) {
        if (!isValidIp(ip || '')) return;
        if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
        closeSocket();
        currentIp = ip;
        $('ip-input').value = ip;
        if (!connected) {
            $('ip-display').innerText = 'Đang kết nối ' + ip + ':' + PORT + '...';
            $('ip-display').style.color = 'yellow';
        }
        var socket;
        try { socket = new WebSocket('ws://' + ip + ':' + PORT); } catch (e) { scheduleReconnect(3000); return; }
        ws = socket;
        lastMessageAt = now();
        socket.onmessage = function (event) {
            lastMessageAt = now();
            var data;
            try { data = JSON.parse(event.data); } catch (e) { return; }
            setConnected(true);
            if (data && (data.status === 'hello' || data.status === 'ping')) return;
            renderSubtitles(data);
        };
        socket.onclose = socket.onerror = function () {
            if (ws !== socket) return;
            closeSocket();
            setConnected(false);
            if (!failingSince) failingSince = now();
            scheduleReconnect(3000);
        };
    }

    // iPhone gửi "ping" mỗi 3 giây: im lặng quá 10 giây = mất kết nối (Wi-Fi rớt, iPhone khoá màn hình...)
    function watchdog() {
        if (ws && now() - lastMessageAt > 10000) {
            closeSocket();
            setConnected(false);
            scheduleReconnect(500);
        }
        // Sai IP quá 15 giây -> tự quét mạng tìm iPhone (tối đa mỗi 60 giây một lần)
        if (!connected && failingSince && now() - failingSince > 15000 && now() - lastScanAt > 60000) {
            startScan(false);
        }
    }

    // ------------------------------------------------------------------ tự tìm iPhone
    function getTvSubnets(done) {
        var prefixes = [];
        function add(ip) {
            if (ip && isValidIp(ip)) {
                var p = ip.split('.').slice(0, 3).join('.');
                if (prefixes.indexOf(p) < 0) prefixes.push(p);
            }
        }
        var pending = 0;
        function finish() { if (--pending <= 0) { add(currentIp); add(BUILD_IP); done(prefixes); } }
        if (typeof tizen !== 'undefined' && tizen.systeminfo) {
            ['WIFI_NETWORK', 'ETHERNET_NETWORK'].forEach(function (prop) {
                pending++;
                try {
                    tizen.systeminfo.getPropertyValue(prop, function (info) { add(info && info.ipAddress); finish(); }, finish);
                } catch (e) { finish(); }
            });
        }
        if (!pending) { pending = 1; finish(); }
    }

    function probe(ip, timeoutMs, cb) {
        var done = false, s;
        function finish(ok) {
            if (done) return; done = true;
            clearTimeout(t);
            if (s) { s.onopen = s.onmessage = s.onerror = s.onclose = null; try { s.close(); } catch (e) {} }
            cb(ok ? ip : null);
        }
        var t = setTimeout(function () { finish(false); }, timeoutMs);
        try { s = new WebSocket('ws://' + ip + ':' + PORT); } catch (e) { finish(false); return; }
        s.onmessage = function (ev) {
            try { var d = JSON.parse(ev.data); finish(!!(d && (d.app === 'PS5Translator' || d.status))); } catch (e) { finish(false); }
        };
        s.onerror = s.onclose = function () { finish(false); };
    }

    function startScan(manual) {
        if (scanning) return;
        scanning = true;
        lastScanAt = now();
        updateStatus('Đang tìm iPhone trong mạng Wi-Fi...', 'connecting');
        getTvSubnets(function (prefixes) {
            var targets = [];
            prefixes.forEach(function (p) { for (var i = 1; i < 255; i++) targets.push(p + '.' + i); });
            var index = 0, active = 0, found = null, BATCH = 24;
            function next() {
                if (found) return;
                while (active < BATCH && index < targets.length) {
                    active++;
                    probe(targets[index++], 1800, function (ip) {
                        active--;
                        if (ip && !found) {
                            found = ip;
                            scanning = false;
                            store(STORAGE_IP_KEY, ip);
                            updateStatus('Tìm thấy iPhone: ' + ip, 'connected');
                            connectWebSocket(ip);
                            return;
                        }
                        if (!found && index >= targets.length && active === 0) {
                            scanning = false;
                            updateStatus('Không tìm thấy iPhone. Mở app iPhone, cùng Wi-Fi với TV rồi thử lại.', 'error');
                            if (manual) showPanel(true);
                            return;
                        }
                        next();
                    });
                }
            }
            if (!targets.length) { scanning = false; updateStatus('Không đọc được mạng của TV', 'error'); return; }
            next();
        });
    }

    // ------------------------------------------------------------------ vẽ phụ đề
    function num(v, fallback) {
        v = Number(v);
        if (!isFinite(v)) return fallback;
        return v > 1.0001 ? v / 100 : v;     // gói cũ "texts" dùng %, "boxes" dùng 0..1
    }

    function normalize(data) {
        if (!data) return [];
        if (data.boxes && data.boxes.length) {
            return data.boxes.map(function (b, i) {
                return {
                    id: b.stableID || b.id || (b.text + '_' + i),
                    text: b.text || '',
                    x: num(b.x, 0), y: num(b.y, 0), w: num(b.w, 0.8), h: num(b.h, 0.1),
                    fontSizeNorm: Number(b.fontSizeNorm) || 0,
                    color: /^#?[0-9a-fA-F]{6}$/.test(b.textColorHex || '') ? '#' + b.textColorHex.replace('#', '') : '#ffffff',
                    bold: b.isBold !== false,
                    center: !!b.textAlignCenter
                };
            });
        }
        if (data.texts && data.texts.length) {
            return data.texts.map(function (t, i) {
                return {
                    id: 't' + i + '_' + t.text,
                    text: t.text || '',
                    x: num(t.x, 0.1), y: num(t.y, 0.8), w: num(t.width, 0.8), h: num(t.height, 0.1),
                    fontSizeNorm: 0, color: '#ffff00', bold: true, center: true
                };
            });
        }
        return [];
    }

    function renderSubtitles(data) {
        var container = $('overlay-container');
        var H = container.clientHeight || window.innerHeight || 1080;
        var items = normalize(data);
        var keep = {};

        items.forEach(function (b) {
            if (!b.text) return;
            keep[b.id] = true;
            var slot = slots[b.id];
            if (!slot) {
                slot = document.createElement('div');
                slot.className = 'sub-slot';
                var bubble = document.createElement('div');
                bubble.className = 'sub-bubble';
                slot.appendChild(bubble);
                container.appendChild(slot);
                slots[b.id] = slot;
            }
            var bubbleEl = slot.firstChild;
            // Giống TranslatedSubtitleBoxView trên iPhone (cùng công thức, đổi sang pixel TV)
            var fontPx = b.fontSizeNorm > 0 ? b.fontSizeNorm * H : Math.max(0.028, Math.min(0.06, b.h * 0.78)) * H;
            var padX = fontPx * (b.center ? 0.35 : 0.32);
            var padY = fontPx * (b.center ? 0.18 : 0.14);

            slot.style.left = (b.x * 100) + '%';
            slot.style.top = (b.y * 100) + '%';
            slot.style.width = (b.w * 100) + '%';
            slot.style.height = (b.h * 100) + '%';

            bubbleEl.style.fontSize = fontPx.toFixed(1) + 'px';
            bubbleEl.style.padding = padY.toFixed(1) + 'px ' + padX.toFixed(1) + 'px';
            bubbleEl.style.borderRadius = Math.max(3, fontPx * 0.22).toFixed(1) + 'px';
            bubbleEl.style.color = b.color;
            bubbleEl.style.fontWeight = b.bold ? 'bold' : 'normal';
            bubbleEl.style.textAlign = b.center ? 'center' : 'left';
            // Thoại: neo đáy khung + căn giữa. Menu/lựa chọn: neo góc trái-trên. Dài hơn thì giãn thêm dòng.
            bubbleEl.style.top = b.center ? 'auto' : '0';
            bubbleEl.style.bottom = b.center ? '0' : 'auto';
            bubbleEl.style.left = '0';
            if (bubbleEl.textContent !== b.text) bubbleEl.textContent = b.text;
        });

        for (var id in slots) {
            if (slots.hasOwnProperty(id) && !keep[id]) {
                if (slots[id].parentNode) slots[id].parentNode.removeChild(slots[id]);
                delete slots[id];
            }
        }
    }

    function clearSubtitles() { renderSubtitles({ boxes: [] }); }

    // ------------------------------------------------------------------ dòng trạng thái
    function updateStatus(message, type, autoHide) {
        var el = $('status-bar');
        if (statusTimeout) { clearTimeout(statusTimeout); statusTimeout = null; }
        el.style.display = 'block';
        el.innerText = message;
        el.style.color = type === 'connected' ? '#76ff03' : type === 'error' ? '#ff5252' : 'yellow';
        if (autoHide) {
            statusTimeout = setTimeout(function () { showPanel(false); }, 2000);
        }
    }

    // Cho phép kiểm thử ngoài TV (node / trình duyệt PC)
    window.__ps5tv = { normalize: normalize, renderSubtitles: renderSubtitles, isValidIp: isValidIp };
})();
