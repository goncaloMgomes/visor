-- Visor: the mouse position and clicks for the robot (eyes that follow the
-- mouse, curious looks after clicks). For Hyprland
-- configured in Lua: add this to hyprland.lua (or `require` it).
-- Writes "x y clicks" to $XDG_RUNTIME_DIR/visor/pointer, every 100 ms while it changes.
local VISOR_PTR = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/visor/pointer"
local visor_clicks, visor_last = 0, ""

local function visor_pointer(force)
    local p = hl.get_cursor_pos()
    if not p then return end
    local line = string.format("%d %d %d", math.floor(p.x), math.floor(p.y), visor_clicks)
    if line == visor_last and not force then return end
    visor_last = line
    local f = io.open(VISOR_PTR, "w")
    if f then f:write(line, "\n"); f:close() end
end
VISOR_PTR_TIMER = hl.timer(function() visor_pointer(false) end, { timeout = 100, type = "repeat" })

local function visor_click()
    visor_clicks = visor_clicks + 1
    visor_pointer(true)
end
hl.bind("mouse:272", visor_click, { non_consuming = true })
hl.bind("mouse:273", visor_click, { non_consuming = true })
