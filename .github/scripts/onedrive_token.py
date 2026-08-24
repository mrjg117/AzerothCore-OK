#!/usr/bin/env python3
# ============================================================
# onedrive_token.py —— 用「自建应用 + 证书」换 OneDrive app-only 访问令牌
# ------------------------------------------------------------
# 你的 E5 账号使用 Azure AD 企业应用 + X.509 证书鉴权（非 client secret）。
# rclone 的 onedrive 后端不支持证书直接鉴权（其 client_credentials 只认 client secret），
# 因此本脚本用 msal 以证书签名 client_assertion 换取 Graph app-only 令牌，
# 再由调用方把令牌喂给 rclone 的 token 配置（配合 drive_id 实现 app-only 上传）。
#
# 环境变量（来自 CI Secret）：
#   ONEDRIVE_CLIENT_ID   Azure AD 应用(客户端) ID
#   ONEDRIVE_TENANT     租户 ID（如 zh33.onmicrosoft.com 或 GUID）
#   ONEDRIVE_CERT      证书 PEM（含 -----BEGIN CERTIFICATE-----）
#   ONEDRIVE_KEY       私钥 PEM（含 -----BEGIN PRIVATE KEY----- / EC PRIVATE KEY）
#   （可选）ONEDRIVE_SCOPE  默认 https://graph.microsoft.com/.default
#   注：选盘/目录变量（ONEDRIVE_USER_ID / ONEDRIVE_DRIVE_ID / ONEDRIVE_UPLOAD_PATH）
#       在 upload_artifacts.sh 中消费，本脚本只负责证书→令牌。
#
# 输出：rclone 可直读的 token JSON：
#   {"access_token":"...","token_type":"Bearer","expiry":"YYYY-mm-ddTHH:MM:SS.000000000Z"}
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

client_id = os.environ.get("ONEDRIVE_CLIENT_ID")
tenant = os.environ.get("ONEDRIVE_TENANT")
cert_pem = os.environ.get("ONEDRIVE_CERT")
key_pem = os.environ.get("ONEDRIVE_KEY")
scope = os.environ.get("ONEDRIVE_SCOPE", "https://graph.microsoft.com/.default")

for var, val in (
    ("ONEDRIVE_CLIENT_ID", client_id),
    ("ONEDRIVE_TENANT", tenant),
    ("ONEDRIVE_CERT", cert_pem),
    ("ONEDRIVE_KEY", key_pem),
):
    if not val:
        sys.stderr.write(f"缺少环境变量 {var}\n")
        sys.exit(2)


def normalize_pem(raw: str, what: str) -> str:
    """把任意形态(压平一行 / 带 \\r / 缺换行)的 PEM 归一为标准多行 PEM。

    只重排换行，不改变密钥内容。识别 -----BEGIN <标签>----- ... -----END <标签>-----
    之间的 base64 主体，去除所有空白后按每 64 字符重新换行。
    标签支持 CERTIFICATE / PRIVATE KEY / RSA PRIVATE KEY / EC PRIVATE KEY 等。
    """
    if not raw:
        return raw
    raw = raw.replace("\r", "")
    m = re.search(
        r"-----BEGIN ([A-Z0-9 ]*?(?:PRIVATE KEY|CERTIFICATE))-----(.*?)-----END \1-----",
        raw, re.S,
    )
    if not m:
        # 无标准标签：原样返回，交由下方 cryptography 校验给出明确人话报错
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

# 前置校验：归一化后若仍解析失败，给人话而非 msal 深层 traceback
try:
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    from cryptography.x509 import load_pem_x509_certificate
    load_pem_private_key(key_pem.encode(), password=None)
    load_pem_x509_certificate(cert_pem.encode())
except Exception as e:  # noqa
    sys.stderr.write(
        "ONEDRIVE 证书/私钥经归一化后仍无法解析: {}\n".format(e)
        + "  常见原因: (1) Secret 不含 -----BEGIN/END----- 标签;\n"
        + "            (2) 粘贴的不是 X.509 证书+私钥对;\n"
        + "            (3) 内容被截断。\n"
        + "  本地自检: openssl x509 -in cert.pem -noout -subject\n"
        + "            openssl pkey  -in key.pem  -check  -noout\n"
    )
    sys.exit(2)

# 证书指纹(thumbprint)：SHA1(证书 DER)，msal 证书鉴权必需
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

exp = int(time.time()) + int(token.get("expires_in", 3600))
out = {
    "access_token": token["access_token"],
    "token_type": token.get("token_type", "Bearer"),
    # app-only 流程无 refresh_token；rclone 的 token blob 要求该键存在（空串即可），
    # 否则 rclone 初始化 onedrive remote 时会报配置不完整。
    "refresh_token": "",
    "expiry": time.strftime("%Y-%m-%dT%H:%M:%S.000000000Z", time.gmtime(exp)),
}
print(json.dumps(out))
