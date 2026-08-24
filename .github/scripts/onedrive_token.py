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
#
# 输出：rclone 可直读的 token JSON：
#   {"access_token":"...","token_type":"Bearer","expiry":"YYYY-mm-ddTHH:MM:SS.000000000Z"}
# ============================================================
import os
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
    "expiry": time.strftime("%Y-%m-%dT%H:%M:%S.000000000Z", time.gmtime(exp)),
}
print(json.dumps(out))
