# 远程调试日志

[English](remote-debug-log.md) | **简体中文**

当你连不上自己的 iPhone 时（比如手机用蜂窝网络、插着板子），拉取 App 的**文本**调试日志（`Documents/debug.log`）。
iPhone 不能接受连接，所以由 App 轮询你自己部署的一个小服务器：你在服务器上发起请求，App 上传所要的日志末尾部分。

- **默认关闭。** 设置 › 开发者 › 远程调试日志：端点 URL 和令牌。两项都为空时完全不发网络请求。令牌存在钥匙串里；
  两项都不进设置备份。
- **只有文本。** 只上传 debug.log 的文本行，绝不上传截图、视频或运行记录文件。上传前 App 会移除模型密钥、其他已存的密钥、
  通道令牌、形似令牌的字符串、`Authorization` 头和 `key=…` 键值、内嵌图片、IP 地址和输入的文字。
- **何时轮询：** App 打开或正在运行任务时约每 30 秒一次（不新增后台模式）。
- **免手动输入的配置方式：** 把内容为 `{"url": "https://…", "token": "…"}` 的 `remote-debug-log.json` 放进 App 的
  Documents（访达 › iPhone › 文件，或
  `xcrun devicectl device copy to --device <id> --domain-type appDataContainer --domain-identifier <bundle id> --source remote-debug-log.json --destination Documents/remote-debug-log.json`）。
  App 约 30 秒内导入并删除该文件。

## 服务器 API（自行部署）

任何 HTTPS 服务器都可以，例如 Cloudflare Worker 加私有 R2 存储桶。`<url>` 即 App 里填的端点 URL。

| 路由 | 请求 | 响应 |
|---|---|---|
| `POST <url>/poll` | `Authorization: Bearer <token>`，请求体 `{}` | `{"want": {"id": "ab12cd34", "minutes": 5}}`（或 `"lines": 2000`），无事可做时 `{}` |
| `POST <url>/upload` | `Authorization: Bearer <token>`、`Content-Type: text/plain; charset=utf-8`、`X-Request-Id: <want.id>`，请求体为日志文本（≤ 1.9 MB） | 成功返回 `200` |

`minutes` = 最近 N 分钟内带时间戳的行；`lines` = 最后 N 行。服务器应以常数时间比较令牌、拒绝非 UTF-8 文本的请求体、
限制大小（2 MB）、限制上传频率并删除旧日志。管理端（发起请求、列出和读取上传）由你自己实现。

```sh
# App 发出的请求
curl -X POST -H "Authorization: Bearer $TOKEN" -d '{}' https://logs.example.com/poll
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: text/plain; charset=utf-8" \
     -H "X-Request-Id: ab12cd34" --data-binary @tail.log https://logs.example.com/upload
```
