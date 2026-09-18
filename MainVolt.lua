-- Volt entrypoint. Main.lua stays the gameplay source of truth.
-- This wrapper only handles Volt capability selection and stable source loading.

local function getEnvironment()
	if type(getgenv) == "function" then
		local ok, environment = pcall(getgenv)
		if ok and type(environment) == "table" then
			return environment
		end
	end
	return _G
end

local Environment = getEnvironment()
local HttpService = game:GetService("HttpService")

local function fetchText(url: string): string
	local requester = if type(request) == "function"
		then request
		elseif type(http_request) == "function" then http_request
		else nil

	if requester then
		local ok, response = pcall(requester, {
			Url = url,
			Method = "GET",
		})
		assert(ok and type(response) == "table", "Volt HTTP request thất bại")
		assert(
			not response.StatusCode or response.StatusCode >= 200 and response.StatusCode < 300,
			"HTTP status không hợp lệ: " .. tostring(response.StatusCode)
		)
		assert(type(response.Body) == "string" and #response.Body > 0, "HTTP response rỗng")
		return response.Body
	end

	local ok, body = pcall(function()
		return game:HttpGet(url)
	end)
	assert(ok and type(body) == "string" and #body > 0, "Volt không có HTTP API khả dụng")
	return body
end

local commitSha = Environment.__AuraVoltResolvedCommit
if type(commitSha) ~= "string" or not commitSha:match("^[0-9a-fA-F]+$") or #commitSha < 7 then
	local cacheBust = tostring(os.time())
	local branchBody = fetchText(
		"https://api.github.com/repos/torung1404/aura/commits/main?v=" .. cacheBust
	)
	local ok, branch = pcall(function()
		return HttpService:JSONDecode(branchBody)
	end)
	assert(ok and type(branch) == "table" and type(branch.sha) == "string", "GitHub trả về commit main không hợp lệ")
	commitSha = branch.sha
end
Environment.__AuraVoltResolvedCommit = nil

-- Tell Main.lua to prefer Volt's documented native input APIs. Main still keeps
-- VIM as a fallback, so the same gameplay source remains usable on Delta.
Environment.AutoFarmExecutorProfile = "VOLT"
Environment.AutoFarmPreferNativeInput = true

local executorName = "unknown"
if type(identifyexecutor) == "function" then
	local ok, name = pcall(identifyexecutor)
	if ok and name ~= nil then
		executorName = tostring(name)
	end
end

local source = fetchText(
	"https://raw.githubusercontent.com/torung1404/aura/" .. commitSha .. "/Main.lua?v=" .. tostring(os.time())
)
print(string.format("[VOLT LOADER] executor=%s main=%s bytes=%d", executorName, commitSha, #source))

local run, loadError = loadstring(source, "@Aura/Main.lua")
assert(run, "Main.lua compile lỗi: " .. tostring(loadError))

local ok, runtimeError = pcall(run)
assert(ok, "Main.lua runtime lỗi: " .. tostring(runtimeError))
