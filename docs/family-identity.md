# Family Gateway 的可配置身份验证

2026-11-03。`OidcJwtVerifier` 是可选的 RS256/OIDC 验证适配器，不负责注册账号、登录页面、购买服务、签发身份或恢复管理员账号。没有配置时 Gateway 仍返回不可用，不能改用客户端 Dad/Mom 署名或二维码角色作为认证。

安装 `services/family_gateway/requirements-auth.txt` 的固定依赖后，宿主可以显式传入：

```python
from services.family_gateway import Gateway, OidcJwtVerifier

verifier = OidcJwtVerifier(
    issuer=operator_configured_issuer,
    audience=operator_configured_gateway_audience,
    jwks_url=operator_configured_https_jwks_url,
)
# database、origin、object_store 均由宿主在私有配置中明确提供。
app = Gateway(database, origin=gateway_https_origin,
              verify_bearer=verifier, object_store=dedicated_object_store)
```

示例不包含可用生产配置，也不会启动服务器。issuer、audience、JWKS URL 不能来自待验证 JWT 的 `jku` / `jwk`、二维码或请求体。真实会话应由选定身份提供方的受支持登录流程取得；不要把其他 App 的 ID token、长期云密钥或 NAS 密码当作 Gateway bearer。

适配器固定只验 RS256，使用 PyJWT/cryptography 验证签名及 issuer、单一 audience、必需 claims 与有效期；额外检查整数日期、最大会话时长、UTF-8、重复字段和公钥范围。默认最长会话 900 秒，可显式配置至最多 3600 秒。subject 按配置 issuer 和外部 sub 一起哈希形成稳定成员标识，避免不同提供方同名 sub 混淆；角色仍完全取服务端成员表。

JWKS 仅从显式 HTTPS URL 获取，默认系统证书和继承代理、不跟随重定向，10 秒超时、64 KiB/20 keys 上限，缓存默认 300 秒。未知 key 的重新获取有最短间隔；刷新失败会关闭授权，不回退到过期公钥、未验签内容或客户端自报身份。宿主可在确认密钥轮换后调用 `invalidate_keys()`。不能把缓存策略解读为即时身份会话撤销；已签发 JWT 可能持续有效至到期，成员撤销仍由 Gateway 每次操作及流式检查拒绝。

实际验证使用本地临时 RSA 密钥和假 JWKS 获取器，没有连接真实身份提供方。测试涵盖签名、过期、轮换、并发刷新、编码、注入和错误脱敏。它们不能证明真实供应商的 JWT audience/claims 配置正确。

仍需的具体资源：选定提供方的精确 issuer、专用 gateway audience、公开 JWKS HTTPS 地址及其云端网络许可、受支持的 App 登录会话接入、管理员身份恢复策略。真实 TLS 前端必须验证 Host，只能由受信任宿主设置 `wsgi.url_scheme=https`；不信任来自用户请求的 Forwarded / X-Forwarded-Proto。这里没有配置真实提供方或生产部署。

API 行为依据 [PyJWT API](https://pyjwt.readthedocs.io/en/stable/api.html) 与 [官方安装说明](https://pyjwt.readthedocs.io/en/stable/installation.html)。
