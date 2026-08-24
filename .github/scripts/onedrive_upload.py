#!/usr/bin/env python3
# ============================================================
# onedrive_upload.py —— 用「自建应用 + 证书」经 Microsoft Graph 直传文件到 OneDrive
# ------------------------------------------------------------
# 为什么不用 rclone：
#   rclone 的 onedrive 后端在 app-only（证书 / client_credentials）场景下
#   必须显式 drive_id，且 onedrive 类型在 client_credentials 下官方明确不支持，
#   只能走 sharepoint 类型 + drive_id，配置繁琐且 E5 教育/商业版盘本质就是
#   SharePoint 个人站点。本脚本直接调用 Graph 的 upload session API（官方原生
#   支持 app-only），用 UPN 路径定位用户盘，免 drive_id、免 rclone 中间层。
#
# 官方上传方式（已查文档）：
#   POST /users/{user_id}/drive/root:/{path}:/createUploadSession
#   再对返回的 uploadUrl 按 4-60 MiB（最大 60 MiB）分片顺序 PUT。
#   单个 upload session 的分片必须顺序（协议层不支持同 session 并发分片），
#   但多个文件可各自开 session 并行（调用方并行传 .tar.zst 与 .sha256 即可）。
#   支持断点续传：服务端 202 响应带回 nextExpectedRanges，失败可从中断处重传。
#
# 环境变量（来自 CI Secret）：
#   ONEDRIVE_CLIENT_ID / ONEDRIVE_TENANT / ONEDRIVE_CERT / ONEDRIVE_KEY  —— 证书四件套
#   ONEDRIVE_USER_ID   —— 目标用户 UPN（如 admin@zh33.onmicrosoft.com），定位其盘
#   ONEDRIVE_UPLOAD_PATH —— 盘内目标目录（默认 acok），文件落地为 <path>/<basename>
#
# 命令行参数：onedrive_upload.py <local-file> [remote-subdir]
# 退出码：0 成功；非 0 失败（调用方据此告警而非阻断整条流水线）
# ============================================================
import os
import re
import sys
import time
import json
import base64
import hashlib

try:
    import msal
except ImportError:
    sys.stderr.write("缺少 msal：请先 `pip install msal`\n")
    sys.exit(2)

# 仅本地调试用；CI 中走环境变量
GRAPH = "https://graph.microsoft.com/v1.0"

client_id = os.environ.get("ONEDRIVE_CLIENT_ID")
tenant = os.environ.get("ONEDRIVE_TENANT")
cert_pem = os.environ.get("ONEDRIVE_CERT")
key_pem = os.environ.get("ONEDRIVE_KEY")
user_id = os.environ.get("ONEDRIVE_USER_ID")
upload_path = os.environ.get("ONEDRIVE_UPLOAD_PATH", "acok")
scope = os.environ.get("ONEDRIVE_SCOPE", "https://graph.microsoft.com/.default")

for var, val in (
    ("ONEDRIVE_CLIENT_ID", client_id),
    ("ONEDRIVE_TENANT", tenant),
    ("ONEDRIVE_CERT", cert_pem),
    ("ONEDRIVE_KEY", key_pem),
    ("ONEDRIVE_USER_ID", user_id),
):
    if not val:
        sys.stderr.write(f"缺少环境变量 {var}\n")
        sys.exit(2)


def normalize_pem(raw: str, what: str) -> str:
    """把任意形态(压平一行 / 带 \\r / 缺换行)的 PEM 归一为标准多行 PEM。"""
    if not raw:
        return raw
    raw = raw.replace("\r", "")
    m = re.search(
        r"-----BEGIN ([A-Z0-9 ]*?(?:PRIVATE KEY|CERTIFICATE))-----(.*?)-----END \1-----",
        raw, re.S,
    )
    if not m:
        return raw
    label = m.group(1)
    body = re.sub(r"\s+", "", m.group(2))
    if not body:
        return raw
    chunks = [body[i:i + 64] for i in range(0, len(body), 64)]
    return "-----BEGIN {}-----\n{}\n-----END {}-----\n".format(
        label, "\n".join(chunks), label
    )


cert_pem = normalize_pem(cert_pem, "cert")
key_pem = normalize_pem(key_pem, "key")

try:
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    from cryptography.x509 import load_pem_x509_certificate
    load_pem_private_key(key_pem.encode(), password=None)
    load_pem_x509_certificate(cert_pem.encode())
except ImportError:
    # cryptography 通常由 msal 间接依赖安装；CI 环境必有。本地缺则跳过校验，不阻断。
    sys.stderr.write("  警告: 本地缺 cryptography 模块，跳过证书预校验（CI 中 msal 会自动带入）\n")
except Exception as e:  # noqa
    sys.stderr.write(
        "ONEDRIVE 证书/私钥经归一化后仍无法解析: {}\n".format(e)
        + "  常见原因: (1) Secret 不含 -----BEGIN/END----- 标签;\n"
        + "            (2) 粘贴的不是 X.509 证书+私钥对;\n"
        + "            (3) 内容被截断。\n"
    )
    sys.exit(2)

try:
    b64 = "".join(cert_pem.split("-----")[2].split())
    cert_der = base64.b64decode(b64)
    thumbprint = hashlib.sha1(cert_der).hexdigest().upper()
except Exception as e:  # noqa
    sys.stderr.write(f"证书解析失败: {e}\n")
    sys.exit(2)

authority = f"https://login.microsoftonline.com/{tenant}"
app = msal.ConfidentialClientApplication(
    client_id,
    authority=authority,
    client_credential={"thumbprint": thumbprint, "private_key": key_pem},
)

token = app.acquire_token_for_client(scopes=[scope])
if "access_token" not in token:
    sys.stderr.write("获取令牌失败: " + json.dumps(token, ensure_ascii=False) + "\n")
    sys.exit(1)

ACCESS_TOKEN = token["access_token"]
HTTP_TIMEOUT = 300  # 单分片上传超时（秒），3GB 按 60MiB 分片单片约数秒，留足余量


def http_put(url, data, headers):
    """极简 PUT（避免引入 requests 依赖；CI 仅装 msal）。"""
    import urllib.request
    import urllib.error
    req = urllib.request.Request(url, data=data, method="PUT")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        return e.code, body


def http_post_json(url, headers, body):
    import urllib.request
    import urllib.error
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def upload_file(local_file, subdir):
    name = os.path.basename(local_file)
    # UPN 含 @ 需 URL 编码；路径用 users/{user}/drive/root:/{path}: 形式
    from urllib.parse import quote
    safe_user = quote(user_id, safe="")
    safe_path = quote(f"{subdir}/{name}")
    session_url = (
        f"{GRAPH}/users/{safe_user}/drive/root:/{safe_path}:/createUploadSession"
    )
    headers = {
        "Authorization": f"Bearer {ACCESS_TOKEN}",
        "Accept": "application/json",
    }
    # deferCommit=False：所有分片传完即自动提交，避免额外 commit 请求
    status, body = http_post_json(session_url, headers, {"item": {"@microsoft.graph.conflictBehavior": "replace"}})
    if status != 200 and status != 201:
        sys.stderr.write(f"createUploadSession 失败 ({status}): {body}\n")
        return False
    try:
        upload_url = json.loads(body)["uploadUrl"]
    except (KeyError, ValueError) as e:
        sys.stderr.write(f"createUploadSession 响应解析失败: {e}\n{body}\n")
        return False

    fsize = os.path.getsize(local_file)
    frag = 60 * 1024 * 1024  # 60 MiB 单分片（官方推荐上限）
    uploaded = 0
    retries = 5
    with open(local_file, "rb") as fh:
        while uploaded < fsize:
            buf = fh.read(frag)
            if not buf:
                break
            end = uploaded + len(buf) - 1
            chunk_headers = {
                "Authorization": f"Bearer {ACCESS_TOKEN}",
                "Content-Length": str(len(buf)),
                "Content-Range": f"bytes {uploaded}-{end}/{fsize}",
            }
            ok = False
            for attempt in range(retries):
                st, rb = http_put(upload_url, buf, chunk_headers)
                if st in (200, 201, 202):
                    ok = True
                    # 202 = 还有更多分片；200/201 = 整体完成
                    if st in (200, 201):
                        uploaded = fsize
                    else:
                        # 用 nextExpectedRanges 校正已传位置，支持断点续传
                        try:
                            nxt = json.loads(rb).get("nextExpectedRanges", [f"{end+1}-"])
                            uploaded = int(nxt[0].split("-")[0])
                            fh.seek(uploaded)
                        except Exception:
                            uploaded = end + 1
                    break
                # 5xx / 429 重试；其余（4xx）直接失败
                if st == 429 or 500 <= st < 600:
                    time.sleep(min(2 ** attempt, 30))
                    continue
                sys.stderr.write(f"分片上传失败 ({st}): {rb}\n")
                return False
            if not ok:
                sys.stderr.write("分片上传重试耗尽，上传中止\n")
                return False
            sys.stderr.write(f"  进度 {uploaded}/{fsize} ({uploaded*100//fsize}%)\n")
    return True


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("用法: onedrive_upload.py <local-file> [remote-subdir]\n")
        sys.exit(2)
    local_file = sys.argv[1]
    if not os.path.isfile(local_file):
        sys.stderr.write(f"文件不存在: {local_file}\n")
        sys.exit(1)
    subdir = sys.argv[2] if len(sys.argv) > 2 else upload_path
    sys.stderr.write(f">> [OneDrive] 上传 {os.path.basename(local_file)} -> {subdir}/\n")
    if upload_file(local_file, subdir):
        sys.stderr.write("   OneDrive 上传完成\n")
        sys.exit(0)
    else:
        sys.stderr.write("   OneDrive 上传失败\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
