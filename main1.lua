--[[
    ╔══════════════════════════════════════════════════════════╗
    ║           SKYFIRE ENHANCED  ·  v2.0                     ║
    ║   Drone ESP · Aim Prediction · DRG Team ESP · GUI       ║
    ╚══════════════════════════════════════════════════════════╝
    
    Features:
    • Drone ESP — boxes, name tags, distance, velocity, health bars
    • Advanced aim prediction — iterative intercept solver with
      velocity smoothing, acceleration estimation, and bullet drop
    • DRG Team ESP — highlight all DRG/Operator (Dummian) players
    • Modern glassmorphism GUI with per-feature toggles
    • Toggle everything on/off with keybinds
]]

-- ═══════════════════════════════════════════════════════════
-- SERVICES
-- ═══════════════════════════════════════════════════════════
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local Teams              = game:GetService("Teams")
local TweenService       = game:GetService("TweenService")
local LocalPlayer        = Players.LocalPlayer
local Camera             = workspace.CurrentCamera

-- ═══════════════════════════════════════════════════════════
-- CONFIGURATION
-- ═══════════════════════════════════════════════════════════
local CONFIG = {
    -- Drone ESP
    DroneESP = {
        Enabled       = true,
        MaxDistance    = 8000,
        BoxColor      = Color3.fromRGB(255, 80, 50),
        FriendlyColor = Color3.fromRGB(80, 200, 120),
        CrashedColor  = Color3.fromRGB(120, 120, 120),
        TextSize      = 14,
        ShowVelocity  = true,
        ShowDistance   = true,
        ShowName      = true,
        ShowHealth    = true,
        ShowTracer    = true,
        TracerOrigin  = "Bottom", -- "Bottom", "Center", "Mouse"
    },
    
    -- Aim Prediction
    AimPrediction = {
        Enabled          = true,
        ShowPrediction   = true,
        PredictionColor  = Color3.fromRGB(0, 255, 200),
        LockedColor      = Color3.fromRGB(255, 50, 50),
        SmoothFactor     = 0.12,     -- velocity lerp rate (lower = smoother)
        MaxPredictTime   = 4.0,      -- max seconds to predict ahead
        BulletSpeed      = 900,      -- default bullet speed (studs/s) — adapted from weapon
        Gravity          = 196.2,    -- Roblox gravity (workspace.Gravity)
        IterationCount   = 8,        -- intercept solver iterations
        AimAssist        = false,    -- auto-snap crosshair to predicted pos
        AimAssistFOV     = 120,      -- screen-space pixel radius for lock
        AimKey           = Enum.KeyCode.E,
    },
    
    -- DRG/Enemy Team ESP
    TeamESP = {
        Enabled        = true,
        MaxDistance     = 3000,
        EnemySide      = "Dummian",  -- DRG + Operators
        BoxColor       = Color3.fromRGB(255, 60, 75),
        NameColor      = Color3.fromRGB(255, 200, 80),
        HealthBarWidth = 4,
        ShowName       = true,
        ShowDistance    = true,
        ShowHealth     = true,
        ShowWeapon     = true,
        ShowTracer     = true,
        HighlightFill  = 0.75,
        HighlightOutline = Color3.fromRGB(255, 60, 75),
    },
    
    -- GUI
    GUI = {
        ToggleKey   = Enum.KeyCode.RightShift,
        AccentColor = Color3.fromRGB(140, 80, 255),
        AccentAlt   = Color3.fromRGB(80, 200, 255),
        DarkBG      = Color3.fromRGB(18, 18, 24),
        CardBG      = Color3.fromRGB(28, 28, 38),
        TextColor   = Color3.fromRGB(230, 230, 240),
        DimText     = Color3.fromRGB(140, 140, 160),
    },
}

-- ═══════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════
local droneDrawings   = {}   -- [model] = {box, nameTag, tracer, etc.}
local droneVelocities = {}   -- [model] = {pos, vel, smoothVel, accel, lastTime}
local playerDrawings  = {}   -- [player] = {box, nameTag, etc.}
local playerHighlights = {}  -- [player] = Highlight instance
local aimTarget       = nil  -- current aimed drone entry
local aimLocked       = false
local guiVisible      = true
local connections     = {}

-- ═══════════════════════════════════════════════════════════
-- UTILITY
-- ═══════════════════════════════════════════════════════════
local function getTeamSide(team)
    if not team then return nil end
    return team:GetAttribute("TRV_Side")
end

local function isEnemy(team)
    if not team then return false end
    local mySide = getTeamSide(LocalPlayer.Team)
    local theirSide = getTeamSide(team)
    if not mySide or not theirSide then return false end
    return mySide ~= theirSide
end

local function isDRGSide(team)
    if not team then return false end
    local side = getTeamSide(team)
    return side == CONFIG.TeamESP.EnemySide
end

local function worldToScreen(pos)
    local screenPos, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen, screenPos.Z
end

local function distanceTo(pos)
    return (Camera.CFrame.Position - pos).Magnitude
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function lerpV3(a, b, t)
    return a:Lerp(b, t)
end

-- ═══════════════════════════════════════════════════════════
-- DRAWING LIBRARY (uses Roblox Drawing API)
-- ═══════════════════════════════════════════════════════════
local function newDrawing(class, props)
    local d = Drawing.new(class)
    for k, v in pairs(props or {}) do
        d[k] = v
    end
    return d
end

local function destroyDrawings(tbl)
    for _, d in pairs(tbl) do
        if typeof(d) == "table" then
            destroyDrawings(d)
        elseif d and typeof(d) ~= "string" and typeof(d) ~= "number" and typeof(d) ~= "boolean" then
            pcall(function() d:Remove() end)
            pcall(function() d:Destroy() end)
        end
    end
end

-- ═══════════════════════════════════════════════════════════
-- DRONE ESP DRAWINGS
-- ═══════════════════════════════════════════════════════════
local function createDroneDrawing()
    return {
        box = newDrawing("Square", {
            Thickness = 1.5,
            Filled = false,
            Transparency = 0.85,
            Color = CONFIG.DroneESP.BoxColor,
            Visible = false,
            ZIndex = 2,
        }),
        boxFill = newDrawing("Square", {
            Thickness = 1,
            Filled = true,
            Transparency = 0.12,
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
        distTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = CONFIG.GUI.DimText,
            Visible = false,
            ZIndex = 3,
        }),
        velTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = Color3.fromRGB(150, 220, 255),
            Visible = false,
            ZIndex = 3,
        }),
        healthBar = newDrawing("Line", {
            Thickness = 3,
            Color = Color3.fromRGB(0, 255, 100),
            Visible = false,
            ZIndex = 3,
        }),
        healthBarBG = newDrawing("Line", {
            Thickness = 3,
            Color = Color3.fromRGB(50, 50, 50),
            Visible = false,
            ZIndex = 2,
        }),
        tracer = newDrawing("Line", {
            Thickness = 1,
            Transparency = 0.5,
            Color = CONFIG.DroneESP.BoxColor,
            Visible = false,
            ZIndex = 1,
        }),
        predCircle = newDrawing("Circle", {
            Thickness = 2,
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
            Thickness = 1,
            Transparency = 0.6,
            Color = CONFIG.AimPrediction.PredictionColor,
            Visible = false,
            ZIndex = 3,
        }),
    }
end

-- ═══════════════════════════════════════════════════════════
-- PLAYER ESP DRAWINGS
-- ═══════════════════════════════════════════════════════════
local function createPlayerDrawing()
    return {
        box = newDrawing("Square", {
            Thickness = 1.5,
            Filled = false,
            Transparency = 0.85,
            Color = CONFIG.TeamESP.BoxColor,
            Visible = false,
            ZIndex = 2,
        }),
        boxFill = newDrawing("Square", {
            Thickness = 1,
            Filled = true,
            Transparency = 0.08,
            Color = CONFIG.TeamESP.BoxColor,
            Visible = false,
            ZIndex = 1,
        }),
        nameTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize,
            Center = true,
            Outline = true,
            Color = CONFIG.TeamESP.NameColor,
            Visible = false,
            ZIndex = 3,
        }),
        distTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = CONFIG.GUI.DimText,
            Visible = false,
            ZIndex = 3,
        }),
        healthBar = newDrawing("Line", {
            Thickness = CONFIG.TeamESP.HealthBarWidth,
            Color = Color3.fromRGB(0, 255, 100),
            Visible = false,
            ZIndex = 3,
        }),
        healthBarBG = newDrawing("Line", {
            Thickness = CONFIG.TeamESP.HealthBarWidth,
            Color = Color3.fromRGB(50, 50, 50),
            Visible = false,
            ZIndex = 2,
        }),
        weaponTag = newDrawing("Text", {
            Size = CONFIG.DroneESP.TextSize - 2,
            Center = true,
            Outline = true,
            Color = Color3.fromRGB(200, 200, 220),
            Visible = false,
            ZIndex = 3,
        }),
        tracer = newDrawing("Line", {
            Thickness = 1,
            Transparency = 0.4,
            Color = CONFIG.TeamESP.BoxColor,
            Visible = false,
            ZIndex = 1,
        }),
    }
end

-- ═══════════════════════════════════════════════════════════
-- AIM PREDICTION ENGINE
-- Advanced iterative intercept solver with:
--  • Velocity smoothing (exponential lerp)
--  • Acceleration estimation (first-order derivative)
--  • Bullet drop compensation (quadratic gravity)
--  • Iterative convergence (Newton-like refinement)
-- ═══════════════════════════════════════════════════════════
local function updateDroneTracking(model, base, dt)
    local pos = base.Position
    local rawVel = base.AssemblyLinearVelocity
    local now = tick()
    
    local entry = droneVelocities[model]
    if not entry then
        droneVelocities[model] = {
            pos = pos,
            vel = rawVel,
            smoothVel = rawVel,
            accel = Vector3.zero,
            lastTime = now,
            lastVel = rawVel,
        }
        return droneVelocities[model]
    end
    
    local elapsed = math.max(now - entry.lastTime, 0.001)
    local alpha = 1 - math.exp(-elapsed / CONFIG.AimPrediction.SmoothFactor)
    
    -- Smooth velocity with exponential moving average
    local newSmooth = lerpV3(entry.smoothVel, rawVel, alpha)
    
    -- Estimate acceleration (derivative of velocity)
    local accelRaw = (newSmooth - entry.lastVel) / elapsed
    local accelAlpha = 1 - math.exp(-elapsed / (CONFIG.AimPrediction.SmoothFactor * 2))
    local newAccel = lerpV3(entry.accel, accelRaw, accelAlpha)
    
    entry.pos = pos
    entry.vel = rawVel
    entry.smoothVel = newSmooth
    entry.lastVel = newSmooth
    entry.accel = newAccel
    entry.lastTime = now
    
    return entry
end

local function predictPosition(entry, t)
    -- Position = pos + vel*t + 0.5*accel*t^2
    return entry.pos + entry.smoothVel * t + entry.accel * (0.5 * t * t)
end

local function solveIntercept(shooterPos, targetEntry, bulletSpeed)
    -- Iterative intercept solver
    -- Start with naive time estimate, refine through iterations
    local targetPos = targetEntry.pos
    local dist = (targetPos - shooterPos).Magnitude
    local timeEstimate = dist / bulletSpeed
    local gravity = CONFIG.AimPrediction.Gravity
    
    local bestPos = targetPos
    local bestTime = timeEstimate
    
    for i = 1, CONFIG.AimPrediction.IterationCount do
        -- Predict where target will be at estimated time
        local futurePos = predictPosition(targetEntry, timeEstimate)
        
        -- Calculate where bullet needs to aim to hit that point
        -- accounting for bullet drop: bulletY = -0.5 * g * t^2
        local delta = futurePos - shooterPos
        local horizontalDist = Vector3.new(delta.X, 0, delta.Z).Magnitude
        
        -- Compensate for bullet drop
        local dropCompensation = 0.5 * gravity * timeEstimate * timeEstimate
        local aimPos = futurePos + Vector3.new(0, dropCompensation, 0)
        
        -- Recalculate time based on 3D distance to aim point
        local aimDist = (aimPos - shooterPos).Magnitude
        local newTime = aimDist / bulletSpeed
        
        -- Convergence check
        if math.abs(newTime - timeEstimate) < 0.001 then
            bestPos = aimPos
            bestTime = newTime
            break
        end
        
        timeEstimate = newTime
        bestPos = aimPos
        bestTime = newTime
    end
    
    -- Clamp prediction time
    if bestTime > CONFIG.AimPrediction.MaxPredictTime then
        return nil, nil
    end
    
    return bestPos, bestTime
end

-- ═══════════════════════════════════════════════════════════
-- FIND NEAREST DRONE TO CROSSHAIR
-- ═══════════════════════════════════════════════════════════
local function findBestDroneTarget()
    local screenCenter = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local bestDist = CONFIG.AimPrediction.AimAssistFOV
    local bestModel = nil
    local bestEntry = nil
    
    for model, entry in pairs(droneVelocities) do
        if model.Parent and not model:GetAttribute("Crashed") then
            -- Check if this drone is an enemy
            local droneTeam = model:GetAttribute("TRV_Team")
            local ownerUserId = model:GetAttribute("OperatorUserId")
            local isFriendly = false
            
            if droneTeam then
                local teamObj = Teams:FindFirstChild(droneTeam)
                if teamObj then
                    local mySide = getTeamSide(LocalPlayer.Team)
                    local theirSide = getTeamSide(teamObj)
                    isFriendly = mySide and theirSide and mySide == theirSide
                end
            elseif ownerUserId then
                local player = Players:GetPlayerByUserId(ownerUserId)
                if player and player.Team then
                    isFriendly = not isEnemy(player.Team)
                end
            end
            
            if not isFriendly then
                local screenPos, onScreen = worldToScreen(entry.pos)
                if onScreen then
                    local dist = (screenPos - screenCenter).Magnitude
                    if dist < bestDist then
                        bestDist = dist
                        bestModel = model
                        bestEntry = entry
                    end
                end
            end
        end
    end
    
    return bestModel, bestEntry
end

-- ═══════════════════════════════════════════════════════════
-- MAIN RENDER LOOP
-- ═══════════════════════════════════════════════════════════
local function getScreenBottom()
    return Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
end

local function getScreenCenter()
    return Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
end

local function updateDroneESP(dt)
    if not CONFIG.DroneESP.Enabled then
        for model, drawings in pairs(droneDrawings) do
            for _, d in pairs(drawings) do
                pcall(function() d.Visible = false end)
            end
        end
        return
    end
    
    -- Collect all UAV models
    local activeDrones = {}
    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("Model") and child:GetAttribute("UAV") then
            activeDrones[child] = true
            local base = child:FindFirstChild("Base") or child.PrimaryPart
            if base and base:IsA("BasePart") then
                -- Update tracking
                local entry = updateDroneTracking(child, base, dt)
                
                -- Create drawings if needed
                if not droneDrawings[child] then
                    droneDrawings[child] = createDroneDrawing()
                end
                
                local d = droneDrawings[child]
                local dist = distanceTo(base.Position)
                
                if dist > CONFIG.DroneESP.MaxDistance then
                    for _, drawing in pairs(d) do
                        pcall(function() drawing.Visible = false end)
                    end
                    continue
                end
                
                -- Get bounding box on screen
                local cf = child:GetBoundingBox()
                local size = child:GetExtentsSize()
                
                local corners = {
                    cf * Vector3.new( size.X/2,  size.Y/2,  size.Z/2),
                    cf * Vector3.new(-size.X/2,  size.Y/2,  size.Z/2),
                    cf * Vector3.new( size.X/2, -size.Y/2,  size.Z/2),
                    cf * Vector3.new(-size.X/2, -size.Y/2,  size.Z/2),
                    cf * Vector3.new( size.X/2,  size.Y/2, -size.Z/2),
                    cf * Vector3.new(-size.X/2,  size.Y/2, -size.Z/2),
                    cf * Vector3.new( size.X/2, -size.Y/2, -size.Z/2),
                    cf * Vector3.new(-size.X/2, -size.Y/2, -size.Z/2),
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
                    for _, drawing in pairs(d) do
                        pcall(function() drawing.Visible = false end)
                    end
                    continue
                end
                
                -- Determine color
                local isCrashed = child:GetAttribute("Crashed")
                local droneTeam = child:GetAttribute("TRV_Team")
                local ownerUserId = child:GetAttribute("OperatorUserId")
                local isFriendly = false
                
                if droneTeam then
                    local teamObj = Teams:FindFirstChild(droneTeam)
                    if teamObj then
                        local mySide = getTeamSide(LocalPlayer.Team)
                        local theirSide = getTeamSide(teamObj)
                        isFriendly = mySide and theirSide and mySide == theirSide
                    end
                elseif ownerUserId then
                    local player = Players:GetPlayerByUserId(ownerUserId)
                    if player and player.Team then
                        isFriendly = not isEnemy(player.Team)
                    end
                end
                
                local color
                if isCrashed then
                    color = CONFIG.DroneESP.CrashedColor
                elseif isFriendly then
                    color = CONFIG.DroneESP.FriendlyColor
                else
                    color = CONFIG.DroneESP.BoxColor
                end
                
                -- Padding
                local pad = math.max(4, (maxX - minX) * 0.08)
                minX -= pad; minY -= pad; maxX += pad; maxY += pad
                local w = maxX - minX
                local h = maxY - minY
                
                -- Box
                d.box.Size = Vector2.new(w, h)
                d.box.Position = Vector2.new(minX, minY)
                d.box.Color = color
                d.box.Visible = true
                
                d.boxFill.Size = Vector2.new(w, h)
                d.boxFill.Position = Vector2.new(minX, minY)
                d.boxFill.Color = color
                d.boxFill.Visible = true
                
                -- Name tag
                local yOff = minY - 4
                if CONFIG.DroneESP.ShowName then
                    d.nameTag.Text = child.Name
                    d.nameTag.Position = Vector2.new(minX + w/2, yOff - 16)
                    d.nameTag.Color = color
                    d.nameTag.Visible = true
                    yOff -= 18
                else
                    d.nameTag.Visible = false
                end
                
                -- Distance
                if CONFIG.DroneESP.ShowDistance then
                    d.distTag.Text = string.format("%.0f st", dist)
                    d.distTag.Position = Vector2.new(minX + w/2, maxY + 3)
                    d.distTag.Visible = true
                else
                    d.distTag.Visible = false
                end
                
                -- Velocity
                if CONFIG.DroneESP.ShowVelocity and entry then
                    local speed = math.floor(entry.smoothVel.Magnitude + 0.5)
                    d.velTag.Text = string.format("%d st/s", speed)
                    d.velTag.Position = Vector2.new(minX + w/2, maxY + 17)
                    d.velTag.Visible = true
                else
                    d.velTag.Visible = false
                end
                
                -- Health bar (left side)
                local droneHP = child:GetAttribute("HP")
                local droneMaxHP = child:GetAttribute("MaxHP")
                if CONFIG.DroneESP.ShowHealth and droneHP and droneMaxHP and droneMaxHP > 0 then
                    local ratio = math.clamp(droneHP / droneMaxHP, 0, 1)
                    local barH = h * ratio
                    d.healthBarBG.From = Vector2.new(minX - 5, minY)
                    d.healthBarBG.To = Vector2.new(minX - 5, maxY)
                    d.healthBarBG.Visible = true
                    d.healthBar.From = Vector2.new(minX - 5, maxY - barH)
                    d.healthBar.To = Vector2.new(minX - 5, maxY)
                    d.healthBar.Color = Color3.fromRGB(
                        math.floor(255 * (1 - ratio)),
                        math.floor(255 * ratio),
                        50
                    )
                    d.healthBar.Visible = true
                else
                    d.healthBar.Visible = false
                    d.healthBarBG.Visible = false
                end
                
                -- Tracer
                if CONFIG.DroneESP.ShowTracer then
                    local origin
                    if CONFIG.DroneESP.TracerOrigin == "Bottom" then
                        origin = getScreenBottom()
                    elseif CONFIG.DroneESP.TracerOrigin == "Mouse" then
                        local mp = UserInputService:GetMouseLocation()
                        origin = Vector2.new(mp.X, mp.Y)
                    else
                        origin = getScreenCenter()
                    end
                    d.tracer.From = origin
                    d.tracer.To = Vector2.new(minX + w/2, maxY)
                    d.tracer.Color = color
                    d.tracer.Visible = true
                else
                    d.tracer.Visible = false
                end
                
                -- Aim Prediction visuals
                if CONFIG.AimPrediction.Enabled and CONFIG.AimPrediction.ShowPrediction and entry and not isCrashed and not isFriendly then
                    local shooterPos = Camera.CFrame.Position
                    local char = LocalPlayer.Character
                    if char then
                        local hrp = char:FindFirstChild("HumanoidRootPart")
                        if hrp then shooterPos = hrp.Position end
                    end
                    
                    local predPos, predTime = solveIntercept(shooterPos, entry, CONFIG.AimPrediction.BulletSpeed)
                    
                    if predPos and predTime then
                        local predScreen, predOnScreen = worldToScreen(predPos)
                        local isLocked = aimLocked and aimTarget == child
                        
                        if predOnScreen then
                            local predColor = isLocked and CONFIG.AimPrediction.LockedColor or CONFIG.AimPrediction.PredictionColor
                            d.predCircle.Position = predScreen
                            d.predCircle.Color = predColor
                            d.predCircle.Radius = math.clamp(800 / dist, 4, 20)
                            d.predCircle.Visible = true
                            
                            d.predDot.Position = predScreen
                            d.predDot.Color = predColor
                            d.predDot.Visible = true
                            
                            -- Line from drone to predicted pos
                            local droneCenter = Vector2.new(minX + w/2, minY + h/2)
                            d.predLine.From = droneCenter
                            d.predLine.To = predScreen
                            d.predLine.Color = predColor
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
        end
    end
    
    -- Cleanup removed drones
    for model, drawings in pairs(droneDrawings) do
        if not activeDrones[model] then
            destroyDrawings(drawings)
            droneDrawings[model] = nil
            droneVelocities[model] = nil
        end
    end
end

-- ═══════════════════════════════════════════════════════════
-- PLAYER / DRG TEAM ESP
-- ═══════════════════════════════════════════════════════════
local function updatePlayerESP()
    if not CONFIG.TeamESP.Enabled then
        for player, drawings in pairs(playerDrawings) do
            for _, d in pairs(drawings) do
                pcall(function() d.Visible = false end)
            end
        end
        for player, hl in pairs(playerHighlights) do
            pcall(function() hl:Destroy() end)
        end
        playerHighlights = {}
        return
    end
    
    local activePlayers = {}
    
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Team and isDRGSide(player.Team) then
            activePlayers[player] = true
            local char = player.Character
            if not char then continue end
            
            local hrp = char:FindFirstChild("HumanoidRootPart")
            local hum = char:FindFirstChildOfClass("Humanoid")
            local head = char:FindFirstChild("Head")
            if not hrp or not hum or hum.Health <= 0 then continue end
            
            local dist = distanceTo(hrp.Position)
            if dist > CONFIG.TeamESP.MaxDistance then
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
            
            -- Create drawings
            if not playerDrawings[player] then
                playerDrawings[player] = createPlayerDrawing()
            end
            
            local d = playerDrawings[player]
            
            -- 3D bounding box from character
            local rootCF = hrp.CFrame
            local charSize = Vector3.new(4, 6, 3)  -- approximate player bounds
            
            local topPos = rootCF.Position + Vector3.new(0, charSize.Y / 2 + 0.5, 0)
            local bottomPos = rootCF.Position - Vector3.new(0, charSize.Y / 2, 0)
            
            local topScreen, topOn = worldToScreen(topPos)
            local botScreen, botOn = worldToScreen(bottomPos)
            
            if not topOn or not botOn then
                for _, drawing in pairs(d) do
                    pcall(function() drawing.Visible = false end)
                end
                continue
            end
            
            local h = math.abs(botScreen.Y - topScreen.Y)
            local w = h * 0.55
            local cx = (topScreen.X + botScreen.X) / 2
            
            -- Box
            d.box.Size = Vector2.new(w, h)
            d.box.Position = Vector2.new(cx - w/2, topScreen.Y)
            d.box.Color = CONFIG.TeamESP.BoxColor
            d.box.Visible = true
            
            d.boxFill.Size = Vector2.new(w, h)
            d.boxFill.Position = Vector2.new(cx - w/2, topScreen.Y)
            d.boxFill.Color = CONFIG.TeamESP.BoxColor
            d.boxFill.Visible = true
            
            -- Name
            if CONFIG.TeamESP.ShowName then
                local teamTag = player.Team and player.Team.Name or ""
                d.nameTag.Text = string.format("[%s] %s", teamTag, player.DisplayName)
                d.nameTag.Position = Vector2.new(cx, topScreen.Y - 16)
                d.nameTag.Color = CONFIG.TeamESP.NameColor
                d.nameTag.Visible = true
            else
                d.nameTag.Visible = false
            end
            
            -- Distance
            if CONFIG.TeamESP.ShowDistance then
                d.distTag.Text = string.format("%.0f st", dist)
                d.distTag.Position = Vector2.new(cx, botScreen.Y + 3)
                d.distTag.Visible = true
            else
                d.distTag.Visible = false
            end
            
            -- Weapon
            if CONFIG.TeamESP.ShowWeapon then
                local tool = char:FindFirstChildOfClass("Tool")
                if tool then
                    d.weaponTag.Text = tool.Name
                    d.weaponTag.Position = Vector2.new(cx, botScreen.Y + 17)
                    d.weaponTag.Visible = true
                else
                    d.weaponTag.Visible = false
                end
            else
                d.weaponTag.Visible = false
            end
            
            -- Health bar (left side)
            if CONFIG.TeamESP.ShowHealth then
                local ratio = math.clamp(hum.Health / hum.MaxHealth, 0, 1)
                local barX = cx - w/2 - 5
                d.healthBarBG.From = Vector2.new(barX, topScreen.Y)
                d.healthBarBG.To = Vector2.new(barX, botScreen.Y)
                d.healthBarBG.Visible = true
                d.healthBar.From = Vector2.new(barX, botScreen.Y - h * ratio)
                d.healthBar.To = Vector2.new(barX, botScreen.Y)
                d.healthBar.Color = Color3.fromRGB(
                    math.floor(255 * (1 - ratio)),
                    math.floor(255 * ratio),
                    50
                )
                d.healthBar.Visible = true
            else
                d.healthBar.Visible = false
                d.healthBarBG.Visible = false
            end
            
            -- Tracer
            if CONFIG.TeamESP.ShowTracer then
                d.tracer.From = getScreenBottom()
                d.tracer.To = Vector2.new(cx, botScreen.Y)
                d.tracer.Color = CONFIG.TeamESP.BoxColor
                d.tracer.Visible = true
            else
                d.tracer.Visible = false
            end
            
            -- 3D Highlight
            if not playerHighlights[player] then
                local hl = Instance.new("Highlight")
                hl.Name = "SKYFIRE_ESP"
                hl.FillTransparency = CONFIG.TeamESP.HighlightFill
                hl.OutlineColor = CONFIG.TeamESP.HighlightOutline
                hl.FillColor = CONFIG.TeamESP.BoxColor
                hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                hl.Adornee = char
                hl.Parent = char
                playerHighlights[player] = hl
            end
        end
    end
    
    -- Cleanup removed players
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

-- ═══════════════════════════════════════════════════════════
-- MODERN GLASSMORPHISM GUI
-- ═══════════════════════════════════════════════════════════
local gui

local function createGUI()
    -- Cleanup existing
    local existing = LocalPlayer.PlayerGui:FindFirstChild("SkyfireEnhancedGUI")
    if existing then existing:Destroy() end
    
    gui = Instance.new("ScreenGui")
    gui.Name = "SkyfireEnhancedGUI"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.DisplayOrder = 999
    gui.Parent = LocalPlayer.PlayerGui
    
    -- Main container
    local mainFrame = Instance.new("Frame")
    mainFrame.Name = "MainFrame"
    mainFrame.AnchorPoint = Vector2.new(0, 0.5)
    mainFrame.Position = UDim2.new(0, 14, 0.5, 0)
    mainFrame.Size = UDim2.new(0, 280, 0, 0)  -- auto-sized by UIListLayout
    mainFrame.AutomaticSize = Enum.AutomaticSize.Y
    mainFrame.BackgroundColor3 = CONFIG.GUI.DarkBG
    mainFrame.BackgroundTransparency = 0.08
    mainFrame.BorderSizePixel = 0
    mainFrame.Parent = gui
    
    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 14)
    mainCorner.Parent = mainFrame
    
    local mainStroke = Instance.new("UIStroke")
    mainStroke.Color = CONFIG.GUI.AccentColor
    mainStroke.Transparency = 0.5
    mainStroke.Thickness = 1.5
    mainStroke.Parent = mainFrame
    
    local mainPadding = Instance.new("UIPadding")
    mainPadding.PaddingTop = UDim.new(0, 10)
    mainPadding.PaddingBottom = UDim.new(0, 10)
    mainPadding.PaddingLeft = UDim.new(0, 12)
    mainPadding.PaddingRight = UDim.new(0, 12)
    mainPadding.Parent = mainFrame
    
    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 6)
    listLayout.Parent = mainFrame
    
    -- ═══ TITLE BAR ═══
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundTransparency = 1
    titleBar.LayoutOrder = 0
    titleBar.Parent = mainFrame
    
    local titleIcon = Instance.new("TextLabel")
    titleIcon.Size = UDim2.new(0, 28, 0, 28)
    titleIcon.Position = UDim2.new(0, 0, 0.5, -14)
    titleIcon.BackgroundColor3 = CONFIG.GUI.AccentColor
    titleIcon.BackgroundTransparency = 0.15
    titleIcon.Text = "⚡"
    titleIcon.TextSize = 16
    titleIcon.Font = Enum.Font.GothamBold
    titleIcon.TextColor3 = Color3.new(1, 1, 1)
    titleIcon.Parent = titleBar
    
    local iconCorner = Instance.new("UICorner")
    iconCorner.CornerRadius = UDim.new(0, 7)
    iconCorner.Parent = titleIcon
    
    local titleText = Instance.new("TextLabel")
    titleText.Size = UDim2.new(1, -36, 0, 20)
    titleText.Position = UDim2.new(0, 36, 0, 2)
    titleText.BackgroundTransparency = 1
    titleText.Text = "SKYFIRE ENHANCED"
    titleText.TextXAlignment = Enum.TextXAlignment.Left
    titleText.TextSize = 15
    titleText.Font = Enum.Font.GothamBold
    titleText.TextColor3 = CONFIG.GUI.AccentColor
    titleText.Parent = titleBar
    
    local titleSub = Instance.new("TextLabel")
    titleSub.Size = UDim2.new(1, -36, 0, 14)
    titleSub.Position = UDim2.new(0, 36, 0, 21)
    titleSub.BackgroundTransparency = 1
    titleSub.Text = "v2.0 · Drone ESP · DRG ESP · Aimbot"
    titleSub.TextXAlignment = Enum.TextXAlignment.Left
    titleSub.TextSize = 10
    titleSub.Font = Enum.Font.Gotham
    titleSub.TextColor3 = CONFIG.GUI.DimText
    titleSub.Parent = titleBar
    
    -- ═══ DIVIDER ═══
    local function createDivider(order)
        local divider = Instance.new("Frame")
        divider.Size = UDim2.new(1, 0, 0, 1)
        divider.BackgroundColor3 = CONFIG.GUI.AccentColor
        divider.BackgroundTransparency = 0.7
        divider.BorderSizePixel = 0
        divider.LayoutOrder = order
        divider.Parent = mainFrame
        return divider
    end
    
    -- ═══ TOGGLE BUTTON CREATOR ═══
    local function createToggle(name, description, order, getter, setter)
        local toggleFrame = Instance.new("Frame")
        toggleFrame.Name = name
        toggleFrame.Size = UDim2.new(1, 0, 0, 32)
        toggleFrame.BackgroundColor3 = CONFIG.GUI.CardBG
        toggleFrame.BackgroundTransparency = 0.4
        toggleFrame.BorderSizePixel = 0
        toggleFrame.LayoutOrder = order
        toggleFrame.Parent = mainFrame
        
        local toggleCorner = Instance.new("UICorner")
        toggleCorner.CornerRadius = UDim.new(0, 8)
        toggleCorner.Parent = toggleFrame
        
        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -56, 1, 0)
        label.Position = UDim2.new(0, 10, 0, 0)
        label.BackgroundTransparency = 1
        label.Text = description
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextSize = 12
        label.Font = Enum.Font.GothamMedium
        label.TextColor3 = CONFIG.GUI.TextColor
        label.Parent = toggleFrame
        
        -- Toggle switch
        local switchBG = Instance.new("Frame")
        switchBG.Name = "SwitchBG"
        switchBG.AnchorPoint = Vector2.new(1, 0.5)
        switchBG.Position = UDim2.new(1, -8, 0.5, 0)
        switchBG.Size = UDim2.new(0, 38, 0, 20)
        switchBG.BackgroundColor3 = getter() and CONFIG.GUI.AccentColor or Color3.fromRGB(60, 60, 70)
        switchBG.BorderSizePixel = 0
        switchBG.Parent = toggleFrame
        
        local switchCorner = Instance.new("UICorner")
        switchCorner.CornerRadius = UDim.new(0.5, 0)
        switchCorner.Parent = switchBG
        
        local knob = Instance.new("Frame")
        knob.Name = "Knob"
        knob.AnchorPoint = Vector2.new(0, 0.5)
        knob.Position = getter() and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
        knob.Size = UDim2.new(0, 16, 0, 16)
        knob.BackgroundColor3 = Color3.new(1, 1, 1)
        knob.BorderSizePixel = 0
        knob.Parent = switchBG
        
        local knobCorner = Instance.new("UICorner")
        knobCorner.CornerRadius = UDim.new(0.5, 0)
        knobCorner.Parent = knob
        
        -- Click handler
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 1, 0)
        btn.BackgroundTransparency = 1
        btn.Text = ""
        btn.Parent = toggleFrame
        
        btn.MouseButton1Click:Connect(function()
            local newState = not getter()
            setter(newState)
            
            -- Animate
            local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            TweenService:Create(switchBG, tweenInfo, {
                BackgroundColor3 = newState and CONFIG.GUI.AccentColor or Color3.fromRGB(60, 60, 70)
            }):Play()
            TweenService:Create(knob, tweenInfo, {
                Position = newState and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
            }):Play()
        end)
        
        return toggleFrame
    end
    
    -- ═══ SECTION HEADER ═══
    local function createSectionHeader(text, order, icon)
        local header = Instance.new("TextLabel")
        header.Size = UDim2.new(1, 0, 0, 22)
        header.BackgroundTransparency = 1
        header.Text = (icon or "").. "  " .. text
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.TextSize = 12
        header.Font = Enum.Font.GothamBold
        header.TextColor3 = CONFIG.GUI.AccentAlt
        header.LayoutOrder = order
        header.Parent = mainFrame
        return header
    end
    
    -- ═══ BUILD SECTIONS ═══
    createDivider(1)
    
    -- DRONE ESP section
    createSectionHeader("DRONE ESP", 10, "🛸")
    createToggle("DroneESPToggle", "Drone ESP", 11,
        function() return CONFIG.DroneESP.Enabled end,
        function(v) CONFIG.DroneESP.Enabled = v end
    )
    createToggle("DroneBoxToggle", "Show Tracers", 12,
        function() return CONFIG.DroneESP.ShowTracer end,
        function(v) CONFIG.DroneESP.ShowTracer = v end
    )
    createToggle("DroneVelToggle", "Show Velocity", 13,
        function() return CONFIG.DroneESP.ShowVelocity end,
        function(v) CONFIG.DroneESP.ShowVelocity = v end
    )
    createToggle("DroneNameToggle", "Show Names", 14,
        function() return CONFIG.DroneESP.ShowName end,
        function(v) CONFIG.DroneESP.ShowName = v end
    )
    
    createDivider(20)
    
    -- AIM PREDICTION section
    createSectionHeader("AIM PREDICTION", 21, "🎯")
    createToggle("AimPredToggle", "Aim Prediction", 22,
        function() return CONFIG.AimPrediction.Enabled end,
        function(v) CONFIG.AimPrediction.Enabled = v end
    )
    createToggle("AimShowToggle", "Show Predicted Point", 23,
        function() return CONFIG.AimPrediction.ShowPrediction end,
        function(v) CONFIG.AimPrediction.ShowPrediction = v end
    )
    createToggle("AimAssistToggle", "Aim Assist (E key)", 24,
        function() return CONFIG.AimPrediction.AimAssist end,
        function(v) CONFIG.AimPrediction.AimAssist = v end
    )
    
    createDivider(30)
    
    -- DRG TEAM ESP section
    createSectionHeader("DRG / ENEMY ESP", 31, "👥")
    createToggle("TeamESPToggle", "Team ESP", 32,
        function() return CONFIG.TeamESP.Enabled end,
        function(v) CONFIG.TeamESP.Enabled = v end
    )
    createToggle("TeamNameToggle", "Show Names", 33,
        function() return CONFIG.TeamESP.ShowName end,
        function(v) CONFIG.TeamESP.ShowName = v end
    )
    createToggle("TeamHealthToggle", "Show Health Bars", 34,
        function() return CONFIG.TeamESP.ShowHealth end,
        function(v) CONFIG.TeamESP.ShowHealth = v end
    )
    createToggle("TeamWeaponToggle", "Show Weapons", 35,
        function() return CONFIG.TeamESP.ShowWeapon end,
        function(v) CONFIG.TeamESP.ShowWeapon = v end
    )
    createToggle("TeamTracerToggle", "Show Tracers", 36,
        function() return CONFIG.TeamESP.ShowTracer end,
        function(v) CONFIG.TeamESP.ShowTracer = v end
    )
    
    createDivider(40)
    
    -- Status footer
    local footer = Instance.new("TextLabel")
    footer.Size = UDim2.new(1, 0, 0, 16)
    footer.BackgroundTransparency = 1
    footer.Text = "[RShift] Toggle GUI  ·  [E] Lock Aim"
    footer.TextSize = 9
    footer.Font = Enum.Font.Gotham
    footer.TextColor3 = CONFIG.GUI.DimText
    footer.LayoutOrder = 50
    footer.Parent = mainFrame
    
    -- Make draggable
    local dragging = false
    local dragStart, startPos
    
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = mainFrame.Position
        end
    end)
    
    titleBar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
    
    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            mainFrame.Position = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
        end
    end)
    
    -- Open animation
    mainFrame.BackgroundTransparency = 1
    TweenService:Create(mainFrame, TweenInfo.new(0.5, Enum.EasingStyle.Exponential), {
        BackgroundTransparency = 0.08
    }):Play()
    
    return gui
end

-- ═══════════════════════════════════════════════════════════
-- INPUT HANDLING
-- ═══════════════════════════════════════════════════════════
local function setupInput()
    table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        
        -- Toggle GUI
        if input.KeyCode == CONFIG.GUI.ToggleKey then
            if gui then
                local mainFrame = gui:FindFirstChild("MainFrame")
                if mainFrame then
                    guiVisible = not guiVisible
                    local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad)
                    if guiVisible then
                        mainFrame.Visible = true
                        TweenService:Create(mainFrame, tweenInfo, {
                            BackgroundTransparency = 0.08
                        }):Play()
                    else
                        TweenService:Create(mainFrame, tweenInfo, {
                            BackgroundTransparency = 1
                        }):Play()
                        task.delay(0.3, function()
                            if not guiVisible then mainFrame.Visible = false end
                        end)
                    end
                end
            end
        end
        
        -- Aim lock
        if input.KeyCode == CONFIG.AimPrediction.AimKey then
            if CONFIG.AimPrediction.AimAssist then
                local model, entry = findBestDroneTarget()
                if model and entry then
                    aimTarget = model
                    aimLocked = true
                else
                    aimTarget = nil
                    aimLocked = false
                end
            end
        end
    end))
    
    table.insert(connections, UserInputService.InputEnded:Connect(function(input, gameProcessed)
        if input.KeyCode == CONFIG.AimPrediction.AimKey then
            aimLocked = false
            aimTarget = nil
        end
    end))
end

-- ═══════════════════════════════════════════════════════════
-- AIM ASSIST — MOVE CAMERA TO PREDICTED POS
-- ═══════════════════════════════════════════════════════════
local function updateAimAssist()
    if not CONFIG.AimPrediction.AimAssist or not aimLocked or not aimTarget then return end
    
    local entry = droneVelocities[aimTarget]
    if not entry or not aimTarget.Parent or aimTarget:GetAttribute("Crashed") then
        aimLocked = false
        aimTarget = nil
        return
    end
    
    local shooterPos = Camera.CFrame.Position
    local char = LocalPlayer.Character
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then shooterPos = hrp.Position end
    end
    
    local predPos, predTime = solveIntercept(shooterPos, entry, CONFIG.AimPrediction.BulletSpeed)
    if predPos then
        -- Smoothly move camera to look at predicted position
        local targetCF = CFrame.lookAt(Camera.CFrame.Position, predPos)
        Camera.CFrame = Camera.CFrame:Lerp(targetCF, 0.15)
    end
end

-- ═══════════════════════════════════════════════════════════
-- MASTER RENDER LOOP
-- ═══════════════════════════════════════════════════════════
local function onRenderStep(dt)
    Camera = workspace.CurrentCamera
    if not Camera then return end
    
    updateDroneESP(dt)
    updatePlayerESP()
    updateAimAssist()
end

-- ═══════════════════════════════════════════════════════════
-- CLEANUP
-- ═══════════════════════════════════════════════════════════
local function cleanup()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}
    
    for _, drawings in pairs(droneDrawings) do
        destroyDrawings(drawings)
    end
    droneDrawings = {}
    droneVelocities = {}
    
    for _, drawings in pairs(playerDrawings) do
        destroyDrawings(drawings)
    end
    playerDrawings = {}
    
    for _, hl in pairs(playerHighlights) do
        pcall(function() hl:Destroy() end)
    end
    playerHighlights = {}
    
    if gui then
        pcall(function() gui:Destroy() end)
        gui = nil
    end
end

-- ═══════════════════════════════════════════════════════════
-- INIT
-- ═══════════════════════════════════════════════════════════

-- Cleanup any previous instance
if _G.SKYFIRE_ENHANCED_CLEANUP then
    pcall(_G.SKYFIRE_ENHANCED_CLEANUP)
end
_G.SKYFIRE_ENHANCED_CLEANUP = cleanup

-- Get gravity from workspace
CONFIG.AimPrediction.Gravity = workspace.Gravity or 196.2

-- Create GUI
createGUI()

-- Setup input
setupInput()

-- Main render connection
local renderConn = RunService.RenderStepped:Connect(onRenderStep)
table.insert(connections, renderConn)

-- Player remove cleanup
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

print("═══════════════════════════════════════")
print("  ⚡ SKYFIRE ENHANCED v2.0 Loaded!")
print("  [RShift] Toggle GUI")
print("  [E]      Lock Aim (when Aim Assist ON)")
print("═══════════════════════════════════════")
