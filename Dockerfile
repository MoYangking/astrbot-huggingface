FROM ghcr.io/moyangking/astrbot-lagrange-docker:main

# 只开放一个公网端口（Nginx对外）
EXPOSE 8000

# 环境变量（可按需覆盖）
ENV BASE_URL=https://generativelanguage.googleapis.com/v1beta
ENV TOOLS_CODE_EXECUTION_ENABLED=false
ENV IMAGE_MODELS='["gemini-2.0-flash"]'
ENV SEARCH_MODELS='["gemini-2.0-flash"]'

# 统一在这里定义内部服务端口，方便改
# 对外Nginx端口
ENV PUBLIC_PORT=8000
# Uvicorn内部端口（从8000改为9000，避免占用对外端口）
ENV UVICORN_PORT=9000
# dotnet内部端口（假定是6185，如需变更可覆盖）
ENV DOTNET_PORT=6185

ARG APP_HOME=/app

# 用于添加额外的apt包（可在构建时传入）
ARG APT_PACKAGES=""
# 用于添加额外的pip包（可在构建时传入）
ARG PIP_PACKAGES=""

# 切换到 root 用户以便安装软件包和使用 pip 安装包
USER root

# 安装 git、curl、jq、Nginx、envsubst 以及额外 apt 包
RUN apt-get update && apt-get install -y \
    git jq curl nginx gettext-base ${APT_PACKAGES} && \
    rm -rf /var/lib/apt/lists/*

# 安装额外的 pip 包
RUN if [ ! -z "${PIP_PACKAGES}" ]; then pip install ${PIP_PACKAGES}; fi

# 将工作目录设置为 /app
WORKDIR ${APP_HOME}

# 克隆代码到临时目录，然后复制到工作目录以避免 "directory not empty" 错误
RUN git clone --depth=1 https://github.com/MoYangking/gemini-balance.git /tmp/gemini-balance && \
    cp -a /tmp/gemini-balance/. . && rm -rf /tmp/gemini-balance

# 安装 requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# 确保启动脚本和 supervisord 配置
COPY launch.sh /app/launch.sh
COPY supervisord.conf /app/supervisord.conf

# 反向代理的 Nginx 模板
COPY nginx.conf.template /app/nginx.conf.template

# 额外工具
RUN curl -JLO https://github.com/bincooo/SillyTavern-Docker/releases/download/v1.0.0/git-batch

# 确保执行权限
RUN chmod +x /app/launch.sh && chmod +x /app/git-batch

# 确保目录权限
RUN chmod -R 777 ${APP_HOME}

# 验证文件存在
RUN ls -la /app/launch.sh

# 去除 Windows 换行符
RUN sed -i 's/\r$//' /app/launch.sh

# 将 Nginx 日志打到容器 stdout/stderr（配合我们自定义的nginx.conf也可）
# 可选：ln -sf /dev/stdout /var/log/nginx/access.log && ln -sf /dev/stderr /var/log/nginx/error.log

CMD ["/usr/bin/supervisord", "-c", "/app/supervisord.conf"]