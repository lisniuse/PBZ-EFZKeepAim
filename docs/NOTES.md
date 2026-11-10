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
