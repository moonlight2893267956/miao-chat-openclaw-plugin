# miaochat_file_output skill

用于将 OpenClaw 生成的本地文件回传到 Miao Chat：

1. 调 `/api/v1/files/init-upload` 申请 `assistant_output` 上传凭证
2. 直传 COS
3. 调 `/api/v1/conversations/{conversation_id}/assistant-output/complete` 入 assistant 消息附件

## 文件

- `send_generated_file.py`: 主入口
- `install_skill.sh`: 安装到 OpenClaw workspace skill 目录（推荐）
- `verify_skill.sh`: 本地链路健康检查
- `verify_assistant_output_e2e.sh`: 一键端到端验收（回传后校验消息附件入会话）

## 参数

```bash
python3 send_generated_file.py \
  --conversation-id c_xxx \
  --request-id req_xxx \
  --file-path /tmp/report.pdf \
  --api-base http://127.0.0.1:8081 \
  --user-id u_xxx
```

可选参数：

- `--mime`：默认按扩展名自动探测
- `--file-name`：默认取 `file-path` 文件名
- `--token`：可选 Bearer Token
- `--source`：默认 `openclaw_skill`
- `--context-json` / `--context-file`：从 `invoke.start` 上下文读取 `conversation_id/request_id`
- `--config`：可选 JSON 配置文件，支持读取 `apiBase/backendBase/userId/token`
  - 不传时会自动尝试：`脚本同目录/config.json`、`上级目录/config.json`、`当前工作目录/config.json`

字段优先级：

1. `--context-json / --context-file` 内的 `conversation_id/request_id`
2. 显式命令参数
3. `request_id` 自动生成（`conversation_id` 不自动补）

## 环境变量

- `MIAO_CHAT_API_BASE`
- `MIAO_CHAT_USER_ID`
- `MIAO_CHAT_TOKEN`

注意：`user_id` 现在为必填（可来自上下文、`--user-id`、配置或环境变量），不再默认 `u_demo`，避免误发到错误会话。

## 输出

成功时输出 JSON：

```json
{
  "request_id": "req_xxx",
  "conversation_id": "c_xxx",
  "file_id": "f_xxx",
  "message_id": "m_xxx",
  "idempotent": false,
  "object_key": "assistant-output/..."
}
```

## OpenClaw 安装建议

1. 执行安装脚本（默认安装到 `~/.openclaw/workspace/skills/miaochat-file-output`）
2. 可选：在 OpenClaw 中注册别名命令 `send_generated_file`
3. 重启 OpenClaw
4. 执行 `scripts/verify_skill.sh` 验证链路

示例：

```bash
bash install_skill.sh --api-base http://127.0.0.1:8081
```

可选参数：

- `--target-dir`：自定义 skill 目录
- `--api-base` / `--user-id` / `--token`：写入 `config.json` 供脚本默认读取
- `--no-legacy-link`：不创建 `~/.openclaw/skills/miaochat_file_output` 兼容软链

## 一键验收（只传 conversation_id）

先设置环境变量：

```bash
export MIAO_CHAT_API_BASE=http://127.0.0.1:8081
export MIAO_CHAT_USER_ID=u_xxx
# 可选
# export MIAO_CHAT_TOKEN=xxxx
```

执行：

```bash
bash verify_assistant_output_e2e.sh c_xxx
```

脚本会自动：
1. 生成一个测试文件（或使用你传入的 file_path）
2. 调 `send_generated_file.py` 上传并回调
3. 拉取会话消息并校验 `message_id/file_id` 是否真实落库且挂到附件
