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

> **Steam 更新 EFZ 会冲掉这一行。** 更新后重跑一次脚本即可（脚本会识别"未打补丁"状态）。
> 日志里如果出现 `[TW-TPADS] exit why=action`，就是这行被冲掉了。

## 可调参数

都在 `EFZKeepAim/common/media/lua/client/EFZKeepAim/EFZKeepAim.lua` 顶部：

| 变量 | 默认 | 说明 |
|---|---|---|
| `KEEP_AIM` | `true` | 关掉就是原版行为 |
| `VERBOSE` | `true` | 往 `console.txt` 打 `[EFZKeepAim]` 开头的日志。稳定后可设 `false` |
| `PREAIM_AT` | `0.7` | 装填动作做到这个进度就提前抬瞄准。调大回镜更平滑，调小回镜更快；`0.0` = 从动作一开始就硬撑 |
| `REAIM_FRAMES` | `12` | 动作结束后每帧强推瞄准的帧数，防 Java 层把镜压回去 |
| `RACK_BLOCK_MS` | `500` | 拦"自动拉栓入队"的时间窗，别调太大，否则会挡掉玩家自己按的拉栓 |
| `EXEMPT_MS` | `1200` | 告诉 EFZ"这几帧别因为动作状态退镜"的时间窗 |
| `AUTO_RACK_ON_TRIGGER` | `true` | 膛空时点左键自动补一个拉栓（见下方限制） |

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
