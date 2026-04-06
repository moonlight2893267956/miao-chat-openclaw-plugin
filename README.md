# openclaw-miao-gateway

Miao Chat 的 OpenClaw 插件版网关客户端。

目标：任意一台机器装上插件并配置好 `wsUrl + channelId` 后，只要 OpenClaw 进程启动，插件就会自动连接后端网关、发心跳、接收 `invoke.start` 并调用本机 OpenClaw 生成回复。服务端维护在线渠道列表，App 新建会话时选择其中一个渠道并绑定。

## 目录

- `openclaw.plugin.json`: 插件元数据与配置 Schema
- `index.js`: 插件入口，注册后台 service
- `src/gateway-client.js`: WebSocket register/heartbeat/reconnect
- `src/invoke-handler.js`: 处理 `invoke.start` 并回传 `invoke.chunk/done/error`

### 当前主入口

- `bin/install_plugin_local.sh`: 安装到当前机器的 `~/.openclaw`
- `bin/uninstall_plugin_local.sh`: 卸载本地插件注册
- `bin/deploy_plugin_to_node.sh`: 在目标节点执行插件部署、重启和在线校验
- `bin/sync_and_deploy_plugin_to_node.sh`: 从当前工作机同步代码并远程部署到节点

### 当前验证脚本

- `scripts/verify_channel_online.sh`: 检查指定 `channel_id` 是否注册成功并在线
- `scripts/verify_channel_invoke.sh`: 连续执行 10 次同步调用验证
- `scripts/verify_channel_reconnect.sh`: 重启 OpenClaw 后验证重连恢复时间
- `scripts/verify_channel_longrun.sh`: 长时间稳定性巡检

### 历史脚本

- `scripts/legacy/`: 旧的固定双通道验证脚本，仅用于回溯历史问题

## 快速安装

在仓库根目录执行：

```bash
cd /Users/wuxiangyi/Desktop/project/dev/miao-chat/miao-chat-openclaw-plugin
bash bin/install_plugin_local.sh
```

安装脚本会做三件事：

1. 复制插件目录到 `~/.openclaw/extensions/openclaw-miao-gateway`
2. 在 `~/.openclaw/openclaw.json` 中写入 `plugins.installs/entries/allow`
3. 以交互方式写入 `entries.openclaw-miao-gateway.config`

## 配置说明

安装后，编辑 `~/.openclaw/openclaw.json`：

- `plugins.entries.openclaw-miao-gateway.enabled`: 是否启用插件
- `plugins.entries.openclaw-miao-gateway.config.wsUrl`: 后端网关地址
- `plugins.entries.openclaw-miao-gateway.config.channelId`: 该节点在服务端的唯一渠道标识
- `plugins.entries.openclaw-miao-gateway.config.registerToken`: 后端注册 token
- `plugins.entries.openclaw-miao-gateway.config.deviceId`: 设备标识，可省略，默认由宿主机生成
- `plugins.entries.openclaw-miao-gateway.config.heartbeatIntervalSec`: 心跳间隔，默认 20
- `plugins.entries.openclaw-miao-gateway.config.reconnectMaxSec`: 重连上限，默认 8
- `plugins.entries.openclaw-miao-gateway.config.maxConcurrentInvokes`: 插件并发上限，默认 1
- `plugins.entries.openclaw-miao-gateway.config.queueWaitTimeoutMs`: 请求在队列中最长等待时间，默认 60000ms
- `plugins.entries.openclaw-miao-gateway.config.openclawGatewayUrl`: 本地 OpenClaw 网关地址，默认 `ws://127.0.0.1:18789`
- `plugins.entries.openclaw-miao-gateway.config.openclawSessionKey`: 本地会话 key，默认 `agent:local:main`

最小必填配置只有两项：`wsUrl` + `channelId`。

并发行为说明：

- 当请求并发超过 `maxConcurrentInvokes` 时，插件会进入队列等待，不会立即返回 busy 失败
- 队列超过上限时，返回 `CHANNEL_QUEUE_FULL`
- 单个请求在队列中等待超过 `queueWaitTimeoutMs` 时，返回 `CHANNEL_QUEUE_TIMEOUT`

## 新节点接入

目标：把 `miao-chat-openclaw-plugin` 装到一台新机器后，配置并重启 OpenClaw，即可自动注册到服务端渠道目录。

### 1) 远程同步并部署

```bash
cd /Users/wuxiangyi/Desktop/project/dev/miao-chat/miao-chat-openclaw-plugin
CHANNEL_ID=miao-node-mac-mini \
DEVICE_ID=mac-mini-01 \
bash bin/sync_and_deploy_plugin_to_node.sh
```

可选环境变量：

- `WS_URL`
- `CHANNEL_ID`
- `DEVICE_ID`
- `REGISTER_TOKEN`
- `OPENCLAW_GATEWAY_URL`
- `OPENCLAW_SESSION_KEY`
- `BACKEND_BASE`

### 2) 在线校验

```bash
BACKEND_BASE=http://81.70.216.46:8081 CHANNEL_ID=miao-node-mac-mini \
bash scripts/verify_channel_online.sh
```

### 3) 调用链路校验

```bash
bash scripts/verify_channel_invoke.sh http://81.70.216.46:8081 miao-node-mac-mini
```

### 4) 重连校验

```bash
bash scripts/verify_channel_reconnect.sh http://81.70.216.46:8081 miao-node-mac-mini
```

### 5) 长稳巡检

```bash
bash scripts/verify_channel_longrun.sh http://81.70.216.46:8081 miao-node-mac-mini 1800 30 45000
```

## 卸载

```bash
cd /Users/wuxiangyi/Desktop/project/dev/miao-chat/miao-chat-openclaw-plugin
bash bin/uninstall_plugin_local.sh
```

会从 `openclaw.json` 删除该插件的 `allow/entries/installs`，并删除扩展目录。
