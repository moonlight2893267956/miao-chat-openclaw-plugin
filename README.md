# openclaw-miao-gateway

Miao Chat 的 OpenClaw 插件版网关客户端。

目标：把你之前手动运行的本机 gateway 脚本，内置为 OpenClaw 插件服务。只要 OpenClaw 进程启动，插件就会自动连接后端网关、发心跳、接收 `invoke.start` 并调用本机 OpenClaw 生成回复。

## 目录

- `openclaw.plugin.json`: 插件元数据与配置 Schema
- `index.js`: 插件入口，注册后台 service
- `src/gateway-client.js`: WebSocket register/heartbeat/reconnect
- `src/invoke-handler.js`: 处理 `invoke.start` 并回传 `invoke.chunk/done/error`
- `scripts/install_local_plugin.sh`: 一键安装到 `~/.openclaw`
- `scripts/uninstall_local_plugin.sh`: 卸载本地插件注册

## 快速安装

在仓库根目录执行：

```bash
cd /Users/wuxiangyi/Desktop/project/dev/miao-chat/miao-chat-openclaw-plugin
bash scripts/install_local_plugin.sh
```

安装脚本会做三件事：

1. 复制插件目录到 `~/.openclaw/extensions/openclaw-miao-gateway`
2. 在 `~/.openclaw/openclaw.json` 中写入 `plugins.installs/entries/allow`
3. 以交互方式写入 `entries.openclaw-miao-gateway.config`（可跳过可选项）

## 配置说明

安装后，编辑 `~/.openclaw/openclaw.json`：

- `plugins.entries.openclaw-miao-gateway.enabled`: 是否启用插件
- `plugins.entries.openclaw-miao-gateway.config.wsUrl`: 后端网关地址
- `plugins.entries.openclaw-miao-gateway.config.channelId`: 本机插件唯一标识（建议固定）
- `plugins.entries.openclaw-miao-gateway.config.registerToken`: 后端注册 token（如启用鉴权，可省略）
- `plugins.entries.openclaw-miao-gateway.config.deviceId`: 设备标识（可省略，默认主机名）
- `plugins.entries.openclaw-miao-gateway.config.heartbeatIntervalSec`: 心跳间隔（可省略，默认 20）
- `plugins.entries.openclaw-miao-gateway.config.reconnectMaxSec`: 重连上限（可省略，默认 8）
- `plugins.entries.openclaw-miao-gateway.config.maxConcurrentInvokes`: 插件并发上限（可省略，默认 1）
- `plugins.entries.openclaw-miao-gateway.config.queueWaitTimeoutMs`: 请求在队列中最长等待时间（可省略，默认 60000ms）
- `plugins.entries.openclaw-miao-gateway.config.openclawGatewayUrl`: 本地 OpenClaw 网关地址（可省略，默认 `ws://127.0.0.1:18789`）
- `plugins.entries.openclaw-miao-gateway.config.openclawSessionKey`: 本地会话 key（可省略）

最小必填配置只有两项：`wsUrl` + `channelId`。其它字段都可以省略并使用插件默认值。

并发行为说明：
- 当请求并发超过 `maxConcurrentInvokes` 时，插件会自动进入队列等待，不会立即返回 busy 失败。
- 队列超过上限（当前 100）时，才会返回 `CHANNEL_QUEUE_FULL`。
- 若单个请求在队列里等待超过 `queueWaitTimeoutMs`，会返回 `CHANNEL_QUEUE_TIMEOUT`。

示例见 `config.example.json`。

## 验证

1. 启动后端并确认 `ws/channel-gateway` 可达
2. 启动 OpenClaw
3. 访问后端：

```bash
curl -s http://<backend-host>:8081/api/v1/channel-gateway/status
```

看到你的 `channelId` `online=true` 即接入成功。

## 卸载

```bash
cd /Users/wuxiangyi/Desktop/project/dev/miao-chat/miao-chat-openclaw-plugin
bash scripts/uninstall_local_plugin.sh
```

会从 `openclaw.json` 删除该插件的 `allow/entries/installs`，并删除扩展目录。
