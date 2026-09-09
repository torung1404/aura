local response = request({
	Url = "https://raw.githubusercontent.com/torung1404/aurafarming/main/Main.lua",
	Method = "GET",
})

assert(response and response.Body, "Không tải được Main.lua từ GitHub")
local run, loadError = loadstring(response.Body)
assert(run, loadError)
run()
