local cacheBust = tostring(os.time())
assert(type(request) == "function", "Delta request API không khả dụng")
assert(type(loadstring) == "function", "Delta loadstring API không khả dụng")
local branchResponse = request({
    Url = "https://api.github.com/repos/torung1404/aura/commits/main?v=" .. cacheBust,
    Method = "GET",
})
assert(branchResponse and branchResponse.Body, "Không lấy được phiên bản main từ GitHub")
assert(
    not branchResponse.StatusCode or branchResponse.StatusCode >= 200 and branchResponse.StatusCode < 300,
    "GitHub trả về lỗi phiên bản main"
)

local ok, branch = pcall(function()
    return game:GetService("HttpService"):JSONDecode(branchResponse.Body)
end)
assert(ok and type(branch) == "table" and type(branch.sha) == "string", "GitHub trả về phiên bản main không hợp lệ")

local response = request({
    -- Pin the source body to the SHA just resolved above. raw/main can be served
    -- from a stale CDN cache even when the URL has a query-string cache buster.
    Url = "https://raw.githubusercontent.com/torung1404/aura/" .. branch.sha .. "/Main.lua?v=" .. cacheBust,
    Method = "GET",
})
assert(response and response.Body, "Không tải được Main.lua từ GitHub")
assert(not response.StatusCode or response.StatusCode >= 200 and response.StatusCode < 300, "GitHub trả về lỗi Main.lua")
print("[LOADER] main=" .. branch.sha)
local run, loadError = loadstring(response.Body)
assert(run, loadError)
local started, runtimeError = pcall(run)
assert(started, "Main.lua khởi động lỗi: " .. tostring(runtimeError))
