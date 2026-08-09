# Fluxgram 通知服务

这是 Fluxgram 的 NAS 端 Bark 通知监听服务。真实配置只保存在 NAS 的 `.env`，不要复制到仓库。

通知去重记录保存在 NAS 数据卷的 `/data/seen-messages.json`，服务重启后仍会保留最近的消息 ID，避免同一条消息重复推送。Bark 失败的消息 ID 会保存在 `/data/pending-notifications.json`，重启后通过 Telegram 重新读取并重试。

## NAS 部署

部署目录：由你的 Docker 部署环境决定，例如 `./services/tg-notify`。

重建并启动：

```sh
docker compose up -d --build tg-notify
```

查看状态和日志：

```sh
docker ps --filter name=tg-notify
docker logs --tail 100 tg-notify
```

## 通知开关

`GET /status` 查看监听状态，`POST /control` 开关通知监听。两个接口都必须携带 NAS 上 `.env` 中配置的 `NOTIFY_STATUS_TOKEN`，请求头为 `X-TGAPP-Token`。

```sh
curl -H "X-TGAPP-Token: $NOTIFY_STATUS_TOKEN" http://127.0.0.1:30178/status
curl -X POST -H "X-TGAPP-Token: $NOTIFY_STATUS_TOKEN" \
  -H "content-type: application/json" \
  -d '{"enabled":false}' \
  http://127.0.0.1:30178/control
```

关闭后服务容器仍保持运行，但会断开 Telegram 监听、停止轮询和 Bark 投递，并清除待重试通知。重新开启后自动重连，并从当前消息位置开始，不补发关闭期间的旧消息。开关状态保存在 `/data/notification-settings.json`，重启容器后仍然有效。

## 公开资源

Fluxgram 默认通知图标和会话动态头像位于 TGAPP 的 `public/notify-avatars` 目录，公网地址使用实际代理到 TGAPP 的域名：

`https://your-gateway.example.com/notify-avatars/fluxgram-icon.png`

该目录由 TGAPP 在鉴权中间件之前以静态资源方式提供；其他静态资源和 API 仍保持原有鉴权策略。

## 恢复原则

恢复时只需要还原源码、保留 NAS `.env` 和 `/data` 会话目录，然后重新执行 Compose 启动命令。不要把设备令牌、Telegram 会话、访问令牌或代理配置写入 Git。
