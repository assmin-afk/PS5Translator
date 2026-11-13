#!/usr/bin/env bash
# ============================================================================
# build_chiaki_native.sh - Biên dịch lõi Remote Play chiaki-ng (đầy đủ: session,
# ctrl, Takion, ECDH, gkcrypt, FEC, video) + mbedTLS + nanopb + jerasure/gf-complete
# + cầu nối C của PS5Translator thành 1 thư viện tĩnh libps5native.a
#
# Cách dùng:
#   scripts/build_chiaki_native.sh <thu_muc_chiaki-ng> <thu_muc_mbedtls> <thu_muc_ra>
#
# Mặc định build cho iPhone (arm64, iOS 16). Có thể ghi đè bằng biến môi trường:
#   NATIVE_CC   (vd: "gcc" để thử trên Linux)
#   NATIVE_AR   (vd: "ar")
# ============================================================================
set -euo pipefail

CHIAKI_DIR="$(cd "$1" && pwd)"
MBEDTLS_DIR="$(cd "$2" && pwd)"
OUT_DIR="$3"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="$ROOT_DIR/ChiakiNative"

mkdir -p "$OUT_DIR/obj"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
OBJ="$OUT_DIR/obj"
rm -f "$OBJ"/*.o

if [ -z "${NATIVE_CC:-}" ]; then
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  NATIVE_CC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -isysroot $SDK"
fi
NATIVE_AR="${NATIVE_AR:-}"

TP="$CHIAKI_DIR/third-party"
COMMON_FLAGS="-O2 -w -fPIC -DCHIAKI_LIB_ENABLE_MBEDTLS -DPB_C99_STATIC_ASSERT"
INCLUDES="-I$NATIVE_DIR/stubs -I$NATIVE_DIR/config -I$NATIVE_DIR/generated -I$NATIVE_DIR \
 -I$CHIAKI_DIR/lib/include -I$TP/nanopb -I$TP/jerasure/include -I$TP/gf-complete/include \
 -I$MBEDTLS_DIR/include -I$MBEDTLS_DIR/library"

compile() { # $1 = tiền tố tên object, $2 = file .c
  local out="$OBJ/$1_$(basename "$2" .c).o"
  $NATIVE_CC $COMMON_FLAGS $INCLUDES -c "$2" -o "$out"
}

echo "==> mbedTLS"
for f in "$MBEDTLS_DIR"/library/*.c; do compile mbed "$f"; done

echo "==> gf-complete + jerasure"
for f in gf gf_wgen gf_w4 gf_w8 gf_w16 gf_w32 gf_w64 gf_w128 gf_rand gf_general gf_cpu; do
  compile gf "$TP/gf-complete/src/$f.c"
done
for f in galois jerasure reed_sol cauchy liberation; do
  compile jer "$TP/jerasure/src/$f.c"
done

echo "==> nanopb + takion.pb"
for f in pb_common pb_encode pb_decode; do compile npb "$TP/nanopb/$f.c"; done
compile npb "$NATIVE_DIR/generated/takion.pb.c"

echo "==> chiaki-ng lib (bỏ: holepunch/rudp/aia/ffmpeg/pi/opus)"
for f in "$CHIAKI_DIR"/lib/src/*.c; do
  case "$(basename "$f")" in
    aia.c|aia_openssl.c|ffmpegdecoder.c|pidecoder.c|opusdecoder.c|opusencoder.c) continue ;;
  esac
  compile chiaki "$f"
done

echo "==> cầu nối PS5Translator"
compile ps5 "$NATIVE_DIR/chiaki_ios_stubs.c"
compile ps5 "$NATIVE_DIR/ChiakiCBridge.c"
compile ps5 "$NATIVE_DIR/PS5RemotePlayBridge.c"

rm -f "$OUT_DIR/libps5native.a"
if [ -n "$NATIVE_AR" ]; then
  $NATIVE_AR rcs "$OUT_DIR/libps5native.a" "$OBJ"/*.o
else
  xcrun -sdk iphoneos libtool -static -o "$OUT_DIR/libps5native.a" "$OBJ"/*.o
fi
echo "==> Xong: $OUT_DIR/libps5native.a ($(ls "$OBJ" | wc -l | tr -d ' ') object)"
