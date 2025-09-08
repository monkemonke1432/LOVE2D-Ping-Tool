-- main.lua
-- LOVE2D ping tool with subtle rainbow gradient and transparent UI

local socket = require("socket")

-- ---------- UI State ----------
local ui = {
    host = "127.0.0.1",
    port = "80",
    protocols = {"TCP","UDP","ICMP"},
    protocolIndex = 1,
    dropdownOpen = false,
    activeField = "host",
    status = "Ready.",
    log = {},
    busy = false
}

local theme = {
    font = nil,
    pad = 8,
    boxH = 32,
    btnW = 120,
    lineH = 20
}

-- ---------- Helpers ----------
local function log(line)
    table.insert(ui.log, 1, os.date("[%H:%M:%S] ") .. line)
    if #ui.log > 200 then table.remove(ui.log) end
end

-- ---------- Ping Implementations ----------
local function pingTCP(host, port, timeout)
    timeout = timeout or 2.0
    local t0 = socket.gettime()
    local tcp = socket.tcp()
    tcp:settimeout(timeout)
    local ok, err = tcp:connect(host, tonumber(port))
    local dt = (socket.gettime() - t0) * 1000
    if ok or err == "already connected" then tcp:close(); return true, dt end
    if tcp.close then tcp:close() end
    return false, dt, err
end

local function pingUDP(host, port, timeout)
    timeout = timeout or 1.0
    local udp = socket.udp()
    udp:settimeout(timeout)
    local ok, err = udp:setpeername(host, tonumber(port))
    if not ok then return false, nil, "setpeername: "..tostring(err) end
    local payload = "love-ping-" .. tostring(math.random(0,1e9))
    local t0 = socket.gettime()
    udp:send(payload)
    local data = udp:receive()
    local dt = (socket.gettime() - t0) * 1000
    udp:close()
    if data then return true, dt end
    return false, dt, "no response (UDP)"
end

local function buildICMPCmd(host, timeoutSec)
    timeoutSec = timeoutSec or 1
    local osname = love.system.getOS()
    if osname == "Windows" then
        return string.format('ping -n 1 -w %d "%s"', math.floor(timeoutSec*1000), host)
    elseif osname == "OS X" then
        return string.format('ping -c 1 "%s"', host)
    else
        return string.format('ping -c 1 -W %d "%s"', timeoutSec, host)
    end
end

local function parseICMP(output)
    local ms = output:match("time[=<]?(%d+%.?%d*)%s*ms") or output:match("time[=<]?(%d+)")
    if ms then ms = tonumber(ms) end
    local success = output:lower():match("ttl") or output:match("1 received") or output:match("bytes from") or output:match("Reply from")
    return (success ~= nil), ms
end

local function pingICMP(host, timeoutSec)
    local cmd = buildICMPCmd(host, timeoutSec)
    local f = io.popen(cmd .. " 2>&1")
    if not f then return false, nil, "io.popen unavailable" end
    local out = f:read("*a") or ""
    f:close()
    local ok, ms = parseICMP(out)
    if ok then return true, ms end
    return false, nil, "no reply"
end

-- ---------- Threads ----------
local function startPing(host, port, proto)
    if ui.busy then return end
    ui.busy = true
    ui.status = "Pinging..."
    local channel = love.thread.getChannel("pingresult")
    channel:clear()

    local code = [[
        local socket = require("socket")
        local args = ...
        local proto, host, port, timeout = args.proto, args.host, args.port, args.timeout
        local result = {proto=proto, host=host, port=port}
        local function pingTCP(host, port, timeout)
            timeout = timeout or 2
            local t0 = socket.gettime()
            local tcp = socket.tcp()
            tcp:settimeout(timeout)
            local ok, err = tcp:connect(host, tonumber(port))
            local dt = (socket.gettime()-t0)*1000
            if ok or err=="already connected" then tcp:close(); return true, dt end
            if tcp.close then tcp:close() end
            return false, dt, err
        end
        local function pingUDP(host, port, timeout)
            timeout = timeout or 1
            local udp = socket.udp()
            udp:settimeout(timeout)
            local ok, err = udp:setpeername(host, tonumber(port))
            if not ok then return false, 0, err end
            local t0 = socket.gettime()
            udp:send("love-ping")
            udp:receive()
            local dt = (socket.gettime()-t0)*1000
            udp:close()
            return true, dt
        end
        local function pingICMP(host, timeout)
            local cmd = 'ping -c 1 "'..host..'"'
            local f = io.popen(cmd..' 2>&1')
            if not f then return false,0,"io.popen unavailable" end
            local out = f:read("*a") or ""
            f:close()
            local ok = out:lower():match("ttl") or out:match("bytes from")
            return ok~=nil,0
        end

        if proto=="TCP" then
            result.ok,result.ms,result.err = pingTCP(host, port, timeout)
        elseif proto=="UDP" then
            result.ok,result.ms,result.err = pingUDP(host, port, timeout)
        else
            result.ok,result.ms,result.err = pingICMP(host, timeout)
        end

        love.thread.getChannel("pingresult"):push(result)
    ]]

    local thread = love.thread.newThread(code)
    thread:start({proto=proto, host=host, port=tonumber(port), timeout=2})
end

-- ---------- Gradient & Transparent UI ----------
local function drawGradientBackground()
    local w, h = love.graphics.getDimensions()
    local verts = {
        {0,0,0,0,1,0.7,0.7,1},   -- top-left
        {w,0,1,0,0.7,1,0.7,1},   -- top-right
        {w,h,1,1,0.7,0.7,1,1},   -- bottom-right
        {0,h,0,1,1,1,0.7,1}      -- bottom-left
    }
    local mesh = love.graphics.newMesh(verts, "fan", "static")
    love.graphics.draw(mesh)
end

local function drawTransparentBox(x,y,w,h,active)
    love.graphics.setColor(0,0,0,0.35)
    love.graphics.rectangle("fill", x,y,w,h)
    love.graphics.setColor(1,1,1,1)
    love.graphics.rectangle("line", x,y,w,h)
    if active then
        love.graphics.setColor(1,1,1,0.6)
        love.graphics.line(x+2, y+h-2, x+w-2, y+h-2)
        love.graphics.setColor(1,1,1,1)
    end
end

-- ---------- LOVE2D Callbacks ----------
function love.load()
    theme.font = love.graphics.newFont(14)
    love.window.setTitle("LOVE2D Ping Tool")
    love.window.setMode(640, 420, {resizable=false})
    math.randomseed(os.time())
end

function love.draw()
    drawGradientBackground()
    love.graphics.setFont(theme.font)
    local w,h = love.graphics.getDimensions()
    local x,y = theme.pad, theme.pad

    -- Host
    love.graphics.print("Host/IP", x,y)
    drawTransparentBox(x, y+18, 260, theme.boxH, ui.activeField=="host")
    love.graphics.print(ui.host, x+6, y+26)

    -- Port
    local px = x+280
    love.graphics.print("Port", px,y)
    drawTransparentBox(px, y+18, 100, theme.boxH, ui.activeField=="port")
    love.graphics.print(ui.port, px+6, y+26)

    -- Protocol
    local dx = px+120
    love.graphics.print("Protocol", dx,y)
    drawTransparentBox(dx, y+18, 120, theme.boxH, ui.activeField=="protocol")
    love.graphics.print(ui.protocols[ui.protocolIndex], dx+6, y+26)
    if ui.dropdownOpen then
        love.graphics.setColor(0,0,0,0.35)
        love.graphics.rectangle("fill", dx, y+18+theme.boxH, 120, #ui.protocols*theme.boxH)
        love.graphics.setColor(1,1,1,1)
        love.graphics.rectangle("line", dx, y+18+theme.boxH, 120, #ui.protocols*theme.boxH)
        for i,p in ipairs(ui.protocols) do
            love.graphics.print(p, dx+6, y+18+theme.boxH+(i-1)*theme.boxH+8)
        end
    end

    -- Ping button
    local bx = dx+140
    love.graphics.setColor(0,0,0,0.35)
    love.graphics.rectangle("fill", bx, y+18, theme.btnW, theme.boxH)
    love.graphics.setColor(1,1,1,1)
    love.graphics.rectangle("line", bx, y+18, theme.btnW, theme.boxH)
    love.graphics.printf(ui.busy and "Pinging..." or "Ping", bx, y+26, theme.btnW, "center")

    -- Status
    love.graphics.print("Status: "..ui.status, x, y+18+theme.boxH+14)

    -- Log
    local logY = y+18+theme.boxH+14+theme.lineH+6
    love.graphics.print("Log:", x, logY)
    love.graphics.setColor(0,0,0,0.35)
    love.graphics.rectangle("fill", x, logY+18, w-2*theme.pad, h-(logY+18)-theme.pad)
    love.graphics.setColor(1,1,1,1)
    love.graphics.rectangle("line", x, logY+18, w-2*theme.pad, h-(logY+18)-theme.pad)
    local ly = logY+24
    for i,line in ipairs(ui.log) do
        love.graphics.print(line, x+6, ly)
        ly = ly + theme.lineH
        if ly > h-theme.pad-theme.lineH then break end
    end
end

function love.update(dt)
    local channel = love.thread.getChannel("pingresult")
    local result = channel:pop()
    if result then
        ui.busy = false
        if result.ok then
            ui.status = string.format("%s reply (%.1f ms)", result.host, result.ms or 0)
        else
            ui.status = string.format("%s no reply - %s", result.host, tostring(result.err))
        end
        log(ui.status)
    end
end

-- ---------- Mouse & Keyboard ----------
local function mouseIn(x,y,w,h,mx,my) return mx>=x and mx<=x+w and my>=y and my<=y+h end

function love.mousepressed(mx,my,btn)
    if btn~=1 then return end
    local x,y = theme.pad, theme.pad
    local px = x+280
    local dx = px+120
    local bx = dx+140

    if mouseIn(x, y+18, 260, theme.boxH, mx,my) then ui.activeField="host"; ui.dropdownOpen=false; return end
    if mouseIn(px, y+18, 100, theme.boxH, mx,my) then ui.activeField="port"; ui.dropdownOpen=false; return end
    if mouseIn(dx, y+18, 120, theme.boxH, mx,my) then ui.activeField="protocol"; ui.dropdownOpen=not ui.dropdownOpen; return end
    if ui.dropdownOpen and mouseIn(dx, y+18+theme.boxH, 120, #ui.protocols*theme.boxH, mx,my) then
        local idx = math.floor((my-(y+18+theme.boxH))/theme.boxH)+1
        if ui.protocols[idx] then ui.protocolIndex=idx end
        ui.dropdownOpen=false
        return
    end
    if mouseIn(bx, y+18, theme.btnW, theme.boxH, mx,my) and not ui.busy then
        if ui.host=="" then ui.status="Enter host/IP"; return end
        if ui.protocols[ui.protocolIndex]~="ICMP" then
            local p=tonumber(ui.port)
            if not p or p<1 or p>65535 then ui.status="Port must be 1..65535"; return end
        end
        startPing(ui.host, ui.port, ui.protocols[ui.protocolIndex])
    end
    ui.activeField=nil
    ui.dropdownOpen=false
end

function love.textinput(t)
    if ui.activeField=="host" then ui.host=ui.host..t
    elseif ui.activeField=="port" then if t:match("%d") then ui.port=ui.port..t end end
end

function love.keypressed(key)
    if key=="tab" then
        if ui.activeField=="host" then ui.activeField="port"
        elseif ui.activeField=="port" then ui.activeField="protocol"
        else ui.activeField="host" end
    elseif key=="return" or key=="kpenter" then
        if not ui.busy then
            if ui.protocols[ui.protocolIndex]~="ICMP" then
                local p=tonumber(ui.port)
                if not p or p<1 or p>65535 then ui.status="Port must be 1..65535"; return end
            end
            startPing(ui.host, ui.port, ui.protocols[ui.protocolIndex])
        end
    elseif key=="backspace" then
        if ui.activeField=="host" then ui.host=ui.host:sub(1,#ui.host-1)
        elseif ui.activeField=="port" then ui.port=ui.port:sub(1,#ui.port-1) end
    elseif key=="escape" then ui.dropdownOpen=false; ui.activeField=nil
    elseif key=="up" or key=="down" then
        local dir=(key=="up") and -1 or 1
        ui.protocolIndex=((ui.protocolIndex-1+dir) % #ui.protocols)+1
    end
end
