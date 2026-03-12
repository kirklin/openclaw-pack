#!/bin/bash

# ==============================================================================
# Kirklin's openclaw-pack Init Script (Bash + jq)
# ==============================================================================

set -e

# --- Logging Output ---
log_info()    { echo "[INFO]  $1"; }
log_success() { echo "[SUCCESS] $1"; }
log_warn()    { echo "[WARN]  $1"; }
log_error()   { echo "[ERROR] $1" >&2; }

log_info "=== Kirklin's openclaw-pack 初始化 ==="

# --- Env Definitions ---
APP_DATA_DIR="${APP_DATA_DIR:-/home/node/.openclaw}"
APP_WORKSPACE="${APP_WORKSPACE:-${APP_DATA_DIR}/workspace}"
CONFIG_FILE="$APP_DATA_DIR/openclaw.json"
NODE_UID="$(id -u node)"
NODE_GID="$(id -g node)"

# 预创建挂载目录
mkdir -p "$APP_DATA_DIR/extensions" "$APP_WORKSPACE"

# --- Permissions Check ---
if [ "$(id -u)" -eq 0 ]; then
    CURRENT_OWNER="$(stat -c '%u:%g' "$APP_DATA_DIR" 2>/dev/null || echo unknown:unknown)"
    if [ "$CURRENT_OWNER" != "${NODE_UID}:${NODE_GID}" ]; then
        log_warn "检测到挂载目录所有者 ($CURRENT_OWNER) 与容器运行用户 (${NODE_UID}:${NODE_GID}) 不一致"
        log_info "尝试自动修复目录所有权 (chown)..."
        chown -R node:node "$APP_DATA_DIR" || true
    fi

    # 测试 node 用户是否可写
    if ! gosu node test -w "$APP_DATA_DIR"; then
        log_error "权限检查失败: node 用户无法写入 $APP_DATA_DIR"
        log_error "  >> 请在宿主机执行: sudo chown -R ${NODE_UID}:${NODE_GID} 挂载目录"
        log_error "  >> 如果启用了 SELinux, 尝试在挂载的 volumes 路径后加 :z"
        exit 1
    fi
fi

# ==============================================================================
# --- jq Configuration Builder ---
# ==============================================================================

# 1. 基础骨架构建或检查
if [ ! -f "$CONFIG_FILE" ]; then
    log_info "配置文件不存在，使用 jq 构建基础骨架..."
    # 构造基础骨架，并通过 jq 将其格式化输出
    jq -n '
{
  "meta": { "lastTouchedVersion": "2026.2.14" },
  "update": { "checkOnStart": false },
  "browser": {
    "headless": true,
    "noSandbox": true,
    "defaultProfile": "openclaw",
    "executablePath": "/usr/bin/chromium"
  },
  "models": { "mode": "merge", "providers": { "default": { "models": [] } } },
  "agents": {
    "defaults": {
      "compaction": { "mode": "safeguard" },
      "elevatedDefault": "full",
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 },
      "workspace": "'"$APP_WORKSPACE"'",
      "model": { "primary": "default/gpt-5-nano" },
      "imageModel": { "primary": "default/gpt-5-nano" }
    }
  },
  "messages": { "ackReactionScope": "group-mentions", "tts": { "edge": { "voice": "zh-CN-XiaoxiaoNeural" } } },
  "commands": { "native": "auto", "nativeSkills": "auto" },
  "channels": {},
  "plugins": { "entries": {}, "installs": {}, "allow": [] }
}
' > "$CONFIG_FILE"
fi

# 从现有配置加载状态以便用 jq 在内存中更新
tmp_file=$(mktemp)

# ==============================================================================
# 2.大模型提供商(Provider)与模型(Model)同步
# ==============================================================================
LLM_SYNC=${LLM_AUTO_SYNC:-true}
if [[ "${LLM_SYNC,,}" == "true" || "$LLM_SYNC" == "1" ]]; then
    log_info "同步大模型配置..."

    MID="${LLM_PRIMARY_MODEL:-gpt-5-nano}"
    # jq 处理 default provider
    if [[ -n "$LLM_API_KEY" || -n "$LLM_BASE_URL" ]]; then
        jq --arg key "${LLM_API_KEY:-}" \
           --arg url "${LLM_BASE_URL:-}" \
           --arg proto "${LLM_API_FORMAT:-openai-completions}" \
           --arg cw "${LLM_CTX_WINDOW:-200000}" \
           --arg mt "${LLM_MAX_TOKENS:-8192}" \
           --arg mid "$MID" \
        '
        .models.providers.default as $p
        | .models.providers.default = ($p + {
            "api": $proto,
            "apiKey": (if $key != "" then $key else $p.apiKey end),
            "baseUrl": (if $url != "" then $url else $p.baseUrl end),
            "models": (
              if ($p.models | type == "array") then
                # 先过滤掉与新模型ID同名的（如果有），再追加
                ($p.models | map(select(.id != $mid))) + [{
                   "id": $mid,
                   "name": $mid,
                   "reasoning": false,
                   "input": ["text", "image"],
                   "cost": {"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
                   "contextWindow": ($cw | tonumber),
                   "maxTokens": ($mt | tonumber)
                }]
              else
                [{
                   "id": $mid,
                   "name": $mid,
                   "reasoning": false,
                   "input": ["text", "image"],
                   "cost": {"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
                   "contextWindow": ($cw | tonumber),
                   "maxTokens": ($mt | tonumber)
                }]
              end
            )
        })
        ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"

        # Provider 3 (Google Gemini 示例)
        if [[ -n "$GEMINI_API_KEY" || -n "$LLM_THIRD_API_KEY" ]]; then
            jq --arg key "${GEMINI_API_KEY:-$LLM_THIRD_API_KEY}" \
               --arg url "${LLM_THIRD_BASE_URL:-}" \
               --arg proto "${LLM_THIRD_PROTOCOL:-google-gemini-api}" \
               --arg cw "${LLM_THIRD_CONTEXT_WINDOW:-2000000}" \
               --arg mt "${LLM_THIRD_MAX_TOKENS:-8192}" \
               --arg mid "${LLM_THIRD_MODEL_ID:-google/gemini-3.1-flash-lite-preview}" \
               --arg pname "${LLM_THIRD_NAME:-google}" \
            '
            .models.providers[$pname] as $p
            | .models.providers[$pname] = (($p // {}) + {
                "api": $proto,
                "apiKey": (if $key != "" then $key else ($p.apiKey // "") end),
                "baseUrl": (if $url != "" then $url else ($p.baseUrl // "") end),
                "models": (
                  if ($p.models | type == "array") then
                    ($p.models | map(select(.id != $mid))) + [{
                       "id": $mid,
                       "name": $mid,
                       "reasoning": false,
                       "input": ["text", "image"],
                       "cost": {"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
                       "contextWindow": ($cw | tonumber),
                       "maxTokens": ($mt | tonumber)
                    }]
                  else
                    [{
                       "id": $mid,
                       "name": $mid,
                       "reasoning": false,
                       "input": ["text", "image"],
                       "cost": {"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
                       "contextWindow": ($cw | tonumber),
                       "maxTokens": ($mt | tonumber)
                    }]
                  end
                )
            }) | del(.models.providers[$pname].baseUrl | select(. == ""))
            ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
            log_success "已配置提供商: ${LLM_THIRD_NAME:-google} (Google Gemini等)"
        fi

        # 处理主模型路由
        FQ_MID=$MID
        if [[ "$FQ_MID" != */* ]]; then FQ_MID="default/$FQ_MID"; fi

        IMID="${LLM_VISION_MODEL:-$MID}"
        FQ_IMID=$IMID
        if [[ "$FQ_IMID" != */* ]]; then FQ_IMID="default/$FQ_IMID"; fi

        jq --arg p_mid "$FQ_MID" --arg p_imid "$FQ_IMID" \
           '.agents.defaults.model.primary = $p_mid | .agents.defaults.imageModel.primary = $p_imid' \
           "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
        
        log_success "默认提供商同步完毕. 主模型={ $FQ_MID }"
    fi
else
    log_warn "大模型配置同步已跳过 (LLM_AUTO_SYNC=${LLM_SYNC})"
fi

# ==============================================================================
# 3. IM 渠道(Channels)与插件同步
# ==============================================================================
# 提取插件启用状态，供后续写入 'allow' 数组
declare -A PLUGINS_ENABLE_MAP

# 工具函数：生成当前 UTC ISO时间字符串用于安装时间记录
get_utc_now() { date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"; }
UTC_NOW="$(get_utc_now)"

# 全局启用或禁用插件系统
if [[ -n "$OPENCLAW_PLUGINS_ENABLED" ]]; then
    enable_plugins="false"
    [[ "${OPENCLAW_PLUGINS_ENABLED,,}" == "true" ]] && enable_plugins="true"
    jq --argjson ep "$enable_plugins" '.plugins.enabled = $ep' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
fi

# ---- 3.1 Telegram ----
if [[ -n "$BOT_TELEGRAM_TOKEN" ]]; then
    jq --arg token "$BOT_TELEGRAM_TOKEN" \
       '.channels.telegram = {
          "botToken": $token, "dmPolicy": "pairing", "groupPolicy": "allowlist", "streamMode": "partial"
        }' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    
    jq '.plugins.entries.telegram = {"enabled": true}' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    PLUGINS_ENABLE_MAP["telegram"]=1
    log_success "已配置: Telegram"
fi

# ---- 3.2 飞书 (Feishu) ----
if [[ -n "$BOT_FEISHU_APP_ID" && -n "$BOT_FEISHU_SECRET" ]]; then
    jq --arg id "$BOT_FEISHU_APP_ID" --arg sec "$BOT_FEISHU_SECRET" \
       --arg name "${BOT_FEISHU_BOT_NAME:-OpenClaw Bot}" \
       --arg domain "${BOT_FEISHU_DOMAIN:-}" \
       '
       .channels.feishu = {
         "enabled": true, "dmPolicy": "pairing", "groupPolicy": "open",
         "accounts": {
           "default": ({ "appId": $id, "appSecret": $sec, "botName": $name } + (if $domain!="" then {"domain":$domain} else {} end))
         }
       }' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    
    jq --arg now "$UTC_NOW" '
       .plugins.entries.feishu = {"enabled": true} |
       (if .plugins.installs.feishu == null then
          .plugins.installs.feishu = {"source":"npm", "spec":"@openclaw/feishu", "installPath":"/home/node/.openclaw/extensions/feishu", "installedAt": $now}
        else . end)
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    PLUGINS_ENABLE_MAP["feishu"]=1
    log_success "已配置: 飞书"
fi

# ---- 3.3 钉钉 (Dingtalk) ----
if [[ -n "$BOT_DING_CLIENT_ID" && -n "$BOT_DING_SECRET" ]]; then
    jq --arg id "$BOT_DING_CLIENT_ID" --arg sec "$BOT_DING_SECRET" \
       --arg code "${BOT_DING_ROBOT_CODE:-$BOT_DING_CLIENT_ID}" \
       --arg corp "${BOT_DING_CORP_ID:-}" \
       --arg agent "${BOT_DING_AGENT_ID:-}" \
       '
       .channels.dingtalk = {
         "enabled": true, "clientId": $id, "clientSecret": $sec, "robotCode": $code,
         "dmPolicy": "open", "groupPolicy": "open", "messageType": "markdown", "allowFrom": ["*"],
         "corpId": (if $corp!="" then $corp else null end),
         "agentId": (if $agent!="" then $agent else null end)
       } | del(.channels.dingtalk.corpId | nulls) | del(.channels.dingtalk.agentId | nulls)' \
       "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"

    jq --arg now "$UTC_NOW" '
       .plugins.entries.dingtalk = {"enabled": true} |
       (if .plugins.installs.dingtalk == null then
          .plugins.installs.dingtalk = {"source":"npm", "spec":"https://github.com/soimy/clawdbot-channel-dingtalk.git", "installPath":"/home/node/.openclaw/extensions/dingtalk", "installedAt": $now}
        else . end)
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    PLUGINS_ENABLE_MAP["dingtalk"]=1
    log_success "已配置: 钉钉"
fi

# ---- 3.4 QQ (Napcat & qqbot) ----
# 如果配置了 Napcat
if [[ -n "$BOT_NAPCAT_WS_PORT" ]]; then
    jq --arg port "$BOT_NAPCAT_WS_PORT" \
       --arg url "${BOT_NAPCAT_HTTP_URL:-}" \
       --arg acc_t "${BOT_NAPCAT_ACCESS_TOKEN:-}" \
       --arg admin_str "${BOT_NAPCAT_ADMINS:-}" \
       '
       .channels.napcat = {
          "enabled": true, "reverseWsPort": ($port|tonumber), "requireMention": true, "rateLimitMs": 1000,
          "httpUrl": (if $url!="" then $url else null end),
          "accessToken": (if $acc_t!="" then $acc_t else null end),
          "admins": (if $admin_str!="" then ($admin_str | split(",") | map(tonumber? | select(. != null))) else null end)
       } | del(.channels.napcat.httpUrl | nulls) | del(.channels.napcat.accessToken | nulls) | del(.channels.napcat.admins | nulls)' \
       "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"

    jq --arg now "$UTC_NOW" '
       .plugins.entries.napcat = {"enabled": true} |
       (if .plugins.installs.napcat == null then
          .plugins.installs.napcat = {"source":"path", "sourcePath":"/home/node/.openclaw/extensions/napcat", "installPath":"/home/node/.openclaw/extensions/napcat", "installedAt": $now}
        else . end)
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    PLUGINS_ENABLE_MAP["napcat"]=1
    log_success "已配置: QQ (Napcat)"
# 备用旧版 qqbot
elif [[ -n "$BOT_QQ_APP_ID" && -n "$BOT_QQ_SECRET" ]]; then
    jq --arg id "$BOT_QQ_APP_ID" --arg sec "$BOT_QQ_SECRET" \
       '.channels.qqbot = { "enabled": true, "appId": $id, "clientSecret": $sec }' \
       "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    
       jq --arg now "$UTC_NOW" '
       .plugins.entries.qqbot = {"enabled": true} |
       (if .plugins.installs.qqbot == null then
          .plugins.installs.qqbot = {"source":"path", "sourcePath":"/home/node/.openclaw/qqbot", "installPath":"/home/node/.openclaw/extensions/qqbot", "installedAt": $now}
        else . end)
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    PLUGINS_ENABLE_MAP["qqbot"]=1
    log_success "已配置: QQ (旧版 qqbot)"
fi

# ---- 3.5 企业微信 (WeCom) ----
wecom_configured=0
# 3.5.1 旧版本多账号/复杂配置支持 (基于 JSON 字符串合并)
if [[ -n "$BOT_WECOM_MULTI_JSON" ]]; then
    log_info "发现 BOT_WECOM_MULTI_JSON，尝试合并企业微信多账号..."
    if jq -e . >/dev/null 2>&1 <<<"$BOT_WECOM_MULTI_JSON"; then
        jq --argjson wecom_obj "$BOT_WECOM_MULTI_JSON" \
           '.channels.wecom = (.channels.wecom // {}) * $wecom_obj * {
              "enabled": true, "commands": {"enabled":true, "allowlist":["/new","/status","/help","/compact"]}
            }' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
        wecom_configured=1
        log_success "已导入: 企业微信多账号配置 (JSON)"
    else
        log_error "解析 BOT_WECOM_MULTI_JSON 失败，不是合法的 JSON 字符串"
    fi
fi

# 3.5.2 标准单账号覆盖
if [[ -n "$BOT_WECOM_TOKEN" && -n "$BOT_WECOM_AES_KEY" ]]; then
    jq --arg token "$BOT_WECOM_TOKEN" --arg aes "$BOT_WECOM_AES_KEY" \
       '.channels.wecom = (.channels.wecom // {}) * {
          "enabled": true,
          "default": { "token": $token, "encodingAesKey": $aes },
          "commands": { "enabled": true, "allowlist": ["/new","/status","/help","/compact"] }
       } | del(.channels.wecom.token) | del(.channels.wecom.encodingAesKey)' \
       "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    wecom_configured=1
    log_success "已配置: 企业微信单账号"
fi

if [[ $wecom_configured -eq 1 ]]; then
    jq --arg now "$UTC_NOW" '
       .plugins.entries.wecom = {"enabled": true} |
       (if .plugins.installs.wecom == null then
          .plugins.installs.wecom = {"source":"npm", "spec":"@sunnoy/wecom", "installPath":"/home/node/.openclaw/extensions/wecom", "installedAt": $now}
        else . end)
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    PLUGINS_ENABLE_MAP["wecom"]=1
fi

# ---- 合并激活的插件白名单 (allow) ----
ALLOW_ARRAY=$(printf '%s\n' "${!PLUGINS_ENABLE_MAP[@]}" | jq -R . | jq -s .)
if [[ "$ALLOW_ARRAY" != "[]" ]]; then
    jq --argjson arr "$ALLOW_ARRAY" '.plugins.allow = $arr' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    log_info "已激活的插件: $(echo ${!PLUGINS_ENABLE_MAP[@]})"
fi

# ==============================================================================
# 4. Gateway 网关与高级配置
# ==============================================================================
if [[ -n "$OPENCLAW_GATEWAY_TOKEN" ]]; then
    jq --arg port "${OPENCLAW_GATEWAY_PORT:-18789}" \
       --arg bind "${OPENCLAW_GATEWAY_BIND:-0.0.0.0}" \
       --arg mode "${OPENCLAW_GATEWAY_MODE:-local}" \
       --arg token "$OPENCLAW_GATEWAY_TOKEN" \
       --arg amode "${OPENCLAW_GATEWAY_AUTH_MODE:-token}" \
       --arg insecure "${OPENCLAW_GATEWAY_ALLOW_INSECURE_AUTH:-true}" \
       --arg disable_device "${OPENCLAW_GATEWAY_DANGEROUSLY_DISABLE_DEVICE_AUTH:-true}" \
       --arg origins "${OPENCLAW_GATEWAY_ALLOWED_ORIGINS:-}" \
       '
       .gateway = (.gateway // {}) * {
          "port": ($port|tonumber), "bind": $bind, "mode": $mode,
          "auth": { "mode": $amode, "token": $token },
          "controlUi": {
            "allowInsecureAuth": (if $insecure | ascii_downcase == "true" then true else false end),
            "dangerouslyDisableDeviceAuth": (if $disable_device | ascii_downcase == "true" then true else false end)
          } 
       } | (if $origins!="" then 
              .gateway.controlUi.allowedOrigins = ($origins | split(",") | map(sub("^\\s+";"") | sub("\\s+$";""))) 
            else . end)
       ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    log_success "网关代理 (Gateway) 配置已刷新."
fi

# ==============================================================================
# 4.5. OpenViking Memory Integration
# ==============================================================================
PLUGIN_DEST="/home/node/.openclaw/extensions/memory-openviking"
if [ ! -f "${PLUGIN_DEST}/package.json" ]; then
    log_info "正在下载 memory-openviking 插件..."
    mkdir -p "${PLUGIN_DEST}"
    REPO="volcengine/OpenViking"
    BRANCH="main"
    gh_raw="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
    files=(
        "index.ts" "config.ts" "client.ts" "process-manager.ts"
        "memory-ranking.ts" "text-utils.ts" "openclaw.plugin.json"
        "package.json" "package-lock.json" "tsconfig.json"
    )
    for name in "${files[@]}"; do
        curl -fsSL --connect-timeout 15 -o "${PLUGIN_DEST}/${name}" "${gh_raw}/examples/openclaw-memory-plugin/${name}" || true
    done
    echo "node_modules/" > "${PLUGIN_DEST}/.gitignore"
    log_info "正在安装 memory-openviking 依赖..."
    (cd "${PLUGIN_DEST}" && npm install --no-audit --no-fund --omit=dev || true)
fi

# 禁用原生 memory-core (qmd) 及移除老旧的 memory 配置
jq '.plugins.entries["memory-core"] = {"enabled": false} | del(.memory)' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"

# 启用 OpenViking 插件 (使用 path 源) 并设为默认记忆后端
jq --arg now "$UTC_NOW" '
   .plugins.entries["memory-openviking"] = {
     "enabled": true,
     "config": {
       "mode": "remote",
       "baseUrl": "http://openviking:1933",
       "apiKey": "openclaw-secret"
     }
   } |
   .plugins.installs["memory-openviking"] = {
     "source": "path",
     "sourcePath": "/home/node/.openclaw/extensions/memory-openviking",
     "installPath": "/home/node/.openclaw/extensions/memory-openviking",
     "installedAt": $now
   } |
   .plugins.slots.memory = "memory-openviking" |
   del(.agents.defaults.memory) |
   (if (.plugins.allow | index("memory-openviking") == null) then .plugins.allow += ["memory-openviking"] else . end)
' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"

# 将 memory-openviking 添加到 allow 列表
jq 'if (.plugins.allow | index("memory-openviking") == null) then .plugins.allow += ["memory-openviking"] else . end' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
# 移除 memory-core 从 allow 列表 (防止被加载)
jq '.plugins.allow = [.plugins.allow[] | select(. != "memory-core")]' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"

log_success "已配置: OpenViking 长程记忆插件并禁用原生 qmd"

# 记录更新时间戳并保存
jq --arg now "$UTC_NOW" '.meta.lastTouchedAt = $now' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
rm -f "$tmp_file"

# ==============================================================================
# 5. 二次权限修复与服务启动
# ==============================================================================
if [ "$(id -u)" -eq 0 ]; then
    chown -R node:node "$APP_DATA_DIR" || true
fi

log_info "=== Kirklin's openclaw-pack 初始化完毕 ==="

# 暴露 Bun
export BUN_INSTALL="/usr/local"
export PATH="$BUN_INSTALL/bin:$PATH"
export DBUS_SESSION_BUS_ADDRESS=/dev/null

cleanup() {
    log_warn "接收到停止信号, 正在安全关闭 OpenClaw Gateway..."
    if [ -n "$GATEWAY_PID" ]; then
        kill -TERM "$GATEWAY_PID" 2>/dev/null || true
        wait "$GATEWAY_PID" 2>/dev/null || true
    fi
    log_success "服务已停止"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

log_info "=> [启动容器主进程] OpenClaw Gateway <="
log_info "网关将在端口 [${OPENCLAW_GATEWAY_PORT:-18789}] 上监听 [${OPENCLAW_GATEWAY_BIND:-0.0.0.0}]"
echo ""

# 使用 gosu 进行降权，用 node 用户跑网关应用
gosu node env HOME=/home/node DBUS_SESSION_BUS_ADDRESS=/dev/null \
    BUN_INSTALL="/usr/local" PATH="/usr/local/bin:$PATH" \
    openclaw gateway run \
    --bind "${OPENCLAW_GATEWAY_BIND:-lan}" \
    --port "${OPENCLAW_GATEWAY_PORT:-18789}" \
    --token "${OPENCLAW_GATEWAY_TOKEN:-}" \
    --verbose &
GATEWAY_PID=$!

wait "$GATEWAY_PID"
EXIT_CODE=$?

log_error "=> OpenClaw Gateway 已异常退出 (退出码: $EXIT_CODE) <="
exit $EXIT_CODE
