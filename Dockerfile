FROM ghcr.io/moyangking/astrbot-lagrange-docker:main

# 对外只需要开放一个 noVNC 端口（这里选 6080）
EXPOSE 6080

# 你的原始 ENV
ENV BASE_URL=https://generativelanguage.googleapis.com/v1beta
ENV TOOLS_CODE_EXECUTION_ENABLED=false
ENV IMAGE_MODELS='["gemini-2.0-flash"]'
ENV SEARCH_MODELS='["gemini-2.0-flash"]'

# noVNC/桌面相关 ENV
ENV NOVNC_PORT=6080 \
    SCREEN_WIDTH=1440 \
    SCREEN_HEIGHT=900 \
    SCREEN_DEPTH=24 \
    # 在 noVNC 打开的浏览器首页里要显示的内网服务链接（可按需改动）
    INTERNAL_LINKS='[{"name":"Uvicorn API","url":"http://127.0.0.1:8000"},{"name":"Dotnet 服务(示例)","url":"http://127.0.0.1:6185"}]'

ARG APP_HOME=/app
ARG APT_PACKAGES=""
ARG PIP_PACKAGES=""

# 切换到 root 用户
USER root

# 安装 git、curl、jq + noVNC 桌面相关组件（不使用 Nginx）
# 同时尽力安装 firefox-esr，若无则尝试 chromium/chromium-browser
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git jq curl ca-certificates \
      novnc websockify x11vnc xvfb fluxbox fonts-dejavu \
      ${APT_PACKAGES} && \
    (apt-get install -y --no-install-recommends firefox-esr || \
     apt-get install -y --no-install-recommends chromium || \
     apt-get install -y --no-install-recommends chromium-browser || true) && \
    rm -rf /var/lib/apt/lists/*

# 安装额外的 pip 包（如果设置了 PIP_PACKAGES）
RUN if [ ! -z "${PIP_PACKAGES}" ]; then pip install ${PIP_PACKAGES}; fi

# 设置工作目录
WORKDIR ${APP_HOME}

# 克隆业务代码
RUN git clone --depth=1 https://github.com/MoYangking/gemini-balance.git /tmp/gemini-balance && \
    cp -a /tmp/gemini-balance/. . && rm -rf /tmp/gemini-balance

# 安装 requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# 放置启动脚本与 supervisor 配置
COPY launch.sh /app/launch.sh
COPY supervisord.conf /app/supervisord.conf

# 便捷工具（来自你原来的 Dockerfile）
RUN curl -JLO https://github.com/bincooo/SillyTavern-Docker/releases/download/v1.0.0/git-batch

# noVNC 桌面启动脚本
COPY start-desktop.sh /app/start-desktop.sh

# 权限
RUN chmod +x /app/launch.sh /app/git-batch /app/start-desktop.sh && \
    chmod -R 777 ${APP_HOME}

# 验证
RUN ls -la /app/launch.sh && sed -i 's/\r$//' /app/launch.sh

# 使用 supervisord 管理全部进程（包含 noVNC + 桌面 + 你的原有服务）
CMD ["/usr/bin/supervisord", "-c", "/app/supervisord.conf"]