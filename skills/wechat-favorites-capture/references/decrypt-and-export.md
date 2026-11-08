# 解密与导出

微信收藏库 `favorite.db` 是 SQLCipher 4 加密的 SQLite。密钥不在磁盘上，只在微信进程内存里。
这一节是跑 `wfc_capture.sh export` 之前要知道的全部。

## 目录

1. [为什么要重签名](#1-为什么要重签名)
2. [准备微信副本](#2-准备微信副本)
3. [提取密钥](#3-提取密钥)
4. [解密](#4-解密)
5. [交叉校验](#5-交叉校验)
6. [清理](#6-清理)
7. [常见故障](#7-常见故障)

---

## 1. 为什么要重签名

macOS 的 Hardened Runtime 会禁止调试器 attach。微信是 hardened 的，frida 挂不上去。
唯一的办法是复制一份、去掉 hardened 标志、用 ad-hoc 身份重签。

**必须用 `ditto`，不能用 `cp -R`。** `cp -R` 不会保留扩展属性和代码签名的元数据，
重签之后微信会因为签名不完整而启动失败。`ditto` 会保留它们。

```bash
ditto /Applications/WeChat.app ~/Desktop/WeChat.app
codesign --force --deep --sign - ~/Desktop/WeChat.app
```

重签之后 `codesign -d --entitlements -` 应该显示 hardened runtime 标志被摘掉
（`0x10000` → `0x2` adhoc）。

> 别用这份副本替换 `/Applications/WeChat.app`，也别给它推送自动更新——它是用来被
> attach 的，不是用来日常使用的。

## 2. 准备微信副本

上面的 `ditto` + `codesign` 就是全部。

## 3. 提取密钥

微信在派生数据库密钥时调用 `CCKeyDerivationPBKDF`。frida hook 这个符号，把每次 PBKDF2
派生的参数和结果记下来：

```bash
<venv>/bin/python <skill-dir>/scripts/extract_key.py \
  --app ~/Desktop/WeChat.app \
  --seconds 300 \
  --log <state-dir>/wechat_frida_keys.log
```

**跑之前关掉正在运行的微信。** 数据目录跟用户身份走，用 sudo 起的进程读不到正确的库。

```bash
killall WeChat 2>/dev/null; sleep 2
```

frida 会 spawn 一份新的微信副本并注入 hook。启动之后：

- 微信 4.1.15 实测**启动阶段就加载了 `favorite.db` 的密钥**（日志里 `salt=` 与库首
  16 字节匹配），不用等打开收藏页。但别的微信版本不一定，日志为准。
- 需要手动登录的话，在 300 秒窗口内完成。

日志长这样：

```
rounds=256000
pw=<hex>
salt=<hex>          # 256000 轮这条的 salt == 目标库首 16 字节
dk=<hex>            # 32 字节 = cipher_key

rounds=2
pw=<上面的 dk>
salt=<上面的 salt XOR 0x3a>
dk=<hex>            # 32 字节 = hmac_key
```

看到 `rounds=2` 那条紧跟着 `rounds=256000` 那条，说明 salt 和 PBKDF2 参数都对上了。

## 4. 解密

`wfc_capture.sh export` 会自己做完这些事：

1. 找到 `favorite.db`，拷到工作目录。原库一个字节都不动。
2. 用日志里的 salt 匹配出对应的 PBKDF2 记录，派生 `cipher_key` 和 `hmac_key`。
3. 逐页校验 HMAC-SHA512(`密文 || iv || pgno小端`)，**全页通过才写输出**。
4. page 1 的首 16 字节还原成 `SQLite format 3\0`，末尾 80 字节的 reserve 区清零。

### 关于 WAL —— 快照可能不是最新的

**这个解密器只解主库，不解 WAL。** 微信运行期间，未 checkpoint 的新收藏躺在
`favorite.db-wal` 里，解出来的主库是旧的。

回执里的 `wal_present` 字段会告诉你这件事。两个解法：

**A. 让微信自己收尾（推荐）。** 退出微信，它会把 WAL checkpoint 进主库。然后重新
`export`。抓密钥本来就要先退出微信，所以正常流程里这一步是顺带的。

**B. 用官方 sqlcipher CLI 读穿 WAL。** 它能同时处理主库和 WAL：

```bash
printf "PRAGMA key=\"x'$KEY'\";\nATTACH DATABASE 'plain.db' AS plain KEY '';\nSELECT sqlcipher_export('plain');\n" \
  | <viz-skill>/vendor/sqlcipher <work>/favorite.db
```

> 注意：`vendor/sqlcipher` 是本地编译的官方 4.6.1 CLI，**不在上游仓库里**，也不是本
> skill 的一部分。新装的机器上它可能不存在——那就用解法 A。

**别指望「把 `-wal` 一起拷过去」就能解决。** 解密器逐页处理的是主库文件，拷过去的
WAL 只是被留在了工作目录里，并没有被合并。

也可以手动调：

```bash
<venv>/bin/python <skill-dir>/scripts/decrypt_favorite_db.py \
  --input <work>/favorite.db \
  --output <dataset>/favorite_plain.db \
  --keylog <state-dir>/wechat_frida_keys.log
```

已经有 cipher_key 时可以跳过 frida，直接 `--key <64位十六进制>`。

校验不通过会直接报错，不会写出半成品库。

## 5. 交叉校验

解出来的库应该和官方 sqlcipher CLI 的结果一致。skill 自带一份编译好的
`vendor/sqlcipher`（4.6.1）可以当参照实现——它在上游 skill 里，不在本 skill 里：

```bash
printf "PRAGMA key=\"x'$KEY'\";\nATTACH DATABASE 'plain.db' AS plain KEY '';\nSELECT sqlcipher_export('plain');\n" \
  | <viz-skill>/vendor/sqlcipher <work>/favorite.db

python3 - <<'PY'
import sqlite3, hashlib
def sig(p):
    c = sqlite3.connect(p)
    h = hashlib.sha256()
    for row in c.execute("select * from fav_db_item order by rowid"):
        h.update(repr(row).encode())
    n = c.execute("select count(*) from fav_db_item").fetchone()[0]
    c.close()
    return n, h.hexdigest()[:16]
print("cli:", sig("plain_cli.db"), "\npy :", sig("plain_py.db"))
PY
```

两边应该逐行一致。

## 6. 清理

密钥日志和重签名副本用完就删：

```bash
rm -f <state-dir>/wechat_frida_keys.log
rm -rf ~/Desktop/WeChat.app
```

`favorite_plain.db` 是明文的个人浏览记录。留在采集目录里没问题，但**别提交进 git**——
采集目录里加一条 `.gitignore` 把 `favorite_plain.db` 排除掉。

## 7. 常见故障

| 症状 | 原因 / 处理 |
|---|---|
| frida 报 `unable to attach` / 微信启动即退 | Hardened Runtime 没摘掉。重新 `codesign --force --deep --sign -`，并确认用的是 `ditto` 复制的副本 |
| 日志里没有 `rounds=256000` | hook 没触发。确认微信真的起来了并加载了收藏库；或者 `--seconds` 给得太短 |
| salt 对不上 | 抓密钥时微信登录的账号和现在读库的账号不是同一个。换账号登录后重来 |
| 解密报 HMAC 校验失败 | 密钥是旧的（微信升级后密钥会变）。重跑一次提取流程 |
| 记录数比微信里看到的少 | WAL 里有没 checkpoint 的帧。退出微信让它 checkpoint，然后重跑 export（见上面「关于 WAL」） |
| `parse_favorites.py` 报 0 条 | 表结构不是 4.x 的 `fav_db_item`。检查微信版本；3.x 走 `FavItems`，脚本两边都兼容 |
