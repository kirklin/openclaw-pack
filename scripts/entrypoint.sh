#!/bin/bash

# ==============================================================================
# Kirklin's openclaw-pack Init Script
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

# --- Workspace Initialization & Overwrite ---
# 如果 OVERWRITE_WORKSPACE 为 true (默认)，则从模板覆盖
OVERWRITE_WS="${OVERWRITE_WORKSPACE:-true}"
WORKSPACE_TEMPLATE="/home/node/workspace-template"
INIT_MARKER="$APP_DATA_DIR/.workspace_initialized"

if [ ! -f "$INIT_MARKER" ] || [[ "${OVERWRITE_WS,,}" == "force" ]]; then
    if [[ "${OVERWRITE_WS,,}" == "true" || "$OVERWRITE_WS" == "1" || "${OVERWRITE_WS,,}" == "force" ]]; then
        if [ -d "$WORKSPACE_TEMPLATE" ]; then
            log_info "正在初始化/检测到强制覆盖，同步工作区内容 ($APP_WORKSPACE)..."
            # 使用 cp -rf 覆盖，但也保留可能存在的 git 目录（如果用户映射了自己的 git 库）
            cp -rf "$WORKSPACE_TEMPLATE"/. "$APP_WORKSPACE/"
            touch "$INIT_MARKER"
            log_success "工作区内容同步完成"
        else
            log_warn "未发现工作区模板目录: $WORKSPACE_TEMPLATE"
        fi
    fi
else
    log_info "工作区已存在初始化标记，跳过自动覆盖 (如欲强制同步请设置环境变量 OVERWRITE_WORKSPACE=force)"
fi

# --- 同步预装插件（Docker 构建时以 root 身份安装到 /root/.openclaw） ---
if [ -d "/root/.openclaw/npm" ] && [ ! -d "$APP_DATA_DIR/npm" ]; then
    log_info "同步预装插件到用户目录..."
    cp -r /root/.openclaw/npm "$APP_DATA_DIR/npm"
    chown -R node:node "$APP_DATA_DIR/npm" || true
    log_success "预装插件同步完成"
fi

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
  "meta": { "lastTouchedVersion": "2026.5.7" },
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
  "messages": { "ackReactionScope": "group-mentions" },
  "commands": { "native": "auto", "nativeSkills": "auto" },
  "tools": { "profile": "full", "allow": ["*"], "deny": [], "sessions": { "visibility": "all" } },
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

# ---- 3.2 飞书 (Feishu) ----
if [[ -n "$BOT_FEISHU_APP_ID" && -n "$BOT_FEISHU_SECRET" ]]; then
    jq --arg id "$BOT_FEISHU_APP_ID" --arg sec "$BOT_FEISHU_SECRET" \
       --arg name "${BOT_FEISHU_BOT_NAME:-OpenClaw Bot}" \
       --arg domain "${BOT_FEISHU_DOMAIN:-feishu}" \
       --arg mode "${BOT_FEISHU_CONNECTION_MODE:-websocket}" \
       --arg streaming "${BOT_FEISHU_STREAMING:-true}" \
       --arg dm "${BOT_FEISHU_DM_POLICY:-pairing}" \
       --arg group "${BOT_FEISHU_GROUP_POLICY:-open}" \
       --arg typing "${BOT_FEISHU_TYPING_INDICATOR:-true}" \
       --arg resolve "${BOT_FEISHU_RESOLVE_NAMES:-true}" \
       '
       .channels.feishu = (.channels.feishu // {}) * {
         "enabled": true,
         "domain": $domain,
         "connectionMode": $mode,
         "streaming": ($streaming | ascii_downcase == "true"),
         "dmPolicy": $dm,
         "groupPolicy": $group,
         "typingIndicator": ($typing | ascii_downcase == "true"),
         "resolveSenderNames": ($resolve | ascii_downcase == "true"),
         "accounts": {
           "default": { "appId": $id, "appSecret": $sec, "name": $name }
         }
       }' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    
    jq --arg now "$UTC_NOW" '
       .plugins.entries.feishu = {"enabled": true} |
       (if .plugins.installs.feishu == null then
          .plugins.installs.feishu = {"source":"npm", "spec":"@openclaw/feishu", "installPath":"/home/node/.openclaw/extensions/feishu", "installedAt": $now}
        else . end)
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    PLUGINS_ENABLE_MAP["feishu"]=1
    log_success "已配置: 飞书 (Mode: ${BOT_FEISHU_CONNECTION_MODE:-websocket})"
fi

# ---- 合并激活的插件白名单 (allow) ----
ALLOW_ARRAY=$(printf '%s\n' "${!PLUGINS_ENABLE_MAP[@]}" | jq -R . | jq -s .)
if [[ "$ALLOW_ARRAY" != "[]" ]]; then
    jq --argjson arr "$ALLOW_ARRAY" '.plugins.allow = $arr' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
    log_info "已激活的插件: $(echo ${!PLUGINS_ENABLE_MAP[@]})"
fi

# ==============================================================================
# 4. Tools 工具策略配置
# ==============================================================================
# 控制 Agent 可使用的工具集。默认策略：
#   profile=coding (fs/runtime/sessions/memory) + browser + group:web + image
#   deny canvas/nodes（容器内无 Canvas/macOS 节点）
#   loopDetection 开启，防止 Agent 死循环
TOOLS_PROFILE="${OPENCLAW_TOOLS_PROFILE:-full}"

# 构建 allow 数组（从环境变量 OPENCLAW_TOOLS_ALLOW 解析逗号分隔列表，默认内置）
TOOLS_ALLOW_DEFAULT='["*"]'
if [[ -n "$OPENCLAW_TOOLS_ALLOW" ]]; then
    TOOLS_ALLOW=$(echo "$OPENCLAW_TOOLS_ALLOW" | tr ',' '\n' | jq -Rsc 'split("\n") | map(select(length>0))')
else
    TOOLS_ALLOW="$TOOLS_ALLOW_DEFAULT"
fi

# 构建 deny 数组（默认禁用 canvas/nodes，可通过 OPENCLAW_TOOLS_DENY 覆盖）
TOOLS_DENY_DEFAULT='["canvas","nodes"]'
if [[ -n "$OPENCLAW_TOOLS_DENY" ]]; then
    TOOLS_DENY=$(echo "$OPENCLAW_TOOLS_DENY" | tr ',' '\n' | jq -Rsc 'split("\n") | map(select(length>0))')
else
    TOOLS_DENY="$TOOLS_DENY_DEFAULT"
fi

# Session 可见性配置
SESSIONS_VISIBILITY="${OPENCLAW_SESSIONS_VISIBILITY:-all}"

# loopDetection 开关（默认 true）
LOOP_DETECTION="${OPENCLAW_TOOLS_LOOP_DETECTION:-true}"

jq --arg profile "$TOOLS_PROFILE" \
   --argjson allow  "$TOOLS_ALLOW" \
   --argjson deny   "$TOOLS_DENY" \
   --arg visibility "$SESSIONS_VISIBILITY" \
   --argjson loopEnabled "$LOOP_DETECTION" \
   '
   .tools = (.tools // {}) * {
     "profile": $profile,
     "allow":   $allow,
     "deny":    $deny,
     "sessions": {
       "visibility": $visibility
     },
     "loopDetection": {
       "enabled":                      $loopEnabled,
       "warningThreshold":             10,
       "criticalThreshold":            20,
       "globalCircuitBreakerThreshold": 30,
       "historySize":                  30,
       "detectors": {
         "genericRepeat":        true,
         "knownPollNoProgress":  true,
         "pingPong":             true
       }
     }
   } | del(.sessions)
   ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
log_success "工具与会话策略已配置: profile=${TOOLS_PROFILE}, deny=${TOOLS_DENY}, visibility=${SESSIONS_VISIBILITY}"

# ==============================================================================
# 5. Gateway 网关与高级配置
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

# 记录更新时间戳并保存
jq --arg now "$UTC_NOW" '.meta.lastTouchedAt = $now' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
rm -f "$tmp_file"

# ==============================================================================
# 6. 二次权限修复与服务启动
# ==============================================================================
if [ "$(id -u)" -eq 0 ]; then
    # 核心数据卷归 node 用户所有，确保可以写入会话、凭证等
    chown -R node:node "$APP_DATA_DIR" || true
    # 插件目录归 root 所有，以通过 OpenClaw 的 "suspicious ownership" 安全检查
    if [ -d "$APP_DATA_DIR/extensions" ]; then
        chown -R root:root "$APP_DATA_DIR/extensions" || true
    fi
fi

log_info "=== Kirklin's openclaw-pack 初始化完毕 ==="

export DBUS_SESSION_BUS_ADDRESS=/dev/null
export OPENCLAW_ALLOW_ROOT=1

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
