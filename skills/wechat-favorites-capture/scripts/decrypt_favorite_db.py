#!/usr/bin/env python3
"""
解密微信收藏数据库（SQLCipher 4 加密的 favorite.db）→ 明文 SQLite。

上游仓库没有提供这一步的实现（SKILL.md 里说"内置在 parse_favorites.py 的上游"，
即作者本地脚本，未开源）。本脚本按 SQLCipher 4.6.1 源码规格实现，并用官方
sqlcipher CLI 生成的样本做过字节级验证。

规格（摘自 sqlcipher-4.6.1/src/sqlcipher.c，已实证核对）：
  密文密钥 cipher_key = PBKDF2-HMAC-SHA512(pass, salt, 256000, 32)
  HMAC 密钥 hmac_key  = PBKDF2-HMAC-SHA512(cipher_key, salt XOR 0x3a, 2, 32)
  页布局 page N>1     = 密文(page_size-80) | iv(16) | hmac(64)
           page 1     = salt(16) | 密文(page_size-96) | iv(16) | hmac(64)
  HMAC 输入           = 密文 || iv || pgno(4 字节小端)
  page 1 的 HMAC 不含 salt 段；解密后需把明文首 16 字节还原为
  "SQLite format 3\\0"，reserve 区（末尾 80 字节）清零。

密钥来源：frida hook CCKeyDerivationPBKDF 的日志（按 salt 与库首 16 字节匹配）。
"""

import argparse
import hashlib
import hmac as hmac_mod
import os
import re
import struct
import sys

from Crypto.Cipher import AES

# --- SQLCipher 4 默认参数 ---
PAGE_SIZE = 4096
RESERVE_SZ = 80          # iv(16) + hmac(64)
SALT_SZ = 16
IV_SZ = 16
HMAC_SZ = 64
KDF_ITER = 256000
FAST_KDF_ITER = 2
HMAC_SALT_MASK = 0x3A    # sqlcipher.c: #define HMAC_SALT_MASK 0x3a
SQLITE_MAGIC = b"SQLite format 3\x00"


def _pbkdf2(password, salt, iterations, dklen=32):
    return hashlib.pbkdf2_hmac("sha512", password, salt, iterations, dklen)


def _xor_mask(data, mask=HMAC_SALT_MASK):
    return bytes(b ^ mask for b in data)


def parse_keylog(path):
    """解析 frida 日志，返回 [{rounds, pw, salt, dk}] 列表。

    日志格式（SKILL.md 中的 hook 脚本写入）：
        rounds=256000
        pw=<hex>
        salt=<hex>
        dk=<hex>
    """
    entries = []
    cur = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            m = re.match(r"^(rounds|pw|salt|dk)=([0-9a-fA-F]*)$", line)
            if m:
                cur[m.group(1)] = m.group(2)
            elif not line and cur:
                entries.append(cur)
                cur = {}
    if cur:
        entries.append(cur)
    return entries


def _page_parts(page, pgno, page_size, reserve_sz):
    """切分一页，返回 (密文, iv, hmac)。page 1 前面多一段明文 salt。"""
    if pgno == 1:
        salt = page[:SALT_SZ]
        ct = page[SALT_SZ:page_size - reserve_sz]
    else:
        salt = b""
        ct = page[:page_size - reserve_sz]
    iv = page[page_size - reserve_sz:page_size - reserve_sz + IV_SZ]
    mac = page[page_size - reserve_sz + IV_SZ:page_size - reserve_sz + IV_SZ + HMAC_SZ]
    return salt, ct, iv, mac


def _page_hmac(hmac_key, ct, iv, pgno):
    return hmac_mod.new(hmac_key, ct + iv + struct.pack("<I", pgno), hashlib.sha512).digest()


def try_key(data, cipher_key, hmac_key, page_size=PAGE_SIZE, reserve_sz=RESERVE_SZ):
    """用给定密钥组试解，返回明文页列表；校验失败返回 None。"""
    n_pages = len(data) // page_size
    if n_pages == 0:
        return None
    out = []
    for i in range(n_pages):
        pgno = i + 1
        page = data[i * page_size:(i + 1) * page_size]
        salt, ct, iv, mac = _page_parts(page, pgno, page_size, reserve_sz)
        if len(ct) == 0 or len(mac) < HMAC_SZ:
            return None
        if not hmac_mod.compare_digest(_page_hmac(hmac_key, ct, iv, pgno), mac[:HMAC_SZ]):
            return None
        plain = AES.new(cipher_key, AES.MODE_CBC, iv).decrypt(ct)
        if pgno == 1:
            plain = SQLITE_MAGIC + plain
        out.append(plain + b"\x00" * reserve_sz)
    return out


def main():
    p = argparse.ArgumentParser(description="解密微信收藏数据库（SQLCipher 4）")
    p.add_argument("--input", "-i", required=True, help="加密的 favorite.db 路径")
    p.add_argument("--output", "-o", required=True, help="解密后明文 db 的输出路径")
    p.add_argument("--key", "-k", help="cipher_key 十六进制（64 字符）。不给则从 --keylog 匹配")
    p.add_argument("--keylog", help="frida 密钥日志（默认 /tmp/wechat_frida_keys.log）")
    p.add_argument("--page-size", type=int, default=PAGE_SIZE, help=f"页大小，默认 {PAGE_SIZE}")
    p.add_argument("--reserve-size", type=int, default=RESERVE_SZ, help=f"reserve 区大小，默认 {RESERVE_SZ}")
    args = p.parse_args()

    if not os.path.exists(args.input):
        print(f"[ERROR] 找不到输入文件: {args.input}", file=sys.stderr)
        return 1
    data = open(args.input, "rb").read()
    if len(data) < args.page_size:
        print(f"[ERROR] 文件太小，不可能是完整数据库: {len(data)} bytes", file=sys.stderr)
        return 1

    salt = data[:SALT_SZ]
    n_pages = len(data) // args.page_size
    print(f"[INFO] 输入: {args.input}  ({len(data)} bytes, {n_pages} 页)")
    print(f"[INFO] salt: {salt.hex()}")

    # ---- 收集候选 cipher_key / hmac_key ----
    cipher_candidates = []   # [(来源, cipher_key_bytes, [可选 hmac_key 候选])]
    if args.key:
        cipher_candidates.append(("--key 参数", bytes.fromhex(args.key.strip()), []))
    else:
        keylog = args.keylog or "/tmp/wechat_frida_keys.log"
        if not os.path.exists(keylog):
            print(f"[ERROR] 找不到 frida 密钥日志: {keylog}\n"
                  f"        先按 SKILL.md Step 2 提取密钥，或用 --key 直接传 cipher_key",
                  file=sys.stderr)
            return 1
        entries = parse_keylog(keylog)
        print(f"[INFO] 密钥日志解析到 {len(entries)} 条 PBKDF2 记录")
        # 日志里 rounds==2 的那条：salt = db_salt XOR 0x3a，dk 即 hmac_key
        logged_hmac = []
        for e in entries:
            try:
                s = bytes.fromhex(e.get("salt", ""))
                d = bytes.fromhex(e.get("dk", ""))
            except ValueError:
                continue
            if e.get("rounds") == str(FAST_KDF_ITER) and s == _xor_mask(salt):
                logged_hmac.append(d[:32])
        for e in entries:
            try:
                s = bytes.fromhex(e.get("salt", ""))
                d = bytes.fromhex(e.get("dk", ""))
            except ValueError:
                continue
            if s != salt or not d:
                continue
            rounds = e.get("rounds", "?")
            cipher_candidates.append((f"frida 日志 (rounds={rounds})", d[:32], list(logged_hmac)))
        if not cipher_candidates:
            print(f"[ERROR] 日志中没有 salt 与本库匹配的记录。\n"
                  f"        本库 salt = {salt.hex()}\n"
                  f"        提示：frida 运行期间必须在微信里打开「收藏」页面，密钥才会加载。",
                  file=sys.stderr)
            return 1

    # ---- 逐个候选试解 ----
    for src, cipher_key, extra_hmac in cipher_candidates:
        hmac_candidates = [_pbkdf2(cipher_key, _xor_mask(salt), FAST_KDF_ITER, 32)]
        hmac_candidates += [h for h in extra_hmac if h]
        for hmac_key in hmac_candidates:
            pages = try_key(data, cipher_key, hmac_key, args.page_size, args.reserve_size)
            if pages is None:
                continue
            with open(args.output, "wb") as f:
                f.write(b"".join(pages))
            print(f"[OK] 解密成功  来源: {src}")
            print(f"[OK] cipher_key: {cipher_key.hex()}")
            print(f"[OK] hmac_key : {hmac_key.hex()}")
            print(f"[OK] 输出: {args.output}  ({n_pages} 页)")
            wal = args.input + "-wal"
            if os.path.exists(wal):
                print(f"[WARN] 存在 WAL 文件 {wal}，本次未解密，库内容可能不是最新快照")
            return 0

    print("[ERROR] 所有候选密钥都未通过 HMAC 校验。\n"
          "        可能原因：密钥不匹配 / 页大小或 reserve 大小不对 / 微信版本改用了别的加密方案。\n"
          f"        提示：可试 --page-size 1024|2048|8192|16382 或 --reserve-size 16|48|80。", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
