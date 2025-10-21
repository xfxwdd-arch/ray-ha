FROM iregistry.baidu-int.com/hub-official/ubuntu:24.04 AS builder

# 设置非交互模式
ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'deb http://mirrors.baidubce.com/ubuntu/ noble main restricted universe multiverse' > /etc/apt/sources.list \
    && echo 'deb http://mirrors.baidubce.com/ubuntu/ noble-updates main restricted universe multiverse' >> /etc/apt/sources.list \
    && echo 'deb http://mirrors.baidubce.com/ubuntu/ noble-backports main restricted universe multiverse' >> /etc/apt/sources.list \
    && echo 'deb http://mirrors.baidubce.com/ubuntu/ noble-security main restricted universe multiverse' >> /etc/apt/sources.list

RUN echo 'exit 0' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

RUN apt update && \
    apt install -y gnupg ca-certificates python3 python3-pip redis-tools sudo curl less vim wget && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# 安装ray
RUN pip3 install -U 'ray[default,data]' -i http://pip.baidu-int.com/simple --trusted-host pip.baidu-int.com --break-system-packages

# 验证redis安装
RUN redis-cli --version

USER root

RUN mkdir -p /root/ray || true

# 启动和探活脚本
COPY start.sh /root/ray/start.sh
COPY livenessProbe.sh /root/ray/livenessProbe.sh

RUN chmod 777 /root && chmod 777 /root/ray && chmod 777 /root/ray/*.sh

CMD ["/bin/bash"]
