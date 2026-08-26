# TK 新闻工作台公开安装器

这是 `TK新闻精品二创工作台` 的公开启动入口。新电脑在**管理员 PowerShell** 运行：

```powershell
irm https://raw.githubusercontent.com/qq541253643-art/tk-news-installer/refs/heads/main/install.ps1 | iex
```

安装器会在本机生成一把独立的 Ed25519 密钥，只把公钥复制到剪贴板。请把公钥发给 GitHub 管理电脑，由管理员添加到私有主仓库的 `Settings → Deploy keys`，并保持 `Allow write access` 未勾选。生产电脑不需要登录 GitHub。

## 公开范围

本仓库只包含可审计的安装脚本和这份说明，不包含私有主项目、GitHub 令牌、私钥、模型、源素材或成片。私钥只保存在生成它的电脑，安装器不会显示、复制或上传私钥。

首次安装仍需要联网下载项目依赖和模型。网络中断后可重新运行同一条命令，安装链会复用已经完成的系统组件、项目目录和 Python 下载缓存。
