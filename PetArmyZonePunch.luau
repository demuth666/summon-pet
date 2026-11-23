local BPUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/bypasshubpremium/BPUINEW/main/BPUI.lua"))()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local configLoaded, Config = pcall(require, ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
if not configLoaded then
	error("Could not load the game configuration: " .. tostring(Config))
end
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PunchRemote = Remotes:WaitForChild("Punch")
local PadStepRemote = Remotes:WaitForChild("PadStep")
local ArmyActionRemote = Remotes:WaitForChild("ArmyAction")
local CampActionRemote = Remotes:WaitForChild("CampAction")
local AnnounceRemote = Remotes:WaitForChild("Announce")
local SoulRemote = Remotes:WaitForChild("Soul")
local SoulChoiceRemote = Remotes:WaitForChild("SoulChoice")
local WildCreatures = Workspace:WaitForChild("WildCreatures")

local ZONE_LOAD_TIMEOUT = 12
local PAD_STEP_TIMEOUT = 10
local TARGET_LOAD_TIMEOUT = 5
local WAIT_BEFORE_PUNCH = 1.25
local AUTO_FARM_RETRY = 2
local BATTLE_WAIT_TIMEOUT = 60
local HOME_RESTART_DELAY = 25
local FOLLOWER_WAIT_TIMEOUT = 12
local FOLLOWER_MAX_DISTANCE = 220
local FOLLOWER_MIN_CLOSE = 80
local FOLLOWER_SETTLE_TIME = 1

local state = {
	running = true,
	busy = false,
	runId = 0,
	autoFarm = false,
	autoFarmRunId = 0,
	autoSummon = false,
	autoSummonRunId = 0,
	autoSummonHeartbeat = 0,
	autoEquipBest = false,
	autoEquipBestRunId = 0,
	antiAfk = false,
	antiAfkRunId = 0,
	zone = nil,
	rarityLabels = {},
	tierSet = {},
	tierByLabel = {},
}

local runAutoFarm = nil
local runAutoSummon = nil
local runAutoEquipBest = nil
local antiAfkConnection = nil

local soulQueue = {}

SoulRemote.OnClientEvent:Connect(function(action, id, data)
	if action == "add" and id ~= nil and type(data) == "table" then
		soulQueue[id] = {
			id = id,
			kind = data.kind,
			pos = data.pos,
			firstSeen = os.clock(),
			lastAttempt = 0,
			attempts = 0,
		}
	elseif action == "remove" and id ~= nil then
		soulQueue[id] = nil
	end
end)

local latestAnnouncement = nil
local announcementHistory = {}
local announcedKinds = {}

AnnounceRemote.OnClientEvent:Connect(function(info)
	if type(info) ~= "table" then
		return
	end

	local entry = {
		rarity = info.rarity,
		zoneNum = info.zoneNum,
		zone = info.zone,
		kind = info.kind,
		id = info.id,
		size = info.size,
		received = os.clock(),
	}

	latestAnnouncement = entry
	table.insert(announcementHistory, entry)
	if #announcementHistory > 80 then
		table.remove(announcementHistory, 1)
	end

	if entry.kind then
		announcedKinds[entry.kind] = entry
	end
end)

local function getCharacter()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	if character and humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return character, humanoid, rootPart
	end

	return nil
end

local function isNightTime()
	return Workspace:GetAttribute("Night") == true
end

local function hasPetSouls()
	local souls = Workspace:FindFirstChild("MySouls")
	return souls ~= nil and #souls:GetChildren() > 0
end

local function zoneIdAt(position)
	for _, zone in ipairs(Config.Zones) do
		if position.Z <= zone.ZMax and position.Z > zone.ZMin then
			return zone.Id
		end
	end

	return Config.Zones[1].Id
end

local function isInZone(zone)
	local _, _, rootPart = getCharacter()
	if not rootPart or LocalPlayer:GetAttribute("Zone") ~= zone.Id then
		return false
	end

	return zoneIdAt(rootPart.Position) == zone.Id
end

local function getRarityChoices(zone)
	local options = {}
	local tierByLabel = {}

	if not zone then
		return options, tierByLabel
	end

	local ladder = Config.RarityLadder and (Config.RarityLadder[zone.Index] or Config.RarityLadder[1]) or {}

	for tier, label in pairs(ladder) do
		local pool = zone.Pools and zone.Pools[tier]
		if pool and #pool > 0 then
			tierByLabel[label] = tier
		end
	end

	local bossPool = zone.Pools and zone.Pools.Boss
	if bossPool and #bossPool > 0 then
		tierByLabel.Boss = "Boss"
	end

	local added = {}
	for _, label in ipairs(Config.RarityOrder or {}) do
		if tierByLabel[label] then
			table.insert(options, label)
			added[label] = true
		end
	end

	local extras = {}
	for label in pairs(tierByLabel) do
		if not added[label] then
			table.insert(extras, label)
		end
	end
	table.sort(extras)

	for _, label in ipairs(extras) do
		table.insert(options, label)
	end

	if #options == 0 then
		options = { "Common" }
		tierByLabel.Common = "Easy"
	end

	return options, tierByLabel
end

local function announcementMatches(entry, zone, rarityLabels)
	if not entry or not zone or not rarityLabels then
		return false
	end

	if entry.zoneNum and tonumber(entry.zoneNum) ~= zone.Index then
		return false
	end

	if not entry.zoneNum and entry.zone then
		local announcedZone = tostring(entry.zone):lower():gsub("^the ", "")
		local selectedZone = tostring(zone.Name or ""):lower():gsub("^the ", "")
		if announcedZone ~= selectedZone then
			return false
		end
	end

	for _, label in ipairs(rarityLabels) do
		if entry.rarity == label then
			return true
		end
	end

	return false
end

local function recentAnnouncement(zone, rarityLabels, since)
	for index = #announcementHistory, 1, -1 do
		local entry = announcementHistory[index]
		if entry.received < since then
			break
		end

		if announcementMatches(entry, zone, rarityLabels) then
			return entry
		end
	end

	return nil
end

local function getZoneFolder(zone)
	local zones = Workspace:FindFirstChild("Zones")
	if not zones then
		return nil
	end

	if zone.Folder then
		local direct = zones:FindFirstChild(zone.Folder)
		if direct then
			return direct
		end
	end

	for _, child in ipairs(zones:GetChildren()) do
		if child.Name:match("^" .. zone.Id .. "_") or child.Name == zone.Id then
			return child
		end
	end

	return nil
end

local function getZoneSpawnPoints(zone)
	local zoneFolder = getZoneFolder(zone)
	if not zoneFolder then
		return {}
	end

	local spawnFolder = zoneFolder:FindFirstChild("CreatureSpawns")
	local points = {}

	if spawnFolder then
		for _, spawn in ipairs(spawnFolder:GetChildren()) do
			if spawn:IsA("BasePart") then
				table.insert(points, spawn)
			end
		end
	end

	if #points == 0 then
		local zoneSpawn = zoneFolder:FindFirstChild("SpawnLocation", true)
		if zoneSpawn and zoneSpawn:IsA("BasePart") then
			table.insert(points, zoneSpawn)
		end
	end

	return points
end

local function isValidTarget(target, zoneId, tierSet)
	if not target or not target:IsA("Model") or target.Parent ~= WildCreatures then
		return false
	end

	if target:GetAttribute("Zone") ~= zoneId then
		return false
	end

	local tier = target:GetAttribute("Tier")
	if not tier or not tierSet[tier] then
		return false
	end

	if (target:GetAttribute("HP") or 0) <= 0 then
		return false
	end

	local ownerId = target:GetAttribute("OwnerId")
	if ownerId and ownerId ~= LocalPlayer.UserId then
		return false
	end

	return target.PrimaryPart ~= nil
end

local function isAnnouncedTarget(creature, zoneId, tierSet)
	local kind = creature:GetAttribute("Kind")
	local entry = kind and announcedKinds[kind]
	if not entry or os.clock() - entry.received > 45 then
		return false
	end

	local zone = state.zone
	if not zone or zone.Id ~= zoneId then
		return false
	end

	if entry.zoneNum and tonumber(entry.zoneNum) ~= zone.Index then
		return false
	end

	local tier = state.tierByLabel[entry.rarity]
	return tier ~= nil and tierSet[tier] == true
end

local function findTarget(zoneId, tierSet, referencePosition)
	local closestTarget = nil
	local closestDistance = math.huge
	local closestAnnounced = false

	for _, creature in ipairs(WildCreatures:GetChildren()) do
		if isValidTarget(creature, zoneId, tierSet) then
			local distance = referencePosition
				and (creature.PrimaryPart.Position - referencePosition).Magnitude
				or 0
			local announced = isAnnouncedTarget(creature, zoneId, tierSet)

			if (announced and not closestAnnounced)
				or (announced == closestAnnounced and distance < closestDistance)
			then
				closestTarget = creature
				closestDistance = distance
				closestAnnounced = announced
			end
		end
	end

	return closestTarget
end

local zoneOptions = {}
local zonesByOption = {}
local defaultZoneOption = nil
local currentZoneId = nil

do
	local _, _, rootPart = getCharacter()
	if rootPart then
		currentZoneId = LocalPlayer:GetAttribute("Zone") or zoneIdAt(rootPart.Position)
	end
end

for index, zone in ipairs(Config.Zones) do
	local displayName = (zone.Name or zone.Id):gsub("^the ", "")
	local option = string.format("Zone %d - %s", index, displayName)
	table.insert(zoneOptions, option)
	zonesByOption[option] = zone

	if zone.Id == currentZoneId then
		defaultZoneOption = option
	end
end

defaultZoneOption = defaultZoneOption or zoneOptions[1]
state.zone = zonesByOption[defaultZoneOption]

local initialRarities, initialTierByLabel = getRarityChoices(state.zone)
local initialLabel = initialRarities[1] or "Common"
local initialTier = initialTierByLabel[initialLabel] or "Easy"
state.rarityLabels = { initialLabel }
state.tierByLabel = initialTierByLabel
state.tierSet = { [initialTier] = true }

local Window = BPUI:CreateWindow({
	Title = "Pet Army Helper",
	Subtitle = "Zone Battle",
	Icon = "paw-print",
	ConfigFolder = "PetArmyHelper",
	CloseBehavior = "Hide",
	OnDestroy = function()
		state.running = false
		state.autoFarm = false
		state.autoFarmRunId += 1
		state.autoSummon = false
		state.autoSummonRunId += 1
		state.autoEquipBest = false
		state.autoEquipBestRunId += 1
		state.antiAfk = false
		state.antiAfkRunId += 1
		if antiAfkConnection then
			pcall(function()
				antiAfkConnection:Disconnect()
			end)
			antiAfkConnection = nil
		end
		state.runId += 1
		state.busy = false
	end,
})

local Main = Window:CreateTab({ Name = "Main", Icon = "home" })
local BattleSection = Main:CreateSection("Battle Target")
local status = BattleSection:AddParagraph({
	Title = "Status",
	Content = "Choose a zone and one or more rarities, then enable Auto Farm below.",
})

local rarityDropdown = nil
local autoSummonToggle = nil
local antiAfkToggle = nil

local function setStatus(message)
	if state.running then
		status:SetContent(message)
	end
end

local function notify(title, content, notificationType)
	BPUI:Notify({
		Title = title,
		Content = content,
		Type = notificationType or "Info",
		Duration = 4,
	})
end

local function antiAfkPulse()
	pcall(function()
		local virtualUser = game:GetService("VirtualUser")
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.new(0, 0))
	end)
end

local function setAntiAfk(enabled)
	state.antiAfk = enabled
	state.antiAfkRunId += 1
	local generation = state.antiAfkRunId

	if antiAfkConnection then
		pcall(function()
			antiAfkConnection:Disconnect()
		end)
		antiAfkConnection = nil
	end

	if not enabled then
		return
	end

	antiAfkConnection = LocalPlayer.Idled:Connect(function()
		antiAfkPulse()
	end)

	task.spawn(function()
		while state.running and state.antiAfk and state.antiAfkRunId == generation do
			task.wait(75)
			if state.running and state.antiAfk and state.antiAfkRunId == generation then
				antiAfkPulse()
			end
		end
	end)
end

BattleSection:AddToggle({
	Name = "Auto Farm",
	Description = "Continuously find and punch the selected zone and rarities.",
	Default = false,
	Flag = "AutoFarm",
	Callback = function(enabled)
		state.autoFarm = enabled
		state.autoFarmRunId += 1
		local generation = state.autoFarmRunId

		if enabled then
			setStatus("Auto Farm started.")
			task.spawn(function()
				local deadline = os.clock() + 10
				while not runAutoFarm and state.autoFarm and os.clock() < deadline do
					task.wait(0.05)
				end

				if runAutoFarm and state.autoFarm and state.autoFarmRunId == generation then
					runAutoFarm(generation)
				end
			end)
		else
			state.runId += 1
			state.busy = false
			setStatus("Auto Farm stopped.")
		end
	end,
})

autoSummonToggle = BattleSection:AddToggle({
	Name = "Auto Summon",
	Description = "Automatically summon every new pet soul.",
	Default = false,
	Flag = "AutoSummon",
	Callback = function(enabled)
		state.autoSummon = enabled
		state.autoSummonRunId += 1
		local generation = state.autoSummonRunId

		if enabled then
			state.autoSummonHeartbeat = os.clock()
			setStatus("Auto Summon enabled.")
			task.spawn(function()
				local deadline = os.clock() + 10
				while not runAutoSummon and state.autoSummon and os.clock() < deadline do
					task.wait(0.05)
				end

				if runAutoSummon and state.autoSummon and state.autoSummonRunId == generation then
					runAutoSummon(generation)
				end
			end)
		else
			setStatus("Auto Summon disabled.")
		end
	end,
})

BattleSection:AddToggle({
	Name = "Auto Equip Best",
	Description = "Automatically equip your strongest available army.",
	Default = false,
	Flag = "AutoEquipBest",
	Callback = function(enabled)
		state.autoEquipBest = enabled
		state.autoEquipBestRunId += 1
		local generation = state.autoEquipBestRunId

		if enabled then
			setStatus("Auto Equip Best enabled.")
			task.spawn(function()
				local deadline = os.clock() + 10
				while not runAutoEquipBest and state.autoEquipBest and os.clock() < deadline do
					task.wait(0.05)
				end

				if runAutoEquipBest and state.autoEquipBest and state.autoEquipBestRunId == generation then
					runAutoEquipBest(generation)
				end
			end)
		else
			setStatus("Auto Equip Best disabled.")
		end
	end,
})

local function isCurrentRun(runId)
	return state.running and state.runId == runId
end

local function getZonePad(zone)
	local camp = Workspace:FindFirstChild("Camp")
	local pads = camp and camp:FindFirstChild("Pads")
	if not pads then
		return nil
	end

	local directPad = pads:FindFirstChild("Pad_" .. zone.Id)
	if directPad then
		return directPad
	end

	for _, pad in ipairs(pads:GetChildren()) do
		if pad:GetAttribute("ZoneIndex") == zone.Index then
			return pad
		end
	end

	return nil
end

local function getPadTouch(pad)
	for _, descendant in ipairs(pad:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant:GetAttribute("PadZone") ~= nil then
			return descendant
		end
	end

	local fallback = pad:FindFirstChild("Touch", true)
	return fallback and fallback:IsA("BasePart") and fallback or nil
end

local function getPadCFrame(pad)
	local touch = getPadTouch(pad)
	if touch then
		return touch.CFrame
	end

	if pad:IsA("Model") then
		return pad:GetPivot() + Vector3.new(0, 3, 0)
	end

	local basePart = pad:FindFirstChildWhichIsA("BasePart", true)
	if basePart then
		return basePart.CFrame + Vector3.new(0, 3, 0)
	end

	return nil
end

local function travelViaPad(zone, runId)
	local pad = getZonePad(zone)
	if not pad then
		return false, "Could not find the pad for " .. (zone.Name or zone.Id) .. "."
	end

	local character, _, rootPart = getCharacter()
	if not character or not rootPart then
		return false, "Your character is not ready."
	end

	local touch = getPadTouch(pad)
	local padCFrame = getPadCFrame(pad)

	if not padCFrame or padCFrame.Position.Magnitude < 1 then
		local camp = Config.Camp or {}
		local campPoint = Vector3.new(camp.CenterX or 3000, 10, (camp.ZMin or 100) + 100)

		character:PivotTo(CFrame.new(campPoint))
		task.wait(0.25)
		pcall(function()
			Workspace:RequestStreamAroundAsync(campPoint)
		end)

		local streamDeadline = os.clock() + 5
		repeat
			task.wait(0.15)
			padCFrame = getPadCFrame(pad)
		until (padCFrame and padCFrame.Position.Magnitude >= 1) or os.clock() >= streamDeadline
	end

	if not padCFrame or padCFrame.Position.Magnitude < 1 then
		return false, "The pad for " .. (zone.Name or zone.Id) .. " did not load."
	end

	character:PivotTo(padCFrame)
	task.wait(0.25)
	pcall(function()
		Workspace:RequestStreamAroundAsync(padCFrame.Position)
	end)

	if not isCurrentRun(runId) then
		return false, "cancelled"
	end

	character, _, rootPart = getCharacter()
	if not character or not rootPart then
		return false, "Your character disappeared while using the pad."
	end

	if (rootPart.Position - padCFrame.Position).Magnitude > 12 then
		character:PivotTo(padCFrame)
		task.wait(0.15)
	end

	local touchDeadline = os.clock() + 3
	while not touch and os.clock() < touchDeadline do
		task.wait(0.1)
		touch = getPadTouch(pad)
	end

	if touch then
		character:PivotTo(touch.CFrame)
		task.wait(0.1)
	end

	PadStepRemote:FireServer()

	local deadline = os.clock() + PAD_STEP_TIMEOUT
	repeat
		if not isCurrentRun(runId) then
			return false, "cancelled"
		end

		if isInZone(zone) then
			return true
		end

		task.wait(0.2)
	until os.clock() >= deadline

	return false, "Pad step did not move you to " .. (zone.Name or zone.Id) .. ". Try again."
end

local function travelToZone(zone, runId)
	if isInZone(zone) then
		return true
	end

	return travelViaPad(zone, runId)
end

local function goHome()
	if LocalPlayer:GetAttribute("Home") == true then
		return true
	end

	setStatus("Returning home...")

	for attempt = 1, 2 do
		local success, result = pcall(function()
			return CampActionRemote:InvokeServer("home")
		end)

		if success and type(result) == "table" and result.ok == false and result.msg then
			setStatus("Returning home: " .. tostring(result.msg))
		end

		local deadline = os.clock() + 5
		repeat
			if LocalPlayer:GetAttribute("Home") == true then
				return true
			end
			task.wait(0.2)
		until os.clock() >= deadline

		if attempt == 1 then
			task.wait(1.5)
		end
	end

	return LocalPlayer:GetAttribute("Home") == true
end

local function simulateWalkTo(position, runId, maxSteps)
	local character, _, rootPart = getCharacter()
	if not character or not rootPart then
		return false
	end

	local steps = 0
	while steps < (maxSteps or 10) do
		if not isCurrentRun(runId) then
			return false
		end

		local current = rootPart.Position
		local flatDelta = Vector3.new(position.X - current.X, 0, position.Z - current.Z)
		if flatDelta.Magnitude < 2 then
			break
		end

		local nextPosition = current + flatDelta.Unit * math.min(4, flatDelta.Magnitude)
		character:PivotTo(CFrame.lookAt(
			Vector3.new(nextPosition.X, current.Y, nextPosition.Z),
			Vector3.new(position.X, current.Y, position.Z)
		))

		steps += 1
		if steps % 3 == 0 then
			pcall(function()
				Workspace:RequestStreamAroundAsync(nextPosition)
			end)
		end

		task.wait(0.12)
	end

	return true
end

local function getSpawnByName(spawnFolder, name)
	if not spawnFolder then
		return nil
	end

	for _, child in ipairs(spawnFolder:GetChildren()) do
		if child.Name == name and child:IsA("BasePart") then
			return child
		end
	end

	return nil
end

local function ensureSpawnsRendered(zone, runId)
	local spawnFolder = nil
	local easySpawn = nil
	local deadline = os.clock() + 5

	repeat
		local zoneFolder = getZoneFolder(zone)
		spawnFolder = zoneFolder and zoneFolder:FindFirstChild("CreatureSpawns")
		if getSpawnByName(spawnFolder, "HardSpawn") then
			return true
		end

		easySpawn = getSpawnByName(spawnFolder, "EasySpawn")
		if easySpawn then
			break
		end

		task.wait(0.15)
	until not isCurrentRun(runId) or os.clock() >= deadline

	if not easySpawn then
		return false
	end

	local character = getCharacter()
	if not character then
		return false
	end

	setStatus("Moving to EasySpawn...")
	character:PivotTo(easySpawn.CFrame + Vector3.new(0, 4, 0))
	pcall(function()
		Workspace:RequestStreamAroundAsync(easySpawn.Position)
	end)
	task.wait(0.4)

	setStatus("Waiting for HardSpawn to render...")
	deadline = os.clock() + 10
	local nextPing = 0

	while isCurrentRun(runId) and os.clock() < deadline do
		local zoneFolder = getZoneFolder(zone)
		spawnFolder = zoneFolder and zoneFolder:FindFirstChild("CreatureSpawns")
		if getSpawnByName(spawnFolder, "HardSpawn") then
			setStatus("HardSpawn rendered. Starting target search...")
			task.wait(0.4)
			return true
		end

		if os.clock() >= nextPing then
			nextPing = os.clock() + 1
			pcall(function()
				Workspace:RequestStreamAroundAsync(easySpawn.Position)
			end)
		end

		task.wait(0.2)
	end

	return false
end

local function streamScanZone(zone, tierSet, runId)
	local queue = {}
	local seen = {}
	local areaAdded = false

	local function addPosition(position)
		local key = string.format("%.0f:%.0f", position.X, position.Z)
		if not seen[key] then
			seen[key] = true
			table.insert(queue, position)
		end
	end

	local function addSpawnPoints()
		for _, spawn in ipairs(getZoneSpawnPoints(zone)) do
			addPosition(spawn.Position)
		end
	end

	local function addAreaSamples()
		if areaAdded then
			return
		end
		areaAdded = true

		local _, _, rootPart = getCharacter()
		local baseY = rootPart and rootPart.Position.Y or 0
		local spawnPoints = getZoneSpawnPoints(zone)
		local minX = rootPart and rootPart.Position.X - 700 or -700
		local maxX = rootPart and rootPart.Position.X + 700 or 700

		if #spawnPoints > 0 then
			minX = math.huge
			maxX = -math.huge
			for _, spawn in ipairs(spawnPoints) do
				minX = math.min(minX, spawn.Position.X)
				maxX = math.max(maxX, spawn.Position.X)
			end
			minX -= 300
			maxX += 300
		end

		local xs = { minX, (minX + maxX) / 2, maxX }
		for z = zone.ZMax - 200, zone.ZMin + 200, -550 do
			for _, x in ipairs(xs) do
				addPosition(Vector3.new(x, baseY, z))
			end
		end
	end

	addSpawnPoints()

	local deadline = os.clock() + 18
	local attempts = 0

	while attempts < 32 and os.clock() < deadline do
		if not isCurrentRun(runId) then
			return nil
		end

		if #queue == 0 then
			addAreaSamples()
			if #queue == 0 then
				break
			end
		end

		local position = table.remove(queue, 1)
		attempts += 1

		pcall(function()
			Workspace:RequestStreamAroundAsync(position)
		end)
		task.wait(0.3)

		local _, _, rootPart = getCharacter()
		local target = findTarget(zone.Id, tierSet, rootPart and rootPart.Position)
		if target then
			return target
		end

		addSpawnPoints()
	end

	local _, _, rootPart = getCharacter()
	return findTarget(zone.Id, tierSet, rootPart and rootPart.Position)
end

local function warmUpZone(zone, tierSet, runId)
	local _, _, rootPart = getCharacter()
	if not rootPart then
		return nil
	end

	if not ensureSpawnsRendered(zone, runId) then
		return nil
	end

	setStatus("Streaming zone areas to find the selected rarity...")
	local target = streamScanZone(zone, tierSet, runId)
	if target then
		return target
	end

	local startPosition = rootPart.Position
	local destination = Vector3.new(startPosition.X, startPosition.Y, (zone.ZMin + zone.ZMax) / 2)
	local bestDistance = 120

	for _, spawn in ipairs(getZoneSpawnPoints(zone)) do
		local delta = spawn.Position - startPosition
		local distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			destination = spawn.Position
		end
	end

	simulateWalkTo(destination, runId, 10)
	task.wait(0.35)

	local _, _, currentRoot = getCharacter()
	return findTarget(zone.Id, tierSet, currentRoot and currentRoot.Position)
end

local function waitForTarget(zoneId, tierSet, runId)
	local deadline = os.clock() + ZONE_LOAD_TIMEOUT

	repeat
		if not isCurrentRun(runId) then
			return nil, "cancelled"
		end

		if isNightTime() then
			return nil, "night"
		end

		local _, _, rootPart = getCharacter()
		if not rootPart or LocalPlayer:GetAttribute("Zone") ~= zoneId or zoneIdAt(rootPart.Position) ~= zoneId then
			return nil, "leftZone"
		end

		local target = findTarget(zoneId, tierSet, rootPart.Position)
		if target then
			return target, nil
		end

		task.wait(0.25)
	until os.clock() >= deadline

	return nil, "timeout"
end

local function teleportToTarget(target, runId)
	local character = getCharacter()
	local targetPart = target and target.PrimaryPart
	if not character or not targetPart then
		return false
	end

	local targetPosition = targetPart.Position
	local distance = math.clamp(targetPart.Size.Z / 2 + 3, 5, 10)
	local destination = targetPosition + targetPart.CFrame.LookVector * distance + Vector3.new(0, 2, 0)
	character:PivotTo(CFrame.lookAt(destination, targetPosition))

	local deadline = os.clock() + TARGET_LOAD_TIMEOUT
	repeat
		if not isCurrentRun(runId) then
			return false
		end

		character = getCharacter()
		if character and target.Parent and target.PrimaryPart then
			task.wait(WAIT_BEFORE_PUNCH)
			return isCurrentRun(runId) and getCharacter() ~= nil and target.Parent ~= nil and target.PrimaryPart ~= nil
		end
		task.wait(0.1)
	until os.clock() >= deadline

	return false
end

local function getFollowerDistances(referencePosition)
	local folder = Workspace:FindFirstChild("Followers")
	if not folder then
		return 0, math.huge, math.huge
	end

	local count = 0
	local closest = math.huge
	local farthest = 0

	for _, follower in ipairs(folder:GetChildren()) do
		if follower:IsA("Model") and follower:GetAttribute("Owner") == LocalPlayer.UserId and (follower:GetAttribute("HP") or 0) > 0 then
			local rootPart = follower.PrimaryPart or follower:FindFirstChild("HumanoidRootPart")
			if rootPart and rootPart:IsA("BasePart") then
				count += 1
				local distance = (rootPart.Position - referencePosition).Magnitude
				closest = math.min(closest, distance)
				farthest = math.max(farthest, distance)
			end
		end
	end

	return count, closest, farthest
end

local function waitForFollowers(runId, isAuto)
	local deadline = os.clock() + FOLLOWER_WAIT_TIMEOUT
	local stableSince = nil
	local lastCount = -1

	repeat
		if not isCurrentRun(runId) then
			return false, "cancelled"
		end

		if isNightTime() then
			return false, "Night started. Waiting for daybreak."
		end

		local _, humanoid, rootPart = getCharacter()
		if not humanoid or not rootPart or humanoid.Health <= 0 then
			return false, "Your character fainted before the battle started."
		end

		local count, closest, farthest = getFollowerDistances(rootPart.Position)
		if count > 0 and count ~= lastCount then
			lastCount = count
			stableSince = nil
		end

		if count > 0 then
			setStatus(string.format(
				"%sWaiting for followers (%d, near %.0f, far %.0f)...",
				isAuto and "Auto Farm: " or "",
				count,
				closest,
				farthest
			))
		else
			setStatus(string.format("%sWaiting for followers to appear...", isAuto and "Auto Farm: " or ""))
		end

		if count > 0 and farthest <= FOLLOWER_MAX_DISTANCE and closest <= FOLLOWER_MIN_CLOSE then
			stableSince = stableSince or os.clock()
			if os.clock() - stableSince >= FOLLOWER_SETTLE_TIME then
				return true
			end
		else
			stableSince = nil
		end

		task.wait(0.25)
	until os.clock() >= deadline

	return false, "Your followers did not catch up. The punch was cancelled."
end

local function farmOnce(isAuto)
	if state.busy then
		return false, nil, state.runId, "busy"
	end

	local zone = state.zone
	local tierSet = state.tierSet
	local rarityLabels = state.rarityLabels
	if not zone or #rarityLabels == 0 or next(tierSet) == nil then
		return false, nil, state.runId, "Choose a zone and at least one rarity first."
	end

	local rarityText = table.concat(rarityLabels, ", ")

	state.busy = true
	state.runId += 1
	local runId = state.runId

	local function fail(message, notificationType)
		state.busy = false
		setStatus(message)
		if not isAuto then
			notify("Battle not started", message, notificationType or "Error")
		end
		return false, nil, runId, message
	end

	setStatus(string.format("%sUsing the pad to travel to %s...", isAuto and "Auto Farm: " or "", zone.Name or zone.Id))

	local ok, err = travelToZone(zone, runId)
	if not ok then
		if err == "cancelled" then
			state.busy = false
			return false, nil, runId, err
		end
		return fail(err)
	end

	local zoneViewDeadline = os.clock() + 3
	while isCurrentRun(runId) and os.clock() < zoneViewDeadline do
		local zoneView = tostring(LocalPlayer:GetAttribute("ZoneView") or "")
		if zoneView == tostring(zone.Index) or zoneView == zone.Id then
			break
		end
		task.wait(0.15)
	end

	task.wait(0.5)
	if not isCurrentRun(runId) then
		state.busy = false
		return false, nil, runId, "cancelled"
	end

	setStatus(string.format("%sWalking in %s to render %s...", isAuto and "Auto Farm: " or "", zone.Name or zone.Id, rarityText))
	local _, _, immediateRoot = getCharacter()
	local target = immediateRoot and findTarget(zone.Id, tierSet, immediateRoot.Position) or nil

	if not target then
		target = warmUpZone(zone, tierSet, runId)
	end

	if not isCurrentRun(runId) then
		state.busy = false
		return false, nil, runId, "cancelled"
	end

	if not target then
		setStatus(string.format("%sLooking for %s in %s...", isAuto and "Auto Farm: " or "", rarityText, zone.Name or zone.Id))
	end

	local waitError = nil
	if not target then
		target, waitError = waitForTarget(zone.Id, tierSet, runId)
	end

	if not isCurrentRun(runId) then
		state.busy = false
		return false, nil, runId, "cancelled"
	end

	if not target then
		if waitError == "night" then
			return fail("Night started. Waiting for daybreak.", "Warning")
		end

		if waitError == "leftZone" and LocalPlayer:GetAttribute("Home") ~= true then
			return fail("Your character left the selected zone. Please try again.", "Warning")
		end

		local message = string.format("No available pet matching %s was found in %s.", rarityText, zone.Name or zone.Id)
		if goHome() then
			state.busy = false
			setStatus(message .. " Returned home and waiting for the next cycle.")
			return false, nil, runId, "__HOME__"
		end

		return fail(message .. " Could not return home.", "Warning")
	end

	local petName = target:GetAttribute("DisplayName") or target.Name
	local petTier = target:GetAttribute("Tier")
	local petRarity = "Selected"
	for label, tier in pairs(state.tierByLabel) do
		if tier == petTier then
			petRarity = label
			break
		end
	end

	setStatus(string.format("%sFound %s (%s). Teleporting to it...", isAuto and "Auto Farm: " or "", petName, petRarity))
	if not teleportToTarget(target, runId) then
		return fail("The pet or your character disappeared before the punch.")
	end

	if not isCurrentRun(runId) then
		state.busy = false
		return false, nil, runId, "cancelled"
	end

	local followersReady, followerError = waitForFollowers(runId, isAuto)
	if not followersReady then
		if followerError == "cancelled" then
			state.busy = false
			return false, nil, runId, followerError
		end
		return fail(followerError, "Warning")
	end

	if not isCurrentRun(runId) then
		state.busy = false
		return false, nil, runId, "cancelled"
	end

	if not isValidTarget(target, zone.Id, tierSet) then
		return fail("The selected pet is no longer available. Please try again.", "Warning")
	end

	PunchRemote:FireServer(target)
	target:SetAttribute("_myPunchAt", os.clock())
	state.busy = false

	setStatus(string.format("%sPunched %s (%s).", isAuto and "Auto Farm: " or "", petName, petRarity))
	if not isAuto then
		notify("Battle started", petName .. " (" .. petRarity .. ")", "Success")
	end

	return true, target, runId
end

local function waitForBattleEnd(target, runId)
	local deadline = os.clock() + BATTLE_WAIT_TIMEOUT
	local lastUpdate = 0
	local targetName = target:GetAttribute("DisplayName") or target.Name

	while state.running and state.autoFarm and state.runId == runId do
		local hp = target:GetAttribute("HP") or 0
		local maxHp = target:GetAttribute("MaxHP") or 0

		if target.Parent ~= WildCreatures or hp <= 0 or hasPetSouls() then
			return true
		end

		if isNightTime() then
			return false
		end

		if os.clock() - lastUpdate >= 1 then
			lastUpdate = os.clock()
			local percent = if maxHp > 0 then math.clamp(math.floor((hp / maxHp) * 100), 0, 100) else 0
			setStatus(string.format("Auto Farm: fighting %s (%d%% HP)...", targetName, percent))
		end

		if os.clock() >= deadline then
			return false
		end

		task.wait(0.5)
	end

	return false
end

local function waitAtHome(generation)
	local started = os.clock()

	while state.running and state.autoFarm and state.autoFarmRunId == generation do
		if isNightTime() then
			return true
		end

		local announcement = recentAnnouncement(state.zone, state.rarityLabels, started)
		if announcement then
			setStatus(string.format(
				"Auto Farm: announced %s in %s. Going to zone...",
				tostring(announcement.rarity),
				tostring(announcement.zone or state.zone.Name or state.zone.Id)
			))
			task.wait(0.5)
			return true
		end

		local remaining = math.max(0, HOME_RESTART_DELAY - (os.clock() - started))
		if remaining <= 0 then
			return true
		end

		setStatus(string.format("Auto Farm: at home, waiting %.0fs for a matching announcement...", remaining))
		task.wait(0.5)
	end

	return false
end

runAutoFarm = function(generation)
	while state.running and state.autoFarm and state.autoFarmRunId == generation do
		while state.running and state.autoFarm and state.autoFarmRunId == generation and isNightTime() do
			setStatus("Auto Farm: night time. Waiting for daybreak...")
			state.busy = false
			task.wait(1)
		end

		if not state.running or not state.autoFarm or state.autoFarmRunId ~= generation then
			break
		end

		while state.running
			and state.autoFarm
			and state.autoFarmRunId == generation
			and state.autoSummon
			and hasPetSouls()
		do
			setStatus("Auto Farm: waiting for Auto Summon to finish...")
			state.busy = false
			task.wait(0.5)
		end

		if not state.running or not state.autoFarm or state.autoFarmRunId ~= generation then
			break
		end

		local petName = #state.rarityLabels > 0 and table.concat(state.rarityLabels, ", ") or "selected rarities"
		local ok, target, runId, farmError = farmOnce(true)

		if not state.running or not state.autoFarm or state.autoFarmRunId ~= generation then
			break
		end

		if ok and target then
			petName = target:GetAttribute("DisplayName") or target.Name
			setStatus("Auto Farm: waiting for the battle with " .. petName .. "...")
			waitForBattleEnd(target, runId)
			if state.running and state.autoFarm and state.autoFarmRunId == generation then
				task.wait(1)
			end
		elseif farmError == "__HOME__" then
			if not waitAtHome(generation) then
				break
			end
		else
			setStatus("Auto Farm: " .. tostring(farmError or "no target found") .. " Retrying...")
			task.wait(AUTO_FARM_RETRY)
		end
	end

	state.busy = false
end

local equipInProgress = false

local function equipBestNow()
	if equipInProgress then
		return false
	end

	equipInProgress = true
	local success, result = pcall(function()
		return ArmyActionRemote:InvokeServer("equipBest")
	end)
	equipInProgress = false

	if not success then
		return false, tostring(result)
	end

	if type(result) == "table" and result.ok == false then
		return false, result.msg
	end

	return true
end

runAutoEquipBest = function(generation)
	local lastError = nil

	while state.running and state.autoEquipBest and state.autoEquipBestRunId == generation do
		local ok, err = equipBestNow()
		if not ok and err and err ~= lastError then
			lastError = err
			setStatus("Auto Equip Best: " .. tostring(err))
		end

		local nextEquip = os.clock() + 5
		while state.running and state.autoEquipBest and state.autoEquipBestRunId == generation and os.clock() < nextEquip do
			task.wait(0.25)
		end
	end
end

local function getSummonButton()
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	local soulGui = playerGui and playerGui:FindFirstChild("SoulChoice")
	if not soulGui or not soulGui.Enabled then
		return nil
	end

	return soulGui:FindFirstChild("SummonBtn", true)
end

local function summonViaUI()
	local button = getSummonButton()
	if not button then
		return false
	end

	local fired = false
	local ok, connections = pcall(getconnections, button.Activated)
	if ok and type(connections) == "table" then
		for _, connection in ipairs(connections) do
			if connection.Enabled and type(connection.Function) == "function" then
				local called = pcall(connection.Function)
				fired = fired or called
			end
		end
	end

	if not fired and type(firesignal) == "function" then
		local called = pcall(firesignal, button.Activated)
		fired = fired or called
	end

	return fired
end

local function autoSummonLoop(generation)
	local modelFirstSeen = {}
	local modelLastAttempt = {}
	local modelAttempts = {}

	local function approachSoul(position)
		if not position then
			return
		end

		local character, _, rootPart = getCharacter()
		if not character or not rootPart then
			return
		end

		if (rootPart.Position - position).Magnitude <= 12 then
			return
		end

		character:PivotTo(CFrame.lookAt(
			position + Vector3.new(0, 4, 8),
			position
		))
		pcall(function()
			Workspace:RequestStreamAroundAsync(position)
		end)
		setStatus("Auto Summon: moving to soul...")
		task.wait(0.4)
	end

	while state.running and state.autoSummon and state.autoSummonRunId == generation do
		state.autoSummonHeartbeat = os.clock()
		local acted = false
		local now = os.clock()

		for model in pairs(modelFirstSeen) do
			if not model.Parent then
				modelFirstSeen[model] = nil
				modelLastAttempt[model] = nil
				modelAttempts[model] = nil
			end
		end

		for id, info in pairs(soulQueue) do
			if not state.running or not state.autoSummon or state.autoSummonRunId ~= generation then
				break
			end

			if now - info.firstSeen > 20 then
				soulQueue[id] = nil
			elseif now - info.firstSeen >= 1
				and now - info.lastAttempt >= 1.5
				and info.attempts < 6
			then
				info.attempts += 1
				info.lastAttempt = now

				approachSoul(info.pos)
				SoulChoiceRemote:FireServer(info.id, "summon")
				setStatus("Auto Summon: summoning " .. tostring(info.kind or id) .. "...")
				acted = true

				if state.autoEquipBest then
					task.spawn(equipBestNow)
				end

				task.wait(0.4)
				break
			end
		end

		if not acted then
			local souls = Workspace:FindFirstChild("MySouls")
			if souls then
				for _, soul in ipairs(souls:GetChildren()) do
					if not state.running or not state.autoSummon or state.autoSummonRunId ~= generation then
						break
					end

					local kind = soul.Name:match("^Soul_(.+)$")
					local soulRoot = soul.PrimaryPart or soul:FindFirstChild("SoulRoot", true)
					if kind and soulRoot then
						local key = soul
						local first = modelFirstSeen[key] or now
						local last = modelLastAttempt[key] or 0
						local attempts = modelAttempts[key] or 0
						modelFirstSeen[key] = first
						modelLastAttempt[key] = last
						modelAttempts[key] = attempts

						if now - first >= 1 and now - last >= 1.5 and attempts < 6 then
							modelAttempts[key] = attempts + 1
							modelLastAttempt[key] = now

							approachSoul(soulRoot.Position)
							local pressed = summonViaUI()
							if not pressed then
								task.wait(0.35)
								pressed = summonViaUI()
							end

							if pressed then
								setStatus("Auto Summon: pressed Summon for " .. kind .. ".")
								acted = true
								if state.autoEquipBest then
									task.spawn(equipBestNow)
								end
							else
								setStatus("Auto Summon: waiting for the Summon prompt...")
							end

							break
						end
					end
				end
			end
		end

		task.wait(acted and 0.25 or 0.5)
	end
end

runAutoSummon = function(generation)
	while state.running and state.autoSummon and state.autoSummonRunId == generation do
		local success, err = pcall(autoSummonLoop, generation)
		if success then
			break
		end

		setStatus("Auto Summon: recovered from an error, retrying...")
		warn("[PetArmyHelper] Auto Summon error: " .. tostring(err))
		task.wait(1)
	end
end

BattleSection:AddDropdown({
	Name = "Zone",
	Options = zoneOptions,
	Default = defaultZoneOption,
	Flag = "SelectedZone",
	Callback = function(option)
		local zone = zonesByOption[option]
		if not zone then
			return
		end

		state.zone = zone
		local options, tierByLabel = getRarityChoices(zone)
		local preferredLabels = {}
		local tierSet = {}

		for _, label in ipairs(state.rarityLabels) do
			local tier = tierByLabel[label]
			if tier then
				table.insert(preferredLabels, label)
				tierSet[tier] = true
			end
		end

		if #preferredLabels == 0 then
			local label = options[1]
			local tier = tierByLabel[label]
			if label and tier then
				preferredLabels = { label }
				tierSet[tier] = true
			end
		end

		state.rarityLabels = preferredLabels
		state.tierSet = tierSet
		state.tierByLabel = tierByLabel

		if rarityDropdown then
			rarityDropdown:Refresh(options, false)
			rarityDropdown:Set(preferredLabels, true)
		end
	end,
})

rarityDropdown = BattleSection:AddDropdown({
	Name = "Rarity",
	Description = "Select one or more rarities.",
	Options = initialRarities,
	Default = state.rarityLabels,
	Multi = true,
	Flag = "SelectedRarities",
	Callback = function(selection)
		local selected = if type(selection) == "table" then selection else { selection }
		local _, tierByLabel = getRarityChoices(state.zone)
		local labels = {}
		local tierSet = {}

		for _, label in ipairs(selected) do
			local tier = tierByLabel[label]
			if tier then
				table.insert(labels, label)
				tierSet[tier] = true
			end
		end

		state.rarityLabels = labels
		state.tierSet = tierSet
		state.tierByLabel = tierByLabel
	end,
})

task.spawn(function()
	local settingsTab = nil
	local deadline = os.clock() + 5

	repeat
		for _, tab in ipairs(Window._tabs or {}) do
			if tab._isSettings then
				settingsTab = tab
				break
			end
		end

		if not settingsTab then
			task.wait(0.1)
		end
	until settingsTab or not state.running or os.clock() >= deadline

	if settingsTab then
		local utility = settingsTab:CreateSection("Utility")
		antiAfkToggle = utility:AddToggle({
			Name = "Anti AFK",
			Description = "Prevents Roblox from kicking you for being idle.",
			Icon = "activity",
			Default = true,
			Flag = "AntiAFK",
			Callback = setAntiAfk,
		})
	end
end)

task.spawn(function()
	while state.running do
		task.wait(1)

		if antiAfkToggle then
			local enabled = antiAfkToggle.Value == true
			if enabled ~= state.antiAfk then
				setAntiAfk(enabled)
			end
		end

		if autoSummonToggle and autoSummonToggle.Value == true and state.running then
			local heartbeatAge = os.clock() - (state.autoSummonHeartbeat or 0)
			if not state.autoSummon or heartbeatAge > 12 then
				state.autoSummon = true
				state.autoSummonRunId += 1
				state.autoSummonHeartbeat = os.clock()
				local generation = state.autoSummonRunId

				if runAutoSummon then
					task.spawn(function()
						if state.running and state.autoSummon and state.autoSummonRunId == generation then
							runAutoSummon(generation)
						end
					end)
				end
			end
		end
	end
end)

Main:Select()
