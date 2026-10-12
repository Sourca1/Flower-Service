-- Connected Discord-GitHub
-- Dependencies used by the NPC for lifecycle management, pathfinding, combat,
-- cooldowns, distance checks, animation loading, and ragdoll behavior.
local Knit = require(game.ReplicatedStorage.Packages.Knit.Knit)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local SpawnPoints = workspace:FindFirstChild("SpawnPoints")
local PathPoints = workspace:FindFirstChild("PathPoints")
local TweenService = game:GetService("TweenService")
local SimplePath = require(ReplicatedStorage.Packages.SimplePath)
local Hitboxes = require(ReplicatedStorage.Shared.Hitboxes)
local Cooldowns = require(ReplicatedStorage.Shared.Cooldowns)
local Util = require(ReplicatedStorage.Shared.Util)
local Ragdoll = require(ReplicatedStorage.Shared.Ragdoll)

local FlowersService = Knit.CreateService{
	Name = "FlowersService",
	Client = {}
}

-- Central tuning values for the NPC. Chase speed is expressed as a multiplier so
-- temporary effects can be composed through the same movement modifier system.
FlowersService.Settings = {
	ChaseDistance = 100,
	BaseWalkSpeed = 35,
	ChaseMultiplier = 1.7, -- 35 * 1.7 = ~60 when chasing
}

-- Runtime state for the single Flowers NPC managed by this service. These
-- references are initialized in KnitStart and reused by the AI and attack logic.
local Debug = false
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

-- A chase path is only recomputed after the target has moved far enough from the
-- last requested destination. This avoids rebuilding a path every AI update.
local RECOMPUTE_DISTANCE = 6
local lastTargetPosition = nil
local flowersSpeedFolder = nil

-- Calculates the NPC's final speed by multiplying every active modifier together.
-- A value of 1 is neutral, values above 1 increase speed, and 0 fully stops movement.
-- This allows independent effects such as Chase, Stun, and GrabSlow to coexist.
local function getFlowersSpeed()
	if not flowersSpeedFolder then return FlowersService.Settings.BaseWalkSpeed end

	local total = 1
	for _, value in pairs(flowersSpeedFolder:GetChildren()) do
		if value:IsA("NumberValue") then
			total *= value.Value
		end
	end

	return FlowersService.Settings.BaseWalkSpeed * total
end

-- Creates the modifier container if it does not already exist and keeps
-- Humanoid.WalkSpeed synchronized whenever modifiers are added, removed, or changed.
local function setupSpeedFolder()
	flowersSpeedFolder = flowers:FindFirstChild("SpeedMultipliers")
	if not flowersSpeedFolder then
		flowersSpeedFolder = Instance.new("Folder")
		flowersSpeedFolder.Name = "SpeedMultipliers"
		flowersSpeedFolder.Parent = flowers
	end

	-- A modifier may be tweened after it is inserted, so changes to its value also
	-- trigger a complete speed recalculation rather than only reacting to insertion.
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

-- Adds or updates a named movement modifier. Naming modifiers prevents duplicate
-- effects from stacking accidentally, while duration allows temporary effects to
-- remove themselves through the same RemoveMultiplier path.
function FlowersService:AddMultiplier(name: string, value: number, duration: number?, tweenTime: number?)
	if not flowersSpeedFolder then return end
	local TweenService = game:GetService("TweenService")

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

-- Removes a movement modifier. When tweening is requested, the modifier first
-- returns to the neutral value of 1 so movement transitions smoothly before cleanup.
function FlowersService:RemoveMultiplier(name: string, tweenTime: number?)
	if not flowersSpeedFolder then return end
	local TweenService = game:GetService("TweenService")
	local value = flowersSpeedFolder:FindFirstChild(name)
	if not value then return end

	if tweenTime then
		TweenService:Create(value, TweenInfo.new(tweenTime), {Value = 1}):Play()
		task.delay(tweenTime, function()
			if value and value.Parent then value:Destroy() end
		end)
	else
		value:Destroy()
	end
end

-- Finds the active target for the NPC. A TargetOverride takes priority over normal
-- nearest-player selection so another system can temporarily force Flowers to focus
-- a specific player, such as the player responsible for stunning it.
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

		-- Invalid overrides are cleared so normal nearest-player targeting can resume.
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

-- Temporarily disables movement and both attacks. Once the stun expires, the NPC
-- can retaliate against the stunner by forcing a temporary target override and
-- immediately resuming chase behavior toward that player.
function FlowersService:Stun(duration: number, stunnerPlayer: Player?)
	if flowers:GetAttribute("Stunned") then return end

	flowers:SetAttribute("Stunned", true)
	StunnedAnimation.Looped = true
	StunnedAnimation:Play(0.125)
	self:AddMultiplier("Stun", 0, nil, 0.1)
	path:Stop()

	-- Extending both attack cooldowns prevents an attack sequence from starting while
	-- the NPC is immobilized, keeping movement and combat state consistent.
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

-- Map helpers used by the wandering behavior to choose random spawn/path locations.
function FlowersService:RandomSpawn()
	local spawns = SpawnPoints:GetChildren()
	return spawns[math.random(1, #spawns)]
end

function FlowersService:RandomPathPoint()
	local points = PathPoints:GetChildren()
	return points[math.random(1, #points)]
end

-- Attempts the ranged grab when the target is inside its intended distance band and
-- the ability is available. Punch is briefly locked as well so both attacks cannot
-- overlap while the grab startup and pull sequence are running.
function FlowersService:TryGrab()
	local player, distance = FlowersService:GetNearestPlayer(root)
	if distance < 15 or distance > 50 then return end
	if not Cooldowns:CanUse(flowers, "Grab") then return end

	Cooldowns:Start(flowers, "Grab", 8)
	Cooldowns:Start(flowers, "Punch", 1.5)
	self:AddMultiplier("GrabSlow", 0, nil, 0.1)
	GrabAnimation:Play(0.125)

	-- The startup delay gives the animation time to telegraph the grab before its
	-- hitbox becomes active.
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

				-- Repeated short-lived velocity constraints continually redirect the target
				-- toward Flowers during the pull window, then damage is applied at the end.
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

	-- Restore normal movement/rotation after the grab's active sequence finishes.
	task.delay(0.6, function()
		self:RemoveMultiplier("GrabSlow", 0.2)
		Humanoid.AutoRotate = true
	end)
end

-- Chooses between the close-range punch and the grab based on target distance.
-- The individual attack functions remain responsible for their own cooldown checks.
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


-- Tracks whether the main Flowers AI loop should currently be running.
-- Flowers only becomes active during the night.
local aiRunning = false

-- Switches Flowers into its chase state.
-- This only runs the transition logic once instead of reapplying
-- the chase multiplier every AI update.
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

-- Switches Flowers back into wandering.
-- Removes the chase speed bonus and clears the last chase destination.
local function enterWander()
	if CurrentState == "WANDER" then return end

	CurrentState = "WANDER"
	lastTargetPosition = nil

	FlowersService:RemoveMultiplier("Chase", 0.5)
end

-- Updates Flowers while chasing a player.
-- Paths are only recomputed when the target has moved far enough,
-- preventing unnecessary pathfinding requests every AI update.
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

-- Updates Flowers while wandering around the map.
-- A new path point is only selected when Flowers has no target
-- or reaches the current wander point.
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

-- Makes the high-level AI decision for this update.
-- Chase takes priority whenever a player is inside the aggro range;
-- otherwise Flowers returns to wandering.
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

-- Main AI update loop.
-- Runs at a lower frequency because target selection and pathfinding
-- do not need to run every frame.
local function runAI()
	while aiRunning do
		task.wait(0.25)
		updateAI()
	end
end

-- Initializes all runtime references used by Flowers.
-- Keeping this outside KnitStart prevents initialization from cluttering
-- the actual service startup logic.
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

-- Called whenever Flowers reaches its current path destination.
-- When wandering, reaching a destination immediately selects another
-- point so Flowers continuously moves around the map.
local function onPathReached()
	if CurrentState ~= "WANDER" then return end

	currentTarget = FlowersService:RandomPathPoint()
	if not currentTarget then return end

	path:Run(currentTarget.Position)
end

-- Activates Flowers when night begins and starts its AI loop.
local function startAI()
	if aiRunning then return end

	aiRunning = true

	flowers.Parent = workspace
	path.Visualize = Debug

	task.spawn(runAI)
end

-- Deactivates Flowers during the day and resets any temporary
-- navigation/chase state so the next night begins cleanly.
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

-- Starts the Flowers NPC system.
-- KnitStart now only handles initialization, event connections,
-- and deciding when the AI should start/stop.
function FlowersService:KnitStart()
	initializeFlowers()

	local TimeCycle = Knit.GetService("TimeCycle")

	path.Reached:Connect(onPathReached)

	task.spawn(function()
		while true do
			task.wait(0.1)

			local Cycle = TimeCycle.Client:GetCycle()

			if Cycle == "Night" and not aiRunning then
				startAI()
				continue
			end

			if Cycle == "Day" and aiRunning then
				stopAI()
			end
		end
	end)
end

-- Initializes the NPC and owns its main AI lifecycle. The outer loop watches the
-- day/night cycle, while the inner loop performs lower-frequency AI decisions only
-- while Flowers is active at night.
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
