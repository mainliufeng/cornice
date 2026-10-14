-- Standalone Lua configuration for Cornice's managed Hyprland session.
-- The session runner owns compositor, Broker and shell startup.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.config({
    general = { layout = "dwindle", gaps_in = 5, gaps_out = 10, border_size = 2 },
    decoration = { rounding = 8 },
    dwindle = { preserve_split = true },
    input = { kb_layout = "us", follow_mouse = 1, touchpad = { natural_scroll = true } },
    xwayland = { enabled = true },
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true },
})
hl.bind("SUPER + R", hl.dsp.exec_cmd("cornice launcher"))
hl.bind("SUPER + N", hl.dsp.exec_cmd("cornice notifications"))
hl.bind("SUPER + ALT + L", hl.dsp.exec_cmd("cornice lock"))
hl.bind("SUPER + C", hl.dsp.window.close())
hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind("SUPER + F", hl.dsp.window.fullscreen())
hl.bind("SUPER + SHIFT + F", hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
for _, direction in ipairs({ "left", "right", "up", "down" }) do
    hl.bind("SUPER + " .. direction, hl.dsp.focus({ direction = direction }))
end
for i = 1, 10 do
    local key = i % 10
    hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end
hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
