#!/usr/bin/env bash
set -Eeuo pipefail

NOVNC_PORT=${NOVNC_PORT:-6080}
SCREEN_WIDTH=${SCREEN_WIDTH:-1440}
SCREEN_HEIGHT=${SCREEN_HEIGHT:-900}
SCREEN_DEPTH=${SCREEN_DEPTH:-24}

# 确保 X11 目录存在；rootless 场景 chown 可能失败，静音即可
mkdir -p /tmp/.X11-unix || true
(chown root:root /tmp/.X11-unix 2>/dev/null || true)
chmod 1777 /tmp/.X11-unix || true

# 选一个空闲 DISPLAY，尽量避开 :0
choose_display() {
  for n in 1 0 2 3 4 5 99; do
    if [ ! -e "/tmp/.X${n}-lock" ]; then
      echo "$n"; return
    fi
  done
  echo 1
}
DNUM="$(choose_display)"
export DISPLAY=":${DNUM}"
VNC_PORT=$((5900 + DNUM))

cleanup() {
  set +e
  pkill -f "x11vnc.*:${VNC_PORT}" >/dev/null 2>&1 || true
  pkill -f "Xvfb :${DNUM}" >/dev/null 2>&1 || true
  rm -f "/tmp/.X${DNUM}-lock"
}
trap cleanup EXIT TERM INT

# 启动 Xvfb
Xvfb ":${DNUM}" -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" -nolisten tcp &
sleep 0.5

# 窗口管理器
fluxbox >/dev/null 2>&1 &

# 可选 VNC 密码（公网建议开启）
PASS_OPTS=""
if [ -n "${VNC_PASSWORD:-}" ]; then
  PASS_OPTS="-passwd ${VNC_PASSWORD}"
fi

# VNC（仅本机）
x11vnc -display ":${DNUM}" -rfbport "${VNC_PORT}" -localhost -forever -shared -nopw ${PASS_OPTS} -quiet >/dev/null 2>&1 &

# 生成 “容器内浏览器”的起始页（用于访问 127.0.0.1 的内部服务）
mkdir -p /app/desktop
DEFAULT_LINKS='[
  {"name":"Uvicorn API","url":"http://127.0.0.1:8000"},
  {"name":"Dotnet 服务(示例)","url":"http://127.0.0.1:6185"}
]'

# 优先 base64（避免 JSON 被转义/截断）
LINKS_JSON=""
if [ -n "${INTERNAL_LINKS_B64:-}" ] && command -v base64 >/dev/null 2>&1; then
  if LINKS_JSON=$(printf '%s' "${INTERNAL_LINKS_B64}" | base64 -d 2>/dev/null); then
    :
  else
    echo "WARN: INTERNAL_LINKS_B64 解码失败，回退到 INTERNAL_LINKS/默认"
    LINKS_JSON=""
  fi
fi
# 其次用明文 INTERNAL_LINKS
if [ -z "$LINKS_JSON" ]; then
  LINKS_JSON="${INTERNAL_LINKS:-$DEFAULT_LINKS}"
fi
# 校验 JSON，非法则回退默认
if ! echo "$LINKS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "WARN: INTERNAL_LINKS 不是合法 JSON，回落到默认链接"
  LINKS_JSON="$DEFAULT_LINKS"
fi

LINK_ITEMS=$(echo "$LINKS_JSON" | jq -r '.[] | "<li><a href=\"KATEX_INLINE_OPEN.url)\" target=\"_self\">KATEX_INLINE_OPEN.name)</a></li>"')

cat > /app/desktop/index.html <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<title>内网服务入口</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Noto Sans", "Helvetica Neue", Arial; padding: 24px; background: #0b132b; color: #e0e0e0; }
  h1 { margin-top: 0; }
  ul { line-height: 1.8; }
  a { color: #61dafb; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .hint { margin-top: 16px; color: #bbb; font-size: 14px; }
</style>
</head>
<body>
  <h1>内网服务入口</h1>
  <ul>
EOF

echo "    ${LINK_ITEMS}" >> /app/desktop/index.html

cat >> /app/desktop/index.html <<'EOF'
  </ul>
  <div class="hint">
    提示：这些链接只在容器内可访问（127.0.0.1），请通过本页面的浏览器打开使用。
  </div>
</body>
</html>
EOF

# 启动容器内浏览器，打开上面的入口页
browser=""
if command -v firefox-esr >/dev/null 2>&1; then browser=firefox-esr
elif command -v firefox >/dev/null 2>&1; then browser=firefox
elif command -v chromium >/dev/null 2>&1; then browser=chromium
elif command -v chromium-browser >/dev/null 2>&1; then browser=chromium-browser
fi

if [ -n "$browser" ]; then
  if [[ "$browser" == chromium* ]]; then
    "$browser" --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --disable-infobars "file:///app/desktop/index.html" >/dev/null 2>&1 &
  else
    "$browser" "file:///app/desktop/index.html" >/dev/null 2>&1 &
  fi
else
  echo "WARN: 未找到浏览器（firefox/chromium）"
fi

# 准备 noVNC 静态资源，定制 index.html 让根路径直接进入 vnc.html（自动连接）
NOVNC_SRC="/usr/share/novnc"
[ -d "/usr/lib/novnc" ] && NOVNC_SRC="/usr/lib/novnc"
mkdir -p /app/novnc
# 首次复制 noVNC 静态文件
if [ ! -f /app/novnc/vnc.html ]; then
  cp -a "${NOVNC_SRC}/." /app/novnc/
fi

# 写入自定义首页：访问 / 直接跳到 vnc.html 并自动连接
cat > /app/novnc/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>noVNC</title>
  <script>
    (function () {
      var host = window.location.hostname;
      var port = window.location.port || (window.location.protocol === 'https:' ? '443' : '80');
      var encrypt = (window.location.protocol === 'https:') ? '&encrypt=1' : '';
      // 使用 /vnc.html 并自动连接到当前 host:port，path 使用 websockify（noVNC 默认）
      var target = 'vnc.html?autoconnect=1&reconnect=1&resize=remote&view_clip=1&host='
                   + encodeURIComponent(host) + '&port=' + encodeURIComponent(port)
                   + '&path=websockify' + encrypt;
      window.location.replace(target);
    })();
  </script>
</head>
<body>
  正在跳转到 noVNC...
</body>
</html>
EOF

# 前台运行 websockify（把根路径 / 的 web 根指向 /app/novnc）
echo "noVNC Web: /app/novnc, 监听端口: ${NOVNC_PORT}, DISPLAY :${DNUM}, VNC ${VNC_PORT}"
exec websockify --web "/app/novnc" "${NOVNC_PORT}" "localhost:${VNC_PORT}"