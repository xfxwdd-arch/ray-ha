FROM iregistry.baidu-int.com/hub-official/ubuntu:20.04 AS builder

# 设置非交互模式
ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal main restricted universe multiverse' > /etc/apt/sources.list \
    && echo 'deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-updates main restricted universe multiverse' >> /etc/apt/sources.list \
    && echo 'deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-backports main restricted universe multiverse' >> /etc/apt/sources.list \
    && echo 'deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ focal-security main restricted universe multiverse' >> /etc/apt/sources.list

RUN apt update && \
    apt install -y gnupg ca-certificates python3.9 pip sudo curl less vim wget net-tools telnet strace sysstat && \
    apt install -y redis-tools && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

# 安装ray
RUN pip3 install -U 'ray[serve]' -i https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple

# 验证redis安装
RUN redis-cli --version

USER root

RUN mkdir -p /root/ray || true

# 启动和探活脚本
COPY start.sh /root/ray/start.sh
COPY livenessProbe.sh /root/ray/livenessProbe.sh

RUN chmod 777 /root && chmod 777 /root/ray && chmod 777 /root/ray/*.sh

CMD ["/bin/bash"]
