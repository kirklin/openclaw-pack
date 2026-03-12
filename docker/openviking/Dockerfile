FROM python:3.11-slim

LABEL description="OpenViking long-term memory server for openclaw-pack"

# 安装 openviking（bake 到镜像中，避免每次启动重装）
RUN pip install openviking --upgrade --no-cache-dir -q

# 复制启动脚本
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 1933

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
