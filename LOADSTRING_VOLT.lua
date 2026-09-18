-- Volt loader. Resolve main once, pin every source fetch to the same commit,
-- then pass that commit to MainVolt.lua to avoid a second GitHub API lookup.

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

local cacheBust = tostring(os.time())
local branchBody = fetchText(
	"https://api.github.com/repos/torung1404/aura/commits/main?v=" .. cacheBust
)
local ok, branch = pcall(function()
	return HttpService:JSONDecode(branchBody)
end)
assert(ok and type(branch) == "table" and type(branch.sha) == "string", "GitHub trả về commit main không hợp lệ")

Environment.__AuraVoltResolvedCommit = branch.sha
local source = fetchText(
	"https://raw.githubusercontent.com/torung1404/aura/" .. branch.sha .. "/MainVolt.lua?v=" .. cacheBust
)
print("[VOLT LOADER] entry=" .. branch.sha)

local run, loadError = loadstring(source, "@Aura/MainVolt.lua")
if not run then
	Environment.__AuraVoltResolvedCommit = nil
	error("MainVolt.lua compile lỗi: " .. tostring(loadError))
end

local ran, runtimeError = pcall(run)
if not ran then
	Environment.__AuraVoltResolvedCommit = nil
	error("MainVolt.lua runtime lỗi: " .. tostring(runtimeError))
end
