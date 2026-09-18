-- Volt loader: pin both requests to one current main commit.
local cacheBust = tostring(os.time())
assert(type(loadstring) == "function", "Volt loadstring API không khả dụng")

local function fetch(url)
	local function accepted(response)
		return response
			and type(response.Body) == "string"
			and #response.Body > 0
			and (not response.StatusCode or response.StatusCode >= 200 and response.StatusCode < 300)
	end
	local function executorGet(sender)
		if type(sender) == "function" then
			local ok, response = pcall(sender, { Url = url, Method = "GET" })
			if ok and accepted(response) then
				return response.Body
			end
		end
		return nil
	end
	local body = executorGet(request) or executorGet(http_request)
	if body then
		return body
	end
	local ok, httpBody = pcall(function()
		return game:HttpGet(url)
	end)
	if ok and type(httpBody) == "string" and #httpBody > 0 then
		return httpBody
	end
	return nil
end

local branchBody = fetch("https://api.github.com/repos/torung1404/aura/commits/main?v=" .. cacheBust)
assert(branchBody, "Không lấy được phiên bản main từ GitHub")
local decoded, branch = pcall(function()
	return game:GetService("HttpService"):JSONDecode(branchBody)
end)
assert(decoded and type(branch) == "table" and type(branch.sha) == "string", "GitHub trả về phiên bản main không hợp lệ")

local source = fetch("https://raw.githubusercontent.com/torung1404/aura/" .. branch.sha .. "/MainVolt.lua?v=" .. cacheBust)
assert(source, "Không tải được MainVolt.lua từ GitHub")
print("[VOLT LOADER] main=" .. branch.sha)
local run, loadError = loadstring(source)
assert(run, loadError)
local started, runtimeError = pcall(run)
assert(started, "MainVolt.lua khởi động lỗi: " .. tostring(runtimeError))
