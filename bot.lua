-- Secret finder + reporter + server hopper (Delta-friendly)
queue_on_teleport("loadstring(Game:HttpGet('https://raw.githubusercontent.com/bypassv5/autojoiner/refs/heads/main/bot.lua'))()")
-- === CONFIG ===
local MIN_TARGET = 10_000_000
local API_URL = "http://novachat.elementfx.com/report.php"
local POLL_DELAY = 1           -- wait after hop in case teleport fails
local HOP_DELAY  = 0.2           -- small delay before teleport
local SERVER_FETCH_LIMIT = 10  -- safety cap on server pages

-- === SERVICES / ENV ===
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PLACE_ID = game.PlaceId

-- executor HTTP (Delta / Synapse / etc.)
local http = http_request or request or (syn and syn.request)
if not http then
    warn("[Finder] No http_request / request / syn.request available. Abort.")
    return
end

local function log(...)
    print("[Finder]", ...)
end

------------------------------------------------------------
-- Parse generation text like "12.3M", "45K", "1.2B", "500000"
------------------------------------------------------------
local function parseGenerationText(txt)
    if not txt then return 0, "?" end
    -- strip $, "/s", and whitespace
    local s = tostring(txt):gsub("%$", ""):gsub("/s", ""):gsub("%s+", "")
    local multipliers = { K = 1_000, M = 1_000_000, B = 1_000_000_000 }
    local last = s:sub(-1):upper()

    if multipliers[last] then
        local num = tonumber(s:sub(1, -2)) or 0
        return num * multipliers[last], s
    else
        local n = tonumber(s)
        if n then return n, s end
        return 0, s
    end
end

------------------------------------------------------------
-- POST JobId + info to your PHP endpoint on x10
------------------------------------------------------------
local function postJob(fullGenValue, rawGen, nameText, baseOwner)
    local payload = {
        jobId = tostring(game.JobId or "unknown"),
        placeId = tostring(PLACE_ID or "unknown"),
        generation = fullGenValue,
        rawGeneration = rawGen,
        name = tostring(nameText or "?"),
        owner = tostring(baseOwner or "?"),
        time = os.time(),
    }

    local body = HttpService:JSONEncode(payload)

    local ok, res = pcall(function()
        return http({
            Url = API_URL,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = body
        })
    end)

    if ok then
        log("Posted JobId " .. payload.jobId .. " | Gen " .. tostring(fullGenValue))
    else
        warn("[Finder] POST failed:", res)
    end
end

------------------------------------------------------------
-- Scan all plots for Secret brainrots
-- returns found(bool), fullGenValue(number)
------------------------------------------------------------
local function findAndNotifySecrets()
    if not workspace:FindFirstChild("Plots") then
        log("No Plots folder, skipping.")
        return false, 0
    end

    local PlayerName = LocalPlayer and (LocalPlayer.DisplayName or LocalPlayer.Name)

    for _, plot in ipairs(workspace.Plots:GetChildren()) do
        local sign = plot:FindFirstChild("PlotSign")
        if not sign then continue end

        local surf = sign:FindFirstChild("SurfaceGui")
        if not surf then continue end

        local frame = surf:FindFirstChild("Frame")
        if not frame then continue end

        local label = frame:FindFirstChild("TextLabel")
        if not label then continue end

        if label.Text == "Empty Base" then continue end

        local baseOwner = string.split(label.Text, "'")[1] or "?"
        if baseOwner == PlayerName then
            -- skip our own base
            continue
        end

        local podiums = plot:FindFirstChild("AnimalPodiums")
        if not podiums then continue end

        for _, podium in ipairs(podiums:GetChildren()) do
            local spawn = podium:FindFirstChild("Base") and podium.Base:FindFirstChild("Spawn")
            if not spawn then continue end

            local attach = spawn:FindFirstChild("Attatchment") or spawn:FindFirstChild("Attachment")
            if not attach then continue end

            local overhead = attach:FindFirstChild("AnimalOverhead")
            if not overhead then continue end

            local rarity = overhead:FindFirstChild("Rarity")
            local stolen = overhead:FindFirstChild("Stolen")
            if not rarity or not stolen then continue end

            if rarity.Text == "Secret" and stolen.Text ~= "FUSING" then
                local mutation = overhead:FindFirstChild("Mutation")
                local generation = overhead:FindFirstChild("Generation")
                local name = overhead:FindFirstChild("DisplayName")
                local traits = overhead:FindFirstChild("Traits")

                local mutationText = (mutation and mutation.Visible and mutation.Text) or "Normal"
                local generationText = generation and generation.Text or "?"
                local nameText = name and name.Text or "?"
                local traitAmount = 0

                if traits then
                    for _, n in ipairs(traits:GetChildren()) do
                        if n:IsA("ImageLabel") and n.Name == "Template" and n.Visible then
                            traitAmount = traitAmount + 1
                        end
                    end
                end

                local fullGenValue, rawGen = parseGenerationText(generationText)

                log(("SECRET FOUND! Name=%s | Owner=%s | Gen=%s (%d) | Mut=%s | Traits=%d")
                    :format(nameText, baseOwner, rawGen, fullGenValue, mutationText, traitAmount))

                if fullGenValue >= MIN_TARGET then
                    postJob(fullGenValue, rawGen, nameText, baseOwner)
                    return true, fullGenValue
                end
            end
        end
    end

    return false, 0
end
------------------------------------------------------------
-- Collect candidate servers (non-full, not current)
-- Uses executor http_request instead of HttpService:GetAsync
------------------------------------------------------------
local function collectServers()
    local servers = {}
    local cursor = ""
    local attempts = 0

    repeat
        attempts = attempts + 1

        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s")
            :format(PLACE_ID, cursor ~= "" and ("&cursor=" .. cursor) or "")

        local ok, res = pcall(function()
            return http({
                Url = url,
                Method = "GET",
                Headers = {
                    ["Accept"] = "application/json"
                }
            })
        end)

        if not ok or not res or not res.Body then
            warn("[Finder] Failed to fetch server list (attempt " .. attempts .. ")")
            cursor = ""
            break
        end

        local successDecode, decoded = pcall(function()
            return HttpService:JSONDecode(res.Body)
        end)

        if successDecode and decoded and decoded.data then
            for _, s in ipairs(decoded.data) do
                if s
                    and s.id
                    and tonumber(s.playing or 0) < tonumber(s.maxPlayers or 0)
                    and s.id ~= game.JobId
                then
                    table.insert(servers, s.id)
                end
            end
            cursor = decoded.nextPageCursor or ""
        else
            warn("[Finder] JSON decode failed on server list.")
            cursor = ""
            break
        end
    until cursor == "" or attempts >= SERVER_FETCH_LIMIT or #servers >= 50

    return servers
end

------------------------------------------------------------
-- Hop to a random server from list
------------------------------------------------------------
local function hopServer()
    local servers = collectServers()
    if #servers == 0 then
        warn("[Finder] No servers found; waiting and retrying.")
        task.wait(10)
        return
    end

    math.randomseed(tick() + os.time())
    local target = servers[math.random(1, #servers)]
    log("Hopping to server:", target)
    task.wait(HOP_DELAY)

    if not LocalPlayer then
        warn("[Finder] No LocalPlayer; teleport skipped.")
        return
    end

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(PLACE_ID, target, LocalPlayer)
    end)
    if not ok then
        warn("[Finder] Teleport failed:", err)
    end
end

------------------------------------------------------------
-- MAIN LOOP: scan -> (maybe post) -> hop. Always hops.
------------------------------------------------------------
while true do
    local found, value = findAndNotifySecrets()
    log("Scan complete. Found >=10M:", found, "Value:", value)

    -- always hop after scan
    hopServer()

    -- if teleport fails for some reason, wait a bit then scan again
    task.wait(POLL_DELAY)
end
