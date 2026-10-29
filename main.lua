--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                 SKYFIRE · PROJECT VECTOR EDITION                    ║
    ║        Native Vector UI · Drone ESP · 2nd-Order Lead Aim            ║
    ║          Soldier ESP · Dynamic Ballistics · Silent Stealth          ║
    ╚══════════════════════════════════════════════════════════════════════╝

    Engine Architecture:
    • Native Vector Menu (menu.*) — Clean ImGui integration, zero ScreenGui footprint
    • Native Overlay Pipeline (draw.* in OnFrame) — D3D/Vulkan overlay rendering
    • OS-Level Input Polling (input.IsKeyDown) — Bypasses Roblox turret input blockades
    • 2nd-Order Lead Solver — Smooth velocity, acceleration, gravity drop, drag
    • TRV Dynamic Ballistics — Auto-detects handheld weapons & ZU-23-2 turret stats
    • Wreck & Falling Filter — Per-user toggle for crashed drones
    • Soldier ESP & Chams — Powered by entity.GetPlayers() and native chams
]]

-- ═══════════════════════════════════════════════════════════════════════
-- SILENT ENVIRONMENT HARNESS (Zero Console Leaks)
-- ═══════════════════════════════════════════════════════════════════════
local print = function(...) end
local warn  = function(...) end

-- ═══════════════════════════════════════════════════════════════════════
-- CONSTANTS & BALLISTIC DEFAULTS
-- ═══════════════════════════════════════════════════════════════════════
local DEFAULT_BALLISTIC_SPEED = 3285.71
local DEFAULT_BALLISTIC_DROP  = 35.0357
local VK_E                    = 0x45 -- Virtual Key 'E'

-- ═══════════════════════════════════════════════════════════════════════
-- INITIALIZE VECTOR MENU
-- ═══════════════════════════════════════════════════════════════════════
pcall(function()
    -- Tab 1: Drones
    menu.AddTab("Drones", "D")
    menu.AddGroup("Drones", "Drone ESP")
    menu.AddCheckbox("Drones", "Drone ESP", "drone_esp", "Enable Drone ESP", true)
    menu.AddCheckbox("Drones", "Drone ESP", "drone_box", "Bounding Boxes", true)
    menu.AddCheckbox("Drones", "Drone ESP", "drone_name", "Model Name", true)
    menu.AddCheckbox("Drones", "Drone ESP", "drone_pilot", "Pilot Name", true)
    menu.AddCheckbox("Drones", "Drone ESP", "drone_dist", "Distance", true)
    menu.AddCheckbox("Drones", "Drone ESP", "drone_vel", "Velocity Tag", true)
    menu.AddCheckbox("Drones", "Drone ESP", "drone_hp", "Health Bar", true)
    menu.AddCheckbox("Drones", "Drone ESP", "drone_tracer", "Snaplines (Tracers)", true)
    menu.AddCombo("Drones", "Drone ESP", "drone_tracer_origin", "Tracer Origin", {"Bottom", "Screen Center", "Mouse"}, 0)
    menu.AddSeparator("Drones", "Drone ESP")
    menu.AddCheckbox("Drones", "Drone ESP", "drone_crashed", "Show Crashed / Wrecks", false)
    menu.AddSliderInt("Drones", "Drone ESP", "drone_max_dist", "Max Drone Distance", 500, 15000, 9000, "%d studs")
    menu.AddSeparator("Drones", "Drone ESP")
    menu.AddColorpicker("Drones", "Drone ESP", "drone_col_enemy", "Enemy Drone Color", {1.0, 0.25, 0.2, 1.0})
    menu.AddColorpicker("Drones", "Drone ESP", "drone_col_friendly", "Friendly Drone Color", {0.18, 0.8, 0.44, 1.0})
    menu.AddColorpicker("Drones", "Drone ESP", "drone_col_crashed", "Wreck Color", {0.45, 0.45, 0.5, 1.0})

    -- Tab 2: Aim Prediction & Assist
    menu.AddTab("Aimbot", "A")
    menu.AddGroup("Aimbot", "Lead Prediction")
    menu.AddCheckbox("Aimbot", "Lead Prediction", "aim_enabled", "Enable Lead Prediction", true)
    menu.AddCheckbox("Aimbot", "Lead Prediction", "aim_lead_circle", "Draw Lead Circle", true)
    menu.AddCheckbox("Aimbot", "Lead Prediction", "aim_lead_line", "Draw Lead Vector Line", true)
    menu.AddColorpicker("Aimbot", "Lead Prediction", "aim_col_lead", "Lead Circle Color", {0.0, 0.94, 1.0, 1.0})
    menu.AddColorpicker("Aimbot", "Lead Prediction", "aim_col_locked", "Target Locked Color", {1.0, 0.15, 0.15, 1.0})
    menu.AddSliderInt("Aimbot", "Lead Prediction", "aim_iters", "Solver Iterations", 3, 20, 10, "%d iters")
    menu.AddSliderFloat("Aimbot", "Lead Prediction", "aim_max_time", "Max Predict Time", 1.0, 10.0, 5.0, "%.1f s")
    menu.AddSliderFloat("Aimbot", "Lead Prediction", "aim_smooth_factor", "Kinematic Filter Smooth", 0.02, 0.3, 0.08, "%.2f")

    menu.AddGroup("Aimbot", "Aim Assist", 0, true)
    menu.AddCheckbox("Aimbot", "Aim Assist", "aim_assist", "Enable Aim Assist", true)
    menu.AddHotkey("Aimbot", "Aim Assist", "aim_key", "Aim Assist Key", VK_E)
    menu.AddCombo("Aimbot", "Aim Assist", "aim_assist_mode", "Assist Type", {"Camera LookAt", "Mouse Move"}, 0)
    menu.AddSliderInt("Aimbot", "Aim Assist", "aim_fov", "Aim FOV Radius", 20, 600, 140, "%d px")
    menu.AddCheckbox("Aimbot", "Aim Assist", "aim_show_fov", "Show FOV Circle", true)
    menu.AddSliderFloat("Aimbot", "Aim Assist", "aim_smooth", "Aim Smoothing (Higher = Slower)", 1.0, 25.0, 4.0, "%.1f")

    -- Tab 3: Soldiers
    menu.AddTab("Soldiers", "S")
    menu.AddGroup("Soldiers", "Soldier ESP")
    menu.AddCheckbox("Soldiers", "Soldier ESP", "soldier_esp", "Enable Soldier ESP", true)
    menu.AddCheckbox("Soldiers", "Soldier ESP", "soldier_enemy_only", "Enemies Only (DRG / Opponents)", true)
    menu.AddCheckbox("Soldiers", "Soldier ESP", "soldier_box", "Show Boxes", true)
    menu.AddCombo("Soldiers", "Soldier ESP", "soldier_box_style", "Box Style", {"Full Box", "Corner Box"}, 1)
    menu.AddCheckbox("Soldiers", "Soldier ESP", "soldier_chams", "Player Chams (Native)", false)
    menu.AddCheckbox("Soldiers", "Soldier ESP", "soldier_name", "Player Names", true)
    menu.AddCheckbox("Soldiers", "Soldier ESP", "soldier_dist", "Distance", true)
    menu.AddCheckbox("Soldiers", "Soldier ESP", "soldier_hp", "Health Bar", true)
    menu.AddCheckbox("Soldiers", "Soldier ESP", "soldier_tracer", "Tracers", false)
    menu.AddSliderInt("Soldiers", "Soldier ESP", "soldier_max_dist", "Max Distance", 200, 6000, 3500, "%d studs")
    menu.AddColorpicker("Soldiers", "Soldier ESP", "soldier_col_enemy", "Enemy Soldier Color", {1.0, 0.28, 0.28, 1.0})
    menu.AddColorpicker("Soldiers", "Soldier ESP", "soldier_col_friendly", "Friendly Soldier Color", {0.28, 0.7, 1.0, 1.0})

    -- Tab 4: Ballistics
    menu.AddTab("Ballistics", "B")
    menu.AddGroup("Ballistics", "Weapon & Turret Ballistics")
    menu.AddCheckbox("Ballistics", "Weapon & Turret Ballistics", "bal_auto", "Auto-Detect Weapon / ZU-23-2", true)
    menu.AddCheckbox("Ballistics", "Weapon & Turret Ballistics", "bal_comp_shooter", "Compensate Shooter Velocity", true)
    menu.AddCheckbox("Ballistics", "Weapon & Turret Ballistics", "bal_show_hud", "Show Ballistics HUD", true)
    menu.AddSeparator("Ballistics", "Weapon & Turret Ballistics")
    menu.AddSliderInt("Ballistics", "Weapon & Turret Ballistics", "bal_speed", "Manual Bullet Speed", 500, 5000, 1800, "%d studs/s")
    menu.AddSliderFloat("Ballistics", "Weapon & Turret Ballistics", "bal_drop", "Manual Bullet Drop", 0.0, 200.0, 35.04, "%.2f")
    menu.AddSliderFloat("Ballistics", "Weapon & Turret Ballistics", "bal_drag", "Manual Bullet Drag", 0.0, 0.001, 0.0, "%.5f")
end)

-- ═══════════════════════════════════════════════════════════════════════
-- STATE CACHE
-- ═══════════════════════════════════════════════════════════════════════
local activeDroneModels  = {}
local droneKinematics    = {}
local weaponConfigCache  = {}

local currentWeaponName  = "Default / None"
local currentBulletSpeed = DEFAULT_BALLISTIC_SPEED
local currentBulletDrop  = DEFAULT_BALLISTIC_DROP
local currentBulletDrag  = 0
local lastWeaponId       = ""

local activeAimTarget    = nil
local activeAimLeadPos   = nil
local activeAimTime      = 0
local isAimTargetLocked  = false

-- ═══════════════════════════════════════════════════════════════════════
-- HELPER UTILITIES
-- ═══════════════════════════════════════════════════════════════════════
local function safeV3(x, y, z)
    if Vector3.New then
        return Vector3.New(x or 0, y or 0, z or 0)
    end
    return Vector3.new(x or 0, y or 0, z or 0)
end

local function getAttr(inst, name)
    if not inst then return nil end
    local ok, res = pcall(function()
        if inst.GetAttribute then
            return inst:GetAttribute(name)
        end
        return nil
    end)
    return ok and res or nil
end

local function lerpV3(a, b, t)
    return a:Lerp(b, t)
end

-- ═══════════════════════════════════════════════════════════════════════
-- TEAM SIDES & ALIGNMENT RESOLUTION
-- ═══════════════════════════════════════════════════════════════════════
local function getTeamSide(teamName)
    if not teamName or teamName == "" then return nil end
    local side = nil
    pcall(function()
        local Teams = game:GetService("Teams")
        if Teams then
            local tObj = Teams:FindFirstChild(teamName)
            if tObj then
                side = getAttr(tObj, "TRV_Side")
            end
        end
    end)
    return side
end

local function isEnemyTeam(myTeamName, targetTeamName)
    if not targetTeamName or targetTeamName == "" then return true end
    if not myTeamName or myTeamName == "" then return true end
    if myTeamName == targetTeamName then return false end

    local mySide = getTeamSide(myTeamName)
    local theirSide = getTeamSide(targetTeamName)
    if mySide and theirSide then
        return mySide ~= theirSide
    end

    local dummianTerms = { "Dummian", "DRG", "Operator", "Red", "OpFor" }
    local noobianTerms = { "Noobian", "Blue", "Defender", "Trooper" }

    local function matchesAny(name, list)
        for _, term in ipairs(list) do
            if string.find(name, term) then return true end
        end
        return false
    end

    local myIsDummian = matchesAny(myTeamName, dummianTerms)
    local theirIsDummian = matchesAny(targetTeamName, dummianTerms)
    if myIsDummian ~= theirIsDummian then return true end

    return myTeamName ~= targetTeamName
end

-- ═══════════════════════════════════════════════════════════════════════
-- DYNAMIC BALLISTICS INSPECTION
-- ═══════════════════════════════════════════════════════════════════════
local function loadTRVConfig(cfgName)
    if weaponConfigCache[cfgName] then
        return weaponConfigCache[cfgName]
    end
    local cfg = nil
    pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        local trv = RS and RS:FindFirstChild("TRV")
        local shared = trv and trv:FindFirstChild("Shared")
        local configs = shared and shared:FindFirstChild("Configs")
        local mod = configs and configs:FindFirstChild(cfgName)
        if mod and mod:IsA("ModuleScript") then
            local ok, data = pcall(require, mod)
            if ok and type(data) == "table" then
                cfg = data
                weaponConfigCache[cfgName] = data
            end
        end
    end)
    return cfg
end

local function updateBallistics()
    if not menu.Get("bal_auto") then
        currentBulletSpeed = menu.Get("bal_speed") or DEFAULT_BALLISTIC_SPEED
        currentBulletDrop  = menu.Get("bal_drop") or DEFAULT_BALLISTIC_DROP
        currentBulletDrag  = menu.Get("bal_drag") or 0
        currentWeaponName  = "Manual Override"
        return
    end

    local lp = entity.GetLocalPlayer()
    local char = lp and lp.Character
    if not char then
        currentWeaponName  = "Unarmed"
        currentBulletSpeed = DEFAULT_BALLISTIC_SPEED
        currentBulletDrop  = DEFAULT_BALLISTIC_DROP
        currentBulletDrag  = 0
        lastWeaponId       = ""
        return
    end

    -- 1. Turret Mount Detection (e.g. ZU-23-2 Anti-Air Cannon)
    local hum = lp.Humanoid or (char.FindFirstChildOfClass and char:FindFirstChildOfClass("Humanoid"))
    local seat = hum and hum.SeatPart
    if seat then
        local turretModel = seat.FindFirstAncestorOfClass and seat:FindFirstAncestorOfClass("Model")
        local turretWeapon = turretModel and (getAttr(turretModel, "TurretWeapon") or getAttr(turretModel, "WeaponName"))
        if not turretWeapon and turretModel and turretModel.Parent then
            turretWeapon = getAttr(turretModel.Parent, "TurretWeapon") or getAttr(turretModel.Parent, "WeaponName")
        end

        local modelName = turretModel and turretModel.Name or ""
        if turretWeapon or string.find(modelName, "ZU") or string.find(modelName, "23") or string.find(modelName, "Turret") then
            local weaponKey = turretWeapon or modelName
            if weaponKey ~= lastWeaponId then
                lastWeaponId = weaponKey
                local cfg = loadTRVConfig(weaponKey)
                if cfg then
                    currentWeaponName  = weaponKey .. " (Turret)"
                    currentBulletSpeed = cfg.bulletSpeed or 3460
                    currentBulletDrop  = cfg.bulletDrop or 120
                    currentBulletDrag  = cfg.drag or 0.00022
                else
                    currentWeaponName  = "ZU-23-2 Turret"
                    currentBulletSpeed = 3460
                    currentBulletDrop  = 120
                    currentBulletDrag  = 0.00022
                end
            end
            return
        end
    end

    -- 2. Handheld Weapon Inspection
    local toolName = lp.ToolName
    if (not toolName or toolName == "") and char.FindFirstChildOfClass then
        local tool = char:FindFirstChildOfClass("Tool")
        if tool then toolName = tool.Name end
    end

    if toolName and toolName ~= "" then
        if toolName ~= lastWeaponId then
            lastWeaponId = toolName
            local cfg = loadTRVConfig(toolName)
            if cfg then
                currentWeaponName  = toolName
                currentBulletSpeed = cfg.bulletSpeed or DEFAULT_BALLISTIC_SPEED
                currentBulletDrop  = cfg.bulletDrop or DEFAULT_BALLISTIC_DROP
                currentBulletDrag  = cfg.drag or 0
            elseif string.find(toolName, "PKP") then
                currentWeaponName  = toolName
                currentBulletSpeed = 1800
                currentBulletDrop  = 35.0357
                currentBulletDrag  = 0
            elseif string.find(toolName, "AK") then
                currentWeaponName  = toolName
                currentBulletSpeed = 1600
                currentBulletDrop  = 35.0357
                currentBulletDrag  = 0
            elseif string.find(toolName, "SVD") then
                currentWeaponName  = toolName
                currentBulletSpeed = 2400
                currentBulletDrop  = 35.0357
                currentBulletDrag  = 0
            else
                currentWeaponName  = toolName .. " (Standard)"
                currentBulletSpeed = DEFAULT_BALLISTIC_SPEED
                currentBulletDrop  = DEFAULT_BALLISTIC_DROP
                currentBulletDrag  = 0
            end
        end
        return
    end

    if lastWeaponId ~= "NONE" then
        lastWeaponId = "NONE"
        currentWeaponName  = "Default / Fallback"
        currentBulletSpeed = DEFAULT_BALLISTIC_SPEED
        currentBulletDrop  = DEFAULT_BALLISTIC_DROP
        currentBulletDrag  = 0
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- BACKGROUND DRONE HARVESTER (High Performance Thread)
-- ═══════════════════════════════════════════════════════════════════════
thread.Create(function()
    local found = {}

    -- Scan CollectionService tagged drones
    pcall(function()
        local CS = game:GetService("CollectionService")
        if CS and CS.GetTagged then
            local list = CS:GetTagged("UAVDrone")
            if list then
                for _, d in ipairs(list) do
                    if d and d.Parent then
                        found[d] = true
                    end
                end
            end
        end
    end)

    -- Scan Workspace descendants
    pcall(function()
        local ws = game.Workspace
        if ws then
            for _, child in ipairs(ws:GetChildren()) do
                if child and child.ClassName == "Model" then
                    local name = child.Name
                    local isDrone = false
                    local isUAV = getAttr(child, "UAV") or getAttr(child, "UAVDrone")

                    if isUAV then
                        isDrone = true
                    elseif string.find(name, "Drone") or string.find(name, "UAV") or string.find(name, "FPV")
                        or string.find(name, "Switchblade") or string.find(name, "Lancet") or string.find(name, "Geran") then
                        isDrone = true
                    elseif child.FindFirstChild and child:FindFirstChild("Base")
                        and (child:FindFirstChild("Rotor") or child:FindFirstChild("Propeller")) then
                        isDrone = true
                    end

                    if isDrone then
                        found[child] = true
                    end
                end
            end
        end
    end)

    activeDroneModels = found
end, 350)

-- ═══════════════════════════════════════════════════════════════════════
-- KINEMATICS & LEAD INTERCEPT SOLVER
-- ═══════════════════════════════════════════════════════════════════════
local function updateDroneKinematics(model, primaryPart, dt)
    local pos = primaryPart.Position
    if not pos then return nil end

    local rawVel = nil
    pcall(function()
        rawVel = primaryPart.AssemblyLinearVelocity or primaryPart.Velocity
    end)

    local now = utility.GetTime()
    local state = droneKinematics[model]

    if not state then
        rawVel = rawVel or safeV3(0, 0, 0)
        state = {
            pos = pos,
            vel = rawVel,
            smoothVel = rawVel,
            lastVel = rawVel,
            accel = safeV3(0, 0, 0),
            lastTime = now,
            lastPos = pos,
        }
        droneKinematics[model] = state
        return state
    end

    local elapsed = math.max(0.001, math.min(now - state.lastTime, 0.25))
    if not rawVel then
        rawVel = (pos - state.lastPos) * (1 / elapsed)
    end

    local smoothFactor = menu.Get("aim_smooth_factor") or 0.08
    local alpha = 1 - math.exp(-elapsed / smoothFactor)
    local newSmoothVel = lerpV3(state.smoothVel, rawVel, alpha)

    local rawAccel = (newSmoothVel - state.lastVel) * (1 / elapsed)
    local accelAlpha = 1 - math.exp(-elapsed / (smoothFactor * 2.2))
    local newAccel = lerpV3(state.accel, rawAccel, accelAlpha)

    if newAccel.Magnitude > 350 then
        newAccel = newAccel.Unit * 350
    end

    state.pos = pos
    state.lastPos = pos
    state.vel = rawVel
    state.smoothVel = newSmoothVel
    state.lastVel = newSmoothVel
    state.accel = newAccel
    state.lastTime = now

    return state
end

local function solveLead(shooterPos, shooterVel, targetPos, targetVel, targetAccel, bulletSpeed, bulletDrop, bulletDrag, maxTime, iters)
    local tof = (targetPos - shooterPos).Magnitude / bulletSpeed
    local aimPos = targetPos

    for _ = 1, iters do
        local futurePos = targetPos + (targetVel * tof) + (targetAccel * (0.5 * tof * tof))
        local effOrigin = shooterPos + (shooterVel * tof)
        local delta = futurePos - effOrigin
        local dist = delta.Magnitude

        local effSpeed = bulletSpeed
        if bulletDrag and bulletDrag > 0 then
            effSpeed = bulletSpeed / (1 + bulletDrag * dist)
        end

        local verticalDrop = 0.5 * bulletDrop * (tof * tof)
        local compensated = futurePos + safeV3(0, verticalDrop, 0)

        local updatedTof = (compensated - effOrigin).Magnitude / effSpeed
        if math.abs(updatedTof - tof) < 0.0004 then
            aimPos = compensated
            tof = updatedTof
            break
        end

        tof = updatedTof
        aimPos = compensated
    end

    if tof > maxTime then
        return nil, nil
    end

    return aimPos, tof
end

-- ═══════════════════════════════════════════════════════════════════════
-- AIM ASSIST DISPATCHER (Camera / Mouse)
-- ═══════════════════════════════════════════════════════════════════════
local function performAimAssist(targetWorldPos, targetScreenX, targetScreenY, cx, cy)
    local mode = menu.Get("aim_assist_mode") or 0
    local smooth = math.max(1.0, menu.Get("aim_smooth") or 4.0)

    if mode == 0 then
        -- Native Camera LookAt
        pcall(function()
            camera.LookAt(targetWorldPos.X, targetWorldPos.Y, targetWorldPos.Z, smooth)
        end)
    else
        -- Relative Mouse Move
        local dx = (targetScreenX - cx) / smooth
        local dy = (targetScreenY - cy) / smooth
        pcall(function()
            input.MoveMouse(dx, dy)
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- RENDER LOOP (OnFrame Pipeline)
-- ═══════════════════════════════════════════════════════════════════════
OnFrame = function()
    local dt = utility.GetDeltaTime()
    local sw, sh = draw.GetScreenSize()
    local cx, cy = sw * 0.5, sh * 0.5

    -- Periodic ballistics check
    updateBallistics()

    local lp = entity.GetLocalPlayer()
    local myTeam = lp and lp.Team or ""
    local camPos = camera.GetPosition()

    -- Shooter velocity for relative intercept
    local shooterVel = safeV3(0, 0, 0)
    if menu.Get("bal_comp_shooter") and lp and lp.Velocity then
        shooterVel = lp.Velocity
    end

    local aimFovRadius = menu.Get("aim_fov") or 140
    local isAimEnabled = menu.Get("aim_enabled")
    local isAimAssistEnabled = menu.Get("aim_assist")
    local aimVk = menu.GetKey("aim_key") or VK_E
    local isAimKeyDown = input.IsKeyDown(aimVk)

    -- Draw FOV Circle
    if isAimEnabled and menu.Get("aim_show_fov") then
        local fovCol = isAimTargetLocked and (menu.GetColor("aim_col_locked") or {1, 0.15, 0.15, 0.7})
            or {1.0, 1.0, 1.0, 0.35}
        draw.Circle(cx, cy, aimFovRadius, fovCol, 48, 1.2)
    end

    -- ─────────────────────────────────────────────────────────────────
    -- 1. SOLDIER ESP PASS
    -- ─────────────────────────────────────────────────────────────────
    if menu.Get("soldier_esp") then
        local maxSoldierDist = menu.Get("soldier_max_dist") or 3500
        local enemiesOnly = menu.Get("soldier_enemy_only")
        local boxStyle = menu.Get("soldier_box_style") or 1
        local showBoxes = menu.Get("soldier_box")
        local showChams = menu.Get("soldier_chams")
        local showNames = menu.Get("soldier_name")
        local showDist = menu.Get("soldier_dist")
        local showHp = menu.Get("soldier_hp")
        local showTracers = menu.Get("soldier_tracer")

        local enemyColor = menu.GetColor("soldier_col_enemy") or {1.0, 0.28, 0.28, 1.0}
        local friendlyColor = menu.GetColor("soldier_col_friendly") or {0.28, 0.7, 1.0, 1.0}

        local players = entity.GetPlayers()
        for _, p in ipairs(players) do
            if not p.IsLocal and p.IsAlive and p.Position then
                local dist = p:DistanceTo()
                if dist <= maxSoldierDist then
                    local isEnemy = isEnemyTeam(myTeam, p.Team)
                    if (not enemiesOnly) or isEnemy then
                        local col = isEnemy and enemyColor or friendlyColor

                        -- Chams
                        if showChams then
                            pcall(function()
                                draw.ChamsPlayer(p, {col[1], col[2], col[3], 0.65}, 2)
                            end)
                        end

                        local bounds = p:GetBounds()
                        if bounds and bounds.valid then
                            local bx, by, bw, bh = bounds.x, bounds.y, bounds.w, bounds.h

                            -- Bounding Box
                            if showBoxes then
                                if boxStyle == 1 then
                                    draw.CornerBox(bx, by, bw, bh, col)
                                else
                                    draw.Box(bx, by, bw, bh, col, 0)
                                end
                            end

                            -- Health Bar
                            if showHp and p.Health and p.MaxHealth then
                                draw.HealthBar(bx - 6, by, bh, p.Health, p.MaxHealth)
                            end

                            -- Name Tag
                            if showNames then
                                local nameText = p.Name
                                local nw, nh = draw.GetTextSize(nameText, 13)
                                draw.Text(bx + bw * 0.5 - nw * 0.5, by - nh - 2, nameText, col, 13)
                            end

                            -- Distance Tag
                            if showDist then
                                local distText = string.format("%d studs", math.floor(dist))
                                local dw, _ = draw.GetTextSize(distText, 11)
                                draw.Text(bx + bw * 0.5 - dw * 0.5, by + bh + 2, distText, {0.75, 0.75, 0.8, 1.0}, 11)
                            end

                            -- Snapline
                            if showTracers then
                                draw.Line(cx, sh, bx + bw * 0.5, by + bh, {col[1], col[2], col[3], 0.4}, 1.0)
                            end
                        end
                    end
                end
            end
        end
    end

    -- ─────────────────────────────────────────────────────────────────
    -- 2. DRONE ESP & KINEMATICS PASS
    -- ─────────────────────────────────────────────────────────────────
    local isDroneEsp = menu.Get("drone_esp")
    local showWrecks = menu.Get("drone_crashed")
    local maxDroneDist = menu.Get("drone_max_dist") or 9000
    local showDroneBoxes = menu.Get("drone_box")
    local showDroneNames = menu.Get("drone_name")
    local showDronePilots = menu.Get("drone_pilot")
    local showDroneDist = menu.Get("drone_dist")
    local showDroneVel = menu.Get("drone_vel")
    local showDroneHp = menu.Get("drone_hp")
    local showDroneTracers = menu.Get("drone_tracer")
    local tracerOriginMode = menu.Get("drone_tracer_origin") or 0

    local enemyDroneCol = menu.GetColor("drone_col_enemy") or {1.0, 0.25, 0.2, 1.0}
    local friendDroneCol = menu.GetColor("drone_col_friendly") or {0.18, 0.8, 0.44, 1.0}
    local wreckDroneCol = menu.GetColor("drone_col_crashed") or {0.45, 0.45, 0.5, 1.0}

    local leadCircleCol = menu.GetColor("aim_col_lead") or {0.0, 0.94, 1.0, 1.0}
    local lockedAimCol = menu.GetColor("aim_col_locked") or {1.0, 0.15, 0.15, 1.0}
    local maxPredictTime = menu.Get("aim_max_time") or 5.0
    local solverIters = menu.Get("aim_iters") or 10

    local tracerStartX, tracerStartY = cx, sh
    if tracerOriginMode == 1 then
        tracerStartX, tracerStartY = cx, cy
    elseif tracerOriginMode == 2 then
        local mx, my = input.GetMousePosition()
        tracerStartX, tracerStartY = mx, my
    end

    local bestTargetModel = nil
    local bestTargetPos = nil
    local bestLeadScreenX, bestLeadScreenY = nil, nil
    local bestFovDist = aimFovRadius

    for drone in pairs(activeDroneModels) do
        if drone.Parent then
            local base = nil
            pcall(function()
                base = drone:FindFirstChild("Base") or drone.PrimaryPart
                    or (drone.FindFirstChildWhichIsA and drone:FindFirstChildWhichIsA("BasePart"))
            end)

            if base and base.Position then
                local basePos = base.Position
                local dist = (camPos - basePos).Magnitude

                if dist <= maxDroneDist then
                    local isCrashed = getAttr(drone, "Crashed") or getAttr(drone, "Falling")
                    local hp = getAttr(drone, "HP")
                    local maxHp = getAttr(drone, "MaxHP") or 100
                    if hp and hp <= 0 then isCrashed = true end

                    -- Filter crashed drones / wrecks if switch is disabled
                    if not (isCrashed and not showWrecks) then
                        local state = updateDroneKinematics(drone, base, dt)

                        -- Determine Drone Team & Friendliness
                        local isEnemy = true
                        local droneTeam = getAttr(drone, "TRV_Team")
                        local pilotUserId = getAttr(drone, "OperatorUserId")
                        local pilotName = nil

                        if pilotUserId then
                            for _, ply in ipairs(entity.GetPlayers()) do
                                if ply.UserId == pilotUserId then
                                    pilotName = ply.Name
                                    if not isEnemyTeam(myTeam, ply.Team) then
                                        isEnemy = false
                                    end
                                    break
                                end
                            end
                        elseif droneTeam and not isEnemyTeam(myTeam, droneTeam) then
                            isEnemy = false
                        end

                        local boxCol = isCrashed and wreckDroneCol or (isEnemy and enemyDroneCol or friendDroneCol)

                        -- Project Drone to Screen
                        local sx, sy, onScreen = draw.WorldToScreen(basePos.X, basePos.Y, basePos.Z)

                        if onScreen and isDroneEsp then
                            -- Estimate Drone Box Size
                            local topX, topY, topOk = draw.WorldToScreen(basePos.X, basePos.Y + 2.0, basePos.Z)
                            local botX, botY, botOk = draw.WorldToScreen(basePos.X, basePos.Y - 2.0, basePos.Z)
                            local boxH = (topOk and botOk) and math.max(14, math.abs(botY - topY)) or math.max(14, 1800 / dist)
                            local boxW = boxH * 1.5
                            local boxX = sx - boxW * 0.5
                            local boxY = sy - boxH * 0.5

                            -- Box
                            if showDroneBoxes then
                                draw.Box(boxX, boxY, boxW, boxH, boxCol, 0)
                            end

                            -- Health Bar
                            if showDroneHp and hp and maxHp and maxHp > 0 then
                                draw.HealthBar(boxX - 5, boxY, boxH, hp, maxHp)
                            end

                            -- Model Name
                            if showDroneNames then
                                local label = isCrashed and (drone.Name .. " [WRECK]") or drone.Name
                                local nw, nh = draw.GetTextSize(label, 12)
                                draw.Text(boxX + boxW * 0.5 - nw * 0.5, boxY - nh - 2, label, boxCol, 12)
                            end

                            -- Pilot Tag
                            if showDronePilots and pilotName then
                                local pLabel = "Pilot: " .. pilotName
                                local pw, ph = draw.GetTextSize(pLabel, 11)
                                draw.Text(boxX + boxW * 0.5 - pw * 0.5, boxY - ph - (showDroneNames and 16 or 2), pLabel, {0.85, 0.85, 0.9, 1.0}, 11)
                            end

                            -- Distance Tag
                            if showDroneDist then
                                local distText = string.format("%d studs", math.floor(dist))
                                local dw, _ = draw.GetTextSize(distText, 11)
                                draw.Text(boxX + boxW * 0.5 - dw * 0.5, boxY + boxH + 2, distText, {0.7, 0.75, 0.85, 1.0}, 11)
                            end

                            -- Velocity Tag
                            if showDroneVel and state and state.smoothVel then
                                local velSpeed = state.smoothVel.Magnitude
                                local velText = string.format("%.1f m/s", velSpeed * 0.28)
                                local vw, _ = draw.GetTextSize(velText, 11)
                                draw.Text(boxX + boxW * 0.5 - vw * 0.5, boxY + boxH + (showDroneDist and 15 or 2), velText, {0.4, 0.88, 1.0, 1.0}, 11)
                            end

                            -- Snapline
                            if showDroneTracers then
                                draw.Line(tracerStartX, tracerStartY, sx, boxY + boxH, {boxCol[1], boxCol[2], boxCol[3], 0.45}, 1.0)
                            end
                        end

                        -- ─────────────────────────────────────────────
                        -- 3. LEAD AIM PREDICTION EVALUATION
                        -- ─────────────────────────────────────────────
                        if isAimEnabled and isEnemy and (not isCrashed) and state then
                            local leadAimPos, tof = solveLead(
                                camPos,
                                shooterVel,
                                state.pos,
                                state.smoothVel,
                                state.accel,
                                currentBulletSpeed,
                                currentBulletDrop,
                                currentBulletDrag,
                                maxPredictTime,
                                solverIters
                            )

                            if leadAimPos and tof then
                                local lx, ly, leadOnScreen = draw.WorldToScreen(leadAimPos.X, leadAimPos.Y, leadAimPos.Z)

                                if leadOnScreen then
                                    local fovDist = math.sqrt((lx - cx) * (lx - cx) + (ly - cy) * (ly - cy))

                                    -- Check if closest candidate to center crosshair
                                    if fovDist < bestFovDist then
                                        bestFovDist = fovDist
                                        bestTargetModel = drone
                                        bestTargetPos = leadAimPos
                                        bestLeadScreenX = lx
                                        bestLeadScreenY = ly
                                        activeAimTime = tof
                                    end

                                    -- Draw Lead Circle & Vector Line
                                    local isTargetLocked = (bestTargetModel == drone and isAimKeyDown and isAimAssistEnabled)
                                    local curLeadCol = isTargetLocked and lockedAimCol or leadCircleCol

                                    if menu.Get("aim_lead_circle") then
                                        draw.Circle(lx, ly, 8, curLeadCol, 24, 2.0)
                                        draw.CircleFilled(lx, ly, 3, curLeadCol, 12)
                                        draw.Text(lx + 10, ly - 6, string.format("%.2fs", tof), curLeadCol, 11)
                                    end

                                    if menu.Get("aim_lead_line") and onScreen then
                                        draw.Line(sx, sy, lx, ly, {curLeadCol[1], curLeadCol[2], curLeadCol[3], 0.55}, 1.2)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- ─────────────────────────────────────────────────────────────────
    -- 4. DISPATCH AIM ASSIST LOCK
    -- ─────────────────────────────────────────────────────────────────
    if bestTargetModel and bestTargetPos and bestLeadScreenX and bestLeadScreenY then
        activeAimTarget = bestTargetModel
        activeAimLeadPos = bestTargetPos

        if isAimAssistEnabled and isAimKeyDown then
            isAimTargetLocked = true
            performAimAssist(bestTargetPos, bestLeadScreenX, bestLeadScreenY, cx, cy)
        else
            isAimTargetLocked = false
        end
    else
        activeAimTarget = nil
        activeAimLeadPos = nil
        isAimTargetLocked = false
    end

    -- ─────────────────────────────────────────────────────────────────
    -- 5. BALLISTICS TELEMETRY HUD (draw.Window)
    -- ─────────────────────────────────────────────────────────────────
    if menu.Get("bal_show_hud") then
        local targetName = activeAimTarget and activeAimTarget.Name or "None"
        local lockStatus = isAimTargetLocked and "[LOCKED]" or (activeAimTarget and "[ACQUIRED]" or "[STANDBY]")

        local hudItems = {
            "Weapon: " .. currentWeaponName,
            string.format("Speed: %.1f st/s", currentBulletSpeed),
            string.format("Drop: %.2f", currentBulletDrop),
            string.format("Drag: %.5f", currentBulletDrag),
            "Target: " .. targetName .. " " .. lockStatus,
            string.format("Lead Time: %.2fs", activeAimTime or 0),
        }

        draw.Window(20, 20, "skyfire_hud", "SKYFIRE BALLISTICS", hudItems)
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- INITIAL LOAD NOTIFICATION
-- ═══════════════════════════════════════════════════════════════════════
pcall(function()
    notify.Success("SKYFIRE VECTOR", "Native UI & 2nd-Order Aim Prediction active", 5)
end)
