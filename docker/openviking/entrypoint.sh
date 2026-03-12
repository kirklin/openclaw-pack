#!/bin/bash
# ==============================================================================
# OpenViking 启动脚本
# 首次启动时根据环境变量生成 ov.conf，然后启动 openviking-server
# ==============================================================================
set -e

CONFIG=/root/.openviking/ov.conf

mkdir -p /root/.openviking/data

if [ ! -f "$CONFIG" ]; then
  echo "[openviking] Generating ov.conf from environment variables..."
  python3 - << 'PYEOF'
import json, os

def get(key, default=None):
    v = os.environ.get(key, default)
    return v if v else default

conf = {
  "server": {"host": "127.0.0.1", "port": 1933},
  "storage": {
    "workspace": "/root/.openviking/data",
    "vectordb": {"backend": "local"},
    "agfs": {"backend": "local", "port": 1833}
  },
  "embedding": {
    "dense": {
      "provider": get("OPENVIKING_EMBED_PROVIDER", "openai"),
      "api_key":  get("OPENVIKING_EMBED_API_KEY") or get("OV_API_KEY"),
      "api_base": get("OPENVIKING_EMBED_API_BASE") or get("OV_API_BASE"),
      "model":    get("OPENVIKING_EMBED_MODEL", "text-embedding-3-small"),
      "dimension": int(get("OPENVIKING_EMBED_DIM", "1536")),
      "input": "text"
    }
  },
  "vlm": {
    "provider": get("OPENVIKING_VLM_PROVIDER", "openai"),
    "api_key":  get("OPENVIKING_VLM_API_KEY") or get("OV_API_KEY"),
    "api_base": get("OPENVIKING_VLM_API_BASE") or get("OV_API_BASE"),
    "model":    get("OPENVIKING_VLM_MODEL", "gpt-4o-mini")
  }
}

# 清理 None 值（避免写入非法字段）
conf['embedding']['dense'] = {k: v for k, v in conf['embedding']['dense'].items() if v is not None}
conf['vlm'] = {k: v for k, v in conf['vlm'].items() if v is not None}

with open("/root/.openviking/ov.conf", "w") as f:
  json.dump(conf, f, indent=2)

print("[openviking] ov.conf generated successfully.")
print("[openviking] embed:", conf['embedding']['dense'].get('provider'), conf['embedding']['dense'].get('model'))
print("[openviking] vlm:  ", conf['vlm'].get('provider'), conf['vlm'].get('model'))
PYEOF
else
  echo "[openviking] ov.conf already exists, skipping generation."
fi

echo "[openviking] Starting openviking-server..."
exec openviking-server
