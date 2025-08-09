# 使用官方推荐的基础镜像
FROM ghcr.io/moyangking/astrbot-lagrange-docker:main

# 暴露应用程序所需的端口
EXPOSE 6185
EXPOSE 8000

# 设置环境变量
ENV BASE_URL=https://generativelanguage.googleapis.com/v1beta
ENV TOOLS_CODE_EXECUTION_ENABLED=false
ENV IMAGE_MODELS='["gemini-2.0-flash"]'
ENV SEARCH_MODELS='["gemini-2.0-flash"]'

# 定义应用程序主目录的参数
ARG APP_HOME=/app

# 定义用于安装额外软件包的参数
ARG APT_PACKAGES=""
ARG PIP_PACKAGES=""

# 切换到 root 用户以便进行安装操作
USER root

# 更新软件包列表并安装必要的依赖
# 将所有 apt 操作合并到一层，以减小镜像体积
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    jq \
    curl \
    supervisor \
    ${APT_PACKAGES} && \
    rm -rf /var/lib/apt/lists/*

# 如果定义了额外的 pip 包，则进行安装
RUN if [ ! -z "${PIP_PACKAGES}" ]; then pip install --no-cache-dir ${PIP_PACKAGES}; fi

# 克隆代码仓库
# 修正：在克隆前，先强制删除目标目录，以防基础镜像中已存在该目录
RUN rm -rf ${APP_HOME} && git clone --depth=1 https://github.com/snailyp/gemini-balance.git ${APP_HOME}

# 将工作目录切换到应用程序主目录
WORKDIR ${APP_HOME}

# 安装 Python 依赖
RUN pip install --no-cache-dir -r requirements.txt

# 复制配置文件和启动脚本
COPY launch.sh /app/launch.sh
COPY supervisord.conf /app/supervisord.conf

# 下载 git-batch 工具
RUN curl -JLO https://github.com/bincooo/SillyTavern-Docker/releases/download/v1.0.0/git-batch

# 确保脚本有执行权限
# 修正：将 git-batch 也赋予执行权限
RUN chmod +x /app/launch.sh /app/git-batch

# 去除 Windows 换行符，防止脚本执行错误
RUN sed -i 's/\r$//' /app/launch.sh

# 确保目录权限 (在所有文件操作后执行更稳妥)
RUN chmod -R 777 ${APP_HOME}

# 最终启动命令
CMD ["/usr/bin/supervisord", "-c", "/app/supervisord.conf"]
