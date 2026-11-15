#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把改动推到 GitHub，触发 Actions 编译。

为什么不用 git push：
    在无凭据的沙箱/服务器里，git push 需要 SSH key 或 credential helper；
    这里直接走 GitHub REST API（用 token），只提交你点名的文件，
    其余文件按 base_tree 保留远端现状 —— 不会把本地一堆垃圾一起带上去。

用法：
    export GITHUB_TOKEN=ghp_xxx        # 或在 ~/.gh_token 里放一行 token
    python3 push2.py "0.1.1: 修 xxx" Tweak.xm control

    # 文件路径相对于源目录（默认 = 本脚本所在目录）
    PLUGIN_SRC=/path/to/project python3 push2.py "msg" Tweak.xm

推完脚本会打印本次 run 的地址。取产物：
    gh run list  --repo <owner/repo> --limit 1
    gh run watch <run-id> --repo <owner/repo>
    gh run download <run-id> --repo <owner/repo> -D ./out
"""
import base64
import os
import sys
from pathlib import Path

import requests

# ←←← 只改这一行（或设环境变量 PLUGIN_REPO）
REPO = os.environ.get("PLUGIN_REPO", "YOUR_NAME/YOUR_REPO")
BRANCH = os.environ.get("PLUGIN_BRANCH", "main")
API = f"https://api.github.com/repos/{REPO}"

S = requests.Session()


def token() -> str:
    tok = os.environ.get("GITHUB_TOKEN", "").strip()
    if not tok:
        p = Path.home() / ".gh_token"
        if p.exists():
            tok = p.read_text(encoding="utf-8").strip()
    if not tok:
        sys.exit("缺少令牌：export GITHUB_TOKEN=... 或写入 ~/.gh_token")
    return tok


def call(method: str, url: str, **kw) -> dict:
    r = S.request(method, url, timeout=60, **kw)
    if r.status_code >= 300:
        sys.exit(f"{method} {url} -> {r.status_code}\n{r.text[:800]}")
    return r.json() if r.text.strip() else {}


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    msg, files = sys.argv[1], sys.argv[2:]

    root = Path(os.environ.get("PLUGIN_SRC") or Path(__file__).resolve().parent).resolve()
    missing = [f for f in files if not (root / f).is_file()]
    if missing:
        sys.exit("这些文件不存在：" + ", ".join(missing))

    S.headers.update({
        "Authorization": f"Bearer {token()}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })

    ref = call("GET", f"{API}/git/ref/heads/{BRANCH}")
    head = ref["object"]["sha"]
    head_commit = call("GET", f"{API}/git/commits/{head}")
    base_tree = head_commit["tree"]["sha"]
    first = (head_commit.get("message") or "").splitlines()
    print(f"远端 HEAD {head[:7]}  ({first[0][:60] if first else '?'})")

    tree = []
    for rel in files:
        data = (root / rel).read_bytes()
        blob = call("POST", f"{API}/git/blobs",
                    json={"content": base64.b64encode(data).decode(), "encoding": "base64"})
        tree.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        print(f"  blob {rel:<24} {len(data):>8} bytes -> {blob['sha'][:7]}")

    new_tree = call("POST", f"{API}/git/trees",
                    json={"base_tree": base_tree, "tree": tree})
    commit = call("POST", f"{API}/git/commits",
                  json={"message": msg, "tree": new_tree["sha"], "parents": [head]})
    call("PATCH", f"{API}/git/refs/heads/{BRANCH}",
         json={"sha": commit["sha"], "force": False})

    print(f"已推送 {commit['sha'][:7]} → {BRANCH}")
    print(f"CI: https://github.com/{REPO}/actions")


if __name__ == "__main__":
    main()
