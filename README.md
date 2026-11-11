# PBZ-EFZKeepAim

**开镜打完栓动狙，镜不再自己收掉。** 这是给《僵尸毁灭工程》(Project Zomboid, Build 42) 的
塔科夫枪械包 [Escape From Zomboid Firearms](https://steamcommunity.com/sharedfiles/filedetails/?id=3824755284)
写的客户端补丁。

> 非官方补丁，与 EFZ 作者无关。仓库内不包含 EFZ 的任何原始文件，只包含一个可选的一行 hook 补丁和说明。

---

## 解决什么问题

用 EFZ 的**栓动狙 / 泵动枪**（M700、SV-98、AXMC、DVL-10、TRG M10、T-5000M、Mosin、VPO-215，
以及 MP133 / M590A1 / M870 / KS-23M / TOZ-106 这些泵动枪）时：

- 开镜 → 开枪 → **镜头自己退出去**，得重新按一次右键
- 腰射反而没这个毛病，步枪/冲锋枪也不会

这个补丁让**开镜状态下**射击后不再收镜。腰射完全不受影响，自动拉栓照常工作。

## 顺带的手感改进（v3）

- **拉栓更快**：走动画速度变量 `ReloadSpeed` 整体提速（不是硬截动作），动画和它内部的
  声音/上膛事件一起按比例提前，所以快但不抽帧。默认 1.7 倍，可调。
- **回镜更快**：拉栓做到一半就开始抬镜（`PREAIM_AT`），动作一结束镜已经就位；
  同时清掉原版在拉栓开始时偷偷加的那笔"瞄准延迟"。
- **更稳**：回镜窗口按毫秒算，60Hz / 144Hz 手感一致；进度用实测拉栓时长换算，
  不再依赖 `getJobDelta`（那个对 `maxTime = -1` 的动作到末端才跳）。
- **自动拉栓的冷却自适应**：跟着实测时长走，不再固定干等 0.9 秒。

## 安装

### 1. MOD 本体（必装）

把 `EFZKeepAim` 整个文件夹丢进存档目录的 `mods` 下：

```
<你的 cachedir>\mods\EFZKeepAim\
```

例如本机是 `D:\Project\mods\EFZKeepAim\`。

然后在 `mods\default.txt` 末尾（**必须在 `EscapeFromZomboidFirearms` 之后**）加一行：

```
    mod = EFZKeepAim,
```

或者直接进游戏 `Mods` 菜单勾选。重启游戏生效（Lua 不支持热加载）。

### 2. 配套的一行补丁（可选，但强烈建议）

EFZ 的第三人称开镜模块 `TW_AdsFromThird.lua` 里，退出开镜的条件之一是"角色身上有正在跑的动作"。
**开枪这个动作本身**会在 Java 层留下几帧动作状态，跟拉栓无关——光拦拉栓挡不住它，镜还是会掉。

打补丁（幂等，自动备份）：

```powershell
cd patches
.\apply-patch.ps1
```

脚本会自动从 Steam 库目录找到 EFZ。找不到就手动指定：

```powershell
.\apply-patch.ps1 -Path "D:\Program Files (x86)\Steam\steamapps\workshop\content\108600\3824755284\mods\EscapeFromZomboidFirearms"
```

想撤销：`.\apply-patch.ps1 -Revert`

> 如果提示"无法加载文件，未对文件进行数字签名"，先跑一次
> `powershell -ExecutionPolicy Bypass -File .\apply-patch.ps1`，或
> `Set-ExecutionPolicy -Scope Process Bypass`。

> **Steam 更新 EFZ 会冲掉这一行。** 更新后重跑一次脚本即可（脚本会识别"未打补丁"状态）。
> 日志里如果出现 `[TW-TPADS] exit why=action`，就是这行被冲掉了。

## 可调参数

都在 `EFZKeepAim/common/media/lua/client/EFZKeepAim/EFZKeepAim.lua` 顶部：

| 变量 | 默认 | 说明 |
|---|---|---|
| `RACK_HARD_MS` | `340` | **拉栓快慢就调这一个数。** 动作总共占多少毫秒，到点强制收工。原版实测 825ms，340 ≈ 2.4 倍速。`0` = 关闭截断 |
| `KEEP_AIM` | `true` | 关掉就是原版行为 |
| `VERBOSE` | `true` | 往 `console.txt` 打 `[EFZKeepAim]` 开头的日志。稳定后可设 `false` |
| `RACK_SPEED` | `1.0` | **默认别动。** 它乘在角色 `ReloadSpeed` 变量上，但实测动画根本不读这个值（见下方），真正决定拉栓速度的是 `RACK_HARD_MS` + animset 里的 `$AnimNodeSpeed` |
| `PREAIM_AT` | `0.32` | 拉栓动作做到这个比例就开始回镜。调小回镜更早，`0.0` = 动作一开始就硬撑 |
| `REAIM_MS` | `450` | 动作结束后强推瞄准的时长，单位毫秒。调长不拖慢速度，只是把引擎重算出来的延迟多压一会儿 |
| `AIM_SNAP` | `true` | 清掉原版在拉栓开始时加的那笔抬镜延迟。想保留原版的精度爬升就设 `false` |
| `RACK_EST_MS` | `360` | 首次的拉栓时长估计，跑过一次后自动换成实测值。要和 `RACK_HARD_MS` 对得上，否则开局第一发回镜偏晚 |
| `RACK_BLOCK_MS` | `500` | 拦"自动拉栓入队"的时间窗，别调太大，否则会挡掉玩家自己按的拉栓 |
| `EXEMPT_MS` | `1200` | 告诉 EFZ"这几帧别因为动作状态退镜"的时间窗 |
| `AUTO_RACK_ON_TRIGGER` | `true` | 膛空时点左键自动补一个拉栓（见下方限制） |

### 手感怎么调（v4）

拉栓快慢和回镜快慢是两件事，分开调：

- **嫌拉栓慢** → 降 `RACK_HARD_MS`（默认 `340`，可以到 `280`）。这是唯一直接管总时长的数。
- **嫌拉完栓还要等一下才开镜** → 降 `PREAIM_AT`、确认 `AIM_SNAP = true`、加 `$AnimSpeed`。
- **嫌回镜之后还抖一下** → 加 `REAIM_MS`（400~600）。

> 技术细节：拉栓时长由动画决定（`ISRackFirearm.maxTime = -1`），动画播完时触发
> `rackingFinished` 才 `forceComplete`。所以有两条路，而且**只能一起走**：
>
> - animset 里把 `m_SpeedScale` 从 `ReloadSpeed` 变量换成固定数字 → 动画真的变快
> - Lua 里按毫秒硬截断 → 动画变快后事件会被跳过，`rackingFinished` 不触发，
>   动作反而悬到超时（**实测 825ms → 1729ms**）。截断就是给加速擦屁股的。
>
> 只改 animset 不加速截断，就是 v3.2 那版"越改越慢"。只截断不加速动画，动作会在
> 中途被砍断。两个一起，动画基本播完、动作准时结束。

### 3. 动画层的两处硬编码（apply-patch.ps1 一并处理）

Lua 只能改数值，改不动动画状态机。开镜状态下拉完栓，动画必须从 `RackRifleAim` 退回
`IdleRifle`，播一遍 `AimToIdle_Rifle` 把枪放下，再由脚本把镜推回来、播一遍抬枪。
EFZ 给这条路的是 **0.5 秒 / 0.5 秒、1.3 倍速**，一来一回将近一秒。

两个数分别管两件事，都要改：

| 位置 | 原值 | 改成 | 管什么 |
|---|---|---|---|
| 节点 `<m_SpeedScale>` | `ReloadSpeed`（≈0.8） | `2.2` | 拉栓动画本身的播放速度 |
| 过渡 `<m_speedScale>` | `1.3` | `3.5` | "放枪"那段过渡剪辑的播放速度 |
| 过渡 `m_blendIn/OutTime` | `0.5` / `0.5` | `0.08` / `0.08` | 切换时的混合时间 |

改完节点速度后动画事件会漏，必须靠 Lua 的 `RACK_HARD_MS` 收尾——两个是一套的，别只改一半。

> 只压 `m_blendInTime` 是没用的——它控制的是混合过程，`AimToIdle_Rifle` 这段剪辑
> 本身有多长不会变。真正让剪辑变快的是 `m_speedScale`。这是第一版没效果的原因。

```powershell
cd patches
.\apply-patch.ps1          # 打 hook + 收动画
.\apply-patch.ps1 -Revert  # 两样一起还原
```

只改这三个数值，节点自己的 `m_BlendTime`、条件、事件一律不动。范围限定在长枪
（`RackRifle*` / `RackShotgun*` / `RackLeverAction*`，共 126 个节点）——手枪、左轮、
双管霰弹的拉栓本来就短，一起提速手感会突变。原版的 4 个 `Rack*Aim` 节点不改
（改游戏本体风险大），EFZ 武器走自己的 `*_TW_Contact_*` 节点，优先级 100，本来就盖过原版。

> 详见 [`docs/NOTES.md`](docs/NOTES.md) 第 7 节。

## 工作原理

掉镜不是单点问题，是三条链路叠出来的，缺一条都还会掉：

| # | 链路 | 位置 | 补丁怎么处理 |
|---|---|---|---|
| 1 | 攻击结束时排一个拉栓 timed action | 原版 `ISReloadWeaponAction.OnPlayerAttackFinished` | 包 `ISTimedActionQueue.add`，开镜窗口内丢弃刚排进来的 `ISRackFirearm` |
| 2 | EFZ 自己的 `TWAutoRack` 下一 tick 发现膛空、队列没拉栓，再补一个 | EFZ `TW/AutoRack.lua` | 同时包 `TWAutoRack.afterShot`，并清 `pending` |
| 3 | Java 层对"任何正在跑的动作"淡出 ADS | EFZ / Viewpoint Java 侧 | ① 射击后 1.2 秒内让 EFZ 的 TPADS 不因动作退出（就是那个一行补丁）② 装填动作期间与结束后强推 `setIsAiming(true)` |

三条都掐断后，镜才真的不动。**只做第 1 条是无效的**——这也是第一版失败的原因，日志里
`blocked queued auto-rack` 和 `exit why=action` 出现在同一帧。

完整的技术排查记录（含日志证据、踩过的坑）见 [`docs/NOTES.md`](docs/NOTES.md)。

## 已知限制

1. **开镜打完一发，膛是空的，要自己拉栓。** 这是拦掉自动拉栓的直接代价。拉栓时镜不会掉（补丁豁免 + 事后补回）。
2. **膛空时点左键会有一声空响。** 引擎先判定打不出去才轮到 Lua，这一下截不住。补丁会在攻击动作结束后补一个拉栓。
3. **Java 层能在 Lua 之上压镜。** 视觉过渡时长没有可调参数（EFZ 的 TPADS 和 Viewpoint 的 `viewpoint-live.properties` 都没有 ADS 速度项），
   只能用"提前 + 强推"来压缩，所以拉栓期间可能还有轻微拉远再回位的抖动。
4. 只在 **Build 42** 上验证过（42.22.2）。B41 大概率不适用。
5. 如果不打那个一行补丁，功能会退化成"只拦自动拉栓"——镜仍然会掉。

## 目录结构

```
EFZKeepAim/                          MOD 本体，整个文件夹丢进 cachedir\mods\
  42/mod.info
  common/media/lua/client/EFZKeepAim/EFZKeepAim.lua
patches/
  TW_AdsFromThird.lua.patch          给想手动 apply / 看 diff 的人
  apply-patch.ps1                    幂等安装脚本（自动定位 + 备份 + 支持 -Revert）
docs/
  NOTES.md                            技术笔记：三条链路、日志证据、API 事实
```

## 许可

补丁代码（本仓库除 `patches/TW_AdsFromThird.lua.patch` 的引用上下文外）以 MIT 发布，随意取用。
`TW_AdsFromThird.lua.patch` 的上下文行属于 EFZ（作者所有），仅作兼容性补丁引用。
