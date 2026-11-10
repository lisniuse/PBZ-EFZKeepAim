--[[ ==========================================================================
    EFZ Keep ADS  (mod id: EFZKeepAim)   v2

    问题：用 Escape From Zomboid Firearms 的栓动狙 / 泵动枪时，开镜打一发，
          镜头会自己收掉，必须重新右键。

    链路（三条，缺一不可）：
      1. 原版对 isRackAfterShoot() 的武器，在攻击结束时排一个拉栓 timed action
         —— ISReloadWeaponAction.OnPlayerAttackFinished
      2. EFZ 的 TWAutoRack 在下一 tick 发现膛里没弹、队列里没拉栓，会再补一个
         —— TWAutoRack.afterShot / reconcileShots
      3. Java 层对"任何正在跑的 timed action"淡出 ADS

    做法：射击瞬间立标记，然后在两个入口同时掐断 —— 队列入队（ISTimedActionQueue.add）
          和 EFZ 的补发（TWAutoRack.afterShot）。

    v2 修正（v1 无效的原因）：
      · ISTimedActionQueue 是 client 目录的模块，加载顺序不保证，v1 在文件加载时
        装钩子可能装不上且静默失败 => 改为惰性安装 + OnGameStart/OnTick 重试
      · 只挡了 Q.add，没挡 TWAutoRack.afterShot，EFZ 下一 tick 照样补拉栓
      · 武器对象用 == 比较不保险 => 改为优先比 getID()
      · 瞄准判定补上 EFZ 的 TWZB.aimIntent（EFZ 不一定走 player:isAiming()）

    只在「开镜 + 手上还是这把枪」时生效：腰射时自动拉栓完全照常。

    代价：这一发之后膛是空的，要自己拉栓才能打下一发（镜不掉）。

    注意：本文件不修改 EFZ 任何文件。但光靠它不够 —— 链路 3 需要 EFZ 侧的
    TW_AdsFromThird.lua 打一行 hook（调用本 mod 导出的 EFZKeepAim.exempt），
    见仓库 patches/apply-patch.ps1。Steam 更新 EFZ 会冲掉那一行，重跑脚本即可。
========================================================================== ]]

local MOD = 'EFZKeepAim'

-- ============================ 可调开关 ============================
local KEEP_AIM = true   -- 开镜射击后不掉镜（代价：之后要自己拉栓）
local VERBOSE = true    -- 排查期打开：控制台会打印 [EFZKeepAim] 开头的行
-- =================================================================

-- 两个时间窗：
--   RACK_BLOCK_MS  拦"自动拉栓入队"的窗口，短一点，别把玩家的手动拉栓也挡了
--   EXEMPT_MS      第三人称开镜不因"有动作状态"退出的窗口，要盖住射击动作的残留帧
local RACK_BLOCK_MS = 500
local EXEMPT_MS = 1200

-- 回镜速度：动作做到这个进度就提前把瞄准抬起来，动作一结束镜已经就位
-- 1.0 = 等动作完全结束才回（最慢）；0.7 = 提前三成；0.0 = 一进动作就抬（等于动作期间硬撑开镜）
local PREAIM_AT = 0.7
-- 动作结束后强推瞄准的帧数（每帧推一次，防 Java 层每帧把镜压回去）
local REAIM_FRAMES = 12

local function log(fmt, ...)
    if not VERBOSE then return end
    local ok, s = pcall(string.format, fmt, ...)
    print('[' .. MOD .. '] ' .. (ok and s or tostring(fmt)))
end

local function nowMs()
    return (getTimestampMs and getTimestampMs()) or 0
end

-- 瞄准判定：EFZ 有自己的一套（TWZB.aimIntent），优先问它
local function aimState(p)
    if not p then return false, 'no-player' end
    local z = rawget(_G, 'TWZB')
    if z and type(z.aimIntent) == 'function' then
        local ok, v = pcall(z.aimIntent, p)
        if ok and v ~= nil then return v == true, 'aimIntent' end
    end
    local ok, v = pcall(function() return p:isAiming() end)
    return (ok and v == true), 'isAiming'
end

-- 物品比较：优先比 getID，退回 ==
local function sameItem(a, b)
    if a == b then return true end
    if not (a and b) then return false end
    local oka, ia = pcall(function() return a:getID() end)
    local okb, ib = pcall(function() return b:getID() end)
    return oka and okb and ia ~= nil and ia == ib
end

local function alive(p)
    if not p then return false end
    local ok, dead = pcall(function() return p:isDead() end)
    return not (ok and dead == true)
end

local function isLocal(p)
    local ok, flag = pcall(function() return p:isLocalPlayer() end)
    if ok and flag ~= true then return false end
    local p0 = getSpecificPlayer and getSpecificPlayer(0)
    return (p0 == nil) or (p0 == p)
end

local function racksAfterShot(g)
    if not g then return false end
    local ok, v = pcall(function() return g:isRackAfterShoot() end)
    return ok and v == true
end

local function holds(p, g)
    local ok, item = pcall(function() return p:getPrimaryHandItem() end)
    return ok and sameItem(item, g)
end

-- ======================= 射击标记（sealed） =======================

local rackingNow = nil -- 定义在下面（前向声明）
local filling = nil -- 当前装填动作 { player=, action=, aimed=, at= }

-- 装填类动作：拉栓、换弹、插弹匣、退弹（EFZ 的 manualQueueHold 也是这几个）
local FILL_ACTIONS = {
    ISRackFirearm = true,
    ISReloadWeaponAction = true,
    ISInsertMagazine = true,
    ISUnloadBulletsFromFirearm = true,
}

local sealed = nil -- { player=, gun=, at= }

local function sealFor(maxAge)
    local s = sealed
    if not s then return nil end
    local age = nowMs() - s.at
    if age > EXEMPT_MS then
        sealed = nil
        return nil
    end
    if age > maxAge then return nil end
    return s
end

-- 这个动作/这次补发是不是"刚刚那发开镜射击"引出来的
local function matchesSeal(player, gun)
    local s = sealFor(RACK_BLOCK_MS)
    if not s then return false end
    if s.player ~= player then return false end
    return sameItem(s.gun, gun)
end

-- 给 EFZ 的第三人称开镜模块用（TW_AdsFromThird.lua 里加了一行判断）：
-- 刚开过枪的这段时间、以及开镜状态下自己拉栓的这段时间，都别因为"有动作在跑"退出开镜。
-- 那一行是本地补丁，Steam 更新 EFZ 后会被冲掉，需要重打。
EFZKeepAim = {
    exempt = function(p)
        if not p then return false end
        local s = sealed
        if s and s.player == p and (nowMs() - s.at) <= EXEMPT_MS then return true end
        return rackingNow ~= nil and rackingNow(p) == true
    end,
}

local function markShot(player, gun)
    if not (KEEP_AIM and player and gun) then return end
    if not isLocal(player) or not alive(player) then return end
    if not racksAfterShot(gun) then return end
    if not holds(player, gun) then
        log('shot seen but weapon moved, skip (%s)', tostring(gun))
        return
    end
    local aiming, how = aimState(player)
    if not aiming then
        log('shot in hip fire (%s=false), auto-rack left alone', how)
        return
    end
    sealed = { player = player, gun = gun, at = nowMs() }
    log('sealed after shot, aiming via %s', how)
end

-- ==================== 入口 1：队列入队 ====================

local guardInstalled = false

local function installAddGuard()
    if guardInstalled then return true end
    local Q = rawget(_G, 'ISTimedActionQueue')
    if not (type(Q) == 'table' and type(Q.add) == 'function') then return false end
    if Q.twKeepAimOrigAdd then
        guardInstalled = true
        return true
    end

    local origAdd = Q.add
    Q.twKeepAimOrigAdd = origAdd

    Q.add = function(action, ...)
        if type(action) == 'table' and action.Type == 'ISRackFirearm' then
            local s = sealFor(RACK_BLOCK_MS)
            if s and action.character == s.player then
                s.blocked = (s.blocked or 0) + 1
                log('blocked queued auto-rack (Q.add) #%d', s.blocked)
                return
            end
        end
        -- 放行的装填动作：记下来，动作期间让第三人称开镜别退出
        if type(action) == 'table' and FILL_ACTIONS[action.Type] then
            local p = action.character
            if p and isLocal(p) and alive(p) then
                local aiming = aimState(p)
                if aiming then
                    filling = { player = p, action = action, aimed = true, at = nowMs() }
                    log('fill action starts (%s)', tostring(action.Type))
                end
            end
        end
        return origAdd(action, ...)
    end

    guardInstalled = true
    log('queue guard installed')
    return true
end

-- ==================== 入口 2：EFZ AutoRack 补发 ====================

local autoRackHooked = false

local function hookAutoRack()
    if autoRackHooked then return true end
    local ar = rawget(_G, 'TWAutoRack')
    if not (type(ar) == 'table' and type(ar.afterShot) == 'function') then return false end
    if ar.twKeepAimOrigAfterShot then
        autoRackHooked = true
        return true
    end

    local orig = ar.afterShot
    ar.twKeepAimOrigAfterShot = orig

    ar.afterShot = function(player, gun)
        if KEEP_AIM and player and matchesSeal(player, gun) then
            log('suppressed TWAutoRack.afterShot')
            return false
        end
        return orig(player, gun)
    end

    autoRackHooked = true
    log('TWAutoRack guard installed')
    return true
end

-- ============ 开镜状态下自己拉栓 / 换弹：动作期间 + 做完都别丢镜 ============

local function queueHas(p, action)
    local Q = rawget(_G, 'ISTimedActionQueue')
    if not (type(Q) == 'table' and type(Q.getTimedActionQueue) == 'function') then return nil end
    local ok, q = pcall(Q.getTimedActionQueue, p)
    if not ok or type(q) ~= 'table' then return nil end
    if q.current == action then return true end
    if type(q.queue) == 'table' then
        for i = 1, #q.queue do
            if q.queue[i] == action then return true end
        end
    end
    return false
end

rackingNow = function(p)
    if not p then return false end
    if filling and filling.player == p then return true end
    -- 兜底：没记到它，但队列里确实在跑装填动作
    local Q = rawget(_G, 'ISTimedActionQueue')
    if not (type(Q) == 'table' and type(Q.getTimedActionQueue) == 'function') then return false end
    local ok, q = pcall(Q.getTimedActionQueue, p)
    if not ok or type(q) ~= 'table' then return false end
    local cur = q.current
    return type(cur) == 'table' and FILL_ACTIONS[cur.Type] == true
end

-- 拉栓结束后补几帧瞄准：万一 Java 层在动作期间把镜压下去了，这里把它拉回来
local reaim = nil -- { player=, at=, left= }

local rackHooked = false

local function hookRack()
    if rackHooked then return true end
    local cls = rawget(_G, 'ISRackFirearm')
    if type(cls) ~= 'table' then return false end
    if type(cls.start) ~= 'function' or type(cls.stop) ~= 'function' then return false end
    if cls.twKeepAimStop then
        rackHooked = true
        return true
    end

    local origStart = cls.start
    local origStop = cls.stop

    cls.start = function(self, ...)
        local okA, aiming = pcall(function() return aimState(self.character) end)
        self.twKeepAimAimed = (okA and aiming) or false
        return origStart(self, ...)
    end

    cls.stop = function(self, ...)
        local r = origStop(self, ...)
        if KEEP_AIM and self.twKeepAimAimed and self.character then
            reaim = { player = self.character, at = nowMs(), left = REAIM_FRAMES }
            log('rack done, re-aim queued')
        end
        return r
    end

    cls.twKeepAimStop = origStop
    rackHooked = true
    log('rack hook installed')
    return true
end

-- ============ 空膛时点射击 => 自动补一个拉栓 ============
-- 场景：栓动枪打完一发、镜还开着，但膛是空的。这时再点左键，引擎的
-- ISReloadWeaponAction.attackHook 会先 ISTimedActionQueue.clear() 再判定打不出去，
-- 玩家只会听到空响。这里在它之后排一个拉栓，点一下就把栓拉上。

local AUTO_RACK_ON_TRIGGER = true
local lastAutoRack = 0
local pendingRack = nil -- { player=, gun=, at= } 等这一下空枪攻击结束再排拉栓

local function doQueueRack(character, weapon)
    if not (character and weapon) then return false end
    if rackingNow(character) then return false end
    local cls = rawget(_G, 'ISRackFirearm')
    local Q = rawget(_G, 'ISTimedActionQueue')
    if not (type(cls) == 'table' and type(cls.new) == 'function' and type(Q) == 'table') then return false end
    local add = Q.twKeepAimOrigAdd or Q.add -- 绕过自己的自动拉栓拦截
    if type(add) ~= 'function' then return false end

    local action = cls:new(character, weapon)
    if aimState(character) then
        filling = { player = character, action = action, aimed = true, at = nowMs() }
    end

    lastAutoRack = nowMs()
    local okAdd = pcall(function() add(action) end)
    log('auto rack queued (%s)', tostring(okAdd))
    return okAdd
end

local function triggerAutoRack(character, weapon)
    if not AUTO_RACK_ON_TRIGGER then return end
    if not (character and weapon) then return end
    if not racksAfterShot(weapon) then return end          -- 最快的筛子：绝大多数枪都不是栓动
    if not isLocal(character) or not alive(character) then return end
    if not holds(character, weapon) then return end
    if rackingNow(character) then return end               -- 已经在拉栓 / 换弹
    if (nowMs() - lastAutoRack) < 900 then return end       -- 拉栓动作本身约 0.6~0.8 秒，按住不放时别反复重排

    local okC, chambered = pcall(function() return weapon:isRoundChambered() end)
    if not okC or chambered == true then return end         -- 膛里有活弹，不用管

    local okA, ammo = pcall(function() return weapon:getCurrentAmmoCount() end)
    if not okA then return end
    local okP, per = pcall(function() return weapon:getAmmoPerShoot() end)
    if (ammo or 0) < ((okP and per) or 1) then return end   -- 弹匣也空了，那是换弹的事

    -- 不在这里排队：膛空时引擎紧接着会 DoAttack(0) 打一下空枪，那个攻击动作
    -- 会立刻把刚排进队列的拉栓打断（日志里 add 和 stop 同一帧）。
    -- 先记下来，等这一下攻击结束、OnTick 里 isAttackStarted() 回落再排。
    pendingRack = { player = character, gun = weapon, at = nowMs() }
    log('empty chamber on trigger -> rack pending')
end

local attackHooked = false

local function hookAttack()
    if attackHooked then return true end
    local H = rawget(_G, 'Hook')
    if not (type(H) == 'table' and type(H.Attack) == 'table' and type(H.Attack.Add) == 'function') then return false end
    H.Attack.Add(function(character, chargeDelta, weapon)
        local ok, err = pcall(triggerAutoRack, character, weapon)
        if not ok then log('attack hook error: %s', tostring(err)) end
    end)
    attackHooked = true
    log('attack hook installed')
    return true
end

local function ensureGuards()
    local a = installAddGuard()
    local b = hookAutoRack()
    local c = hookRack()
    local d = hookAttack()
    return a, b, c, d
end

ensureGuards()

-- 加载那一刻模块可能还没到，重试
Events.OnGameStart.Add(function()
    ensureGuards()
    if not guardInstalled then log('WARN: ISTimedActionQueue still missing at OnGameStart') end
    if not autoRackHooked then log('WARN: TWAutoRack missing at OnGameStart') end
    if not rackHooked then log('WARN: ISRackFirearm missing at OnGameStart') end
    if not attackHooked then log('WARN: Hook.Attack missing at OnGameStart') end
end)

-- ==================== 兜底：已经排进队列的 ====================

local function dropQueuedRacks(p)
    local Q = rawget(_G, 'ISTimedActionQueue')
    if not (type(Q) == 'table' and type(Q.getTimedActionQueue) == 'function') then return 0 end
    local ok, queue = pcall(Q.getTimedActionQueue, p)
    if not ok or type(queue) ~= 'table' or type(queue.queue) ~= 'table' then return 0 end
    local dropped = 0
    for i = #queue.queue, 1, -1 do
        local a = queue.queue[i]
        if type(a) == 'table' and a.Type == 'ISRackFirearm' and a ~= queue.current then
            local okR = pcall(function() queue:removeFromQueue(a) end)
            if okR then dropped = dropped + 1 end
        end
    end
    return dropped
end

-- ==================== 事件接线 ====================

Events.OnWeaponSwingHitPoint.Add(function(player, weapon)
    -- 诊断：确认事件确实到达
    if VERBOSE and weapon and racksAfterShot(weapon) then
        local okT, ft = pcall(function() return weapon:getFullType() end)
        log('OnWeaponSwingHitPoint reached (%s)', tostring(okT and ft or '?'))
    end
    markShot(player, weapon)
end)

Events.OnPlayerAttackFinished.Add(function(player, weapon)
    if not KEEP_AIM then return end
    if not matchesSeal(player, weapon) then return end
    local n = dropQueuedRacks(player)
    if n > 0 then log('fallback swept %d queued rack', n) end
end)

Events.OnTick.Add(function()
    if not guardInstalled or not autoRackHooked or not rackHooked or not attackHooked then ensureGuards() end
    sealFor(-1) -- 只做过期清理

    -- 空膛点射之后的补拉栓：等这一下攻击动作结束
    local pr = pendingRack
    if pr then
        local age = nowMs() - pr.at
        local over = age > 2000
        local ready = false
        if over then
            pendingRack = nil
        elseif age >= 120 then -- 至少放过这一下空枪攻击的头 120ms
            local okB, started = pcall(function() return pr.player:isAttackStarted() end)
            ready = (not okB) or (started ~= true)
            if ready then
                pendingRack = nil
                if alive(pr.player) and holds(pr.player, pr.gun) then
                    doQueueRack(pr.player, pr.gun)
                end
            end
        end
    end

    -- 装填动作结束 => 排一次"回镜"；动作没结束时看进度，够快做完了就先抬瞄准
    local f = filling
    if f then
        local has = queueHas(f.player, f.action)
        if has == false or (nowMs() - f.at) > 8000 then
            filling = nil
            if f.aimed then
                reaim = { player = f.player, at = nowMs(), left = REAIM_FRAMES }
                log('fill done, re-aim queued')
            end
        elseif f.aimed and not f.preaimed then
            -- 提前回镜：动作收尾阶段就把瞄准抬起来，避免"拉完栓还要等一下才开镜"
            local okD, d = pcall(function() return f.action:getJobDelta() end)
            if okD and type(d) == 'number' and d >= PREAIM_AT then
                f.preaimed = true
                local okA = pcall(function() f.player:setIsAiming(true) end)
                log('pre-aim at %d%% (%s)', math.floor(d * 100), tostring(okA))
            end
        end
    end

    local r = reaim
    if r then
        if r.left <= 0 or (nowMs() - r.at) > 800 then
            reaim = nil
        else
            r.left = r.left - 1
            if alive(r.player) then
                -- 意图还在（玩家没主动取消）就强推视觉瞄准：EFZ 的 Java 层会把镜压回去，
                -- 只认 isAiming() 的话这里会一直被它带着走，回镜就慢
                if not aimState(r.player) then
                    reaim = nil -- 玩家自己取消了开镜，尊重
                else
                    local okA, actual = pcall(function() return r.player:isAiming() end)
                    if not (okA and actual == true) then
                        pcall(function() r.player:setIsAiming(true) end)
                    end
                end
            end
        end
    end
end)

log('v2 loaded (KEEP_AIM=%s)', tostring(KEEP_AIM))
