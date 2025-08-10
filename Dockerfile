FROM ghcr.io/moyangking/astrbot-lagrange-docker:main

# 仅对外暴露 noVNC 的一个端口
EXPOSE 6080

ENV BASE_URL=https://generativelanguage.googleapis.com/v1beta
ENV TOOLS_CODE_EXECUTION_ENABLED=false
ENV IMAGE_MODELS='["gemini-2.0-flash"]'
ENV SEARCH_MODELS='["gemini-2.0-flash"]'

# noVNC/桌面相关
ENV NOVNC_PORT=6080 \
    SCREEN_WIDTH=1440 \
    SCREEN_HEIGHT=900 \
    SCREEN_DEPTH=24 \
    INTERNAL_LINKS=[{\"name\":\"Uvicorn API\",\"url\":\"http://127.0.0.1:8000\"},{\"name\":\"Dotnet 服务(示例)\",\"url\":\"http://127.0.0.1:6185\"}]

ARG APP_HOME=/app
ARG APT_PACKAGES=""
ARG PIP_PACKAGES=""

USER root

# 安装依赖（无 Nginx）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git jq curl ca-certificates \
      novnc websockify x11vnc xvfb fluxbox fonts-dejavu \
      ${APT_PACKAGES} && \
    (apt-get install -y --no-install-recommends firefox-esr || \
     apt-get install -y --no-install-recommends firefox || \
     apt-get install -y --no-install-recommends chromium || \
     apt-get install -y --no-install-recommends chromium-browser || true) && \
    rm -rf /var/lib/apt/lists/*

# 可选额外 pip
RUN if [ ! -z "${PIP_PACKAGES}" ]; then pip install ${PIP_PACKAGES}; fi

WORKDIR ${APP_HOME}

# 拉取业务代码
RUN git clone --depth=1 https://github.com/MoYangking/gemini-balance.git /tmp/gemini-balance && \
    cp -a /tmp/gemini-balance/. . && rm -rf /tmp/gemini-balance

# 安装 requirements
RUN pip install --no-cache-dir -r requirements.txt

# 复制脚本与 supervisor 配置
COPY launch.sh /app/launch.sh
COPY supervisord.conf /app/supervisord.conf
COPY start-desktop.sh /app/start-desktop.sh

# 便捷工具
RUN curl -JLO https://github.com/bincooo/SillyTavern-Docker/releases/download/v1.0.0/git-batch

# 权限 && 换行修正
RUN chmod +x /app/launch.sh /app/git-batch /app/start-desktop.sh && \
    sed -i 's/\r$//' /app/launch.sh && \
    chmod -R 777 ${APP_HOME}

CMD ["/usr/bin/supervisord", "-c", "/app/supervisord.conf"]