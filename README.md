# Kirklin's openclaw-pack

> **极简、专业、开箱即用的 OpenClaw 聚合网关环境**。本项目将原本分散的四大国产 IM 插件（飞书、钉钉、QQ、企业微信）深度打包整合。只需一行命令，即可获得全功能的聊天机器人网关能力。

## 项目简介

`openclaw-pack` 是一个基于强大开源框架 [OpenClaw](https://github.com/openclaw/openclaw) 构建的 Docker 镜像。

### 核心特性

- **聚合集成**：免配置，直接内置飞书、钉钉、QQ 机器人、企业微信四大国内主流 IM 平台通道。
- **专业规范体系**：环境变量经过高度抽象归类。无论是大模型的 `LLM_BASE_URL` 或者是企微的多设备并发，一目了然。
- **专业日志审计**：初始化环节拥有清晰的日志输出（`INFO`/`WARN`/`ERROR`/`SUCCESS`），一眼排错。
- **自动权限修复**：启动自检数据卷 `UID:GID` 权限冲突，后台主动修复后再安全降权启动服务，彻底告别 `Permission Denied`。

---

## 快速开始

### 1. 准备配置

下载配置文件与示例变量：

```bash
wget https://raw.githubusercontent.com/kirklin/openclaw-pack/main/compose.yaml
wget https://raw.githubusercontent.com/kirklin/openclaw-pack/main/.env.example
```

### 2. 配置环境变量

```bash
cp .env.example .env
nano .env
```

**最核心 AI 后端配置示例**（至少需要指定大模型，国内 IM 通道为按需填写）：

| 环境变量            | 说明                                  | 示例值                      |
| ------------------- | ------------------------------------- | --------------------------- |
| `LLM_PRIMARY_MODEL` | 你的模型名称（如 gpt-5-nano） | `gpt-5-nano`                    |
| `LLM_BASE_URL`      | 大模型或中转平台的接口地址            | `https://api.openai.com/v1` |
| `LLM_API_KEY`       | 对接平台的 API 密钥                   | `sk-xxxxxx`                 |

如果您需要对接**飞书**，只需额外补充：
| 环境变量 | 说明 |
|---------|------|
| `BOT_FEISHU_APP_ID` | 飞书应用 APP ID |
| `BOT_FEISHU_SECRET` | 飞书应用凭证 |

### 3. 一键起飞

> **⚠️ 注意：** 强烈建议使用 `docker compose` 启动本项目，而不是直接使用 `docker run`。直接使用 `docker run` 无法自动加载 `.env` 文件中的配置（如 `GEMINI_API_KEY` 等），除非你手动用 `-e` 注入所有变量。

```bash
docker compose up -d
```

### 4. 查阅专业日志

```bash
docker compose logs -f openclaw-pack
```

> **示例输出：**
> <br/>[INFO] === Kirklin's openclaw-pack 初始化 ===
> <br/>[INFO] 同步大模型配置...
> <br/>[SUCCESS] 默认提供商同步完毕. 主模型={ default/gpt-5-nano }
> <br/>[SUCCESS] 已配置: 飞书
> <br/>[SUCCESS] 已配置: 企业微信多账号配置 (JSON)
> <br/>[SUCCESS] 网关代理 (Gateway) 配置已刷新.

---

## 高级用法：企业微信多账号 (Multi-Bot) 集成

支持利用纯 `jq` 在 JSON 层进行深度的对象合并。只需在 `.env` 中添加一条紧凑的 JSON 即可：

```bash
BOT_WECOM_MULTI_JSON={"bot_support":{"token":"T1","encodingAesKey":"K1","agent":{"corpId":"wxXXXXX","corpSecret":"S1","agentId":1001}}}
```

启动后容器将自动分发路由至不同应用通道，消息彻底隔离！

---

## 🤖 IM 平台接入指南

以下是各大 IM 平台对接机器人所需的简单环境变量配置步骤。容器会在下次启动时自动生效。

<details>
<summary><b>飞书 (Feishu/Lark) 接入全指南</b></summary>

### 1. 飞书开放平台准备
1. 访问 [飞书开放平台](https://open.feishu.cn/) 并登录。如果是 Lark (国际版) 租户，请使用 [Lark Open Platform](https://open.larksuite.com/app)。
2. **创建自建应用**: 点击“创建企业自建应用”，填写应用名称。
3. **获取凭证**: 在“凭证与基础信息”中获取 `App ID` 和 `App Secret`。

### 2. 权限申请 (必需项)
在“权限管理”中勾选并批量申请以下核心权限：
- `im:message` (接收发送消息)
- `im:message.p2p_msg:readonly` (读取私聊消息)
- `im:message.group_at_msg:readonly` (接收群聊 @ 消息)
- `im:message:send_as_bot` (以机器人身份发送消息)
- `im:resource` (图片与资源上传下载)
- `contact:user.employee_id:readonly` (获取员工 ID)

### 3. 应用能力开通
- 进入“应用能力” -> “机器人”，启用机器人功能，并设置机器人的名称。

### 4. 事件订阅 (核心)
在“事件与回调”页面中：
1. **配置方式**: 必须选择 **“使用长连接接收事件”** (WebSocket 模式)。
2. **添加事件**: 搜索并添加 `im.message.receive_v1` (接收消息)。 
   > 注意：如果容器内的网关未运行，保存长连接配置可能会报错。请确保 `docker compose up` 已经在后台运行。

### 5. 版本发布
在“版本管理与发布”中，点击“创建版本”，填入版本号后提交审核，并等待应用发布成功。

### 6. 环境变量配置 (`.env`)
```bash
BOT_FEISHU_APP_ID=cli_xxxxxxxxxx
BOT_FEISHU_SECRET=yyyyyyyyyyyyyy
```

> 💡 **参考手册**：关于更详尽的权限配置 JSON、多账号高级配置示例，请参考官方插件文档：[OpenClaw Feishu Plugin Docs](https://github.com/openclaw/openclaw/blob/main/docs/channels/feishu.md)。

</details>

<details>
<summary><b>钉钉 (DingTalk) 机器人配置</b></summary>

### 1. 简要配置环境变量 (`.env`)
```bash
BOT_DING_CLIENT_ID=ding_xxxxxxxxxx
BOT_DING_SECRET=xxxxxxxxxxxxxxxxxxxx
BOT_DING_ROBOT_CODE=ding_xxxxxxxxxx  # 通常与 Client ID 相同
BOT_DING_CORP_ID=ding_xxxxxxxxxxxx   # 你的钉钉企业 ID
BOT_DING_AGENT_ID=123456789          # 应用的 Agent ID
```

> 💡 **详细文档**：关于如何在钉钉开放平台创建机器人、切换 Stream 接收模式，以及高级卡片消息发送等更多细节，请参考插件原始仓库：[clawdbot-channel-dingtalk](https://github.com/soimy/clawdbot-channel-dingtalk)。

</details>

<details>
<summary><b>QQ / Napcat 接入指南</b></summary>

如果你使用的是 QQ 官方开放平台，填写下面两项：
```bash
QQBOT_APP_ID=100000xxx
QQBOT_CLIENT_SECRET=xxxxxxxxxxxxxx
```

> 💡 **详细文档**：QQ 官方接口的最新策略要求与进阶使用方法，请参考插件原始仓库：[qqbot](https://github.com/sliverp/qqbot)。

</details>

<details>
<summary><b>企业微信 (WeCom) 单账号配置</b></summary>

### 1. 简要配置环境变量 (`.env`)
```bash
WECOM_TOKEN=你的Token
WECOM_ENCODING_AES_KEY=你的EncodingAESKeyxxxxxxxxxx
```
*填写完毕后，会自动映射为内部的 `default` 机器人账号。*

> 💡 **详细图文教程**：企业微信的 Token 配置较为复杂，牵扯到 API 验证和地址填写。关于企业微信后台的确切配置步骤、接收回调 URL 服务器验证，以及高级群组拦截和并发配置，强烈建议参考原始插件文档：[openclaw-plugin-wecom](https://github.com/sunnoy/openclaw-plugin-wecom)。

</details>

---
