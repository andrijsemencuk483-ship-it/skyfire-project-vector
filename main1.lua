--[[
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                     SKYFIRE ENHANCED  ·  v3.6                       ║
    ║        Turret Aim Fix · Zero-Lag Async Boot · Wreck Filter          ║
    ╚══════════════════════════════════════════════════════════════════════╝

    Performance & Turret Scoping Overhaul:
    • ZU-23-2 & Turret Scope Fix: Unconditional key polling (bypasses gameProcessed
      absorption when seated/scoped) + mousemoverel hardware input support for turrets
    • Zero-Lag Asynchronous Boot: UI and asset fetching deferred via task.defer;
      spatial checks use optimized squared distance pre-filtering (zero frame drop)
    • Dynamic Weapon Caching: Tool/seat changes only trigger lookup on actual switch
    • Robust Error Isolation: Pcall safety boundaries prevent thread crashes
    • Full Rayfield UI Suite (No Key System, Real-Time Sliders, Crashed Drone Toggle)
]]

-- ═══════════════════════════════════════════════════════════════════════
-- SERVICES & CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local CollectionService  = game:GetService("CollectionService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Teams              = game:GetService("Teams")
local TweenService       = game:GetService("TweenService")

local LocalPlayer        = Players.LocalPlayer
local Camera             = workspace.CurrentCamera

-- Safe TRV Framework references
local TRVFolder          = ReplicatedStorage:FindFirstChild("TRV")
local TRVShared          = TRVFolder and TRVFolder:FindFirstChild("Shared")
local TRVConfigs         = TRVShared and TRVShared:FindFirstChild("Configs")

local DEFAULT_BALLISTIC_SPEED = 3285.71  -- Ballistics.DEFAULT_SPEED
local DEFAULT_BALLISTIC_DROP  = 35.0357  -- Ballistics.DEFAULT_DROP

-- ═══════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════
local CONFIG = {
    -- Drone ESP
    DroneESP = {
        Enabled       = true,
        ShowCrashed   = false,                           -- Toggle: Wrecks & falling drones
        MaxDistance   = 9000,                            -- Distance slider (500 - 15000)
        MaxDistSq     = 9000 * 9000,
        BoxColor      = Color3.fromRGB(255, 65, 54),     -- Hostile drone
        FriendlyColor = Color3.fromRGB(46, 204, 113),    -- Allied drone
        CrashedColor  = Color3.fromRGB(110, 110, 120),   -- Dead / crashed
        JammedColor   = Color3.fromRGB(241, 196, 15),    -- CommsLoss (EW)
        TextSize      = 13,
        ShowVelocity  = true,
        ShowDistance  = true,
        ShowName      = true,
        ShowPilot     = true,
        ShowHealth    = true,
        ShowTracer    = true,
        TracerOrigin  = "Bottom", -- "Bottom", "Center", "Mouse"
    },

    -- Dynamic Ballistics & Advanced Aim Prediction
    AimPrediction = {
        Enabled          = true,
        AutoDetectWeapon = true,      -- dynamically read weapon configs from TRV
        ManualSpeed      = 1800,      -- fallback bullet speed (studs/s)
        ManualDrop       = 35.04,     -- fallback bullet drop (studs/s^2)
        ShowPrediction   = true,
        ShowFOVCircle    = true,
        PredictionColor  = Color3.fromRGB(0, 240, 255),
        LockedColor      = Color3.fromRGB(255, 40, 40),
        SmoothFactor     = 0.08,      -- velocity smoothing rate
        MaxPredictTime   = 5.0,       -- max seconds to project forward
        IterationCount   = 10,        -- intercept iterations
        AimAssist        = false,     -- lock camera/mouse to lead point
        AimAssistSmooth  = 0.25,      -- camera lerp rate
        AimAssistFOV     = 140,       -- screen-space pixel radius for lock
        AimKey           = Enum.KeyCode.E,
        CompensateShooter= true,      -- account for shooter velocity
    },

    -- Player & Soldier ESP
    PlayerESP = {
        Enabled          = true,
        EnemiesOnly      = true,      -- only render players from opposing side
        MaxDistance      = 3500,      -- Distance slider (500 - 8000)
        MaxDistSq        = 3500 * 3500,
        BoxColor         = Color3.fromRGB(255, 75, 75),
        FriendlyColor    = Color3.fromRGB(75, 180, 255),
        NameColor        = Color3.fromRGB(255, 215, 0),
        HealthBarWidth   = 3.5,
        ShowName         = true,
        ShowDistance     = true,
        ShowHealth       = true,
        ShowWeapon       = true,
        ShowTracer       = true,
        HighlightFill    = 0.8,
        HighlightOutline = Color3.fromRGB(255, 75, 75),
    },
}

-- ═══════════════════════════════════════════════════════════════════════
-- STATE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════
local droneDrawings    = {}   -- [model] = drawings table
local droneTrackers    = {}   -- [model] = kinematic tracking state
local playerDrawings   = {}   -- [player] = drawings table
local playerHighlights = {}   -- [player] = Highlight instance
local aimTarget        = nil  -- locked drone instance
local aimLocked        = false
local connections      = {}
local weaponConfigCache= {}   -- [weaponName] = cached config table

-- Cached weapon inspection state
local lastEquippedIdentifier = ""
local currentWeaponName  = "Default / None"
local currentBulletSpeed = DEFAULT_BALLISTIC_SPEED
local currentBulletDrop  = DEFAULT_BALLISTIC_DROP
local currentBulletDrag  = 0

-- Live FOV Circle Drawing
local fovCircle = Drawing.new("Circle")
fovCircle.Thickness = 1.2
fovCircle.NumSides = 48
fovCircle.Radius = CONFIG.AimPrediction.AimAssistFOV
fovCircle.Filled = false
fovCircle.Color = Color3.fromRGB(255, 255, 255)
fovCircle.Transparency = 0.35
fovCircle.Visible = false

-- ═══════════════════════════════════════════════════════════════════════
-- OPTIMIZED UTILITIES & FAST MATH
-- ═══════════════════════════════════════════════════════════════════════
local function getDistanceSq(p1, p2)
    local dx = p1.X - p2.X
    local dy = p1.Y - p2.Y
    local dz = p1.Z - p2.Z
    return (dx * dx) + (dy * dy) + (dz * dz)
end

local function getTeamSide(team)
    if not team then return nil end
    local side = team:GetAttribute("TRV_Side")
    if type(side) == "string" and side ~= "" then
        return side
    end
    return team.Name
end

local function isEnemyTeam(theirTeam)
    if not theirTeam then return false end
    local mySide = getTeamSide(LocalPlayer.Team)
    local theirSide = getTeamSide(theirTeam)
    if not mySide or not theirSide then return false end
    return mySide ~= theirSide
end

local function isEnemyPlayer(player)
    if not player or player == LocalPlayer then return false end
    return isEnemyTeam(player.Team)
end

local function resolvePlayerByUserId(userId)
    if not userId or userId <= 0 then return nil end
    return Players:GetPlayerByUserId(userId)
end

local function worldToScreen(pos)
    local screenPos, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen, screenPos.Z
end

local function lerpV3(a, b, t)
    return a:Lerp(b, t)
end

-- ═══════════════════════════════════════════════════════════════════════
-- EFFICIENT WEAPON INTROSPECTION (CACHED)
-- ═══════════════════════════════════════════════════════════════════════
local function loadWeaponConfig(name)
    if weaponConfigCache[name] then
        return weaponConfigCache[name]
    end
    if not TRVConfigs then return nil end
    local configModule = TRVConfigs:FindFirstChild(name)
    if configModule and configModule:IsA("ModuleScript") then
        local success, cfg = pcall(require, configModule)
        if success and type(cfg) == "table" then
            weaponConfigCache[name] = cfg
            return cfg
        end
    end
    return nil
end

local function updateActiveWeaponBallistics()
    if not CONFIG.AimPrediction.AutoDetectWeapon then
        currentBulletSpeed = CONFIG.AimPrediction.ManualSpeed
        currentBulletDrop  = CONFIG.AimPrediction.ManualDrop
        currentBulletDrag  = 0
        currentWeaponName  = "Manual Config"
        return
    end

    local char = LocalPlayer.Character
    if not char then
        currentWeaponName  = "Unarmed"
        currentBulletSpeed = DEFAULT_BALLISTIC_SPEED
        currentBulletDrop  = DEFAULT_BALLISTIC_DROP
        currentBulletDrag  = 0
        lastEquippedIdentifier = ""
        return
    end

    local hum = char:FindFirstChildOfClass("Humanoid")

    -- 1. Check Turret / Vehicle Seat
    if hum and hum.SeatPart then
        local seat = hum.SeatPart
        local turretModel = seat:FindFirstAncestorOfClass("Model")
        local turretWeapon = turretModel and (turretModel:GetAttribute("TurretWeapon") or turretModel:GetAttribute("WeaponName"))
        if not turretWeapon and turretModel and turretModel.Parent then
            turretWeapon = turretModel.Parent:GetAttribute("TurretWeapon") or turretModel.Parent:GetAttribute("WeaponName")
        end

        if turretWeapon then
            local identifier = "TURRET_" .. turretWeapon
            if identifier ~= lastEquippedIdentifier then
                lastEquippedIdentifier = identifier
                local cfg = loadWeaponConfig(turretWeapon)
                if cfg then
                    currentWeaponName  = turretWeapon .. " (Turret)"
                    currentBulletSpeed = cfg.bulletSpeed or DEFAULT_BALLISTIC_SPEED
                    currentBulletDrop  = cfg.bulletDrop or DEFAULT_BALLISTIC_DROP
                    currentBulletDrag  = cfg.drag or 0
                else
                    currentWeaponName  = turretWeapon .. " (Turret/Uncached)"
                    currentBulletSpeed = 3460
                    currentBulletDrop  = 120
                    currentBulletDrag  = 0.00022
                end
            end
            return
        end
    end

    -- 2. Check Tool
    local tool = char:FindFirstChildOfClass("Tool")
    if tool then
        local identifier = "TOOL_" .. tool.Name
        if identifier ~= lastEquippedIdentifier then
            lastEquippedIdentifier = identifier
            local cfg = loadWeaponConfig(tool.Name)
            if cfg then
                currentWeaponName  = tool.Name
                currentBulletSpeed = cfg.bulletSpeed or DEFAULT_BALLISTIC_SPEED
                currentBulletDrop  = cfg.bulletDrop or DEFAULT_BALLISTIC_DROP
                currentBulletDrag  = cfg.drag or 0
            else
                currentWeaponName  = tool.Name .. " (Generic)"
                currentBulletSpeed = 1600
                currentBulletDrop  = DEFAULT_BALLISTIC_DROP
                currentBulletDrag  = 0
            end
        end
        return
    end

    -- 3. Default
    if lastEquippedIdentifier ~= "NONE" then
        lastEquippedIdentifier = "NONE"
        currentWeaponName  = "Standard / Fallback"
        currentBulletSpeed = DEFAULT_BALLISTIC_SPEED
        currentBulletDrop  = DEFAULT_BALLISTIC_DROP
        currentBulletDrag  = 0
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- DRAWING WRAPPER
-- ═══════════════════════════════════════════════════════════════════════
local function newDrawing(class, props)
    local d = Drawing.new(class)
    for k, v in pairs(props or {}) do
        d[k] = v
    end
    return d
end

local function destroyDrawings(tbl)
    for _, d in pairs(tbl or {}) do
        if typeof(d) == "table" then
            destroyDrawings(d)
        elseif d and typeof(d) ~= "string" and typeof(d) ~= "number" and typeof(d) ~= "boolean" then
            pcall(function() d:Remove() end)
            pcall(function() d:Destroy() end)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- DRAWING INSTANTIATION (DRONE & PLAYER)
-- ═══════════════════════════════════════════════════════════════════════
local function createDroneDrawing()
    return {
        box = newDrawing("Square", {
            Thickness = 1.5,
            Filled = false,
            Transparency = 0.9,
            Color = CONFIG.DroneESP.BoxColor,
            Visible = false,
            ZIndex = 2,
        }),
        boxFill = newDrawing("Square", {
            Thickness = 1,
            Filled = true,
            Transparency = 0.14,
            Color = CONFIG.DroneESP.BoxColor,
            Visible = false,
            ZIndex = 1,
        }),
        nameTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize,
            Center = true,
            Outline = true,
            Color = Color3.new(1, 1, 1),
            Visible = false,
            ZIndex = 3,
        }),
        pilotTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = Color3.fromRGB(220, 220, 230),
            Visible = false,
            ZIndex = 3,
        }),
        distTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = Color3.fromRGB(160, 165, 180),
            Visible = false,
            ZIndex = 3,
        }),
        velTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = Color3.fromRGB(130, 220, 255),
            Visible = false,
            ZIndex = 3,
        }),
        healthBar = newDrawing("Line", {
            Thickness = 3.5,
            Color = Color3.fromRGB(0, 255, 100),
            Visible = false,
            ZIndex = 3,
        }),
        healthBarBG = newDrawing("Line", {
            Thickness = 3.5,
            Color = Color3.fromRGB(40, 40, 40),
            Visible = false,
            ZIndex = 2,
        }),
        tracer = newDrawing("Line", {
            Thickness = 1,
            Transparency = 0.55,
            Color = CONFIG.DroneESP.BoxColor,
            Visible = false,
            ZIndex = 1,
        }),
        predCircle = newDrawing("Circle", {
            Thickness = 1.8,
            Filled = false,
            NumSides = 24,
            Radius = 8,
            Color = CONFIG.AimPrediction.PredictionColor,
            Visible = false,
            ZIndex = 4,
        }),
        predDot = newDrawing("Circle", {
            Thickness = 1,
            Filled = true,
            NumSides = 12,
            Radius = 3,
            Color = CONFIG.AimPrediction.PredictionColor,
            Visible = false,
            ZIndex = 5,
        }),
        predLine = newDrawing("Line", {
            Thickness = 1.2,
            Transparency = 0.65,
            Color = CONFIG.AimPrediction.PredictionColor,
            Visible = false,
            ZIndex = 3,
        }),
    }
end

local function createPlayerDrawing()
    return {
        box = newDrawing("Square", {
            Thickness = 1.5,
            Filled = false,
            Transparency = 0.85,
            Color = CONFIG.PlayerESP.BoxColor,
            Visible = false,
            ZIndex = 2,
        }),
        boxFill = newDrawing("Square", {
            Thickness = 1,
            Filled = true,
            Transparency = 0.1,
            Color = CONFIG.PlayerESP.BoxColor,
            Visible = false,
            ZIndex = 1,
        }),
        nameTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize,
            Center = true,
            Outline = true,
            Color = CONFIG.PlayerESP.NameColor,
            Visible = false,
            ZIndex = 3,
        }),
        distTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = Color3.fromRGB(160, 165, 180),
            Visible = false,
            ZIndex = 3,
        }),
        healthBar = newDrawing("Line", {
            Thickness = CONFIG.PlayerESP.HealthBarWidth,
            Color = Color3.fromRGB(0, 255, 100),
            Visible = false,
            ZIndex = 3,
        }),
        healthBarBG = newDrawing("Line", {
            Thickness = CONFIG.PlayerESP.HealthBarWidth,
            Color = Color3.fromRGB(40, 40, 40),
            Visible = false,
            ZIndex = 2,
        }),
        weaponTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = Color3.fromRGB(210, 215, 230),
            Visible = false,
            ZIndex = 3,
        }),
        tracer = newDrawing("Line", {
            Thickness = 1,
            Transparency = 0.45,
            Color = CONFIG.PlayerESP.BoxColor,
            Visible = false,
            ZIndex = 1,
        }),
    }
end

-- ═══════════════════════════════════════════════════════════════════════
-- ADVANCED KINEMATICS & BALLISTIC INTERCEPT SOLVER
-- ═══════════════════════════════════════════════════════════════════════
local function updateKinematics(model, primaryPart, dt)
    local pos = primaryPart.Position
    local rawVel = primaryPart.AssemblyLinearVelocity
    local now = tick()

    local state = droneTrackers[model]
    if not state then
        state = {
            pos = pos,
            vel = rawVel,
            smoothVel = rawVel,
            accel = Vector3.zero,
            lastTime = now,
            lastVel = rawVel,
        }
        droneTrackers[model] = state
        return state
    end

    local elapsed = math.clamp(now - state.lastTime, 0.001, 0.2)
    local alpha = 1 - math.exp(-elapsed / CONFIG.AimPrediction.SmoothFactor)

    local newSmooth = lerpV3(state.smoothVel, rawVel, alpha)
    local rawAccel = (newSmooth - state.lastVel) / elapsed
    local accelAlpha = 1 - math.exp(-elapsed / (CONFIG.AimPrediction.SmoothFactor * 2.2))
    local newAccel = lerpV3(state.accel, rawAccel, accelAlpha)

    if newAccel.Magnitude > 320 then
        newAccel = newAccel.Unit * 320
    end

    state.pos = pos
    state.vel = rawVel
    state.smoothVel = newSmooth
    state.lastVel = newSmooth
    state.accel = newAccel
    state.lastTime = now

    return state
end

local function projectPosition(state, t)
    return state.pos + (state.smoothVel * t) + (state.accel * (0.5 * t * t))
end

local function solveLeadIntercept(shooterOrigin, state, bulletSpeed, bulletDrop, bulletDrag)
    local shooterVel = Vector3.zero
    if CONFIG.AimPrediction.CompensateShooter then
        local char = LocalPlayer.Character
        if char and char:FindFirstChild("HumanoidRootPart") then
            shooterVel = char.HumanoidRootPart.AssemblyLinearVelocity
        end
    end

    local targetPos = state.pos
    local initialDist = (targetPos - shooterOrigin).Magnitude
    local timeOfFlight = initialDist / bulletSpeed
    local bestAimPos = targetPos

    for _ = 1, CONFIG.AimPrediction.IterationCount do
        local futurePos = projectPosition(state, timeOfFlight)
        local effectiveShooterOrigin = shooterOrigin + (shooterVel * timeOfFlight)
        local deltaVector = futurePos - effectiveShooterOrigin
        local currentDist = deltaVector.Magnitude

        local effectiveSpeed = bulletSpeed
        if bulletDrag and bulletDrag > 0 then
            effectiveSpeed = bulletSpeed / (1 + bulletDrag * currentDist)
        end

        local verticalDrop = 0.5 * bulletDrop * (timeOfFlight * timeOfFlight)
        local compensatedPos = futurePos + Vector3.new(0, verticalDrop, 0)

        local travelDist = (compensatedPos - effectiveShooterOrigin).Magnitude
        local updatedTime = travelDist / effectiveSpeed

        if math.abs(updatedTime - timeOfFlight) < 0.0003 then
            bestAimPos = compensatedPos
            timeOfFlight = updatedTime
            break
        end

        timeOfFlight = updatedTime
        bestAimPos = compensatedPos
    end

    if timeOfFlight > CONFIG.AimPrediction.MaxPredictTime then
        return nil, nil
    end

    return bestAimPos, timeOfFlight
end

-- ═══════════════════════════════════════════════════════════════════════
-- TARGET SELECTION
-- ═══════════════════════════════════════════════════════════════════════
local function findBestDroneTarget()
    local screenCenter = Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y * 0.5)
    local bestDist = CONFIG.AimPrediction.AimAssistFOV
    local bestModel = nil
    local bestState = nil

    for model, state in pairs(droneTrackers) do
        if model.Parent then
            local isCrashed = model:GetAttribute("Crashed") or model:GetAttribute("Falling")
            local hp = model:GetAttribute("HP")
            if hp and hp <= 0 then isCrashed = true end

            if not isCrashed then
                local isEnemy = true
                local droneTeam = model:GetAttribute("TRV_Team")
                local operatorId = model:GetAttribute("OperatorUserId")

                if droneTeam then
                    local teamObj = Teams:FindFirstChild(droneTeam)
                    if teamObj and not isEnemyTeam(teamObj) then
                        isEnemy = false
                    end
                elseif operatorId then
                    local pilot = resolvePlayerByUserId(operatorId)
                    if pilot and not isEnemyPlayer(pilot) then
                        isEnemy = false
                    end
                end

                if isEnemy then
                    local screenPos, onScreen = worldToScreen(state.pos)
                    if onScreen then
                        local dist = (screenPos - screenCenter).Magnitude
                        if dist < bestDist then
                            bestDist = dist
                            bestModel = model
                            bestState = state
                        end
                    end
                end
            end
        end
    end

    return bestModel, bestState
end

local function getTracerOrigin(originType)
    if originType == "Bottom" then
        return Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y)
    elseif originType == "Mouse" then
        local mp = UserInputService:GetMouseLocation()
        return Vector2.new(mp.X, mp.Y)
    else
        return Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y * 0.5)
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- DRONE ESP RENDER PASS
-- ═══════════════════════════════════════════════════════════════════════
local function updateDroneESP(dt, camPos)
    if not CONFIG.DroneESP.Enabled then
        for _, drawings in pairs(droneDrawings) do
            for _, d in pairs(drawings) do
                pcall(function() d.Visible = false end)
            end
        end
        return
    end

    local activeDrones = {}
    local taggedDrones = CollectionService:GetTagged("UAVDrone")

    local candidateDrones = {}
    for _, drone in ipairs(taggedDrones) do
        candidateDrones[drone] = true
    end
    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("Model") and child:GetAttribute("UAV") then
            candidateDrones[child] = true
        end
    end

    for drone in pairs(candidateDrones) do
        if not drone.Parent then continue end

        local base = drone:FindFirstChild("Base") or drone.PrimaryPart or drone:FindFirstChildWhichIsA("BasePart")
        if not base then continue end

        local isCrashed = drone:GetAttribute("Crashed") or drone:GetAttribute("Falling")
        local hp = drone:GetAttribute("HP")
        if hp and hp <= 0 then isCrashed = true end

        if isCrashed and not CONFIG.DroneESP.ShowCrashed then
            if droneDrawings[drone] then
                for _, drw in pairs(droneDrawings[drone]) do
                    pcall(function() drw.Visible = false end)
                end
            end
            continue
        end

        -- Fast Squared Distance Check (Zero-Lag Pre-Filtering)
        local basePos = base.Position
        local distSq = getDistanceSq(camPos, basePos)
        if distSq > CONFIG.DroneESP.MaxDistSq then
            if droneDrawings[drone] then
                for _, drw in pairs(droneDrawings[drone]) do
                    pcall(function() drw.Visible = false end)
                end
            end
            continue
        end

        activeDrones[drone] = true
        local state = updateKinematics(drone, base, dt)

        if not droneDrawings[drone] then
            droneDrawings[drone] = createDroneDrawing()
        end

        local d = droneDrawings[drone]
        local dist = math.sqrt(distSq)

        -- On-Screen Bounding Box
        local cf = drone:GetBoundingBox()
        local extents = drone:GetExtentsSize()
        local half = extents * 0.5

        local corners = {
            cf * Vector3.new( half.X,  half.Y,  half.Z),
            cf * Vector3.new(-half.X,  half.Y,  half.Z),
            cf * Vector3.new( half.X, -half.Y,  half.Z),
            cf * Vector3.new(-half.X, -half.Y,  half.Z),
            cf * Vector3.new( half.X,  half.Y, -half.Z),
            cf * Vector3.new(-half.X,  half.Y, -half.Z),
            cf * Vector3.new( half.X, -half.Y, -half.Z),
            cf * Vector3.new(-half.X, -half.Y, -half.Z),
        }

        local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
        local allOnScreen = true

        for _, corner in ipairs(corners) do
            local sp, onScreen, depth = worldToScreen(corner)
            if not onScreen or depth < 0 then
                allOnScreen = false
                break
            end
            minX = math.min(minX, sp.X)
            minY = math.min(minY, sp.Y)
            maxX = math.max(maxX, sp.X)
            maxY = math.max(maxY, sp.Y)
        end

        if not allOnScreen then
            for _, drw in pairs(d) do
                pcall(function() drw.Visible = false end)
            end
            continue
        end

        local isJammed = drone:GetAttribute("CommsLoss") == true
        local droneTeam = drone:GetAttribute("TRV_Team")
        local operatorId = drone:GetAttribute("OperatorUserId")
        local isFriendly = false
        local pilotPlayer = nil

        if operatorId then
            pilotPlayer = resolvePlayerByUserId(operatorId)
            if pilotPlayer and not isEnemyPlayer(pilotPlayer) then
                isFriendly = true
            end
        elseif droneTeam then
            local teamObj = Teams:FindFirstChild(droneTeam)
            if teamObj and not isEnemyTeam(teamObj) then
                isFriendly = true
            end
        end

        local boxColor
        if isCrashed then
            boxColor = CONFIG.DroneESP.CrashedColor
        elseif isJammed then
            boxColor = CONFIG.DroneESP.JammedColor
        elseif isFriendly then
            boxColor = CONFIG.DroneESP.FriendlyColor
        else
            boxColor = CONFIG.DroneESP.BoxColor
        end

        local pad = math.max(4, (maxX - minX) * 0.08)
        minX = minX - pad; minY = minY - pad; maxX = maxX + pad; maxY = maxY + pad
        local w = maxX - minX
        local h = maxY - minY
        local cx = minX + w * 0.5

        -- Box
        d.box.Size = Vector2.new(w, h)
        d.box.Position = Vector2.new(minX, minY)
        d.box.Color = boxColor
        d.box.Visible = true

        d.boxFill.Size = Vector2.new(w, h)
        d.boxFill.Position = Vector2.new(minX, minY)
        d.boxFill.Color = boxColor
        d.boxFill.Visible = true

        -- Name & Type Tag
        local topY = minY - 4
        if CONFIG.DroneESP.ShowName then
            local droneType = drone:GetAttribute("droneType") or "UAV"
            local labelPrefix = isCrashed and "[WRECK]" or ("[" .. string.upper(droneType) .. "]")
            d.nameTag.Text = string.format("%s %s", labelPrefix, drone.Name)
            d.nameTag.Position = Vector2.new(cx, topY - 16)
            d.nameTag.Color = boxColor
            d.nameTag.Visible = true
            topY = topY - 16
        else
            d.nameTag.Visible = false
        end

        -- Pilot Tag
        if CONFIG.DroneESP.ShowPilot and operatorId and not isCrashed then
            local pilotName = pilotPlayer and pilotPlayer.DisplayName or ("ID:" .. tostring(operatorId))
            d.pilotTag.Text = "Pilot: " .. pilotName
            d.pilotTag.Position = Vector2.new(cx, topY - 14)
            d.pilotTag.Visible = true
        else
            d.pilotTag.Visible = false
        end

        -- Bottom Info
        local botY = maxY + 3
        if CONFIG.DroneESP.ShowDistance then
            d.distTag.Text = string.format("%.0f st", dist)
            d.distTag.Position = Vector2.new(cx, botY)
            d.distTag.Visible = true
            botY = botY + 14
        else
            d.distTag.Visible = false
        end

        if CONFIG.DroneESP.ShowVelocity and state and not isCrashed then
            local spd = math.floor(state.smoothVel.Magnitude + 0.5)
            d.velTag.Text = string.format("%d st/s", spd)
            d.velTag.Position = Vector2.new(cx, botY)
            d.velTag.Visible = true
        else
            d.velTag.Visible = false
        end

        -- Health Bar
        local maxHp = drone:GetAttribute("MaxHP") or 100
        if CONFIG.DroneESP.ShowHealth and hp and maxHp > 0 and not isCrashed then
            local ratio = math.clamp(hp / maxHp, 0, 1)
            local barX = minX - 6
            d.healthBarBG.From = Vector2.new(barX, minY)
            d.healthBarBG.To = Vector2.new(barX, maxY)
            d.healthBarBG.Visible = true

            d.healthBar.From = Vector2.new(barX, maxY - (h * ratio))
            d.healthBar.To = Vector2.new(barX, maxY)
            d.healthBar.Color = Color3.fromRGB(
                math.floor(255 * (1 - ratio)),
                math.floor(255 * ratio),
                40
            )
            d.healthBar.Visible = true
        else
            d.healthBar.Visible = false
            d.healthBarBG.Visible = false
        end

        -- Tracer
        if CONFIG.DroneESP.ShowTracer then
            d.tracer.From = getTracerOrigin(CONFIG.DroneESP.TracerOrigin)
            d.tracer.To = Vector2.new(cx, maxY)
            d.tracer.Color = boxColor
            d.tracer.Visible = true
        else
            d.tracer.Visible = false
        end

        -- Ballistic Lead Prediction Visualizer
        if CONFIG.AimPrediction.Enabled and CONFIG.AimPrediction.ShowPrediction and not isFriendly and not isCrashed then
            local shooterPos = camPos
            local char = LocalPlayer.Character
            if char and char:FindFirstChild("HumanoidRootPart") then
                shooterPos = char.HumanoidRootPart.Position
            end

            local predPos, predTime = solveLeadIntercept(shooterPos, state, currentBulletSpeed, currentBulletDrop, currentBulletDrag)
            if predPos and predTime then
                local predScreen, predOn = worldToScreen(predPos)
                local isLocked = aimLocked and (aimTarget == drone)

                if predOn then
                    local color = isLocked and CONFIG.AimPrediction.LockedColor or CONFIG.AimPrediction.PredictionColor
                    d.predCircle.Position = predScreen
                    d.predCircle.Color = color
                    d.predCircle.Radius = math.clamp(900 / dist, 5, 22)
                    d.predCircle.Visible = true

                    d.predDot.Position = predScreen
                    d.predDot.Color = color
                    d.predDot.Visible = true

                    d.predLine.From = Vector2.new(cx, minY + h * 0.5)
                    d.predLine.To = predScreen
                    d.predLine.Color = color
                    d.predLine.Visible = true
                else
                    d.predCircle.Visible = false
                    d.predDot.Visible = false
                    d.predLine.Visible = false
                end
            else
                d.predCircle.Visible = false
                d.predDot.Visible = false
                d.predLine.Visible = false
            end
        else
            d.predCircle.Visible = false
            d.predDot.Visible = false
            d.predLine.Visible = false
        end
    end

    for drone, drawings in pairs(droneDrawings) do
        if not activeDrones[drone] then
            destroyDrawings(drawings)
            droneDrawings[drone] = nil
            droneTrackers[drone] = nil
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- PLAYER ESP RENDER PASS
-- ═══════════════════════════════════════════════════════════════════════
local function updatePlayerESP(camPos)
    if not CONFIG.PlayerESP.Enabled then
        for _, drawings in pairs(playerDrawings) do
            for _, d in pairs(drawings) do
                pcall(function() d.Visible = false end)
            end
        end
        for player, hl in pairs(playerHighlights) do
            pcall(function() hl:Destroy() end)
            playerHighlights[player] = nil
        end
        return
    end

    local activePlayers = {}

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer then continue end

        local isEnemy = isEnemyPlayer(player)
        if CONFIG.PlayerESP.EnemiesOnly and not isEnemy then
            if playerDrawings[player] then
                for _, d in pairs(playerDrawings[player]) do
                    pcall(function() d.Visible = false end)
                end
            end
            if playerHighlights[player] then
                pcall(function() playerHighlights[player]:Destroy() end)
                playerHighlights[player] = nil
            end
            continue
        end

        local char = player.Character
        if not char then continue end

        local hrp = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then continue end

        local hrpPos = hrp.Position
        local distSq = getDistanceSq(camPos, hrpPos)
        if distSq > CONFIG.PlayerESP.MaxDistSq then
            if playerDrawings[player] then
                for _, d in pairs(playerDrawings[player]) do
                    pcall(function() d.Visible = false end)
                end
            end
            if playerHighlights[player] then
                pcall(function() playerHighlights[player]:Destroy() end)
                playerHighlights[player] = nil
            end
            continue
        end

        activePlayers[player] = true
        if not playerDrawings[player] then
            playerDrawings[player] = createPlayerDrawing()
        end

        local d = playerDrawings[player]
        local rootCF = hrp.CFrame
        local charHeight = 5.5

        local topPos = rootCF.Position + Vector3.new(0, charHeight * 0.5 + 0.6, 0)
        local botPos = rootCF.Position - Vector3.new(0, charHeight * 0.5, 0)

        local topScreen, topOn = worldToScreen(topPos)
        local botScreen, botOn = worldToScreen(botPos)

        if not topOn or not botOn then
            for _, drw in pairs(d) do
                pcall(function() drw.Visible = false end)
            end
            continue
        end

        local h = math.abs(botScreen.Y - topScreen.Y)
        local w = h * 0.55
        local cx = (topScreen.X + botScreen.X) * 0.5
        local minX = cx - w * 0.5
        local minY = topScreen.Y
        local maxY = botScreen.Y

        local color = isEnemy and CONFIG.PlayerESP.BoxColor or CONFIG.PlayerESP.FriendlyColor

        d.box.Size = Vector2.new(w, h)
        d.box.Position = Vector2.new(minX, minY)
        d.box.Color = color
        d.box.Visible = true

        d.boxFill.Size = Vector2.new(w, h)
        d.boxFill.Position = Vector2.new(minX, minY)
        d.boxFill.Color = color
        d.boxFill.Visible = true

        if CONFIG.PlayerESP.ShowName then
            local teamName = player.Team and player.Team.Name or "No Team"
            d.nameTag.Text = string.format("[%s] %s", teamName, player.DisplayName)
            d.nameTag.Position = Vector2.new(cx, minY - 16)
            d.nameTag.Color = isEnemy and CONFIG.PlayerESP.NameColor or Color3.fromRGB(150, 220, 255)
            d.nameTag.Visible = true
        else
            d.nameTag.Visible = false
        end

        local botY = maxY + 3
        if CONFIG.PlayerESP.ShowDistance then
            d.distTag.Text = string.format("%.0f st", math.sqrt(distSq))
            d.distTag.Position = Vector2.new(cx, botY)
            d.distTag.Visible = true
            botY = botY + 14
        else
            d.distTag.Visible = false
        end

        if CONFIG.PlayerESP.ShowWeapon then
            local tool = char:FindFirstChildOfClass("Tool")
            if tool then
                d.weaponTag.Text = tool.Name
                d.weaponTag.Position = Vector2.new(cx, botY)
                d.weaponTag.Visible = true
            else
                d.weaponTag.Visible = false
            end
        else
            d.weaponTag.Visible = false
        end

        if CONFIG.PlayerESP.ShowHealth then
            local ratio = math.clamp(hum.Health / hum.MaxHealth, 0, 1)
            local barX = minX - 6
            d.healthBarBG.From = Vector2.new(barX, minY)
            d.healthBarBG.To = Vector2.new(barX, maxY)
            d.healthBarBG.Visible = true

            d.healthBar.From = Vector2.new(barX, maxY - (h * ratio))
            d.healthBar.To = Vector2.new(barX, maxY)
            d.healthBar.Color = Color3.fromRGB(
                math.floor(255 * (1 - ratio)),
                math.floor(255 * ratio),
                40
            )
            d.healthBar.Visible = true
        else
            d.healthBar.Visible = false
            d.healthBarBG.Visible = false
        end

        if CONFIG.PlayerESP.ShowTracer then
            d.tracer.From = getTracerOrigin("Bottom")
            d.tracer.To = Vector2.new(cx, maxY)
            d.tracer.Color = color
            d.tracer.Visible = true
        else
            d.tracer.Visible = false
        end

        if not playerHighlights[player] then
            local hl = Instance.new("Highlight")
            hl.Name = "SKYFIRE_ESP_HL"
            hl.FillTransparency = CONFIG.PlayerESP.HighlightFill
            hl.OutlineColor = color
            hl.FillColor = color
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Adornee = char
            hl.Parent = char
            playerHighlights[player] = hl
        else
            playerHighlights[player].OutlineColor = color
            playerHighlights[player].FillColor = color
        end
    end

    for player, drawings in pairs(playerDrawings) do
        if not activePlayers[player] then
            destroyDrawings(drawings)
            playerDrawings[player] = nil
        end
    end
    for player, hl in pairs(playerHighlights) do
        if not activePlayers[player] then
            pcall(function() hl:Destroy() end)
            playerHighlights[player] = nil
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- AIM ASSIST: UNIVERSAL DISPATCHER (TURRET SCOPE & INFANTRY)
-- ═══════════════════════════════════════════════════════════════════════
local function updateAimAssist()
    -- Sync FOV Circle
    if CONFIG.AimPrediction.ShowFOVCircle and CONFIG.AimPrediction.AimAssist then
        local mousePos = UserInputService:GetMouseLocation()
        fovCircle.Position = mousePos
        fovCircle.Radius = CONFIG.AimPrediction.AimAssistFOV
        fovCircle.Visible = true
    else
        fovCircle.Visible = false
    end

    -- Continuous key state check: unblocks key when gameProcessed is swallowed by turret scope
    if CONFIG.AimPrediction.AimAssist then
        local keyHeld = UserInputService:IsKeyDown(CONFIG.AimPrediction.AimKey)
        if keyHeld and not aimLocked then
            local model, _ = findBestDroneTarget()
            if model then
                aimTarget = model
                aimLocked = true
            end
        elseif not keyHeld and aimLocked then
            aimLocked = false
            aimTarget = nil
        end
    else
        aimLocked = false
        aimTarget = nil
    end

    if not aimLocked or not aimTarget then return end

    local state = droneTrackers[aimTarget]
    if not state or not aimTarget.Parent or aimTarget:GetAttribute("Crashed") or (aimTarget:GetAttribute("HP") and aimTarget:GetAttribute("HP") <= 0) then
        aimLocked = false
        aimTarget = nil
        return
    end

    local shooterPos = Camera.CFrame.Position
    local char = LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        shooterPos = char.HumanoidRootPart.Position
    end

    local predPos, _ = solveLeadIntercept(shooterPos, state, currentBulletSpeed, currentBulletDrop, currentBulletDrag)
    if predPos then
        -- Check if seated in a turret (ZU-23-2)
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local isSeatedTurret = hum and hum.SeatPart ~= nil

        -- If mousemoverel is supported by executor, use direct mouse delta (vital for Turret aim!)
        local predScreen, onScreen = worldToScreen(predPos)
        if onScreen and mousemoverel and isSeatedTurret then
            local center = Vector2.new(Camera.ViewportSize.X * 0.5, Camera.ViewportSize.Y * 0.5)
            local deltaX = (predScreen.X - center.X) * CONFIG.AimPrediction.AimAssistSmooth
            local deltaY = (predScreen.Y - center.Y) * CONFIG.AimPrediction.AimAssistSmooth
            mousemoverel(deltaX, deltaY)
        else
            -- Direct camera smooth lerp for infantry and general aiming
            local targetCF = CFrame.lookAt(Camera.CFrame.Position, predPos)
            Camera.CFrame = Camera.CFrame:Lerp(targetCF, CONFIG.AimPrediction.AimAssistSmooth)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- UNCONDITIONAL INPUT HANDLING (NO GAME-PROCESSED BLOCK)
-- ═══════════════════════════════════════════════════════════════════════
local function setupInput()
    table.insert(connections, UserInputService.InputBegan:Connect(function(input)
        -- Process AimKey UNCONDITIONALLY (bypasses gameProcessed when scoped in ZU-23-2)
        if input.KeyCode == CONFIG.AimPrediction.AimKey then
            if CONFIG.AimPrediction.AimAssist then
                local model, _ = findBestDroneTarget()
                if model then
                    aimTarget = model
                    aimLocked = true
                else
                    aimTarget = nil
                    aimLocked = false
                end
            end
        end
    end))

    table.insert(connections, UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode == CONFIG.AimPrediction.AimKey then
            aimLocked = false
            aimTarget = nil
        end
    end))
end

-- ═══════════════════════════════════════════════════════════════════════
-- ZERO-LAG ASYNCHRONOUS RAYFIELD UI INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════
local RayfieldInstance = nil
local telemetryParagraph = nil

local function loadRayfieldLibrary()
    if getgenv and getgenv().Rayfield then
        return getgenv().Rayfield
    end

    local success, lib = pcall(function()
        return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
    end)
    if success and lib then return lib end

    local success2, lib2 = pcall(function()
        return loadstring(game:HttpGet("https://raw.githubusercontent.com/shlexware/Rayfield/main/source.lua"))()
    end)
    if success2 and lib2 then return lib2 end

    if readfile then
        local success3, lib3 = pcall(function()
            return loadstring(readfile("Rayfield-main/source.lua"))()
        end)
        if success3 and lib3 then return lib3 end
    end

    return nil
end

local function initRayfieldUIAsync()
    task.defer(function()
        local Rayfield = loadRayfieldLibrary()
        if not Rayfield then
            warn("[SKYFIRE ENHANCED] Rayfield UI skipped (headless mode active).")
            return
        end

        RayfieldInstance = Rayfield

        local Window = Rayfield:CreateWindow({
            Name = "SKYFIRE ENHANCED v3.6",
            Icon = 0,
            LoadingTitle = "SKYFIRE ENHANCED",
            LoadingSubtitle = "by Qusa  ·  Combat Suite",
            Theme = "Default",

            DisableRayfieldPrompts = true,
            DisableBuildWarnings = true,

            ConfigurationSaving = {
                Enabled = false,
                FolderName = nil,
                FileName = "SkyfireSettings"
            },

            KeySystem = false, -- NO KEY SYSTEM
        })

        -- ═══ TAB 1: DRONE ESP ═══
        local DroneTab = Window:CreateTab("🛸 Drone ESP", 4483362458)
        DroneTab:CreateSection("ESP Visibility & Filters")

        DroneTab:CreateToggle({
            Name = "Enable Drone ESP",
            CurrentValue = CONFIG.DroneESP.Enabled,
            Flag = "DroneESP_Enabled",
            Callback = function(Value) CONFIG.DroneESP.Enabled = Value end,
        })

        DroneTab:CreateToggle({
            Name = "Show Wrecks & Falling Drones",
            CurrentValue = CONFIG.DroneESP.ShowCrashed,
            Flag = "DroneESP_ShowWrecks",
            Callback = function(Value) CONFIG.DroneESP.ShowCrashed = Value end,
        })

        DroneTab:CreateSlider({
            Name = "Drone Max Distance",
            Range = {500, 15000},
            Increment = 100,
            Suffix = " studs",
            CurrentValue = CONFIG.DroneESP.MaxDistance,
            Flag = "DroneESP_MaxDist",
            Callback = function(Value)
                CONFIG.DroneESP.MaxDistance = Value
                CONFIG.DroneESP.MaxDistSq = Value * Value
            end,
        })

        DroneTab:CreateSection("Drone Visuals")

        DroneTab:CreateToggle({
            Name = "Show Tracers",
            CurrentValue = CONFIG.DroneESP.ShowTracer,
            Flag = "DroneESP_Tracers",
            Callback = function(Value) CONFIG.DroneESP.ShowTracer = Value end,
        })

        DroneTab:CreateDropdown({
            Name = "Tracer Origin",
            Options = {"Bottom", "Center", "Mouse"},
            CurrentOption = {"Bottom"},
            MultipleOptions = false,
            Flag = "DroneESP_TracerOrigin",
            Callback = function(Option)
                local sel = type(Option) == "table" and Option[1] or Option
                CONFIG.DroneESP.TracerOrigin = sel
            end,
        })

        DroneTab:CreateToggle({
            Name = "Show Pilot Username",
            CurrentValue = CONFIG.DroneESP.ShowPilot,
            Flag = "DroneESP_ShowPilot",
            Callback = function(Value) CONFIG.DroneESP.ShowPilot = Value end,
        })

        DroneTab:CreateToggle({
            Name = "Show Kinematic Velocity",
            CurrentValue = CONFIG.DroneESP.ShowVelocity,
            Flag = "DroneESP_ShowVelocity",
            Callback = function(Value) CONFIG.DroneESP.ShowVelocity = Value end,
        })

        DroneTab:CreateToggle({
            Name = "Show Health Bars",
            CurrentValue = CONFIG.DroneESP.ShowHealth,
            Flag = "DroneESP_ShowHealth",
            Callback = function(Value) CONFIG.DroneESP.ShowHealth = Value end,
        })

        -- ═══ TAB 2: AIMBOT & BALLISTICS ═══
        local AimTab = Window:CreateTab("🎯 Aimbot & Lead", 4483362458)
        AimTab:CreateSection("Ballistics Lead Calculation")

        AimTab:CreateToggle({
            Name = "Enable Aim Prediction",
            CurrentValue = CONFIG.AimPrediction.Enabled,
            Flag = "Aim_Enabled",
            Callback = function(Value) CONFIG.AimPrediction.Enabled = Value end,
        })

        AimTab:CreateToggle({
            Name = "Show Predicted Lead Point",
            CurrentValue = CONFIG.AimPrediction.ShowPrediction,
            Flag = "Aim_ShowPoint",
            Callback = function(Value) CONFIG.AimPrediction.ShowPrediction = Value end,
        })

        AimTab:CreateToggle({
            Name = "Auto-Detect Weapon / Turret Ballistics",
            CurrentValue = CONFIG.AimPrediction.AutoDetectWeapon,
            Flag = "Aim_AutoDetect",
            Callback = function(Value) CONFIG.AimPrediction.AutoDetectWeapon = Value end,
        })

        AimTab:CreateToggle({
            Name = "Compensate Shooter Velocity",
            CurrentValue = CONFIG.AimPrediction.CompensateShooter,
            Flag = "Aim_CompShooter",
            Callback = function(Value) CONFIG.AimPrediction.CompensateShooter = Value end,
        })

        AimTab:CreateSection("Aim Assist Lock & FOV")

        AimTab:CreateToggle({
            Name = "Enable Aim Assist Lock (Hold Key)",
            CurrentValue = CONFIG.AimPrediction.AimAssist,
            Flag = "Aim_Assist",
            Callback = function(Value) CONFIG.AimPrediction.AimAssist = Value end,
        })

        AimTab:CreateToggle({
            Name = "Show FOV Circle",
            CurrentValue = CONFIG.AimPrediction.ShowFOVCircle,
            Flag = "Aim_ShowFOV",
            Callback = function(Value) CONFIG.AimPrediction.ShowFOVCircle = Value end,
        })

        AimTab:CreateSlider({
            Name = "Aim Assist FOV Radius",
            Range = {30, 500},
            Increment = 5,
            Suffix = " px",
            CurrentValue = CONFIG.AimPrediction.AimAssistFOV,
            Flag = "Aim_FOVRadius",
            Callback = function(Value)
                CONFIG.AimPrediction.AimAssistFOV = Value
                fovCircle.Radius = Value
            end,
        })

        AimTab:CreateSlider({
            Name = "Aim Assist Smoothing",
            Range = {0.05, 1.0},
            Increment = 0.05,
            Suffix = " lerp",
            CurrentValue = CONFIG.AimPrediction.AimAssistSmooth,
            Flag = "Aim_Smoothing",
            Callback = function(Value) CONFIG.AimPrediction.AimAssistSmooth = Value end,
        })

        AimTab:CreateKeybind({
            Name = "Aim Lock Key",
            CurrentKeybind = "E",
            HoldToInteract = false,
            Flag = "Aim_Keybind",
            Callback = function(Keybind)
                local keyEnum = Enum.KeyCode[Keybind]
                if keyEnum then
                    CONFIG.AimPrediction.AimKey = keyEnum
                end
            end,
        })

        -- ═══ TAB 3: PLAYER ESP ═══
        local PlayerTab = Window:CreateTab("👥 Soldier ESP", 4483362458)
        PlayerTab:CreateSection("Soldier ESP Settings")

        PlayerTab:CreateToggle({
            Name = "Enable Soldier ESP",
            CurrentValue = CONFIG.PlayerESP.Enabled,
            Flag = "Player_Enabled",
            Callback = function(Value) CONFIG.PlayerESP.Enabled = Value end,
        })

        PlayerTab:CreateToggle({
            Name = "Enemy Side Only (Noobian vs Dummian)",
            CurrentValue = CONFIG.PlayerESP.EnemiesOnly,
            Flag = "Player_EnemiesOnly",
            Callback = function(Value) CONFIG.PlayerESP.EnemiesOnly = Value end,
        })

        PlayerTab:CreateSlider({
            Name = "Player Max Distance",
            Range = {500, 8000},
            Increment = 100,
            Suffix = " studs",
            CurrentValue = CONFIG.PlayerESP.MaxDistance,
            Flag = "Player_MaxDist",
            Callback = function(Value)
                CONFIG.PlayerESP.MaxDistance = Value
                CONFIG.PlayerESP.MaxDistSq = Value * Value
            end,
        })

        PlayerTab:CreateToggle({
            Name = "Show Held Weapon",
            CurrentValue = CONFIG.PlayerESP.ShowWeapon,
            Flag = "Player_ShowWeapon",
            Callback = function(Value) CONFIG.PlayerESP.ShowWeapon = Value end,
        })

        PlayerTab:CreateToggle({
            Name = "Show Health Bars",
            CurrentValue = CONFIG.PlayerESP.ShowHealth,
            Flag = "Player_ShowHealth",
            Callback = function(Value) CONFIG.PlayerESP.ShowHealth = Value end,
        })

        PlayerTab:CreateToggle({
            Name = "Show Tracers",
            CurrentValue = CONFIG.PlayerESP.ShowTracer,
            Flag = "Player_ShowTracer",
            Callback = function(Value) CONFIG.PlayerESP.ShowTracer = Value end,
        })

        -- ═══ TAB 4: TELEMETRY & INFO ═══
        local InfoTab = Window:CreateTab("📊 Telemetry", 4483362458)
        InfoTab:CreateSection("Real-Time Ballistics Telemetry")

        telemetryParagraph = InfoTab:CreateParagraph({
            Title = "Active Weapon Stats",
            Content = "Initializing TRV telemetry...",
        })

        InfoTab:CreateButton({
            Name = "Unload / Clean Script",
            Callback = function()
                if _G.SKYFIRE_ENHANCED_CLEANUP then
                    _G.SKYFIRE_ENHANCED_CLEANUP()
                end
            end,
        })
    end)
end

-- ═══════════════════════════════════════════════════════════════════════
-- MASTER RENDER STEP
-- ═══════════════════════════════════════════════════════════════════════
local lastTelemUpdate = 0

local function onRenderStep(dt)
    Camera = workspace.CurrentCamera
    if not Camera then return end

    local camPos = Camera.CFrame.Position

    -- Fast cached weapon check
    updateActiveWeaponBallistics()

    -- Throttle Rayfield paragraph updates to 2Hz to completely eliminate UI lag
    local now = tick()
    if telemetryParagraph and (now - lastTelemUpdate > 0.5) then
        lastTelemUpdate = now
        pcall(function()
            telemetryParagraph:Set({
                Title = "Active Weapon: " .. currentWeaponName,
                Content = string.format("Muzzle Velocity: %.0f studs/s\nGravity Drop: %.2f studs/s²\nAir Drag: %.5f\nAim Target: %s",
                    currentBulletSpeed,
                    currentBulletDrop,
                    currentBulletDrag,
                    aimTarget and aimTarget.Name or "None"
                )
            })
        end)
    end

    -- Fast spatial passes
    updateDroneESP(dt, camPos)
    updatePlayerESP(camPos)
    updateAimAssist()
end

-- ═══════════════════════════════════════════════════════════════════════
-- CLEANUP
-- ═══════════════════════════════════════════════════════════════════════
local function cleanup()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}

    for _, drawings in pairs(droneDrawings) do
        destroyDrawings(drawings)
    end
    droneDrawings = {}
    droneTrackers = {}

    for _, drawings in pairs(playerDrawings) do
        destroyDrawings(drawings)
    end
    playerDrawings = {}

    for _, hl in pairs(playerHighlights) do
        pcall(function() hl:Destroy() end)
    end
    playerHighlights = {}

    pcall(function() fovCircle:Remove() end)
    pcall(function() fovCircle:Destroy() end)

    if RayfieldInstance and RayfieldInstance.Destroy then
        pcall(function() RayfieldInstance:Destroy() end)
        RayfieldInstance = nil
    end
end

-- ═══════════════════════════════════════════════════════════════════════
-- BOOTSTRAPPER
-- ═══════════════════════════════════════════════════════════════════════
if _G.SKYFIRE_ENHANCED_CLEANUP then
    pcall(_G.SKYFIRE_ENHANCED_CLEANUP)
end
_G.SKYFIRE_ENHANCED_CLEANUP = cleanup

setupInput()
initRayfieldUIAsync()

table.insert(connections, RunService.RenderStepped:Connect(onRenderStep))

table.insert(connections, Players.PlayerRemoving:Connect(function(player)
    if playerDrawings[player] then
        destroyDrawings(playerDrawings[player])
        playerDrawings[player] = nil
    end
    if playerHighlights[player] then
        pcall(function() playerHighlights[player]:Destroy() end)
        playerHighlights[player] = nil
    end
end))

print("═══════════════════════════════════════════════════════════════════")
print("  ⚡ SKYFIRE ENHANCED v3.6 (Turret Scope Fix & Async Boot) Ready!")
print("  [E] Hold Aim Lock  |  Rayfield Interface Loaded")
print("═══════════════════════════════════════════════════════════════════")
