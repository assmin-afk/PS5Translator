#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vietsub_db_tool.py - Kiểm tra và tạo data Việt hoá chuẩn cho PS5Translator 1.11

CÁCH DÙNG (chạy trên máy tính có Python 3):

  1) Kiểm tra 1 file data có dùng được không:
       python vietsub_db_tool.py check "until dawn viet hoa.sqlite"

  2) Tạo data chuẩn từ file CSV/TSV có 2 cột tiếng Anh + tiếng Việt
     (dòng đầu là tên cột, ví dụ: en,vi  hoặc  english,vietnamese  hoặc  key,en,vi):
       python vietsub_db_tool.py build cau_thoai.csv "Until Dawn.sqlite"

  3) Tạo data từ 2 file văn bản song song (dòng N của file Anh = dòng N của file Việt).
     Đây là cách phổ biến khi trích xuất từ file ngôn ngữ của game gốc và bản Việt hoá:
       python vietsub_db_tool.py build-parallel english.txt vietnamese.txt "Until Dawn.sqlite"

  4) Tạo data từ file .txt dạng   Câu tiếng Anh ||| Câu tiếng Việt   (mỗi dòng 1 cặp):
       python vietsub_db_tool.py build cau_thoai.txt "Until Dawn.sqlite"

  Tuỳ chọn:  --names ten_rieng.txt   (mỗi dòng 1 tên riêng KHÔNG dịch: Sam, Blackwood...)

CẤU TRÚC DATA CHUẨN (app đọc được nhanh nhất):
  translations_v2(id, en, vi, en_norm, speaker, category, string_key)
      en       : câu tiếng Anh GỐC đúng như trong game
      vi       : câu tiếng Việt TƯƠNG ỨNG (không được giống hệt en)
      en_norm  : en đã chuẩn hoá (chữ thường, bỏ thẻ <Italic>, bỏ dấu câu) - để tra cứu
      speaker  : tên nhân vật nói (nếu có)
      category : dialogue / menu / quest / item / tutorial ...
      string_key: mã chuỗi gốc trong file game (nếu có) - giúp ghép cặp chính xác
  glossary(term, vi, keep_original, kind)  - tên riêng / thuật ngữ
  meta(key, value)                          - thông tin phiên bản
"""
import csv
import re
import sqlite3
import sys
import unicodedata
from collections import Counter

# ---------------------------------------------------------------------------
# Chuẩn hoá: PHẢI GIỐNG TranslationMemory.normalize() trong 7_SmartSubtitleEngine.swift
# ---------------------------------------------------------------------------
RE_SPEAKER = re.compile(r"^\s*\[[^\]]{1,24}\]\s*")
RE_BREAK = re.compile(r"<\s*(cr|br)\s*/?>", re.I)
RE_TAG = re.compile(r"<[^>]*>")
RE_PLACEHOLDER = re.compile(r"\{\d+\}")
VI_MARKS = re.compile("[àáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ]", re.I)


def normalize(text: str) -> str:
    s = unicodedata.normalize("NFC", text or "")
    s = RE_SPEAKER.sub("", s)
    s = RE_BREAK.sub(" ", s)
    s = RE_TAG.sub("", s)
    s = RE_PLACEHOLDER.sub(" ", s)
    s = s.lower()
    for ch in "’‘`´":
        s = s.replace(ch, "'")
    s = s.replace("'", "")
    s = "".join(c if c.isalnum() else " " for c in s)
    return " ".join(s.split())


def speaker_of(text: str):
    m = RE_SPEAKER.match(text or "")
    return m.group(0).strip()[1:-1].strip() if m else None


def has_vi(text: str) -> bool:
    return bool(VI_MARKS.search(text or ""))


# ---------------------------------------------------------------------------
EN_ALIASES = ["en", "english", "en_raw", "original_text", "original", "source", "source_text", "text_raw", "text_en"]
VI_ALIASES = ["vi", "vietnamese", "vi_text", "translated_text", "translation", "target", "target_text", "text_vi"]


def detect(conn):
    tables = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'")]
    skip = ("_data", "_idx", "_content", "_docsize", "_config")
    preferred = ["translations_v2", "translations", "subtitles", "subtitles_fts"]
    ordered = [t for t in preferred if t in tables] + [t for t in tables if t not in preferred]
    for t in ordered:
        if t.endswith(skip) or t in ("glossary", "meta"):
            continue
        cols = [r[1].lower() for r in conn.execute(f'PRAGMA table_info("{t}")')]
        en = next((c for c in EN_ALIASES if c in cols), None)
        vi = next((c for c in VI_ALIASES if c in cols), None)
        if en and vi:
            return t, en, vi, tables
    return None, None, None, tables


def cmd_check(path):
    conn = sqlite3.connect(path)
    table, en_col, vi_col, tables = detect(conn)
    print(f"File: {path}")
    print(f"Bảng có trong file: {', '.join(tables)}")
    if not table:
        print("❌ Không tìm thấy bảng nào có cột tiếng Anh + cột tiếng Việt.")
        return 1
    print(f"Bảng được dùng: {table}  (cột Anh = {en_col}, cột Việt = {vi_col})")
    rows = conn.execute(f'SELECT "{en_col}", "{vi_col}" FROM "{table}"').fetchall()
    total = len(rows)
    valid, identical, empty, swapped = [], 0, 0, 0
    en_lang = Counter()
    for en, vi in rows:
        if not en or not vi:
            empty += 1
            continue
        en_lang["vi" if has_vi(en) else "en"] += 1
        if normalize(en) == normalize(vi):
            identical += 1
            continue
        if has_vi(en) and not has_vi(vi):
            swapped += 1
            continue
        valid.append((en, vi))
    norms = Counter(normalize(en) for en, _ in valid)
    dup = sum(c - 1 for c in norms.values() if c > 1)
    tags = sum(1 for en, _ in rows if en and "<" in en)
    vi_ok = sum(1 for _, vi in valid if has_vi(vi))

    print(f"\nTổng số dòng                     : {total}")
    print(f"Cột 'Anh' thực chất là tiếng Anh : {en_lang['en']}")
    print(f"Cột 'Anh' thực chất là tiếng Việt: {en_lang['vi']}")
    print(f"Dòng có bản dịch GIỐNG HỆT câu gốc: {identical}")
    print(f"Dòng trống                        : {empty}")
    print(f"Dòng bị đảo cột (Việt ở cột Anh)  : {swapped}")
    print(f"Câu gốc chứa thẻ <Italic>/<cr>    : {tags}")
    print(f"➡️  CẶP ANH→VIỆT DÙNG ĐƯỢC        : {len(valid)}  (trong đó {vi_ok} câu Việt có dấu, {dup} câu gốc trùng)")
    if valid:
        print("\nVí dụ cặp hợp lệ:")
        for en, vi in valid[:5]:
            print(f"  EN: {en[:90]}\n  VI: {vi[:90]}")
    if len(valid) < total * 0.5:
        print("\n❌ KẾT LUẬN: data KHÔNG đạt chuẩn để dịch. Xem hướng sửa trong phần đầu file này"
              " (build / build-parallel).")
        return 1
    print("\n✅ KẾT LUẬN: data dùng được.")
    return 0


def create_db(out_path, pairs, names):
    conn = sqlite3.connect(out_path)
    c = conn.cursor()
    c.executescript("""
        DROP TABLE IF EXISTS translations_v2;
        DROP TABLE IF EXISTS glossary;
        DROP TABLE IF EXISTS meta;
        CREATE TABLE translations_v2(
            id INTEGER PRIMARY KEY,
            en TEXT NOT NULL,
            vi TEXT NOT NULL,
            en_norm TEXT NOT NULL,
            speaker TEXT,
            category TEXT,
            string_key TEXT
        );
        CREATE INDEX idx_translations_v2_norm ON translations_v2(en_norm);
        CREATE TABLE glossary(term TEXT PRIMARY KEY, vi TEXT, keep_original INTEGER DEFAULT 1, kind TEXT);
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    """)
    seen = set()
    kept = skipped = 0
    for p in pairs:
        en, vi = (p.get("en") or "").strip(), (p.get("vi") or "").strip()
        n = normalize(en)
        if not n or not vi or n == normalize(vi) or (has_vi(en) and not has_vi(vi)):
            skipped += 1
            continue
        key = (n, vi)
        if key in seen:
            continue
        seen.add(key)
        c.execute("INSERT INTO translations_v2(en, vi, en_norm, speaker, category, string_key) VALUES (?,?,?,?,?,?)",
                  (en, vi, n, p.get("speaker") or speaker_of(en), p.get("category"), p.get("key")))
        kept += 1
    for name in names:
        c.execute("INSERT OR IGNORE INTO glossary(term, vi, keep_original, kind) VALUES (?,?,1,'name')", (name, name))
    c.execute("INSERT INTO meta VALUES ('format','ps5translator-v2')")
    c.execute("INSERT INTO meta VALUES ('pairs',?)", (str(kept),))
    conn.commit()
    conn.close()
    print(f"✅ Đã tạo {out_path}: {kept} cặp Anh→Việt, bỏ {skipped} dòng trống/chưa dịch, {len(names)} tên riêng.")


def read_names(args):
    if "--names" in args:
        path = args[args.index("--names") + 1]
        with open(path, encoding="utf-8-sig") as f:
            return [l.strip() for l in f if l.strip()]
    return []


def cmd_build(src, out, names):
    pairs = []
    if src.lower().endswith(".txt"):
        with open(src, encoding="utf-8-sig") as f:
            for line in f:
                if "|||" in line:
                    en, vi = line.split("|||", 1)
                    pairs.append({"en": en.strip(), "vi": vi.strip()})
    else:
        delim = "\t" if src.lower().endswith((".tsv", ".tab")) else ","
        with open(src, encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f, delimiter=delim)
            cols = {c.lower().strip(): c for c in reader.fieldnames or []}
            en_c = next((cols[a] for a in EN_ALIASES if a in cols), None)
            vi_c = next((cols[a] for a in VI_ALIASES if a in cols), None)
            key_c = next((cols[a] for a in ("key", "string_key", "id", "string_id") if a in cols), None)
            spk_c = cols.get("speaker")
            cat_c = cols.get("category")
            if not en_c or not vi_c:
                print(f"❌ Không thấy cột Anh/Việt. Cột hiện có: {reader.fieldnames}")
                return 1
            for r in reader:
                pairs.append({"en": r.get(en_c), "vi": r.get(vi_c),
                              "key": r.get(key_c) if key_c else None,
                              "speaker": r.get(spk_c) if spk_c else None,
                              "category": r.get(cat_c) if cat_c else None})
    create_db(out, pairs, names)
    return 0


def cmd_build_parallel(en_path, vi_path, out, names):
    with open(en_path, encoding="utf-8-sig") as f:
        en_lines = [l.rstrip("\n\r") for l in f]
    with open(vi_path, encoding="utf-8-sig") as f:
        vi_lines = [l.rstrip("\n\r") for l in f]
    if len(en_lines) != len(vi_lines):
        print(f"⚠️ Số dòng khác nhau: Anh {len(en_lines)} / Việt {len(vi_lines)} -> chỉ ghép {min(len(en_lines), len(vi_lines))} dòng đầu."
              " Hãy kiểm tra lại 2 file có cùng thứ tự.")
    pairs = [{"en": e, "vi": v} for e, v in zip(en_lines, vi_lines)]
    create_db(out, pairs, names)
    return 0


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    cmd = argv[1]
    names = read_names(argv)
    if cmd == "check":
        return cmd_check(argv[2])
    if cmd == "build" and len(argv) >= 4:
        return cmd_build(argv[2], argv[3], names)
    if cmd == "build-parallel" and len(argv) >= 5:
        return cmd_build_parallel(argv[2], argv[3], argv[4], names)
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
