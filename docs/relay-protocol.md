# 中转模式：协议与安全模型

三方：**客户端**（手机/电脑）、**中转站**（公网服务器，`fileswitch relay`）、**NAS**（`fileswitch serve`，无公网 IP）。

```
客户端 ──HTTPS──▶ 中转站 ◀──HTTPS（仅 NAS 主动发起）── NAS
   │  密封的操作 / 加密的文件块        ▲  取件、回执、加密快照、加密缓存
   └──────────── 端到端加密，中转站看不懂 ────────────┘
```

NAS 从不监听公网，也不接受中转站发起的任何连接。它按 `FS_RELAY_INTERVAL`（默认 20 秒）主动向中转站取件；处理过工作后的 2 分钟内改为每 2 秒一次，随后回到低频。本地有变化（例如在家上传）时也会主动推送一次。

## 威胁模型

| 被攻破的一方 | 攻击者能得到 | 攻击者做不到 |
|---|---|---|
| 中转站（包括 root 权限、全部数据） | 密文、文件大小、时间规律、设备数量；可以丢弃或拖延消息（拒绝服务） | 读取文件内容、文件名、目录结构、分类；伪造或重放操作；用 A 文件冒充 B 文件；连进 NAS；读到 NAS 上任何其他数据 |
| 某台已授权设备（被盗） | 该用户交换空间里的文件（在被撤销前） | 彻底删除（默认策略）、添加新设备（默认策略）、改密码、管理用户、接触交换空间以外的任何东西 |
| NAS 上的 FileSwitch 进程（假设解析漏洞） | 交换站数据目录 | 容器以只读根文件系统、无 capability、禁止提权、非 root 运行，且只挂载交换站自己的数据目录 |

撤销设备后：中转站立即拒绝它的令牌；NAS 轮换该用户的空间密钥，此后发布的快照、缓存都用新密钥，被撤销设备的旧密钥打不开。

## 密钥

| 密钥 | 持有者 | 用途 |
|---|---|---|
| 空间密钥 `SK[kid]`（每用户一组，按 kid 递增轮换） | NAS + 该用户的已授权设备 | 加密文件密钥、快照；派生缓存名 |
| 设备密钥 `DK`（每台设备一把） | NAS + 该设备 | 加密该设备的操作、NAS 的回执、密钥环 |
| 文件密钥 `FK`（每个文件随机） | 封装在文件头里（用 SK 加密） | 加密文件内容分段 |
| 中转令牌（每台设备一个） | 设备；中转站只存 SHA-256 | 只用于中转站准入/限流，不赋予任何解密能力 |
| NAS 令牌 `FS_RELAY_TOKEN` | NAS + 中转站 | 中转站识别 NAS；泄露也只能“冒充 NAS 收件”，但读不懂、改不了 |

NAS 上的 SK、DK 都用静态加密主密钥封装后存放在数据库中（因此中转模式要求 `FS_ENCRYPT=true`）。

所有对称加密均为 **XChaCha20-Poly1305**（24 字节随机 nonce），每条消息都带有绑定用途与身份的附加认证数据（AAD），防止跨用途、跨设备挪用：

| 消息 | 密钥 | AAD |
|---|---|---|
| 操作（设备 → NAS） | DK | `fsop1|<设备id>|<操作id>` |
| 回执（NAS → 设备） | DK | `fsrp1|<设备id>|<操作id>` |
| 密钥环 | DK | `fskr1|<设备id>` |
| 配对请求 / 应答 | HKDF(配对密钥) | `fspq1|<lookup>` / `fsps1|<lookup>` |
| 待收取上传的描述 | SK[kid] | `fspend1|<空间id>|<blob id>` |
| 快照 | SK[kid] | `FSS1 ‖ kid ‖ version ‖ 空间id` |
| 文件头（封装 FK） | SK[kid] | `FSE1 ‖ kid` |
| 文件分段 i | FK | 是否为最后一段（1 字节）；nonce = 0¹⁶ ‖ BE64(i) |

## 格式

**文件（FSE1）**：`"FSE1" | 版本 1 | 3 字节保留 | kid(BE32) | nonce(24) | AEAD(SK, FK)(48)`，共 84 字节头；之后是每 64 KiB 明文一段的密文（各带 16 字节标签）。分段 nonce 由序号决定，所以：可以从任意偏移续传（同一 FK 下重新生成的密文完全相同）、不能重排/截断/拼接。

上传操作里记录文件头的随机 nonce，NAS 解密时校验它与操作一致——中转站无法用另一个合法文件替换。下载时客户端用快照里的 SHA-256 校验明文——中转站无法用别的缓存冒充。

**快照（FSS1）**：`"FSS1" | kid | version(BE64) | nonce(24) | AEAD(SK, gzip(JSON))`。JSON 包含该用户的全部文件树节点、回收站、分类、设备列表、统计和策略。客户端的浏览、搜索、时间线都在本地对快照计算。

**缓存名**：`hex(HMAC-SHA256(SK[kid], "cache|节点id|sha256"))[:32]`。

**配对码**：`fileswitch://pair?k=<128 位密钥 base32>&r=<中转站地址>&f=<自签证书指纹>`。`lookup = HKDF(k, "fileswitch-pair", "lookup")`，`key = HKDF(k, …, "key")`。中转站只见到 lookup 和密文，128 位熵使离线穷举不可行；配对码 15 分钟有效、只能用一次。

## 操作

设备提交 `{"t": 类型, "ts": 毫秒时间戳, …}`。NAS 先验证 AEAD，再按操作 id 去重（记录先于执行：崩溃时可能丢一次操作，但绝不会重复执行），拒绝超过 3 天或来自未来的操作，每台设备每分钟最多 120 个，JSON 严格解析（未知字段即拒绝）。

| 类型 | 说明 |
|---|---|
| `ping` | 连通性测试 |
| `mkdir` | 新建文件夹（`name`，或 `path` 递归） |
| `patch` | 重命名 / 移动 / 设置分类 |
| `batch` | 批量 move / categorize / trash |
| `restore` | 从回收站恢复 |
| `purge`、`empty_trash` | 彻底删除；默认被 `FS_REMOTE_PURGE=false` 拒绝 |
| `cat_create`、`cat_update`、`cat_delete`、`cat_reorder` | 分类管理 |
| `upload` | 收取已上传到中转站的密文：`folder`（新建投递文件夹）、`dirs`（空目录）、`files[{rel, blob, nonce, size, mtime}]`；大文件夹分批提交（`nested`） |
| `fetch` | 请 NAS 把指定文件加密后放到中转站缓存 |
| `device_rename`、`device_revoke` | 设备管理 |
| `pair` | 生成配对码；默认被 `FS_REMOTE_PAIRING=false` 拒绝 |

不存在远程修改密码、管理用户、读取安全日志、访问任意路径之类的操作——NAS 里根本没有对应代码路径。

## 中转站接口

客户端（`Authorization: Bearer <中转令牌>`）：`GET /r/v1/status`、`GET /r/v1/snapshot`、`GET /r/v1/keyring`、`POST /r/v1/ops`、`GET /r/v1/replies`、`POST|GET|PUT /r/v1/blobs/{id}`、`POST /r/v1/cache/lookup`、`GET /r/v1/cache/{key}`（支持 Range）、`PUT /r/v1/blobs/{id}/announce`、`GET /r/v1/pending`、`GET /r/v1/pending/{id}`（支持 Range）、`GET /r/v1/events`（SSE）。

配对（无令牌，按 IP 限流）：`POST|GET /r/v1/pair/{lookup}`。

NAS（`Authorization: Bearer <FS_RELAY_TOKEN>`）：`GET /n/v1/poll`、`POST /n/v1/ack`、`PUT /n/v1/spaces/{s}/devices|snapshot|keyrings/{d}`、`POST /n/v1/spaces/{s}/replies`、`GET|PUT|DELETE /n/v1/spaces/{s}/cache[/{key}]`、`GET|DELETE /n/v1/blobs/{id}`、`PUT /n/v1/pair/{lookup}`、`DELETE /n/v1/spaces/{s}`。

中转站对上传和缓存有每空间配额（`FS_RELAY_QUOTA`）与过期时间；NAS 收取上传后立即删除中转站上的副本。

## 待收取的上传

NAS 和中转站之间的线路可能很慢。为了让同一用户的其他设备不用等 NAS 收完：

1. 上传设备把文件密文传完后，用当前空间密钥封装一段描述 `{name, path, size, mtime, nonce, from}`
   （AAD `fspend1|<空间id>|<blob id>`），`PUT /r/v1/blobs/{id}/announce {kid, n, c}`。
   只有上传这台设备能为自己的、已传完的 blob 发布描述。
2. 同一空间的设备 `GET /r/v1/pending` 拿到列表，用密钥环打开描述；`GET /r/v1/pending/{id}` 下载密文
   （只限本空间、已传完、已发布描述的 blob）。
3. 下载方核对文件头里的 nonce 与描述里的 `nonce` 一致，再逐段解密校验。中转站伪造不了描述（没有空间密钥），
   也没法把描述挪到别的 blob 或别的空间上（AAD 绑定了两者）。
4. NAS 收取后删除 blob，描述随之删除，中转站推送 `{"type":"pending"}` 事件，客户端刷新列表。

中转站因此多知道的只有"这个空间的哪台设备上传了多大的文件、谁下载了"，和原来的上传本身相比没有新增内容。

## 留存与日志

中转站只是过路的地方，留什么、留多久都是固定的：

| 内容 | 保留多久 |
| --- | --- |
| 等 NAS 收取的上传、NAS 放上来的文件副本（都是密文） | 最后一个字节到达后 12 小时；NAS 收走或删除后立即清除 |
| 排队的操作、回复（密文） | 12 小时；操作被 NAS 确认后立即清除 |
| 配对请求 | 用过即删，最长 1 小时 |
| 设备令牌哈希、加密的 keyring、最新一份加密快照 | 只有当前这一份，随 NAS 更新覆盖，设备吊销或用户删除时清除 |

「最后一个字节到达」之后的空写入不会重新计时。到期检查每分钟一次。NAS 只推送创建不足 12 小时的文件；更早的文件由设备按需请求，NAS 推送后同样只留 12 小时，不会反复重传。

**删除**：数据库开启 `secure_delete`，删除的行在文件里被清零；预写日志每分钟清空一次；文件先用零覆盖、`fsync`，再 unlink。正在传输的文件等传输结束后再清除，重启打断的清除由下一轮补上。启动时 `VACUUM` 一次，清掉旧版本留在空闲页里的内容。底层的 SSD 或虚拟磁盘是否真的擦除这些块，软件无法保证，但这些数据本来就是中转站没有密钥的密文。

**日志**：中转站不写访问日志，不记录 IP、路径或文件标识；内存里的限流计数 10 分钟后丢弃。部署时容器日志驱动设为 `none`。NAS 同样没有按请求的日志，出错时只记录错误本身；安全日志只记录动作类型、设备和时间，不含文件名或路径，旧版本写入的文件名在升级时清除。

## NAS 的 HTTP 客户端

NAS 访问中转站时不跟随任何重定向。否则被攻破的中转站可以返回 `302 Location: http://192.168.x.x/...`，
让 NAS 把请求打到家里局域网的其他设备上（明文 http 也绕过了证书固定）。客户端同样不跟随重定向。
