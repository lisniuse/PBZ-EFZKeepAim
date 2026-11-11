# 技术笔记：为什么栓动狙开镜开枪会掉镜

记录环境：Project Zomboid **B42.22.2**、EFZ（Workshop `3824755284`）、Viewpoint 0.1.6.2（3D 第三人称）、
ZombieBuddy 2.3.4、Java 25。日志位置 `<cachedir>\console.txt`。

---

## 1. 症状与初始误判

开镜打一发栓动狙，镜自己退出。第一反应是"自动拉栓动作导致 Java 层淡出 ADS"，
于是去拦那个 `ISRackFirearm`。拦住了，**镜还是掉**。

日志把真相钉死了：

```
f:4166 [EFZKeepAim] sealed after shot, aiming via aimIntent
f:4168 [EFZKeepAim] blocked queued auto-rack (Q.add)
f:4168 [TW-TPADS] exit why=action          <-- 同一帧，动作状态还在，镜照退
```

`blocked` 挡住了拉栓，但 TPADS 的退出理由是 `action`，不是 `rack`。
**开枪这个动作本身**在 `p:getCharacterActions()` 里留了几帧状态，就这几帧足够退镜。

## 2. 三条链路

### 链路 A — 原版排自动拉栓

`media/lua/shared/TimedActions/ISReloadWeaponAction.lua`，攻击结束回调里：

```lua
if weapon:isRackAfterShoot() then
    ISTimedActionQueue.add(ISRackFirearm:new(player, weapon))
end
```

只要有 `RackAfterShoot = true`，每发都排。EFZ 的 `TW_Items.txt` 里 16 处这个标记，
覆盖 9 把栓动狙 + 6 把泵动枪。四百多把半自动/全自动都没有，所以步枪不脱镜。

### 链路 B — EFZ 的补发

EFZ `42/media/lua/shared/TW/AutoRack.lua`：`afterShot` 记一条 `pending`，
`reconcileShots` 每 tick 检查"膛里没弹 + 队列里没拉栓"，然后补一个。

**只包 `ISTimedActionQueue.add` 挡不住它** —— 它下一 tick 换个时机又排进来。

### 链路 C — Java 层淡出 ADS

EFZ 源码注释原话：`Java fades ADS for every running action`。
这是引擎/Java 侧的硬行为，Lua 改不了，只能：

- 让 `getCharacterActions()` 别非空（不可控）
- 或者让 EFZ 的 TPADS **自己**别因为这个理由退出 —— 这是唯一可行的口子

## 3. 补丁的三个部件

### 3.1 `ISTimedActionQueue.add` 拦截（拦链路 A）

```lua
local origAdd = Q.add
Q.add = function(action, ...)
    if type(action) == 'table' and action.Type == 'ISRackFirearm' then
        if sealActive() and action.character == sealedPlayer then return end
    end
    return origAdd(action, ...)
end
```

**不能在事后 `removeFromQueue`**：`ISTimedActionQueue.lua:14` 里，队列为空时 `add` 会立刻 `begin()`，
动作当场就开始跑，事后再删已经有残留效果。必须入队前拦。

### 3.2 `TWAutoRack.afterShot` 包装（拦链路 B）

连 `TWAutoRack.pending` 一起清，否则下一 tick 还是会补。

### 3.3 一行 hook（拦链路 C）

`TW_AdsFromThird.lua` 的 `blocked()`：

```lua
local actions=p:getCharacterActions()
if actions and not actions:isEmpty() then return 'action' end
```

改成先问补丁要不要豁免：

```lua
if actions and not actions:isEmpty() then
    local keep=rawget(_G,'EFZKeepAim')
    if not (keep and type(keep.exempt)=='function' and keep.exempt(p)) then return 'action' end
end
```

豁免逻辑全在补丁里，EFZ 侧只有这三行胶水。

## 4. 踩过的坑（按踩到的顺序）

| 现象 | 真因 | 修法 |
|---|---|---|
| 整个 lua 文件没执行 | `weapon:getFullType and weapon:getFullType()` —— 把方法引用当值用，Kahlua 报 `function arguments expected near 'and'` | 拆成两句 `pcall`。**Kahlua 比标准 Lua 严格，改完必须用 luaparse 5.1 过一遍** |
| 钩子没装上但不报错 | `ISTimedActionQueue` 是 `client/` 目录模块，与本文件加载顺序不保证，加载那刻可能是 `nil`，`installAddGuard()` 静默返回 false | 惰性安装 + `OnGameStart` / `OnTick` 重试，装上时打日志 |
| 拦了 `Q.add` 还是掉 | 链路 B 每 tick 补发 | 同时包 `TWAutoRack.afterShot` |
| 点左键自动拉栓没反应，`add` 和 `stop` 同一帧 | 膛空时引擎紧接着 `DoAttack(0)` 打一下空枪，攻击动作立刻打断刚排的拉栓 | 先记 `pendingRack`，等 `isAttackStarted()` 回落再排 |
| 按 R 换弹掉镜 | 只认 `ISRackFirearm`，玩家按 R 触发的是 `ISReloadWeaponAction` | 豁免范围扩到四种装填动作：`ISRackFirearm` / `ISReloadWeaponAction` / `ISInsertMagazine` / `ISUnloadBulletsFromFirearm` |
| 拉完栓回镜慢 | `aimState()` 问的是 EFZ 的 `TWZB.aimIntent`（右键意图）。意图还在但 Java 已经把视觉镜位压掉，旧逻辑"意图 true 就不管"→ 空等 | 意图 true 就每帧 `setIsAiming(true)` 强推；意图 false 立刻放弃（尊重玩家主动取消） |
| 回镜总是慢半拍 | 动作结束后才开始回，过渡动画还得再跑一遍 | `PREAIM_AT`：动作做到 70% 就抬瞄准，动作结束镜已就位 |

## 5. 可复用的 API 事实

- `Events.OnWeaponSwingHitPoint(player, weapon)` —— 命中点事件，可作为"这一发打出去了"的钩子
- `Events.OnPlayerAttackFinished(player, weapon)` —— 攻击结束
- `ISTimedActionQueue.getTimedActionQueue(character)` → queue，字段 `.queue`（数组）、`.current`
- `ISTimedActionQueue.add(action)` 是静态方法；**队列为空时会立刻 `begin()`**（`ISTimedActionQueue.lua:14`）
- `ISTimedActionQueue.removeFromQueue(action)` 在 `ISTimedActionQueue.lua:39`
- `ISBaseTimedAction:getJobDelta()` 返回 0~1 进度（原版 UI 的进度条都用它）
- `hookAttack` 用的是原版 `Hook.Attack`（`ISReloadWeaponAction.attackHook` 之后）
- 武器脚本里 `isRackAfterShoot()` / `isRoundChambered()` / `getCurrentAmmoCount()` 都可 `pcall` 直接调
- EFZ 的 `TWZB.aimIntent(player)` 是意图层判定，和引擎的 `player:isAiming()` 不一定同步

## 6. 排查方法

`VERBOSE = true` 时，`console.txt` 里会按顺序出现：

```
[EFZKeepAim] v2 loaded (KEEP_AIM=true)
[EFZKeepAim] queue guard installed
[EFZKeepAim] TWAutoRack guard installed
[EFZKeepAim] OnWeaponSwingHitPoint reached (Base.M700)
[EFZKeepAim] sealed after shot, aiming via aimIntent
[EFZKeepAim] blocked queued auto-rack (Q.add) #1
```

对照判断：

| 日志缺失 | 说明 |
|---|---|
| 没有 `v2 loaded` | mod 没被加载，去 Mods 菜单勾选 |
| 有 `v2 loaded` 没 `queue guard installed` | `ISTimedActionQueue` 还是 nil，看加载顺序 |
| 没 `OnWeaponSwingHitPoint reached` | 事件没到，武器可能根本没 `RackAfterShoot` |
| 有 `sealed` 之后仍有 `[TW-TPADS] exit why=action` | 一行补丁被 Steam 更新冲掉了，重跑 `apply-patch.ps1` |
| 有 `blocked` 但仍 `exit why=aim` | EFZ 换弹动作把瞄准标志关了，只能靠事后强推 |

`luaparse` 语法检查（Kahlua 不兼容的点靠这个提前抓）：

```powershell
npm install luaparse
node -e "const fs=require('fs'),l=require('luaparse');l.parse(fs.readFileSync(process.argv[1],'utf8'),{luaVersion:'5.1'});console.log('SYNTAX OK')" path\to\file.lua
```

---

## 7. v3：拉栓提速 / 回镜提速（手感）

### 7.1 拉栓时长到底由什么决定

`ISRackFirearm:getDuration()` 返回 **-1**，`maxTime = -1`：

```lua
function ISRackFirearm:new(character, gun)
    local o = ISBaseTimedAction.new(self, character)
    o.maxTime = o:getDuration()   -- -1
```

所以改 `maxTime` 没用。动作长度完全由**动画**决定：动画播到末端触发
`animEvent 'rackingFinished'` → `forceComplete()`。想快只有两条路：

1. 硬截（提前 `forceComplete()`）—— 抽帧，动作做一半就断，难看
2. 让动画播快 —— **正解**

### 7.2 动画速度绑在 `ReloadSpeed` 变量上

`media/animsets/player/actions/LoadRifle.xml`：

```xml
<m_SpeedScale>ReloadSpeed</m_SpeedScale>
```

`RackRifle.xml` 用 `x_extends="loadRifle.xml"` 继承它，`RackRifleAim.xml` 再继承 `RackRifle.xml`；
EFZ 的风格化节点（`RackRifleAim_TW_Contact_*`、`RackBreakAction_*`）各自也写了
`<m_SpeedScale>ReloadSpeed</m_SpeedScale>`。**一个变量盖住所有拉栓动画。**

这个变量由 `ISReloadWeaponAction.setReloadSpeed(character, true)` 写入，原版算式：

```lua
baseReloadSpeed = 0.8 + character:getPerkLevel(Perks.Reloading) * 0.04
```

也就是**枪法 0 级时动画只播 0.8 倍速**——本来就慢。`ISRackFirearm:initVars()` 在
`start()` 里调用它，所以在 `start()` **之后**乘倍率才能覆盖：

```lua
cls.start = function(self, ...)
    local r = origStart(self, ...)      -- initVars() 在里面
    local base = p:getVariableFloat('ReloadSpeed', 0.8)
    p:setVariable('ReloadSpeed', base * RACK_SPEED)
    return r
end
```

动画加速后，节点里的事件（`playReloadSound`@15%、`rackBullet`@30%、
`rackingFinished`@末端）**一起按比例提前**，动作仍然是完整播完的，所以快而不抽帧。
动作结束要把原值写回去，别污染后续的换弹动作。

### 7.3 那笔"瞄准延迟"

`ISRackFirearm:start()` 里还有一段，专门坑回镜：

```lua
if self.character:isAiming() then
    self.character:setAimingDelay(self.character:getAimingDelay() + self.gun:getAimingTime() * (0.15 - perk*0.01))
end
```

开镜状态下拉栓，原版会**加**一笔抬镜延迟。v3 在 `start()` 之后 `setAimingDelay(0)`，
并在回镜窗口里每帧压住，抬枪即准。

### 7.4 进度不能用 `getJobDelta`

`ISBaseTimedAction:getJobDelta()` 对 `maxTime <= 1` 的动作基本一直是 0，直到
`forceComplete()` 才跳到 1。拿它算"做到 70% 就提前回镜"其实永远等到最后一刻才触发
（v2 的 `PREAIM_AT` 实际上就是这个效果）。v3 改成：

- 记录动作开始时刻，`(now - start) / 实测平均时长` 算进度
- 实测时长在每次 `stop`/`perform` 时量出来，滚动平均（0.6 旧 + 0.4 新）
- `getJobDelta` 只在它真给出中间值时优先

### 7.5 可调参数（`EFZKeepAim.lua` 顶部）

| 变量 | 默认 | 作用 | 建议区间 |
|---|---|---|---|
| `RACK_SPEED` | 2.3 | 拉栓动画倍率（乘在原版 `ReloadSpeed` 上） | 1.3 ~ 2.6，超过 2.6 会飘 |
| `PREAIM_AT` | 0.32 | 动作做到多少比例开始回镜 | 0.2 ~ 0.6 |
| `REAIM_MS` | 450 | 动作结束后强推瞄准的时长（毫秒） | 200 ~ 600 |
| `AIM_SNAP` | true | 清掉原版那笔抬镜延迟 | 想保留原版精度爬升就设 false |
| `RACK_EST_MS` | 420 | 首次的时长估计，之后自动实测替换 | 跟着 `RACK_SPEED` 一起调 |

调参时看 `console.txt`：

```
[EFZKeepAim] v3 loaded (KEEP_AIM=true speed=x2.30 preAim=32% reAim=450ms snap=true)
[EFZKeepAim] rack took 452ms (rolling est 452ms)
[EFZKeepAim] pre-aim at 32%
[EFZKeepAim] rack done, re-aim window 450ms
```

`rack took` 就是你现在的实际拉栓时长；想更快就加 `RACK_SPEED`，看这个数掉到多少。

### 7.6 拉完栓到开镜那一秒，Lua 改不到

v3 出来后手感已经好很多，但"拉完栓到重新贴上脸"还是有一段明显的拖沓。查下来不在 Lua 层，
在动画状态机里。

#### 先修正 7.2 的结论：`ReloadSpeed` 变量驱动不了动画

7.2 说"乘 `ReloadSpeed` 就能整体提速，是唯一不抽帧的办法"。**实测是错的。**

```
v3  RACK_SPEED = 1.7  →  [EFZKeepAim] rack took 819ms
v3.1 RACK_SPEED = 2.3 →  [EFZKeepAim] rack took 825ms
```

倍率涨了 35%，时长一动不动。`console.txt` 里两次都打了 `v3 loaded speed=x2.30`，说明
参数确实加载了、`speedUp()` 确实跑了（`twKeepAimAt` 有值才会算出 `rack took`），
但 `character:setVariable('ReloadSpeed', 1.84)` 对动画没有任何影响。要么动画系统读的不是
这个变量的实时值，要么每帧被引擎重置回 `0.8 + perk*0.04`。

v3 当时"有点效果"的其实是 `PREAIM_AT` 和回镜窗口，不是速度。

**唯一有效的办法**：把节点里的 `<m_SpeedScale>ReloadSpeed</m_SpeedScale>` 直接换成数字，
不再依赖变量。

#### 再修正：压 `m_blendInTime` 只能压混合，压不了剪辑

v3.1 把 transition 的 `m_blendInTime` / `m_blendOutTime` 从 0.5 压到 0.08，用户反馈"还是慢，
没改到"。原因：

- `m_blendInTime` 管的是**从当前姿势混合到过渡剪辑**用多久
- `AimToIdle_Rifle` 这段剪辑**本身有多长不会变**
- 真正让剪辑播快的是 `<m_speedScale>`

所以三个数各管一件事，缺一不可：

| 位置 | 原值 | v3.2 | 管什么 |
|---|---|---|---|
| 节点 `<m_SpeedScale>` | `ReloadSpeed`（≈0.8） | `2.0` | 拉栓动画播放速度 |
| 过渡 `<m_speedScale>` | `1.3` | `3.5` | "放枪"剪辑播放速度 |
| 过渡 `m_blendIn/OutTime` | `0.5` | `0.08` | 切换混合时间 |

#### 过渡为什么存在

开镜状态下拉栓走的是 `RackRifleAim*` 节点，它带一条**写死的** transition：

```xml
<m_Transitions>
    <m_Target>IdleRifle</m_Target>
    <m_AnimName>TW_Contact_P026_AimToIdle_Rifle</m_AnimName>
    <m_blendInTime>0.5</m_blendInTime>
    <m_blendOutTime>0.5</m_blendOutTime>
    <m_speedScale>1.3</m_speedScale>
</m_Transitions>
```

`m_EarlyTransitionOut=true`，所以 `isRacking` / `RackAiming` 一被 `ISRackFirearm:stop()`
里的 `clearVariable` 清掉，节点立刻按这条 transition 切出去，播一遍 `AimToIdle_Rifle`
**把枪放下来**，Lua 再把 `setIsAiming(true)` 推上去，又混一遍**抬回来**。一来一回小一秒，
全部发生在拉栓动作已经结束之后。

三条弯路都试不通：

1. **让 `RackAiming` 保持 true** —— transition 是按 `m_Target` 指定目标节点的，不是条件驱动，
   条件只决定"什么时候转出"，不决定"转到哪"
2. **拉栓结束立刻重设 `isRacking`** —— `m_Looped=false` 的节点会重新从头播一遍拉栓
3. **在 Lua 里改 anim node** —— `AnimNode` 没暴露给 Lua，`getAnimNode` 拿不到

最后是**直接改 EFZ 的 animset XML**（`apply-patch.ps1` 里做）。范围：126 个长枪节点
（`RackRifle*` / `RackShotgun*` / `RackLeverAction*`）+ 72 处过渡。手枪、左轮、双管霰弹
没动，它们拉栓本来就短。

**踩的坑**：`apply-patch.ps1 -Revert` 原来用 `-Filter '*efzkeepaim*.bak'` 递归找 hook 备份，
加上 animset 备份后，它把 XML 的备份当成 `TW_AdsFromThird.lua` 的备份盖了上去，直接把
lua 变成 XML。现在 hook 的备份精确匹配 `TW_AdsFromThird.lua.efzkeepaim*.bak`，
animset 的备份改用 `.efzkeepanimset.*.bak` 后缀，两套互不干扰。



## 8. v4：加速 animset 会让动作悬停，必须配 Lua 硬截断

v3.2 把节点 `m_SpeedScale` 从 `ReloadSpeed` 换成固定 `2.0` 之后，实测日志反而变成：

```
RACK_SPEED 1.7 → rack took 819ms
RACK_SPEED 2.3 → rack took 825ms
节点 speed 2.0 → rack took 1729ms / 1880ms   ← 越改越慢
```

原因不是速度语义反了，而是**动画加速后引擎会跳过动画里的 anim 事件**：

```lua
-- ISRackFirearm:animEvent
if event == 'rackingFinished' then
    self:forceComplete()   -- 唯一的正常收尾路径
end
```

`ISRackFirearm.maxTime = -1`、`getDuration()` 返回 `-1`，动作没有时长上限，
完全靠 `rackingFinished` 事件收尾。动画播太快，这个事件落不到帧上，动作就一直挂着，
直到别的机制（队列超时/玩家再操作）把它结束——所以时长翻倍。

**结论：animset 加速和 Lua 收尾必须成对出现。** v4 的做法：

1. animset：`m_SpeedScale` → `2.2`（126 个长枪节点），动画本体从 ~660ms 缩到 ~300ms
2. Lua：hook `ISRackFirearm:update`，从 `start` 起算到 `RACK_HARD_MS`（默认 340ms）就：
   - 若 `rackBullet` 事件没跑过（`twKeepAimRacked` 为假），手动补一次，保证子弹真的顶上膛
   - `self:forceComplete()`

hook 时同时包了 `cls.rackBullet` 来置 `twKeepAimRacked`，避免重复上一次膛（多掉一发子弹）。
`twKeepAimCut` 防重入，`twKeepAimDone` 由 `rackFinished` 置位。

调手感只需要动 `RACK_HARD_MS` 一个数：280 更急、340 默认、400 更顺。`RACK_SPEED`
（角色 `ReloadSpeed` 变量）确认无效，默认 1.0，留着只为兼容老配置。

顺带记一条排查技巧：`rack took` 突然变大不一定是变慢，很可能是**收尾事件没触发**。
