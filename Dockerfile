FROM ghcr.io/moyangking/astrbot-lagrange-docker:main

EXPOSE 6185
EXPOSE 8484

ARG APP_HOME=/app

#用于添加额外的apt包
ARG APT_PACKAGES=""

#用于添加额外的pip包
ARG PIP_PACKAGES=""

#切换到 root 用户以便安装软件包和使用 pip 安装包
USER root

RUN mkdir -p /data && chown -R 1000:1000 /data

#安装 git、curl、jq、unzip 以及额外 apt 包
RUN apt-get update && apt-get install -y git jq curl unzip ${APT_PACKAGES} && \
    rm -rf /var/lib/apt/lists/*

#安装额外的 pip 包
RUN if [ ! -z "${PIP_PACKAGES}" ]; then pip install ${PIP_PACKAGES}; fi

#将工作目录设置为 /app
WORKDIR ${APP_HOME}

#下载并解压 clewdr
RUN curl -fsSL https://github.com/Xerxes-2/clewdr/releases/download/v0.11.14/clewdr-linux-x86_64.zip -o /tmp/clewdr.zip && \
    unzip /tmp/clewdr.zip -d /app && \
    rm /tmp/clewdr.zip && \
    chmod +x /app/clewdr

#确保启动脚本和 supervisord 配置
COPY launch.sh /app/launch.sh
COPY supervisord.conf /app/supervisord.conf
RUN curl -JLO https://github.com/bincooo/SillyTavern-Docker/releases/download/v1.0.0/git-batch

#确保执行权限
RUN chmod +x /app/launch.sh && chmod +x /app/git-batch

#确保目录权限
RUN chmod -R 777 ${APP_HOME}

#验证文件存在
RUN ls -la /app/launch.sh

#去除 Windows 换行符
RUN sed -i 's/\r$//' /app/launch.sh

CMD ["/usr/bin/supervisord", "-c", "/app/supervisord.conf"]