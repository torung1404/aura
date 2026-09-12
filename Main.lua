-- Main.lua — Delta Executor remote entrypoint.
-- One Heartbeat owns movement; DODGE preempts COMBAT, DIRECT, PATH, RECOVERY, and EXPLORE.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local Stats = game:GetService("Stats")

local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
print("[AF] loaded")

local DEFAULT_CONFIG = {
	EnemyKeywords = { "enemy", "boss", "mob", "monster", "zombie", "deity", "volcano", "protector" },
	-- Summoned Ancient Spirit adds are intentionally never farm targets. The
	-- Ancient Enchanted Tree boss remains eligible.
	IgnoredTargetKeywords = { "ancient spirit" },
	BossKeywords = { "boss", "protector" },
	FarmRange = 500,
	TargetAcquireInterval = 1,
	GoalRefreshInterval = 0.15,
	TargetLockRangeMultiplier = 1.25,
	PreferredCombatDistance = 75,
	RetreatEnterDistance = 70,
	RetreatExitDistance = 75,
	AttackRange = 15,
	NormalSkillRange = 80,
	BossSkillRange = 100,
	-- The game grants roughly seven seconds of spawn protection. Use the first
	-- six seconds to reach a target without retreat/path state churn.
	RespawnRushDuration = 6,
	KiteDistance = 75,
	KiteHysteresis = 3,
	AttackCooldown = 0.12,
	QCooldownMin = 0.3,
	QCooldownMax = 0.5,
	ECooldown = 0.4,
	SkillQToolName = "Q",
	SkillEToolName = "E",
	UseTool = false,
	MovementSpeedMultiplier = 1.4,
	DirectReachedDistance = 0.75,
	DirectVerticalTolerance = 7,
	DirectDecisionInterval = 0.25,
	DirectGoalChangeDistance = 5,
	GroundProbeLift = 6,
	GroundProbeDepth = 140,
	GroundSupportDepth = 24,
	PathRebuildCooldown = 1.5,
	PathGoalChangeDistance = 9,
	WaypointReachedDistance = 3.5,
	WaypointTimeout = 6,
	AgentRadius = 2,
	AgentHeight = 5,
	WaypointSpacing = 5,
	MeaningfulProgressDistance = 1.5,
	ProgressCheckInterval = 0.25,
	-- At eight seconds without progress, rebuild a route before considering reset.
	RecoveryRefreshAt = 8,
	StuckPathRetryInterval = 3,
	-- Rebuild a route quickly when collision leaves horizontal velocity near zero.
	SlowMovementSpeedThreshold = 10,
	SlowMovementRepathDelay = 0.75,
	SlowMovementRepathCooldown = 2,
	RespawnStuckTime = 12,
	DetourProbeDistance = 13,
	DetourDuration = 1.5,
	DodgeEnabled = true,
	DodgeTriggerPadding = 2.5,
	DodgePreTriggerPadding = 3.5,
	DodgePlayerSafetyMargin = 1.5,
	DodgeLookaheadSeconds = 0.8,
	DodgeExitHysteresis = 0.25,
	DodgeSafePadding = 5,
	DodgeDetectionRadius = 60,
	DodgeRefreshInterval = 0.12,
	DodgeVerticalPadding = 6,
	DodgeCandidateCount = 8,
	DodgeCommitDuration = 0.35,
	DodgeEvaluationInterval = 0.08,
	DodgeRaycastBudget = 32,
	ExploreCandidateCount = 12,
	ExploreStepDistance = 28,
	ExploreReachedDistance = 2,
	ExploreCommitTime = 1.25,
	ExploreStartDelay = 0.9,
	ExploreReselectAfter = 3,
	ExploreMaxVerticalStep = 4.5,
	ExploreProbeSamples = 5,
	ExploreHistoryCellSize = 18,
	ExploreHistoryLimit = 20,
	ExploreRespawnStuckTime = 15,
	DescentMinDrop = 0.5,
	DescentFlatTolerance = 1.5,
	DescentRiseReleaseCount = 2,
	DebugTelemetry = false,
	AutoReplay = true,
	AutoStart = false,
}

local NavigationState = {
	IDLE = "IDLE",
	DIRECT = "DIRECT",
	STEER = "STEER",
	RETREAT = "RETREAT",
	PATH = "PATH",
	COMBAT = "COMBAT",
	RECOVERY = "RECOVERY",
	DODGE = "DODGE",
	EXPLORE = "EXPLORE",
}

local Environment = (getgenv and getgenv()) or _G
Environment.AutoFarmV21Generation = (tonumber(Environment.AutoFarmV21Generation) or 0) + 1
if type(Environment.AutoFarmV21Shutdown) == "function" then
	local shutdownOk, shutdownError = pcall(Environment.AutoFarmV21Shutdown)
	if not shutdownOk then
		warn("[AF ERROR] previous shutdown: " .. tostring(shutdownError))
	end
end

local CONFIG_FILE = "AutoFarmV21Config.json"
local SavedConfig: { [string]: any } = {}
if type(isfile) == "function" and type(readfile) == "function" then
	local ok, decoded = pcall(function()
		if isfile(CONFIG_FILE) then
			return HttpService:JSONDecode(readfile(CONFIG_FILE))
		end
		return nil
	end)
	if ok and type(decoded) == "table" then
		SavedConfig = decoded
	end
end

local Config = Environment.AutoFarmConfigV21
	or {
		FarmEnabled = false,
		ShowHUD = true,
		HUDPosition = UDim2.fromScale(0.98, 0.04),
	}
Environment.AutoFarmConfigV21 = Config
-- HUD uses a right-edge anchor. Override the legacy left-side position retained
-- in getgenv when an older version of the script is executed again.
Config.HUDPosition = UDim2.fromScale(0.98, 0.04)
for key, value in pairs(DEFAULT_CONFIG) do
	if Config[key] == nil then
		Config[key] = value
	end
end

-- Keep user settings across source upgrades. Values with the wrong type are
-- ignored and the current default remains in place.
for key, defaultValue in pairs(DEFAULT_CONFIG) do
	local savedValue = SavedConfig[key]
	if savedValue ~= nil and type(savedValue) == type(defaultValue) then
		Config[key] = savedValue
	end
end
Config.RespawnStuckTime = 12
Config.ApproachDistance = nil
-- Keep the current Q/E contract regardless of stale old config files.
Config.NormalSkillRange = 80
Config.BossSkillRange = 100
Config.SkillRange = nil
Config.WebhookEnabled = nil
Config.WebhookURL = nil
if type(SavedConfig.FarmEnabled) == "boolean" then
	Config.FarmEnabled = SavedConfig.FarmEnabled
end

-- Clear obsolete settings retained by getgenv from older V21 runs.
Config.CombatDistance = nil
Config.RetreatDistance = nil
Config.StuckDistance = nil
Config.StuckLimit = nil
Config.StuckCheckInterval = nil
Config.DirectMoveRefresh = nil
Config.VerticalTravelThreshold = nil
Config.VerticalRespawnHeight = nil
Config.VerticalRespawnCooldown = nil
Config.PathFailureLimit = nil
Config.PathWatchInterval = nil
Config.MeleeVerticalTolerance = nil
Config.RecoveryDetourAt = nil
Config.RecoveryPathAt = nil
Config.RecoveryAlternateAt = nil

local function saveConfig()
	if type(writefile) ~= "function" then
		return
	end
	pcall(function()
		local persisted = {}
		for key, defaultValue in pairs(DEFAULT_CONFIG) do
			local value = Config[key]
			if type(value) == type(defaultValue) then
				persisted[key] = value
			end
		end
		persisted.FarmEnabled = Config.FarmEnabled == true
		persisted.NormalSkillRange = 80
		persisted.BossSkillRange = 100
		writefile(CONFIG_FILE, HttpService:JSONEncode(persisted))
	end)
end

local Character: Model? = nil
local Humanoid: Humanoid? = nil
local Root: BasePart? = nil
local Target: Model? = nil
local Running = Config.FarmEnabled == true
local Enabled = true
local DefaultAutoRotate = true
local DefaultWalkSpeed = 16
local AppliedWalkSpeed: number? = nil
local SpeedApplied = false

local State = NavigationState.IDLE
local NavigationGoal: Vector3? = nil
local GoalTarget: Model? = nil
local LastGoalRefreshAt = 0
local LastDirectDecisionAt = 0

local ActivePath: Path? = nil
local PathWaypoints: { PathWaypoint }? = nil
local PathIndex = 2
local PathGoal: Vector3? = nil
local PathBlockedConnection: RBXScriptConnection? = nil
local PathComputing = false
local PathRequestSerial = 0
local ActivePathGeneration = 0
local LastPathBuildAt = -math.huge
local PathNeedsRebuild = false
local PathIssuedIndex = 0
local PathIssuedAt = 0
local PathBestWaypointDistance = math.huge
local WaypointIssueSerial = 0
local ActiveWaypointIssueSerial = 0

local RecoveryGoal: Vector3? = nil
local RecoveryUntil = 0
local SteeringTried = false
local DodgeStartedAt = 0
local LastStartClickAt = -math.huge
local CharacterBindSerial = 0
local RespawnInProgress = false
local ResetExecuting = false

local ProgressTarget: Model? = nil
local ProgressGoalAnchor: Vector3? = nil
local BestGoalMetric = math.huge
local BestVerticalDifference = math.huge
local LastMeaningfulProgressAt = os.clock()
local LastProgressCheckAt = 0
local LastStuckPathRetryAt = -math.huge
local LowSpeedSince: number? = nil
local LastLowSpeedPathRetryAt = -math.huge

local LastAttack = 0
local NextQAt = 0
local NextEAt = 0
local TargetDiedConnection: RBXScriptConnection? = nil
local AimAttachment: Attachment? = nil
local AimAlignment: AlignOrientation? = nil
local PlayerControls = nil
local PlayerControlsDisabled = false
local PlayerControlsResolvePending = false

local EnemySet: { [Model]: boolean } = {}
local PendingEnemyModels: { [Model]: boolean } = {}
local LastTargetAcquireAt = -math.huge
local HazardSet: { [BasePart]: boolean } = {}
local ActiveHazard: BasePart? = nil
local DodgeGoal: Vector3? = nil
local LastDodgeGoalAttemptAt = -math.huge
local LastHazardThreatAt = -math.huge
local NearbyActiveHazards: { [BasePart]: boolean } = {}
local LastHazardRefreshAt = -math.huge
local ExploreGoal: Vector3? = nil
local ExploreHeading: Vector3? = nil
local ExploreCommitUntil = 0
local ExploreBestDistance = math.huge
local LastExploreMeaningfulProgressAt = os.clock()
local LastExploreSelectionAt = -math.huge
local NoTargetSince: number? = nil
local DescentLocked = false
local DescentRiseStrikes = 0
local ExploredCells: { [string]: boolean } = {}
local ExploredCellOrder: { string } = {}
local LastTelemetry: { [string]: string } = {}
local RuntimeState = {
	Generation = Environment.AutoFarmV21Generation,
	JumpStillSince = os.clock(),
	JumpBestDistance = math.huge,
	JumpBestVertical = math.huge,
	JumpBurstUntil = 0,
	JumpBurstTaskRunning = false,
	JumpBurstGeneration = 0,
	ReplayAwaitingClose = nil :: GuiButton?,
	ReplayPhase = "IDLE",
	ReplayArmedAt = 0,
	ReplayLastActionAt = -math.huge,
	ReplayModal = nil :: GuiObject?,
	ReplayCompletionRoot = nil :: GuiObject?,
	ReplayOpener = nil :: GuiButton?,
	ReplayConfirmRoot = nil :: GuiObject?,
	ReplayLastGuiScanAt = -math.huge,
	ReplayOpenerMissingReported = false,
	ReplayCompletionDetected = false,
	BossDiedConnection = nil :: RBXScriptConnection?,
	BossDiedTarget = nil :: Model?,
	StartDebugMarker = nil :: GuiObject?,
	StartDebugButton = nil :: GuiButton?,
	StartMarker = nil :: GuiObject?,
	StartButton = nil :: GuiButton?,
	LastStartMarkerScanAt = -math.huge,
	DungeonFinishedLastState = false,
	ActiveDungeonRoot = nil :: Instance?,
	DungeonFinishedInstance = nil :: BoolValue?,
	PreviousDungeonFinishedInstance = nil :: BoolValue?,
	FightingBossInstance = nil :: BoolValue?,
	LastFightingBossState = false,
	FightingBossSeenThisRound = false,
	EnemyFolderInstance = nil :: Instance?,
	DungeonTimeInstance = nil :: ValueBase?,
	DungeonTimeText = nil :: GuiObject?,
	LastDungeonReferenceSearchAt = -math.huge,
	LastDungeonStateCheckAt = 0,
	LastFallbackTargetScanAt = -math.huge,
	LastHUDUpdateAt = -math.huge,
	LastStatsSampleAt = -math.huge,
	PingMs = 0,
	RoundTransitionActive = false,
	RoundBootstrapUntil = 0,
	RoundBootstrapAttempts = 0,
	RoundBootstrapLastCacheAt = -math.huge,
	LastStaleTarget = nil :: Model?,
	CharacterBindRetryUntil = 0,
	CharacterBindRetryPending = false,
	CharacterBindRetryCharacter = nil :: Model?,
	LastCharacterBindWait = "",
	SmoothedFPS = 0,
	HUDInfo = nil :: TextLabel?,
	HUDButton = nil :: TextButton?,
	ReplayYesButton = nil :: GuiButton?,
	ReplayDebugButton = nil :: GuiButton?,
	RoundResetSerial = 0,
	RecoverySerial = 0,
	RespawnRushUntil = 0,
	RoundTransitionSerial = 0,
	RoundTransitionStartedAt = 0,
	RoundTransitionDeadline = 0,
	RoundTransitionTimedOut = false,
	DodgeCommitUntil = 0,
	LastDodgeEvaluationAt = -math.huge,
	DodgeCachedHazard = nil :: BasePart?,
	DodgeCachedPredicted = false,
	DodgeCachedEdgeDistance = math.huge,
	DodgeCachedRouteDistance = math.huge,
	DodgeRaycastsUsed = 0,
	HazardMetadata = {} :: { [BasePart]: { CFrame: CFrame, SampleAt: number, Velocity: Vector3 } },
	VerticalPathTarget = nil :: Model?,
	VerticalPathGoal = nil :: Vector3?,
}

local Connections: { RBXScriptConnection } = {}
local CharacterConnections: { RBXScriptConnection } = {}
local HUD: ScreenGui? = nil
local recoverByRespawn
local setRunning
local setNavigationState
local stopTranslation
local resetRuntimeForNewDungeon
local getTargetRoot

local function isCurrentExecution(): boolean
	return Enabled and Environment.AutoFarmV21Generation == RuntimeState.Generation
end

local function readPingMs(): number?
	local ok, value = pcall(function()
		local network = Stats.Network
		local items = network and network.ServerStatsItem
		local pingItem = items and items["Data Ping"]
		return pingItem and pingItem:GetValue() or nil
	end)
	if ok and type(value) == "number" then
		return math.floor(value + 0.5)
	end
	return nil
end

local function telemetry(event: string, message: string)
	if not Config.DebugTelemetry or LastTelemetry[event] == message then
		return
	end
	LastTelemetry[event] = message
	print(string.format("[AutoFarm:%s] %s", event, message))
end

-- Lifecycle events remain callable, but webhook/network activity is removed.
RuntimeState.sendStatusWebhook = function(_event: string) end

local function disconnect(connection: RBXScriptConnection?)
	if connection and connection.Connected then
		connection:Disconnect()
	end
end

local function disconnectAll(list: { RBXScriptConnection })
	for index = #list, 1, -1 do
		disconnect(list[index])
		list[index] = nil
	end
end

local function alive(): boolean
	return Character ~= nil and Humanoid ~= nil and Root ~= nil and Character.Parent ~= nil and Humanoid.Health > 0
end

local function isIgnoredTarget(model: Model): boolean
	local name = model.Name:lower()
	for _, keyword in ipairs(Config.IgnoredTargetKeywords) do
		if string.find(name, string.lower(keyword), 1, true) then
			return true
		end
	end
	return false
end

local function isEnemy(model: Model): boolean
	if isIgnoredTarget(model) then
		return false
	end
	local current: Instance? = model
	while current and current ~= workspace do
		local name = current.Name:lower()
		for _, keyword in ipairs(Config.EnemyKeywords) do
			if string.find(name, string.lower(keyword), 1, true) then
				return true
			end
		end
		current = current.Parent
	end
	return model:FindFirstChild("EnemyNameplate") ~= nil or model:FindFirstChild("Nameplate") ~= nil
end

local function isBossTarget(model: Model): boolean
	local fightingBoss = RuntimeState.FightingBossInstance
	local enemyFolder = RuntimeState.EnemyFolderInstance
	local activeRoot = RuntimeState.ActiveDungeonRoot
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local structurallyValid = model:IsDescendantOf(workspace)
		and model ~= Character
		and not Players:GetPlayerFromCharacter(model)
		and humanoid ~= nil
		and humanoid.Health > 0
	if
		structurallyValid
		and fightingBoss
		and fightingBoss:IsDescendantOf(workspace)
		and fightingBoss.Value
		and enemyFolder
		and enemyFolder:IsDescendantOf(workspace)
		and model:IsDescendantOf(enemyFolder)
	then
		return true
	end
	if
		structurallyValid
		and fightingBoss
		and fightingBoss:IsDescendantOf(workspace)
		and fightingBoss.Value
		and activeRoot
		and activeRoot:IsDescendantOf(workspace)
		and not enemyFolder
		and model:IsDescendantOf(activeRoot)
	then
		return true
	end
	local current: Instance? = model
	while current and current ~= workspace do
		local name = current.Name:lower()
		for _, keyword in ipairs(Config.BossKeywords) do
			if string.find(name, string.lower(keyword), 1, true) then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

local function skillRangeForTarget(target: Model): number
	-- Only these named bosses have the extended skill range. Other bosses use
	-- the same normal range as regular enemies.
	local targetName = string.lower(target.Name)
	if targetName == "ancient enchanted tree" or targetName == "enchanted forest dragon" then
		return Config.BossSkillRange
	end
	return Config.NormalSkillRange
end

getTargetRoot = function(model: Model): BasePart?
	local humanoidRoot = model:FindFirstChild("HumanoidRootPart", true)
	if humanoidRoot and humanoidRoot:IsA("BasePart") then
		return humanoidRoot
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	for _, object in ipairs(model:GetDescendants()) do
		if object:IsA("BasePart") and object.CanCollide then
			return object
		end
	end
	return nil
end

local function validTarget(target: Model?): boolean
	if not target or not Root or not target:IsDescendantOf(workspace) then
		return false
	end
	if isIgnoredTarget(target) then
		return false
	end
	if target == Character or Players:GetPlayerFromCharacter(target) then
		return false
	end
	local enemyHumanoid = target:FindFirstChildOfClass("Humanoid")
	local enemyRoot = getTargetRoot(target)
	return enemyHumanoid ~= nil
		and enemyRoot ~= nil
		and enemyRoot:IsDescendantOf(workspace)
		and enemyHumanoid.Health > 0
		and (enemyRoot.Position - Root.Position).Magnitude <= Config.FarmRange * Config.TargetLockRangeMultiplier
end

local function registerEnemy(instance: Instance)
	local current: Instance? = instance
	while current and current ~= workspace do
		if current:IsA("Model") and current ~= Character and not Players:GetPlayerFromCharacter(current) then
			local enemyHumanoid = current:FindFirstChildOfClass("Humanoid")
			local enemyRoot = getTargetRoot(current)
			if enemyHumanoid and enemyHumanoid.Health > 0 and enemyRoot and enemyRoot:IsDescendantOf(workspace) then
				local wasKnown = EnemySet[current] == true
				EnemySet[current] = true
				PendingEnemyModels[current] = nil
				if Running and not wasKnown then
					LastTargetAcquireAt = -math.huge
				end
				return
			end
			PendingEnemyModels[current] = true
		end
		current = current.Parent
	end
end

local function makeRaycastParams(target: Model?): RaycastParams
	local parameters = RaycastParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Exclude
	local exclusions = {}
	if Character then
		table.insert(exclusions, Character)
	end
	if target then
		table.insert(exclusions, target)
	end
	parameters.FilterDescendantsInstances = exclusions
	parameters.IgnoreWater = true
	parameters.RespectCanCollide = true
	return parameters
end

local function rootGroundOffset(): number
	if not Root or not Humanoid then
		return 3
	end
	return math.max(2.5, Humanoid.HipHeight + Root.Size.Y * 0.5)
end

local function projectToWalkableGround(position: Vector3, target: Model?): (Vector3, boolean)
	local origin = position + Vector3.new(0, Config.GroundProbeLift, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -Config.GroundProbeDepth, 0), makeRaycastParams(target))
	if not result or result.Normal.Y < math.cos(math.rad(Humanoid and Humanoid.MaxSlopeAngle or 45)) then
		return position, false
	end
	return Vector3.new(position.X, result.Position.Y + rootGroundOffset(), position.Z), true
end

local function hasGroundSupport(position: Vector3, target: Model?): boolean
	local origin = position + Vector3.new(0, 7, 0)
	return workspace:Raycast(origin, Vector3.new(0, -Config.GroundSupportDepth, 0), makeRaycastParams(target)) ~= nil
end

local function hazardNameHint(part: BasePart): boolean
	local current: Instance? = part
	while current and current ~= workspace do
		local lowerName = current.Name:lower()
		if
			lowerName:find("circle", 1, true)
			or lowerName:find("danger", 1, true)
			or lowerName:find("warning", 1, true)
			or lowerName:find("aoe", 1, true)
			or lowerName:find("telegraph", 1, true)
			or lowerName:find("indicator", 1, true)
			or lowerName:find("hitbox", 1, true)
			or lowerName:find("precast", 1, true)
			or lowerName:find("damagebox", 1, true)
			or lowerName:find("damagepart", 1, true)
			or lowerName:find("attack", 1, true)
			or lowerName:find("skill", 1, true)
		then
			return true
		end
		current = current.Parent
	end
	return false
end

local function isHazardCandidate(part: BasePart): boolean
	if not part:IsDescendantOf(workspace) or (Character and part:IsDescendantOf(Character)) then
		return false
	end
	local dimensions = { part.Size.X, part.Size.Y, part.Size.Z }
	table.sort(dimensions)
	local broadAndThin = dimensions[1] <= 5 and dimensions[2] >= 5 and dimensions[3] >= 5
	local color = part.Color
	local visiblyRed = color.R >= 0.65 and color.R >= color.G * 1.35 and color.R >= color.B * 1.2
	local effectGeometry = broadAndThin
		or not part.CanCollide
		or part.AssemblyLinearVelocity.Magnitude >= 1
		or (part:IsA("Part") and (part.Shape == Enum.PartType.Cylinder or part.Shape == Enum.PartType.Ball))
	return (hazardNameHint(part) and effectGeometry)
		or (visiblyRed and broadAndThin)
		or (visiblyRed and part:IsA("Part") and part.Shape == Enum.PartType.Cylinder)
end

local function isActiveHazardPart(part: BasePart): boolean
	if not part:IsDescendantOf(workspace) or (Character and part:IsDescendantOf(Character)) then
		return false
	end
	if part.Size.X <= 0.05 or part.Size.Y <= 0.05 or part.Size.Z <= 0.05 then
		return false
	end
	local color = part.Color
	local visiblyRed = color.R >= 0.65 and color.R >= color.G * 1.35 and color.R >= color.B * 1.2
	local dimensions = { part.Size.X, part.Size.Y, part.Size.Z }
	table.sort(dimensions)
	local broadAndThin = dimensions[1] <= 5 and dimensions[2] >= 5 and dimensions[3] >= 5
	local effectGeometry = broadAndThin
		or not part.CanCollide
		or part.AssemblyLinearVelocity.Magnitude >= 1
		or (part:IsA("Part") and (part.Shape == Enum.PartType.Cylinder or part.Shape == Enum.PartType.Ball))
	local structuralEvidence = hazardNameHint(part) and effectGeometry
	return structuralEvidence
		or (part.Transparency < 0.98 and visiblyRed and broadAndThin)
		or (part.Transparency < 0.98 and visiblyRed and part:IsA("Part") and part.Shape == Enum.PartType.Cylinder)
end

local function registerHazard(instance: Instance)
	-- Cache structural candidates, not only parts that happen to be red at creation time.
	if instance:IsA("BasePart") and isHazardCandidate(instance) then
		HazardSet[instance] = true
		RuntimeState.HazardMetadata[instance] = {
			CFrame = instance.CFrame,
			SampleAt = os.clock(),
			Velocity = instance.AssemblyLinearVelocity,
		}
	end
end

local function buildInitialCaches(cacheRoot: Instance?)
	-- A confirmed enemy folder is both cheaper and safer than re-walking an
	-- entire replayed map. The workspace fallback remains for games that do
	-- not expose such a folder yet.
	local source = cacheRoot
	if not source or not source:IsDescendantOf(workspace) then
		source = workspace
	end
	for _, object in ipairs(source:GetDescendants()) do
		if object:IsA("Model") then
			registerEnemy(object)
		elseif Config.DodgeEnabled and object:IsA("BasePart") then
			registerHazard(object)
		end
	end
end

local function hazardRadius(part: BasePart): number
	-- Circle meshes/cylinders may use any local axis as thickness, so use the largest diameter.
	return math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
end

local function flatPointDistance(first: Vector3, second: Vector3): number
	return Vector2.new(first.X - second.X, first.Z - second.Z).Magnitude
end

local function hazardVerticalHalfExtent(part: BasePart): number
	local worldUp = Vector3.yAxis
	return math.abs(part.CFrame.RightVector:Dot(worldUp)) * part.Size.X * 0.5
		+ math.abs(part.CFrame.UpVector:Dot(worldUp)) * part.Size.Y * 0.5
		+ math.abs(part.CFrame.LookVector:Dot(worldUp)) * part.Size.Z * 0.5
end

local function hazardVelocity(part: BasePart): Vector3
	local metadata = RuntimeState.HazardMetadata[part]
	local now = os.clock()
	local engineVelocity = part.AssemblyLinearVelocity
	if metadata then
		local elapsed = now - metadata.SampleAt
		if elapsed > 0.01 and elapsed <= 0.5 then
			local estimated = (part.Position - metadata.CFrame.Position) / elapsed
			if estimated.Magnitude <= 160 and engineVelocity.Magnitude < 0.1 then
				engineVelocity = estimated
			end
		end
		metadata.CFrame = part.CFrame
		metadata.SampleAt = now
		metadata.Velocity = engineVelocity
	else
		RuntimeState.HazardMetadata[part] = {
			CFrame = part.CFrame,
			SampleAt = now,
			Velocity = engineVelocity,
		}
	end
	return engineVelocity
end

local function hazardThreatensHeight(part: BasePart, position: Vector3, lookaheadSeconds: number?): boolean
	local predictedPosition = part.Position + hazardVelocity(part) * (lookaheadSeconds or 0)
	return math.abs(position.Y - predictedPosition.Y)
		<= hazardVerticalHalfExtent(part) + rootGroundOffset() + Config.DodgeVerticalPadding
end

RuntimeState.hazardIsPrecast = function(part: BasePart): boolean
	local current: Instance? = part
	while current and current ~= workspace do
		local name = current.Name:lower()
		if
			name:find("precast", 1, true)
			or name:find("telegraph", 1, true)
			or name:find("indicator", 1, true)
			or name:find("warning", 1, true)
		then
			return true
		end
		current = current.Parent
	end
	return false
end

RuntimeState.hazardEdgeDistance = function(part: BasePart, position: Vector3, lookaheadSeconds: number?): number
	local futureCFrame = part.CFrame + hazardVelocity(part) * (lookaheadSeconds or 0)
	local half = part.Size * 0.5
	if part:IsA("Part") and (part.Shape == Enum.PartType.Cylinder or part.Shape == Enum.PartType.Ball) then
		local radiusX = math.abs(futureCFrame.RightVector.X) * half.X
			+ math.abs(futureCFrame.UpVector.X) * half.Y
			+ math.abs(futureCFrame.LookVector.X) * half.Z
		local radiusZ = math.abs(futureCFrame.RightVector.Z) * half.X
			+ math.abs(futureCFrame.UpVector.Z) * half.Y
			+ math.abs(futureCFrame.LookVector.Z) * half.Z
		return flatPointDistance(position, futureCFrame.Position) - math.max(radiusX, radiusZ)
	end
	local localPoint = futureCFrame:PointToObjectSpace(Vector3.new(position.X, futureCFrame.Position.Y, position.Z))
	local outsideX = math.abs(localPoint.X) - half.X
	local outsideZ = math.abs(localPoint.Z) - half.Z
	if outsideX <= 0 and outsideZ <= 0 then
		return -math.min(-outsideX, -outsideZ)
	end
	return Vector2.new(math.max(0, outsideX), math.max(0, outsideZ)).Magnitude
end

RuntimeState.segmentHazardClearance = function(part: BasePart, first: Vector3, second: Vector3): number
	local minimum = math.huge
	local sampleCount = math.clamp(math.ceil((second - first).Magnitude / 4), 3, 12)
	for index = 0, sampleCount do
		local alpha = index / sampleCount
		local point = first:Lerp(second, alpha)
		if hazardThreatensHeight(part, point, Config.DodgeLookaheadSeconds * alpha) then
			minimum = math.min(
				minimum,
				RuntimeState.hazardEdgeDistance(part, point, Config.DodgeLookaheadSeconds * alpha)
			)
		end
	end
	return minimum
end

local function playerFootprintRadius(): number
	if not Root then
		return Config.DodgePlayerSafetyMargin
	end
	return math.max(Root.Size.X, Root.Size.Z) * 0.5 + Config.DodgePlayerSafetyMargin
end

local function refreshNearbyActiveHazards()
	if not Config.DodgeEnabled then
		table.clear(NearbyActiveHazards)
		return
	end
	if not Root then
		table.clear(NearbyActiveHazards)
		return
	end
	local now = os.clock()
	if now - LastHazardRefreshAt < Config.DodgeRefreshInterval then
		return
	end
	LastHazardRefreshAt = now
	table.clear(NearbyActiveHazards)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = Character and { Character } or {}
	overlap.MaxParts = 100
	for _, part in ipairs(workspace:GetPartBoundsInRadius(Root.Position, Config.DodgeDetectionRadius, overlap)) do
		if
			isActiveHazardPart(part)
			and (
				hazardThreatensHeight(part, Root.Position)
				or hazardThreatensHeight(part, Root.Position, Config.DodgeLookaheadSeconds)
			)
		then
			NearbyActiveHazards[part] = true
			HazardSet[part] = true
		end
	end
	-- Structural candidates also cover effects excluded from spatial queries.
	for part in pairs(HazardSet) do
		if not part:IsDescendantOf(workspace) then
			HazardSet[part] = nil
			RuntimeState.HazardMetadata[part] = nil
		elseif
			(part.Position - Root.Position).Magnitude <= Config.DodgeDetectionRadius + hazardRadius(part)
			and isActiveHazardPart(part)
			and (
				hazardThreatensHeight(part, Root.Position)
				or hazardThreatensHeight(part, Root.Position, Config.DodgeLookaheadSeconds)
			)
		then
			NearbyActiveHazards[part] = true
		end
	end
end

local function pointIsSafeFromHazards(position: Vector3): boolean
	if not Config.DodgeEnabled then
		return true
	end
	for part in pairs(NearbyActiveHazards) do
		if
			part:IsDescendantOf(workspace)
			and isActiveHazardPart(part)
			and hazardThreatensHeight(part, position, Config.DodgeLookaheadSeconds)
			and RuntimeState.hazardEdgeDistance(part, position, Config.DodgeLookaheadSeconds)
				<= playerFootprintRadius() + Config.DodgeSafePadding
		then
			return false
		end
	end
	return true
end

local function upcomingMovementGoal(): Vector3?
	if not Root then
		return nil
	end
	if State == NavigationState.DIRECT then
		return NavigationGoal
	elseif State == NavigationState.PATH and PathWaypoints then
		local waypoint = PathWaypoints[PathIndex]
		return waypoint and waypoint.Position or nil
	elseif State == NavigationState.RECOVERY or State == NavigationState.STEER or State == NavigationState.RETREAT then
		return RecoveryGoal
	elseif State == NavigationState.EXPLORE then
		return ExploreGoal
	elseif State == NavigationState.DODGE then
		return DodgeGoal
	end
	return Root.Position
end

local function threateningHazard(): (BasePart?, boolean, number, number)
	if not Root then
		return nil, false, math.huge, math.huge
	end
	refreshNearbyActiveHazards()
	local nearest: BasePart? = nil
	local nearestEdge = math.huge
	local nearestPredicted = false
	local nearestRouteDistance = math.huge
	local bestThreatScore = math.huge
	local footprint = playerFootprintRadius()
	local movementGoal = upcomingMovementGoal()
	local predictedEnd = Root.Position
	if movementGoal then
		local flat = Vector3.new(movementGoal.X - Root.Position.X, 0, movementGoal.Z - Root.Position.Z)
		local lookahead = math.clamp((Humanoid and Humanoid.WalkSpeed or 16) * Config.DodgeLookaheadSeconds, 8, 36)
		if flat.Magnitude > 0.1 then
			predictedEnd = Root.Position + flat.Unit * math.min(flat.Magnitude, lookahead)
		end
	end
	for part in pairs(NearbyActiveHazards) do
		if part:IsDescendantOf(workspace) and isActiveHazardPart(part) then
			local edgeDistance = RuntimeState.hazardEdgeDistance(part, Root.Position, 0) - footprint
			local routeClearance = RuntimeState.segmentHazardClearance(part, Root.Position, predictedEnd) - footprint
			local triggerPadding = if RuntimeState.hazardIsPrecast(part)
				then Config.DodgePreTriggerPadding
				else Config.DodgeTriggerPadding
			local predicted = routeClearance <= triggerPadding
			local retainingActiveDodge = State == NavigationState.DODGE
				and edgeDistance <= Config.DodgeSafePadding
			local threatScore = math.min(edgeDistance, routeClearance)
			if
				edgeDistance <= Config.DodgeDetectionRadius
				and (edgeDistance <= triggerPadding or predicted or retainingActiveDodge)
				and threatScore < bestThreatScore
			then
				bestThreatScore = threatScore
				nearestEdge = edgeDistance
				nearest = part
				nearestPredicted = predicted
				nearestRouteDistance = routeClearance
			end
		end
	end
	return nearest, nearestPredicted, nearestEdge, nearestRouteDistance
end

local function dodgeRouteClear(goal: Vector3): boolean
	if not Config.DodgeEnabled then
		return true
	end
	if not Root then
		return false
	end
	local flatDelta = Vector3.new(goal.X - Root.Position.X, 0, goal.Z - Root.Position.Z)
	if flatDelta.Magnitude <= 0.1 then
		return true
	end
	if RuntimeState.DodgeRaycastsUsed >= Config.DodgeRaycastBudget then
		return false
	end
	RuntimeState.DodgeRaycastsUsed += 1
	local obstacle = workspace:Raycast(Root.Position + Vector3.new(0, 2.5, 0), flatDelta, makeRaycastParams(nil))
	if obstacle and obstacle.Distance < flatDelta.Magnitude - 1.5 then
		return false
	end
	local footprint = playerFootprintRadius()
	local previousClearances: { [BasePart]: number } = {}
	for hazard in pairs(NearbyActiveHazards) do
		if isActiveHazardPart(hazard) then
			previousClearances[hazard] = RuntimeState.hazardEdgeDistance(hazard, Root.Position, 0) - footprint
		end
	end
	local previous = Root.Position
	local count = math.min(3, math.max(2, math.ceil(flatDelta.Magnitude / 6)))
	for index = 1, count do
		if RuntimeState.DodgeRaycastsUsed >= Config.DodgeRaycastBudget then
			return false
		end
		RuntimeState.DodgeRaycastsUsed += 1
		local grounded, found = projectToWalkableGround(Root.Position:Lerp(goal, index / count), Target)
		if not found or math.abs(grounded.Y - previous.Y) > Config.ExploreMaxVerticalStep then
			return false
		end
		for hazard in pairs(NearbyActiveHazards) do
			if isActiveHazardPart(hazard) and hazardThreatensHeight(hazard, grounded) then
				local clearance = RuntimeState.hazardEdgeDistance(hazard, grounded, 0) - footprint
				local prior = previousClearances[hazard] or math.huge
				-- Leaving an overlapping hazard is allowed, but the route may not
				-- move deeper into it or cross a different unsafe footprint.
				if
					(prior <= Config.DodgeSafePadding and clearance < prior - 0.1)
					or (prior > Config.DodgeSafePadding and clearance <= Config.DodgeSafePadding)
				then
					return false
				end
				previousClearances[hazard] = clearance
			end
		end
		previous = grounded
	end
	return hasGroundSupport(goal, nil)
end

local function chooseNearestSafeDodgeGoal(hazard: BasePart): Vector3?
	if not Root then
		return nil
	end
	local fromCenter = Vector3.new(Root.Position.X - hazard.Position.X, 0, Root.Position.Z - hazard.Position.Z)
	local baseAngle = fromCenter.Magnitude > 0.1 and math.atan2(fromCenter.Z, fromCenter.X) or 0
	local bestGoal: Vector3? = nil
	local bestScore = -math.huge
	local footprint = playerFootprintRadius()
	local currentClearance = RuntimeState.hazardEdgeDistance(hazard, Root.Position, 0) - footprint
	local escapeDistance = math.max(4, Config.DodgeSafePadding - currentClearance + 2)
	local ringDistances = { escapeDistance, escapeDistance + 5, escapeDistance + 10 }
	for ringIndex, ringDistance in ipairs(ringDistances) do
		for angleIndex = 0, Config.DodgeCandidateCount - 1 do
			local offsetIndex = 0
			if angleIndex > 0 then
				offsetIndex = if angleIndex % 2 == 1 then (angleIndex + 1) / 2 else -angleIndex / 2
			end
			local angle = baseAngle + offsetIndex * math.pi * 2 / Config.DodgeCandidateCount
			local candidate = Root.Position
				+ Vector3.new(math.cos(angle) * ringDistance, 0, math.sin(angle) * ringDistance)
			local grounded, foundGround = projectToWalkableGround(candidate, nil)
			local rejection = if not foundGround
				then "no-ground"
				elseif math.abs(grounded.Y - Root.Position.Y) > Config.DirectVerticalTolerance then "wrong-floor"
				elseif not pointIsSafeFromHazards(grounded) then "hazard-overlap"
				elseif not dodgeRouteClear(grounded) then "blocked-or-gap"
				else nil
			if not rejection then
				local distance = flatPointDistance(Root.Position, grounded)
				local minimumSafety = math.huge
				for otherHazard in pairs(NearbyActiveHazards) do
					if isActiveHazardPart(otherHazard) and hazardThreatensHeight(otherHazard, grounded) then
						minimumSafety = math.min(
							minimumSafety,
							RuntimeState.hazardEdgeDistance(otherHazard, grounded, Config.DodgeLookaheadSeconds)
								- footprint
						)
					end
				end
				local awayDirection = Vector3.new(math.cos(baseAngle), 0, math.sin(baseAngle))
				local candidateDirection = Vector3.new(grounded.X - Root.Position.X, 0, grounded.Z - Root.Position.Z)
				local awayBias = candidateDirection.Magnitude > 0.1 and awayDirection:Dot(candidateDirection.Unit) or 0
				local score = math.min(minimumSafety, 40) * 4 - distance + awayBias * 3
				if not bestGoal or score > bestScore then
					bestScore = score
					bestGoal = grounded
				end
			else
				telemetry("DODGE_REJECT_" .. tostring(ringIndex) .. "_" .. tostring(angleIndex), rejection)
			end
		end
		if bestGoal then
			return bestGoal
		end
	end
	return bestGoal
end

RuntimeState.exploreCellKey = function(position: Vector3): string
	local size = Config.ExploreHistoryCellSize
	return string.format(
		"%d:%d:%d",
		math.floor(position.X / size),
		math.floor(position.Y / size),
		math.floor(position.Z / size)
	)
end

RuntimeState.rememberExplorePosition = function(position: Vector3)
	local key = RuntimeState.exploreCellKey(position)
	if ExploredCells[key] then
		return
	end
	ExploredCells[key] = true
	table.insert(ExploredCellOrder, key)
	if #ExploredCellOrder > Config.ExploreHistoryLimit then
		local oldest = table.remove(ExploredCellOrder, 1)
		ExploredCells[oldest] = nil
	end
end

RuntimeState.evaluateExploreDirection = function(direction: Vector3): (Vector3?, number, string, number)
	if not Root then
		return nil, -math.huge, "no-root", 0
	end
	local stepDistance = Config.ExploreStepDistance
	local obstacle =
		workspace:Raycast(Root.Position + Vector3.new(0, 2.5, 0), direction * stepDistance, makeRaycastParams(nil))
	if obstacle and obstacle.Distance < stepDistance - 1.5 then
		return nil, -math.huge, "wall", 0
	end
	local previousGround = Root.Position
	local finalGround: Vector3? = nil
	for sampleIndex = 1, Config.ExploreProbeSamples do
		local alpha = sampleIndex / Config.ExploreProbeSamples
		local sample = Root.Position + direction * (stepDistance * alpha)
		local ground, foundGround = projectToWalkableGround(sample, nil)
		if not foundGround then
			return nil, -math.huge, "gap", 0
		end
		if math.abs(ground.Y - previousGround.Y) > Config.ExploreMaxVerticalStep then
			return nil, -math.huge, ground.Y < previousGround.Y and "unsafe-drop" or "unsafe-rise", 0
		end
		if not pointIsSafeFromHazards(ground) then
			return nil, -math.huge, "hazard", 0
		end
		previousGround = ground
		finalGround = ground
	end
	if not finalGround then
		return nil, -math.huge, "no-ground", 0
	end
	local continuity = ExploreHeading and math.max(-1, math.min(1, ExploreHeading:Dot(direction))) or 0
	local downhillDelta = Root.Position.Y - finalGround.Y
	local novelty = ExploredCells[RuntimeState.exploreCellKey(finalGround)] and -14 or 12
	local downhillBonus = math.clamp(downhillDelta * 1.25, -5, 7)
	local score = 30 + continuity * 8 + novelty + downhillBonus
	return finalGround,
		score,
		string.format(
			"score=%.1f continuity=%.2f novelty=%.1f downhill=%.1f",
			score,
			continuity,
			novelty,
			downhillDelta
		),
		downhillDelta
end

RuntimeState.chooseExploreGoal = function(): (Vector3?, Vector3?, number)
	if not Root then
		return nil, nil, 0
	end
	refreshNearbyActiveHazards()
	local forward = ExploreHeading or Vector3.new(Root.CFrame.LookVector.X, 0, Root.CFrame.LookVector.Z)
	if forward.Magnitude <= 0.1 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end
	local baseAngle = math.atan2(forward.Z, forward.X)
	local bestGoal: Vector3? = nil
	local bestDirection: Vector3? = nil
	local bestScore = -math.huge
	local bestDownhill = 0
	for index = 0, Config.ExploreCandidateCount - 1 do
		local angle = baseAngle + index * math.pi * 2 / Config.ExploreCandidateCount
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local goal, score, reason, downhill = RuntimeState.evaluateExploreDirection(direction)
		telemetry("EXPLORE_CANDIDATE_" .. tostring(index), reason)
		if goal and score > bestScore then
			bestGoal, bestDirection, bestScore, bestDownhill = goal, direction, score, downhill
		end
	end
	if bestGoal then
		telemetry("EXPLORE_GOAL", string.format("goal=%s score=%.1f", tostring(bestGoal), bestScore))
	else
		telemetry("EXPLORE_GOAL", "no-safe-candidate")
	end
	return bestGoal, bestDirection, bestDownhill
end

local function clearExploreObjective()
	ExploreGoal = nil
	ExploreCommitUntil = 0
	ExploreBestDistance = math.huge
	DescentLocked = false
	DescentRiseStrikes = 0
end

RuntimeState.extendDescentGoal = function(now: number): boolean
	if not DescentLocked or not ExploreHeading or not Root then
		return false
	end
	local goal, _, reason, downhill = RuntimeState.evaluateExploreDirection(ExploreHeading)
	if not goal then
		telemetry("DESCENT_RELEASE", reason)
		DescentLocked = false
		DescentRiseStrikes = 0
		return false
	end
	if downhill < -Config.DescentFlatTolerance then
		DescentRiseStrikes += 1
		if DescentRiseStrikes >= Config.DescentRiseReleaseCount then
			telemetry("DESCENT_RELEASE", string.format("rising downhill=%.1f", downhill))
			DescentLocked = false
			DescentRiseStrikes = 0
			return false
		end
	else
		DescentRiseStrikes = 0
	end
	ExploreGoal = goal
	ExploreBestDistance = flatPointDistance(Root.Position, goal)
	ExploreCommitUntil = now + Config.ExploreCommitTime
	telemetry("DESCENT_EXTEND", string.format("goal=%s downhill=%.1f", tostring(goal), downhill))
	return true
end

local function updateExploreMovement()
	if State ~= NavigationState.EXPLORE or not Root or not Humanoid or not ExploreGoal or Target then
		return
	end
	local direction = Vector3.new(ExploreGoal.X - Root.Position.X, 0, ExploreGoal.Z - Root.Position.Z)
	local distance = direction.Magnitude
	if distance <= Config.ExploreReachedDistance then
		Humanoid:Move(Vector3.zero, false)
		return
	end
	if distance <= ExploreBestDistance - Config.MeaningfulProgressDistance then
		ExploreBestDistance = distance
		LastExploreMeaningfulProgressAt = os.clock()
	end
	if os.clock() - LastExploreMeaningfulProgressAt >= Config.ExploreRespawnStuckTime and not RespawnInProgress then
		recoverByRespawn(nil, LastExploreMeaningfulProgressAt, true)
		return
	end
	Humanoid:Move(direction.Unit, false)
end

local function directRouteClear(goal: Vector3, target: Model?): boolean
	if not Root or math.abs(goal.Y - Root.Position.Y) > Config.DirectVerticalTolerance then
		return false
	end
	local flatDelta = Vector3.new(goal.X - Root.Position.X, 0, goal.Z - Root.Position.Z)
	local distance = flatDelta.Magnitude
	if distance <= Config.WaypointReachedDistance then
		return true
	end
	local obstacle = workspace:Raycast(Root.Position + Vector3.new(0, 2.5, 0), flatDelta, makeRaycastParams(target))
	if obstacle and obstacle.Distance < distance - 2 then
		return false
	end
	local sampleCount = math.max(1, math.ceil(distance / 3))
	local previous = Root.Position
	for index = 1, sampleCount do
		local sample = Root.Position:Lerp(goal, index / sampleCount)
		local ground, found = projectToWalkableGround(sample, target)
		-- Direct navigation may cross adjoining BasicParts with a small seam/step.
		-- Explorer's cliff threshold is intentionally stricter and must not make
		-- normal movement alternate between DIRECT and PATH at those seams.
		if not found or math.abs(ground.Y - previous.Y) > Config.DirectVerticalTolerance then
			return false
		end
		previous = ground
	end
	return hasGroundSupport(goal, target)
end

local function navigationGoalForTarget(enemyRoot: BasePart, target: Model, holdDistance: number?): Vector3
	if not Root then
		return enemyRoot.Position
	end
	local flat = Vector3.new(enemyRoot.Position.X - Root.Position.X, 0, enemyRoot.Position.Z - Root.Position.Z)
	local height = math.abs(enemyRoot.Position.Y - Root.Position.Y)
	local targetBelow = enemyRoot.Position.Y < Root.Position.Y - Config.DirectVerticalTolerance
	if targetBelow and (flat.Magnitude <= 15 or height > flat.Magnitude) then
		local targetGround, foundTargetGround = projectToWalkableGround(enemyRoot.Position, target)
		if foundTargetGround then
			local chosen: Vector3? = nil
			for _, radius in ipairs({ 6, 12 }) do
				for index = 0, 7 do
					local angle = index * math.pi * 2 / 8
					local sample = enemyRoot.Position
						+ Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
					local candidate, foundCandidate = projectToWalkableGround(sample, target)
					if foundCandidate and math.abs(candidate.Y - targetGround.Y) <= Config.DirectVerticalTolerance then
						chosen = candidate
						break
					end
				end
				if chosen then
					break
				end
			end
			return chosen or targetGround
		end
	end
	local desired = enemyRoot.Position
	if flat.Magnitude > 0.01 then
		local desiredHoldDistance = holdDistance or Config.PreferredCombatDistance
		local horizontalHold = math.sqrt(math.max(0, desiredHoldDistance ^ 2 - height ^ 2))
		desired = enemyRoot.Position - flat.Unit * horizontalHold
	end
	-- Probe downward close to the target Y, avoiding the wrong upper floor that caused the 15-stud deadlock.
	local targetGround, targetGroundFound = projectToWalkableGround(enemyRoot.Position, target)
	local approachGround, approachGroundFound = projectToWalkableGround(desired, target)
	if targetGroundFound and (not approachGroundFound or math.abs(approachGround.Y - targetGround.Y) > 6) then
		return targetGround
	end
	if approachGroundFound then
		return approachGround
	end
	if targetGroundFound then
		return targetGround
	end
	return desired
end

local function targetDistanceBucket(distance: number): number
	if distance <= 50 then
		return 1
	elseif distance <= 100 then
		return 2
	elseif distance <= 150 then
		return 3
	elseif distance <= 200 then
		return 4
	elseif distance <= 300 then
		return 5
	end
	return 6
end

local function acquireBestTarget(): Model?
	if not Root then
		return nil
	end
	local cheapCandidates = {}
	for model in pairs(EnemySet) do
		if not model:IsDescendantOf(workspace) then
			EnemySet[model] = nil
		else
			local enemyHumanoid = model:FindFirstChildOfClass("Humanoid")
			local enemyRoot = getTargetRoot(model)
			if
				not isIgnoredTarget(model)
				and enemyHumanoid
				and enemyRoot
				and enemyRoot:IsDescendantOf(workspace)
				and enemyHumanoid.Health > 0
			then
				local delta = enemyRoot.Position - Root.Position
				if delta.Magnitude <= Config.FarmRange then
					table.insert(cheapCandidates, {
						Model = model,
						Vertical = math.abs(delta.Y),
						Distance = delta.Magnitude,
					})
				end
			else
				EnemySet[model] = nil
			end
		end
	end
	if #cheapCandidates == 0 and os.clock() - RuntimeState.LastFallbackTargetScanAt >= 2 then
		RuntimeState.LastFallbackTargetScanAt = os.clock()
		for _, object in ipairs(workspace:GetDescendants()) do
			if
				object:IsA("Model")
				and object ~= Character
				and not Players:GetPlayerFromCharacter(object)
				and isEnemy(object)
			then
				local enemyHumanoid = object:FindFirstChildOfClass("Humanoid")
				local enemyRoot = getTargetRoot(object)
				if
					not isIgnoredTarget(object)
					and enemyHumanoid
					and enemyRoot
					and enemyRoot:IsDescendantOf(workspace)
					and enemyHumanoid.Health > 0
				then
					local delta = enemyRoot.Position - Root.Position
					if delta.Magnitude <= Config.FarmRange then
							EnemySet[object] = true
							PendingEnemyModels[object] = nil
							table.insert(cheapCandidates, {
							Model = object,
							Vertical = math.abs(delta.Y),
							Distance = delta.Magnitude,
						})
					end
				end
			end
		end
	end
	table.sort(cheapCandidates, function(first, second)
		local firstBucket = targetDistanceBucket(first.Distance)
		local secondBucket = targetDistanceBucket(second.Distance)
		if firstBucket ~= secondBucket then
			return firstBucket < secondBucket
		end
		if first.Distance ~= second.Distance then
			return first.Distance < second.Distance
		end
		return first.Vertical < second.Vertical
	end)
	if not cheapCandidates[1] then
		return nil
	end
	return cheapCandidates[1].Model
end

local function targetMetrics(target: Model?): (number, number)
	if not target or not Root then
		return math.huge, math.huge
	end
	local enemyRoot = getTargetRoot(target)
	if not enemyRoot then
		return math.huge, math.huge
	end
	local delta = enemyRoot.Position - Root.Position
	return math.abs(delta.Y), delta.Magnitude
end

local function updateGlobalStuckJump()
	if RuntimeState.RoundTransitionActive then
		RuntimeState.JumpStillSince = os.clock()
		RuntimeState.JumpBestDistance = math.huge
		RuntimeState.JumpBestVertical = math.huge
		return
	end
	if not Running or not alive() or not Root or not Humanoid then
		RuntimeState.JumpStillSince = os.clock()
		RuntimeState.JumpBestDistance = math.huge
		RuntimeState.JumpBestVertical = math.huge
		return
	end
	local now = os.clock()
	local translating = State == NavigationState.DIRECT
		or State == NavigationState.STEER
		or State == NavigationState.RETREAT
		or State == NavigationState.PATH
		or State == NavigationState.RECOVERY
		or State == NavigationState.EXPLORE
	if not translating then
		RuntimeState.JumpStillSince = now
		RuntimeState.JumpBestDistance = math.huge
		RuntimeState.JumpBestVertical = math.huge
		return
	end
	local targetRoot = if validTarget(Target) then getTargetRoot(Target) else nil
	-- PATH progress must be measured against the active waypoint, not directly
	-- against the enemy. A valid route can temporarily move away from the enemy
	-- to get around a BasicPart, which used to make the global watchdog reset a
	-- character that was following its path correctly.
	local objectivePosition = if State == NavigationState.PATH
		then upcomingMovementGoal()
		else if targetRoot then targetRoot.Position else upcomingMovementGoal()
	if not objectivePosition then
		RuntimeState.JumpStillSince = now
		RuntimeState.JumpBestDistance = math.huge
		RuntimeState.JumpBestVertical = math.huge
		return
	end
	local delta = objectivePosition - Root.Position
	local distance, vertical = delta.Magnitude, math.abs(delta.Y)
	if RuntimeState.JumpBestDistance == math.huge then
		RuntimeState.JumpBestDistance = distance
		RuntimeState.JumpBestVertical = vertical
		RuntimeState.JumpStillSince = now
		return
	end
	local progressThreshold = Config.MeaningfulProgressDistance
	local progressed = distance <= RuntimeState.JumpBestDistance - progressThreshold
		or vertical <= RuntimeState.JumpBestVertical - progressThreshold
	if progressed then
		RuntimeState.JumpBestDistance = math.min(RuntimeState.JumpBestDistance, distance)
		RuntimeState.JumpBestVertical = math.min(RuntimeState.JumpBestVertical, vertical)
		RuntimeState.JumpStillSince = now
	elseif now - RuntimeState.JumpStillSince >= Config.RespawnStuckTime and not RespawnInProgress then
		recoverByRespawn(nil, nil, false, RuntimeState.JumpStillSince)
	end
end

local function guiRoots(): { Instance }
	local roots: { Instance } = { PlayerGui }
	if type(gethui) == "function" then
		local ok, hiddenUi = pcall(gethui)
		if ok and typeof(hiddenUi) == "Instance" then
			table.insert(roots, hiddenUi)
		end
	end
	return roots
end

local function visibleGui(object: Instance): boolean
	local current: Instance? = object
	while current do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		elseif current:IsA("ScreenGui") and not current.Enabled then
			return false
		end
		current = current.Parent
	end
	return true
end

local function buttonHasText(button: GuiButton, expected: string): boolean
	local function matches(object: Instance): boolean
		return (object:IsA("TextButton") or object:IsA("TextLabel"))
			and visibleGui(object)
			and object.Text:lower():match("^%s*(.-)%s*$") == expected
	end
	if matches(button) then
		return true
	end
	for _, child in ipairs(button:GetDescendants()) do
		if matches(child) then
			return true
		end
	end
	return false
end

local function findReplayButton(): GuiButton?
	for _, uiRoot in ipairs(guiRoots()) do
		for _, object in ipairs(uiRoot:GetDescendants()) do
			if object:IsA("GuiButton") and visibleGui(object) and buttonHasText(object, "yes") then
				local modal: Instance? = object.Parent
				for _ = 1, 8 do
					if not modal or not modal:IsA("GuiObject") then
						break
					end
					local hasNo = false
					local hasReplayClue = false
					for _, child in ipairs(modal:GetDescendants()) do
						if child:IsA("GuiButton") and visibleGui(child) then
							hasNo = hasNo or buttonHasText(child, "no") or buttonHasText(child, "cancel")
						end
						if (child:IsA("TextLabel") or child:IsA("TextButton")) and visibleGui(child) then
							local text = child.Text:lower()
							hasReplayClue = hasReplayClue
								or text:find("replay", 1, true) ~= nil
								or text:find("again", 1, true) ~= nil
								or text:find("retry", 1, true) ~= nil
								or text:find("dungeon", 1, true) ~= nil
						end
					end
					if hasNo and hasReplayClue then
						if RuntimeState.ReplayConfirmRoot ~= modal then
							print("[REPLAY] confirm detected")
						end
						RuntimeState.ReplayConfirmRoot = modal
						RuntimeState.ReplayModal = modal
						return object
					end
					modal = modal.Parent
				end
			end
		end
	end
	return nil
end

local function tryReplayDungeon()
	local now = os.clock()
	if not Running or not Config.AutoReplay or RuntimeState.ReplayPhase == "IDLE" then
		return
	end
	if now - RuntimeState.ReplayLastGuiScanAt < 0.5 then
		return
	end
	RuntimeState.ReplayLastGuiScanAt = now
	local awaitingClose = RuntimeState.ReplayAwaitingClose
	if
		RuntimeState.ReplayPhase == "CONFIRMING"
		and awaitingClose
		and (not awaitingClose:IsDescendantOf(game) or not visibleGui(awaitingClose))
	then
		RuntimeState.ReplayPhase = "WAIT_NEW_ROUND"
		RuntimeState.ReplayAwaitingClose = nil
	end
	if RuntimeState.ReplayPhase == "WAIT_NEW_ROUND" then
		return
	end
	if not RuntimeState.ReplayCompletionDetected then
		for _, uiRoot in ipairs(guiRoots()) do
			for _, object in ipairs(uiRoot:GetDescendants()) do
				if (object:IsA("TextLabel") or object:IsA("TextButton")) and visibleGui(object) then
					local normalized = object.Text:lower():gsub("[%s%p_]", "")
					if normalized:find("dungeoncompleted", 1, true) then
						local completionRoot: Instance? = object.Parent
						while completionRoot and not completionRoot:IsA("GuiObject") do
							completionRoot = completionRoot.Parent
						end
						RuntimeState.ReplayCompletionRoot = if completionRoot and completionRoot:IsA("GuiObject")
							then completionRoot
							else nil
						RuntimeState.ReplayCompletionDetected = true
						print("[REPLAY] COMPLETE")
						break
					end
				end
			end
			if RuntimeState.ReplayCompletionDetected then
				break
			end
		end
		if not RuntimeState.ReplayCompletionDetected then
			return
		end
		RuntimeState.ReplayPhase = "OPENING"
	end
	if RuntimeState.ReplayCompletionDetected and RuntimeState.ReplayPhase == "ARMED" then
		RuntimeState.ReplayPhase = "OPENING"
	end

	local confirmation = RuntimeState.ReplayYesButton
	if not confirmation or not confirmation:IsDescendantOf(game) or not visibleGui(confirmation) then
		confirmation = findReplayButton()
		RuntimeState.ReplayYesButton = confirmation
	end
	if confirmation then
		if RuntimeState.ReplayPhase ~= "CONFIRMING" then
			RuntimeState.ReplayPhase = "CONFIRMING"
			print("[REPLAY] confirm detected")
		end
		if RuntimeState.ReplayDebugButton ~= confirmation then
			RuntimeState.ReplayDebugButton = confirmation
			print("[REPLAY] YES=" .. confirmation:GetFullName())
		end
		local issued = false
		if type(firesignal) == "function" then
			issued = pcall(function()
				firesignal(confirmation.Activated)
			end)
		end
		if not issued then
			pcall(function()
				confirmation:Activate()
			end)
		end
		print("[REPLAY] YES attempted")
		RuntimeState.ReplayAwaitingClose = confirmation
		RuntimeState.ReplayLastActionAt = now
		RuntimeState.sendStatusWebhook("REPLAY_SENT")
		return
	end

	local cachedOpener = RuntimeState.ReplayOpener
	if
		RuntimeState.ReplayPhase == "OPENING"
		and cachedOpener
		and (not cachedOpener:IsDescendantOf(game) or not visibleGui(cachedOpener))
	then
		RuntimeState.ReplayPhase = "CONFIRMING"
	end
	if RuntimeState.ReplayPhase == "CONFIRMING" then
		return
	end
	local debugCandidates: { string } = {}
	for _, uiRoot in ipairs(guiRoots()) do
		for _, object in ipairs(uiRoot:GetDescendants()) do
			if (object:IsA("TextLabel") or object:IsA("TextButton")) and visibleGui(object) then
				local normalized = object.Text:lower():gsub("[%s%p_]", "")
				local relevant = normalized:find("replay", 1, true) ~= nil
					or normalized:find("complete", 1, true) ~= nil
					or normalized == "yes"
					or normalized == "no"
				if relevant then
					table.insert(debugCandidates, object.Text .. " @ " .. object:GetFullName())
				end
				if
					normalized == "replay"
					or normalized == "replaydungeon"
					or normalized == "playagain"
					or normalized == "retry"
				then
					local opener: GuiButton? = if object:IsA("GuiButton") then object else nil
					local ancestor = object.Parent
					for _ = 1, 8 do
						if opener or not ancestor then
							break
						end
						if ancestor:IsA("GuiButton") then
							opener = ancestor
							break
						end
						ancestor = ancestor.Parent
					end
					if opener and visibleGui(opener) then
						local completionRoot: GuiObject? = nil
						local context: Instance? = opener.Parent
						for _ = 1, 8 do
							if not context or not context:IsA("GuiObject") then
								break
							end
							local hasCompletionClue = false
							for _, child in ipairs(context:GetDescendants()) do
								if (child:IsA("TextLabel") or child:IsA("TextButton")) and visibleGui(child) then
									local text = child.Text:lower()
									hasCompletionClue = hasCompletionClue
										or text:find("completed", 1, true) ~= nil
										or text:find("dungeon", 1, true) ~= nil
								end
							end
							if hasCompletionClue then
								completionRoot = context
								break
							end
							context = context.Parent
						end
						if completionRoot then
							RuntimeState.ReplayCompletionRoot = completionRoot
							RuntimeState.ReplayOpener = opener
							print("[REPLAY] opener=" .. opener:GetFullName())
							local issued = false
							if type(firesignal) == "function" then
								issued = pcall(function()
									firesignal(opener.Activated)
								end)
							end
							if not issued then
								pcall(function()
									opener:Activate()
								end)
							end
							print("[REPLAY] opener attempted")
							return
						end
					end
				end
			end
		end
	end
	if not RuntimeState.ReplayOpenerMissingReported and now - RuntimeState.ReplayArmedAt >= 2 then
		RuntimeState.ReplayOpenerMissingReported = true
		print("[REPLAY] opener not found")
		for _, candidate in ipairs(debugCandidates) do
			print("[REPLAY] candidate=" .. candidate)
		end
	end
end

local function armReplayToken(reason: string)
	if Config.AutoReplay and RuntimeState.ReplayPhase == "IDLE" then
		RuntimeState.ReplayArmedAt = os.clock()
		RuntimeState.ReplayPhase = "ARMED"
		RuntimeState.ReplayCompletionRoot = nil
		RuntimeState.ReplayOpener = nil
		RuntimeState.ReplayConfirmRoot = nil
		RuntimeState.ReplayYesButton = nil
		RuntimeState.ReplayLastGuiScanAt = -math.huge
		RuntimeState.ReplayOpenerMissingReported = false
		print("[REPLAY] ARMED reason=" .. reason)
		telemetry("REPLAY_ARM", reason)
		RuntimeState.sendStatusWebhook("REPLAY_ARMED")
	end
end

RuntimeState.refreshDungeonReferences = function()
	local activeRoot = RuntimeState.ActiveDungeonRoot
	if activeRoot and not activeRoot:IsDescendantOf(workspace) then
		RuntimeState.ActiveDungeonRoot = nil
		RuntimeState.FightingBossInstance = nil
		RuntimeState.EnemyFolderInstance = nil
		RuntimeState.DungeonFinishedInstance = nil
		RuntimeState.DungeonTimeInstance = nil
		activeRoot = nil
	end
	local timeText = RuntimeState.DungeonTimeText
	if timeText and (not timeText:IsDescendantOf(game) or not visibleGui(timeText)) then
		RuntimeState.DungeonTimeText = nil
	end
	local now = os.clock()
	if now - RuntimeState.LastDungeonReferenceSearchAt < 1 then
		return
	end
	RuntimeState.LastDungeonReferenceSearchAt = now
	if not activeRoot then
		local bestBoss: BoolValue? = nil
		local bestRoot: Instance? = nil
		local bestScore = -math.huge
		for _, candidate in ipairs(workspace:GetDescendants()) do
			if candidate:IsA("BoolValue") and candidate.Name:lower() == "fightingboss" then
				local ancestor = candidate.Parent
				local depth = 0
				while ancestor and ancestor ~= workspace and depth < 8 do
					local score = (candidate.Value and 100 or 0) - depth
					if ancestor:FindFirstChild("enemyFolder", true) then
						score += 8
					end
					if ancestor:FindFirstChild("dungeonFinished", true) then
						score += 4
					end
					if ancestor:FindFirstChild("timeleft", true) then
						score += 2
					end
					if score > bestScore then
						bestScore, bestBoss, bestRoot = score, candidate, ancestor
					end
					ancestor = ancestor.Parent
					depth += 1
				end
			end
		end
		RuntimeState.ActiveDungeonRoot = bestRoot
		RuntimeState.FightingBossInstance = bestBoss
		activeRoot = bestRoot
	end
	if activeRoot then
		local boss = RuntimeState.FightingBossInstance
		if not boss or not boss:IsDescendantOf(activeRoot) then
			local candidate = activeRoot:FindFirstChild("fightingBoss", true)
			RuntimeState.FightingBossInstance = if candidate and candidate:IsA("BoolValue") then candidate else nil
		end
		local enemyFolder = activeRoot:FindFirstChild("enemyFolder", true)
		RuntimeState.EnemyFolderInstance = enemyFolder
		local finished = activeRoot:FindFirstChild("dungeonFinished", true)
		RuntimeState.DungeonFinishedInstance = if finished and finished:IsA("BoolValue") then finished else nil
		local timeleft = activeRoot:FindFirstChild("timeleft", true)
		RuntimeState.DungeonTimeInstance = if timeleft
				and (timeleft:IsA("NumberValue") or timeleft:IsA("IntValue") or timeleft:IsA("StringValue"))
			then timeleft
			else nil
	end
	if not RuntimeState.DungeonTimeText then
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.zero
		for _, uiRoot in ipairs(guiRoots()) do
			for _, object in ipairs(uiRoot:GetDescendants()) do
				if (object:IsA("TextLabel") or object:IsA("TextButton")) and visibleGui(object) then
					local lower = object.Text:lower()
					local isTimer = object.Text:match("^%s*%d+:%d%d%s*$") ~= nil
					local topCenter = viewport.X <= 0
						or (
							math.abs((object.AbsolutePosition.X + object.AbsoluteSize.X * 0.5) - viewport.X * 0.5)
								<= viewport.X * 0.3
							and object.AbsolutePosition.Y <= viewport.Y * 0.35
						)
					if
						isTimer
						and topCenter
						and not lower:find("paused", 1, true)
						and not lower:find("boost", 1, true)
						and not lower:find("xp", 1, true)
					then
						RuntimeState.DungeonTimeText = object
						return
					end
				end
			end
		end
	end
end

RuntimeState.remainingDungeonTime = function(): number?
	RuntimeState.refreshDungeonReferences()
	local timeleft = RuntimeState.DungeonTimeInstance
	if timeleft and (timeleft:IsA("NumberValue") or timeleft:IsA("IntValue")) then
		return timeleft.Value
	elseif timeleft and timeleft:IsA("StringValue") then
		local minutes, seconds = timeleft.Value:match("(%d+):(%d%d)")
		if minutes and seconds then
			return tonumber(minutes) * 60 + tonumber(seconds)
		end
	end
	local timeText = RuntimeState.DungeonTimeText
	if timeText and (timeText:IsA("TextLabel") or timeText:IsA("TextButton")) and visibleGui(timeText) then
		local minutes, seconds = timeText.Text:match("(%d+):(%d%d)")
		if minutes and seconds then
			return tonumber(minutes) * 60 + tonumber(seconds)
		end
	end
	return nil
end

local function normalizeStartText(value: string): string
	return value:lower():gsub("[%s%p_]", "")
end

local function startMarkerText(object: GuiObject): string?
	if not (object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox")) then
		return nil
	end
	local content = ""
	pcall(function()
		content = object.ContentText
	end)
	return content ~= "" and content or object.Text
end

local function findStartMarker(): GuiObject?
	local nameFallback: GuiObject? = nil
	for _, uiRoot in ipairs(guiRoots()) do
		for _, object in ipairs(uiRoot:GetDescendants()) do
			if object:IsA("GuiObject") and visibleGui(object) then
				local text = startMarkerText(object)
				if text and normalizeStartText(text) == "start" then
					return object
				end
				if not nameFallback then
					local normalizedName = normalizeStartText(object.Name)
					if
						normalizedName == "start"
						or normalizedName == "startbutton"
						or normalizedName == "startlabel"
						or normalizedName == "startimage"
					then
						nameFallback = object
					end
				end
			end
		end
	end
	return nameFallback
end

local resolveStartButton

local function cachedStartScreen(): (GuiObject?, GuiButton?)
	local marker = RuntimeState.StartMarker
	if marker and marker:IsDescendantOf(game) and visibleGui(marker) then
		local currentText = startMarkerText(marker)
		if currentText and normalizeStartText(currentText) == "start" then
			local button = RuntimeState.StartButton
			if
				button
				and button:IsDescendantOf(game)
				and visibleGui(button)
				and (button == marker or button:IsDescendantOf(marker) or marker:IsDescendantOf(button))
			then
				return marker, button
			end
			local refreshedButton = resolveStartButton(marker)
			RuntimeState.StartButton = refreshedButton
			return marker, refreshedButton
		end
		print("[START] cache=INVALID_TEXT")
	end
	RuntimeState.StartMarker = nil
	RuntimeState.StartButton = nil
	RuntimeState.StartDebugMarker = nil
	RuntimeState.StartDebugButton = nil
	local now = os.clock()
	if now - RuntimeState.LastStartMarkerScanAt < 0.5 then
		return nil, nil
	end
	RuntimeState.LastStartMarkerScanAt = now
	marker = findStartMarker()
	RuntimeState.StartMarker = marker
	RuntimeState.StartButton = marker and resolveStartButton(marker) or nil
	return RuntimeState.StartMarker, RuntimeState.StartButton
end

resolveStartButton = function(marker: GuiObject): GuiButton?
	if marker:IsA("GuiButton") then
		return marker
	end
	local current: Instance? = marker.Parent
	for _ = 1, 8 do
		if current and current:IsA("GuiButton") then
			return current
		end
		current = current and current.Parent or nil
	end
	local center = marker.AbsolutePosition + marker.AbsoluteSize * 0.5
	for _, object in ipairs(PlayerGui:GetGuiObjectsAtPosition(center.X, center.Y)) do
		if
			object:IsA("GuiButton")
			and visibleGui(object)
			and (object == marker or object:IsDescendantOf(marker) or marker:IsDescendantOf(object))
		then
			return object
		end
	end
	return nil
end

local function getVimClickPoint(guiObject: GuiObject, xRatio: number, yRatio: number): (number, number, Vector2)
	local point = guiObject.AbsolutePosition
		+ Vector2.new(guiObject.AbsoluteSize.X * xRatio, guiObject.AbsoluteSize.Y * yRatio)
	local screenGui: ScreenGui? = nil
	local current: Instance? = guiObject
	while current do
		if current:IsA("ScreenGui") then
			screenGui = current
			break
		end
		current = current.Parent
	end
	local inset = select(1, GuiService:GetGuiInset())
	if screenGui and not screenGui.IgnoreGuiInset then
		point += inset
	end
	return point.X, point.Y, inset
end

local function tryStartDungeon(): boolean
	local marker, cachedButton = cachedStartScreen()
	if not marker then
		return false
	end
	if not Running or not Config.AutoStart or os.clock() - LastStartClickAt < 1 then
		return true
	end
	LastStartClickAt = os.clock()
	local button = cachedButton
	local clickTarget = button or marker
	local clickX, clickY, inset = getVimClickPoint(clickTarget, 0.5, 0.55)
	if RuntimeState.StartDebugMarker ~= marker or RuntimeState.StartDebugButton ~= button then
		RuntimeState.StartDebugMarker = marker
		RuntimeState.StartDebugButton = button
		print(string.format("[START] marker=%s class=%s", marker:GetFullName(), marker.ClassName))
		print(string.format("[START] button=%s", button and button:GetFullName() or "nil"))
		print(
			string.format(
				"[START] pos=%s size=%s",
				tostring(clickTarget.AbsolutePosition),
				tostring(clickTarget.AbsoluteSize)
			)
		)
		print(string.format("[START] inset=%s", tostring(inset)))
		print(string.format("[START] finalClick=%.1f,%.1f", clickX, clickY))
	end
	local physicalClickIssued = pcall(function()
		VirtualInputManager:SendMouseMoveEvent(clickX, clickY, game)
	end)
	if physicalClickIssued then
		local executionGeneration = RuntimeState.Generation
		task.delay(0.05, function()
			if not isCurrentExecution() or RuntimeState.Generation ~= executionGeneration then
				return
			end
			pcall(function()
				VirtualInputManager:SendMouseButtonEvent(clickX, clickY, 0, true, game, 0)
			end)
			task.delay(0.04, function()
				if not isCurrentExecution() or RuntimeState.Generation ~= executionGeneration then
					return
				end
				pcall(function()
					VirtualInputManager:SendMouseButtonEvent(clickX, clickY, 0, false, game, 0)
				end)
			end)
		end)
	end
	if button then
		telemetry("START", button:GetFullName())
		if not physicalClickIssued then
			local signalIssued = false
			if type(firesignal) == "function" then
				signalIssued = pcall(function()
					firesignal(button.MouseButton1Click)
				end)
			end
			if not signalIssued then
				pcall(function()
					button:Activate()
				end)
			end
		end
	else
		telemetry("START", "visible text without clickable ancestor")
	end
	return true
end

local function clearAimObjects()
	if AimAlignment then
		AimAlignment:Destroy()
		AimAlignment = nil
	end
	if AimAttachment then
		AimAttachment:Destroy()
		AimAttachment = nil
	end
end

local function ensureAimObjects()
	if not Root or AimAlignment then
		return
	end
	AimAttachment = Instance.new("Attachment")
	AimAttachment.Name = "AutoFarmAimAttachment"
	AimAttachment.Parent = Root
	AimAlignment = Instance.new("AlignOrientation")
	AimAlignment.Name = "AutoFarmAim"
	AimAlignment.Attachment0 = AimAttachment
	AimAlignment.Mode = Enum.OrientationAlignmentMode.OneAttachment
	AimAlignment.MaxTorque = 100000
	AimAlignment.Responsiveness = 35
	AimAlignment.RigidityEnabled = false
	AimAlignment.Enabled = false
	AimAlignment.Parent = Root
end

local function restoreRotation()
	if AimAlignment then
		AimAlignment.Enabled = false
	end
	if Humanoid then
		Humanoid.AutoRotate = DefaultAutoRotate
	end
end

local function faceTarget(enemyRoot: BasePart)
	if not Root or not Humanoid then
		return
	end
	local direction = Vector3.new(enemyRoot.Position.X - Root.Position.X, 0, enemyRoot.Position.Z - Root.Position.Z)
	if direction.Magnitude <= 0.01 then
		return
	end
	ensureAimObjects()
	Humanoid.AutoRotate = false
	if AimAlignment then
		AimAlignment.Enabled = true
		AimAlignment.CFrame = CFrame.lookAt(Vector3.zero, direction.Unit)
	end
end

local function updateTargetFacing()
	if Target and validTarget(Target) then
		local enemyRoot = getTargetRoot(Target)
		if enemyRoot then
			faceTarget(enemyRoot)
			return
		end
	end
	restoreRotation()
end

local function sendKey(key: Enum.KeyCode)
	pcall(function()
		VirtualInputManager:SendKeyEvent(true, key, false, game)
		VirtualInputManager:SendKeyEvent(false, key, false, game)
	end)
end

local function activateSkill(toolName: string, key: Enum.KeyCode): boolean
	if Config.UseTool and Character then
		local tool = Character:FindFirstChild(toolName)
		if tool and tool:IsA("Tool") and tool.Enabled then
			local ok = pcall(function()
				tool:Activate()
			end)
			if ok then
				telemetry("SKILL_" .. toolName, "method=tool")
				return true
			end
		end
	end
	local virtualKey = if toolName == Config.SkillQToolName or key == Enum.KeyCode.Q then 0x51 else 0x45
	if type(keypress) == "function" and type(keyrelease) == "function" then
		local ok = pcall(function()
			keypress(virtualKey)
		end)
		if ok then
			local executionGeneration = RuntimeState.Generation
			task.delay(0.03, function()
				if not isCurrentExecution() or RuntimeState.Generation ~= executionGeneration then
					return
				end
				pcall(function()
					keyrelease(virtualKey)
				end)
			end)
			telemetry("SKILL_" .. toolName, "method=keypress")
			return true
		end
	end
	local ok = pcall(function()
		VirtualInputManager:SendKeyEvent(true, key, false, game)
	end)
	if ok then
		local executionGeneration = RuntimeState.Generation
		task.delay(0.03, function()
			if not isCurrentExecution() or RuntimeState.Generation ~= executionGeneration then
				return
			end
			pcall(function()
				VirtualInputManager:SendKeyEvent(false, key, false, game)
			end)
		end)
		telemetry("SKILL_" .. toolName, "method=virtual-input")
	end
	return ok
end

local function useCombatSkills(enemyRoot: BasePart, distance3D: number)
	local activeSkillRange = Target and skillRangeForTarget(Target) or Config.NormalSkillRange
	if os.clock() < RuntimeState.RespawnRushUntil then
		return
	end
	-- Skill range is independent from the hold distance: cast as soon as a valid
	-- target enters Q/E range, including while the controller is approaching.
	if not Target or not validTarget(Target) or distance3D > activeSkillRange then
		return
	end
	local now = os.clock()
	if now >= NextQAt then
		local minimum = math.max(0.1, Config.QCooldownMin)
		local maximum = math.max(minimum, Config.QCooldownMax)
		if activateSkill(Config.SkillQToolName, Enum.KeyCode.Q) then
			NextQAt = now + minimum + math.random() * (maximum - minimum)
		end
	end
	if now >= NextEAt then
		if activateSkill(Config.SkillEToolName, Enum.KeyCode.E) then
			NextEAt = now + math.max(0.1, Config.ECooldown)
		end
	end
end

local function useNormalAttack(distance3D: number)
	if
		not validTarget(Target)
		or distance3D > Config.AttackRange
		or os.clock() - LastAttack < Config.AttackCooldown
	then
		return
	end
	LastAttack = os.clock()
	if not Character then
		return
	end
	local fallbackTool: Tool? = nil
	for _, object in ipairs(Character:GetChildren()) do
		if object:IsA("Tool") then
			fallbackTool = fallbackTool or object
			if object.Name ~= Config.SkillQToolName and object.Name ~= Config.SkillEToolName then
				object:Activate()
				return
			end
		end
	end
	if fallbackTool then
		fallbackTool:Activate()
	end
end

local function resolvePlayerControls()
	if PlayerControls then
		return PlayerControls
	end
	local playerScripts = Player:FindFirstChild("PlayerScripts")
	local playerModuleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModuleScript or not playerModuleScript:IsA("ModuleScript") then
		return nil
	end
	local ok, controls = pcall(function()
		local playerModule = require(playerModuleScript)
		return playerModule:GetControls()
	end)
	if ok and controls then
		PlayerControls = controls
		return controls
	end
	return nil
end

local function disablePlayerControls()
	if PlayerControlsDisabled then
		return
	end
	local controls = resolvePlayerControls()
	if not controls or type(controls.Disable) ~= "function" then
		if PlayerControlsResolvePending then
			return
		end
		PlayerControlsResolvePending = true
		local executionGeneration = RuntimeState.Generation
		task.defer(function()
			local playerScripts = Player:WaitForChild("PlayerScripts", 5)
			if playerScripts then
				playerScripts:WaitForChild("PlayerModule", 5)
			end
			PlayerControlsResolvePending = false
			if isCurrentExecution() and RuntimeState.Generation == executionGeneration and Running and not PlayerControlsDisabled then
				local retryControls = resolvePlayerControls()
				if retryControls and type(retryControls.Disable) == "function" then
					local ok = pcall(function()
						retryControls:Disable()
					end)
					if ok then
						PlayerControlsDisabled = true
					end
				end
			end
		end)
		return
	end
	local ok = pcall(function()
		controls:Disable()
	end)
	if ok then
		PlayerControlsDisabled = true
	end
end

local function enablePlayerControls()
	if not PlayerControlsDisabled then
		return
	end
	local controls = PlayerControls or resolvePlayerControls()
	if not controls or type(controls.Enable) ~= "function" then
		PlayerControlsDisabled = false
		return
	end
	local ok = pcall(function()
		controls:Enable()
	end)
	if ok then
		PlayerControlsDisabled = false
	end
end

local function applyMovementSpeed()
	if not Humanoid or SpeedApplied then
		return
	end
	DefaultWalkSpeed = Humanoid.WalkSpeed
	AppliedWalkSpeed = DefaultWalkSpeed * Config.MovementSpeedMultiplier
	Humanoid.WalkSpeed = AppliedWalkSpeed
	SpeedApplied = true
end

local function restoreMovementSpeed()
	if Humanoid and SpeedApplied and AppliedWalkSpeed and math.abs(Humanoid.WalkSpeed - AppliedWalkSpeed) <= 0.05 then
		Humanoid.WalkSpeed = DefaultWalkSpeed
	end
	AppliedWalkSpeed = nil
	SpeedApplied = false
end

stopTranslation = function()
	if Humanoid then
		Humanoid:Move(Vector3.zero, false)
	end
end

local function disposePath()
	disconnect(PathBlockedConnection)
	PathBlockedConnection = nil
	if ActivePath then
		ActivePath:Destroy()
	end
	ActivePath = nil
	PathWaypoints = nil
	PathIndex = 2
	PathGoal = nil
	PathNeedsRebuild = false
	PathIssuedIndex = 0
	PathIssuedAt = 0
	PathBestWaypointDistance = math.huge
	ActivePathGeneration = 0
	ActiveWaypointIssueSerial = 0
end

local function cancelPathRequest()
	PathRequestSerial += 1
	PathComputing = false
	disposePath()
end

setNavigationState = function(newState: string)
	if State == newState then
		return
	end
	telemetry("STATE", State .. " -> " .. newState)
	State = newState
end

local function resetProgress(target: Model?, goal: Vector3?)
	ProgressTarget = target
	ProgressGoalAnchor = goal
	BestGoalMetric = math.huge
	BestVerticalDifference = math.huge
	LastMeaningfulProgressAt = os.clock()
	LastProgressCheckAt = 0
	LastStuckPathRetryAt = -math.huge
	LowSpeedSince = nil
	LastLowSpeedPathRetryAt = -math.huge
	RecoveryGoal = nil
	RecoveryUntil = 0
	SteeringTried = false
end

local function pathRemainingMetric(): number
	if not Root or not NavigationGoal then
		return math.huge
	end
	if State ~= NavigationState.PATH or not PathWaypoints or not PathWaypoints[PathIndex] then
		return (NavigationGoal - Root.Position).Magnitude
	end
	local metric = (PathWaypoints[PathIndex].Position - Root.Position).Magnitude
	for index = PathIndex, #PathWaypoints - 1 do
		metric += (PathWaypoints[index + 1].Position - PathWaypoints[index].Position).Magnitude
	end
	metric += (NavigationGoal - PathWaypoints[#PathWaypoints].Position).Magnitude
	return metric
end

local function markMeaningfulProgress()
	LastMeaningfulProgressAt = os.clock()
	BestGoalMetric = pathRemainingMetric()
end

local function updateProgressTracking()
	if not Root or not Target or not NavigationGoal then
		return
	end
	local now = os.clock()
	if ProgressTarget ~= Target or not ProgressGoalAnchor then
		resetProgress(Target, NavigationGoal)
		return
	end
	if now - LastProgressCheckAt < Config.ProgressCheckInterval then
		return
	end
	LastProgressCheckAt = now
	local metric = pathRemainingMetric()
	local enemyRoot = getTargetRoot(Target)
	local vertical = enemyRoot and math.abs(enemyRoot.Position.Y - Root.Position.Y) or math.huge
	local verticalProgress = BestVerticalDifference < math.huge
		and vertical <= BestVerticalDifference - Config.MeaningfulProgressDistance
	if BestVerticalDifference == math.huge then
		BestVerticalDifference = vertical
	elseif verticalProgress then
		BestVerticalDifference = vertical
	end
	if BestGoalMetric == math.huge then
		BestGoalMetric = metric
	elseif metric <= BestGoalMetric - Config.MeaningfulProgressDistance or verticalProgress then
		BestGoalMetric = metric
		LastMeaningfulProgressAt = now
	end
end

local function rayClearance(origin: Vector3, direction: Vector3, target: Model?): number
	local result = workspace:Raycast(
		origin + Vector3.new(0, 2.5, 0),
		direction.Unit * Config.DetourProbeDistance,
		makeRaycastParams(target)
	)
	return result and result.Distance or Config.DetourProbeDistance
end

local function chooseRecoveryDetour(goal: Vector3, retreat: boolean?): Vector3?
	if not Root then
		return nil
	end
	local flatGoal = Vector3.new(goal.X - Root.Position.X, 0, goal.Z - Root.Position.Z)
	if flatGoal.Magnitude <= 0.01 then
		return nil
	end
	local forward = flatGoal.Unit
	local candidates = {}
	local angle = math.atan2(forward.Z, forward.X)
	for index = 0, 11 do
		local heading = angle + index * math.pi / 6
		table.insert(candidates, Vector3.new(math.cos(heading), 0, math.sin(heading)))
	end
	local bestGoal: Vector3? = nil
	local bestScore = -math.huge
	for _, direction in ipairs(candidates) do
		local clearance = rayClearance(Root.Position, direction, Target)
		local candidate = Root.Position + direction * math.max(3, clearance - 1.5)
		local grounded, foundGround = projectToWalkableGround(candidate, Target)
		if
			foundGround
			and directRouteClear(grounded, Target)
			and dodgeRouteClear(grounded)
			and pointIsSafeFromHazards(grounded)
		then
			local goalGain = (goal - Root.Position).Magnitude - (goal - grounded).Magnitude
			local heightGain = math.abs(goal.Y - Root.Position.Y) - math.abs(goal.Y - grounded.Y)
			local score = clearance + goalGain * 2 + heightGain + forward:Dot(direction) * 3
			if score > bestScore and (not retreat or goalGain > 1) then
				bestScore, bestGoal = score, grounded
			end
		end
	end
	return bestGoal
end

local function beginLocalRecovery(goal: Vector3)
	RecoveryGoal = chooseRecoveryDetour(goal)
	RecoveryUntil = os.clock() + Config.DetourDuration
	setNavigationState(NavigationState.RECOVERY)
end

local function issueCurrentWaypoint()
	if State ~= NavigationState.PATH or not Humanoid or not Root or not PathWaypoints then
		return
	end
	local waypoint = PathWaypoints[PathIndex]
	if not waypoint then
		disposePath()
		setNavigationState(NavigationState.IDLE)
		return
	end
	if PathIssuedIndex == PathIndex then
		return
	end
	PathIssuedIndex = PathIndex
	PathIssuedAt = os.clock()
	PathBestWaypointDistance = (waypoint.Position - Root.Position).Magnitude
	WaypointIssueSerial += 1
	ActiveWaypointIssueSerial = WaypointIssueSerial
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		Humanoid.Jump = true
	end
	-- Do not hand this waypoint to MoveTo. A BasicPart edge can cancel Roblox's
	-- one-shot MoveTo command and leave PATH visually active but stationary.
	local direction = Vector3.new(waypoint.Position.X - Root.Position.X, 0, waypoint.Position.Z - Root.Position.Z)
	Humanoid:Move(direction.Magnitude > 0.001 and direction.Unit or Vector3.zero, false)
end

local function requestPath(goal: Vector3): boolean
	if not alive() or not Target or PathComputing then
		return false
	end
	local now = os.clock()
	if now - LastPathBuildAt < Config.PathRebuildCooldown then
		return false
	end
	PathRequestSerial += 1
	local requestId = PathRequestSerial
	local expectedTarget = Target
	local expectedCharacter = Character
	local origin = Root.Position
	local executionGeneration = RuntimeState.Generation
	PathComputing = true
	LastPathBuildAt = now
	disposePath()
	task.spawn(function()
		local newPath = PathfindingService:CreatePath({
			AgentRadius = Config.AgentRadius,
			AgentHeight = Config.AgentHeight,
			AgentCanJump = true,
			AgentCanClimb = true,
			WaypointSpacing = Config.WaypointSpacing,
		})
		local ok = pcall(function()
			newPath:ComputeAsync(origin, goal)
		end)
		if not isCurrentExecution() or RuntimeState.Generation ~= executionGeneration or requestId ~= PathRequestSerial then
			newPath:Destroy()
			return
		end
		PathComputing = false
		if not Enabled or not Running or not alive() or Target ~= expectedTarget or Character ~= expectedCharacter then
			newPath:Destroy()
			return
		end
		local waypoints = ok and newPath.Status == Enum.PathStatus.Success and newPath:GetWaypoints() or nil
		if not waypoints or #waypoints < 2 then
			newPath:Destroy()
			RecoveryGoal = nil
			RecoveryUntil = 0
			setNavigationState(NavigationState.RECOVERY)
			return
		end
		ActivePath = newPath
		ActivePathGeneration = requestId
		PathWaypoints = waypoints
		PathIndex = 2
		PathGoal = goal
		PathIssuedIndex = 0
		PathNeedsRebuild = false
		ActiveWaypointIssueSerial = 0
		PathBlockedConnection = newPath.Blocked:Connect(function(blockedIndex)
			if ActivePathGeneration == requestId and requestId == PathRequestSerial and blockedIndex >= PathIndex then
				PathNeedsRebuild = true
			end
		end)
		setNavigationState(NavigationState.PATH)
		BestGoalMetric = pathRemainingMetric()
		-- The async compute callback publishes state only. The next Heartbeat issues MoveTo.
	end)
	return true
end

local function updatePathNavigation()
	if State ~= NavigationState.PATH or not Root or not PathWaypoints then
		return
	end
	if PathNeedsRebuild then
		cancelPathRequest()
		beginLocalRecovery(NavigationGoal or Root.Position)
		return
	end
	local waypoint = PathWaypoints[PathIndex]
	if not waypoint then
		disposePath()
		setNavigationState(NavigationState.IDLE)
		return
	end
	-- A published path is not monitorable until its current waypoint has been issued.
	-- Returning here guarantees timeout/progress logic never observes PathIssuedAt == 0.
	if PathIssuedIndex ~= PathIndex or PathIssuedAt <= 0 or ActiveWaypointIssueSerial <= 0 then
		issueCurrentWaypoint()
		return
	end
	local waypointDistance = (waypoint.Position - Root.Position).Magnitude
	-- MoveToFinished carries no path/waypoint identity. Position is the sole safe
	-- completion authority; a delayed event can therefore never advance this path.
	if waypointDistance <= Config.WaypointReachedDistance then
		local advanced = PathBestWaypointDistance - waypointDistance >= Config.MeaningfulProgressDistance
		PathIndex += 1
		PathIssuedIndex = 0
		PathIssuedAt = 0
		ActiveWaypointIssueSerial = 0
		-- The next waypoint is a new navigation objective; do not carry the old
		-- waypoint's distance into the global no-progress watchdog.
		RuntimeState.JumpStillSince = os.clock()
		RuntimeState.JumpBestDistance = math.huge
		RuntimeState.JumpBestVertical = math.huge
		if advanced then
			markMeaningfulProgress()
		end
		issueCurrentWaypoint()
		return
	end
	if waypointDistance <= PathBestWaypointDistance - Config.MeaningfulProgressDistance then
		PathBestWaypointDistance = waypointDistance
		markMeaningfulProgress()
	end
	-- PATH owns translation in this state. Refreshing only the current waypoint
	-- direction keeps the character moving along the computed route even when a
	-- floor BasicPart interrupts the engine's default MoveTo behavior.
	local direction = Vector3.new(waypoint.Position.X - Root.Position.X, 0, waypoint.Position.Z - Root.Position.Z)
	Humanoid:Move(direction.Magnitude > 0.001 and direction.Unit or Vector3.zero, false)
	if PathIssuedIndex == PathIndex and PathIssuedAt > 0 and os.clock() - PathIssuedAt >= Config.WaypointTimeout then
		PathNeedsRebuild = true
		return
	end
end

local function updateDirectMovement()
	if State ~= NavigationState.DIRECT or not Humanoid or not Root or not NavigationGoal then
		return
	end
	local direction = Vector3.new(NavigationGoal.X - Root.Position.X, 0, NavigationGoal.Z - Root.Position.Z)
	if direction.Magnitude <= Config.DirectReachedDistance then
		Humanoid:Move(Vector3.zero, false)
	else
		Humanoid:Move(direction.Unit, false)
	end
end

local function updateRecoveryMovement()
	if
		(State ~= NavigationState.RECOVERY and State ~= NavigationState.STEER and State ~= NavigationState.RETREAT)
		or not Humanoid
		or not Root
	then
		return
	end
	if State == NavigationState.RETREAT and Target and validTarget(Target) then
		local enemyRoot = getTargetRoot(Target)
		if enemyRoot then
			local away = Vector3.new(Root.Position.X - enemyRoot.Position.X, 0, Root.Position.Z - enemyRoot.Position.Z)
			local direction = away.Magnitude > 0.1 and away.Unit or Vector3.xAxis
			local retreatPoint, foundGround = projectToWalkableGround(Root.Position + direction * 7, Target)
			if
				foundGround
				and math.abs(retreatPoint.Y - Root.Position.Y) <= Config.DirectVerticalTolerance
				and hasGroundSupport(retreatPoint, Target)
				and directRouteClear(retreatPoint, Target)
			then
				Humanoid:Move(direction, false)
			else
				Humanoid:Move(Vector3.zero, false)
			end
			return
		end
	end
	if State == NavigationState.STEER and RecoveryGoal and os.clock() - LastMeaningfulProgressAt < 1 then
		local heading = Vector3.new(RecoveryGoal.X - Root.Position.X, 0, RecoveryGoal.Z - Root.Position.Z)
		if heading.Magnitude > 0.1 and (heading.Magnitude < 5 or os.clock() >= RecoveryUntil) then
			local extended, found =
				projectToWalkableGround(Root.Position + heading.Unit * Config.DetourProbeDistance, Target)
			if
				found
				and directRouteClear(extended, Target)
				and dodgeRouteClear(extended)
				and pointIsSafeFromHazards(extended)
			then
				RecoveryGoal = extended
				RecoveryUntil = os.clock() + Config.DetourDuration
			end
		end
	end
	if RecoveryGoal and os.clock() < RecoveryUntil then
		local direction = Vector3.new(RecoveryGoal.X - Root.Position.X, 0, RecoveryGoal.Z - Root.Position.Z)
		if direction.Magnitude > Config.WaypointReachedDistance then
			Humanoid:Move(direction.Unit, false)
			return
		end
	end
	Humanoid:Move(Vector3.zero, false)
	-- A recovery detour must own movement long enough to get clear of the
	-- blocking BasicPart. Rebuilding immediately here used to publish a new PATH
	-- before the character had physically left the same blocked edge.
	if State ~= NavigationState.RETREAT and not PathComputing and NavigationGoal then
		requestPath(NavigationGoal)
	end
end

local function decideNavigation()
	if not alive() or not Target or not NavigationGoal then
		return
	end
	local now = os.clock()
	if State == NavigationState.PATH then
		if PathGoal and (NavigationGoal - PathGoal).Magnitude >= Config.PathGoalChangeDistance then
			PathNeedsRebuild = true
		end
		return
	end
	if
		(State == NavigationState.RECOVERY or State == NavigationState.STEER)
		and (PathComputing or now < RecoveryUntil)
	then
		return
	end
	if now - LastDirectDecisionAt < Config.DirectDecisionInterval then
		return
	end
	LastDirectDecisionAt = now
	local progressing = now - LastMeaningfulProgressAt < Config.RecoveryRefreshAt
	local velocity = Root.AssemblyLinearVelocity
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	-- A moving target route may briefly fail a local probe at an edge. Keep DIRECT
	-- while target progress proves that the current command is still productive.
	-- A newly spawned character wedged against a BasicPart is not productive even
	-- though its progress timer was just reset.
	if State == NavigationState.DIRECT and progressing and horizontalSpeed >= Config.SlowMovementSpeedThreshold then
		return
	end
	local delta = NavigationGoal - Root.Position
	local localGoal = Root.Position
		+ (delta.Magnitude > 0.01 and delta.Unit or Vector3.zero)
			* math.min(delta.Magnitude, Config.DetourProbeDistance)
	local grounded = projectToWalkableGround(localGoal, Target)
	local safeDirect = directRouteClear(grounded, Target) and pointIsSafeFromHazards(grounded)
	if safeDirect and (State ~= NavigationState.DIRECT or progressing) then
		disposePath()
		RecoveryGoal = nil
		setNavigationState(NavigationState.DIRECT)
	else
		-- A blocked DIRECT route must start path computation immediately. Waiting for
		-- a full STEER interval made the controller repeatedly resume DIRECT into the
		-- same basic Part, producing bursty stop/start movement at walls and corners.
		SteeringTried = true
		cancelPathRequest()
		beginLocalRecovery(NavigationGoal)
	end
end

local function resetNavigationForTarget(newTarget: Model?)
	RuntimeState.VerticalPathTarget = nil
	RuntimeState.VerticalPathGoal = nil
	if Target ~= newTarget and TargetDiedConnection then
		TargetDiedConnection:Disconnect()
		TargetDiedConnection = nil
	end
	if RuntimeState.BossDiedTarget ~= newTarget then
		if RuntimeState.BossDiedConnection then
			RuntimeState.BossDiedConnection:Disconnect()
			RuntimeState.BossDiedConnection = nil
		end
		RuntimeState.BossDiedTarget = nil
	end
	Target = newTarget
	if newTarget then
		RuntimeState.LastStaleTarget = nil
		print("[TARGET] acquired=" .. newTarget.Name)
	end
	clearExploreObjective()
	if newTarget then
		telemetry("EXPLORE_TARGET", "target=" .. newTarget:GetFullName())
		local targetHumanoid = newTarget:FindFirstChildOfClass("Humanoid")
		if targetHumanoid then
			TargetDiedConnection = targetHumanoid.Died:Connect(function()
				if Target == newTarget then
					EnemySet[newTarget] = nil
					LastTargetAcquireAt = -math.huge
					resetNavigationForTarget(nil)
				end
			end)
		end
		if isBossTarget(newTarget) then
			RuntimeState.sendStatusWebhook("BOSS_DETECTED")
			local bossHumanoid = targetHumanoid
			if bossHumanoid and not RuntimeState.BossDiedConnection then
				RuntimeState.BossDiedTarget = newTarget
				RuntimeState.BossDiedConnection = bossHumanoid.Died:Connect(function()
					armReplayToken("boss-died")
					RuntimeState.sendStatusWebhook("BOSS_DIED")
				end)
			end
		end
	end
	GoalTarget = nil
	NavigationGoal = nil
	LastGoalRefreshAt = 0
	LastDirectDecisionAt = 0
	RecoveryGoal = nil
	RecoveryUntil = 0
	cancelPathRequest()
	LastPathBuildAt = -math.huge
	resetProgress(newTarget, nil)
	setNavigationState(NavigationState.IDLE)
	if not newTarget then
		restoreRotation()
	end
end

local function clearDodgeObjective()
	ActiveHazard = nil
	DodgeGoal = nil
	RuntimeState.DodgeCommitUntil = 0
	RuntimeState.DodgeCachedHazard = nil
	RuntimeState.LastDodgeEvaluationAt = -math.huge
	LastHazardThreatAt = -math.huge
	LastDodgeGoalAttemptAt = -math.huge
end

resetRuntimeForNewDungeon = function()
	RuntimeState.RoundResetSerial += 1
	RuntimeState.RecoverySerial = (RuntimeState.RecoverySerial or 0) + 1
	local resetSerial = RuntimeState.RoundResetSerial
	local executionGeneration = RuntimeState.Generation
	local now = os.clock()
	print("[ROUND] transition=BEGIN")
	RuntimeState.RoundTransitionActive = true
	RuntimeState.RoundBootstrapUntil = now + 7
	RuntimeState.RoundBootstrapAttempts = 0
	RuntimeState.RoundTransitionSerial += 1
	RuntimeState.RoundTransitionStartedAt = now
	RuntimeState.RoundTransitionDeadline = now + 7
	RuntimeState.RoundTransitionTimedOut = false
	RuntimeState.RoundBootstrapLastCacheAt = -math.huge
	cancelPathRequest()
	-- Clear the old target through its normal lifecycle so its death listener,
	-- path and facing state cannot survive into the replayed dungeon.
	resetNavigationForTarget(nil)
	GoalTarget = nil
	NavigationGoal = nil
	RecoveryGoal = nil
	RecoveryUntil = 0
	SteeringTried = false
	clearDodgeObjective()
	DodgeStartedAt = 0
	table.clear(NearbyActiveHazards)
	LastHazardRefreshAt = -math.huge
	clearExploreObjective()
	ExploreHeading = nil
	ExploreBestDistance = math.huge
	LastExploreSelectionAt = -math.huge
	table.clear(ExploredCells)
	table.clear(ExploredCellOrder)
	ProgressTarget = nil
	ProgressGoalAnchor = nil
	BestGoalMetric = math.huge
	BestVerticalDifference = math.huge
	LastMeaningfulProgressAt = now
	LastProgressCheckAt = 0
	LastStuckPathRetryAt = -math.huge
	LowSpeedSince = nil
	LastLowSpeedPathRetryAt = -math.huge
	LastDirectDecisionAt = 0
	LastGoalRefreshAt = 0
	LastPathBuildAt = -math.huge
	ResetExecuting = false
	RespawnInProgress = false
	RuntimeState.JumpBurstGeneration += 1
	RuntimeState.JumpStillSince = now
	RuntimeState.JumpBestDistance = math.huge
	RuntimeState.JumpBestVertical = math.huge
	RuntimeState.JumpBurstUntil = 0
	RuntimeState.JumpBurstTaskRunning = false
	LastTargetAcquireAt = -math.huge
	RuntimeState.LastFallbackTargetScanAt = -math.huge
	NoTargetSince = now
	NextQAt, NextEAt, LastAttack = 0, 0, 0
	State = NavigationState.IDLE
	stopTranslation()
	table.clear(EnemySet)
	table.clear(PendingEnemyModels)
	table.clear(HazardSet)
	table.clear(RuntimeState.HazardMetadata)
	RuntimeState.DungeonFinishedInstance = nil
	RuntimeState.PreviousDungeonFinishedInstance = nil
	RuntimeState.DungeonFinishedLastState = false
	RuntimeState.ActiveDungeonRoot = nil
	RuntimeState.FightingBossInstance = nil
	RuntimeState.EnemyFolderInstance = nil
	RuntimeState.DungeonTimeInstance = nil
	RuntimeState.DungeonTimeText = nil
	RuntimeState.LastDungeonReferenceSearchAt = -math.huge
	RuntimeState.ReplayArmedAt = 0
	RuntimeState.ReplayLastActionAt = -math.huge
	RuntimeState.RespawnRushUntil = 0
	RuntimeState.ReplayAwaitingClose = nil
	RuntimeState.ReplayYesButton = nil
	RuntimeState.ReplayDebugButton = nil
	RuntimeState.ReplayModal = nil
	RuntimeState.ReplayCompletionRoot = nil
	RuntimeState.ReplayOpener = nil
	RuntimeState.ReplayConfirmRoot = nil
	RuntimeState.ReplayPhase = "IDLE"
	RuntimeState.ReplayLastGuiScanAt = -math.huge
	RuntimeState.ReplayOpenerMissingReported = false
	RuntimeState.ReplayCompletionDetected = false
	RuntimeState.LastFightingBossState = false
	RuntimeState.FightingBossSeenThisRound = false
	if RuntimeState.BossDiedConnection then
		RuntimeState.BossDiedConnection:Disconnect()
		RuntimeState.BossDiedConnection = nil
	end
	RuntimeState.BossDiedTarget = nil
	RuntimeState.StartMarker = nil
	RuntimeState.StartButton = nil
	RuntimeState.StartDebugMarker = nil
	RuntimeState.StartDebugButton = nil
	RuntimeState.LastStaleTarget = nil
	RuntimeState.LastStartMarkerScanAt = -math.huge
	RuntimeState.VerticalPathTarget = nil
	RuntimeState.VerticalPathGoal = nil
	local function refreshRoundTargets()
		if
			not isCurrentExecution()
			or RuntimeState.Generation ~= executionGeneration
			or not Running
			or resetSerial ~= RuntimeState.RoundResetSerial
		then
			return
		end
		local attemptNow = os.clock()
		if attemptNow >= RuntimeState.RoundBootstrapUntil then
			RuntimeState.RoundTransitionActive = false
			RuntimeState.RoundTransitionTimedOut = true
			LastMeaningfulProgressAt = attemptNow
			LowSpeedSince = nil
			LastTargetAcquireAt = -math.huge
			print("[ROUND] transition=TIMEOUT")
			return
		end
		RuntimeState.RoundBootstrapAttempts += 1
		print("[ROUND] bootstrap attempt=" .. tostring(RuntimeState.RoundBootstrapAttempts))
		RuntimeState.refreshDungeonReferences()
		local enemyFolder = RuntimeState.EnemyFolderInstance
		local startMarker = cachedStartScreen()
		if enemyFolder and enemyFolder:IsDescendantOf(workspace) and attemptNow - RuntimeState.RoundBootstrapLastCacheAt >= 1 then
			-- The bounded cache refresh covers late enemy replication; events keep
			-- additions warm between attempts without a workspace-wide frame scan.
			RuntimeState.RoundBootstrapLastCacheAt = attemptNow
			buildInitialCaches(enemyFolder)
		end
		LastTargetAcquireAt = -math.huge
		if alive() and not Target then
			local acquired = acquireBestTarget()
			if acquired then
				resetNavigationForTarget(acquired)
				NoTargetSince = nil
			end
		end
		if startMarker or (alive() and enemyFolder and enemyFolder:IsDescendantOf(workspace) and RuntimeState.RoundBootstrapLastCacheAt > -math.huge) then
			RuntimeState.RoundTransitionActive = false
			LastMeaningfulProgressAt = attemptNow
			LowSpeedSince = nil
			print("[ROUND] bootstrap=READY")
			print("[ROUND] transition=END")
			return
		end
		task.delay(0.5, refreshRoundTargets)
	end
	-- Bounded retry handles late replication without relying on fixed long waits.
	task.delay(0.4, refreshRoundTargets)
end

local function leaveDodge()
	telemetry("DODGE_EXIT", ActiveHazard and ("inactive=" .. ActiveHazard:GetFullName()) or "no-active-hazard")
	ActiveHazard = nil
	DodgeGoal = nil
	RuntimeState.DodgeCommitUntil = 0
	RuntimeState.DodgeCachedHazard = nil
	-- Pause, rather than erase, the accumulated no-progress duration.
	local pausedFor = math.max(0, os.clock() - DodgeStartedAt)
	LastMeaningfulProgressAt += pausedFor
	LastExploreMeaningfulProgressAt += pausedFor
	BestGoalMetric = pathRemainingMetric()
	LastDirectDecisionAt = 0
	setNavigationState(NavigationState.IDLE)
	if not Target or not validTarget(Target) then
		restoreRotation()
	end
end

local function updateDodgeController(): boolean
	if not Config.DodgeEnabled then
		if State == NavigationState.DODGE then
			leaveDodge()
		end
		return false
	end

	if not Running or not alive() or not Root or not Humanoid then
		return false
	end
	local now = os.clock()
	local evaluateNow = now - RuntimeState.LastDodgeEvaluationAt >= Config.DodgeEvaluationInterval
	local hazard, predicted, edgeDistance, routeDistance
	if evaluateNow then
		RuntimeState.LastDodgeEvaluationAt = now
		RuntimeState.DodgeRaycastsUsed = 0
		hazard, predicted, edgeDistance, routeDistance = threateningHazard()
		RuntimeState.DodgeCachedHazard = hazard
		RuntimeState.DodgeCachedPredicted = predicted
		RuntimeState.DodgeCachedEdgeDistance = edgeDistance
		RuntimeState.DodgeCachedRouteDistance = routeDistance
	else
		hazard = RuntimeState.DodgeCachedHazard
		predicted = RuntimeState.DodgeCachedPredicted
		edgeDistance = RuntimeState.DodgeCachedEdgeDistance
		routeDistance = RuntimeState.DodgeCachedRouteDistance
	end
	if hazard and not hazard:IsDescendantOf(workspace) then
		hazard = nil
	end
	if not hazard then
		if State == NavigationState.DODGE then
			if os.clock() - LastHazardThreatAt < Config.DodgeExitHysteresis then
				if DodgeGoal then
					local direction = Vector3.new(DodgeGoal.X - Root.Position.X, 0, DodgeGoal.Z - Root.Position.Z)
					Humanoid:Move(direction.Magnitude > 1.5 and direction.Unit or Vector3.zero, false)
				else
					Humanoid:Move(Vector3.zero, false)
				end
				return true
			end
			leaveDodge()
		end
		return false
	end
	LastHazardThreatAt = os.clock()

	local goalUnsafe = not DodgeGoal or not pointIsSafeFromHazards(DodgeGoal)
	if
		not goalUnsafe
		and State == NavigationState.DODGE
		and ActiveHazard ~= hazard
		and DodgeGoal
	then
		goalUnsafe = not dodgeRouteClear(DodgeGoal)
		if not goalUnsafe then
			-- A newly detected hazard does not force a left/right flip when the
			-- committed goal and its route are still safe.
			ActiveHazard = hazard
		end
	end
	local goalReached = DodgeGoal and (DodgeGoal - Root.Position).Magnitude <= 1.5
	local needsNewGoal = State ~= NavigationState.DODGE
		or goalUnsafe
		or goalReached
		or (now >= RuntimeState.DodgeCommitUntil and evaluateNow)
	if needsNewGoal then
		if State ~= NavigationState.DODGE then
			DodgeStartedAt = os.clock()
		end
		if State == NavigationState.DODGE and os.clock() - LastDodgeGoalAttemptAt < 0.2 then
			Humanoid:Move(Vector3.zero, false)
			return true
		end
		LastDodgeGoalAttemptAt = os.clock()
		cancelPathRequest()
		ActiveHazard = hazard
		telemetry(
			"DODGE_ENTER",
			string.format(
				"reason=%s class=%s name=%s parent=%s color=%s transparency=%.2f size=%s verticalDelta=%.1f edge=%.1f route=%.1f",
				predicted and "predicted-route" or "current-edge",
				hazard.ClassName,
				hazard.Name,
				hazard.Parent and hazard.Parent:GetFullName() or "nil",
				tostring(hazard.Color),
				hazard.Transparency,
				tostring(hazard.Size),
				math.abs(Root.Position.Y - hazard.Position.Y),
				edgeDistance,
				routeDistance
			)
		)
		DodgeGoal = chooseNearestSafeDodgeGoal(hazard)
		RuntimeState.DodgeCommitUntil = now + Config.DodgeCommitDuration
		if not DodgeGoal then
			-- Use the outward edge only when it stays on this floor and the route is verified.
			local outward = Vector3.new(Root.Position.X - hazard.Position.X, 0, Root.Position.Z - hazard.Position.Z)
			if outward.Magnitude <= 0.1 then
				outward = Vector3.new(1, 0, 0)
			end
			local currentClearance = RuntimeState.hazardEdgeDistance(hazard, Root.Position, 0)
				- playerFootprintRadius()
			local fallbackDistance = math.max(4, Config.DodgeSafePadding - currentClearance + 2)
			local fallback = Root.Position + outward.Unit * fallbackDistance
			fallback = Vector3.new(fallback.X, Root.Position.Y, fallback.Z)
			local grounded, foundGround = projectToWalkableGround(fallback, nil)
			if
				foundGround
				and math.abs(grounded.Y - Root.Position.Y) <= Config.DirectVerticalTolerance
				and pointIsSafeFromHazards(grounded)
				and dodgeRouteClear(grounded)
			then
				DodgeGoal = grounded
			end
		end
		setNavigationState(NavigationState.DODGE)
		telemetry("DODGE_GOAL", DodgeGoal and tostring(DodgeGoal) or "no-safe-goal")
	end

	if not DodgeGoal then
		Humanoid:Move(Vector3.zero, false)
		return true
	end
	local direction = Vector3.new(DodgeGoal.X - Root.Position.X, 0, DodgeGoal.Z - Root.Position.Z)
	if direction.Magnitude <= 1.5 then
		Humanoid:Move(Vector3.zero, false)
	else
		Humanoid:Move(direction.Unit, false)
	end
	return true
end

local function runRecoveryPolicy()
	local now = os.clock()
	if RuntimeState.RoundTransitionActive then
		LastMeaningfulProgressAt = now
		LowSpeedSince = nil
		return
	end
	if not Target or not NavigationGoal or State == NavigationState.COMBAT then
		LowSpeedSince = nil
		return
	end
	local translating = State == NavigationState.DIRECT
		or State == NavigationState.PATH
		or State == NavigationState.RECOVERY
		or State == NavigationState.STEER
	local noMeaningfulProgressFor = now - LastMeaningfulProgressAt
	if translating and Root and noMeaningfulProgressFor >= Config.SlowMovementRepathDelay then
		local velocity = Root.AssemblyLinearVelocity
		local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		if horizontalSpeed < Config.SlowMovementSpeedThreshold then
			LowSpeedSince = LowSpeedSince or now
			if
				now - LowSpeedSince >= Config.SlowMovementRepathDelay
				and now - LastLowSpeedPathRetryAt >= Config.SlowMovementRepathCooldown
			then
				LastLowSpeedPathRetryAt = now
				cancelPathRequest()
				beginLocalRecovery(NavigationGoal)
				return
			end
		else
			LowSpeedSince = nil
		end
	else
		LowSpeedSince = nil
	end
	local stuckFor = now - LastMeaningfulProgressAt
	if stuckFor >= Config.RespawnStuckTime then
		if not RespawnInProgress then
			recoverByRespawn(Target, LastMeaningfulProgressAt)
		end
		return
	end
	if stuckFor >= Config.RecoveryRefreshAt and now - LastStuckPathRetryAt >= Config.StuckPathRetryInterval then
		-- A BasicPart edge can stop a direct route without blocking it outright.
		-- Rebuild the route before escalating to a character reset.
		LastStuckPathRetryAt = now
		cancelPathRequest()
		beginLocalRecovery(NavigationGoal)
		return
	end
end

local function replayBlocksRecovery(): boolean
	local phase = RuntimeState.ReplayPhase
	return phase == "OPENING" or phase == "CONFIRMING" or phase == "WAIT_NEW_ROUND"
end

local function recoveryAbortReason(): string?
	if not isCurrentExecution() then
		return "shutdown"
	end
	if RuntimeState.RoundTransitionActive then
		return "ROUND_TRANSITION"
	end
	if replayBlocksRecovery() then
		return "replay=" .. RuntimeState.ReplayPhase
	end
	if os.clock() < RuntimeState.RespawnRushUntil then
		return "respawn-grace"
	end
	if cachedStartScreen() then
		return "start-screen"
	end
	return nil
end

recoverByRespawn = function(
	expectedTarget: Model?,
	expectedProgressAt: number?,
	exploreRecovery: boolean?,
	globalStuckAt: number?
)
	if RespawnInProgress or recoveryAbortReason() then
		return
	end
	RuntimeState.RecoverySerial = (RuntimeState.RecoverySerial or 0) + 1
	local recoverySerial = RuntimeState.RecoverySerial
	local executionGeneration = RuntimeState.Generation
	local roundSerial = RuntimeState.RoundResetSerial
	RespawnInProgress = true
	local function recoveryStillCurrent(): boolean
		return isCurrentExecution()
			and RuntimeState.Generation == executionGeneration
			and RuntimeState.RoundResetSerial == roundSerial
			and RuntimeState.RecoverySerial == recoverySerial
	end
	local function releaseRecoveryIfOwned()
		if RuntimeState.RecoverySerial == recoverySerial then
			RespawnInProgress = false
			ResetExecuting = false
		end
	end
	task.spawn(function()
		task.wait(0.4)
		if not recoveryStillCurrent() or not Running then
			releaseRecoveryIfOwned()
			return
		end
		local abortReason = recoveryAbortReason()
		if abortReason then
			print("[RECOVERY] abort=" .. abortReason)
			releaseRecoveryIfOwned()
			return
		end
		if expectedTarget then
			if State == NavigationState.DODGE
				or Target ~= expectedTarget
				or LastMeaningfulProgressAt ~= expectedProgressAt
				or os.clock() - LastMeaningfulProgressAt < Config.RespawnStuckTime
			then
				releaseRecoveryIfOwned()
				return
			end
		elseif exploreRecovery then
			if State == NavigationState.DODGE or Target or LastExploreMeaningfulProgressAt ~= expectedProgressAt then
				releaseRecoveryIfOwned()
				return
			end
		elseif globalStuckAt then
			if RuntimeState.JumpStillSince ~= globalStuckAt then
				releaseRecoveryIfOwned()
				return
			end
		elseif alive() then
			releaseRecoveryIfOwned()
			return
		end
		if not recoveryStillCurrent() then
			releaseRecoveryIfOwned()
			return
		end
		ResetExecuting = true
		print("[RECOVERY] reason=stuck")
		local retainedTarget = if validTarget(Target) then Target else nil
		if retainedTarget then
			cancelPathRequest()
			GoalTarget = nil
			NavigationGoal = nil
			RecoveryGoal = nil
			RecoveryUntil = 0
			resetProgress(retainedTarget, nil)
			setNavigationState(NavigationState.IDLE)
		else
			resetNavigationForTarget(nil)
		end
		local resetCharacter = Character
		for _, key in ipairs({ Enum.KeyCode.Escape, Enum.KeyCode.R, Enum.KeyCode.Return }) do
			if not recoveryStillCurrent()
				or not Running
				or Character ~= resetCharacter
				or State == NavigationState.DODGE
				or recoveryAbortReason()
			then
				releaseRecoveryIfOwned()
				return
			end
			sendKey(key)
			task.wait(0.5)
			if not recoveryStillCurrent() or not Running then
				releaseRecoveryIfOwned()
				return
			end
		end
		task.wait(3)
		if not recoveryStillCurrent() or not Running then
			releaseRecoveryIfOwned()
			return
		end
		releaseRecoveryIfOwned()
	end)
end
local function updateDungeonReplayState()
	local now = os.clock()
	if now - RuntimeState.LastDungeonStateCheckAt < 0.25 then
		return
	end
	RuntimeState.LastDungeonStateCheckAt = now
	RuntimeState.refreshDungeonReferences()
	if RuntimeState.RoundTransitionTimedOut then
		local hasNewRoundEvidence = RuntimeState.ActiveDungeonRoot
			or RuntimeState.EnemyFolderInstance
			or RuntimeState.DungeonTimeInstance
			or cachedStartScreen()
		if hasNewRoundEvidence then
			RuntimeState.RoundTransitionTimedOut = false
			RuntimeState.DungeonFinishedLastState = false
			RuntimeState.ReplayPhase = "IDLE"
			print("[ROUND] new-evidence=resolved")
			print("[ROUND] transition=END")
		end
	end
	local fightingBoss = RuntimeState.FightingBossInstance
	if fightingBoss and fightingBoss:IsA("BoolValue") then
		if fightingBoss.Value then
			RuntimeState.FightingBossSeenThisRound = true
		elseif RuntimeState.LastFightingBossState and RuntimeState.FightingBossSeenThisRound then
			armReplayToken("fightingBoss-ended")
		end
		RuntimeState.LastFightingBossState = fightingBoss.Value
	else
		RuntimeState.LastFightingBossState = false
	end
	local finished = RuntimeState.DungeonFinishedInstance
	if finished and finished:IsA("BoolValue") then
		local previousFinished = RuntimeState.PreviousDungeonFinishedInstance
		local newRound = RuntimeState.DungeonFinishedLastState
			and (
				not finished.Value or (previousFinished ~= nil and previousFinished ~= finished and not finished.Value)
			)
		if finished.Value and not RuntimeState.DungeonFinishedLastState then
			if not RuntimeState.ReplayCompletionDetected then
				print("[REPLAY] COMPLETE")
			end
			RuntimeState.ReplayCompletionDetected = true
			if RuntimeState.ReplayPhase == "ARMED" then
				RuntimeState.ReplayPhase = "OPENING"
			end
			armReplayToken("dungeonFinished")
			RuntimeState.sendStatusWebhook("DUNGEON_FINISHED")
		end
		RuntimeState.DungeonFinishedLastState = finished.Value
		RuntimeState.PreviousDungeonFinishedInstance = finished
		if newRound and resetRuntimeForNewDungeon then
			RuntimeState.ReplayPhase = "WAIT_NEW_ROUND"
			print("[REPLAY] NEW ROUND")
			RuntimeState.sendStatusWebhook("NEW_ROUND")
			resetRuntimeForNewDungeon()
			RuntimeState.sendStatusWebhook("DUNGEON_STARTED")
			return
		end
	elseif RuntimeState.DungeonFinishedLastState then
		RuntimeState.DungeonFinishedInstance = nil
		if not RuntimeState.RoundTransitionActive and not RuntimeState.RoundTransitionTimedOut then
			RuntimeState.RoundTransitionActive = true
			RuntimeState.RoundTransitionStartedAt = now
			RuntimeState.RoundTransitionDeadline = now + 7
			RuntimeState.RoundBootstrapUntil = now + 7
			print("[ROUND] transition=BEGIN awaiting-new-state")
		elseif RuntimeState.RoundTransitionActive and now >= RuntimeState.RoundTransitionDeadline then
			RuntimeState.RoundTransitionActive = false
			RuntimeState.RoundTransitionTimedOut = true
			RuntimeState.ActiveDungeonRoot = nil
			RuntimeState.EnemyFolderInstance = nil
			RuntimeState.FightingBossInstance = nil
			RuntimeState.DungeonTimeInstance = nil
			RuntimeState.DungeonTimeText = nil
			RuntimeState.LastDungeonReferenceSearchAt = -math.huge
			RuntimeState.ReplayPhase = "IDLE"
			RuntimeState.ReplayAwaitingClose = nil
			RuntimeState.ReplayYesButton = nil
			RuntimeState.ReplayCompletionRoot = nil
			RuntimeState.ReplayOpener = nil
			resetNavigationForTarget(nil)
			LastTargetAcquireAt = -math.huge
			print("[ROUND] transition=TIMEOUT")
		end
	end
	local remaining = RuntimeState.remainingDungeonTime()
	if remaining and remaining <= 20 then
		armReplayToken("remaining=" .. tostring(remaining))
	end
	tryReplayDungeon()
	tryStartDungeon()
end

local function updateTargetAndObjective()
	if not Running or not alive() then
		return
	end
	local now = os.clock()
	if tryStartDungeon() then
		setNavigationState(NavigationState.IDLE)
		stopTranslation()
		return
	end
	if RuntimeState.RoundTransitionActive then
		LastMeaningfulProgressAt = now
		LowSpeedSince = nil
		setNavigationState(NavigationState.IDLE)
		stopTranslation()
		return
	end
	if not validTarget(Target) then
		local invalidTarget = Target
		if invalidTarget and RuntimeState.LastStaleTarget ~= invalidTarget then
			RuntimeState.LastStaleTarget = invalidTarget
			print("[TARGET] stale=" .. invalidTarget.Name .. " reason=invalid")
		end
		if invalidTarget or now - LastTargetAcquireAt >= Config.TargetAcquireInterval then
			LastTargetAcquireAt = now
			local acquired = acquireBestTarget()
			if acquired then
				resetNavigationForTarget(acquired)
				RuntimeState.LastStaleTarget = nil
				NoTargetSince = nil
			elseif invalidTarget then
				resetNavigationForTarget(nil)
				LastTargetAcquireAt = -math.huge
				NoTargetSince = now
			end
		end
	end
	if not Target or not Root or not Humanoid then
		cancelPathRequest()
		NavigationGoal = nil
		RecoveryGoal = nil
		setNavigationState(NavigationState.IDLE)
		stopTranslation()
		return
	end
	local enemyRoot = getTargetRoot(Target)
	local enemyHumanoid = Target:FindFirstChildOfClass("Humanoid")
	if not enemyRoot or not enemyHumanoid or enemyHumanoid.Health <= 0 then
		resetNavigationForTarget(nil)
		LastTargetAcquireAt = now
		local acquired = acquireBestTarget()
		if acquired then
			resetNavigationForTarget(acquired)
			NoTargetSince = nil
		else
			NoTargetSince = now
			setNavigationState(NavigationState.IDLE)
			stopTranslation()
		end
		return
	end
	if isBossTarget(Target) and RuntimeState.BossDiedTarget ~= Target then
		if RuntimeState.BossDiedConnection then
			RuntimeState.BossDiedConnection:Disconnect()
		end
		RuntimeState.BossDiedTarget = Target
		RuntimeState.BossDiedConnection = enemyHumanoid.Died:Connect(function()
			armReplayToken("boss-died")
			RuntimeState.sendStatusWebhook("BOSS_DIED")
		end)
	end
	NoTargetSince = nil
	if State == NavigationState.DODGE then
		return
	end
	if
		now - LastTargetAcquireAt >= Config.TargetAcquireInterval
		and State ~= NavigationState.DODGE
		and now >= RuntimeState.RespawnRushUntil
	then
		LastTargetAcquireAt = now
		local candidate = acquireBestTarget()
		local _, currentDistance = targetMetrics(Target)
		local _, candidateDistance = targetMetrics(candidate)
		if
			candidate
			and candidate ~= Target
			and (
				targetDistanceBucket(candidateDistance) < targetDistanceBucket(currentDistance)
				or (
					targetDistanceBucket(candidateDistance) == targetDistanceBucket(currentDistance)
					and candidateDistance <= currentDistance - 10
				)
			)
		then
			resetNavigationForTarget(candidate)
			return
		end
	end
	local distance3D = (enemyRoot.Position - Root.Position).Magnitude
	if now < RuntimeState.RespawnRushUntil then
		local rushHoldDistance = math.max(Config.AttackRange, Config.DirectReachedDistance + 2)
		if distance3D <= rushHoldDistance then
			cancelPathRequest()
			NavigationGoal = nil
			RecoveryGoal = nil
			setNavigationState(NavigationState.COMBAT)
			resetProgress(Target, nil)
			return
		end
		RecoveryGoal = nil
		SteeringTried = false
		GoalTarget = Target
		NavigationGoal = navigationGoalForTarget(enemyRoot, Target, rushHoldDistance)
		-- During spawn protection, keep moving toward the retained target, but do
		-- not ram a BasicPart: direct is used only when the route is clear.
		if directRouteClear(NavigationGoal, Target) then
			if State ~= NavigationState.DIRECT then
				cancelPathRequest()
			end
			setNavigationState(NavigationState.DIRECT)
		elseif not PathComputing and (State ~= NavigationState.PATH or not PathWaypoints) then
			cancelPathRequest()
			setNavigationState(NavigationState.PATH)
			requestPath(NavigationGoal)
		end
		updateProgressTracking()
		return
	end
	if State == NavigationState.RETREAT and distance3D < Config.RetreatExitDistance then
		cancelPathRequest()
		NavigationGoal = nil
		return
	elseif distance3D < Config.RetreatEnterDistance then
		cancelPathRequest()
		NavigationGoal = nil
		setNavigationState(NavigationState.RETREAT)
		return
	end
	if distance3D <= Config.PreferredCombatDistance then
		-- Invalidate an in-flight ComputeAsync as well as any published path. Merely
		-- disposing ActivePath would still allow the old callback to publish PATH.
		if State ~= NavigationState.COMBAT or PathComputing or ActivePath then
			cancelPathRequest()
		end
		NavigationGoal = nil
		setNavigationState(NavigationState.COMBAT)
		resetProgress(Target, nil)
		return
	end
	if State == NavigationState.COMBAT then
		setNavigationState(NavigationState.IDLE)
	end
	local flatDistance =
		Vector3.new(enemyRoot.Position.X - Root.Position.X, 0, enemyRoot.Position.Z - Root.Position.Z).Magnitude
	local verticalDifference = math.abs(enemyRoot.Position.Y - Root.Position.Y)
	local targetBelow = enemyRoot.Position.Y < Root.Position.Y - Config.DirectVerticalTolerance
	if targetBelow and (flatDistance <= 15 or verticalDifference > flatDistance) then
		if RuntimeState.VerticalPathTarget ~= Target or not RuntimeState.VerticalPathGoal then
			RuntimeState.VerticalPathTarget = Target
			RuntimeState.VerticalPathGoal = navigationGoalForTarget(enemyRoot, Target)
		end
		GoalTarget = Target
		NavigationGoal = RuntimeState.VerticalPathGoal
		if ProgressTarget ~= Target or ProgressGoalAnchor ~= NavigationGoal then
			resetProgress(Target, NavigationGoal)
		end
		if not PathComputing and (State ~= NavigationState.PATH or not PathWaypoints) then
			cancelPathRequest()
			setNavigationState(NavigationState.PATH)
			requestPath(NavigationGoal)
		end
		updateProgressTracking()
		runRecoveryPolicy()
		return
	end
	RuntimeState.VerticalPathTarget = nil
	RuntimeState.VerticalPathGoal = nil
	if GoalTarget ~= Target or now - LastGoalRefreshAt >= Config.GoalRefreshInterval then
		LastGoalRefreshAt = now
		GoalTarget = Target
		local newGoal = navigationGoalForTarget(enemyRoot, Target)
		if not NavigationGoal or (newGoal - NavigationGoal).Magnitude >= Config.DirectGoalChangeDistance then
			NavigationGoal = newGoal
		elseif State == NavigationState.DIRECT then
			NavigationGoal = NavigationGoal:Lerp(newGoal, 0.35)
		end
	end
	if not ProgressGoalAnchor then
		resetProgress(Target, NavigationGoal)
	end
	decideNavigation()
	updateProgressTracking()
	runRecoveryPolicy()
end

local function bindCharacter(character: Model)
	CharacterBindSerial += 1
	local serial = CharacterBindSerial
	local now = os.clock()
	if RuntimeState.CharacterBindRetryUntil < now then
		RuntimeState.CharacterBindRetryUntil = now + 8
	end
	local newHumanoid = character:FindFirstChildOfClass("Humanoid")
	local newRoot = character:FindFirstChild("HumanoidRootPart")
	if not isCurrentExecution() or serial ~= CharacterBindSerial or Player.Character ~= character then
		return
	end
	if not newHumanoid or not newHumanoid:IsA("Humanoid") or not newRoot or not newRoot:IsA("BasePart") then
		local missing = (not newHumanoid and "Humanoid" or "") .. (not newRoot and " HumanoidRootPart" or "")
		if RuntimeState.LastCharacterBindWait ~= missing then
			RuntimeState.LastCharacterBindWait = missing
			print("[CHAR] bind waiting=" .. missing)
		end
		if now < RuntimeState.CharacterBindRetryUntil and not RuntimeState.CharacterBindRetryPending then
			RuntimeState.CharacterBindRetryPending = true
			RuntimeState.CharacterBindRetryCharacter = character
			local executionGeneration = RuntimeState.Generation
			task.delay(0.5, function()
				if RuntimeState.CharacterBindRetryCharacter == character then
					RuntimeState.CharacterBindRetryPending = false
					RuntimeState.CharacterBindRetryCharacter = nil
				end
				if
					isCurrentExecution()
					and RuntimeState.Generation == executionGeneration
					and Player.Character == character
				then
					bindCharacter(character)
				end
			end)
		else
			print("[CHAR] bind timeout")
		end
		return
	end
	RuntimeState.CharacterBindRetryUntil = 0
	RuntimeState.CharacterBindRetryPending = false
	RuntimeState.CharacterBindRetryCharacter = nil
	RuntimeState.LastCharacterBindWait = ""
	disconnectAll(CharacterConnections)
	clearAimObjects()
	restoreMovementSpeed()
	cancelPathRequest()
	-- A replay/reset can recreate PlayerModule controls while the old control
	-- object is still marked disabled. Re-resolve it for the new character.
	if PlayerControlsDisabled and PlayerControls then
		pcall(function()
			PlayerControls:Enable()
		end)
	end
	PlayerControls = nil
	PlayerControlsDisabled = false
	PlayerControlsResolvePending = false
	Character = character
	Humanoid = newHumanoid
	Root = newRoot
	if Humanoid then
		DefaultAutoRotate = Humanoid.AutoRotate
		DefaultWalkSpeed = Humanoid.WalkSpeed
	end
	NextQAt, NextEAt, LastAttack = 0, 0, 0
	RespawnInProgress = false
	ResetExecuting = false
	NoTargetSince = os.clock()
	clearDodgeObjective()
	-- Keep a living target through the player's own death. Its listener remains
	-- attached, so an enemy that dies during the respawn still clears normally.
	if Target and validTarget(Target) then
		GoalTarget = nil
		NavigationGoal = nil
		RecoveryGoal = nil
		RecoveryUntil = 0
		cancelPathRequest()
		resetProgress(Target, nil)
		setNavigationState(NavigationState.IDLE)
		LastTargetAcquireAt = os.clock()
	else
		resetNavigationForTarget(nil)
		LastTargetAcquireAt = -math.huge
	end
	if Running then
		applyMovementSpeed()
		disablePlayerControls()
	end
	if Humanoid then
		table.insert(
			CharacterConnections,
			Humanoid.Died:Connect(function()
				local executionGeneration = RuntimeState.Generation
				RuntimeState.RespawnRushUntil = 0
				RuntimeState.sendStatusWebhook("CHARACTER_DIED")
				-- Do not discard a living enemy just because this character died.
				-- CharacterAdded will immediately resume the same target when possible.
				cancelPathRequest()
				GoalTarget = nil
				NavigationGoal = nil
				RecoveryGoal = nil
				RecoveryUntil = 0
				setNavigationState(NavigationState.IDLE)
				if Running then
					task.defer(function()
						task.wait(0.65)
						if
							isCurrentExecution()
							and RuntimeState.Generation == executionGeneration
							and Running
							and not alive()
						then
							recoverByRespawn(nil, nil)
						end
					end)
				end
			end)
		)
	end
end

setRunning = function(value: boolean)
	if Running == value then
		return
	end
	Running = value
	Config.FarmEnabled = value
	saveConfig()
	if value then
		disablePlayerControls()
		applyMovementSpeed()
		LastTargetAcquireAt = -math.huge
		NoTargetSince = os.clock()
		resetProgress(nil, nil)
	else
		RuntimeState.RespawnRushUntil = 0
		clearDodgeObjective()
		resetNavigationForTarget(nil)
		stopTranslation()
		restoreMovementSpeed()
		restoreRotation()
		enablePlayerControls()
	end
end

local function createHUD()
	local old = PlayerGui:FindFirstChild("AutoFarmHUD")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "AutoFarmHUD"
	gui.ResetOnSpawn = false
	local guiParent: Instance = PlayerGui
	if type(gethui) == "function" then
		local ok, result = pcall(gethui)
		if ok and typeof(result) == "Instance" then
			guiParent = result
		end
	end
	gui.Parent = guiParent
	HUD = gui
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(360, 220)
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = Config.HUDPosition
	frame.BackgroundColor3 = Color3.fromRGB(18, 23, 35)
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Parent = gui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = Color3.fromRGB(58, 177, 255)
	stroke.Transparency = 0.3
	local title = Instance.new("TextButton")
	title.Size = UDim2.new(1, 0, 0, 38)
	title.BackgroundColor3 = Color3.fromRGB(32, 47, 70)
	title.BorderSizePixel = 0
	title.Text = "AUTO FARM V21"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Parent = frame
	local info = Instance.new("TextLabel")
	info.Position = UDim2.fromOffset(14, 48)
	info.Size = UDim2.fromOffset(332, 105)
	info.BackgroundTransparency = 1
	info.Font = Enum.Font.Gotham
	info.TextSize = 13
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextYAlignment = Enum.TextYAlignment.Top
	info.TextColor3 = Color3.fromRGB(220, 230, 245)
	info.Parent = frame
	local button = Instance.new("TextButton")
	button.Position = UDim2.fromOffset(14, 166)
	button.Size = UDim2.fromOffset(332, 40)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 14
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Parent = frame
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	table.insert(
		Connections,
		button.MouseButton1Click:Connect(function()
			setRunning(not Running)
		end)
	)
	local dragging = false
	local dragStart = Vector2.zero
	local startPosition = frame.Position
	table.insert(
		Connections,
		title.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				dragging, dragStart, startPosition = true, input.Position, frame.Position
			end
		end)
	)
	table.insert(
		Connections,
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				dragging = false
				Config.HUDPosition = frame.Position
			end
		end)
	)
	table.insert(
		Connections,
		UserInputService.InputChanged:Connect(function(input)
			if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
				frame.Position = UDim2.new(
					startPosition.X.Scale,
					startPosition.X.Offset + input.Position.X - dragStart.X,
					startPosition.Y.Scale,
					startPosition.Y.Offset + input.Position.Y - dragStart.Y
				)
			end
		end)
	)
	RuntimeState.HUDInfo = info
	RuntimeState.HUDButton = button
	table.insert(
		Connections,
		UserInputService.InputBegan:Connect(function(input, processed)
			if
				not processed and (input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift)
			then
				gui.Enabled = not gui.Enabled
			end
		end)
	)
end

local function shutdown()
	print("[SHUTDOWN] runtime stopped")
	Config.FarmEnabled = Running
	saveConfig()
	RuntimeState.RecoverySerial = (RuntimeState.RecoverySerial or 0) + 1
	Enabled, Running = false, false
	RuntimeState.RespawnRushUntil = 0
	clearDodgeObjective()
	resetNavigationForTarget(nil)
	stopTranslation()
	restoreMovementSpeed()
	restoreRotation()
	enablePlayerControls()
	disconnectAll(Connections)
	disconnectAll(CharacterConnections)
	clearAimObjects()
	if HUD then
		HUD:Destroy()
		HUD = nil
	end
	if Environment.AutoFarmV21Shutdown == shutdown then
		Environment.AutoFarmV21Shutdown = nil
	end
end

print("[EXEC] generation=" .. tostring(RuntimeState.Generation))
createHUD()
print("[AF] HUD created")
RuntimeState.sendStatusWebhook("SCRIPT_STARTED")
table.insert(
	Connections,
	workspace.DescendantAdded:Connect(function(instance)
		-- Map/VFX BasicParts can arrive in large bursts after Replay. Enemy
		-- registration only needs a Model (or its Humanoid once it is populated),
		-- so do not walk ancestors for every decorative part in the dungeon.
		if instance:IsA("Model") then
			local executionGeneration = RuntimeState.Generation
			task.defer(function()
				if isCurrentExecution() and RuntimeState.Generation == executionGeneration and instance:IsDescendantOf(workspace) then
					registerEnemy(instance)
				end
			end)
		elseif instance:IsA("Humanoid") or instance:IsA("BasePart") then
			local model: Model? = instance.Parent and instance.Parent:FindFirstAncestorOfClass("Model")
			if model then
				local executionGeneration = RuntimeState.Generation
				task.defer(function()
					if isCurrentExecution() and RuntimeState.Generation == executionGeneration and model:IsDescendantOf(workspace) then
						registerEnemy(model)
					end
				end)
			end
		end
		if Config.DodgeEnabled then
			registerHazard(instance)
		end
	end)
)
table.insert(
	Connections,
	PlayerGui.DescendantAdded:Connect(function(instance)
		if RuntimeState.ReplayPhase ~= "IDLE" and (instance:IsA("TextLabel") or instance:IsA("TextButton")) then
			local text = instance.Text:lower():gsub("[%s%p_]", "")
			if
				text:find("completed", 1, true)
				or text == "replay"
				or text == "playagain"
				or text == "retry"
				or text == "yes"
			then
				RuntimeState.ReplayLastGuiScanAt = -math.huge
			end
		end
	end)
)
table.insert(
	Connections,
	workspace.DescendantRemoving:Connect(function(instance)
		if instance:IsA("Model") then
			EnemySet[instance] = nil
		end
		local targetRoot = Target and getTargetRoot(Target)
		if
			Target
			and (
				Target == instance
				or Target:IsDescendantOf(instance)
				or targetRoot == instance
			)
		then
			if RuntimeState.LastStaleTarget ~= Target then
				RuntimeState.LastStaleTarget = Target
				print("[TARGET] stale=" .. Target.Name .. " reason=removed")
			end
			resetNavigationForTarget(nil)
			LastTargetAcquireAt = -math.huge
		end
		local activeRoot = RuntimeState.ActiveDungeonRoot
		if activeRoot and (activeRoot == instance or activeRoot:IsDescendantOf(instance)) then
			RuntimeState.ActiveDungeonRoot = nil
			RuntimeState.EnemyFolderInstance = nil
			RuntimeState.FightingBossInstance = nil
			RuntimeState.DungeonTimeInstance = nil
			RuntimeState.LastDungeonReferenceSearchAt = -math.huge
		end
		if instance:IsA("BasePart") then
			HazardSet[instance] = nil
			RuntimeState.HazardMetadata[instance] = nil
		end
	end)
)

if Player.Character then
	local executionGeneration = RuntimeState.Generation
	task.defer(function()
		if isCurrentExecution() and RuntimeState.Generation == executionGeneration and Player.Character then
			bindCharacter(Player.Character)
		end
	end)
end
table.insert(
	Connections,
	Player.CharacterAdded:Connect(function(character)
		local executionGeneration = RuntimeState.Generation
		RuntimeState.RespawnRushUntil = os.clock() + Config.RespawnRushDuration
		RuntimeState.CharacterBindRetryUntil = os.clock() + 8
		RuntimeState.CharacterBindRetryPending = false
		RuntimeState.CharacterBindRetryCharacter = nil
		RuntimeState.LastCharacterBindWait = ""
		disconnectAll(CharacterConnections)
		clearAimObjects()
		restoreMovementSpeed()
		cancelPathRequest()
		Character = nil
		Humanoid = nil
		Root = nil
		GoalTarget = nil
		NavigationGoal = nil
		RecoveryGoal = nil
		RecoveryUntil = 0
		setNavigationState(NavigationState.IDLE)
		print("[CHAR] respawn")
		task.defer(function()
			if isCurrentExecution() and RuntimeState.Generation == executionGeneration then
				bindCharacter(character)
			end
		end)
	end)
)

local startupGeneration = RuntimeState.Generation
task.defer(function()
	if isCurrentExecution() and RuntimeState.Generation == startupGeneration then
		buildInitialCaches()
	end
end)
print("[AF] startup complete")
table.insert(
	Connections,
	RunService.Heartbeat:Connect(function(dt)
		if not Enabled then
			return
		end
		if dt > 0 then
			local instantFPS = 1 / dt
			RuntimeState.SmoothedFPS = RuntimeState.SmoothedFPS > 0
					and RuntimeState.SmoothedFPS * 0.85 + instantFPS * 0.15
				or instantFPS
		end
		local now = os.clock()
		if now - RuntimeState.LastStatsSampleAt >= 0.5 then
			RuntimeState.LastStatsSampleAt = now
			local pingMs = readPingMs()
			if pingMs then
				RuntimeState.PingMs = pingMs
				telemetry("PING", tostring(pingMs))
			end
		end
		updateDungeonReplayState()
		if now - RuntimeState.LastHUDUpdateAt >= 0.2 then
			RuntimeState.LastHUDUpdateAt = now
			local info = RuntimeState.HUDInfo
			local button = RuntimeState.HUDButton
			if info and info:IsDescendantOf(game) and button and button:IsDescendantOf(game) then
				local activeTarget = if validTarget(Target) then Target else nil
				local targetRoot = activeTarget and getTargetRoot(activeTarget)
				local distance = targetRoot and Root and (targetRoot.Position - Root.Position).Magnitude
				local height = targetRoot and Root and math.abs(targetRoot.Position.Y - Root.Position.Y)
				local translating = State == NavigationState.DIRECT
					or State == NavigationState.STEER
					or State == NavigationState.RETREAT
					or State == NavigationState.PATH
					or State == NavigationState.RECOVERY
					or State == NavigationState.EXPLORE
				local stuckSeconds = if alive() and translating then math.max(0, now - RuntimeState.JumpStillSince) else 0
				local targetName = activeTarget and (activeTarget.Name .. (isBossTarget(activeTarget) and " [BOSS]" or "")) or "None"
				local replayLabel = if RuntimeState.ReplayPhase == "CONFIRMING"
					then "CONFIRM"
					elseif RuntimeState.ReplayPhase == "WAIT_NEW_ROUND" then "WAIT ROUND"
					else RuntimeState.ReplayPhase
				info.Text = string.format(
					"State: %s | Target: %s\nDist: %s | Y: %s | Skill: %.0f | Kite: %.0f\nDodge: %s | Replay: %s\nFPS: %.0f | Ping: %.0f ms | Speed: +%.0f%%\nStuck: %.1f/%.0fs",
					State,
					targetName,
					distance and string.format("%.1f", distance) or "--",
					height and string.format("%.1f", height) or "--",
					activeTarget and skillRangeForTarget(activeTarget) or Config.NormalSkillRange,
					Config.KiteDistance,
					Config.DodgeEnabled and (State == NavigationState.DODGE and "ACTIVE" or "READY") or "OFF",
					replayLabel,
					RuntimeState.SmoothedFPS,
					RuntimeState.PingMs,
					(Config.MovementSpeedMultiplier - 1) * 100,
					stuckSeconds,
					Config.RespawnStuckTime
				)
				button.Text = Running and "DỪNG AUTO FARM" or "BẮT ĐẦU AUTO FARM"
				button.BackgroundColor3 = Running and Color3.fromRGB(190, 60, 72) or Color3.fromRGB(43, 166, 100)
			end
		end
		if not Running or not alive() then
			return
		end
		if ResetExecuting then
			setNavigationState(NavigationState.IDLE)
			stopTranslation()
			return
		end
		updateGlobalStuckJump()
		updateTargetAndObjective()
		local dodgeOwnsTranslation = Config.DodgeEnabled and updateDodgeController()
		updateTargetFacing()
		if Target and validTarget(Target) then
			local enemyRoot = getTargetRoot(Target)
			if enemyRoot and Root then
				local distance = (enemyRoot.Position - Root.Position).Magnitude
				useCombatSkills(enemyRoot, distance)
				useNormalAttack(distance)
			end
		end
		if dodgeOwnsTranslation then
			return
		end
		if State == NavigationState.DIRECT then
			updateDirectMovement()
		elseif State == NavigationState.PATH then
			updatePathNavigation()
		elseif
			State == NavigationState.RECOVERY
			or State == NavigationState.STEER
			or State == NavigationState.RETREAT
		then
			updateRecoveryMovement()
		elseif State == NavigationState.EXPLORE then
			updateExploreMovement()
		elseif State == NavigationState.COMBAT or State == NavigationState.IDLE then
			stopTranslation()
		end
	end)
)

Environment.AutoFarmV21Shutdown = shutdown
