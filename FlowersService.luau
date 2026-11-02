-- Connected Discord-GitHub

local Knit = require(game.ReplicatedStorage.Packages.Knit.Knit)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local SpawnPoints = workspace:FindFirstChild("SpawnPoints")
local PathPoints = workspace:FindFirstChild("PathPoints")

local SimplePath = require(ReplicatedStorage.Packages.SimplePath)
local Hitboxes = require(ReplicatedStorage.Shared.Hitboxes)
local Cooldowns = require(ReplicatedStorage.Shared.Cooldowns)
local Util = require(ReplicatedStorage.Shared.Util)
local Ragdoll = require(ReplicatedStorage.Shared.Ragdoll)

local FlowersService = Knit.CreateService{
	Name = "FlowersService",
	Client = {}
}

FlowersService.Settings = {
	ChaseDistance = 100,
	BaseWalkSpeed = 35,
	ChaseMultiplier = 1.7,
}

local Debug = false
local aiRunning = false
local CurrentState = "WANDER"
local currentTarget = nil

local flowers: Model = nil
local root = nil
local Humanoid = nil
local path = nil

local PunchAnimation = nil
local GrabAnimation = nil
local StunnedAnimation: AnimationTrack = nil

local grabDuration = 0.5
local pullSpeed = 100

local RECOMPUTE_DISTANCE = 6
local lastTargetPosition = nil
local flowersSpeedFolder = nil

-- Calculate speed using all multipliers
local function getFlowersSpeed()
	if not flowersSpeedFolder then
		return FlowersService.Settings.BaseWalkSpeed
	end

	local total = 1

	for _, value in pairs(flowersSpeedFolder:GetChildren()) do
		if value:IsA("NumberValue") then
			total *= value.Value
		end
	end

	return FlowersService.Settings.BaseWalkSpeed * total
end

-- Update walkspeed when multipliers change
local function setupSpeedFolder()
	flowersSpeedFolder = flowers:FindFirstChild("SpeedMultipliers")

	if not flowersSpeedFolder then
		flowersSpeedFolder = Instance.new("Folder")
		flowersSpeedFolder.Name = "SpeedMultipliers"
		flowersSpeedFolder.Parent = flowers
	end

	flowersSpeedFolder.ChildAdded:Connect(function(child)
		if child:IsA("NumberValue") then
			child.Changed:Connect(function()
				Humanoid.WalkSpeed = getFlowersSpeed()
			end)

			Humanoid.WalkSpeed = getFlowersSpeed()
		end
	end)

	flowersSpeedFolder.ChildRemoved:Connect(function()
		Humanoid.WalkSpeed = getFlowersSpeed()
	end)
end

function FlowersService:AddMultiplier(name: string, value: number, duration: number?, tweenTime: number?)
	if not flowersSpeedFolder then return end

	local existing = flowersSpeedFolder:FindFirstChild(name)

	if existing then
		if tweenTime then
			TweenService:Create(existing, TweenInfo.new(tweenTime), {Value = value}):Play()
		else
			existing.Value = value
		end
	else
		local newValue = Instance.new("NumberValue")
		newValue.Name = name
		newValue.Value = value
		newValue.Parent = flowersSpeedFolder
	end

	if duration then
		task.delay(duration, function()
			self:RemoveMultiplier(name, tweenTime)
		end)
	end
end

function FlowersService:RemoveMultiplier(name: string, tweenTime: number?)
	if not flowersSpeedFolder then return end

	local value = flowersSpeedFolder:FindFirstChild(name)
	if not value then return end

	if tweenTime then
		TweenService:Create(value, TweenInfo.new(tweenTime), {Value = 1}):Play()

		task.delay(tweenTime, function()
			if value and value.Parent then
				value:Destroy()
			end
		end)
	else
		value:Destroy()
	end
end

-- Find the nearest player or use the target override
function FlowersService:GetNearestPlayer(root)
	local overrideName = flowers and flowers:GetAttribute("TargetOverride")

	if overrideName then
		local overridePlayer = Players:FindFirstChild(overrideName)

		if overridePlayer and overridePlayer.Character then
			local hrp = overridePlayer.Character:FindFirstChild("HumanoidRootPart")

			if hrp then
				return overridePlayer, Util.Distance(root.Position, hrp.Position)
			end
		end

		flowers:SetAttribute("TargetOverride", nil)
	end

	local nearestPlayer, nearestDistance = nil, math.huge

	for _, player in pairs(Players:GetPlayers()) do
		local character = player.Character
		if not character then continue end

		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then continue end

		local distance = Util.Distance(root.Position, hrp.Position)

		if distance < nearestDistance then
			nearestPlayer = player
			nearestDistance = distance
		end
	end

	return nearestPlayer, nearestDistance
end

-- Stun Flowers and make it chase whoever stunned it
function FlowersService:Stun(duration: number, stunnerPlayer: Player?)
	if flowers:GetAttribute("Stunned") then return end

	flowers:SetAttribute("Stunned", true)

	StunnedAnimation.Looped = true
	StunnedAnimation:Play(0.125)

	self:AddMultiplier("Stun", 0, nil, 0.1)
	path:Stop()

	Cooldowns:Start(flowers, "Punch", duration)
	Cooldowns:Start(flowers, "Grab", duration)

	task.delay(duration, function()
		if not flowers or not flowers.Parent then return end

		flowers:SetAttribute("Stunned", false)

		self:RemoveMultiplier("Stun", 0.2)
		StunnedAnimation:Stop(0.125)

		if stunnerPlayer and stunnerPlayer.Character then
			local hrp = stunnerPlayer.Character:FindFirstChild("HumanoidRootPart")

			if hrp then
				CurrentState = "CHASE"
				lastTargetPosition = nil

				path:Run(hrp.Position)

				self:AddMultiplier("Chase", FlowersService.Settings.ChaseMultiplier, nil, 0.5)

				flowers:SetAttribute("TargetOverride", stunnerPlayer.Name)

				task.delay(10, function()
					flowers:SetAttribute("TargetOverride", nil)
				end)
			end
		end
	end)
end

function FlowersService:RandomSpawn()
	local spawns = SpawnPoints:GetChildren()
	return spawns[math.random(1, #spawns)]
end

function FlowersService:RandomPathPoint()
	local points = PathPoints:GetChildren()
	return points[math.random(1, #points)]
end

-- Grab players between 15 and 50 studs
function FlowersService:TryGrab()
	local player, distance = FlowersService:GetNearestPlayer(root)

	if distance < 15 or distance > 50 then return end
	if not Cooldowns:CanUse(flowers, "Grab") then return end

	Cooldowns:Start(flowers, "Grab", 8)
	Cooldowns:Start(flowers, "Punch", 1.5)

	self:AddMultiplier("GrabSlow", 0, nil, 0.1)
	GrabAnimation:Play(0.125)

	task.wait(0.25)

	Humanoid.AutoRotate = false

	Hitboxes:CreateHitbox(flowers, {
		Size = Vector3.new(6, 13, 70),
		CFrameOffset = CFrame.new(0, -1, -20),
		Damage = 0,
		Time = 0.4,
		Knockback = 0,
		HitMultiple = true,
		PredictVelocity = false,
		FriendlyFire = false,
		Hide = false,

		Connections = {
			Hit = function(target: Model)
				local targetPlayer = Players:GetPlayerFromCharacter(target)
				if not targetPlayer then return end

				local targetRoot = target:FindFirstChild("HumanoidRootPart")
				local targetHumanoid = target:FindFirstChildOfClass("Humanoid")

				if not targetRoot or not targetHumanoid then return end

				Ragdoll:Ragdoll(target, 1.5)

				-- Pull the player towards Flowers
				task.spawn(function()
					local startTime = tick()

					while tick() - startTime < grabDuration do
						if not targetRoot or not targetRoot.Parent then break end

						local direction = ((root.Position - Vector3.new(0, 3, 0)) - targetRoot.Position).Unit

						local attachment = Instance.new("Attachment")
						attachment.Parent = targetRoot

						local velocity = Instance.new("LinearVelocity")
						velocity.Attachment0 = attachment
						velocity.VectorVelocity = direction * pullSpeed
						velocity.MaxForce = math.huge
						velocity.RelativeTo = Enum.ActuatorRelativeTo.World
						velocity.Parent = targetRoot

						game:GetService("Debris"):AddItem(velocity, 0.05)
						game:GetService("Debris"):AddItem(attachment, 0.05)

						task.wait(0.05)
					end

					if targetHumanoid and targetHumanoid.Health > 0 then
						targetHumanoid:TakeDamage(15)
					end
				end)
			end,
		}
	})

	task.delay(0.6, function()
		self:RemoveMultiplier("GrabSlow", 0.2)
		Humanoid.AutoRotate = true
	end)
end

-- Punch nearby players, otherwise try grabbing
function FlowersService:TryAttack()
	local player, distance = FlowersService:GetNearestPlayer(root)

	if distance <= 10 then
		if not Cooldowns:CanUse(flowers, "Punch") then return end

		PunchAnimation:Play(0.125)

		Hitboxes:CreateHitbox(flowers, {
			Size = Vector3.new(4, 13, 8),
			CFrameOffset = CFrame.new(Vector3.new(0, -1, -1)),
			Damage = 20,
			Time = 0.3,
			Knockback = 30,
			HitMultiple = true,
			PredictVelocity = true,
			FriendlyFire = false,
			Hide = false,

			Connections = {
				Hit = function(target: Model) end,
			}
		})

		Cooldowns:Start(flowers, "Punch", 1.5)
	else
		FlowersService:TryGrab()
	end
end

-- Chase and wander states
local function enterChase()
	if CurrentState == "CHASE" then return end

	CurrentState = "CHASE"
	lastTargetPosition = nil

	FlowersService:AddMultiplier(
		"Chase",
		FlowersService.Settings.ChaseMultiplier,
		nil,
		0.5
	)
end

local function enterWander()
	if CurrentState == "WANDER" then return end

	CurrentState = "WANDER"
	lastTargetPosition = nil

	FlowersService:RemoveMultiplier("Chase", 0.5)
end

-- Only update the path when the player moves far enough
local function updateChase(player: Player?)
	if not player then return end

	local character = player.Character
	if not character then return end

	local targetRoot = character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end

	currentTarget = nil

	local ShouldRecompute = not lastTargetPosition
		or (targetRoot.Position - lastTargetPosition).Magnitude > RECOMPUTE_DISTANCE

	if ShouldRecompute then
		lastTargetPosition = targetRoot.Position
		path:Run(targetRoot.Position)
	end

	FlowersService:TryAttack()
end

-- Move between random path points
local function updateWander()
	if not currentTarget then
		currentTarget = FlowersService:RandomPathPoint()

		if currentTarget then
			path:Run(currentTarget.Position)
		end

		return
	end

	local Distance = (root.Position - currentTarget.Position).Magnitude
	if Distance >= 6 then return end

	currentTarget = FlowersService:RandomPathPoint()
	if not currentTarget then return end

	path:Run(currentTarget.Position)
end

-- Decide whether to chase or wander
local function updateAI()
	local player, distance = FlowersService:GetNearestPlayer(root)

	if player and distance < FlowersService.Settings.ChaseDistance then
		enterChase()
		updateChase(player)
		return
	end

	enterWander()
	updateWander()
end

local function runAI()
	while aiRunning do
		task.wait(0.25)
		updateAI()
	end
end

-- Set up the NPC
local function initializeFlowers()
	flowers = ReplicatedStorage:WaitForChild("Flowers")
	root = flowers.PrimaryPart
	path = SimplePath.new(flowers)
	Humanoid = flowers:FindFirstChild("Humanoid")

	PunchAnimation = Util.LoadAnimation(Humanoid, "119528894450443", Enum.AnimationPriority.Action)
	GrabAnimation = Util.LoadAnimation(Humanoid, "72069414099158", Enum.AnimationPriority.Action2)
	StunnedAnimation = Util.LoadAnimation(Humanoid, "86989799335770", Enum.AnimationPriority.Action4)

	setupSpeedFolder()

	Humanoid.WalkSpeed = FlowersService.Settings.BaseWalkSpeed
end

-- Pick another point when Flowers reaches its destination
local function onPathReached()
	if CurrentState ~= "WANDER" then return end

	currentTarget = FlowersService:RandomPathPoint()
	if not currentTarget then return end

	path:Run(currentTarget.Position)
end

-- Spawn Flowers at night
local function startAI()
	if aiRunning then return end

	aiRunning = true

	flowers.Parent = workspace
	path.Visualize = Debug

	task.spawn(runAI)
end

-- Despawn Flowers during the day
local function stopAI()
	if not aiRunning then return end

	aiRunning = false
	currentTarget = nil
	CurrentState = "WANDER"
	lastTargetPosition = nil

	FlowersService:RemoveMultiplier("Chase")
	path:Stop()

	flowers.Parent = ReplicatedStorage
end

-- Handle the day and night cycle
function FlowersService:KnitStart()
	initializeFlowers()

	local TimeCycle = Knit.GetService("TimeCycle")

	path.Reached:Connect(onPathReached)

	task.spawn(function()
		while true do
			task.wait(0.1)

			local cycle = TimeCycle.Client:GetCycle()

			if cycle == "Night" and not aiRunning then
				startAI()
				continue
			end

			if cycle == "Day" and aiRunning then
				stopAI()
			end
		end
	end)
end

return FlowersService
