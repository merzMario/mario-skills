#!/usr/bin/env python3
"""
从微信 Mac 客户端进程里 hook CCKeyDerivationPBKDF，抓取 PBKDF2 派生过程，
把每条 (rounds, pw, salt, dk) 写入密钥日志，供 decrypt_favorite_db.py 匹配解密。

前置：需要一份去掉了 Hardened Runtime 的微信副本（见 SKILL.md Step 2a）。

用法：
    ~/.claude/skills/wx-favorites-report/.venv/bin/python \\
        ~/.claude/skills/wx-favorites-report/scripts/extract_key.py \\
        --app ~/Desktop/WeChat.app --seconds 240

运行后请在弹出的微信窗口里：登录 → 打开「收藏」页面。密钥只在打开收藏时才会加载。
"""

import argparse
import json
import os
import sys
import time

import frida

DEFAULT_LOG = "/tmp/wechat_frida_keys.log"

JS_CODE = """
function buf2hex(buffer) {
    var a = new Uint8Array(buffer); var h = '';
    for (var i = 0; i < a.length; i++) h += ('0' + a[i].toString(16)).slice(-2);
    return h;
}
var found = false;
Process.enumerateModules().forEach(function(m) {
    if (found) return;
    m.enumerateExports().forEach(function(exp) {
        if (found) return;
        if (exp.name === "CCKeyDerivationPBKDF") {
            found = true;
            send("[*] Hook installed on " + m.name);
            Interceptor.attach(exp.address, {
                onEnter: function(args) {
                    this.pwLen = args[2].toInt32();
                    this.saltLen = args[4].toInt32();
                    this.rounds = args[6].toInt32();
                    this.pw = args[1]; this.salt = args[3];
                    this.dk = args[7]; this.dkLen = args[8].toInt32();
                },
                onLeave: function(retval) {
                    if (this.pwLen < 4 || this.pwLen > 256) return;
                    if (this.saltLen < 4 || this.saltLen > 64) return;
                    var saltHex = buf2hex(this.salt.readByteArray(this.saltLen));
                    var dkHex = buf2hex(this.dk.readByteArray(this.dkLen));
                    var pwHex = buf2hex(this.pw.readByteArray(this.pwLen));
                    send("[PBKDF2] r=" + this.rounds + " salt=" + saltHex);
                    var f = new File(LOG_PATH, "a");
                    f.write("rounds=" + this.rounds + "\\npw=" + pwHex + "\\nsalt=" + saltHex + "\\ndk=" + dkHex + "\\n\\n");
                    f.flush(); f.close();
                }
            });
        }
    });
});
if (!found) send("[!] CCKeyDerivationPBKDF not found");
"""


def main():
    p = argparse.ArgumentParser(description="hook 微信进程抓取 PBKDF2 密钥")
    p.add_argument("--app", default=os.path.expanduser("~/Desktop/WeChat.app"),
                   help="去签名副本路径，默认 ~/Desktop/WeChat.app")
    p.add_argument("--seconds", type=int, default=240, help="保持注入的秒数，默认 240")
    p.add_argument("--log", default=DEFAULT_LOG, help=f"密钥日志路径，默认 {DEFAULT_LOG}")
    p.add_argument("--keep-log", action="store_true", help="不清空已有日志")
    args = p.parse_args()

    binary = os.path.join(args.app, "Contents", "MacOS", "WeChat")
    if not os.path.exists(binary):
        print(f"[ERROR] 找不到微信可执行文件: {binary}\n"
              f"        先按 SKILL.md Step 2a 做签名副本：\n"
              f"        ditto /Applications/WeChat.app ~/Desktop/WeChat.app\n"
              f"        codesign --force --deep --sign - ~/Desktop/WeChat.app", file=sys.stderr)
        return 1

    if not args.keep_log and os.path.exists(args.log):
        os.remove(args.log)

    js = JS_CODE.replace("LOG_PATH", json.dumps(args.log))

    device = frida.get_local_device()
    pid = device.spawn([binary])
    session = device.attach(pid)
    script = session.create_script(js)
    script.on("message", lambda msg, data: print(msg.get("payload", msg), flush=True))
    script.load()
    device.resume(pid)

    print(f"\n[*] 微信已启动 (pid={pid})")
    print("[*] 现在请在微信窗口里：登录 → 点开「收藏」页面 → 保持 60 秒")
    print(f"[*] 注入将保持 {args.seconds} 秒，密钥日志: {args.log}\n", flush=True)

    deadline = time.time() + args.seconds
    while time.time() < deadline:
        time.sleep(5)
        if os.path.exists(args.log) and os.path.getsize(args.log) > 0:
            size = os.path.getsize(args.log)
            print(f"[*] 已捕获密钥 {size} bytes（日志增长中）", flush=True)

    session.detach()
    print(f"\n[*] 完成。密钥日志: {args.log}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
