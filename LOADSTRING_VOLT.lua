-- Stable Volt loader: resolve the branch commit before fetching MainVolt.lua.
local cacheBust = tostring(os.time())
assert(type(request) == "function", "Volt request API không khả dụng")

local branchResponse = request({
	Url = "https://api.github.com/repos/torung1404/aura/commits/main?v=" .. cacheBust,
	Method = "GET",
})
assert(branchResponse and branchResponse.Body, "Không lấy được phiên bản main từ GitHub")
assert(
	not branchResponse.StatusCode or branchResponse.StatusCode >= 200 and branchResponse.StatusCode < 300,
	"GitHub trả về lỗi phiên bản main"
)

local decoded, branch = pcall(function()
	return game:GetService("HttpService"):JSONDecode(branchResponse.Body)
end)
assert(decoded and type(branch) == "table" and type(branch.sha) == "string", "GitHub trả về phiên bản main không hợp lệ")

local sourceResponse = request({
	Url = "https://raw.githubusercontent.com/torung1404/aura/" .. branch.sha .. "/MainVolt.lua?v=" .. cacheBust,
	Method = "GET",
})
assert(sourceResponse and sourceResponse.Body, "Không tải được MainVolt.lua từ GitHub")
assert(
	not sourceResponse.StatusCode or sourceResponse.StatusCode >= 200 and sourceResponse.StatusCode < 300,
	"GitHub trả về lỗi MainVolt.lua"
)

print("[VOLT LOADER] entry=" .. branch.sha)
local run, loadError = loadstring(sourceResponse.Body)
assert(run, loadError)
run()
