-- Project Vector — SKYFIRE Drone ESP & Prediction (Compact v2)
local clamp = function(v, mn, mx) return (v < mn and mn) or (v > mx and mx) or v end
math.clamp = math.clamp or clamp

-- ── Menu Setup ──
menu.AddTab("Skyfire", "✈")
local function mcb(g, id, label, def) menu.AddCheckbox("Skyfire", g, id, label, def) end
local function mcp(g, id, label, def) menu.AddColorpicker("Skyfire", g, id, label, def) end

menu.AddGroup("Skyfire", "Visuals", 0, false)
for _, c in ipairs({
    {"esp_enabled", "Enable ESP", true}, {"esp_box", "Corner Box", true},
    {"esp_names", "Show Names", true},   {"esp_hp", "Show HP Bar", true},
    {"esp_dist", "Show Distance", true}, {"esp_type", "Show Type", true},
    {"esp_wrecks", "Show Wrecks", false},{"esp_vel", "Velocity Vector", true}
}) do mcb("Visuals", c[1], c[2], c[3]) end
menu.AddSliderInt("Skyfire", "Visuals", "esp_max_dist", "Max Dist (m)", 50, 2500, 1200, "%d m")
mcp("Visuals", "col_uav", "UAV Color", {1.0, 0.33, 0.22, 1.0})
mcp("Visuals", "col_fpv", "FPV Color", {1.0, 0.78, 0.20, 1.0})
mcp("Visuals", "col_wreck", "Wreck Color", {0.5, 0.5, 0.5, 0.6})
mcp("Visuals", "col_team", "Team Color", {0.3, 0.85, 0.45, 1.0})

menu.AddGroup("Skyfire", "Aim & Prediction", 0, true)
mcb("Aim & Prediction", "pred_enabled", "Prediction Crosshair", true)
mcp("Aim & Prediction", "col_pred", "Marker Color", {0.45, 0.80, 1.0, 1.0})
menu.AddSliderFloat("Skyfire", "Aim & Prediction", "bullet_speed", "Bullet Speed", 500, 6000, 3285.7, "%.1f")
menu.AddSliderFloat("Skyfire", "Aim & Prediction", "bullet_drop", "Bullet Drop", 0, 100, 35.04, "%.2f")
menu.AddSliderFloat("Skyfire", "Aim & Prediction", "vel_smooth", "Vel Smoothing", 0.05, 1.0, 0.35, "%.2f")
menu.AddSeparator("Skyfire", "Aim & Prediction")
mcb("Aim & Prediction", "aim_enabled", "Enable Snap-Aim", false)
menu.AddHotkey("Skyfire", "Aim & Prediction", "aim_key", "Aim Key", 0x02) -- RMB
menu.AddSliderInt("Skyfire", "Aim & Prediction", "aim_fov", "Aim FOV", 20, 600, 250, "%d px")
menu.AddSliderFloat("Skyfire", "Aim & Prediction", "aim_smooth", "Aim Smoothing", 0.01, 0.95, 0.15, "%.2f")
mcb("Aim & Prediction", "draw_fov", "Draw FOV Circle", true)

-- ── State & Caching ──
local cachedDrones, velCache = {}, {}

local function getDroneData(drone)
    local part = drone:FindFirstChild("Base") or drone:FindFirstChild("CenterMass") or drone.PrimaryPart
    if not part or not part.Position then return nil end
    local ga = function(k) local ok, v = pcall(function() return drone:GetAttribute(k) end); return ok and v or nil end
    local dead = ga("Crashed") or ga("Settled") or (tonumber(ga("HP") or 1) <= 0)
    local dtype = (ga("droneType") or (drone.Name:lower():find("fpv") and "fpv" or "uav")):lower()
    local hp = tonumber(ga("HP")) or (dtype == "fpv" and 1 or 100)
    local maxHp = dtype == "fpv" and 1 or (hp > 100 and 150 or (hp > 50 and 100 or 85))
    return part, Vector3.New(part.Position.X, part.Position.Y, part.Position.Z), not dead, dtype, hp, maxHp, ga("TRV_Team")
end

local function getVelocity(drone, part, pos, now)
    local c = velCache[drone] or {}
    local raw, delta = Vector3.New(0,0,0), Vector3.New(0,0,0)
    pcall(function()
        local v = part.AssemblyLinearVelocity or part.Velocity
        if v then raw = Vector3.New(v.X, v.Y, v.Z) end
    end)
    if c.pos and c.time and (now - c.time > 0.005) then
        local dt = now - c.time
        delta = Vector3.New((pos.X - c.pos.X)/dt, (pos.Y - c.pos.Y)/dt, (pos.Z - c.pos.Z)/dt)
    end
    local vel = (raw.Magnitude > 1.5 and raw or delta)
    local smooth = c.vel and c.vel:Lerp(vel, clamp(menu.Get("vel_smooth") or 0.35, 0.05, 1.0)) or vel
    velCache[drone] = {pos = pos, time = now, vel = smooth}
    return smooth
end

local function predict(origin, targetPos, targetVel, spd, drop)
    local t, aim = (targetPos - origin).Magnitude / math.max(spd, 100), targetPos
    for _ = 1, 6 do
        local fut = targetPos + targetVel * t
        aim = Vector3.New(fut.X, fut.Y + 0.5 * drop * (t * t), fut.Z)
        local nt = (aim - origin).Magnitude / spd
        if math.abs(nt - t) < 0.0005 then break end
        t = nt
    end
    return aim, t
end

-- ── Background Threads ──
thread.Create(function()
    local ws, list = game.Workspace, {}
    local ok, tagged = pcall(function() return game:GetService("CollectionService"):GetTagged("UAVDrone") end)
    if ok and type(tagged) == "table" and #tagged > 0 then
        for _, d in ipairs(tagged) do if utility.IsValid(d) then table.insert(list, d) end end
    elseif ws then
        for _, c in ipairs(ws:GetChildren()) do
            if utility.IsValid(c) and (c.Name:find("Drone") or c.Name:find("UAV") or c.Name:find("FPV") or c:FindFirstChild("Base")) then
                table.insert(list, c)
            end
        end
    end
    cachedDrones = list
    for d, _ in pairs(velCache) do if not utility.IsValid(d) then velCache[d] = nil end end
end, 250)

thread.Create(function()
    if not getgc then return end
    pcall(function()
        local matches = getgc({"bulletSpeed", "bulletDrop"})
        if matches and #matches > 0 then
            for _, m in ipairs(matches) do
                local f = m.fields
                if f and f.bulletSpeed and f.bulletSpeed > 100 then
                    menu.Set("bullet_speed", f.bulletSpeed)
                    if f.bulletDrop then menu.Set("bullet_drop", f.bulletDrop) end
                    break
                end
            end
        end
    end)
end, 2000)

-- ── Render Loop ──
OnFrame = function()
    local cx, cy = input.GetScreenCenter()
    local now, maxDist = utility.GetTime(), menu.Get("esp_max_dist") or 1200
    local bSpeed, bDrop = menu.Get("bullet_speed") or 3285.7, menu.Get("bullet_drop") or 35.04
    local aimFov, aimSmooth = menu.Get("aim_fov") or 250, menu.Get("aim_smooth") or 0.15
    local aimKey = menu.GetKey("aim_key") == 0 and 0x02 or menu.GetKey("aim_key")

    if menu.Get("aim_enabled") and menu.Get("draw_fov") then
        draw.Circle(cx, cy, aimFov, {1, 1, 1, 0.25}, 36, 1.0)
    end

    local camPos = camera.GetPosition() or Vector3.New(0,0,0)
    local myTeam = pcall(function() return game.LocalPlayer.Character:GetAttribute("TRV_Team") end) and game.LocalPlayer.Character:GetAttribute("TRV_Team") or nil
    local bestAimDist, bestAimPos = math.huge, nil

    for _, drone in ipairs(cachedDrones) do
        if utility.IsValid(drone) then
            local part, pos, alive, dtype, hp, maxHp, team = getDroneData(drone)
            local dist = pos and (pos - camPos).Magnitude or math.huge
            if pos and (dist * 0.28 <= maxDist) and (alive or menu.Get("esp_wrecks")) then
                local isFriendly = (myTeam and team and myTeam == team)
                local col = not alive and menu.GetColor("col_wreck") or (isFriendly and menu.GetColor("col_team") or (dtype == "fpv" and menu.GetColor("col_fpv") or menu.GetColor("col_uav")))
                local sx, sy, onScreen = utility.WorldToScreen(pos)
                local vel = getVelocity(drone, part, pos, now)

                -- Visuals
                if menu.Get("esp_enabled") and onScreen then
                    local _, topY, topOk = utility.WorldToScreen(Vector3.New(pos.X, pos.Y + (dtype == "fpv" and 1 or 2), pos.Z))
                    local _, botY, botOk = utility.WorldToScreen(Vector3.New(pos.X, pos.Y - (dtype == "fpv" and 1 or 2), pos.Z))
                    local boxH = clamp((topOk and botOk) and math.abs(botY - topY) or (2800 / math.max(dist, 10)), 16, 500)
                    local boxW, boxX, boxY = boxH * 0.85, sx - (boxH * 0.85) / 2, sy - boxH / 2

                    if menu.Get("esp_box") then draw.CornerBox(boxX, boxY, boxW, boxH, col) end
                    if menu.Get("esp_hp")  then draw.HealthBar(boxX - 6, boxY, boxH, hp, maxHp) end
                    if menu.Get("esp_names") then
                        local tw, th = draw.GetTextSize(drone.Name, 13)
                        draw.Text(boxX + boxW/2 - tw/2, boxY - th - 3, drone.Name, col, 13)
                    end
                    local tag = (menu.Get("esp_type") and (not alive and "💀 WRECK " or (dtype == "fpv" and "⚡ FPV " or "✈ UAV ")) or "") .. (menu.Get("esp_dist") and string.format("[%.0fm]", dist * 0.28) or "")
                    if #tag > 0 then
                        local tw, _ = draw.GetTextSize(tag, 11)
                        draw.Text(boxX + boxW/2 - tw/2, boxY + boxH + 2, tag, {0.85, 0.85, 0.85, 1}, 11)
                    end
                    if menu.Get("esp_vel") and vel.Magnitude > 3.0 then
                        local vx, vy, vOn = utility.WorldToScreen(pos + vel.Unit * math.min(vel.Magnitude * 0.18, 35))
                        if vOn then draw.Line(sx, sy, vx, vy, {1, 1, 0.3, 0.75}, 1) end
                    end
                end

                -- Prediction & Aimbot
                if alive and not isFriendly and vel.Magnitude > 1.5 then
                    local predPos, tof = predict(camPos, pos, vel, bSpeed, bDrop)
                    local px, py, pOn = utility.WorldToScreen(predPos)
                    if pOn then
                        if menu.Get("pred_enabled") then
                            local pc = menu.GetColor("col_pred")
                            draw.Circle(px, py, 4, pc, 16, 1.5)
                            draw.Line(px-9, py, px-3, py, pc, 1.5); draw.Line(px+3, py, px+9, py, pc, 1.5)
                            draw.Line(px, py-9, px, py-3, pc, 1.5); draw.Line(px, py+3, px, py+9, pc, 1.5)
                            if onScreen then draw.Line(sx, sy, px, py, {pc[1], pc[2], pc[3], 0.35}, 1) end
                            draw.Text(px + 7, py - 14, string.format("%.2fs", tof), pc, 11)
                        end
                        local dCross = math.sqrt((px - cx)^2 + (py - cy)^2)
                        if dCross <= aimFov and dCross < bestAimDist then
                            bestAimDist, bestAimPos = dCross, {x = px, y = py}
                        end
                    end
                end
            end
        end
    end

    -- Aim Execution
    if menu.Get("aim_enabled") and bestAimPos and input.IsKeyDown(aimKey) then
        local mx = (bestAimPos.x - cx) * (1.0 - aimSmooth)
        local my = (bestAimPos.y - cy) * (1.0 - aimSmooth)
        if math.abs(mx) > 0.1 or math.abs(my) > 0.1 then input.MoveMouse(mx, my) end
    end
end

notify.Success("SKYFIRE Drone Helper", "Compact Edition Active", 4)

