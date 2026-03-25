# SillyTavern Incremental Save

SillyTavern 默认在每次发送消息后，将**完整的聊天记录**上传到服务端并覆写文件。当聊天记录较大时，每发一条消息都要传输全部数据，导致保存缓慢甚至卡顿。

本补丁将保存行为改为**增量追加**：只上传新增的消息，大幅减少传输量。

## 问题

```
用户发送一条消息
  ↓
前端序列化整个 chat 数组（header + 全部消息）
  ↓
POST /api/chats/save  →  上传完整聊天数据
  ↓
服务端覆写 .jsonl 文件
```

聊天记录越长，每次保存的传输量越大。但实际上每轮对话新增的内容只占很小一部分。

## 解决方案

```
用户发送一条消息
  ↓
前端检测：只是追加了新消息？旧消息没改？
  ├─ 是 → POST /api/chats/save-append  →  只上传新增的消息
  └─ 否 → POST /api/chats/save          →  回退到全量保存（编辑/删除/swipe 时）
```

### 核心机制

- **前端变更检测**：跟踪消息数量和内容 hash，判断是否只有末尾追加
- **服务端追加写入**：新增 `/api/chats/save-append` 端点，校验行数一致性后追加消息到 JSONL 文件
- **自动回退**：编辑旧消息、swipe、删除、重排等操作会改变 hash，自动回退到全量保存
- **一致性校验**：`expectedLines` 机制确保客户端和服务端数据同步，不匹配则拒绝增量保存

## 适用版本

- SillyTavern **1.16.0**（`ghcr.io/sillytavern/sillytavern:latest`）

## 安装

### Docker 部署

```bash
git clone https://github.com/ransxd/sillytavern-incremental-save.git
cd sillytavern-incremental-save
./install.sh --docker sillytavern
```

默认容器名为 `sillytavern`，如果你的容器名不同，替换最后的参数即可。

脚本会自动：
1. 备份原始文件到 `backups/` 目录
2. 应用补丁
3. 重启容器

### 本地部署

```bash
git clone https://github.com/ransxd/sillytavern-incremental-save.git
cd sillytavern-incremental-save
./install.sh --local /path/to/SillyTavern
```

应用后需手动重启 SillyTavern。

## 卸载

```bash
# Docker
./uninstall.sh --docker sillytavern

# 本地
./uninstall.sh --local /path/to/SillyTavern
```

## 验证

安装后打开浏览器 DevTools → Network 面板：

1. 打开一个聊天，发送第一条消息 → 应看到 `/api/chats/save`（全量，初始化跟踪状态）
2. 再发一条消息 → 应看到 `/api/chats/save-append`（增量）
3. 编辑一条旧消息后保存 → 应回退到 `/api/chats/save`（全量）

控制台中会打印 `Incremental save: appending N new message(s)` 日志。

## 修改的文件

| 文件 | 改动 |
|------|------|
| `src/endpoints/chats.js` | 新增 `countLines()`、`tryAppendChat()` 辅助函数；新增 `/save-append` 和 `/group/save-append` 端点 |
| `public/script.js` | 新增增量跟踪变量 + hash 函数；`saveChat()` 优先尝试增量保存；`clearChat()` 中重置状态 |
| `public/scripts/group-chats.js` | `saveGroupChat()` 同样支持增量保存 |

## 安全性

- 增量保存失败时**自动回退**到全量保存，不会丢数据
- `expectedLines` 校验确保客户端与服务端文件行数一致
- 原有的 integrity check、backup 机制完全保留
- 编辑/删除/swipe 等修改旧消息的操作不受影响，会正常触发全量保存

## License

MIT
