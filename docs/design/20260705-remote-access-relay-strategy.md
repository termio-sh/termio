---
title: 远程访问与中转策略（tunelo / BYO-tunnel）
status: draft
type: design
created: 2026-07-05
updated: 2026-07-05
related:
  - 20260628-session-share.md
---

# 设计：Termio 手机↔Mac 远程访问的中转策略

> 手机companion 如何在公网上找到 Mac：短期白嫖别人的免费隧道（BYO-tunnel），长期把自研的 tunelo 改造成一个只服务 Termio 的托管 rendezvous relay。本文记录两条路线、tunelo 的具体改造点，以及从 OpenClaw 等同类项目学到的"零基础设施"模式。

## 0. 结论先行

- **手机侧只需要 URL 稳定，不需要中心 relay。** 配对时手机已记住 `(URL, token)`；痛点全来自现在用的 cloudflared **quick tunnel**（每次重建换随机 URL → 手机 unauthorized → 重新配对）。换成**稳定 URL** 即解决。
- **行业不发 per-host 长期公网 URL。** TeamViewer/AnyDesk/Chrome Remote Desktop/Tailscale/VS Code Tunnels/sshx/Happy 都是"**中心 rendezvous broker + 两端 outbound + ID/token 路由**，P2P-first、relay 只兜底"。cloudflared 的 ingress **不能跨用户按 token 路由**——那件事必须由一个 relay 进程做。
- **成本几乎为零的前提**：不用 Cloudflare Access 座位鉴权、不给每台 Mac 单独发 DNS 记录。真正会撞墙的是**单 zone DNS 记录配额**和**滥用条款**，不是"隧道每条多少钱"（Named Tunnel 单条 = 免费、无带宽费）。
- **两条路线**：
  - **短期 = BYO-tunnel（白嫖）**：Termio 不运营任何 relay，隧道由用户自带（cloudflared / ngrok / Tailscale 的免费额度）。零基础设施，也**没有 relay 可被白嫖**。这正是 OpenClaw 的做法。
  - **长期 = 托管 tunelo relay**：把自研 tunelo 改成 token-keyed rendezvous broker，给"开箱即用、不配隧道"的体验；代价是要防开源白嫖 → 用已有的 Lemon Squeezy 授权后端签短期 token 准入。

## 1. Cloudflare 定价核对（2026-07）

- **Named Tunnel 一条 = 免费**，隧道数量不限，**隧道流量不计费**（无 egress）。Named vs quick tunnel 的区别只是"固定 UUID + 固定 hostname + 自动重连 + 可挂自己域名"。
- 会掏钱的是 **Zero Trust / Access 座位**：免费 ≤50 用户，超出 **$7/user/月**。**只有用 Cloudflare 自带登录鉴权挡在隧道前才触发**——Termio 走自己的 pairing token，**不吃这条**。
- 几万用户的真实瓶颈（都不是钱）：
  1. **一 Mac 一隧道 = 一条 DNS 记录**，单 zone 记录数有软上限（非企业版几千量级）。**wildcard 救不了**——`*.t.termio.sh` 只能指向一条隧道 = 一台 Mac。
  2. **"disproportionate load" 滥用条款**。
  3. **quick tunnel 不能上生产**（限速、URL 随机）。

来源：[Cloudflare — Free Tunnels for Everyone](https://blog.cloudflare.com/tunnel-for-everyone/)、[Zero Trust Plans & Pricing](https://www.cloudflare.com/plans/zero-trust-services/)。

## 2. 目标架构（token 路由）

```
现在:  phone  --inbound-->  <随机>.trycloudflare.com  -->  这台 Mac:8787
目标:  phone  --\                                    /--  Mac (outbound uplink)
                 >-- wss://relay.<domain>?t=TOKEN --<
       两端都 outbound 连同一入口，relay 用 token 当路由键把两条 socket 对接
```

- **cloudflared ingress 不做这个**（只在一台机器内按 hostname/path 分流）。token 路由必须在一个 relay 进程里。
- 关键洞察：**relay 不等于"帮几万人转发全部流量"**。这类产品先 STUN/ICE 打洞 P2P，relay 只兜底约 10–20% 硬 NAT 的连接。而 Termio **只传终端帧不传视频**，纯 WS 中转都无所谓——**连 P2P/TURN 复杂度都不用上**。

## 3. 同类项目怎么做的：OpenClaw = 零基础设施 / BYO-tunnel

OpenClaw（前身 Clawdbot→Moltbot，MIT，GitHub 8 周破 18 万 star 的自托管 AI 助手）的远程访问模式，直接印证了短期路线：

- **它自己不跑任何 relay。** Gateway **默认只绑 loopback（127.0.0.1:18789）+ token/password 鉴权**。
- 远程访问 = **让用户自带隧道**：官方文档首选 **Tailscale Serve**、通用兜底 **SSH tunnel**（`ssh -N -L 18789:127.0.0.1:18789 user@host`）、以及直连 LAN/Tailnet；社区指南再叠加 **Cloudflare Tunnel / ngrok / Localtonet**。
- 它"白嫖"的方式 = **不运营基础设施**，成本甩给每个用户自己的 Cloudflare/Tailscale/ngrok 免费额度 → 项目侧零成本、无限扩、**且没有共享 relay 需要防白嫖**。

> 这对 Termio 的启示：**Q2"防白嫖"只有当你自己跑共享 relay 时才存在。** 采用 OpenClaw 的 BYO 模式，问题自动消失。

来源：[openclaw/openclaw docs/gateway/remote.md](https://github.com/openclaw/openclaw/blob/main/docs/gateway/remote.md)、[Self-Host OpenClaw and Access It Remotely](https://localtonet.com/blog/how-to-self-host-openclaw)。

## 4. 短期方案：BYO-tunnel（复用 Cloudflare / ngrok 免费额度）

Termio 已经具备一切前提：companion 绑 loopback、手机首帧发 `.auth(token)`、`CompanionServer` 验 token（`CompanionServer.swift:257`）——**app 层鉴权端到端已成立，隧道只是哑管**。

- **Mac 侧**：`TunnelManager` 支持"可插拔隧道 provider"——cloudflared quick（现状）/ cloudflared named / ngrok，任选。用户带哪个免费额度都行。
- **UX 现实**：BYO 模式下"稳定 URL"要么靠 cloudflared **named tunnel**（用户自己的 CF 账号+域名，一条 DNS 记在他自己 zone，对你零成本），要么靠 ngrok 付费固定域名。免费 quick tunnel 仍会 churn。
- **净收益**：Termio 不运营 relay、零基础设施成本、**无白嫖者问题**。**代价** = 让用户自己配隧道（UX 门槛），且"relay 可读明文"取决于所选 provider。

这是**先上线、先验证需求**的路线，也是"先白嫖 Cloudflare/ngrok"的确切含义。

## 5. 长期方案：把 tunelo 改造成 Termio 专用 rendezvous relay

tunelo（自研 Rust + QUIC，quinn/rustls）**已经 80% 是 broker**——#4 的 `Attach` visitor role：native visitor 按 subdomain 挂到已存在隧道，之后它开的每条 bidi QUIC 流都桥接到 owner，可跑任意字节协议（WS/裸帧）。配上 #3 "stable subdomain across reconnects"，Termio 直接映射：**Mac = `Register`（稳定名），手机 = 接入，WS 帧端到端跑，QUIC 全程。**

### 5.1 两条接入路径

| | 路径 A：WSS Host 路由（现有 HTTP 面） | 路径 B：native QUIC `Attach` |
|---|---|---|
| 手机侧改动 | **零**（仍 `URLSessionWebSocket` 连 `wss://<name>.<domain>`） | iOS 要塞 QUIC client（quinn FFI / NWConnection） |
| 传输 | 手机→relay 是 TLS，relay→Mac 是 QUIC | 全程 QUIC，多路复用/丢包恢复更好 |
| 隐私 | **relay 看得见明文 WS 帧**（TLS 在 relay 终止） | 便于端到端加密 |

**推荐先路径 A**：手机几乎不改，只把随机 URL 换成稳定 URL。

### 5.2 必须先修的真 bug：subdomain 抢注

`router.rs::resolve_subdomain`：请求名对应的 session 一旦 QUIC 断开（`close_reason().is_some()`）就 **evict 后发给来者**。含义：**Mac 网络一抖，任何知道 subdomain 的人都能 `Register` 抢走它**（现有 `password` 只 gate `Attach`，不 gate `Register` 回收）→ 拒真主 + 占名的 DoS。

**修复 = 稳定身份 owner 自证回收。稳定身份用密钥对，不用机器码。**

> **先看同类项目怎么做（2026-07-05 调研）。** 严肃项目的设备/隧道身份**无一用硬件机器码**，全是"首次运行生成的密钥对 + 稳定名 = hash(公钥)"：
> - **Syncthing**：device ID = `base32(SHA-256(自签证书))`，TLS 握手时对端哈希你的证书即得你的 ID，持私钥即证明是你。
> - **Tailscale**：curve25519 machine/node key，官方明说**不基于硬件 ID**，"机器叫什么名字都无所谓"。
> - **cloudflared / ngrok**：稳定名绑一个 **server 发的秘密凭证**（tunnel credentials.json / authtoken + bind ACL），不是硬件。
> - 机器码库自己的文档也承认：MAC/BIOS/CPU 在 VM 里不可靠，且**未经同意的设备指纹 = GDPR/PECR 违规、用户删不掉**。
>
> **为什么密钥对完胜机器码**：①身份+证明合一（challenge 签名自证，不用额外字段）；②跨平台=一份纯 Rust 代码（`ed25519-dalek`，无 `#[cfg]`；机器码要读三套 OS 源 + 容器里还得兜底存文件，反而更复杂）；③隐私干净（tunelo 开源，躲开硬件指纹）。**机器码只留给 License 3-座位计数**（它擅长"是不是同一台物理机、扛系统重装"），与隧道身份正交，别混。

具体机制：

- **身份**：tunelo client 首次运行生成 Ed25519 密钥对。存储：独立用户 `~/.config/tunelo/identity.key`(0600, via `dirs`)；Termio 嵌入时走 **macOS Keychain**（扛 app 重装，和机器码一样耐久）。
- **命名**：`subdomain = base32_lower(SHA-256(pubkey))[..12]`，client 本地即可算出，不必等 relay 回（QR 可提前生成、永久固定）。
- `protocol/messages.rs` — 新增 `RelayControl::Challenge { nonce }`（relay 连上先发）；`Register` 去掉 `owner_key`，改带 `pubkey` + `signature`（签 `nonce ‖ subdomain`）。
- `relay/src/router.rs` — `resolve_subdomain` → `claim`：
  1. 验签失败 / `hash(pubkey) != subdomain` → 拒；
  2. 名字空闲 → 发；
  3. 被**同一 pubkey** 占 → 发（Mac 重连回收），踢旧 session；★ 抢注修复
  4. 无 pubkey 的老式公共隧道 → 保留懒回收，向后兼容。
- relay **零持久化**：名字自带证明（preimage resistance），不需要存任何 owner_key 表。`Attach` 侧继续被 `password_ok`（`auth.rs`，常数时间比较）挡。
- 新依赖 `ed25519-dalek` + `dirs`，纯 Rust，不破坏 Windows/Linux 交叉编译。

### 5.3 时长限制：已是开关

`main.rs:100` `max_session` 默认 `86400`（24h），`0 = 无限`；机制在 `tunnel.rs:138`（>0 才设 deadline）。

- **常驻 companion 必须 `tunelo relay --max-session 0`**，否则每 24h 被 `Shutdown` 一次。
- 想改默认：`main.rs:100` 的 `default_value = "86400"` → `"0"`。

### 5.4 防开源白嫖（Q2）：只 gate `Register`，用授权后端签 token

前提认清：**开源二进制塞不住秘密**（硬编码 key 仓库里摆着），且**别人 fork 去自建 `tunelo relay` 是好事**——你只保护**你那台 relay 的带宽/机器**。

**关键洞察：只需 gate `Register`（owner）。** 白嫖者想暴露自己的服务必须当 owner；visitor/HTTP 面只能连到已注册的 owner 隧道 → 只要所有 owner 都是真 Termio 装机，visitor 面自动守住。**一点设防，全线覆盖。**

**机制 = 复用已有的 Lemon Squeezy 授权后端签短期 token：**

1. Termio app（有 license 或 trial 期）→ 你的控制端点 `POST /relay-token {license/install_id, pubkey_hash}`；
2. 后端校验 → 返回短期（≤1h）token，用你的 **Ed25519 私钥**签 `{install_id, pubkey_hash, exp}`；签进 `pubkey_hash` 就把 **license ↔ 身份密钥对**绑死，relay 可顺带校验"这个 token 只配这个 subdomain"；
3. tunelo client 在 `Register` 带上（`messages.rs` 加 `auth_token: Option<String>`）；
4. relay 用**内嵌公钥**验签 + 查 exp（`tunnel.rs::handle_owner` 在 `router.register` 之前），失败 `send_error(UNAUTHORIZED)` + `bail!`。

> 准入（`auth_token`，防白嫖）与归属（§5.2 密钥对自证）是**两层正交的东西**：前者证明"你付费了"，后者证明"这个名字是你的"。可以分开加，也可以让 token 签 `pubkey_hash` 把两者合流。

- 私钥只在你后端；relay 里是**公钥**，可光明正大写进开源 crate——**开源不泄任何东西**，无 license 拿不到 token。
- 补：短 exp + 撤销名单、每 install_id 隧道数上限、按 IP register 限速。
- 残余风险：真付费/trial 用户能抠自己 token 去 app 外白嫖——但他本就是合法用户，短 exp + per-install 上限压死滥用。要更狠再上 macOS **App Attest**（连 fork 都签不出），现在过度。

### 5.5 隐私取舍：relay 看不看得见终端

路径 A 里 TLS 在 relay 终止 → **relay 进程能读明文终端流**。因为是你自己的 relay，多数可接受。若不接受：

- **便宜**：app 层加一层 Noise/X25519（手机↔Mac 握手），relay 照旧当哑管只见密文——**tunelo 不用改**（`Attach` 桥的是裸流）。
- **彻底**：走路径 B（手机原生 QUIC Attach），换更好传输 + E2EE，代价是 iOS QUIC client。

### 5.6 规模

单机按 tunelo DESIGN 实测 ~10K tunnels / 100–200MB，撑得住低几万；再多才需要**多 relay 目录**（`key → 哪个节点持有 owner`，Redis/一致性哈希）——**明确推迟到单机顶不住那天**，别提前建（scope creep）。配套加个**主动 liveness reaper**（现在 eviction 只在 `resolve_subdomain` 懒清）。

## 6. Termio 侧接线（长期路径 A）

1. `TunnelManager.swift:139`：cloudflared spawn → 起 tunelo **client(owner)**：`tunelo port 8787 --relay <你的relay> --identity <Keychain 里的密钥> --password <token>`（或直接嵌 `crates/tunelo` client）。subdomain = `base32(SHA-256(pubkey))`，**Termio 本地即可算出**（不必等 relay 回），不可枚举。删 `reapStrayTunnels`/regex 抓 URL。
2. `MobileSettingsTab.swift:23`：QR host 从随机 `*.trycloudflare.com` → 固定 `wss://<稳定subdomain>.<domain>/?t=<token>`。**跨重建稳定 → tunnel-churn 重配对痛点根除。**
3. iOS：`CompanionLink` 存的 URL 变常量；`token(of:)`、auth-first 首帧**全不动**。

## 7. 决策与下一步

- **现在**：走 §4 短期 BYO-tunnel（复用 Cloudflare/ngrok），先上线验证需求，零基础设施、无白嫖者问题。
- **待需求验证后**：做 §5 tunelo 改造——最小可用套餐 = 密钥对身份 `claim`（challenge 签名自证，含抢注修复）+ `auth_token` 验签 + `--max-session 0`，可合成一个 diff。
- **推迟**：多 relay 目录、App Attest、native QUIC Attach（路径 B）——真撞规模/隐私红线再上。

### 待办

- [ ] tunelo：密钥对身份（Ed25519 challenge 签名自证）抢注修复 + `auth_token` Ed25519 验签（合一个 diff）；新依赖 `ed25519-dalek` + `dirs`，纯 Rust 保交叉编译
- [ ] 后端：`/relay-token` 签发端点（复用 Lemon Squeezy license/trial 校验）
- [ ] Termio：`TunnelManager` 可插拔 provider（cloudflared quick/named、ngrok）
- [ ] 决策：relay 是否需要 E2EE（取决于对"relay 可读终端"的容忍度）

