#!/usr/bin/env bash
set -e

export DISPLAY=:0
W=${SCREEN_WIDTH:-1440}
H=${SCREEN_HEIGHT:-900}
D=${SCREEN_DEPTH:-24}
NOVNC_PORT=${NOVNC_PORT:-6080}

# 启动 X 虚拟显示
Xvfb :0 -screen 0 ${W}x${H}x${D} -nolisten tcp &
sleep 0.5

# 启动轻量窗口管理器
fluxbox >/dev/null 2>&1 &

# 启动 VNC 服务（仅容器内使用，不暴露端口）
x11vnc -display :0 -rfbport 5900 -forever -shared -nopw -quiet >/dev/null 2>&1 &

# 生成 noVNC 内浏览器的起始页，包含内网服务快捷入口
mkdir -p /app/desktop
LINKS_JSON="${INTERNAL_LINKS:-[{\"name\":\"Uvicorn API\",\"url\":\"http://127.0.0.1:8000\"},{\"name\":\"Dotnet 服务(示例)\",\"url\":\"http://127.0.0.1:6185\"}]}"

LINK_ITEMS=$(echo "$LINKS_JSON" | jq -r '.[] | "<li><a href=\"KATEX_INLINE_OPEN.url)\" target=\"_self\">KATEX_INLINE_OPEN.name)</a></li>"')

cat > /app/desktop/index.html <<EOF
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
    ${LINK_ITEMS}
  </ul>
  <div class="hint">
    提示：这些链接只在容器内可访问（127.0.0.1），请通过本页面的浏览器打开使用。
  </div>
</body>
</html>
EOF

# 启动一个浏览器（优先 firefox-esr，其次 firefox / chromium）
BROWSER=""
if command -v firefox-esr >/dev/null 2>&1; then
  BROWSER="firefox-esr"
elif command -v firefox >/dev/null 2>&1; then
  BROWSER="firefox"
elif command -v chromium >/dev/null 2>&1; then
  BROWSER="chromium"
elif command -v chromium-browser >/dev/null 2>&1; then
  BROWSER="chromium-browser"
fi

if [ -n "$BROWSER" ]; then
  if [[ "$BROWSER" == "chromium"* ]]; then
    "$BROWSER" --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --disable-infobars "file:///app/desktop/index.html" >/dev/null 2>&1 &
  else
    "$BROWSER" --no-remote "file:///app/desktop/index.html" >/dev/null 2>&1 &
  fi
else
  echo "未找到可用的浏览器（firefox/chromium），请确认镜像内安装成功。"
fi

# 选择 noVNC 静态文件目录
NOVNC_WEB="/usr/share/novnc"
[ -d "/usr/lib/novnc" ] && NOVNC_WEB="/usr/lib/novnc"

echo "noVNC Web: ${NOVNC_WEB}, 监听端口: ${NOVNC_PORT}"
# 启动 websockify + noVNC（对外暴露的唯一端口）
exec websockify --web "${NOVNC_WEB}" ${NOVNC_PORT} localhost:5900