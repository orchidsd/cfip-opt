# Cloudflare 优选 IP 一键管理

在软路由(OpenWrt)上自动测速挑选 Cloudflare 优选 IP，并把结果写入 Cloudflare DNS 解析池，让访客自动就近/最优接入。支持 Telegram / PushPlus 推送结果、高峰时段自动跳过、DNS 自愈看门狗。

## 特性

- **优选 + 更新 DNS**: 停代理 → 测速(CloudflareST) → 清超期/失效记录 → 写解析池 → 重启代理 → 推送通知
- **灵活模式**: `domain`(写域名解析池) / `ip`(只出结果不写 DNS)；`multi_to_one`(一条解析推多条) / `one_to_one`(每个域名固定 IP)
- **智能通知**: 排名表(手机一行放下不折行)、候选/通过/剔除数、与上次对比趋势、执行明细
- **高峰跳过**: 跨午夜高峰时段(默认 21:00→6:00)跳过测速，避免晚高峰测出假差结果
- **验证与自愈**: 推送前延迟验证 + watchdog 每 5 分钟探测、连续失败自动重跑/回滚
- **定时任务**: 内置每天 5/13/21 点优选，可交互式自定义时刻

## 安装

在路由器上执行(任意 OpenWrt / Alpine / Debian / CentOS):

```bash
# 方式一: 就地安装(推荐): 把整个项目 scp 上路由器后
cd /root/cfip-opt && bash bin/install.sh

# 方式二: 远程一键安装(不依赖 git，推荐)
# GitHub 不通时用国内镜像把下面 URL 换成 https://ghfast.top/https://github.com/... 即可
bash -c 'curl -fsSL https://github.com/orchidsd/cfip-opt/archive/refs/heads/main.tar.gz | tar xz -C /tmp && mv /tmp/cfip-opt-main /tmp/cfip-opt && bash /tmp/cfip-opt/bin/install.sh'
```

安装脚本做的事(幂等，重复执行安全):

1. 安装依赖 `bash jq curl` 等
2. 按架构下载 `cfst`(CloudflareST) 测速二进制并复用其 IP 列表
3. 生成默认配置 `conf/config.json`
4. 注册定时任务 + 创建全局命令 `cfip`(重登 shell 生效)

## 快速开始

```bash
cfip            # 进入交互菜单
cfip            # [5] 账号与解析池: 填 Cloudflare 邮箱 / Zone ID / API Key
cfip            # [4] 基本设置: 确认 mode/ip_version/port
cfip            # [16] 定时任务: 如不需要定时可直接跳过默认 5/13/21 点
cfip-opt.sh run # 首次试跑
cfip            # [11] 运行状态: 查看代理/测速/DNS池/看门狗
```

## 使用方式

### 1. 交互菜单(裸命令 `cfip` 或 `cfip-opt.sh`)

| 编号 | 功能 | 说明 |
|----|------|------|
| **主操作** | | |
| 1 | 一键完整优选 | 测速 + 更新DNS + 通知 (期间短暂断网) |
| 2 | 仅测速 | 不更新 DNS，调试/挑选用 |
| 3 | 仅更新 DNS | 用上次测速结果更新 |
| **修改配置** | | |
| 4 | 基本设置 | 模式 / IP版本 / 端口 |
| 5 | 代理客户端 | openclash / passwall / ... (枚举选择) |
| 6 | 账号与解析池 | 邮箱 / Zone ID / API Key / 池条数 |
| 7 | 测速设置 | 线程 / 延迟 / 丢包 / 测速源地址 |
| 8 | 高级参数 | 低频微调项 |
| 9 | 验证与自愈 | 推送前验证 / 看门狗 |
| 10 | IP列表与通知 | TG / PushPlus |
| **查看 / 工具** | | |
| 11 | 运行状态 | 代理 / 测速 / DNS池 / 看门狗 / 定时任务 |
| 12 | 显示当前配置 | |
| 13 | 测试通知 | 手动发一条测试通知 |
| 14 | 回滚上次 DNS 快照 | |
| 15 | 更新 IP 列表 | |
| 16 | 定时任务 | 优选时刻 / 看门狗间隔 |
| 17 | 高峰跳过 | 晚高峰不测速(跨午夜区间) |
| 18 | 启动代理客户端 | **手动退出优选后代理被停时应急拉起** |
| 0 | 退出 | |

### 2. 命令行子命令(适合 cron / 脚本)

```bash
cfip-opt.sh run       # 完整优选流程(默认, cron 用)
cfip-opt.sh config    # 交互式配置(全部分组)
cfip-opt.sh show      # 显示当前配置
cfip-opt.sh test      # 仅测速(含代理停启)
cfip-opt.sh dns       # 仅更新 DNS
cfip-opt.sh status    # 运行状态面板
cfip-opt.sh notify    # 测试通知
cfip-opt.sh rollback  # 回滚上次 DNS 快照
cfip-opt.sh ipupdate  # 立即更新 IP 列表
cfip-opt.sh start     # 手动启动代理客户端(应急)
```

### 3. 定时任务

```bash
cfip  # [16] 定时任务: 交互式设置优选时刻与看门狗间隔
```

默认定时(已由 install.sh 写入 cron):

```
0 5,13,21 * * * /root/cfip-opt/bin/cfip-opt.sh run   # 每天 5/13/21 点优选
*/5 * * * *     /root/cfip-opt/bin/watchdog.sh        # 看门狗每 5 分钟自检
```

## 配置说明

配置文件 `conf/config.json`(建议用菜单修改，会同时校验):

```jsonc
{
  "mode": "domain",                 // domain=写DNS池, ip=只测速
  "ip_version": "ipv4",             // ipv4 / ipv6
  "port": 443,                      // Cloudflare 接入端口
  "speed_test": {                   // 测速参数(线程/次数/丢包上限/区码筛选等)
    "enabled": true,
    "url": "https://nodejs.org/dist/v20.11.0/node-v20.11.0.tar.gz",
    "threads": 200,                 // 并发测速线程
    "display_count": 10,            // 通知排名表展示条数
    "colo": "TPE,HKG,NRT,..."       // 只测指定机房(留空=全全球)
  },
  "verify": {                       // 推送前验证
    "enabled": true,
    "max_ms": 1200,                 // 超过该延迟剔除
    "probes": 3                     // 探测次数
  },
  "watchdog": {                     // 自愈看门狗
    "enabled": true,
    "auto_run": true,               // 连续失败后自动重跑优选
    "fail_consecutive": 3
  },
  "ip_list": {
    "auto_update": true,            // 过期自动下载新列表
    "max_age_days": 7
  },
  "peak_hours": {                   // 高峰跳过(跨午夜: start>end 也支持)
    "enabled": false,               // true=高峰时段不测速
    "start": 21,                    // 21:00
    "end": 6                        // 至次日 06:00
  },
  "cloudflare": {
    "email": "",                    // Cloudflare 账号邮箱
    "zone_id": "",                  // 区域 ID
    "api_key": "",                  // Global API Key
    "domain": "",                   // 主域名
    "subdomain": "",                // 子域名(写入解析)
    "strategy": "multi_to_one",     // multi_to_one(一条多IP) / one_to_one(每域名一IP)
    "hostname": "",                 // one_to_one 模式下的域名列表
    "min_records": 6,               // 池目标条数
    "keep_days": 2,                 // 记录保留天数(超期清除)
    "max_records": 24               // 池上限
  },
  "proxy_client": "openclash",      // 代理客户端(openclash/passwall/...)
  "notifications": {
    "telegram": {
      "enabled": true,
      "bot_token": "",
      "user_id": "",
      "api_host": "api.telegram.org" // 可填反代，如 tg.weiguang4.eu.org
    },
    "pushplus": { "enabled": false, "token": "" }
  }
}
```

## 通知模板

每次优选完成推送一条 Telegram HTML 消息，包含:

```
Cloudflare 优选 IP
状态: 完成        时间: 2026-09-14 00:18:25 · 用时 1分9秒
配置: IPv4 · :443 · 验证≤1200ms
测速源: <url>(来源)  解析: cdn.xxx.com(multi_to_one 固定5条 保留2天)

排名(候选 24 · 通过 10 / 剔除 14)
#  IP              ms   MB/s  REG
1  172.67.236.143  185  4.8    FRA
2  ...

较上次: 延迟 154.3ms→185ms ↑(30.7ms) · 速度 46.7→4.8MB/s

执行明细(略)
```

## 故障排查

| 现象 | 处理 |
|------|------|
| 手动退出优选后代理停了 | 菜单 `[18] 启动代理客户端` 或 `cfip-opt.sh start` |
| Telegram 收不到通知 | 菜单 `[13] 测试通知`；检查 `api_host` 连通(可换反代)与 `bot_token/user_id` |
| 通知表格折行 | 表格已按 32 字符/行压缩，若手机仍折行说明屏幕过窄，可减少 `display_count` |
| run 后没推送 | 看 `/root/cfip-opt/informlog`；高峰时段会跳过并推送"跳过"通知 |
| DNS 池一直低于目标 | 降低 `min_records` 或 `max_records` 待填满；检查 `keep_days` 未见效时改回 2 |
| 主流不可达 | 换 `speed_test.url`(测速源)为稳定下载地址；加大 `download_timeout` |

## 目录结构

```
cfip-opt/
├── bin/
│   ├── cfip-opt.sh    # 主程序(菜单 + CLI 子命令)
│   ├── install.sh     # 一键安装
│   ├── uninstall.sh   # 卸载(清 cron/命令/文件)
│   ├── watchdog.sh    # 自愈看门狗(cron 每5分钟)
│   └── tools/         # 运维辅助脚本(诊断/参数微调)
├── lib/
│   ├── common.sh      # 公共函数(日志/校验/高峰判断)
│   ├── config.sh      # 配置管理(校验/交互向导)
│   ├── ip_test.sh     # 测速模块(调用 cfst)
│   ├── dns_update.sh  # DNS 池维护(CF API 增删查)
│   ├── notify.sh      # 通知组装与发送(TG/PushPlus)
│   └── proxy.sh       # 代理客户端停/启/重启
├── conf/config.json.example
└── ip/               # IP 列表(自动维护)
```