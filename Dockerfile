FROM ghcr.io/moyangking/astrbot-lagrange-docker:main

# 只开放一个公网端口（Nginx对外）
EXPOSE 8000

# 业务环境变量（按需覆盖）
ENV BASE_URL=https://generativelanguage.googleapis.com/v1beta
ENV TOOLS_CODE_EXECUTION_ENABLED=false
ENV IMAGE_MODELS='["gemini-2.0-flash"]'
ENV SEARCH_MODELS='["gemini-2.0-flash"]'

# 统一定义内部服务端口，便于通过环境变量覆盖
ENV PUBLIC_PORT=8000      # 容器内 Nginx 对外端口
ENV UVICORN_PORT=9000     # Python(Uvicorn) 内部端口
ENV DOTNET_PORT=6185      # dotnet 内部端口

ARG APP_HOME=/app

# 构建期可加装额外包
ARG APT_PACKAGES=""
ARG PIP_PACKAGES=""

# root 以便安装
USER root

# 安装 git、curl、jq、nginx、envsubst 及额外 apt 包
RUN apt-get update && apt-get install -y \
    git jq curl nginx gettext-base ${APT_PACKAGES} && \
    rm -rf /var/lib/apt/lists/*

# 安装额外 pip 包（可选）
RUN if [ ! -z "${PIP_PACKAGES}" ]; then pip install ${PIP_PACKAGES}; fi

# 工作目录
WORKDIR ${APP_HOME}

# 拉取项目代码
RUN git clone --depth=1 https://github.com/MoYangking/gemini-balance.git /tmp/gemini-balance && \
    cp -a /tmp/gemini-balance/. . && rm -rf /tmp/gemini-balance

# 安装 Python 依赖
RUN pip install --no-cache-dir -r requirements.txt

# 放入启动脚本、supervisor 配置、Nginx 模板
COPY launch.sh /app/launch.sh
COPY supervisord.conf /app/supervisord.conf
COPY nginx.conf.template /app/nginx.conf.template

# 额外工具（原有）
RUN curl -JLO https://github.com/bincooo/SillyTavern-Docker/releases/download/v1.0.0/git-batch

# 权限
RUN chmod +x /app/launch.sh && chmod +x /app/git-batch
RUN chmod -R 777 ${APP_HOME}

# 验证文件存在 + 处理换行
RUN ls -la /app/launch.sh
RUN sed -i 's/\r$//' /app/launch.sh

# 以 supervisord 作为入口
CMD ["/usr/bin/supervisord", "-c", "/app/supervisord.conf"]