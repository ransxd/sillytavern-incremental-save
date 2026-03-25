# SillyTavern Incremental Save + Image Cache

SillyTavern 性能优化补丁，包含两个功能：

1. **增量保存** — 发新消息时只上传新增内容，不再全量上传整个聊天记录
2. **外部图片缓存** — 聊天中的外部图片（如 catbox.moe）通过服务端代理缓存，避免重复下载

## 功能一：增量保存

SillyTavern 默认在每次发送消息后，将**完整的聊天记录**上传到服务端并覆写文件。当聊天记录较大时，每发一条消息都要传输全部数据，导致保存缓慢甚至卡顿。

本补丁将保存行为改为**增量追加**：只上传新增的消息，大幅减少传输量。

```
发一条消息 → 检测：只是新增了消息吗？
  ├─ 是 → 只上传新增的那几条消息（毫秒级完成）
  └─ 否 → 回退全量保存（编辑/删除/swipe等场景，保证数据安全）
```

### 核心机制

- **前端变更检测**：跟踪消息数量和内容 hash，判断是否只有末尾追加
- **服务端追加写入**：新增 `/api/chats/save-append` 端点，校验行数一致性后追加消息到 JSONL 文件
- **自动回退**：编辑旧消息、swipe、删除、重排等操作会改变 hash，自动回退到全量保存
- **一致性校验**：`expectedLines` 机制确保客户端和服务端数据同步，不匹配则拒绝增量保存

## 功能二：外部图片缓存

聊天消息中嵌入的外部图片（如 `files.catbox.moe`）默认每次加载都要从源站重新下载。catbox 等图床通常不设置 `Cache-Control` 头，导致浏览器无法有效缓存。

本补丁通过服务端代理实现缓存：

```
浏览器渲染消息
  ↓
外部图片 URL 自动改写为 /api/image-proxy?url=...
  ↓
首次：服务端下载图片 → 缓存到磁盘 → 返回（设置 7 天缓存头）
再次：服务端直接读磁盘返回（毫秒级）
之后：浏览器直接从本地缓存返回（不发请求）
```

### 核心机制

- **URL 改写**：通过 DOMPurify 钩子，在消息渲染时将外部 `<img>` 的 src 自动改写为代理地址
- **磁盘缓存**：图片以 SHA256(URL) 为文件名缓存在 `data/<user>/cache/images/` 目录
- **浏览器缓存**：响应设置 `Cache-Control: public, max-age=604800`，浏览器 7 天内不再请求
- **并发去重**：多个请求同一图片时，只发起一次远程下载
- **安全限制**：只代理 HTTP/HTTPS 协议，单文件最大 10MB

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
2. 应用补丁 + 复制新文件
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

### 增量保存

安装后打开浏览器 DevTools → Network 面板：

1. 打开一个聊天，发送第一条消息 → 应看到 `/api/chats/save`（全量，初始化跟踪状态）
2. 再发一条消息 → 应看到 `/api/chats/save-append`（增量）
3. 编辑一条旧消息后保存 → 应回退到 `/api/chats/save`（全量）

控制台中会打印 `Incremental save: appending N new message(s)` 日志。

### 图片缓存

1. 打开包含外部图片的聊天
2. Network 面板中图片请求应指向 `/api/image-proxy?url=...`
3. 响应头中应有 `X-Image-Cache: HIT`（缓存命中）或 `MISS`（首次下载）
4. 刷新页面，图片应瞬间加载

## 修改的文件

| 文件 | 改动 |
|------|------|
| `src/endpoints/chats.js` | 新增 `countLines()`、`tryAppendChat()`；新增 `/save-append` 和 `/group/save-append` 端点 |
| `public/script.js` | 新增增量跟踪变量 + hash 函数；`saveChat()` 优先尝试增量保存 |
| `public/scripts/group-chats.js` | `saveGroupChat()` 同样支持增量保存 |
| `src/endpoints/image-proxy.js` | **新增文件**：外部图片代理缓存端点 |
| `src/server-startup.js` | 注册 `/api/image-proxy` 路由 |
| `public/scripts/chats.js` | DOMPurify 钩子中添加外部图片 URL 改写 |

## 安全性

- 增量保存失败时**自动回退**到全量保存，不会丢数据
- `expectedLines` 校验确保客户端与服务端文件行数一致
- 原有的 integrity check、backup 机制完全保留
- 编辑/删除/swipe 等修改旧消息的操作不受影响，会正常触发全量保存
- 图片代理只允许 HTTP/HTTPS 协议，单文件限制 10MB
- 图片缓存在用户数据目录下，跟随 Docker volume 持久化

## License

MIT
