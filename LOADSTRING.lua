local response = request({
	-- Cache-bust so each Delta execution fetches the current aura/main source.
	Url = "https://raw.githubusercontent.com/torung1404/aura/main/Main.lua?v=" .. tostring(os.time()),
	Method = "GET",
})

assert(response and response.Body, "Không tải được Main.lua từ GitHub")
assert(not response.StatusCode or response.StatusCode >= 200 and response.StatusCode < 300, "GitHub trả về lỗi")
local run, loadError = loadstring(response.Body)
assert(run, loadError)
run()
