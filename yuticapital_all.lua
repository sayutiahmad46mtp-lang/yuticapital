-- YutiCapital (satu file): yuticapital.lua + engine.lua + pabrik.lua + ui_extra.lua
-- Tiap bagian dibungkus fungsi sendiri (batas 200 local per fungsi), isinya tidak diubah.

-- ======================= yuticapital.lua =======================
do (function()
-- YutiCapital v1.0 | Tahap 1: kerangka
-- Isi: jendela, watermark nama, config, koneksi ke game, jembatan Session.API
-- (Pabrik, AI satpam & bot chat dipasang di tahap berikutnya, file sendiri)

local G = (getgenv and getgenv()) or _G
-- tutup instance lama (termasuk script Kzoyz x Opus) supaya tidak bentrok
for _, key in ipairs({ "__YutiCapital", "__KzoyzOpus", "__GTFarm" }) do
    if G[key] and G[key].Cleanup then pcall(G[key].Cleanup) end
    G[key] = nil
end
local Session = {}
G.__YutiCapital = Session
local function alive() return G.__YutiCapital == Session end

-- identitas thread + thread khusus untuk mengubah UI (dibutuhkan dropdown di sebagian executor)
do
    local getId = getthreadidentity or get_thread_identity or getidentity or (syn and syn.get_thread_identity)
    if type(getId) == "function" then pcall(function() Session.Ident = getId() end) end
    Session.Exec = coroutine.create(function(job)
        while true do
            local ok, err = pcall(job)
            job = coroutine.yield(ok, err)
        end
    end)
end

---------------------------------------------------------------------
-- SERVICES & MODULE GAME
---------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local TextService = game:GetService("TextService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
PlayerGui:WaitForChild("GameGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemDB = require(Shared.ItemDB)
local InventoryModule = require(Shared.Inventory)

local WindUI = loadstring(game:HttpGet(
    "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"
))()

---------------------------------------------------------------------
-- DATA
---------------------------------------------------------------------
local NAME = "YutiCapital"
local FOLDER = "YutiCapital"

local Opt = { AntiAfk = true }
local Brand = { Text = NAME }

local Refs = {
    World = nil,   -- data world (fg, bg, ukuran)
    Inv = nil,     -- inventori
    SetTile = nil, -- fungsi place game
    State = nil,   -- posisi karakter
    Punch = nil,   -- fungsi pukul game
    Menu = nil,    -- menu game (keluar / masuk world)
    Gems = nil,
    Hud = nil,     -- jangkauan pukul & place, fungsi drop
    Others = nil,  -- daftar pemain lain di world
}

local UI = {}
local Connections = {}

-- Jalankan fn dengan izin penuh. Hasil: ok, err
function UI.exec(fn)
    local setId = setthreadidentity or set_thread_identity or setidentity or (syn and syn.set_thread_identity)
    local function elevate()
        if Session.Ident and type(setId) == "function" then pcall(setId, Session.Ident) end
    end
    local err1 = nil
    local co = Session.Exec
    if co and coroutine.status(co) == "suspended" then
        local okR, ok, err = coroutine.resume(co, function()
            elevate()
            fn()
        end)
        if okR and ok ~= false then return true end
        err1 = okR and err or ok
    end
    elevate()
    local ok2, err2 = pcall(fn)
    if ok2 then return true end
    return false, tostring(err2 or err1)
end

UI.Jobs = {}
function UI.later(key, fn, delay)
    UI.Jobs[key] = { fn = fn, at = os.clock() + (delay or 0) }
end
function UI.runJobs()
    local now = os.clock()
    local due = {}
    for key, job in pairs(UI.Jobs) do
        if now >= job.at then due[#due + 1] = key end
    end
    for _, key in ipairs(due) do
        local job = UI.Jobs[key]
        if job and now >= job.at then
            UI.Jobs[key] = nil
            local ok, err = pcall(job.fn)
            if not ok then warn("[" .. NAME .. "] UI job " .. tostring(key) .. ": " .. tostring(err)) end
        end
    end
end

local function notify(title, content, dur)
    task.defer(function()
        pcall(function()
            WindUI:Notify({ Title = title, Content = content, Duration = dur or 3, Icon = "info" })
        end)
    end)
end

---------------------------------------------------------------------
-- CONFIG: simpan & muat pengaturan otomatis
-- File per akun: workspace/YutiCapital/config_<UserId>.json
---------------------------------------------------------------------
local Config = {
    AutoSave = true,
    Paused = false,
    Folder = FOLDER,
    Data = {},
    List = {},
    LastJson = nil,
    Status = "-",
}

do
    local HttpService = game:GetService("HttpService")
    local canFile = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
    Config.CanFile = canFile
    Config.Path = Config.Folder .. "/config_" .. tostring(LocalPlayer.UserId) .. ".json"

    local function read()
        if not canFile then return nil end
        local okE, exists = pcall(isfile, Config.Path)
        if not okE or not exists then return nil end
        local okR, raw = pcall(readfile, Config.Path)
        if not okR or type(raw) ~= "string" then return nil end
        local okD, data = pcall(HttpService.JSONDecode, HttpService, raw)
        if okD and type(data) == "table" then return data end
        return nil
    end

    local loaded = read()
    Config.Found = loaded ~= nil
    Config.Data = loaded or {}
    if Config.Data.AutoSave == false then Config.AutoSave = false end
    Config.Status = Config.Found and "Config dimuat" or (canFile and "Belum ada config" or "Executor tidak bisa simpan file")

    -- Daftarkan tabel pengaturan; nilai dari file langsung dipasang
    function Config.add(name, tbl, keys)
        table.insert(Config.List, { name = name, tbl = tbl, keys = keys })
        local saved = Config.Data[name]
        if type(saved) ~= "table" then return end
        for _, k in ipairs(keys) do
            local v, cur = saved[k], tbl[k]
            if v ~= nil and (cur == nil or type(v) == type(cur)) then tbl[k] = v end
        end
    end

    function Config.saved(name, key)
        local t = Config.Data[name]
        return type(t) == "table" and t[key] or nil
    end

    local function collect()
        local out = { AutoSave = Config.AutoSave, Version = 1 }
        for _, e in ipairs(Config.List) do
            local t = {}
            for _, k in ipairs(e.keys) do t[k] = e.tbl[k] end
            out[e.name] = t
        end
        return out
    end

    function Config.save(force)
        if not canFile then
            Config.Status = "Executor tidak bisa simpan file"
            return false
        end
        if Config.Paused and not force then return false end
        local okJ, json = pcall(HttpService.JSONEncode, HttpService, collect())
        if not okJ then
            Config.Status = "Gagal membaca pengaturan"
            return false
        end
        if not force and json == Config.LastJson then return true end
        if type(isfolder) == "function" and type(makefolder) == "function" then
            local okF, has = pcall(isfolder, Config.Folder)
            if okF and not has then pcall(makefolder, Config.Folder) end
        end
        local ok = pcall(writefile, Config.Path, json)
        if ok then
            Config.LastJson = json
            Config.Paused = false
            Config.Status = "Tersimpan " .. os.date("%H:%M:%S")
        else
            Config.Status = "Gagal simpan file"
        end
        return ok
    end

    function Config.reset()
        Config.Paused = true
        Config.LastJson = nil
        if canFile and type(delfile) == "function" then
            local ok = pcall(delfile, Config.Path)
            Config.Status = ok and "Config dihapus. Execute ulang untuk default" or "Gagal hapus file"
            return ok
        end
        Config.Status = "Executor tidak bisa hapus file"
        return false
    end

    function Config.start()
        if Config.Found then
            local okJ, json = pcall(HttpService.JSONEncode, HttpService, collect())
            if okJ then Config.LastJson = json end
        end
        task.spawn(function()
            while alive() do
                task.wait(3)
                if Config.AutoSave and alive() then Config.save(false) end
            end
        end)
    end
end

Config.add("Umum", Opt, { "AntiAfk" })

---------------------------------------------------------------------
-- CARI DATA & FUNGSI GAME (getgc)
---------------------------------------------------------------------
local getconsts = (debug and debug.getconstants) or getconstants

local function constsOf(fn)
    if not getconsts then return nil end
    if islclosure and not islclosure(fn) then return nil end
    local ok, consts = pcall(getconsts, fn)
    if not ok or type(consts) ~= "table" then return nil end
    return consts
end

-- Fungsi place game: memakai "placedAt" + "flips"; kirimnya "tile" (baru) / "SetTile" (lama)
local function isSetTileFn(fn)
    local consts = constsOf(fn)
    if not consts then return false end
    local hasSend, hasPlaced, hasFlips = false, false, false
    for _, c in pairs(consts) do
        if c == "tile" or c == "SetTile" then hasSend = true
        elseif c == "placedAt" then hasPlaced = true
        elseif c == "flips" then hasFlips = true end
    end
    return hasSend and hasPlaced and hasFlips
end

-- Fungsi pukul game: "Empty the Vending Machine first!" + "newCrack" (lama: "HarvestProvider")
local function isPunchFn(fn)
    local consts = constsOf(fn)
    if not consts then return false end
    local hasVend, hasMark = false, false
    for _, c in pairs(consts) do
        if c == "Empty the Vending Machine first!" then hasVend = true
        elseif c == "newCrack" or c == "HarvestProvider" then hasMark = true end
    end
    return hasVend and hasMark
end

local function isStateHolder(v)
    local fn = rawget(v, "state")
    if type(fn) ~= "function" then return false end
    local ok, s = pcall(fn)
    return ok and type(s) == "table" and type(s.x) == "number" and type(s.y) == "number"
        and s.facing ~= nil and s.vx ~= nil
end

-- Pastikan fungsi milik game, bukan milik script ini
local function isGameFn(fn)
    if fn == isSetTileFn or fn == isPunchFn then return false end
    if isexecutorclosure then
        local ok, res = pcall(isexecutorclosure, fn)
        if ok and res then return false end
    end
    local ok, src = pcall(debug.info, fn, "s")
    if ok and type(src) == "string" and src ~= "" and not string.find(src, "GameGui", 1, true) then
        return false
    end
    return true
end

local function findRefs()
    for k in pairs(Refs) do Refs[k] = nil end
    if not getgc then return false, "Executor tidak punya getgc()" end
    for _, v in ipairs(getgc(true)) do
        local tv = type(v)
        if tv == "table" then
            if not Refs.World then
                local ok, isWorld = pcall(function()
                    return type(rawget(v, "fg")) == "table" and type(rawget(v, "bg")) == "table"
                        and type(rawget(v, "w")) == "number" and type(rawget(v, "h")) == "number"
                        and rawget(v, "spawn") ~= nil
                end)
                if ok and isWorld then Refs.World = v end
            end
            if not Refs.Inv then
                local ok, isInv = pcall(function()
                    return getmetatable(v) == InventoryModule and type(rawget(v, "slots")) == "table"
                        and rawget(v, "capacity") ~= nil
                end)
                if ok and isInv then Refs.Inv = v end
            end
            if not Refs.State then
                local ok, isHolder = pcall(isStateHolder, v)
                if ok and isHolder then Refs.State = rawget(v, "state") end
            end
            if not Refs.Menu then
                local ok, isMenu = pcall(function()
                    return type(rawget(v, "openBackpack")) == "function" and type(rawget(v, "ui")) == "table"
                end)
                if ok and isMenu then Refs.Menu = v end
            end
            if not Refs.Gems then
                local ok, isG = pcall(function() return type(rawget(v, "addGems")) == "function" end)
                if ok and isG then Refs.Gems = v end
            end
            if not Refs.Hud then
                local ok, isH = pcall(function()
                    return type(rawget(v, "punchRange")) == "function" and type(rawget(v, "handPower")) == "function"
                end)
                if ok and isH then Refs.Hud = v end
            end
            if not Refs.Others then
                -- data pemain lain: punya list(), where(), playerAt()
                local ok, isO = pcall(function()
                    return type(rawget(v, "list")) == "function" and type(rawget(v, "where")) == "function"
                        and type(rawget(v, "playerAt")) == "function"
                end)
                if ok and isO then Refs.Others = v end
            end
        elseif tv == "function" and (not Refs.SetTile or not Refs.Punch) and isGameFn(v) then
            if not Refs.SetTile and isSetTileFn(v) then
                Refs.SetTile = v
            elseif not Refs.Punch and isPunchFn(v) then
                Refs.Punch = v
            end
        end
        if Refs.World and Refs.Inv and Refs.SetTile and Refs.State and Refs.Punch
            and Refs.Menu and Refs.Gems and Refs.Hud and Refs.Others then break end
    end
    return Refs.World ~= nil
end

local function refsText()
    return "World: " .. (Refs.World and "OK" or "TIDAK")
        .. " | Inventori: " .. (Refs.Inv and "OK" or "TIDAK")
        .. " | setTile: " .. (Refs.SetTile and "OK" or "TIDAK")
        .. " | Posisi: " .. (Refs.State and "OK" or "TIDAK")
        .. " | Pukul: " .. (Refs.Punch and "OK" or "TIDAK")
        .. " | Pemain: " .. (Refs.Others and "OK" or "TIDAK")
end

---------------------------------------------------------------------
-- ITEM, INVENTORI & POSISI
---------------------------------------------------------------------
local function itemName(id)
    local it = ItemDB[id]
    return (it and it.name) or ("Item #" .. tostring(id))
end

local function invCount(id)
    if not Refs.Inv then return 0 end
    local ok, n = pcall(function() return Refs.Inv:count(id) end)
    return ok and n or 0
end

local function playerState()
    if not Refs.State then return nil end
    local ok, s = pcall(Refs.State)
    if ok and type(s) == "table" and type(s.x) == "number" and type(s.y) == "number" and s.active ~= false then
        return s
    end
    return nil
end

---------------------------------------------------------------------
-- WATERMARK NAMA (hanya di layar sendiri)
-- Nama asli (huruf gambar "BitmapText") disembunyikan, diganti teks beranimasi
-- di 2 tempat: tag di atas karakter & nama di panel kiri atas.
-- Pemain lain tetap melihat nama asli. Selalu aktif; lepas saat script ditutup.
---------------------------------------------------------------------
local NameFx = { t0 = os.clock(), On = true }

local NAME_COLORS = ColorSequence.new({
    ColorSequenceKeypoint.new(0.00, Color3.fromRGB(170, 90, 255)),  -- ungu
    ColorSequenceKeypoint.new(0.25, Color3.fromRGB(60, 205, 255)),  -- biru muda
    ColorSequenceKeypoint.new(0.50, Color3.fromRGB(255, 110, 210)), -- pink
    ColorSequenceKeypoint.new(0.75, Color3.fromRGB(60, 205, 255)),
    ColorSequenceKeypoint.new(1.00, Color3.fromRGB(170, 90, 255)),
})
local NAME_FONT = Enum.Font.FredokaOne

local function nameHolders()
    local gg = PlayerGui:FindFirstChild("GameGui")
    local world = gg and gg:FindFirstChild("World")
    local cam = world and world:FindFirstChild("Camera")
    local chat = PlayerGui:FindFirstChild("ChatGui")
    local hud = chat and chat:FindFirstChild("HUD")
    local panel = hud and hud:FindFirstChild("PlayerPanel")
    return cam and cam:FindFirstChild("NameTag"), panel and panel:FindFirstChild("Name")
end

local function textWidth(text, size)
    local ok, v = pcall(TextService.GetTextSize, TextService, text, size, NAME_FONT, Vector2.new(2000, 200))
    return (ok and v.X or #text * size * 0.55) + 6 -- +6 untuk garis tepi
end

local function makeLabel(holder, size, isTag)
    local lb = Instance.new("TextLabel")
    lb.Name = "YutiName"
    lb.BackgroundTransparency = 1
    lb.Font = NAME_FONT
    lb.TextSize = size
    lb.TextColor3 = Color3.new(1, 1, 1)
    lb.Text = Brand.Text
    lb.ZIndex = isTag and 1017 or 10
    if isTag then
        lb.AnchorPoint = Vector2.new(0.5, 0.5) -- denyut dari tengah
        lb.Position = UDim2.fromScale(0.5, 0.5)
    else
        lb.AnchorPoint = Vector2.new(0, 0.5)
        lb.Position = UDim2.new(0, 3, 0.5, 0)
        lb.TextXAlignment = Enum.TextXAlignment.Left
    end
    local st = Instance.new("UIStroke")
    st.Thickness = 2
    st.Color = Color3.fromRGB(25, 12, 40)
    st.Transparency = 0.1
    st.Parent = lb
    local gr = Instance.new("UIGradient")
    gr.Color = NAME_COLORS
    gr.Rotation = 12
    gr.Parent = lb
    local sc = Instance.new("UIScale")
    sc.Parent = lb
    lb.Parent = holder
    return { holder = holder, bitmap = holder:FindFirstChild("BitmapText"), label = lb, gr = gr, sc = sc,
        size = size, isTag = isTag, text = nil, w = 0 }
end

local function dropEntry(e)
    if not e then return end
    pcall(function() e.label:Destroy() end)
    if e.bitmap then pcall(function() e.bitmap.Visible = true end) end
    if e.isTag and e.bitmap then
        -- kembalikan ukuran tag & posisi wrench sesuai nama asli
        pcall(function()
            local bw = e.bitmap.Size.X.Offset
            e.holder.Size = UDim2.fromOffset(bw, e.holder.Size.Y.Offset)
            local wr = e.holder:FindFirstChild("Wrench")
            if wr then wr.Position = UDim2.fromOffset(bw + 4, wr.Position.Y.Offset) end
        end)
    end
end

local function nameRestore()
    dropEntry(NameFx.tag)
    dropEntry(NameFx.panel)
    NameFx.tag, NameFx.panel = nil, nil
end

-- Pastikan label ada, nama asli tersembunyi, ukuran tag pas dengan teks
local function nameKeep(e, holder, size, isTag)
    if not holder then
        dropEntry(e)
        return nil
    end
    if not e or e.holder ~= holder or not e.label.Parent then
        dropEntry(e)
        e = makeLabel(holder, size, isTag)
    end
    if e.text ~= Brand.Text then
        e.text = Brand.Text
        e.label.Text = Brand.Text
        e.w = textWidth(Brand.Text, size)
    end
    if e.bitmap and e.bitmap.Visible then e.bitmap.Visible = false end
    if isTag then
        local h = math.max(holder.Size.Y.Offset, size + 6)
        if e.label.Size.X.Offset ~= e.w or e.label.Size.Y.Offset ~= h then
            e.label.Size = UDim2.fromOffset(e.w, h)
        end
        if holder.Size.X.Offset ~= e.w then
            holder.Size = UDim2.fromOffset(e.w, holder.Size.Y.Offset) -- bendera tetap di kiri nama
        end
        local wr = holder:FindFirstChild("Wrench")
        if wr and wr.Position.X.Offset ~= e.w + 4 then
            wr.Position = UDim2.fromOffset(e.w + 4, wr.Position.Y.Offset)
        end
    else
        e.label.Size = UDim2.new(1, -6, 1, 0)
    end
    return e
end

-- Animasi tiap frame: gradient mengalir + denyut halus
table.insert(Connections, RunService.RenderStepped:Connect(function()
    if not alive() or not NameFx.On then return end
    local tag, panelName = nameHolders()
    NameFx.tag = nameKeep(NameFx.tag, tag, 22, true)
    NameFx.panel = nameKeep(NameFx.panel, panelName, 21, false)
    local t = os.clock() - NameFx.t0
    local offset = Vector2.new(((t * 0.45) % 2) - 1, 0)
    local pulse = 1 + 0.045 * math.sin(t * 3.2)
    local tg, pn = NameFx.tag, NameFx.panel
    if tg then
        tg.gr.Offset = offset
        tg.sc.Scale = pulse
    end
    if pn then
        pn.gr.Offset = offset
        pn.sc.Scale = pulse
    end
end))

---------------------------------------------------------------------
-- ANTI AFK
---------------------------------------------------------------------
table.insert(Connections, LocalPlayer.Idled:Connect(function()
    if Opt.AntiAfk and alive() then
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end
end))

---------------------------------------------------------------------
-- UI WINDUI
---------------------------------------------------------------------
local Window = WindUI:CreateWindow({
    Title = NAME,
    Icon = "sprout",
    Author = "v1.0 | Tahap 1",
    Folder = FOLDER,
    Size = UDim2.fromOffset(640, 380),
    Theme = "Dark",
    Transparent = true,
    SideBarWidth = 150,
    ToggleKey = Enum.KeyCode.Insert, -- PC: Insert untuk buka/tutup menu
})
pcall(function()
    Window:EditOpenButton({
        Title = NAME,
        Icon = "sprout",
        Draggable = true,
        OnlyMobile = false,
    })
end)

-- Kalau 1 elemen error, yang lain tetap dibuat
local function safe(fn)
    local ok, err = pcall(fn)
    if not ok then warn("[" .. NAME .. "] UI error: " .. tostring(err)) end
end

local function makeTab(title, icon)
    local ok, tab = pcall(function() return Window:Tab({ Title = title, Icon = icon }) end)
    if ok and tab then return tab end
    return Window:Tab({ Title = title })
end

-- Kotak di dalam tab yang bisa dibuka / ditutup
local function box(tab, title, opened)
    local ok, sec = pcall(function()
        return tab:Section({ Title = title, Box = true, BoxBorder = true, Opened = opened == true })
    end)
    if ok and type(sec) == "table" and type(sec.Toggle) == "function" then return sec end
    pcall(function() tab:Section({ Title = title }) end)
    return tab
end

-- Angka pakai Slider; kalau gagal, pakai kotak input
local function addNumber(tab, o)
    local ok = pcall(function()
        tab:Slider({
            Title = o.Title,
            Desc = o.Desc,
            Step = o.Step or 1,
            Value = { Min = o.Min, Max = o.Max, Default = o.Default },
            Callback = function(v)
                v = tonumber(v)
                if v then o.Callback(v) end
            end,
        })
    end)
    if ok then return end
    safe(function()
        tab:Input({
            Title = o.Title,
            Desc = (o.Desc and (o.Desc .. " ") or "") .. "(" .. o.Min .. "-" .. o.Max .. ")",
            Value = tostring(o.Default),
            Placeholder = tostring(o.Default),
            Callback = function(text)
                local v = tonumber(text)
                if v then o.Callback(math.clamp(v, o.Min, o.Max)) end
            end,
        })
    end)
end

-- Cek data pemain lain (untuk menentukan radius bot chat): hasil di console (F9)
local function dumpOthers()
    local o = Refs.Others
    if not o then
        notify("Pemain", "Data pemain belum ketemu, tekan Hubungkan ke game", 4)
        return
    end
    local ok, list = pcall(o.list)
    if not ok or type(list) ~= "table" then
        warn("[" .. NAME .. "] Others.list gagal: " .. tostring(list))
        return
    end
    local me = playerState()
    print(("[%s] posisi sendiri: x=%s y=%s | entri pemain lain: %d"):format(
        NAME, me and tostring(me.x) or "?", me and tostring(me.y) or "?", #list))
    for i, e in ipairs(list) do
        if type(e) == "table" then
            for k, v in pairs(e) do print("  entri " .. i, k, v) end
            local uid = tonumber(e[1] or e.userId)
            if uid then
                local ok2, a, b, c = pcall(o.where, uid)
                print("  where(" .. uid .. ") =", ok2, a, b, c)
            end
        else
            print("  entri " .. i, e)
        end
    end
    notify("Pemain", "Hasil ada di console (F9)", 4)
end

local function reconnect(show)
    findRefs()
    pcall(function() UI.RefInfo:SetDesc(refsText()) end)
    if show then notify(show, refsText(), 5) end
end

-- ===== TAB: STATUS =====
local MainTab = makeTab("Status", "activity")

safe(function()
    UI.RefInfo = MainTab:Paragraph({ Title = "Koneksi game", Desc = "-" })
end)
safe(function()
    UI.ConfigStatus = MainTab:Paragraph({ Title = "Config", Desc = Config.Status })
end)

local bConn = box(MainTab, "Koneksi", true)
local bCfg = box(MainTab, "Config", false)

safe(function()
    bConn:Button({
        Title = "Hubungkan ke game",
        Desc = "Pakai setelah pindah world",
        Callback = function()
            UI.later("reconnect", function() reconnect("Koneksi") end)
        end,
    })
end)

safe(function()
    bConn:Button({
        Title = "Cek data pemain (console)",
        Desc = "Cetak posisi pemain lain ke console F9, untuk radius bot chat",
        Callback = function() pcall(dumpOthers) end,
    })
end)

safe(function()
    bConn:Toggle({
        Title = "Anti AFK",
        Value = Opt.AntiAfk,
        Callback = function(on) Opt.AntiAfk = on end,
    })
end)

safe(function()
    bCfg:Toggle({
        Title = "Auto Save Config",
        Desc = "Simpan pengaturan otomatis, dimuat lagi saat execute",
        Value = Config.AutoSave,
        Callback = function(on)
            Config.AutoSave = on
            Config.save(true)
        end,
    })
end)

safe(function()
    bCfg:Button({
        Title = "Simpan config sekarang",
        Callback = function()
            local ok = Config.save(true)
            notify("Config", ok and "Tersimpan" or Config.Status, 3)
        end,
    })
end)

safe(function()
    bCfg:Button({
        Title = "Reset config (default)",
        Desc = "Hapus file config, lalu execute ulang",
        Callback = function()
            Config.reset()
            notify("Config", Config.Status, 4)
        end,
    })
end)

---------------------------------------------------------------------
-- JEMBATAN untuk file lain (Pabrik, AI satpam, bot chat)
-- File lain membaca: getgenv().__YutiCapital.API
---------------------------------------------------------------------
Session.API = {
    Name = NAME,
    Folder = FOLDER,
    alive = alive,
    Refs = Refs,
    UI = UI,
    Config = Config,
    Window = Window,
    WindUI = WindUI,
    Connections = Connections,
    ItemDB = ItemDB,
    notify = notify,
    safe = safe,
    makeTab = makeTab,
    box = box,
    addNumber = addNumber,
    invCount = invCount,
    itemName = itemName,
    playerState = playerState,
    reconnect = reconnect,
    findRefs = findRefs,
}

---------------------------------------------------------------------
-- INIT
---------------------------------------------------------------------
-- Thread pekerjaan UI (dropdown di sebagian executor hanya bisa diubah dari thread ini)
task.spawn(function()
    while alive() do
        local ok, err = pcall(UI.runJobs)
        if not ok then warn("[" .. NAME .. "] UI runner: " .. tostring(err)) end
        task.wait(0.1)
    end
end)

task.spawn(function()
    reconnect(NAME)
    Config.start()
end)

task.spawn(function()
    local shownRefs, shownCfg = nil, nil
    while alive() do
        local txt = refsText()
        if UI.RefInfo and txt ~= shownRefs then
            shownRefs = txt
            pcall(function() UI.RefInfo:SetDesc(txt) end)
        end
        if UI.ConfigStatus and Config.Status ~= shownCfg then
            shownCfg = Config.Status
            pcall(function() UI.ConfigStatus:SetDesc(Config.Status) end)
        end
        task.wait(1)
    end
end)

---------------------------------------------------------------------
-- CLEANUP (otomatis saat script dijalankan ulang)
---------------------------------------------------------------------
Session.Cleanup = function()
    if Config.AutoSave then pcall(Config.save, false) end
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    NameFx.On = false
    pcall(nameRestore)
    pcall(function() Window:Destroy() end)
end

end)() end

-- ======================= engine.lua =======================
do (function()
-- YutiCapital v1.0 | Tahap 2A: engine.lua
-- Isi: mesin gerak otomatis (A*), place & pukul, auto collect (drop), mesin panen/tanam lahan,
--      pindah world, titik drop (dropTrip), notifikasi Discord.
-- Dibuka lewat: getgenv().__YutiCapital.API.Engine
-- Jalankan SETELAH yuticapital.lua. Logika disalin dari script lama (Kzoyz x Opus), nama fungsi sama.

local G = (getgenv and getgenv()) or _G
local Session = G.__YutiCapital
local API = Session and Session.API
if not API then
    warn("[YutiCapital] engine.lua: jalankan yuticapital.lua dulu")
    return
end
-- engine lama (kalau engine.lua dijalankan ulang): tutup dulu supaya hook tidak bertumpuk
if API.Engine and API.Engine.Cleanup then pcall(API.Engine.Cleanup) end
API.Engine = nil

local alive = API.alive
local NAME = API.Name

---------------------------------------------------------------------
-- SERVICES & MODULE GAME
---------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WorldRemotes = ReplicatedStorage:WaitForChild("WorldRemotes")
-- Remote lama (versi game sebelum ByteNet). Hanya dipakai kalau fungsi baru tidak ada.
local SetTileRemote = WorldRemotes:FindFirstChild("SetTile")

local ItemDB = API.ItemDB
local NetOk, Net = pcall(require, Shared.Net)

local GameGui = PlayerGui:WaitForChild("GameGui")
local MenuModOk, MenuModule = pcall(require, GameGui:WaitForChild("WorldMenu"))

---------------------------------------------------------------------
-- BAGIAN DARI tahap 1 (dipakai apa adanya)
---------------------------------------------------------------------
local Refs = API.Refs
local UI = API.UI
local Config = API.Config
local Connections = API.Connections
local notify = API.notify
local itemName = API.itemName
local invCount = API.invCount
local playerState = API.playerState

local getconsts = (debug and debug.getconstants) or getconstants

---------------------------------------------------------------------
-- PENGATURAN & DATA (disalin dari script lama)
---------------------------------------------------------------------
local State = {
    Running = false,
    Mode = "Place + Break",       -- "Place + Break" | "Break saja" | "Place saja"
    PlaceMs = 250,                -- jeda setelah tiap place
    BreakMs = 220,                -- jeda tiap pukulan (normal 220)
    AfterBreakMs = 300,           -- jeda setelah block hancur
    HitsOverride = 0,             -- jumlah pukulan manual (0 = otomatis)
    BreakBackground = true,       -- selalu ikut pecah background (tanpa tombol)
    MultiTarget = 1,              -- jumlah tile dipukul bergantian (1 = biasa)
    SelectedId = nil,
    Offsets = {},                 -- tile yang dipilih di Grid
    CalibX = 0,
    CalibY = 0,
    AntiAfk = true,
    MutePunch = true,
    Visual = true,                -- animasi tangan saat break / place / tanam / panen (tampilan saja)
    LiteMode = false,
    AutoCollect = true,           -- ambil drop di tile yang dipilih
    CollectAround = false,        -- ambil drop di sekitar karakter (radius) kapan saja
    CollectRadius = 3,            -- jari-jari collect (tile), dipakai mode Remote
    CollectMode = "Sentuhan",     -- "Sentuhan" (badan, seperti main manual) / "Remote" (ambil dari jauh, cara lama)
    Override = nil,               -- Pabrik memakai tile & block sendiri
    Quiet = false,                -- tanpa notifikasi (dipakai Pabrik)
    Cycles = 0,
    Placed = 0,
    Broken = 0,
    Collected = 0,                -- jumlah drop yang diambil
    CollectFail = 0,              -- jumlah drop yang ditolak server
    LastAction = "-",
    SeedDrop = false,             -- seed hasil break sudah banyak -> drop ke titik drop
    SeedDropAt = 190,             -- drop kalau seed sudah sebanyak ini
    SeedKeep = 0,                 -- seed yang disisakan
    Dropped = 0,
    DropPause = false,            -- Auto Farm dijeda sementara (sedang pergi drop)
}

local Land = {
    X0 = 0, X1 = 99,  -- kolom awal & akhir
    Y0 = 2,           -- baris block paling atas
    Gap = 2,          -- jarak antar baris (2 = ada 1 tile kosong untuk pohon)
    Rows = 10,        -- jumlah baris
    Stairs = true,    -- ujung baris dibuka bergantian kiri/kanan (jalan naik-turun seperti tangga)
}

-- Pabrik: state bersama. engine memakai Zone / Drop* / Traveling / Running / Exit; pabrik.lua (2B)
-- menambah modul Pabrik (step, loop, start, stop) pada tabel yang sama.
local Pabrik = {
    Running = false,
    SeedId = nil,
    BlockId = nil,
    WholeWorld = false,  -- tanam & panen di seluruh world (bukan hanya lahan)
    Tiles = {},          -- tile break, relatif ke posisi break ("dx,dy")
    BreakX = -1, BreakY = -1,
    BreakSec = 60,       -- lama 1 sesi break sebelum cek pohon lagi
    Drop = true,
    Keep = 50,           -- seed yang disisakan untuk ditanam lagi
    DropAt = 200,        -- drop kalau seed sudah sebanyak ini
    DropWorld = "",      -- "" = world ini | "WORLD" | "WORLD:ID"
    DropX = -1, DropY = -1,
    Harvested = 0,
    Planted = 0,
    Dropped = 0,
    Skip = {},
    Status = "-",
    Traveling = false,
    Home = "",
    Zone = nil,          -- tempat drop (tidak ikut di-collect), dipakai semua fitur drop
    Row = {},            -- baris tanam yang sedang dikerjakan
    Exit = "-",          -- kategori keluar world: "-" | "penjaga" | "otomatis"
    ExitWhy = nil,       -- alasan singkat (untuk status)
}

local Farmer = {
    Running = false,
    Harvest = true,
    Plant = true,
    Collect = true,
    UseBlock = false,   -- taruh block kalau tidak ada jalan
    ScaffoldId = nil,
    HarvestMs = 250,    -- jeda setelah tiap panen
    PlantMs = 250,      -- jeda setelah tiap tanam
    SeedId = nil,
    Skip = {},
    Harvested = 0,
    Planted = 0,
    Status = "-",
    Drop = false,       -- inventori hampir penuh -> drop hasil panen ke titik drop
    DropAt = 190,       -- drop kalau item hasil panen sudah sebanyak ini
    Keep = 50,          -- seed tanam yang disisakan
    Dropped = 0,
    Got = {},           -- seed pohon yang pernah dipanen (untuk cari item hasil panen)
    Row = {},           -- baris tanam yang sedang dikerjakan (tanam rapi per baris)
}

-- Bendera fitur lain yang TIDAK dibawa ke YutiCapital. Kode mesin (autoOn, worldVersion,
-- collectTick, scaffoldId, dll) masih membaca bendera ini, jadi dibiarkan ada dengan nilai mati.
-- Fitur baru di masa depan (mis. Vending) cukup menyalakan benderanya lewat API.Engine.
local Misc = { Ghost = false }
local Clear = { Running = false, Collect = true, UseBlock = false, ScaffoldId = nil, Broken = 0, Status = "-" }
local Splice = { Running = false, Roaming = false, Planted = 0, Status = "-" }
local Build = { Running = false, Placed = 0, Harvested = 0, Planted = 0, Dug = 0, Status = "-" }
local Vend = { Running = false, Status = "-" }

-- Penjaga: engine hanya butuh nama world, keluar / masuk world, dan Mode "idle".
-- (Deteksi Mod / Dev / pemain ada di tahap AI satpam, memakai tabel ini juga.)
local Guard = { On = false, Mode = "idle" }

-- Tombol gerak buatan (dipakai gerak otomatis)
local AutoInput = { active = false, left = false, right = false, jump = false, down = false }

-- Daftar drop di world (diambil dari game)
local Drops = { list = nil, update = nil, brokeAt = {} }
-- Animasi aksi: fungsi gambar tangan game + nomor upvalue "aksi terakhir" (diisi saat hubungkan)
local Anim = { fn = nil, idx = nil, set = nil }
local DropFailUntil = {}   -- drop yang ditolak, dicoba lagi nanti
local HitCount = {}        -- hitung pukulan (cadangan)
local PlacedAt = {}        -- kapan tile di-place

local Stats = { T0 = os.clock(), Gems0 = nil, Items = {}, Base = {} }

local Engine = {}
local function engineAlive() return alive() and not Engine.Dead end

---------------------------------------------------------------------
-- NOTIFIKASI DISCORD (webhook)
---------------------------------------------------------------------
local Hook = {
    On = false,
    Url = "",
    Penjaga = true,   -- mod / dev / pemain masuk world
    Stop = true,      -- aktivitas berhenti (block habis, error)
    Full = true,      -- inventori penuh
    Bonus = true,     -- quest diklaim / redeem berhasil
    Rejoin = true,    -- terlempar / masuk lagi
    Pabrik = true,    -- pabrik drop / lahan selesai / berhenti
    ReportMin = 0,    -- laporan statistik tiap X menit (0 = mati)
    Queue = {},
    LastFull = {},
    Status = "-",
}

do (function()
    local HttpService = game:GetService("HttpService")

    local function requester()
        return (syn and syn.request) or (http and http.request) or http_request or request
            or (fluxus and fluxus.request)
    end

    function Hook.valid(url)
        url = tostring(url or "")
        for _, host in ipairs({ "discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com" }) do
            if string.sub(url, 1, #host + 22) == "https://" .. host .. "/api/webhooks/" then return true end
        end
        return false
    end

    -- jenis: "penjaga" | "stop" | "full" | "bonus" | "rejoin" | "report" | "test"
    function Hook.send(kind, text)
        if not Hook.On or not Hook.valid(Hook.Url) then return end
        local allow = kind == "test" or kind == "report"
            or (kind == "penjaga" and Hook.Penjaga) or (kind == "stop" and Hook.Stop)
            or (kind == "full" and Hook.Full) or (kind == "bonus" and Hook.Bonus)
            or (kind == "rejoin" and Hook.Rejoin) or (kind == "pabrik" and Hook.Pabrik)
        if not allow or #Hook.Queue >= 20 then return end
        table.insert(Hook.Queue, tostring(text))
    end

    task.spawn(function()
        while engineAlive() do
            local text = table.remove(Hook.Queue, 1)
            if not text then
                task.wait(0.5)
            else
                local req = requester()
                if not req then
                    Hook.Status = "Executor tidak punya fungsi request"
                else
                    local body = HttpService:JSONEncode({
                        username = NAME,
                        content = ("**[%s]** %s"):format(LocalPlayer.Name, text),
                    })
                    local ok, res = pcall(req, {
                        Url = Hook.Url, Method = "POST",
                        Headers = { ["Content-Type"] = "application/json" }, Body = body,
                    })
                    local code = ok and type(res) == "table" and tonumber(res.StatusCode or res.Status) or nil
                    if ok and (code == nil or code < 300) then
                        Hook.Status = "Terkirim " .. os.date("%H:%M:%S")
                    else
                        Hook.Status = "Gagal kirim (" .. tostring(code or res) .. ")"
                    end
                end
                task.wait(2.5)
            end
        end
    end)
end)() end

---------------------------------------------------------------------
-- ANIMASI TANGAN GAME (tampilan saja)
---------------------------------------------------------------------
-- Fungsi game yang menggambar tangan karakter saat memukul / memasang
function Anim.isArmFn(fn)
    if not getconsts then return false end
    if islclosure and not islclosure(fn) then return false end
    local ok, consts = pcall(getconsts, fn)
    if not ok or type(consts) ~= "table" then return false end
    local a, b, c = false, false, false
    for _, k in pairs(consts) do
        if k == "forearm" then a = true
        elseif k == "heldReach" then b = true
        elseif k == "punchReach" then c = true end
    end
    return a and b and c
end

-- Cari nomor upvalue "aksi terakhir" (tabel {t, x, y, facing} atau nil) di fungsi tangan.
-- Upvalue ini dipakai bersama oleh kode input & gambar karakter game, jadi cukup diganti sekali.
function Anim.bind(fn)
    local gu = (debug and debug.getupvalue) or getupvalue
    local su = (debug and debug.setupvalue) or setupvalue
    if not (gu and su) then return false end
    local vals, last = {}, 0
    for i = 1, 16 do
        local ok, v = pcall(gu, fn, i)
        if not ok then break end
        vals[i] = v
        if v ~= nil then last = i end
    end
    for i = 1, last - 1 do
        local v = vals[i]
        if v == nil or (type(v) == "table" and rawget(v, "t") ~= nil and rawget(v, "facing") ~= nil) then
            Anim.fn, Anim.idx, Anim.set = fn, i, su
            return true
        end
    end
    return false
end

---------------------------------------------------------------------
-- WORLD: tile & posisi karakter
---------------------------------------------------------------------
local function tileAt(layer, x, y)
    local w = Refs.World
    if not w or x < 0 or y < 0 or x >= w.w or y >= w.h then return nil end
    local grid = w[layer]
    local row = grid and grid[y]
    return row and (row[x] or 0) or nil
end

local function getView()
    local gg = PlayerGui:FindFirstChild("GameGui")
    local cam = gg and gg:FindFirstChild("World") and gg.World:FindFirstChild("Camera")
    local tiles = cam and cam:FindFirstChild("Tiles")
    local pv = cam and cam:FindFirstChild("PlayerView")
    if not (tiles and pv) then return nil end
    local sample = tiles:FindFirstChildWhichIsA("ImageLabel")
    if not sample or sample.AbsoluteSize.X <= 0 then return nil end
    return { tiles = tiles, pv = pv, ts = sample.AbsoluteSize.X }
end

local function getPlayerTile()
    if Refs.State then
        local ok, s = pcall(Refs.State)
        if ok and type(s) == "table" and type(s.x) == "number" then
            if s.active == false then return nil end
            return math.floor(s.x) + State.CalibX, math.floor(s.y - 0.475) + State.CalibY
        end
    end
    local v = getView()
    if not v then return nil end
    local center = v.pv.AbsolutePosition + v.pv.AbsoluteSize / 2
    local rel = center - v.tiles.AbsolutePosition
    return math.floor(rel.X / v.ts) + State.CalibX, math.floor(rel.Y / v.ts) + State.CalibY
end

-- Tile, block & mode Auto Farm yang dipakai sekarang (Pabrik memakai miliknya sendiri)
local function farmOffsets()
    local o = State.Override
    return (o and o.offsets) or State.Offsets
end
local function farmBlock()
    local o = State.Override
    if o then return o.block end
    return State.SelectedId
end
local function farmMode()
    local o = State.Override
    return (o and o.mode) or State.Mode
end

local function sortedOffsets()
    local list = {}
    for key in pairs(farmOffsets()) do
        local dx, dy = string.match(key, "^(-?%d+),(-?%d+)$")
        table.insert(list, { dx = tonumber(dx), dy = tonumber(dy) })
    end
    table.sort(list, function(a, b)
        if a.dy ~= b.dy then return a.dy < b.dy end
        return a.dx < b.dx
    end)
    return list
end

---------------------------------------------------------------------
-- AKSI DASAR: place & pukul
---------------------------------------------------------------------
local function sendSetTile(layer, x, y, id)
    if id ~= 0 and State.Visual and Anim.place then Anim.place(x, y, id) end
    if Refs.SetTile then
        local ok, err = pcall(Refs.SetTile, layer, x, y, id, false, false)
        if ok then return true end
        warn("[" .. NAME .. "] setTile game gagal, pakai remote langsung: " .. tostring(err))
    end
    if NetOk and type(Net) == "table" and type(Net.tile) == "table" then
        -- sama seperti game: layer 1 = fg, 2 = bg
        local ok = pcall(Net.tile.send, {
            layer = (layer == "bg") and 2 or 1, x = x, y = y, id = id, flip = false,
        })
        if not ok then return false end
    elseif SetTileRemote then
        SetTileRemote:FireServer(layer, x, y, id, false)
    else
        return false
    end
    local grid = Refs.World and Refs.World[layer]
    if grid and grid[y] then grid[y][x] = id end
    return true
end

local function sendHitFx(x, y)
    if NetOk and type(Net) == "table" and Net.act then
        pcall(Net.act.send, { x = x + 0.5, y = y + 0.5 })
    end
end

local function hitsNeeded(id)
    if State.HitsOverride > 0 then return State.HitsOverride end
    local it = ItemDB[id]
    if not it then return 4 end
    local h = (it.kind == "seed") and 20 or it.hits
    return tonumber(h) or 4
end

local function canBreak(id)
    if id == 0 then return false end
    local it = ItemDB[id]
    if not it then return true end
    if it.lock or it.area or it.vend or it.display then return false end
    local h = (it.kind == "seed") and 20 or it.hits
    return h == nil or h > 0
end

-- Game abaikan pukulan ke tile yang baru di-place (< 0.3 detik)
local PLACE_GUARD = 0.32

-- Place 1 tile kalau kosong. Hasil: "place" / "habis" / nil
local function tryPlace(x, y)
    local sel = farmBlock()
    if not sel then return nil end
    local fg = tileAt("fg", x, y)
    if fg == nil then return nil end
    local bg = tileAt("bg", x, y)
    local it = ItemDB[sel]
    local layer = (it and it.background) and "bg" or "fg"
    local cur = (layer == "bg") and bg or fg
    if not (cur == 0 and (layer == "bg" or fg == 0)) then return nil end
    if invCount(sel) <= 0 then return "habis" end

    sendSetTile(layer, x, y, sel)
    if Refs.Inv then pcall(function() Refs.Inv:remove(sel, 1) end) end
    local key = x .. "," .. y
    HitCount[key] = nil
    PlacedAt[key] = os.clock()
    State.Placed += 1
    State.LastAction = "Place " .. itemName(sel) .. " (" .. x .. "," .. y .. ")"
    return "place"
end

-- Masih ada yang bisa dipecah di tile ini? (block depan / background)
local function breakableAt(x, y)
    local fg = tileAt("fg", x, y)
    if fg == nil then return false end
    if fg ~= 0 then return canBreak(fg) end
    local bg = tileAt("bg", x, y)
    return State.BreakBackground and bg ~= nil and bg ~= 0 and canBreak(bg)
end

-- Pukul 1 kali. Hasil: "hit" / "broke" / nil
-- includeBg = ikut pecah background
local function tryBreak(x, y, includeBg)
    if includeBg == nil then includeBg = State.BreakBackground end
    local key = x .. "," .. y
    local fg = tileAt("fg", x, y)
    if fg == nil then return nil end
    local bg = tileAt("bg", x, y)
    local layer, id
    if fg ~= 0 then
        layer, id = "fg", fg
    elseif includeBg and bg ~= 0 then
        layer, id = "bg", bg
    end
    if not layer or not canBreak(id) then return nil end

    -- tunggu sebentar kalau tile baru di-place
    local t = PlacedAt[key]
    if t then
        local age = os.clock() - t
        if age < PLACE_GUARD then task.wait(PLACE_GUARD - age) end
        PlacedAt[key] = nil
    end

    if Refs.Punch then
        local ok, err = pcall(Refs.Punch, x, y, State.MutePunch or nil, nil)
        if not ok then
            State.LastAction = "Error pukul: " .. tostring(err)
            return nil
        end
        if State.Visual then Anim.swing(x, y, "punch") end
        if tileAt(layer, x, y) ~= id then
            Drops.brokeAt[key] = os.clock()
            State.Broken += 1
            State.LastAction = "Break " .. itemName(id) .. " (" .. x .. "," .. y .. ")"
            return "broke"
        end
        State.LastAction = "Pukul " .. itemName(id) .. " (" .. x .. "," .. y .. ")"
        return "hit"
    end

    -- Cadangan: hitung pukulan sendiri
    local hc = HitCount[key]
    if not hc or hc.id ~= id or hc.layer ~= layer then
        hc = { id = id, layer = layer, n = 0 }
        HitCount[key] = hc
    end
    hc.n += 1
    sendHitFx(x, y)
    if State.Visual then Anim.swing(x, y, "punch") end
    local need = hitsNeeded(id)
    if hc.n >= need then
        sendSetTile(layer, x, y, 0)
        HitCount[key] = nil
        Drops.brokeAt[key] = os.clock()
        State.Broken += 1
        State.LastAction = "Break " .. itemName(id) .. " (" .. x .. "," .. y .. ")"
        return "broke"
    end
    State.LastAction = "Pukul " .. itemName(id) .. " " .. hc.n .. "/" .. need
    return "hit"
end

---------------------------------------------------------------------
-- AUTO COLLECT
---------------------------------------------------------------------
-- Cara game: World.takeDrop(uid, jumlah) -> server balas jumlahnya -> masuk inventori.
-- Game cuma ambil drop yang disentuh badan; di sini drop diambil langsung.
local TakeDropRemote = WorldRemotes:FindFirstChild("TakeDrop") -- game lama saja

local getUpvalues -- (didefinisikan di bawah)

-- Fungsi tangan game dipanggil dari fungsi gambar yang terhubung ke RenderStepped:
-- cukup periksa upvalue fungsi-fungsi itu (jauh lebih ringan dari scan getgc).
function Anim.findFast()
    if not getconnections or Anim.fn then return Anim.fn ~= nil end
    for _, name in ipairs({ "RenderStepped", "Heartbeat", "PreRender", "Stepped" }) do
        local okS, sig = pcall(function() return RunService[name] end)
        if okS and sig then
            local ok, conns = pcall(getconnections, sig)
            if ok and type(conns) == "table" then
                for _, c in ipairs(conns) do
                    local okf, fn = pcall(function() return c.Function end)
                    if okf and type(fn) == "function" then
                        for _, u in pairs(getUpvalues(fn)) do
                            if type(u) == "function" and Anim.isArmFn(u) then
                                Refs.Arm = u
                                return Anim.bind(u)
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

function getUpvalues(fn)
    if debug and debug.getupvalues then
        local ok, ups = pcall(debug.getupvalues, fn)
        if ok and type(ups) == "table" then return ups end
    end
    local out = {}
    local gu = (debug and debug.getupvalue) or getupvalue
    if gu then
        for i = 1, 60 do
            local ok, v = pcall(gu, fn, i)
            if not ok then break end
            out[i] = v
        end
    end
    return out
end

-- Cek apakah tabel ini daftar drop game
local function isDropList(t)
    if type(t) ~= "table" or t == Refs.World then return false end
    local first = rawget(t, 1)
    if first == nil then return next(t) == nil end
    return type(first) == "table" and rawget(first, "uid") ~= nil and rawget(first, "frame") ~= nil
end

-- deep = true: boleh pakai getgc (berat, bisa bikin lag / crash di HP) -> hanya dari tombol "Hubungkan ke game"
local function findDropRefs(deep)
    -- 0) fungsi game World.dropList(): daftar drop yang sama untuk semua world (paling ringan)
    local w0 = Refs.World
    local dl = w0 and rawget(w0, "dropList")
    if type(dl) == "function" then
        local okl, l = pcall(dl)
        if okl and isDropList(l) then
            if Drops.list ~= l then Drops.update = nil end
            Drops.list = l
            -- v5.9.0: fungsi update (kurangi / hapus drop) juga wajib dicari. Dulu langsung
            -- return di sini, jadi Drops.update kosong -> drop hasil mode Remote tidak dihapus.
            if not Drops.update then Drops.findUpdate() end
            return true
        end
    end
    if Drops.list and not deep then return true end -- yang lama masih dipakai
    Drops.list, Drops.update = nil, nil
    -- 1) dari fungsi World.dropTaken (isinya: daftar drop + fungsi update)
    local wd = Refs.World and rawget(Refs.World, "dropTaken")
    if type(wd) == "function" then
        for _, u in pairs(getUpvalues(wd)) do
            if not Drops.list and isDropList(u) then
                Drops.list = u
            elseif not Drops.update and type(u) == "function" then
                Drops.update = u
            end
        end
    end
    -- 2) dari handler DropTaken game
    local ev = WorldRemotes:FindFirstChild("DropTaken")
    if not Drops.list and ev and getconnections then
        local ok, conns = pcall(getconnections, ev.OnClientEvent)
        if ok and type(conns) == "table" then
            for _, c in ipairs(conns) do
                local okf, fn = pcall(function() return c.Function end)
                if okf and type(fn) == "function" then
                    for _, u in pairs(getUpvalues(fn)) do
                        if not Drops.list and isDropList(u) then
                            Drops.list = u
                        elseif not Drops.update and type(u) == "function" then
                            Drops.update = u
                        end
                    end
                end
                if Drops.list then break end
            end
        end
    end
    -- 3) cadangan: cari lewat getgc (hanya kalau diminta: berat)
    if not Drops.list and deep and getgc then
        for _, v in ipairs(getgc(true)) do
            if type(v) == "table" then
                local e = rawget(v, 1)
                if type(e) == "table" and rawget(e, "uid") ~= nil and rawget(e, "frame") ~= nil
                    and rawget(e, "born") ~= nil then
                    Drops.list = v
                    break
                end
            end
        end
    end
    return Drops.list ~= nil
end

-- Cari fungsi game yang mengurangi / menghapus drop (dipakai World.dropTaken).
-- Ciri: upvalue World.dropTaken, dan fungsi itu sendiri memegang daftar drop yang sama.
function Drops.findUpdate()
    local w, list = Refs.World, Drops.list
    local wd = w and rawget(w, "dropTaken")
    if type(wd) ~= "function" or not list then return false end
    for _, u in pairs(getUpvalues(wd)) do
        if type(u) == "function" then
            for _, uu in pairs(getUpvalues(u)) do
                if rawequal(uu, list) then
                    Drops.update = u
                    return true
                end
            end
        end
    end
    return false
end

-- Terapkan hasil ambil drop ke tampilan, sama seperti game:
--   sisa > 0 -> angka drop dikurangi; sisa 0 -> keluar dari daftar + frame dihapus.
-- Tanpa ini, loop gambar game menampilkan drop lagi (flown di-reset saat badan tidak menyentuh).
function Drops.applyTaken(d, left)
    local list = Drops.list
    if not list or not table.find(list, d) then return end
    if not Drops.update then Drops.findUpdate() end
    if Drops.update then
        local ok = pcall(Drops.update, d, left)
        if ok then
            if left > 0 then
                d.flown = nil
                if typeof(d.frame) == "Instance" then pcall(function() d.frame.Visible = not d.culled end) end
            end
            return
        end
    end
    -- cadangan manual (fungsi game tidak ketemu)
    d.n = left
    if left > 0 then
        pcall(function()
            if d.setGem then d.setGem(left) elseif d.count then d.count:set(left > 1 and tostring(left) or "") end
        end)
        d.flown = nil
        if typeof(d.frame) == "Instance" then pcall(function() d.frame.Visible = not d.culled end) end
    else
        local i = table.find(list, d)
        if i then table.remove(list, i) end
        if typeof(d.frame) == "Instance" then pcall(function() d.frame:Destroy() end) end
    end
end

local function takeDrop(d)
    local worldTake = Refs.World and rawget(Refs.World, "takeDrop")
    if type(worldTake) ~= "function" and not TakeDropRemote then return false end
    if d.taking or d.pending or d.display or (d.n or 0) <= 0 then return false end
    -- drop yang kamu buang sendiri belum boleh dipungut lagi (aturan game), kecuali gems
    if d.armed == false and d.id ~= 112 then return false end
    local now = os.clock()
    if DropFailUntil[d.uid] and now < DropFailUntil[d.uid] then return false end

    local amount = d.n
    if d.id ~= 112 and Refs.Inv then -- 112 = gems, tidak makan slot
        local okr, room = pcall(function() return Refs.Inv:room(d.id) end)
        if okr and type(room) == "number" then amount = math.min(amount, room) end
    end
    if amount <= 0 then -- inventori penuh: coba lagi 1 detik lagi
        DropFailUntil[d.uid] = now + 1
        local last = Hook.LastFull[d.id]
        if not last or now - last > 120 then
            Hook.LastFull[d.id] = now
            Hook.send("full", "Inventori penuh: " .. itemName(d.id) .. " tidak bisa diambil lagi")
        end
        return false
    end

    d.taking = true -- cegah diambil dobel
    -- langsung hilang dari layar selama menunggu jawaban server.
    -- Tidak pakai d.flown: loop gambar game me-reset flown + memunculkan drop lagi
    -- tiap frame kalau badan tidak menyentuhnya (mode Remote = ambil dari jauh).
    if typeof(d.frame) == "Instance" then pcall(function() d.frame.Visible = false end) end
    local ok, taken
    if type(worldTake) == "function" then
        ok, taken = pcall(worldTake, d.uid, amount) -- cara game baru
    else
        ok, taken = pcall(TakeDropRemote.InvokeServer, TakeDropRemote, d.uid, amount)
    end
    d.taking = false

    if not (ok and type(taken) == "number" and taken > 0) then
        State.CollectFail += 1
        d.refused = os.clock() -- tanda ditolak, sama seperti game
        d.failN = (d.failN or 0) + 1
        DropFailUntil[d.uid] = os.clock() + math.min(8, d.failN) -- 1, 2, 3.. detik (yang terus ditolak makin jarang)
        d.flown = nil
        if typeof(d.frame) == "Instance" then pcall(function() d.frame.Visible = not d.culled end) end
        return false
    end
    DropFailUntil[d.uid] = nil

    if d.id == 112 then
        if Refs.Gems then pcall(Refs.Gems.addGems, taken) end
    elseif Refs.Inv then
        pcall(function() Refs.Inv:add(d.id, taken) end)
    end
    Drops.applyTaken(d, math.max(0, (d.n or 0) - taken)) -- kurangi / hapus drop seperti game
    State.Collected += taken
    Stats.Items[d.id] = (Stats.Items[d.id] or 0) + taken
    State.LastAction = "Collect " .. itemName(d.id) .. " x" .. taken
    return true
end

local function inTile(t, x, y)
    return x >= t.x - 0.15 and x < t.x + 1.15 and y >= t.y - 0.15 and y < t.y + 1.15
end

-- ---------- Collector cepat ----------
-- Cek daftar drop TIAP FRAME. Drop di area langsung diambil, semuanya sekaligus
-- (paralel), jadi tidak antri menunggu balasan server satu per satu.
--   Auto Farm  : drop di tile yang dipilih di Grid
--   Clear / Farmer : drop di sekitar karakter
local OffsetParse = {}
local nextDropScan = 0

local function canTry(d, now)
    if type(d) ~= "table" or d.taking or (d.n or 0) <= 0 or type(d.x) ~= "number" then return false end
    if d.armed == false and d.id ~= 112 then return false end
    local fail = DropFailUntil[d.uid]
    return not (fail and now < fail)
end

-- Drop TIDAK diambil lewat remote oleh script: drop terambil oleh game sendiri saat badan
-- menyentuhnya (fisika game, seperti main manual). Di sini cuma cari daftar drop & hitung
-- drop yang terambil di dekat badan (untuk status).
-- Mode Remote (cara lama): drop di tile grid / di sekitar karakter diambil lewat fungsi ambil-drop game
function Drops.remoteTick(list, s)
    local offs = farmOffsets()
    local farmArea = (State.AutoCollect or State.Override ~= nil) and next(offs) ~= nil
    local nearArea = (Clear.Running and Clear.Collect) or (Farmer.Running and Farmer.Collect)
        or Pabrik.Running or Build.Running or Splice.Roaming
    if not farmArea and not nearArea then return end
    local cx, cy = s.x, s.y - 0.475
    local ptx, pty = getPlayerTile()
    local now = os.clock()
    local R = (State.CollectRadius or 3) + 0.2
    local z = Pabrik.Zone -- tempat drop pabrik tidak ikut diambil lagi
    if z and z.world ~= (Refs.World and rawget(Refs.World, "name")) then z = nil end
    for i = #list, 1, -1 do
        local d = list[i]
        if canTry(d, now) and not (z and math.abs(d.x - z.x) <= 2.5 and math.abs(d.y - z.y) <= 2.5) then
            local hit = nearArea and math.abs(d.x - cx) <= R and math.abs(d.y - cy) <= R
            if not hit and farmArea and ptx then
                for key in pairs(offs) do
                    local o = OffsetParse[key]
                    if not o then
                        local dx, dy = string.match(key, "^(-?%d+),(-?%d+)$")
                        o = { tonumber(dx), tonumber(dy) }
                        OffsetParse[key] = o
                    end
                    if o[1] and inTile({ x = ptx + o[1], y = pty + o[2] }, d.x, d.y) then
                        hit = true
                        break
                    end
                end
            end
            if hit then task.spawn(takeDrop, d) end
        end
    end
end

local function collectTick()
    local busy = State.AutoCollect or State.Override ~= nil or (Clear.Running and Clear.Collect)
        or (Farmer.Running and Farmer.Collect) or Pabrik.Running or Build.Running or Splice.Roaming or Vend.Running
    if not busy then return end
    local tnow = os.clock()
    if tnow < (Drops.nextTick or 0) then return end -- 5-10x per detik cukup (hemat FPS)
    Drops.nextTick = tnow + ((State.CollectMode == "Remote") and 0.1 or 0.2)
    local list = Drops.list
    if not list then
        local now = os.clock()
        if now >= nextDropScan then -- cari daftar drop paling sering tiap 5 detik
            nextDropScan = now + 5
            findDropRefs()
        end
        return
    end
    local ok, s = false, nil
    if Refs.State then ok, s = pcall(Refs.State) end
    if not (ok and type(s) == "table" and type(s.x) == "number") then return end
    if State.CollectMode == "Remote" then
        Drops.remoteTick(list, s) -- jumlah terambil dihitung oleh takeDrop
        return
    end
    local cx, cy = s.x, s.y - 0.475
    local seen = {}
    for _, d in ipairs(list) do
        if type(d) == "table" and type(d.x) == "number" and math.abs(d.x - cx) <= 1.5 and math.abs(d.y - cy) <= 1.5 then
            seen[d] = d.n or 0
        end
    end
    for d, n in pairs(Drops.seen or {}) do
        if seen[d] == nil and not table.find(list, d) and d.id and n > 0 then -- hilang di dekat badan = terambil
            State.Collected += n
            Stats.Items[d.id] = (Stats.Items[d.id] or 0) + n
        end
    end
    Drops.seen = seen
end

table.insert(Connections, RunService.Heartbeat:Connect(function()
    if engineAlive() then collectTick() end
end))

-- Tunggu sebentar sampai drop di tile ini terambil (supaya tidak tertimpa block baru)
local function waitTileDrops(t, maxSec)
    local list = Drops.list
    if not list then return end
    local t0 = os.clock()
    while os.clock() - t0 < maxSec and alive() do
        local now, busy = os.clock(), false
        for _, d in ipairs(list) do
            if type(d) == "table" and type(d.x) == "number" and (d.n or 0) > 0 and inTile(t, d.x, d.y)
                and (d.taking or canTry(d, now)) then
                busy = true
                break
            end
        end
        if not busy then return end
        task.wait()
    end
end

-- Tunggu sampai drop yang menempel badan selesai dipungut game (sentuhan, bukan remote)
local function waitNearDrops(maxSec)
    local list = Drops.list
    if not list then return end
    task.wait(0.15) -- drop baru muncul sedikit terlambat
    local t0 = os.clock()
    while os.clock() - t0 < maxSec and alive() do
        local ok, s = false, nil
        if Refs.State then ok, s = pcall(Refs.State) end
        if not (ok and type(s) == "table" and type(s.x) == "number") then return end
        local cx, cy = s.x, s.y - 0.475
        local busy = false
        for _, d in ipairs(list) do
            -- sama dengan aturan game: < 0.6 tile mendatar & setinggi badan (kaki s.y, kepala s.y - 0.95)
            if type(d) == "table" and type(d.x) == "number" and (d.n or 0) > 0 and d.armed ~= false
                and math.abs(d.x - s.x) < 0.6 and d.y + 0.3 > s.y - 0.95 and d.y - 0.3 < s.y then
                local room = true
                if d.id ~= 112 and Refs.Inv then -- inventori penuh: tidak akan terpungut
                    local okr, r = pcall(function() return Refs.Inv:room(d.id) end)
                    if okr and type(r) == "number" and r <= 0 then room = false end
                end
                if room then
                    busy = true
                    break
                end
            end
        end
        if not busy then return end
        task.wait()
    end
end

---------------------------------------------------------------------
-- STATUS
---------------------------------------------------------------------
local function offsetsText()
    local list = {}
    for _, o in ipairs(sortedOffsets()) do
        table.insert(list, "(" .. o.dx .. "," .. o.dy .. ")")
    end
    return #list > 0 and table.concat(list, " ") or "-"
end

local lastStatusText = nil

local function updateStatus()
    if not UI.Status then return end
    local px, py = getPlayerTile()
    local sel = State.SelectedId
    local txt = "Status   : " .. (State.Running and "JALAN" or "BERHENTI")
        .. "\nBlock    : " .. (sel and (itemName(sel) .. " x" .. invCount(sel)) or "-")
        .. "\nKarakter : " .. (px and ("(" .. px .. "," .. py .. ")") or "tidak di world")
        .. "\nTile     : " .. offsetsText()
        .. "\nPlace/Break/Collect : " .. State.Placed .. " / " .. State.Broken .. " / " .. State.Collected
        .. (State.CollectFail > 0 and (" (ditolak " .. State.CollectFail .. ")") or "")
        .. (State.Dropped > 0 and ("\nDrop seed: di-drop " .. State.Dropped) or "")
        .. "\nAksi     : " .. State.LastAction
    if txt == lastStatusText then return end
    lastStatusText = txt
    task.defer(function()
        pcall(function() UI.Status:SetDesc(txt) end)
    end)
end

---------------------------------------------------------------------
-- KONTROL GERAK GAME
---------------------------------------------------------------------
-- Tombol gerak game dibaca dari WorldMenu.isDown. Dibungkus supaya gerak otomatis
-- bisa "menekan" tombol sendiri (AutoInput). (Fly / ghost milik script lama tidak dibawa.)
local OrigIsDown = nil
local function isDownWrapper(saved, key, ...)
    if AutoInput.active then
        if key == "keyLeft" then return AutoInput.left end
        if key == "keyRight" then return AutoInput.right end
        if key == "keyJump" then return AutoInput.jump end
        if key == "keyDown" then return AutoInput.down end
    end
    return OrigIsDown(saved, key, ...)
end

if MenuModOk and type(MenuModule) == "table" and type(rawget(MenuModule, "isDown")) == "function" then
    OrigIsDown = rawget(MenuModule, "isDown")
    MenuModule.isDown = isDownWrapper
end

---------------------------------------------------------------------
-- FARM LOOP: place semua dulu, baru break satu per satu
---------------------------------------------------------------------
local stopFarm

local function waitMs(ms)
    task.wait(math.max(ms or 0, 10) / 1000)
    return State.Running and alive()
end

local function validate()
    local doPlace = farmMode() ~= "Break saja"
    if not Refs.World then return "Data world belum ketemu. Tekan 'Hubungkan ke game'" end
    if next(farmOffsets()) == nil then return "Pilih tile dulu di Grid Tile" end
    if not getPlayerTile() then return "Kamu belum masuk world" end
    if doPlace and not farmBlock() then return "Pilih block dari inventori" end
    return nil
end

-- Rayman's Fist sedang dipakai? (fungsi asli game)
local function raymanOn()
    local w = Refs.World
    local f = w and rawget(w, "raymanOn")
    if type(f) ~= "function" then return false end
    local ok, on = pcall(f)
    return ok and on == true
end

-- Cari 2-3 tile target yang segaris dari karakter (8 arah, jarak 1-3),
-- sama seperti pukulan Rayman di game.
local RAY_DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local function raymanLine(px, py, active)
    local byKey = {}
    for _, a in ipairs(active) do byKey[a.x .. "," .. a.y] = a end
    local best, bestDir = nil, nil
    for _, d in ipairs(RAY_DIRS) do
        local line = {}
        for i = 1, 3 do
            local a = byKey[(px + d[1] * i) .. "," .. (py + d[2] * i)]
            if a then line[#line + 1] = a end
        end
        if #line >= 2 and #line > (best and #best or 0) then best, bestDir = line, d end
    end
    return best, bestDir
end

-- Kabarkan gerakan Rayman ke server (paket yang sama dengan game saat pukulan Rayman)
local function raymanAct(dir)
    local ok, s = pcall(Refs.State)
    if not ok or type(s) ~= "table" or not s.x then return end
    if NetOk and type(Net) == "table" and Net.act then
        pcall(Net.act.send, { kind = 4, x = s.x + dir[1], y = s.y - 0.475 + dir[2] })
    end
end

local function farmLoop(runId)
    local lastStatus = 0
    while State.Running and alive() and State.RunId == runId do
        if State.DropPause then -- sedang pergi drop seed
            task.wait(0.2)
            continue
        end
        local doPlace = farmMode() ~= "Break saja"
        local doBreak = farmMode() ~= "Place saja"

        local px, py = getPlayerTile()
        if not px then
            stopFarm("Karakter tidak ditemukan (keluar world?)")
            return
        end

        local tiles = {}
        for _, o in ipairs(sortedOffsets()) do
            tiles[#tiles + 1] = { x = px + o.dx, y = py + o.dy }
        end

        local acted, outOfBlock = false, false

        -- 0) Ambil drop di semua tile grid dengan sentuhan badan (sekali sapu), lalu balik ke posisi
        if (State.AutoCollect or State.Override) and not State.DropPause then
            Drops.waitSpawn(tiles) -- drop pecahan barusan datang dari server: tunggu muncul dulu
            if State.CollectMode == "Remote" then
                for _, t in ipairs(tiles) do waitTileDrops(t, 0.4) end -- diambil lewat remote (collectTick)
            elseif Drops.touchAll then
                Drops.touchAll(tiles, px, py)
            end
        end

        -- 1) Place semua tile kosong
        if doPlace then
            for _, t in ipairs(tiles) do
                if not State.Running or State.DropPause then break end
                local r = tryPlace(t.x, t.y)
                if r == "habis" then
                    outOfBlock = true
                    break
                elseif r == "place" then
                    acted = true
                    if not waitMs(State.PlaceMs) then break end
                end
            end
        end

        -- 2) Pukul tile sampai habis (block depan lalu background).
        --    Server hanya terima 1 pukulan tiap ~0.22 detik (tangan biasa), jadi multi target
        --    = beberapa tile dipukul BERGANTIAN (sama seperti 2 jari). Semua tile benar-benar pecah.
        --    Pakai Rayman's Fist: 2-3 tile segaris dipukul sekali jalan (seperti Rayman asli).
        if doBreak then
            local K = math.clamp(math.floor(State.MultiTarget or 1), 1, 5)
            local nextI, active = 1, {}
            while State.Running and alive() and not State.DropPause do
                while #active < K and nextI <= #tiles do
                    local t = tiles[nextI]
                    nextI += 1
                    active[#active + 1] = { x = t.x, y = t.y, n = 0 }
                end
                if #active == 0 then break end

                -- pilih tile yang dipukul sekarang
                local hits, rayDir = nil, nil
                if K > 1 and raymanOn() then
                    hits, rayDir = raymanLine(px, py, active)
                end
                if not rayDir then hits = { active[1] } end -- giliran depan antrian

                local t0 = os.clock()
                if rayDir then raymanAct(rayDir) end
                local hit, broke = false, false
                for i, a in ipairs(hits) do
                    if not State.Running then break end
                    if i > 1 then task.wait(0.05) end -- jarak antar tile seperti animasi Rayman
                    local r = tryBreak(a.x, a.y)
                    a.n += 1
                    if r then hit, acted = true, true end
                    if r == "broke" then broke = true end
                    -- selesai kalau kosong / tidak bisa dipecah / sudah habis sampai background
                    if r == nil or a.n > 80 or (r == "broke" and not breakableAt(a.x, a.y)) then
                        a.done = true
                    end
                    a.used = true
                end

                -- tile yang barusan dipukul pindah ke belakang antrian (bergantian)
                local nextActive = {}
                for _, a in ipairs(active) do
                    if not a.done and not a.used then nextActive[#nextActive + 1] = a end
                end
                for _, a in ipairs(hits) do
                    a.used = nil
                    if not a.done then nextActive[#nextActive + 1] = a end
                end
                active = nextActive

                if hit then
                    local gap = State.BreakMs / 1000
                    if rayDir then gap = math.max(gap, 0.35) end -- jeda Rayman asli
                    local rest = gap - (os.clock() - t0)
                    if rest > 0.005 then task.wait(rest) end
                    if not (State.Running and alive()) then break end
                end
                -- drop diambil otomatis oleh collector cepat
                if broke and State.AfterBreakMs > 0 then task.wait(State.AfterBreakMs / 1000) end
            end
        end

        if not State.Running or not alive() then break end
        if State.DropPause then continue end

        if not acted then
            local sel = farmBlock()
            if outOfBlock or (doPlace and sel and invCount(sel) <= 0) then
                stopFarm("Block " .. itemName(sel) .. " di inventori habis")
                return
            end
            if not waitMs(State.BreakMs) then break end
        end

        State.Cycles += 1
        if os.clock() - lastStatus > 1 then
            lastStatus = os.clock()
            updateStatus()
        end
    end
    updateStatus()
end

local function setRunningVisual()
    if State.Override then return end -- dijalankan Pabrik: tombol Auto Farm tidak diubah
    if UI.FarmToggle then pcall(function() UI.FarmToggle:Set(State.Running) end) end
    if UI.GridStart and UI.GridMode == "farm" then
        UI.GridStart.Text = State.Running and "STOP" or "START"
        UI.GridStart.BackgroundColor3 = State.Running and Color3.fromRGB(200, 60, 60) or Color3.fromRGB(46, 160, 90)
    end
end

stopFarm = function(reason)
    State.Running = false
    setRunningVisual()
    if reason and not State.Quiet then
        notify("Auto Farm berhenti", reason, 4)
        Hook.send("stop", "Auto Farm berhenti: " .. reason)
    end
    updateStatus()
end

-- Auto Farm, Clear & Farmer tidak boleh jalan bersamaan
local stopClear, stopFarmer

local function startFarm()
    if State.Running then return end
    local err = validate()
    if err then
        stopFarm(err)
        return
    end
    if Splice.Running and Splice.stop then Splice.stop("Dihentikan karena Auto Farm dimulai") end
    if Pabrik.Running and Pabrik.stop then Pabrik.stop("Dihentikan karena Auto Farm dimulai") end
    if Build.Running and Build.stop then Build.stop("Dihentikan karena Auto Farm dimulai") end
    if Clear.Running and stopClear then stopClear("Dihentikan karena Auto Farm dimulai") end
    if Farmer.Running and stopFarmer then stopFarmer("Dihentikan karena Auto Farm dimulai") end
    table.clear(HitCount)
    table.clear(PlacedAt)
    State.DropPause = false
    State.Running = true
    State.RunId = (State.RunId or 0) + 1
    setRunningVisual()
    updateStatus()
    task.spawn(farmLoop, State.RunId)
end

-- Fungsi gerak dikumpulkan di tabel Auto (Luau batasi 200 variabel per fungsi)
local Auto = {}
do (function() -- fungsi sendiri: variabel di dalam tidak ikut batas 200 local
---------------------------------------------------------------------
-- GERAK OTOMATIS
---------------------------------------------------------------------
-- Cara kerja:
--   - Jalan dicari pakai A* sesuai fisika game (jalan, jatuh, lompat naik 1-3 tile).
--   - Karakter digerakkan dengan "menekan" tombol, sama seperti main biasa.
--   - Tidak pakai fly / noclip karena server me-rollback.
--   - Kalau tidak ada pijakan, taruh block dari inventori (jembatan / tangga).
local floor, abs = math.floor, math.abs

local Move = { Placed = 0 }  -- jumlah block pijakan yang dipasang
local BadEdge = {}           -- jalur yang barusan gagal (dihindari dulu)
local ClearFail, FarmerFail = {}, {}
local BreakTimes = {}        -- tile yang terus balik lagi setelah pecah
local Reach = nil            -- daftar tile yang bisa dijangkau (cache)

local function autoOn()
    return (Clear.Running or Farmer.Running or Splice.Roaming or Pabrik.Running or Build.Running or Move.Homing
        or Vend.Running) and alive()
end

local function setMoveStatus(text)
    if Clear.Running then
        Clear.Status = text
    elseif Farmer.Running then
        Farmer.Status = text
    elseif Splice.Roaming then
        Splice.Status = text
    elseif Build.Running then
        Build.Status = text
    elseif Pabrik.Running then
        Pabrik.Status = text
    elseif Vend.Running then
        Vend.Status = text
    end
end

local function skipTile(tbl, idx, sec)
    tbl[idx] = os.clock() + (sec or 30)
end

local function skipped(tbl, idx, now)
    local t = tbl[idx]
    if not t then return false end
    if (now or os.clock()) >= t then
        tbl[idx] = nil
        return false
    end
    return true
end

local function skippedCount(tbl)
    local n, now = 0, os.clock()
    for _, t in pairs(tbl) do
        if t > now then n += 1 end
    end
    return n
end

local function hudRange(name, def)
    local f = Refs.Hud and Refs.Hud[name]
    if type(f) == "function" then
        local ok, r = pcall(f)
        if ok and type(r) == "number" and r > 0 then return r end
    end
    return def
end

local function punchReach() return hudRange("punchRange", 2.5) end
local function buildReach() return hudRange("buildRange", 2.5) end

local function fgIdAt(x, y)
    local w = Refs.World
    local row = w and w.fg[y]
    return (row and row[x]) or 0
end

local function fgItemAt(x, y)
    local id = fgIdAt(x, y)
    if id ~= 0 then return ItemDB[id] end
    return nil
end

-- Tile padat? (sama dengan cek tabrakan game)
local function solidAt(x, y)
    local w = Refs.World
    if not w then return true end
    if x < 0 or x >= w.w or y >= w.h then return true end
    if y < 0 then return false end
    local it = fgItemAt(x, y)
    if not it then return false end
    if it.combiner then
        local ok, shut = pcall(w.combinerShut, x, y)
        return (not ok) or (shut and true or false)
    end
    if it.vip then -- pintu VIP: padat kalau kamu tidak punya akses
        local ok, may = pcall(w.vipMay, x, y)
        return not (ok and may)
    end
    if it.entrance then
        local sw = w.switches and w.switches[y * w.w + x]
        if it.gate then
            return not (sw and sw.off == true)
        end
        if sw and sw.public then return false end
        local ok, may = pcall(function() return w.areas.mayBuild(w.lock, x, y) end)
        return not (ok and may)
    end
    return it.solid and true or false
end

-- Tile berbahaya (lava, duri, laser)
local function hazardAt(x, y)
    local it = fgItemAt(x, y)
    return it ~= nil and (it.deadly or it.hurts or it.laser) and true or false
end

local function platformAt(x, y)
    local it = fgItemAt(x, y)
    return it ~= nil and it.platform and true or false
end

local function openAt(x, y)
    return not solidAt(x, y) and not hazardAt(x, y)
end

-- Ada pijakan aman di bawah tile ini?
local function realSupport(x, y)
    return not hazardAt(x, y + 1) and (solidAt(x, y + 1) or platformAt(x, y + 1))
end

-- Target kelihatan dari badan? (tidak terhalang lantai / atap padat di antaranya)
-- Panen lewat block bisa, tapi drop-nya jatuh di balik block dan tidak terambil.
function Move.los(nx, ny, tx, ty)
    if ty - ny >= 2 then
        for y = ny + 1, ty - 1 do
            if solidAt(tx, y) then return false end
        end
    elseif ny - ty >= 2 then
        for y = ty + 1, ny - 1 do
            if solidAt(tx, y) then return false end
        end
    end
    return true
end

-- Tile masuk jangkauan? (bentuk kotak di sekitar badan)
local function stateReaches(s, tx, ty, R)
    return abs(tx + 0.5 - s.x) <= R and abs(ty + 0.5 - (s.y - 0.475)) <= R
end

-- Boleh pecah di sini? (cek lock)
local function canWorkAt(x, y)
    local w = Refs.World
    local ok, res = pcall(function()
        if w.areas and type(w.areas.mayBuild) == "function" and not w.areas.mayBuild(w.lock, x, y) then
            return false
        end
        if type(w.builderOk) == "function" and not w.builderOk(x, y, false) then
            return false
        end
        return true
    end)
    return (not ok) or res
end

-- ---------- Block pijakan ----------
local function scaffoldId()
    local id, use
    if Clear.Running then
        id, use = Clear.ScaffoldId, Clear.UseBlock
    elseif Farmer.Running then
        id, use = Farmer.ScaffoldId, Farmer.UseBlock
    end -- Bangun Lahan tidak pakai pijakan (jalan di atas baris yang sedang dibangun)
    if use and id and invCount(id) > 0 then return id end
    return nil
end

-- Boleh taruh block di sini? (kosong + izin bangun)
local function placeOk(x, y)
    local w = Refs.World
    if not w or x < 0 or y < 0 or x >= w.w or y >= w.h then return false end
    if fgIdAt(x, y) ~= 0 then return false end
    local ok, res = pcall(function()
        if w.areas and type(w.areas.canEdit) == "function" and not w.areas.canEdit(x, y) then return false end
        if type(w.builderOk) == "function" and not w.builderOk(x, y, true) then return false end
        return true
    end)
    return (not ok) or res
end

local function placeScaffold(x, y)
    local id = scaffoldId()
    if not id or not placeOk(x, y) then return false end
    local s = playerState()
    if not s or not stateReaches(s, x, y, buildReach() - 0.05) then return false end
    sendSetTile("fg", x, y, id) -- place lewat fungsi game
    if Refs.Inv then pcall(function() Refs.Inv:remove(id, 1) end) end
    Move.Placed += 1
    return true
end

local function worldVersion()
    -- berubah tiap ada block / pohon yang berubah, supaya cache jangkauan tidak basi
    return Clear.Broken + Farmer.Harvested + Farmer.Planted + Move.Placed + Splice.Planted
        + Pabrik.Harvested + Pabrik.Planted + Build.Placed + Build.Harvested + Build.Planted + Build.Dug
        + State.Placed + State.Broken
end

local function startNode(s)
    local ny = floor(s.y - 0.475)
    local nx = floor(s.x)
    if realSupport(nx, ny) then return nx, ny end
    local a, b = floor(s.x - 0.3), floor(s.x + 0.3 - 0.0001)
    for _, c in ipairs({ a, b }) do
        if c ~= nx and realSupport(c, ny) then return c, ny end
    end
    return nx, ny
end

-- ---------- Antrian prioritas untuk A* ----------
local function heapPush(hf, hi, n, f, i)
    n += 1
    local k = n
    while k > 1 do
        local p = k // 2
        if hf[p] <= f then break end
        hf[k], hi[k] = hf[p], hi[p]
        k = p
    end
    hf[k], hi[k] = f, i
    return n
end

local function heapPop(hf, hi, n)
    local top = hi[1]
    local lf, li = hf[n], hi[n]
    hf[n], hi[n] = nil, nil
    n -= 1
    if n > 0 then
        local k = 1
        while true do
            local c = k * 2
            if c > n then break end
            if c < n and hf[c + 1] < hf[c] then c += 1 end
            if lf <= hf[c] then break end
            hf[k], hi[k] = hf[c], hi[c]
            k = c
        end
        hf[k], hi[k] = lf, li
    end
    return top, n
end

-- ---------- A* ----------
-- Cari jalan termurah ke tempat yang bisa memukul salah satu target.
-- Langkah yang bisa dipakai:
--   walk   : geser 1 tile (+ taruh block kalau perlu)
--   fall   : jalan ke pinggir lalu jatuh
--   jump   : lompat naik 1-3 tile
--   gap    : lompati lubang 1-2 tile
--   stair  : tangga lahan: lompat naik 2 lewat lubang ke lorong setinggi 1 tile
--   pillar : lompat lalu taruh block di bawah kaki (naik 1)
local MAX_EXPAND = 8000
local BLOCK_COST = 2

local function reachOffsets(R)
    return floor(R), math.ceil(-R + 0.025), floor(R + 0.025)
end

local function astar(sx, sy, goals, gx, gy, R, useBlock)
    local w = Refs.World
    if not w then return nil, false, {} end
    local W, H = w.w, w.h
    local WH = W * H
    local dxm, dyLo, dyHi = reachOffsets(R)
    local oC, sC, bC = {}, {}, {}

    local function open(x, y)
        if x < 0 or x >= W or y >= H then return false end
        if y < 0 then return true end
        local i = y * W + x
        local v = oC[i]
        if v == nil then
            v = openAt(x, y)
            oC[i] = v
        end
        return v
    end

    local function sup(x, y)
        if x < 0 or x >= W or y < 0 or y >= H then return false end
        local i = y * W + x
        local v = sC[i]
        if v == nil then
            v = realSupport(x, y)
            sC[i] = v
        end
        return v
    end

    local function buildable(x, y)
        if not useBlock or x < 0 or x >= W or y < 0 or y >= H then return false end
        local i = y * W + x
        local v = bC[i]
        if v == nil then
            v = placeOk(x, y)
            bC[i] = v
        end
        return v
    end

    local function h(x, y)
        local dx = abs(gx - x) - R
        local dyRaw = gy - y
        local dy = abs(dyRaw) - R
        local vw = (dyRaw < 0) and 1.5 or 0.5
        return (dx > 0 and dx or 0) + vw * (dy > 0 and dy or 0)
    end

    local function isGoal(nx, ny)
        -- goals.maxY: tempat berdiri tidak boleh lebih bawah dari ini (Bangun Lahan)
        if goals.maxY and ny > goals.maxY then return false end
        for ty = ny + dyLo, ny + dyHi do
            if ty >= 0 and ty < H then
                local base = ty * W
                for tx = nx - dxm, nx + dxm do
                    -- jangan berdiri tepat di atas target (noSelf: juga jangan di dalam tile target)
                    if tx >= 0 and tx < W and goals[base + tx] and not (tx == nx and ty == ny + 1)
                        and not (goals.noSelf and tx == nx and ty == ny)
                        and not (goals.los and ty - ny >= 2 and not open(tx, ny + 1))
                        and not (goals.los and ny - ty >= 2 and not open(tx, ny - 1)) then
                        return true
                    end
                end
            end
        end
        return false
    end

    local ex, ey, ek, ec, eb = {}, {}, {}, {}, {}
    local n = 0
    local function add(x, y, kind, cost, build)
        n += 1
        ex[n], ey[n], ek[n], ec[n], eb[n] = x, y, kind, cost, build
    end

    local function expand(x, y)
        n = 0
        for s = -1, 1, 2 do
            local ax = x + s
            if open(ax, y) then
                if sup(ax, y) then
                    add(ax, y, "walk", 1, false)
                else
                    if buildable(ax, y + 1) then
                        add(ax, y, "walk", 1 + BLOCK_COST, true)
                    end
                    -- jatuh sampai ketemu pijakan
                    local fy = y + 1
                    while fy < H and fy - y <= 40 and open(ax, fy) and not sup(ax, fy) do
                        fy += 1
                    end
                    if fy < H and open(ax, fy) and sup(ax, fy) then
                        add(ax, fy, "fall", 1 + 0.5 * (fy - y), false)
                    end
                    -- lompati lubang 1-2 tile
                    if open(x, y - 1) and open(x, y - 2) then
                        for dist = 2, 3 do
                            local mx = x + (dist - 1) * s
                            if not (open(mx, y) and open(mx, y - 1) and open(mx, y - 2)) then break end
                            if dist == 3 and sup(mx, y) then break end
                            local bx = x + dist * s
                            if open(bx, y - 1) and open(bx, y - 2) then
                                for k = 0, 2 do
                                    if not open(bx, y + k) then break end
                                    if sup(bx, y + k) then
                                        add(bx, y + k, "gap", dist + 0.5 + 0.5 * k, false)
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
            -- lompat naik (atas kepala harus kosong)
            for dy = 1, 3 do
                if not open(x, y - dy) then break end
                if open(x, y - dy - 1) and open(ax, y - dy) and sup(ax, y - dy) and open(ax, y - dy - 1) then
                    add(ax, y - dy, "jump", 1 + 1.5 * dy, false)
                end
            end
            -- tangga lahan: naik 1-2 tile ke lorong setinggi 1 tile (atapnya pas di atas kepala,
            -- jadi lompat biasa tidak muat). Rapat ke dinding, lompat, geser masuk di puncak.
            for dy = 1, 2 do
                if open(x, y - 1) and (dy == 1 or open(x, y - 2)) and open(ax, y - dy) and sup(ax, y - dy)
                    and not (open(x, y - dy - 1) and open(ax, y - dy - 1)) then
                    add(ax, y - dy, "stair", 3 + 1.5 * dy, false)
                end
            end
        end
        -- naik 1 pakai block
        if useBlock and open(x, y - 1) and open(x, y - 2) and open(x, y - 3) and buildable(x, y) then
            add(x, y - 1, "pillar", 2 + BLOCK_COST, true)
        end
        return n
    end

    local startI = sy * W + sx
    local g, came, kind, buildOf, closed = { [startI] = 0 }, {}, {}, {}, {}
    local hf, hi, hn = {}, {}, 0
    hn = heapPush(hf, hi, hn, h(sx, sy), startI)
    local expanded = 0
    local now = os.clock()

    while hn > 0 do
        local cur
        cur, hn = heapPop(hf, hi, hn)
        if not closed[cur] then
            closed[cur] = true
            local cx, cy = cur % W, cur // W
            if isGoal(cx, cy) then
                local path = {}
                local i = cur
                while i ~= startI do
                    local p = came[i]
                    table.insert(path, 1, {
                        fx = p % W, fy = p // W, x = i % W, y = i // W,
                        kind = kind[i], build = buildOf[i], key = p * WH + i,
                    })
                    i = p
                end
                return path, false, closed
            end
            expanded += 1
            if expanded > MAX_EXPAND then return nil, false, closed end
            if expanded % 400 == 0 then
                task.wait()
                if not autoOn() then return nil, false, closed end
            end
            local gc = g[cur]
            local cnt = expand(cx, cy)
            for k = 1, cnt do
                local ni = ey[k] * W + ex[k]
                if not closed[ni] then
                    local bad = BadEdge[cur * WH + ni]
                    if not (bad and bad > now) then
                        local ng = gc + ec[k]
                        local old = g[ni]
                        if old == nil or ng < old then
                            g[ni], came[ni], kind[ni], buildOf[ni] = ng, cur, ek[k], eb[k]
                            hn = heapPush(hf, hi, hn, ng + h(ex[k], ey[k]), ni)
                        end
                    end
                end
            end
        end
    end
    return nil, true, closed -- tidak ada jalan sama sekali
end

-- Semua tile yang bisa dijangkau dari area ini
local function reachableTileSet(closed, W, R)
    local set = {}
    local dxm, dyLo, dyHi = reachOffsets(R)
    local n = 0
    for i in pairs(closed) do
        local x, y = i % W, i // W
        for dy = dyLo, dyHi do
            local ty = y + dy
            if ty >= 0 then
                local base = ty * W
                for dx = -dxm, dxm do
                    local tx = x + dx
                    if tx >= 0 and tx < W then set[base + tx] = true end
                end
            end
        end
        n += 1
        if n % 500 == 0 then task.wait() end
    end
    return set
end

-- Simpan daftar tile terjangkau, supaya tile di seberang jurang langsung dilewati
-- (tidak cari jalan berulang yang bikin karakter diam).
local function reachFilter(startI, R, useBlock)
    local c = Reach
    if c and c.world == Refs.World and c.start == startI and c.R == R and c.block == useBlock
        and c.ver == worldVersion() and os.clock() - c.at < 30 then
        return c.set
    end
    return nil
end

local function storeReach(startI, R, useBlock, closed)
    Reach = {
        world = Refs.World, start = startI, R = R, block = useBlock, ver = worldVersion(), at = os.clock(),
        set = reachableTileSet(closed, Refs.World.w, R),
    }
end

-- ---------- Gerakkan karakter ----------
local function releaseInput()
    AutoInput.left, AutoInput.right, AutoInput.jump, AutoInput.down = false, false, false, false
end

local function frame()
    task.wait()
    return autoOn()
end

local function waitAuto(ms)
    task.wait(math.max(ms or 0, 30) / 1000)
    return autoOn()
end

-- ===== ANIMASI AKSI (hanya tampilan di layar sendiri, tidak mengirim apa pun ke server) =====
-- Tangan karakter mengarah ke tile (sama seperti saat pemain memukul / memasang sendiri).
function Anim.swing(x, y, kind)
    if not (Anim.fn and Anim.idx and Anim.set) then return end
    local s = playerState()
    local facing = (s and x + 0.5 < s.x) and -1 or 1
    pcall(Anim.set, Anim.fn, Anim.idx, { t = os.clock(), x = x + 0.5, y = y + 0.5, facing = facing, kind = kind })
end

-- Efek asap kecil saat block dipasang (pakai efek "place" game)
function Anim.puff(x, y)
    local list = Refs.Particles
    if not list or #list == 0 then return end
    local pick = Anim.Particles
    if not pick then
        local worldGui = PlayerGui:FindFirstChild("GameGui")
        worldGui = worldGui and worldGui:FindFirstChild("World")
        for _, p in ipairs(list) do
            local ok, inWorld = pcall(function()
                return worldGui ~= nil and typeof(p.parent) == "Instance" and p.parent:IsDescendantOf(worldGui)
            end)
            if ok and inWorld then
                pick = p
                break
            end
        end
        pick = pick or list[1]
        Anim.Particles = pick
    end
    pcall(function() pick:place(x + 0.5, y + 0.5) end)
end

function Anim.place(x, y, id)
    local it = ItemDB[id]
    local seed = it and it.kind == "seed"
    Anim.swing(x, y, "build")
    if not seed then Anim.puff(x, y) end
end

-- Jalan ke targetX, lepas tombol saat sudah cukup dekat untuk berhenti
local function steerX(s, targetX, tol)
    local dx = targetX - s.x
    local vx = s.vx or 0
    local decel = s.grounded and 48 or 17
    local dir = 0
    if abs(dx) > tol then
        dir = dx > 0 and 1 or -1
        if vx * dir > 0 and (vx * vx) / (2 * decel) >= abs(dx) - tol * 0.5 then
            dir = 0
        end
    end
    AutoInput.left = dir < 0
    AutoInput.right = dir > 0
end

-- Jalan sampai berdiri di tengah tile tujuan
local function execWalk(tx, ty)
    local cx = tx + 0.5
    local s0 = playerState()
    if not s0 then return false end
    local limit = 1.5 + abs(cx - s0.x) * 0.35
    local t0 = os.clock()
    while frame() do
        local s = playerState()
        if not s or s.dead then return false end
        local nx, ny = floor(s.x), floor(s.y - 0.475)
        if s.grounded and ny ~= ty then return false end
        steerX(s, cx, 0.1)
        if nx == tx and abs(s.x - cx) <= 0.2 and s.grounded and abs(s.vx or 0) < 2 then
            AutoInput.left, AutoInput.right = false, false
            return true
        end
        if os.clock() - t0 > limit then return false end
    end
    return false
end

-- Jalan ke pinggir lalu jatuh ke tile tujuan
local function execFall(e)
    local cx = e.x + 0.5
    local limit = 1.5 + 0.3 * (e.y - e.fy)
    local t0 = os.clock()
    while frame() do
        local s = playerState()
        if not s or s.dead then return false end
        steerX(s, cx, 0.1)
        if s.grounded then
            local nx, ny = floor(s.x), floor(s.y - 0.475)
            if ny == e.y then
                if nx == e.x and abs(s.x - cx) <= 0.25 then return true end
            elseif ny ~= e.fy then
                return false
            end
        end
        if os.clock() - t0 > limit then return false end
    end
    return false
end

-- Lompat naik ke tile sebelah
local function execJump(e)
    if not execWalk(e.fx, e.fy) then return false end
    local dy = e.fy - e.y
    local top = e.y + 1                               -- tinggi kaki di tujuan
    local releaseY = top - ((dy == 1) and 0 or 0.4)   -- lepas lompat di sini (kepala tidak kebentur)
    local cx = e.x + 0.5
    releaseInput()
    if not frame() then return false end              -- lepas 1 frame supaya lompat terbaca
    AutoInput.jump = true
    local t0 = os.clock()
    local airborne = false
    while frame() do
        local s = playerState()
        if not s or s.dead then return false end
        if not s.grounded then airborne = true end
        if AutoInput.jump and (s.y <= releaseY or (airborne and (s.vy or 0) >= 0)) then
            AutoInput.jump = false
        end
        if s.y <= top + 0.25 then
            steerX(s, cx, 0.1)
        else
            steerX(s, e.fx + 0.5, 0.15)
        end
        if airborne and s.grounded then
            local nx, ny = floor(s.x), floor(s.y - 0.475)
            if ny == e.y then
                if nx == e.x and abs(s.x - cx) <= 0.25 then
                    AutoInput.jump = false
                    return true
                end
            else
                return false
            end
        end
        if not airborne and os.clock() - t0 > 0.35 then return false end
        if os.clock() - t0 > 1.8 then return false end
    end
    return false
end

-- Lompati lubang: ancang-ancang, lompat di ujung, rem di udara
local function execGap(e)
    if not execWalk(e.fx, e.fy) then return false end
    local s0 = playerState()
    if not s0 then return false end
    local dir = (e.x > e.fx) and 1 or -1
    local takeoff = e.fx + 0.5 + dir * 0.6
    local startY = s0.y
    local cx = e.x + 0.5
    releaseInput()
    local t0 = os.clock()
    local jumped, airborne, jumpAt = false, false, 0
    while frame() do
        local s = playerState()
        if not s or s.dead then return false end
        if not jumped then
            AutoInput.left, AutoInput.right = dir < 0, dir > 0
            if (s.x - takeoff) * dir >= 0 or not s.grounded then
                jumped, jumpAt = true, os.clock()
                AutoInput.jump = s.grounded
            end
        else
            if not s.grounded then airborne = true end
            if AutoInput.jump and (s.y <= startY - 1 or (airborne and (s.vy or 0) >= 0)) then
                AutoInput.jump = false
            end
            steerX(s, cx, 0.1)
            if airborne and s.grounded then
                local nx, ny = floor(s.x), floor(s.y - 0.475)
                if ny == e.y then
                    if nx == e.x and abs(s.x - cx) <= 0.25 then return true end
                else
                    return false
                end
            end
            if not airborne and os.clock() - jumpAt > 0.35 then return false end
        end
        if os.clock() - t0 > 2.2 then return false end
    end
    return false
end

-- Tangga lahan: naik 1-2 tile ke lorong setinggi 1 tile (lewat lubang tangga / keluar dari lubang).
-- Cara main manual: berdiri rapat ke sisi tujuan, lompat, tekan arah tujuan SETELAH badan naik
-- (kalau ditekan terlalu cepat badan masuk ke bawah block tujuan -> kepala kebentur -> jatuh),
-- saat kepala menempel atap lorong kaki sudah di atas block tujuan -> geser masuk. 3 cara dicoba.
function Move.execStair(e)
    if not execWalk(e.fx, e.fy) then return false end
    local dir = (e.x > e.fx) and 1 or -1
    local top = e.y + 1 -- tinggi kaki di tujuan (atas block pijakan)
    local hug = e.fx + 0.5 + dir * 0.17
    for try = 1, 3 do
        -- rapat ke dinding sisi tujuan
        local t0 = os.clock()
        while frame() do
            local s = playerState()
            if not s or s.dead then return false end
            steerX(s, hug, 0.03)
            if abs(s.x - hug) <= 0.06 and abs(s.vx or 0) < 1 then break end
            if os.clock() - t0 > 0.8 then break end
        end
        releaseInput()
        if not frame() then return false end
        local s0 = playerState()
        if not s0 then return false end
        local y0 = s0.y
        AutoInput.jump = true
        t0 = os.clock()
        local airborne, landed = false, nil
        while frame() do
            local s = playerState()
            if not s or s.dead then return false end
            if not s.grounded then airborne = true end
            if AutoInput.jump and (s.y <= top - 0.1 or (airborne and (s.vy or 0) >= 0)) then
                AutoInput.jump = false -- sudah setinggi tujuan / kena atap
            end
            -- Saat lompat di bawah atap lorong, kepala menempel di atap +-0.18 dtk dan kaki sudah di atas block
            -- tujuan: tekan arah di saat itu -> badan langsung masuk lorong (tidak perlu diangkat game).
            -- Tombol arah JANGAN ditekan di lantai: badan masuk ke bawah block tujuan -> kepala kebentur -> jatuh.
            -- coba 1: saat kaki sudah setinggi atas block tujuan (menempel atap)
            -- coba 2: setelah naik 0.15 tile (menempel sisi block, game mengangkat badan s/d 0.3 tile)
            -- coba 3: saat kaki 0.25 tile di bawah atas block
            local press = (try == 1 and s.y <= top + 0.02) or (try == 2 and s.y <= y0 - 0.15) or (try == 3 and s.y <= top + 0.25)
            if airborne and press then
                AutoInput.right, AutoInput.left = dir > 0, dir < 0
            else
                steerX(s, hug, 0.03)
            end
            if airborne and s.grounded then
                landed = floor(s.y - 0.475)
                break
            end
            if not airborne and os.clock() - t0 > 0.35 then break end
            if os.clock() - t0 > 1.8 then break end
        end
        releaseInput()
        if landed == e.y then
            return execWalk(e.x, e.y) -- sudah di lorong atas: ke tengah tile tujuan
        end
        if landed ~= nil and landed ~= e.fy then return false end -- jatuh ke tempat lain
        if not execWalk(e.fx, e.fy) then return false end
    end
    return false
end

-- Naik 1 tile: lompat, taruh block di bawah kaki, lalu mendarat di atasnya.
-- Block ditaruh agak telat supaya posisi di server sudah ikut naik.
local function execPillar(e)
    if not execWalk(e.fx, e.fy) then return false end
    if fgIdAt(e.fx, e.fy) ~= 0 then return false end
    releaseInput()
    if not frame() then return false end
    AutoInput.jump = true
    local t0 = os.clock()
    local placed, airborne = false, false
    while frame() do
        local s = playerState()
        if not s or s.dead then return false end
        if not s.grounded then airborne = true end
        steerX(s, e.fx + 0.5, 0.12)
        if AutoInput.jump and (s.y < e.fy - 0.9 or (airborne and (s.vy or 0) >= 0)) then
            AutoInput.jump = false
        end
        if not placed and airborne and s.y < e.fy - 0.25 and ((s.vy or 0) > -6 or s.y < e.fy - 0.8) then
            placed = placeScaffold(e.fx, e.fy)
            if not placed then return false end
        end
        if s.grounded and airborne then
            local nx, ny = floor(s.x), floor(s.y - 0.475)
            return placed and nx == e.x and ny == e.y
        end
        if not airborne and os.clock() - t0 > 0.35 then return false end
        if os.clock() - t0 > 1.8 then return false end
    end
    return false
end

local function followPath(path)
    local i = 1
    while i <= #path do
        if not autoOn() then return false end
        local e = path[i]
        local last, ok = i, false
        if e.kind == "walk" then
            -- langkah searah digabung jadi satu gerakan
            local dir = e.x - e.fx
            while path[last + 1] and path[last + 1].kind == "walk" and (path[last + 1].x - path[last + 1].fx) == dir do
                last += 1
            end
            local anyBuild = false
            for j = i, last do
                if path[j].build then
                    anyBuild = true
                    break
                end
            end
            if anyBuild then
                -- perlu block: taruh block di depan, lalu melangkah
                ok = true
                for j = i, last do
                    local st = path[j]
                    if st.build and not realSupport(st.x, st.y) then
                        setMoveStatus(("Taruh block pijakan (%d,%d)"):format(st.x, st.y + 1))
                        if not placeScaffold(st.x, st.y + 1) or not waitAuto(120) then
                            ok = false
                            break
                        end
                    end
                    if not execWalk(st.x, st.y) then
                        ok = false
                        break
                    end
                end
            else
                setMoveStatus(("Jalan ke (%d,%d)"):format(path[last].x, path[last].y))
                ok = execWalk(path[last].x, path[last].y)
            end
        elseif e.kind == "pillar" then
            setMoveStatus(("Naik pakai block ke (%d,%d)"):format(e.x, e.y))
            ok = execPillar(e)
        elseif e.kind == "fall" then
            setMoveStatus(("Turun ke (%d,%d)"):format(e.x, e.y))
            ok = execFall(e)
        elseif e.kind == "jump" then
            setMoveStatus(("Lompat ke (%d,%d)"):format(e.x, e.y))
            ok = execJump(e)
        elseif e.kind == "gap" then
            setMoveStatus(("Lompati lubang ke (%d,%d)"):format(e.x, e.y))
            ok = execGap(e)
        elseif e.kind == "stair" then
            setMoveStatus(("Naik tangga ke (%d,%d)"):format(e.x, e.y))
            ok = Move.execStair(e)
        end
        releaseInput()
        if not ok then
            -- hindari jalur ini sementara (tangga cuma sebentar, supaya tidak memutar jauh ke tangga lain)
            BadEdge[e.key] = os.clock() + ((e.kind == "stair") and 5 or 20)
            return false
        end
        i = last + 1
    end
    return true
end

-- Cari jalan ke grup target, lalu jalan ke sana
local function travelGroup(sx, sy, group, R, useBlock, skipTbl, failTbl)
    local w = Refs.World
    local goals = {}
    goals.maxY = group.maxY
    goals.los = group.los
    for _, t in ipairs(group) do goals[t.idx] = true end
    local first = group[1]
    setMoveStatus(("Cari jalan A* ke (%d,%d)"):format(first.x, first.y))
    local path, exhausted, closed = astar(sx, sy, goals, first.x, first.y, R, useBlock)
    if path then
        if #path == 0 then
            for _, t in ipairs(group) do skipTile(skipTbl, t.idx, 20) end
        elseif not followPath(path) then
            failTbl[first.idx] = (failTbl[first.idx] or 0) + 1
            if failTbl[first.idx] >= 3 then
                for _, t in ipairs(group) do skipTile(skipTbl, t.idx, 40) end
            end
        end
        releaseInput()
        return true
    end
    -- tidak ada jalan ke grup ini
    for _, t in ipairs(group) do skipTile(skipTbl, t.idx, exhausted and 60 or 30) end
    if exhausted and w then storeReach(sy * w.w + sx, R, useBlock, closed) end
    releaseInput()
    return false
end

-- ---------- Datangi drop yang belum terambil ----------
-- Hasil panen kadang jatuh di luar jangkauan collect. Drop dicari dari daftar drop game
-- (sama seperti Growscan), lalu karakter jalan mendekat (A*, tanpa pijakan) sampai drop
-- itu benar-benar terambil. Drop yang tidak ada jalannya dilewati sebentar.
-- Ambil drop di tile kerja dengan sentuhan badan (Auto Farm, Pabrik, bibit Bangun Lahan), tanpa remote.
-- Aturan game: drop terpungut kalau jaraknya < 0.6 tile dari tengah badan (mendatar) dan setinggi badan.
--   - tile sebaris (kiri / kanan, sampai 3 tile): disusuri sampai tile terjauh tiap sisi
--   - tile baris atas (kiri, tengah, kanan): berdiri di bawahnya lalu lompat kecil (tap); selama di udara
--     geser ke tile atas berikutnya yang masih ada drop-nya (bisa kena 2 sekaligus)
-- lalu balik lagi ke posisi kerja (hx, hy). Hasil: true = sudah balik ke posisi kerja.
function Drops.touchAll(tiles, hx, hy)
    local list = Drops.list
    if not list or not OrigIsDown then return false end
    local function dropsAt(t)
        for _, d in ipairs(list) do
            if type(d) == "table" and type(d.x) == "number" and (d.n or 0) > 0 and d.armed ~= false
                and not d.taking and inTile(t, d.x, d.y) then
                return true
            end
        end
        return false
    end
    local has = {}
    for _, t in ipairs(tiles) do
        if not solidAt(t.x, t.y) and dropsAt(t) then has[#has + 1] = t end
    end
    if #has == 0 then return false end
    local s0 = playerState()
    if not s0 or s0.dead or not s0.grounded then return false end
    local function ground(c) return openAt(c, hy) and realSupport(c, hy) end
    local function walkable(a, b)
        local st = (b >= a) and 1 or -1
        for c = a, b, st do
            if not ground(c) then return false end
        end
        return true
    end
    local was = AutoInput.active
    AutoInput.active = true
    local function moveTo(cx, maxT)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < (maxT or 1.2) do
            task.wait()
            local c = playerState()
            if not c or c.dead then break end
            steerX(c, cx, 0.1)
            if c.grounded and abs(c.x - cx) <= 0.15 and abs(c.vx or 0) < 1.5 then
                AutoInput.left, AutoInput.right = false, false
                return true
            end
        end
        AutoInput.left, AutoInput.right = false, false
        return false
    end
    -- lompat kecil (tap = naik +-1.4 tile, tidak sampai naik ke atas baris block), di udara geser ke toX
    local function hop(toX)
        AutoInput.left, AutoInput.right = false, false
        local c0 = playerState()
        if not c0 then return end
        local y0 = c0.y
        AutoInput.jump = true
        local t0, air = os.clock(), false
        while alive() and os.clock() - t0 < 1.4 do
            task.wait()
            local c = playerState()
            if not c or c.dead then break end
            if not c.grounded then
                air = true
                AutoInput.jump = false -- tap: lepas begitu lepas dari tanah
            end
            if toX and air and c.y <= y0 - 0.25 then steerX(c, toX, 0.1) else AutoInput.left, AutoInput.right = false, false end
            if air and c.grounded then break end
            if not air and os.clock() - t0 > 0.35 then break end
        end
        AutoInput.jump, AutoInput.left, AutoInput.right = false, false, false
    end
    -- baris badan: susuri sampai tile terjauh tiap sisi
    local lo, hi = hx, hx
    for _, t in ipairs(has) do
        if t.y == hy and abs(t.x - hx) <= 3 then
            if t.x < lo then lo = t.x end
            if t.x > hi then hi = t.x end
        end
    end
    if lo < hx and walkable(hx - 1, lo) then moveTo(lo + 0.5) end
    if hi > hx and walkable(hx + 1, hi) then moveTo(hi + 0.5) end
    -- baris atas: lompat di bawah tile yang masih ada drop-nya (maks 4 lompatan)
    for _ = 1, 4 do
        local cs = playerState()
        if not cs or not alive() then break end
        local cur = floor(cs.x)
        local cols = {}
        for _, t in ipairs(has) do
            if t.y == hy - 1 and abs(t.x - hx) <= 1 and ground(t.x) and walkable(cur, t.x)
                and not solidAt(t.x, t.y) and dropsAt(t) then
                cols[#cols + 1] = t.x
            end
        end
        if #cols == 0 then break end
        table.sort(cols, function(p, q) return abs(p - cur) < abs(q - cur) end)
        local a = cols[1]
        if a ~= cur then moveTo(a + 0.5) end
        hop(cols[2] and (cols[2] + 0.5) or nil) -- sambil geser ke tile berikutnya
    end
    -- balik ke posisi kerja
    local ok = moveTo(hx + 0.5, 2)
    AutoInput.left, AutoInput.right, AutoInput.jump = false, false, false
    AutoInput.active = was
    waitNearDrops(0.2)
    return ok
end

function Drops.touch(t, hx, hy)
    return Drops.touchAll({ t }, hx, hy)
end

-- Tile yang barusan pecah: drop-nya datang dari server (sesuai ping). Tunggu sampai drop baru
-- muncul di tile itu (atau batas waktu), supaya tidak keburu ketimpa block baru / tidak tersentuh.
function Drops.waitSpawn(tiles)
    local ping = 0.1
    pcall(function() ping = LocalPlayer:GetNetworkPing() end)
    local limit = math.clamp(0.15 + 2.5 * ping, 0.25, 0.8)
    local newest = nil
    for _, t in ipairs(tiles) do
        local b = Drops.brokeAt[t.x .. "," .. t.y]
        if b and os.clock() - b < limit and (not newest or b > newest) then newest = b end
    end
    if not newest then return end
    local list = Drops.list
    while os.clock() - newest < limit and alive() do
        if list then
            for _, d in ipairs(list) do
                if type(d) == "table" and type(d.x) == "number" and (d.born or 0) >= newest then
                    for _, t in ipairs(tiles) do
                        if inTile(t, d.x, d.y) then
                            task.wait(0.05) -- drop lain dari pecahan yang sama
                            return
                        end
                    end
                end
            end
        end
        task.wait()
    end
end

-- Datangi 1 drop sampai terambil (berdiri di tile drop-nya; kalau tile itu tidak bisa dipijak,
-- misal lubang tangga: berdiri tepat di bawahnya lalu lompat sekali). Hasil: true = terambil.
function Move.visitDrop(d)
    local w = Refs.World
    local s = playerState()
    if not w or not s then return false, "nopath" end
    local W = w.w
    local tx, ty = floor(d.x), floor(d.y)
    if solidAt(tx, ty) then return false, "nopath" end -- terkubur di dalam block: tidak bisa disentuh
    local sx, sy = startNode(s)
    local goal = { [ty * W + tx] = true }
    local path = astar(sx, sy, goal, tx, ty, 0.5, false)
    if not path and ty + 1 < w.h then
        path = astar(sx, sy, { [(ty + 1) * W + tx] = true }, tx, ty + 1, 0.5, false)
    end
    if not path then path = astar(sx, sy, goal, tx, ty, 1.2, false) end
    if not path then return false, "nopath" end
    if #path > 0 then
        local ok = followPath(path)
        releaseInput()
        if not ok then return false, "nopath" end
    end
    local ping = 0.1
    pcall(function() ping = LocalPlayer:GetNetworkPing() end)
    waitNearDrops(math.clamp(0.6 + 3 * ping, 1, 2.5))
    local function left() return (d.n or 0) > 0 and table.find(Drops.list or {}, d) ~= nil end
    local cur = playerState()
    if left() and cur and cur.grounded and abs(d.x - cur.x) <= 0.9 and d.y < cur.y - 0.9 and d.y > cur.y - 2.6 then
        -- drop di atas kepala: lompat sekali supaya kena badan
        AutoInput.active = true
        AutoInput.jump = true
        task.wait(0.25)
        AutoInput.jump = false
        local t0 = os.clock()
        repeat
            task.wait(0.05)
            local c = playerState()
        until not c or c.grounded or os.clock() - t0 > 1.5
        waitNearDrops(0.5)
    end
    if left() then return false, "left" end
    return true
end

-- Susuri 1 baris (tile badan ry) dari kolom xa ke xb tanpa berhenti di tiap drop:
-- drop di jalan terambil sambil lewat, sama seperti main manual.
function Move.walkRow(ry, xa, xb)
    local w = Refs.World
    if not w then return false end
    for _, tx in ipairs({ xa, xb }) do
        local s = playerState()
        if not s or s.dead then return false end
        local sx, sy = startNode(s)
        if not (sx == tx and sy == ry) then
            local goal = { [ry * w.w + tx] = true }
            local path = astar(sx, sy, goal, tx, ry, 0.5, false) or astar(sx, sy, goal, tx, ry, 1.2, false)
            if not path then
                releaseInput()
                return false
            end
            if #path > 0 and not followPath(path) then
                releaseInput()
                return false
            end
        end
    end
    releaseInput()
    return true
end

-- Ambil drop yang belum terambil, PER BARIS (seperti main manual):
--   pilih drop terdekat (baris sendiri didahulukan), lalu susuri baris itu dari ujung terdekat
--   ke ujung lainnya tanpa berhenti. Yang masih tertinggal (mis. di lubang tangga) baru didatangi
--   satu-satu, dan yang tetap tidak terambil tidak dicoba lagi sebentar.
-- filter(d) = true: drop ini boleh diambil (nil = semua). maxSec = batas waktu (20 dtk).
Move.FetchFail = {}
function Move.fetchDrops(live, maxDist, filter, maxSec)
    local list = Drops.list
    local w = Refs.World
    if not list or not w then return 0 end
    maxDist = maxDist or 8
    local got, t0 = 0, os.clock()
    local function want(d, now)
        if not (canTry(d, now) and d.id) then return false end
        if Move.FetchFail[d.uid] and now < Move.FetchFail[d.uid] then return false end
        if solidAt(floor(d.x), floor(d.y)) then -- terkubur di dalam block: tidak bisa disentuh
            Move.FetchFail[d.uid] = now + 300
            return false
        end
        local z = Pabrik.Zone
        if z and not Move.NoZone and z.world == rawget(w, "name") and abs(d.x - z.x) <= 2.5 and abs(d.y - z.y) <= 2.5 then
            return false
        end
        if filter and not filter(d) then return false end
        if d.id ~= 112 and Refs.Inv then -- inventori penuh: tidak usah diambil
            local okr, r = pcall(function() return Refs.Inv:room(d.id) end)
            if okr and type(r) == "number" and r <= 0 then return false end
        end
        return true
    end
    while live() and alive() and os.clock() - t0 < (maxSec or 20) do
        local s = playerState()
        if not s or s.dead then break end
        if not s.grounded then
            task.wait(0.05)
            continue
        end
        local cx, cy = s.x, s.y - 0.475
        local now = os.clock()
        local best, bd = nil, nil
        for _, d in ipairs(list) do
            if want(d, now) then
                local dx, dy = d.x - cx, d.y - cy
                if abs(dx) <= maxDist and abs(dy) <= maxDist and (abs(dx) >= 0.6 or abs(dy) >= 0.75) then
                    local dd = dx * dx + 9 * dy * dy -- baris sendiri didahulukan
                    if not bd or dd < bd then best, bd = d, dd end
                end
            end
        end
        if not best then break end
        local ry = floor(best.y)
        if best.x < 0 or ry < 0 or best.x >= w.w or ry >= w.h then
            Move.FetchFail[best.uid] = now + 30
        else
            -- semua drop di baris itu: susuri dari ujung terdekat ke ujung lainnya
            local inRow, lo, hi = {}, best.x, best.x
            for _, d in ipairs(list) do
                if floor(d.y) == ry and abs(d.x - cx) <= maxDist and want(d, now) then
                    inRow[#inRow + 1] = d
                    if d.x < lo then lo = d.x end
                    if d.x > hi then hi = d.x end
                end
            end
            local xa, xb = floor(lo), floor(hi)
            if abs(hi - cx) < abs(lo - cx) then xa, xb = xb, xa end
            setMoveStatus(("Ambil drop baris y %d (x %d-%d)"):format(ry, math.min(xa, xb), math.max(xa, xb)))
            local ok = Move.walkRow(ry, xa, xb)
            -- pungutan dikirim ke server: tunggu balasannya (ping) sebelum menilai drop tertinggal
            local ping = 0.1
            pcall(function() ping = LocalPlayer:GetNetworkPing() end)
            local tw = os.clock()
            repeat
                task.wait(0.05)
                local busy = false
                for _, d in ipairs(inRow) do
                    if d.taking then
                        busy = true
                        break
                    end
                end
            until not busy or os.clock() - tw > math.clamp(0.3 + 3 * ping, 0.5, 2.5)
            got += 1
            Move.FetchTry = Move.FetchTry or {}
            for _, d in ipairs(inRow) do
                if (d.n or 0) > 0 and table.find(list, d) then
                    local okv, why = false, "nopath"
                    if ok then okv, why = Move.visitDrop(d) end
                    if not okv then
                        local tries = (Move.FetchTry[d.uid] or 0) + 1
                        Move.FetchTry[d.uid] = tries
                        if why == "left" and tries < 4 then
                            Move.FetchFail[d.uid] = os.clock() + 1.5 -- sudah didatangi (balasan server telat / sisa sebagian): coba lagi sebentar lagi
                        else
                            Move.FetchFail[d.uid] = os.clock() + 30 -- tidak ada jalan / tetap tidak terambil
                        end
                    else
                        Move.FetchTry[d.uid] = nil
                    end
                end
            end
        end
    end
    releaseInput()
    return got
end

local function autoBegin()
    AutoInput.active = true
    releaseInput()
    Reach = nil
end

local function autoEnd()
    if Clear.Running or Farmer.Running or Splice.Roaming or Pabrik.Running or Build.Running or Move.Homing
        or Vend.Running then
        return
    end
    AutoInput.active = false
    releaseInput()
end

---------------------------------------------------------------------
-- FARMER: mesin panen + tanam (dipakai bersama Pabrik)
---------------------------------------------------------------------
-- Pohon siap kalau: waktu server >= waktu tanam + lama tumbuh (sama dengan game).
-- Seed ditanam di tile kosong yang di bawahnya ada block.
local function findTreeRefs()
    Refs.Trees, Refs.TreeMode, Refs.TreeP = nil, nil, nil
    -- 1) cara utama (game v1159+): ikuti fungsi World.tileChanged -> fungsi simpan pohon.
    --    Tetap jalan walau world belum punya pohon (tabel kosong).
    local okS, foundS = pcall(function() return Auto.findTreesStruct and Auto.findTreesStruct() end)
    if okS and foundS == true then return true end
    Refs.Trees, Refs.TreeMode, Refs.TreeP = nil, nil, nil
    -- 2) game lama: handler remote WorldRemotes.TreeChanged
    local ev = WorldRemotes:FindFirstChild("TreeChanged")
    if ev and ev:IsA("RemoteEvent") and getconnections then
        local ok, conns = pcall(getconnections, ev.OnClientEvent)
        if ok and type(conns) == "table" then
            for _, c in ipairs(conns) do
                local okf, fn = pcall(function() return c.Function end)
                if okf and type(fn) == "function" then
                    for _, u in pairs(getUpvalues(fn)) do
                        if type(u) == "table" and u ~= Refs.World and rawget(u, "fg") == nil then
                            local _, v = next(u)
                            if type(v) == "table" and type(rawget(v, "p")) == "number" then
                                Refs.Trees, Refs.TreeMode, Refs.TreeP = u, "idx", "p"
                                break
                            end
                        end
                    end
                end
                if Refs.Trees then return true end
            end
        end
    end
    -- 3) cadangan: telusuri upvalue lebih dalam (butuh world yang sudah ada pohonnya)
    if Auto.findTreesDeep then pcall(Auto.findTreesDeep) end
    return Refs.Trees ~= nil
end

-- Tabel ini cocok jadi data pohon? Kosong = boleh (world tanpa pohon).
-- Isi = [y*W+x] -> { p = waktu tanam (waktu server), f = buah, s = sudah di-splice }
function Auto.treeTableOk(t)
    local w = Refs.World
    if type(t) ~= "table" or t == w or getmetatable(t) ~= nil or rawget(t, "fg") ~= nil then return false end
    local n = 0
    for k, v in pairs(t) do
        n += 1
        if n > 6 then break end
        if type(k) ~= "number" or type(v) ~= "table" or type(rawget(v, "p")) ~= "number" then return false end
        if w and type(w.w) == "number" and type(w.h) == "number" and (k < 0 or k >= w.w * w.h) then return false end
    end
    return true
end

-- Cari data pohon dari struktur kode game (tanpa getgc, tanpa remote):
--   World.tileChanged memegang (upvalue) tabel pohon + fungsi simpan pohon.
--   Fungsi simpan pohon memegang World + tabel pohon + tabel gambar pohon.
--   Tabel yang dipegang KEDUANYA = tabel pohon.
function Auto.findTreesStruct()
    local w = Refs.World
    if not w or not getUpvalues then return false end
    local roots = {}
    for _, name in ipairs({ "tileChanged", "treeChanged", "setTree" }) do
        local f = rawget(w, name)
        if type(f) == "function" then roots[#roots + 1] = f end
    end
    for _, root in ipairs(roots) do
        local ups = getUpvalues(root)
        local tset = {}
        for _, u in pairs(ups) do
            if type(u) == "table" and u ~= w then tset[u] = true end
        end
        for _, g in pairs(ups) do
            if type(g) == "function" then
                local gu = getUpvalues(g)
                local hasW, nT, shared = false, 0, {}
                for _, v in pairs(gu) do
                    if rawequal(v, w) then
                        hasW = true
                    elseif type(v) == "table" then
                        nT += 1
                        if tset[v] then shared[#shared + 1] = v end
                    end
                end
                -- fungsi simpan pohon: upvalue sedikit (World + 2 tabel), satu tabel sama dengan tileChanged
                if hasW and nT <= 3 and #shared == 1 and Auto.treeTableOk(shared[1]) then
                    Refs.Trees, Refs.TreeMode, Refs.TreeP = shared[1], "idx", "p"
                    return true
                end
            end
        end
        -- cadangan: tabel milik tileChanged yang isinya jelas data pohon
        for t in pairs(tset) do
            if next(t) ~= nil and Auto.treeTableOk(t) and Auto.treeShape(t) == "idx" then
                Refs.Trees, Refs.TreeMode, Refs.TreeP = t, "idx", "p"
                return true
            end
        end
    end
    return false
end

-- Data pohon di tile (x,y): { p = waktu tanam (waktu server), s = sudah di-splice }.
-- Bentuk tabel bisa beda tergantung versi game (lihat Auto.findTreesDeep).
function Auto.treeEntry(x, y)
    local t, w = Refs.Trees, Refs.World
    if not t or not w then return nil end
    local mode = Refs.TreeMode or "idx"
    local e
    if mode == "xy" then
        e = t[x .. "," .. y]
    elseif mode == "rows" then
        local r = t[y]
        e = type(r) == "table" and r[x] or nil
    else
        e = t[y * w.w + x]
    end
    if type(e) == "number" then return { p = e } end
    if type(e) ~= "table" then return nil end
    local pk = Refs.TreeP or "p"
    if pk ~= "p" then return { p = rawget(e, pk), s = rawget(e, "s") } end
    return e
end

-- Tabel ini data pohon? Hasil: mode ("idx" / "xy" / "rows"), nama field waktu tanam
function Auto.treeShape(t)
    local w = Refs.World
    if type(t) ~= "table" or not w or t == w or rawget(t, "fg") ~= nil then return nil end
    local W, H = w.w, w.h
    local okT, st = pcall(function() return workspace:GetServerTimeNow() end)
    if not okT then st = os.time() end
    local function timeKey(e)
        if type(e) == "number" then
            return (math.abs(e - st) < 86400 * 90) and "#" or nil
        end
        if type(e) ~= "table" then return nil end
        local pv = rawget(e, "p")
        if type(pv) == "number" and math.abs(pv - st) < 86400 * 90 then return "p" end
        for fk, fv in pairs(e) do
            if type(fv) == "number" and math.abs(fv - st) < 86400 * 90 then return fk end
        end
        return nil
    end
    local function seedAt(x, y)
        local row = w.fg[y]
        local id = row and row[x]
        local it = id and ItemDB[id]
        return it ~= nil and it.kind == "seed"
    end
    local checked, good, bad, mode, pk = 0, 0, 0, nil, nil
    for k, v in pairs(t) do
        checked += 1
        if checked > 10 then break end
        local x, y, e, m = nil, nil, nil, nil
        if type(k) == "number" and k % 1 == 0 and k >= 0 then
            if type(v) == "table" and k < H and timeKey(v) == nil then
                -- baris: t[y][x]
                local kx, ve = next(v)
                if type(kx) == "number" and kx >= 0 and kx < W then x, y, e, m = kx, k, ve, "rows" end
            elseif k < W * H then
                x, y, e, m = k % W, k // W, v, "idx"
            end
        elseif type(k) == "string" then
            local a, b = string.match(k, "^(%d+),(%d+)$")
            if a then x, y, e, m = tonumber(a), tonumber(b), v, "xy" end
        end
        if not x then return nil end
        if mode and mode ~= m then return nil end
        mode = m
        local tk = timeKey(e)
        if tk and seedAt(x, y) then
            good += 1
            pk = (tk == "#") and "p" or tk
        else
            bad += 1 -- data lama (pohon sudah dipanen) masih tersimpan: boleh sedikit
        end
    end
    if good == 0 or bad > good then return nil end
    return mode, pk
end

-- Cari data pohon lewat upvalue fungsi game (remote world, fungsi World, RunService, Net). Tanpa getgc.
function Auto.findTreesDeep()
    local w = Refs.World
    if not w or not getUpvalues then return false end
    local queue, seenF, seenT, nF = {}, {}, {}, 0
    local function addFn(fn)
        if type(fn) == "function" and not seenF[fn] then queue[#queue + 1] = fn end
    end
    local function tryTable(t)
        if seenT[t] then return false end
        seenT[t] = true
        local mode, pk = Auto.treeShape(t)
        if mode then
            Refs.Trees, Refs.TreeMode, Refs.TreeP = t, mode, pk
            return true
        end
        return false
    end
    -- 1) isi World langsung (tabel & fungsi)
    for _, v in pairs(w) do
        if type(v) == "table" then
            if tryTable(v) then return true end
        elseif type(v) == "function" then
            addFn(v)
        end
    end
    -- 2) handler remote world
    if getconnections then
        for _, ev in ipairs(WorldRemotes:GetChildren()) do
            if ev:IsA("RemoteEvent") then
                local ok, conns = pcall(getconnections, ev.OnClientEvent)
                if ok and type(conns) == "table" then
                    for _, c in ipairs(conns) do
                        local okf, fn = pcall(function() return c.Function end)
                        if okf then addFn(fn) end
                    end
                end
            end
        end
        for _, name in ipairs({ "RenderStepped", "Heartbeat", "Stepped" }) do
            local okS, sig = pcall(function() return RunService[name] end)
            local ok, conns = pcall(getconnections, sig)
            if okS and ok and type(conns) == "table" then
                for _, c in ipairs(conns) do
                    local okf, fn = pcall(function() return c.Function end)
                    if okf then addFn(fn) end
                end
            end
        end
    end
    -- 3) telusuri upvalue (maks 1500 fungsi)
    local i = 1
    while i <= #queue and nF < 1500 do
        local fn = queue[i]
        i += 1
        if not seenF[fn] then
            seenF[fn] = true
            nF += 1
            for _, u in pairs(getUpvalues(fn)) do
                if type(u) == "table" then
                    if tryTable(u) then return true end
                elseif type(u) == "function" then
                    addFn(u)
                end
            end
        end
    end
    return false
end
local function farmReach()
    return math.min(punchReach(), buildReach())
end
-- Kapan pohon ini siap panen (nil = bukan pohon)
local function treeReadyAt(x, y, id)
    if not Refs.Trees or not Refs.World then return nil end
    local it = ItemDB[id]
    if not (it and it.kind == "seed") then return nil end
    local t = Auto.treeEntry(x, y)
    if type(t) ~= "table" or type(t.p) ~= "number" then return nil end
    return t.p + (it.grow or 0)
end

-- Bisa tanam seed di sini? (seedId kosong = seed Farmer)
local function plantSpotOk(x, y, seedId)
    local w = Refs.World
    if not w or x < 0 or y < 0 or x >= w.w or y + 1 >= w.h then return false end
    if fgIdAt(x, y) ~= 0 then return false end
    local below = fgIdAt(x, y + 1)
    if below == 0 then return false end
    local it = ItemDB[below]
    if not it or it.kind == "seed" then return false end
    if not (solidAt(x, y + 1) or it.platform) then return false end
    local ok, res = pcall(function()
        if w.areas and type(w.areas.canEdit) == "function" and not w.areas.canEdit(x, y) then return false end
        if type(w.builderOk) == "function" and not w.builderOk(x, y, true) then return false end
        local sid = seedId or Farmer.SeedId
        local seed = sid and ItemDB[sid]
        if seed and type(w.needsWay) == "function" and w.needsWay(seed)
            and type(w.wayBlocked) == "function" and w.wayBlocked(x, y) then
            return false
        end
        return true
    end)
    return (not ok) or res
end

-- Mesin panen & tanam dipakai bersama oleh Farmer dan Pabrik.
-- FC = pengaturan yang sedang dipakai (seed, area, kecepatan, dll).
local FC = nil
local function farmerCfg()
    return {
        run = function() return Farmer.Running end,
        harvest = Farmer.Harvest,
        plant = Farmer.Plant,
        seed = Farmer.SeedId,
        skip = Farmer.Skip,
        hms = Farmer.HarvestMs,
        pms = Farmer.PlantMs,
        area = nil,      -- function(x, y): boleh panen di sini?
        plantSet = nil,  -- [idx] = true: hanya tanam di tile ini
        exclude = nil,   -- [idx] = true: jangan tanam di tile ini
        row = Farmer.Row,        -- tanam rapi per baris
        collect = Farmer.Collect, -- ambil drop panen dulu sebelum lanjut
        status = function(t) Farmer.Status = t end,
        onHarvest = function(id)
            Farmer.Harvested += 1
            if id then Farmer.Got[id] = true end
        end,
        onPlant = function() Farmer.Planted += 1 end,
    }
end

local function fcSeeds()
    return FC.seed and invCount(FC.seed) or 0
end

local function fcHarvestOk(x, y)
    return FC.harvest and (not FC.area or FC.area(x, y))
end

local function fcPlantOk(idx)
    return (not FC.plantSet or FC.plantSet[idx]) and not (FC.exclude and FC.exclude[idx])
end

local function plantSeed(x, y)
    local id = FC.seed
    if not id or invCount(id) <= 0 then return false end
    sendSetTile("fg", x, y, id)
    if Refs.Inv then pcall(function() Refs.Inv:remove(id, 1) end) end
    FC.onPlant()
    FC.status("Tanam " .. itemName(id) .. " (" .. x .. "," .. y .. ")")
    return true
end

-- Panen & tanam semua yang terjangkau dari sini
local function farmerWorkInReach(s)
    local w = Refs.World
    local W = w.w
    local R = farmReach() - 0.08
    local cx, cy = s.x, s.y - 0.475
    local now = os.clock()
    local st = workspace:GetServerTimeNow()
    local doPlant = FC.plant and fcSeeds() > 0
    local harvest, plant = {}, {}
    local bx, by = floor(s.x), floor(cy)
    for ty = math.max(0, floor(cy - R - 0.5)), math.min(floor(cy + R + 0.5), w.h - 1) do
        for tx = math.max(0, floor(cx - R - 0.5)), math.min(floor(cx + R + 0.5), W - 1) do
            if stateReaches(s, tx, ty, R) then
                local idx = ty * W + tx
                if not skipped(FC.skip, idx, now) then
                    local id = fgIdAt(tx, ty)
                    if id ~= 0 and fcHarvestOk(tx, ty) and (not FC.only or id == FC.only) then
                        local ra = treeReadyAt(tx, ty, id)
                        if ra and st >= ra and Move.los(bx, by, tx, ty) then
                            if canWorkAt(tx, ty) then
                                harvest[#harvest + 1] = { x = tx, y = ty, idx = idx }
                            else
                                skipTile(FC.skip, idx, 120)
                            end
                        end
                    elseif doPlant and id == 0 and fcPlantOk(idx) and (not FC.row or FC.row.y == ty)
                        and plantSpotOk(tx, ty, FC.seed) then
                        plant[#plant + 1] = { x = tx, y = ty, idx = idx }
                    end
                end
            end
        end
    end
    local function byX(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end
    table.sort(harvest, byX)
    table.sort(plant, byX)

    local done, got = 0, 0
    for _, t in ipairs(harvest) do
        if not FC.run() or not alive() then return done end
        local cur = playerState()
        if not cur or not stateReaches(cur, t.x, t.y, R) then break end
        local id = fgIdAt(t.x, t.y)
        local r = tryBreak(t.x, t.y, false) -- pohon siap: 1 pukulan = panen
        if r == "broke" then
            FC.onHarvest(id)
            got += 1
            FC.status("Panen " .. itemName(id) .. " (" .. t.x .. "," .. t.y .. ")")
        else
            skipTile(FC.skip, t.idx, 30)
        end
        done += 1
        if not waitAuto(FC.hms) then return done end
    end
    -- ambil hasil panen dulu sebelum pindah / tanam
    if got > 0 and FC.collect then
        FC.status("Ambil hasil panen...")
        task.wait(0.25) -- drop panen muncul sedikit terlambat
        if not FC.run() or not alive() then return done end
        -- susuri baris ini sampai drop terjauh (terambil sambil lewat, tanpa berhenti)
        if Move.fetchDrops(FC.run, 8, function(d) return abs(d.y - cy) <= 1.6 end, 10) > 0 then return done end
    end
    for _, t in ipairs(plant) do
        if not FC.run() or not alive() then return done end
        if fcSeeds() <= 0 then break end
        local cur = playerState()
        if not cur or not stateReaches(cur, t.x, t.y, R) then return done end
        if fgIdAt(t.x, t.y) == 0 then
            if not plantSeed(t.x, t.y) then break end
            done += 1
            if not waitAuto(FC.pms) then return done end
        end
    end
    return done
end

-- Cari target + kapan pohon berikutnya siap.
--   Panen : pohon siap terdekat (didahulukan).
--   Tanam : rapi per baris. Selesaikan 1 baris dulu (baris yang sedang dikerjakan,
--           atau baris terdekat dengan karakter), dari tile paling kiri ke kanan.
local function farmerScan(px, py, maxN, filter)
    local w = Refs.World
    local W, H = w.w, w.h
    local best = {}
    local now = os.clock()
    local st = workspace:GetServerTimeNow()
    local nextReady = nil
    local doPlant = FC.plant and fcSeeds() > 0
    local rows = {} -- [y] = daftar tempat tanam di baris itu
    local scanned = 0
    for y = 0, H - 1 do
        local frow, below = w.fg[y], w.fg[y + 1]
        for x = 0, W - 1 do
            local id = frow and frow[x] or 0
            if id ~= 0 then
                if fcHarvestOk(x, y) and (not FC.only or id == FC.only) then
                    local ra = treeReadyAt(x, y, id)
                    if ra and st >= ra then
                        local idx = y * W + x
                        if not skipped(FC.skip, idx, now) then
                            if filter and not filter[idx] then
                                skipTile(FC.skip, idx, 60)
                            else
                                local dx, dy = x - px, (y - py) * 1.3
                                local d = dx * dx + dy * dy
                                if #best < maxN or d < best[#best].d then
                                    if canWorkAt(x, y) then
                                        local pos = #best + 1
                                        while pos > 1 and best[pos - 1].d > d do pos -= 1 end
                                        table.insert(best, pos, { x = x, y = y, idx = idx, d = d, kind = "harvest" })
                                        if #best > maxN then best[#best] = nil end
                                    else
                                        skipTile(FC.skip, idx, 120)
                                    end
                                end
                            end
                        end
                    elseif ra and (not nextReady or ra - st < nextReady) then
                        nextReady = ra - st
                    end
                end
            elseif doPlant then
                local b = below and below[x] or 0
                local idx = y * W + x
                if b ~= 0 and fcPlantOk(idx) and not skipped(FC.skip, idx, now) then
                    if filter and not filter[idx] then
                        skipTile(FC.skip, idx, 60)
                    else
                        local r = rows[y]
                        if not r then
                            r = {}
                            rows[y] = r
                        end
                        r[#r + 1] = { x = x, y = y, idx = idx, kind = "plant" }
                    end
                end
            end
        end
        scanned += W
        if scanned >= 6000 then
            scanned = 0
            task.wait()
            if not FC.run() or not alive() then break end
        end
    end
    if #best > 0 or not doPlant then return best, nextReady end

    -- tanam rapi: baris yang sedang dikerjakan dulu, lalu baris terdekat
    local lock = FC.row and FC.row.y
    local order = {}
    for y in pairs(rows) do order[#order + 1] = y end
    local function rowKey(y) return (y == lock) and -1 or math.abs(y - py) end
    table.sort(order, function(a, b)
        local ka, kb = rowKey(a), rowKey(b)
        if ka ~= kb then return ka < kb end
        return a < b
    end)
    for _, y in ipairs(order) do
        local list = rows[y]
        table.sort(list, function(a, b) return a.x < b.x end) -- dari kiri ke kanan
        for _, t in ipairs(list) do
            if plantSpotOk(t.x, t.y, FC.seed) then
                if FC.row then FC.row.y = y end
                return { t }, nextReady
            end
            skipTile(FC.skip, t.idx, 120)
        end
    end
    if FC.row then FC.row.y = nil end
    return best, nextReady
end

-- 1 langkah mesin panen/tanam (pakai FC):
--   kerjakan yang terjangkau, atau jalan ke target terdekat.
-- Hasil: "work" | "move" | "wait" | "idle" (+ detik ke pohon siap berikutnya)
-- Tersangkut lama di udara / pinggir block (bikin karakter diam): dorong sedikit ke samping
function Move.airCheck(s)
    if s.grounded then
        Move.AirAt = nil
        return
    end
    if not Move.AirAt then
        Move.AirAt = os.clock()
    elseif os.clock() - Move.AirAt > 3 then
        Move.AirAt = nil
        local right = (s.facing or 1) < 0 -- ke arah sebaliknya
        AutoInput.active = true
        AutoInput.right, AutoInput.left = right, not right
        task.wait(0.2)
        AutoInput.right, AutoInput.left = false, false
    end
end

local function fieldStep()
    local w = Refs.World
    local s = playerState()
    if not w or not s or s.dead then
        releaseInput()
        task.wait(0.5)
        return "wait"
    end
    if not s.grounded then
        releaseInput()
        Move.airCheck(s)
        task.wait()
        return "wait"
    end
    Move.AirAt = nil
    releaseInput()
    if farmerWorkInReach(s) > 0 then return "work" end
    local R = farmReach() - 0.35
    local useBlock = scaffoldId() ~= nil
    local sx, sy = startNode(s)
    local px, py = floor(s.x), floor(s.y - 0.475)
    local targets, nextReady = farmerScan(px, py, 8, reachFilter(sy * w.w + sx, R, useBlock))
    if not FC.run() or not alive() then return "wait" end
    if #targets == 0 then return "idle", nextReady end
    targets.los = targets[1].kind == "harvest" -- panen: berdiri di baris pohon (drop terambil)
    travelGroup(sx, sy, targets, R, useBlock, FC.skip, FarmerFail)
    return "move"
end

-- Jalan ke 1 tile tertentu (dipakai Penjaga: balik ke posisi Auto Farm).
-- Pakai A* yang sama, tanpa taruh block.
local function walkTo(tx, ty, maxSec)
    local w = Refs.World
    if not w or not OrigIsDown then return false end
    if tx < 0 or ty < 0 or tx >= w.w or ty >= w.h then return false end
    Move.Homing = true
    autoBegin()
    local goal = { [ty * w.w + tx] = true }
    local t0, ok = os.clock(), false
    while alive() and Move.Homing and os.clock() - t0 < (maxSec or 30) do
        local s = playerState()
        if not s or s.dead then
            task.wait(0.3) -- tunggu respawn / world selesai dimuat
        else
            local sx, sy = startNode(s)
            if sx == tx and sy == ty and s.grounded then
                ok = true
                break
            end
            local path = astar(sx, sy, goal, tx, ty, 0.5, false)
            if not path then break end -- tidak ada jalan
            if #path > 0 then followPath(path) end
            releaseInput()
            task.wait(0.15)
        end
    end
    Move.Homing = false
    autoEnd()
    return ok
end

---------------------------------------------------------------------
-- LAHAN
---------------------------------------------------------------------
-- Baris block dari Y atas ke bawah, selalu 1 tile kosong di antaranya (tempat pohon & jalan).
-- Jumlah baris otomatis: turun terus menembus tanah sampai bedrock. Kalau bedrock jatuh di baris
-- lahan, bedrock itu jadi lantai baris terakhir (tanah tepat di atas bedrock ikut digali).
-- (tanah di celah baris digali Bangun Lahan, tanah di baris lahan dipakai sebagai lahan).
-- Kedua ujung baris dibuat tangga (lihat landCols).
-- Hasil disimpan sebentar (dipanggil sangat sering oleh Pabrik / status).
local function landRows()
    local w = Refs.World
    if not w then return {} end
    local x0 = math.clamp(math.floor(math.min(Land.X0, Land.X1)), 0, w.w - 1)
    local x1 = math.clamp(math.floor(math.max(Land.X0, Land.X1)), 0, w.w - 1)
    local y0 = math.max(1, math.floor(Land.Y0))
    local c = Land.Cache
    local now = os.clock()
    if c and c.w == w and c.x0 == x0 and c.x1 == x1 and c.y0 == y0 and now - c.at < 2 then
        return c.rows
    end
    local rows = {}
    local span = x1 - x0 + 1
    -- block yang tidak bisa dipecah (bedrock dll)
    local function hard(x, y)
        local id = fgIdAt(x, y)
        if id == 0 then return false end
        local it = ItemDB[id]
        return it ~= nil and it.solid == true and not canBreak(id)
    end
    local y = y0
    while y <= w.h - 2 and #rows < 40 do
        local hg, hr = 0, 0
        for x = x0, x1 do
            if hard(x, y - 1) then hg += 1 end
            if hard(x, y) then hr += 1 end
        end
        if hg * 2 > span then break end -- celahnya bedrock: berhenti
        rows[#rows + 1] = y
        if hr * 2 > span then break end -- baris ini bedrock: jadi lantai paling bawah
        y += 2
    end
    Land.Cache = { w = w, x0 = x0, x1 = x1, y0 = y0, at = now, rows = rows }
    return rows
end

-- Kolom block baris ke-k (0 = paling atas). Tangga 2 kolom di KIRI dan KANAN:
--   baris ke-1, 3, 5.. : x0+1 .. x1-1              (kolom x0 & x1 kosong)
--   baris ke-2, 4, 6.. : x0, x0+2 .. x1-2, x1      (kolom x0+1 & x1-1 kosong)
-- Jadi dari ujung mana saja bisa turun (jatuh 2 tile ke anak tangga di bawahnya)
-- dan naik (lompat 2 tile), selang-seling seperti tangga.
local function landCols(k)
    local w = Refs.World
    local x0 = math.clamp(math.floor(math.min(Land.X0, Land.X1)), 0, w.w - 1)
    local x1 = math.clamp(math.floor(math.max(Land.X0, Land.X1)), 0, w.w - 1)
    local cols = {}
    if x1 - x0 < 4 then -- terlalu sempit untuk tangga
        for x = x0, x1 do cols[#cols + 1] = x end
    elseif k % 2 == 0 then
        for x = x0 + 1, x1 - 1 do cols[#cols + 1] = x end
    else
        cols[#cols + 1] = x0
        for x = x0 + 2, x1 - 2 do cols[#cols + 1] = x end
        cols[#cols + 1] = x1
    end
    return cols
end

local function inLandRect(x, y)
    local rows = landRows()
    if #rows == 0 then return false end
    local x0 = math.min(Land.X0, Land.X1)
    local x1 = math.max(Land.X0, Land.X1)
    return x >= x0 and x <= x1 and y >= rows[1] - 1 and y <= rows[#rows]
end

-- Tile tanam lahan (di atas block yang sudah terpasang): [idx] = true
local function landPlantSet()
    local set = {}
    local w = Refs.World
    if not w then return set end
    for k, y in ipairs(landRows()) do
        for _, x in ipairs(landCols(k - 1)) do
            if fgIdAt(x, y) ~= 0 and y - 1 >= 0 then set[(y - 1) * w.w + x] = true end
        end
    end
    return set
end

-- Seed <-> block (seed biasanya id block + 1, kecuali item khusus yang punya seedId)
local function seedOfBlock(block)
    local it = block and ItemDB[block]
    if not it then return nil end
    local sid = it.seedId or (block + 1)
    local sd = ItemDB[sid]
    if sd and sd.kind == "seed" then return sid end
    return nil
end

local function blockOfSeed(seed)
    if not seed then return nil end
    local b = seed - 1
    local it = ItemDB[b]
    if it and it.kind ~= "seed" and (it.seedId == nil or it.seedId == seed) then return b end
    return nil
end

local function readyTreeCount(whole, only)
    local w = Refs.World
    if not w then return 0 end
    local st = workspace:GetServerTimeNow()
    local x0, x1, y0, y1 = 0, w.w - 1, 0, w.h - 1
    if not whole then
        local rows = landRows()
        if #rows == 0 then return 0 end
        x0 = math.max(0, math.min(Land.X0, Land.X1))
        x1 = math.min(w.w - 1, math.max(Land.X0, Land.X1))
        y0, y1 = math.max(0, rows[1] - 1), rows[#rows]
    end
    local n, nxt = 0, nil
    for y = y0, y1 do
        for x = x0, x1 do
            local id = fgIdAt(x, y)
            if id ~= 0 and (not only or id == only) then
                local ra = treeReadyAt(x, y, id)
                if ra then
                    if st >= ra then
                        n += 1
                    elseif not nxt or ra - st < nxt then
                        nxt = ra - st
                    end
                end
            end
        end
    end
    return n, nxt
end

---------------------------------------------------------------------
-- PINDAH WORLD (Guard: hanya bagian keluar / masuk world yang dipakai engine)
-- Disalin dari seksi PENJAGA script lama. Deteksi Mod / Dev / pemain (Guard.tick, dll)
-- dipasang di tahap AI satpam pada tabel Guard yang sama (API.Engine.Guard).
---------------------------------------------------------------------
local function strip(s) return (tostring(s or ""):gsub("`.", "")) end

local function worldName()
    local n = Refs.World and rawget(Refs.World, "name")
    return type(n) == "string" and n or ""
end

-- Keluar world = sama seperti tombol "Exit World" game
local function leaveWorld()
    local m = Refs.Menu
    if m and type(rawget(m, "openPicker")) == "function" and pcall(m.openPicker) then
        return true
    end
    local w = Refs.World
    if w and type(rawget(w, "call")) == "function" then
        return (pcall(w.call, "LeaveWorld"))
    end
    return false
end

-- Masuk world lewat menu game (sama seperti ketik nama world lalu Enter)
local function enterWorld(name, timeout)
    local w = Refs.World
    if not w or name == "" then return false, "nama world tidak diketahui" end
    local oldFg = rawget(w, "fg")
    local m = Refs.Menu
    if m and type(rawget(m, "enter")) == "function" then
        pcall(m.enter, name)
    elseif type(rawget(w, "enter")) == "function" then
        local ok, res, msg = pcall(w.enter, name)
        if ok and not res then return false, strip(msg) end
    else
        return false, "fungsi masuk world tidak ketemu"
    end
    -- berhasil kalau data world sudah diganti yang baru
    local t0 = os.clock()
    while alive() and os.clock() - t0 < (timeout or 8) do
        if rawget(w, "fg") ~= oldFg then return true end
        task.wait(0.25)
    end
    return false, "world penuh / dikunci / gagal"
end

Guard.enterWorld = enterWorld
Guard.leaveWorld = leaveWorld
Guard.worldName = worldName
function Guard.afterEnter()
    Auto.resetReach()
    pcall(findDropRefs)
    pcall(Auto.findTreeRefs)
    table.clear(DropFailUntil)
end

---------------------------------------------------------------------
-- PINDAH WORLD & DROP
---------------------------------------------------------------------
-- "WORLD" / "WORLD:ID" / ":ID" -> nama world, id pintu
local function parseDropTarget()
    local raw = tostring(Pabrik.DropWorld or ""):gsub("%s", "")
    local name, door = string.match(raw, "^([^:]*):(.+)$")
    if not name then name = raw end
    name = string.upper(name):gsub("[^A-Z0-9]", "")
    if door == "" then door = nil end
    return name, door
end

-- Pindah world (lewat menu game), bisa langsung ke pintu tertentu
local function goWorld(name, door)
    if Guard.worldName() ~= "" then
        Guard.leaveWorld()
        task.wait(2)
    end
    if door and Refs.World then rawset(Refs.World, "arriveDoor", door) end
    local ok, err = Guard.enterWorld(name, 20) -- loading lambat: tunggu sampai 20 dtk
    if ok then
        task.wait(1.5)
        Guard.afterEnter()
    end
    return ok, err
end

-- Drop pakai fungsi drop game (item jatuh di depan karakter)
local function dropItems(id, n, live)
    local hud = Refs.Hud
    local f = hud and rawget(hud, "onDrop")
    if type(f) ~= "function" then return 0, "fungsi drop game tidak ketemu" end
    local left, flipped = n, false
    while left > 0 and live() do
        local before = invCount(id)
        pcall(f, id, math.min(left, 200))
        task.wait(0.7) -- game menolak drop yang terlalu cepat (0.3 dtk)
        local got = before - invCount(id)
        if got > 0 then
            left -= got
        elseif not flipped then
            -- di depan tembok / tidak boleh drop: hadap ke arah lain lalu coba lagi
            flipped = true
            local st = playerState()
            local right = st and (st.facing or 1) < 0
            AutoInput.active = true
            AutoInput.right, AutoInput.left = right, not right
            task.wait(0.06)
            AutoInput.right, AutoInput.left = false, false
            task.wait(0.3)
        else
            return n - left, "tidak bisa drop di posisi ini"
        end
    end
    return n - left, nil
end

-- Titik drop bersama (dipakai Pabrik, Farmer, Auto Farm):
-- pergi ke titik drop (bisa world lain / WORLD:ID), drop item, lalu pulang ke world asal.
-- items = { { id =, n = }, ... }  -> it.got diisi jumlah yang berhasil di-drop
-- Hasil: ok, alasan ("nopoint" | "home" | teks error)
-- (BUG 5: goWorld dibungkus pcall, dan seluruh trip dibungkus lagi di dropTrip di bawah,
--  jadi Pabrik.Traveling selalu kembali false walau ada error.)
local function dropTripRun(items, live, say)
    say = say or function() end
    local name, door = parseDropTarget()
    local home = Guard.worldName()
    if name == "" then name = home end
    if Pabrik.DropX < 0 and not door and name == home then
        say("Titik drop belum diatur (tab Titik Drop), drop dilewati")
        return false, "nopoint"
    end
    Pabrik.Traveling = true
    local mine = Pabrik.Running -- trip dari Pabrik: dicatat sebagai keluar OTOMATIS
    if mine then Pabrik.Exit, Pabrik.ExitWhy = "otomatis", "trip drop" end
    local away = name ~= home
    local ok, why = true, nil
    if away or door then
        say("Pergi ke " .. name .. (door and (":" .. door) or "") .. " untuk drop")
        local pc, r1, r2 = pcall(goWorld, name, door)
        local okw, err = pc and r1, (pc and r2) or (not pc and r1) or nil
        if not okw then ok, why = false, "gagal masuk " .. name .. " (" .. tostring(err) .. ")" end
    end
    if ok and live() and Pabrik.DropX >= 0 then
        say(("Jalan ke posisi drop (%d,%d)"):format(Pabrik.DropX, Pabrik.DropY))
        if not walkTo(Pabrik.DropX, Pabrik.DropY, 60) then ok, why = false, "tidak bisa jalan ke posisi drop" end
    end
    if ok and live() then
        local s = playerState()
        if s then Pabrik.Zone = { world = Guard.worldName(), x = s.x, y = s.y - 0.475 } end
        for _, it in ipairs(items) do
            if not live() then break end
            local got, err = dropItems(it.id, it.n, live)
            it.got = got
            if got > 0 then
                local msg = ("Drop %s x%d di %s"):format(itemName(it.id), got, Guard.worldName())
                say(msg)
                notify("Drop", msg, 4)
                Hook.send("pabrik", msg)
            end
            if err then
                ok, why = false, err
                break
            end
        end
    end
    if not ok then
        say("Drop gagal: " .. tostring(why))
        notify("Drop", "Drop gagal: " .. tostring(why), 5)
        Hook.send("pabrik", "Drop gagal: " .. tostring(why))
    end
    -- pulang ke world asal (juga kalau masuk pintu di world yang sama gagal dan karakter ada di luar)
    if home ~= "" and live() and (away or Guard.worldName() ~= home) then
        say("Pulang ke " .. home)
        local okh = false
        for try = 1, 4 do
            local pcH, rH = pcall(goWorld, home, nil)
            okh = pcH and rH == true
            if okh or not live() then break end
            if try < 4 then
                say(("Gagal pulang ke %s (%d/4), coba lagi"):format(home, try))
                task.wait(5 * try)
            end
        end
        if not okh and live() then
            -- Pabrik TIDAK di-stop: pabrikLoop masuk lagi sendiri (keluar otomatis)
            Pabrik.Traveling = false
            autoEnd()
            return false, "home"
        end
    end
    if mine and Pabrik.Running then Pabrik.Exit, Pabrik.ExitWhy = "-", nil end
    Pabrik.Traveling = false
    autoEnd()
    return ok, why
end

local function dropTrip(items, live, say)
    local okp, ok, why = pcall(dropTripRun, items, live, say)
    if okp then return ok, why end
    -- error tak terduga di tengah trip: Traveling WAJIB dibuka lagi supaya Pabrik tidak nyangkut.
    -- Kalau karakter masih di luar world pabrik, pabrikLoop masuk lagi sendiri (keluar otomatis).
    Pabrik.Traveling = false
    pcall(autoEnd)
    pcall(releaseInput)
    warn("[" .. NAME .. "] dropTrip error: " .. tostring(ok))
    pcall(notify, "Drop", "Drop gagal (error), dicoba lagi nanti", 5)
    pcall(Hook.send, "pabrik", "Drop gagal (error): " .. tostring(ok))
    return false, "error: " .. tostring(ok)
end
Auto.dropTrip = dropTrip

-- Titik drop sudah diatur? (posisi, WORLD:ID, atau world lain)
function Pabrik.pointSet()
    if Pabrik.DropX >= 0 then return true end
    local name, door = parseDropTarget()
    if door then return true end
    return name ~= "" and name ~= Guard.worldName()
end

---------------------------------------------------------------------
-- EKSPOR dari dalam fungsi gerak (variabel di sini lokal)
---------------------------------------------------------------------
Auto.stopWalk = function() Move.Homing = false end
Auto.here = function()
    local s = playerState()
    if s then return startNode(s) end
    return nil
end
Auto.findTreeRefs = findTreeRefs
Auto.releaseInput = releaseInput
Auto.BadEdge = BadEdge
Auto.resetReach = function() Reach = nil end
Auto.walkTo = walkTo
Auto.treeReadyAt = treeReadyAt
Auto.plantSpotOk = plantSpotOk
Auto.landRows = landRows
Auto.seedOfBlock = seedOfBlock
Auto.blockOfSeed = blockOfSeed
Auto.parseDropTarget = parseDropTarget

-- gerak
Engine.Move = Move
Engine.BadEdge = BadEdge
Engine.autoOn = autoOn
Engine.autoBegin = autoBegin
Engine.autoEnd = autoEnd
Engine.releaseInput = releaseInput
Engine.waitAuto = waitAuto
Engine.startNode = startNode
Engine.astar = astar
Engine.followPath = followPath
Engine.travelGroup = travelGroup
Engine.walkTo = walkTo
Engine.stopWalk = Auto.stopWalk
Engine.here = Auto.here
Engine.resetReach = Auto.resetReach
Engine.punchReach = punchReach
Engine.buildReach = buildReach
Engine.farmReach = farmReach
Engine.canWorkAt = canWorkAt
Engine.placeOk = placeOk
Engine.stateReaches = stateReaches
Engine.solidAt = solidAt
Engine.openAt = openAt
Engine.fgIdAt = fgIdAt
-- panen & tanam (mesin lahan)
Engine.fieldStep = fieldStep
Engine.setFC = function(cfg) FC = cfg end -- FC = pengaturan mesin yang dipakai fieldStep (dibuat pabrikCfg)
Engine.getFC = function() return FC end
Engine.farmerCfg = farmerCfg
Engine.treeReadyAt = treeReadyAt
Engine.plantSpotOk = plantSpotOk
Engine.findTreeRefs = findTreeRefs
Engine.readyTreeCount = readyTreeCount
Engine.landRows = landRows
Engine.landCols = landCols
Engine.inLandRect = inLandRect
Engine.landPlantSet = landPlantSet
Engine.seedOfBlock = seedOfBlock
Engine.blockOfSeed = blockOfSeed
-- pindah world & drop
Engine.goWorld = goWorld
Engine.dropItems = dropItems
Engine.dropTrip = dropTrip
Engine.parseDropTarget = parseDropTarget
end)() end -- do (gerak otomatis)

---------------------------------------------------------------------
-- EKSPOR (di luar fungsi gerak)
---------------------------------------------------------------------
Engine.State = State
Engine.Land = Land
Engine.Pabrik = Pabrik
Engine.Farmer = Farmer
Engine.Guard = Guard
Engine.Hook = Hook
Engine.Stats = Stats
Engine.Drops = Drops
Engine.Anim = Anim
Engine.Auto = Auto
Engine.AutoInput = AutoInput
Engine.HitCount = HitCount
Engine.PlacedAt = PlacedAt
Engine.DropFailUntil = DropFailUntil
-- bendera fitur lain (kosong, lihat catatan di atas)
Engine.Clear, Engine.Splice, Engine.Build, Engine.Vend = Clear, Splice, Build, Vend
-- place & pukul
Engine.tileAt = tileAt
Engine.getPlayerTile = getPlayerTile
Engine.sendSetTile = sendSetTile
Engine.tryPlace = tryPlace
Engine.tryBreak = tryBreak
Engine.breakableAt = breakableAt
Engine.canBreak = canBreak
-- Auto Farm (place + break di tile Grid / Override)
Engine.farmLoop = farmLoop
Engine.startFarm = startFarm
Engine.stopFarm = stopFarm
Engine.waitMs = waitMs
Engine.updateStatus = updateStatus
-- drop (auto collect)
Engine.findDropRefs = findDropRefs
Engine.waitNearDrops = waitNearDrops
Engine.waitTileDrops = waitTileDrops

---------------------------------------------------------------------
-- HUBUNGKAN: data tambahan yang tidak dicari tahap 1 (daftar drop, data pohon, animasi tangan)
-- Dijalankan otomatis begitu Refs.World ada, dan lagi tiap tombol "Hubungkan ke game" ditekan
-- (findRefs mengosongkan Refs, penanda Refs.EngineOk ikut hilang -> engine menghubungkan ulang).
---------------------------------------------------------------------
function Engine.connect()
    Refs.EngineOk = true -- dipasang dulu: kalau ada error, tidak diulang tiap detik
    if Refs.World then
        pcall(findDropRefs, true)
        pcall(Auto.findTreeRefs)
    end
    table.clear(DropFailUntil)
    Anim.fn, Anim.idx = nil, nil
    pcall(Anim.findFast)
    Auto.resetReach()
    return true
end

task.spawn(function()
    while engineAlive() do
        if Refs.World and not Refs.EngineOk then
            local ok, err = pcall(Engine.connect)
            if not ok then warn("[" .. NAME .. "] Engine.connect: " .. tostring(err)) end
        end
        task.wait(1)
    end
end)

---------------------------------------------------------------------
-- PENGATURAN TERSIMPAN (config)
---------------------------------------------------------------------
Config.add("Farm", State, { "PlaceMs", "BreakMs", "AfterBreakMs", "MultiTarget", "MutePunch", "Visual", "CollectMode", "CollectRadius" })
Config.add("Farmer", Farmer, { "HarvestMs", "PlantMs" })
Config.add("Lahan", Land, { "X0", "X1", "Y0" })
Config.add("Discord", Hook, { "On", "Url", "Penjaga", "Stop", "Full", "Bonus", "Rejoin", "Pabrik", "ReportMin" })
-- game memberi jeda minimal antar aksi (place ~0.135 dtk, pukul ~0.19 dtk)
State.PlaceMs = math.max(State.PlaceMs, 140)
State.BreakMs = math.max(State.BreakMs, 200)
Farmer.HarvestMs = math.max(Farmer.HarvestMs, 140)
Farmer.PlantMs = math.max(Farmer.PlantMs, 140)

---------------------------------------------------------------------
-- CLEANUP (dipanggil Session.Cleanup tahap 1 saat script dijalankan ulang)
---------------------------------------------------------------------
function Engine.Cleanup()
    State.Running = false
    State.Override = nil
    State.Quiet = false
    Pabrik.Running = false
    Pabrik.Traveling = false
    if Engine.Move then Engine.Move.Homing = false end
    AutoInput.active = false
    if Engine.releaseInput then pcall(Engine.releaseInput) end
    if OrigIsDown and MenuModOk and rawget(MenuModule, "isDown") == isDownWrapper then
        MenuModule.isDown = OrigIsDown
    end
    Engine.Dead = true
end

do
    local base = Session.EngineBaseCleanup or Session.Cleanup
    Session.EngineBaseCleanup = base
    Session.Cleanup = function()
        pcall(Engine.Cleanup)
        if base then base() end
    end
end

Engine.ready = true
API.Engine = Engine

end)() end

-- ======================= pabrik.lua =======================
do (function()
-- YutiCapital v1.0 | Tahap 2B: pabrik.lua
-- Isi: modul Pabrik (break -> tanam -> panen -> break lagi, seed lebihan di-drop) + tab UI Pabrik.
-- Jalankan SETELAH yuticapital.lua dan engine.lua. Mesin gerak / panen / drop dipakai dari API.Engine
-- (tidak disalin ulang). Logika Pabrik disalin dari script lama (Kzoyz x Opus), nama fungsi sama.

local G = (getgenv and getgenv()) or _G
local Session = G.__YutiCapital
local API = Session and Session.API
if not API then
    warn("[YutiCapital] pabrik.lua: jalankan yuticapital.lua dulu")
    return
end
local Engine = API.Engine
if not (Engine and Engine.ready) then
    warn("[YutiCapital] pabrik.lua: jalankan engine.lua dulu")
    return
end
-- pabrik.lua lama (kalau dijalankan ulang): tutup dulu supaya loop & thread lama berhenti
if API.PabrikMod and API.PabrikMod.Cleanup then pcall(API.PabrikMod.Cleanup) end
local Mod = { Dead = false }
API.PabrikMod = Mod

local alive = API.alive
local NAME = API.Name
-- hidup = script masih jalan, pabrik.lua ini belum diganti yang baru, dan engine yang dipakai belum ditutup
local function pabrikAlive() return alive() and not Mod.Dead and not Engine.Dead end

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

---------------------------------------------------------------------
-- BAGIAN DARI tahap 1 & engine (dipakai apa adanya)
---------------------------------------------------------------------
local Refs = API.Refs
local UI = API.UI
local Config = API.Config
local notify = API.notify
local itemName = API.itemName
local invCount = API.invCount
local playerState = API.playerState
local ItemDB = API.ItemDB

local State = Engine.State
local Pabrik = Engine.Pabrik
local Farmer = Engine.Farmer
local Guard = Engine.Guard
local Hook = Engine.Hook
local Auto = Engine.Auto
local Drops = Engine.Drops
local BadEdge = Engine.BadEdge
local HitCount = Engine.HitCount
local PlacedAt = Engine.PlacedAt

local fieldStep = Engine.fieldStep
local setFC = Engine.setFC
local walkTo = Engine.walkTo
local farmLoop = Engine.farmLoop
local stopFarm = Engine.stopFarm
local dropTrip = Engine.dropTrip
local goWorld = Engine.goWorld
local autoBegin = Engine.autoBegin
local autoEnd = Engine.autoEnd
local releaseInput = Engine.releaseInput
local waitAuto = Engine.waitAuto
local startNode = Engine.startNode
local readyTreeCount = Engine.readyTreeCount
local landRows = Engine.landRows
local landPlantSet = Engine.landPlantSet
local inLandRect = Engine.inLandRect
local blockOfSeed = Engine.blockOfSeed
local resetReach = Engine.resetReach
local findTreeRefs = Engine.findTreeRefs
local parseDropTarget = Engine.parseDropTarget

local BOOT_SEEDS = 10 -- (mode produksi) cukup seed segini untuk mulai tanam
local CAP = 190       -- batas aman jumlah item (maksimal 200 per item)
local OUT_WAIT = 8    -- keluar OTOMATIS: tunggu sekian detik dulu sebelum masuk lagi sendiri
local DROP_MAX = CAP - 20 -- batas atas "drop kalau seed sudah": drop harus terjadi sebelum panen berhenti (seed >= CAP - 20)

---------------------------------------------------------------------
-- BATAS DROP (BUG: DropAt 200 > CAP 190 tidak pernah tercapai; Keep >= DropAt = drop 0)
---------------------------------------------------------------------
-- DropAt dibatasi 2..CAP-20 (170). Keep dipaksa 0..DropAt-1 (selalu ada yang di-drop).
local function normalizeDrop()
    local at = math.floor(tonumber(Pabrik.DropAt) or DROP_MAX)
    at = math.min(at, DROP_MAX)
    at = math.max(at, 2)
    Pabrik.DropAt = at
    local keep = math.floor(tonumber(Pabrik.Keep) or 0)
    keep = math.max(0, math.min(keep, at - 1))
    Pabrik.Keep = keep
end
normalizeDrop() -- default engine (DropAt 200) -> 170

-- Setelan tersimpan (Config.add memuat nilai lama, jadi batasi lagi sesudahnya)
Config.add("Pabrik", Pabrik, {
    "SeedId", "WholeWorld", "Tiles", "BreakX", "BreakY",
    "Drop", "Keep", "DropAt", "DropWorld", "DropX", "DropY",
})
normalizeDrop() -- config lama bisa menyimpan DropAt 200 / Keep >= DropAt

---------------------------------------------------------------------
-- PABRIK
---------------------------------------------------------------------
local function pabrikCfg(o, harvest, plant)
    local plantSet, area = nil, nil
    if not o.whole then
        plantSet = landPlantSet()
        area = inLandRect
    end
    return {
        run = o.live,
        harvest = harvest,
        plant = plant and invCount(o.seed) > 0,
        seed = o.seed,
        skip = Pabrik.Skip,
        hms = Farmer.HarvestMs,
        pms = Farmer.PlantMs,
        area = area,
        plantSet = plantSet,
        exclude = o.exclude,
        row = Pabrik.Row,
        collect = true,
        status = function(t) Pabrik.Status = t end,
        onHarvest = function() Pabrik.Harvested += 1 end,
        onPlant = function() Pabrik.Planted += 1 end,
    }
end

-- Break block di posisi pabrik (pakai Auto Farm dengan tile & block pabrik)
local function pabrikBreak(o)
    if os.clock() < (Pabrik.BreakFailUntil or 0) then return false end
    local s = playerState()
    if not s then return false end
    local hx, hy = startNode(s)
    if hx ~= Pabrik.BreakX or hy ~= Pabrik.BreakY then
        Pabrik.Status = ("Jalan ke posisi break (%d,%d)"):format(Pabrik.BreakX, Pabrik.BreakY)
        if not walkTo(Pabrik.BreakX, Pabrik.BreakY, 45) then
            Pabrik.Status = "Gagal jalan ke posisi break, dicoba lagi nanti"
            Pabrik.BreakFailUntil = os.clock() + 30
            return false
        end
    end
    if not o.live() then return false end
    State.Override = { offsets = Pabrik.Tiles, block = o.block, mode = "Place + Break" }
    State.Quiet = true
    table.clear(HitCount)
    table.clear(PlacedAt)
    State.Running = true
    State.RunId = (State.RunId or 0) + 1
    local id = State.RunId
    local acts0 = State.Placed + State.Broken
    local lastActs, lastActAt = acts0, os.clock()
    task.spawn(function() -- pengawas sesi break
        while State.Running and State.RunId == id do
            task.wait(1)
            local sd = invCount(o.seed)
            local acts = State.Placed + State.Broken
            if acts ~= lastActs then lastActs, lastActAt = acts, os.clock() end
            -- break terus sampai block habis (tanpa batas waktu sesi)
            if not o.live() or sd >= CAP
                or (o.drop and Pabrik.Drop and sd >= Pabrik.DropAt)
                or (o.breakMode ~= "always" and sd >= BOOT_SEEDS)
                or os.clock() - lastActAt > 8 then -- 8 detik tidak ada place / pukul: jangan diam di sini
                State.Running = false
            end
        end
    end)
    Pabrik.Status = "Break " .. itemName(o.block) .. " di posisi pabrik"
    local ok, e = pcall(farmLoop, id)
    if not ok then warn("[" .. NAME .. "] Pabrik break error: " .. tostring(e)) end
    State.Running = false
    State.Override = nil
    State.Quiet = false
    -- tanpa aksi karena seed sudah cukup untuk di-drop / tas penuh BUKAN kegagalan break
    local sd = invCount(o.seed)
    if State.Placed + State.Broken == acts0 and invCount(o.block) > 0
        and sd < Pabrik.DropAt and sd < CAP then
        Pabrik.BreakFailUntil = os.clock() + 60
        Pabrik.Status = "Sesi break tanpa aksi: cek posisi & tile break (dicoba lagi 1 menit)"
    end
    return true
end

local function pabrikDrop(seed, n, live)
    local items = { { id = seed, n = n } }
    local ok, why = dropTrip(items, live, function(t) Pabrik.Status = t end)
    Pabrik.Dropped += items[1].got or 0
    if ok == true then Pabrik.BreakFailUntil = 0 end -- drop berhasil: break boleh jalan lagi
    if why == "home" then
        -- tidak di-stop: pabrikLoop masuk lagi sendiri (kategori keluar otomatis)
        Pabrik.Status = "Gagal pulang ke world pabrik " .. tostring(Pabrik.Home) .. ", mencoba lagi..."
        notify("Pabrik", "Gagal pulang, masuk lagi otomatis", 5)
    elseif not ok then
        Pabrik.DropOffUntil = os.clock() + ((why == "nopoint") and 60 or 120)
    end
end

local PHASE_NAME = { panen = "PANEN", tanam = "TANAM", ["break"] = "BREAK", tunggu = "TUNGGU" }

local function breakReady()
    return Pabrik.BreakX >= 0 and next(Pabrik.Tiles) ~= nil and os.clock() >= (Pabrik.BreakFailUntil or 0)
end

-- 1 langkah pabrik. o = { seed, block, drop, breakMode, whole, exclude, live, phase }
-- Hasil: "drop" | "work" | "move" | "wait" | "break" | "next" | "idle" (+ detik ke pohon siap)
local function pabrikStep(o)
    normalizeDrop() -- setelan bisa berubah kapan saja (config / slider)
    local seeds, blocks = invCount(o.seed), invCount(o.block)
    o.phase = o.phase or "panen"
    Pabrik.Phase = PHASE_NAME[o.phase]
    -- drop seed lebihan (kapan saja)
    if o.drop and Pabrik.Drop and seeds >= Pabrik.DropAt and seeds > Pabrik.Keep
        and os.clock() >= (Pabrik.DropOffUntil or 0) then
        pabrikDrop(o.seed, seeds - Pabrik.Keep, o.live)
        return "drop"
    end

    if o.phase == "panen" then
        -- 1x panen bisa kena beberapa pohon, jadi sisakan ruang ~20 item
        if blocks >= CAP - 20 or seeds >= CAP - 20 then
            o.idleAt = os.clock() -- fase tunggu tidak boleh balik ke panen sebelum 5 detik
            o.phase = "tanam"
            return "next"
        end
        setFC(pabrikCfg(o, true, false))
        local r = fieldStep()
        if r == "idle" then
            o.idleAt = os.clock()
            o.phase = "tanam"
            return "next"
        end
        return r
    end

    if o.phase == "tanam" then
        if seeds > 0 then
            setFC(pabrikCfg(o, false, true))
            local r = fieldStep()
            if r ~= "idle" then return r end
        end
        o.phase = "break"
        return "next"
    end

    if o.phase == "break" then
        local want
        if o.breakMode == "always" then
            want = blocks > 0
        else -- mode produksi: break hanya untuk dapat seed awal
            local _, nxt = readyTreeCount(o.whole)
            want = blocks > 0 and seeds < BOOT_SEEDS and nxt == nil
        end
        if want and breakReady() and pabrikBreak(o) then
            -- block masih ada: lanjut break (habiskan dulu), block habis: tanam
            o.phase = (o.breakMode == "always" and invCount(o.block) > 0) and "break" or "tanam"
            return "break"
        end
        o.phase = "tunggu"
        return "next"
    end

    -- tunggu
    local n, nxt = readyTreeCount(o.whole)
    if n > 0 and os.clock() - (o.idleAt or 0) > 5 then
        o.phase = "panen"
        return "next"
    end
    if o.breakMode == "always" and blocks > 0 and breakReady() then
        o.phase = "break"
        return "next"
    end
    if seeds > 0 and os.clock() - (o.plantAt or 0) > 10 then
        o.plantAt = os.clock() -- sesekali cek tile kosong (misal pohon dipanen orang lain)
        o.phase = "tanam"
        return "next"
    end
    return "idle", nxt, n
end

local function waitText(sec)
    sec = math.max(0, math.ceil(sec or 0))
    if sec >= 60 then return ("%dm %dd"):format(sec // 60, sec % 60) end
    return sec .. " dtk"
end

-- Jeda sebelum masuk world pabrik lagi: 10 dtk, naik x1.25 tiap percobaan, maksimal 60 dtk
local function rejoinDelay(tries)
    return math.min(60, 10 * 1.25 ^ (math.max(tries, 1) - 1))
end

local function pabrikLoop(runId)
    local function live() return Pabrik.Running and pabrikAlive() and Pabrik.RunId == runId end
    local o = { seed = Pabrik.SeedId, block = Pabrik.BlockId, drop = true, breakMode = "always", live = live }
    while live() do
        task.wait()
        o.whole = Pabrik.WholeWorld
        local here = Guard.worldName()
        if not Pabrik.Traveling and Pabrik.Home ~= "" and here ~= Pabrik.Home then
            -- Di luar world pabrik. Dua kategori keluar:
            --   PENJAGA : Penjaga yang men-stop Pabrik lalu mengatur masuk lagi + lanjut
            --             (Pabrik.Running sudah mati, loop ini tidak sampai ke sini).
            --   OTOMATIS: trip drop gagal pulang / dilempar server / terputus -> masuk lagi
            --             sendiri, dicoba terus dengan jeda makin lama (tidak berhenti sendiri).
            if Guard.Mode ~= "idle" then
                Pabrik.Status = "Penjaga mengatur keluar / masuk world..."
                task.wait(1)
                continue
            end
            local now = os.clock()
            if not o.outAt then
                o.outAt, o.tries, o.retryAt = now, 0, now + OUT_WAIT
                Pabrik.Exit = "otomatis"
                Pabrik.ExitWhy = Pabrik.ExitWhy or "keluar dari world"
                Hook.send("pabrik", "Keluar world (otomatis: " .. Pabrik.ExitWhy .. "), masuk lagi ke " .. Pabrik.Home)
            end
            if (Auto.rejoinBusy and Auto.rejoinBusy()) or now < o.retryAt then
                Pabrik.Status = ("Di luar world pabrik (%s), masuk lagi %d dtk"):format(
                    Pabrik.Home, math.max(0, math.ceil(o.retryAt - now)))
                task.wait(1)
                continue
            end
            o.tries += 1
            Pabrik.Traveling = true
            Pabrik.Status = ("Masuk lagi ke %s (percobaan %d)"):format(Pabrik.Home, o.tries)
            local pc, r1, r2 = pcall(goWorld, Pabrik.Home, nil)
            Pabrik.Traveling = false
            local okw, err = pc and r1, (pc and r2) or (not pc and r1) or nil
            if not okw then
                local wait = rejoinDelay(o.tries)
                o.retryAt = os.clock() + wait
                Pabrik.Status = ("Gagal masuk %s (%s), coba lagi %d dtk"):format(
                    Pabrik.Home, tostring(err or "?"), math.ceil(wait))
                if o.tries == 1 or o.tries % 5 == 0 then
                    notify("Pabrik", "Gagal masuk lagi ke " .. Pabrik.Home .. " (percobaan " .. o.tries .. ")", 4)
                end
            end
            continue
        end
        if o.outAt then
            -- sudah di world pabrik lagi (masuk sendiri atau manual): segarkan data, lanjut dari awal
            o.outAt = nil
            pcall(Guard.afterEnter)
            table.clear(Pabrik.Skip)
            table.clear(Pabrik.Row)
            table.clear(BadEdge)
            resetReach()
            Pabrik.BreakFailUntil, Pabrik.DropOffUntil = 0, 0
            o.phase = "panen"
            Pabrik.Exit, Pabrik.ExitWhy = "-", nil
            Pabrik.Status = "Sudah di world pabrik, lanjut"
            Hook.send("pabrik", "Sudah di world " .. Pabrik.Home .. ", Pabrik lanjut")
        end
        local r, nextReady, nReady = pabrikStep(o)
        if r ~= "idle" then o.stuckAt = nil end
        if r == "idle" then
            local seeds, blocks = invCount(o.seed), invCount(o.block)
            if not nextReady and (nReady or 0) == 0 and seeds <= 0 and blocks <= 0 then
                if Pabrik.stop then Pabrik.stop("Seed & block habis, tidak ada pohon tumbuh") end
                break
            end
            if (nReady or 0) > 0 then
                -- ada pohon siap tapi tidak terjangkau: lama-lama reset daftar lewati & jalur
                o.stuckAt = o.stuckAt or os.clock()
                if os.clock() - o.stuckAt > 30 then
                    o.stuckAt = nil
                    table.clear(Pabrik.Skip)
                    table.clear(BadEdge)
                    resetReach()
                end
            end
            if seeds >= CAP - 20 and not (Pabrik.Drop and Pabrik.pointSet()) then
                Pabrik.Status = ("Seed hampir penuh (%d): atur titik drop & nyalakan Auto drop seed"):format(seeds)
            elseif (nReady or 0) > 0 then
                Pabrik.Status = nReady .. " pohon siap belum terjangkau, dicoba lagi"
            elseif nextReady then
                Pabrik.Status = "Menunggu pohon siap ±" .. waitText(nextReady)
            elseif blocks > 0 and (Pabrik.BreakX < 0 or next(Pabrik.Tiles) == nil) then
                Pabrik.Status = "Ada block tapi posisi / tile break belum diatur"
            elseif seeds > 0 then
                Pabrik.Status = "Lahan penuh, menunggu"
            else
                Pabrik.Status = "Menunggu..."
            end
            if not waitAuto(1000) then break end
        end
    end
    releaseInput()
end

function Pabrik.stop(reason)
    Pabrik.Running = false
    Pabrik.Traveling = false
    if Pabrik.Exit == "otomatis" then Pabrik.Exit, Pabrik.ExitWhy = "-", nil end
    if State.Override then State.Running = false end
    autoEnd()
    releaseInput()
    Pabrik.Status = reason or "Dihentikan"
    if UI.PabrikToggle then pcall(function() UI.PabrikToggle:Set(false) end) end
    if reason then
        notify("Pabrik", reason, 5)
        if not string.find(reason, "^Dihentikan") then Hook.send("pabrik", "Pabrik berhenti: " .. reason) end
    end
end

-- Kontrol gerak game (WorldMenu.isDown) ada? (engine yang membungkusnya; modul game yang sama)
local function moveControlOk()
    local ok, res = pcall(function()
        local gui = LocalPlayer.PlayerGui:FindFirstChild("GameGui")
        local menu = gui and gui:FindFirstChild("WorldMenu")
        if not menu then return false end
        local m = require(menu)
        return type(m) == "table" and type(rawget(m, "isDown")) == "function"
    end)
    return ok and res == true
end

function Pabrik.start()
    if Pabrik.Running then return end
    normalizeDrop()
    -- engine tidak mencoba ulang sendiri: kalau daftar drop / data pohon belum ketemu, hubungkan ulang dulu
    if (not Drops.list or not Refs.Trees) and type(API.reconnect) == "function" then
        pcall(API.reconnect)
    end
    local err
    local block = blockOfSeed(Pabrik.SeedId)
    if not Refs.World then
        err = "Data world belum ketemu. Tekan 'Hubungkan ke game'"
    elseif not moveControlOk() then
        err = "Kontrol gerak game (WorldMenu.isDown) tidak ketemu"
    elseif not playerState() then
        err = "Kamu belum masuk world"
    elseif not Pabrik.SeedId then
        err = "Pilih seed pabrik dulu"
    elseif not block then
        err = "Block dari seed ini tidak ketemu"
    elseif not Pabrik.WholeWorld and #landRows() == 0 then
        err = "Atur lahan dulu (tab Lahan)"
    end
    if err then
        notify("Pabrik", err, 4)
        if UI.PabrikToggle then pcall(function() UI.PabrikToggle:Set(false) end) end
        return
    end
    if State.Running and not State.Override then stopFarm("Dihentikan karena Pabrik dimulai") end
    if not Refs.Trees then pcall(findTreeRefs) end
    Pabrik.BlockId = block
    Pabrik.Home = Guard.worldName()
    Pabrik.Exit, Pabrik.ExitWhy = "-", nil
    table.clear(Pabrik.Skip)
    table.clear(Pabrik.Row)
    table.clear(BadEdge)
    Pabrik.DropOffUntil, Pabrik.BreakFailUntil = 0, 0
    Pabrik.Running = true
    Pabrik.RunId = (Pabrik.RunId or 0) + 1
    Pabrik.Status = "Mulai..."
    autoBegin()
    if UI.PabrikToggle then pcall(function() UI.PabrikToggle:Set(true) end) end
    local id = Pabrik.RunId
    task.spawn(function()
        local ok, e = pcall(pabrikLoop, id)
        if not ok then
            warn("[" .. NAME .. "] Pabrik error: " .. tostring(e))
            if Pabrik.Running then Pabrik.stop("Error: " .. tostring(e)) end
        end
    end)
end

---------------------------------------------------------------------
-- TAB UI: PABRIK
---------------------------------------------------------------------
local function safe(fn)
    local ok, err = pcall(fn)
    if not ok then warn("[" .. NAME .. "] UI error: " .. tostring(err)) end
end

-- Angka pakai Slider; kalau gagal, pakai kotak input
local function addNumber(tab, o)
    local ok = pcall(function()
        tab:Slider({
            Title = o.Title,
            Desc = o.Desc,
            Step = o.Step or 1,
            Value = { Min = o.Min, Max = o.Max, Default = o.Default },
            Callback = function(v)
                v = tonumber(v)
                if v then o.Callback(v) end
            end,
        })
    end)
    if ok then return end
    safe(function()
        tab:Input({
            Title = o.Title,
            Desc = (o.Desc and (o.Desc .. " ") or "") .. "(" .. o.Min .. "-" .. o.Max .. ")",
            Value = tostring(o.Default),
            Placeholder = tostring(o.Default),
            Callback = function(text)
                local v = tonumber(text)
                if v then o.Callback(math.clamp(v, o.Min, o.Max)) end
            end,
        })
    end)
end

-- Seed di inventori
local function seedIds()
    local ids = {}
    if Refs.Inv then
        for _, slot in ipairs(Refs.Inv.slots) do
            local it = slot.id and ItemDB[slot.id]
            if it and it.kind == "seed" and (slot.n or 0) > 0 then
                ids[#ids + 1] = slot.id
            end
        end
    end
    table.sort(ids)
    return ids
end

do
    local PTab = API.makeTab("Pabrik", "factory", "farm")

    safe(function()
        UI.PabrikStatus = PTab:Paragraph({ Title = "Status Pabrik", Desc = "-" })
    end)

    local pCtl = API.box(PTab, "Kontrol", true)
    local pBreak = API.box(PTab, "Posisi & tile break", true)
    local pDrop = API.box(PTab, "Drop seed", true)

    safe(function()
        UI.PabrikToggle = pCtl:Toggle({
            Title = "Jalankan Pabrik",
            Desc = "Break -> tanam -> panen -> break lagi, seed lebihan di-drop",
            Value = false,
            Callback = function(on)
                if on then Pabrik.start() elseif Pabrik.Running then Pabrik.stop() end
            end,
        })
    end)

    safe(function()
        UI.PabrikSeedDropdown = pCtl:Dropdown({
            Title = "Seed pabrik",
            Desc = "Block-nya otomatis (contoh: Dirt Seed -> Dirt)",
            Values = { "(memuat...)" },
            Callback = function(opt)
                local id = tonumber(string.match(opt or "", "%[(%d+)%]$"))
                if id then Pabrik.SeedId = id end
            end,
        })
    end)

    safe(function()
        pCtl:Toggle({
            Title = "Tanam di seluruh world",
            Desc = "Mati = hanya di lahan (tab Lahan)",
            Value = Pabrik.WholeWorld,
            Callback = function(on) Pabrik.WholeWorld = on end,
        })
    end)

    safe(function()
        pBreak:Button({
            Title = "Pakai posisi sekarang untuk break",
            Desc = "Berdiri di tempat break, lalu tekan",
            Callback = function()
                local x, y = Engine.here()
                if not x then
                    notify("Pabrik", "Kamu belum masuk world", 3)
                    return
                end
                Pabrik.BreakX, Pabrik.BreakY = x, y
                notify("Pabrik", ("Posisi break (%d,%d)"):format(x, y), 3)
            end,
        })
    end)

    safe(function()
        pBreak:Button({
            Title = "Pilih tile break (Grid)",
            Desc = "Grid terbuka dalam mode Pabrik (terpisah dari tile Auto Farm)",
            Callback = function()
                if UI.setGridMode then
                    UI.setGridMode("pabrik")
                    if UI.GridGui then UI.GridGui.Enabled = true end
                else
                    notify("Pabrik", "Grid tile belum tersedia di versi ini", 4)
                end
            end,
        })
    end)

    safe(function()
        pDrop:Toggle({
            Title = "Auto drop seed",
            Desc = "Ke titik drop (tab Titik Drop)",
            Value = Pabrik.Drop,
            Callback = function(on) Pabrik.Drop = on end,
        })
    end)

    addNumber(pDrop, {
        Title = "Sisakan seed",
        Desc = "Untuk ditanam lagi. Selalu lebih kecil dari batas drop",
        Min = 0, Max = DROP_MAX - 1, Step = 1, Default = Pabrik.Keep,
        Callback = function(v)
            Pabrik.Keep = math.floor(v)
            normalizeDrop() -- paksa Keep < DropAt
        end,
    })

    addNumber(pDrop, {
        Title = "Drop kalau seed sudah",
        Desc = ("Maksimal %d. Contoh %d & sisakan 50 = drop %d"):format(DROP_MAX, DROP_MAX, DROP_MAX - 50),
        Min = 2, Max = DROP_MAX, Step = 1, Default = Pabrik.DropAt,
        Callback = function(v)
            Pabrik.DropAt = math.floor(v)
            normalizeDrop() -- Keep ikut turun kalau sekarang >= DropAt
        end,
    })

    local function countKeys(t)
        local n = 0
        for _ in pairs(t) do n += 1 end
        return n
    end

    -- Dropdown seed: di-refresh hanya kalau daftar seed berubah
    task.spawn(function()
        local lastSig
        while pabrikAlive() do
            local dd = UI.PabrikSeedDropdown
            if dd then
                local ids = seedIds()
                local sig = table.concat(ids, ",")
                if sig ~= lastSig then
                    lastSig = sig
                    local labels = {}
                    for _, id in ipairs(ids) do
                        labels[#labels + 1] = string.format("%s [%d]", itemName(id), id)
                    end
                    if #labels == 0 then labels = { "(tidak ada seed di inventori)" } end
                    pcall(function() dd:Refresh(labels) end)
                    if Pabrik.SeedId then
                        local want = "[" .. tostring(Pabrik.SeedId) .. "]"
                        for _, label in ipairs(labels) do
                            if string.sub(label, -#want) == want then
                                pcall(function() dd:Select(label) end)
                                break
                            end
                        end
                    end
                end
            end
            task.wait(2)
        end
    end)

    task.spawn(function()
        while pabrikAlive() do
            local seed, block = Pabrik.SeedId, blockOfSeed(Pabrik.SeedId)
            local name, door = parseDropTarget()
            local dropAt = (name ~= "" and name or "world ini") .. (door and (" pintu " .. door) or "")
                .. (Pabrik.DropX >= 0 and (" (" .. Pabrik.DropX .. "," .. Pabrik.DropY .. ")") or "")
            local txt = table.concat({
                "Status : " .. (Pabrik.Running and ("JALAN - fase " .. tostring(Pabrik.Phase or "-")) or "BERHENTI"),
                ("Seed   : %s x%d | block %s x%d"):format(seed and itemName(seed) or "-", seed and invCount(seed) or 0,
                    block and itemName(block) or "-", block and invCount(block) or 0),
                ("Break  : %s | tile %d"):format(Pabrik.BreakX >= 0 and ("(" .. Pabrik.BreakX .. "," .. Pabrik.BreakY .. ")")
                    or "belum diatur", countKeys(Pabrik.Tiles)),
                ("Drop   : %s | sisakan %d, drop saat >= %d"):format(Pabrik.Drop and dropAt or "mati", Pabrik.Keep, Pabrik.DropAt),
                ("Hasil  : panen %d | tanam %d | di-drop %d"):format(Pabrik.Harvested, Pabrik.Planted, Pabrik.Dropped),
                "Keluar : " .. ((Pabrik.Exit == "penjaga" and ("Penjaga - " .. tostring(Pabrik.ExitWhy or "-")))
                    or (Pabrik.Exit == "otomatis" and ("Otomatis - " .. tostring(Pabrik.ExitWhy or "-")))
                    or "-"),
                "Aksi   : " .. Pabrik.Status,
            }, "\n")
            if UI.PabrikStatus and txt ~= Pabrik.Shown then
                Pabrik.Shown = txt
                pcall(function() UI.PabrikStatus:SetDesc(txt) end)
            end
            -- tombol START di Grid (mode pabrik), kalau Grid ada
            if UI.GridMode == "pabrik" and UI.GridStart then
                local T = (API.I18N and API.I18N.T) or function(s) return s end
                UI.GridStart.Text = T(Pabrik.Running and "STOP PABRIK" or "START PABRIK")
                UI.GridStart.BackgroundColor3 = Pabrik.Running and Color3.fromRGB(200, 60, 60) or Color3.fromRGB(46, 160, 90)
            end
            task.wait(1)
        end
    end)
end

---------------------------------------------------------------------
-- CLEANUP (dipanggil Session.Cleanup saat script dijalankan ulang, dan oleh pabrik.lua baru)
---------------------------------------------------------------------
function Mod.Cleanup()
    Mod.Dead = true
    Pabrik.Running = false
    Pabrik.Traveling = false
    if State.Override then
        State.Running = false
        State.Override = nil
        State.Quiet = false
    end
end

do
    local base = Session.PabrikBaseCleanup or Session.Cleanup
    Session.PabrikBaseCleanup = base
    Session.Cleanup = function()
        pcall(Mod.Cleanup)
        if base then base() end
    end
end

Mod.ready = true

end)() end

-- ======================= ui_extra.lua =======================
do (function()
-- YutiCapital v1.0 | Tahap 2C: ui_extra.lua
-- Isi: Grid tile 5x5 (hanya mode "pabrik"), tab Lahan, tab Titik Drop, tab Discord.
-- Jalankan SETELAH yuticapital.lua, engine.lua, dan pabrik.lua. Logika & nama disalin dari script lama
-- (Kzoyz x Opus). Setelan Lahan / Discord sudah didaftarkan Config.add di engine.lua, tidak didaftarkan lagi.

local G = (getgenv and getgenv()) or _G
local Session = G.__YutiCapital
local API = Session and Session.API
if not API then
    warn("[YutiCapital] ui_extra.lua: jalankan yuticapital.lua dulu")
    return
end
local Engine = API.Engine
if not (Engine and Engine.ready) then
    warn("[YutiCapital] ui_extra.lua: jalankan engine.lua dulu")
    return
end
if not (API.PabrikMod and API.PabrikMod.ready) then
    warn("[YutiCapital] ui_extra.lua: jalankan pabrik.lua dulu")
    return
end
if type(API.makeTab) ~= "function" or type(API.box) ~= "function" then
    warn("[YutiCapital] ui_extra.lua: API.makeTab / API.box tidak ada")
    return
end
-- ui_extra.lua lama (kalau dijalankan ulang): tutup dulu supaya GUI & thread lama hilang
if API.UiExtra and API.UiExtra.Cleanup then pcall(API.UiExtra.Cleanup) end
local Mod = { Dead = false, Conns = {} }
API.UiExtra = Mod

local alive = API.alive
local NAME = API.Name
-- hidup = script masih jalan, ui_extra.lua ini belum diganti yang baru, dan engine yang dipakai belum ditutup
local function uiAlive() return alive() and not Mod.Dead and not Engine.Dead end

local UserInputService = game:GetService("UserInputService")

---------------------------------------------------------------------
-- BAGIAN DARI tahap 1 & engine (dipakai apa adanya)
---------------------------------------------------------------------
local UI = API.UI
local notify = API.notify
local invCount = API.invCount

local State = Engine.State
local Pabrik = Engine.Pabrik
local Farmer = Engine.Farmer
local Land = Engine.Land
local Guard = Engine.Guard
local Hook = Engine.Hook
local getPlayerTile = Engine.getPlayerTile
local updateStatus = Engine.updateStatus

local function safe(fn)
    local ok, err = pcall(fn)
    if not ok then warn("[" .. NAME .. "] UI error: " .. tostring(err)) end
end

-- teks menu: lewat terjemahan tahap 1 kalau ada
local function T(s)
    local i = API.I18N
    if i and type(i.T) == "function" then
        local ok, r = pcall(i.T, s)
        if ok and r then return r end
    end
    return s
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---------------------------------------------------------------------
-- GUI TAMBAHAN: Grid Tile 5x5 (mode pabrik saja)
---------------------------------------------------------------------
local guiParent = (gethui and gethui()) or game:GetService("CoreGui")

local function newScreenGui(name)
    local sg = Instance.new("ScreenGui")
    sg.Name = name
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.DisplayOrder = 999
    sg.Enabled = false
    if syn and syn.protect_gui then pcall(syn.protect_gui, sg) end
    sg.Parent = guiParent
    return sg
end

local GRID_RADIUS = 2
local CELL = 38
local GAP = 4

local GridGui = newScreenGui("YutiGrid")
UI.GridGui = GridGui

local side = GRID_RADIUS * 2 + 1
local gridSize = side * CELL + (side - 1) * GAP

local Panel = Instance.new("Frame")
Panel.Size = UDim2.fromOffset(gridSize + 20, gridSize + 96)
Panel.Position = UDim2.fromOffset(20, 80)
Panel.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
Panel.BorderSizePixel = 0
Panel.Parent = GridGui
Instance.new("UICorner", Panel).CornerRadius = UDim.new(0, 10)
local pStroke = Instance.new("UIStroke", Panel)
pStroke.Color = Color3.fromRGB(70, 70, 90)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -40, 0, 28)
Title.Position = UDim2.fromOffset(10, 4)
Title.BackgroundTransparency = 1
Title.Font = Enum.Font.GothamBold
Title.TextSize = 13
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.TextColor3 = Color3.fromRGB(235, 235, 245)
Title.Text = T("Tile Break Pabrik")
Title.Parent = Panel

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.fromOffset(24, 24)
CloseBtn.Position = UDim2.new(1, -30, 0, 6)
CloseBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 75)
CloseBtn.Text = "X"
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 12
CloseBtn.TextColor3 = Color3.new(1, 1, 1)
CloseBtn.Parent = Panel
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)
CloseBtn.MouseButton1Click:Connect(function()
    GridGui.Enabled = false
end)

local GridHolder = Instance.new("Frame")
GridHolder.Size = UDim2.fromOffset(gridSize, gridSize)
GridHolder.Position = UDim2.fromOffset(10, 36)
GridHolder.BackgroundTransparency = 1
GridHolder.Parent = Panel

local COLOR_OFF = Color3.fromRGB(48, 48, 60)
local COLOR_ON = Color3.fromRGB(46, 160, 90)
local COLOR_ME = Color3.fromRGB(60, 110, 220)
local COLOR_STOP = Color3.fromRGB(200, 60, 60)
local CellButtons = {}

-- Grid hanya dipakai untuk tile break Pabrik
UI.GridMode = "pabrik"
UI.gridTarget = function()
    return Pabrik.Tiles
end

local function paintCell(key)
    local b = CellButtons[key]
    if b then b.BackgroundColor3 = UI.gridTarget()[key] and COLOR_ON or COLOR_OFF end
end

for row = 0, side - 1 do
    for col = 0, side - 1 do
        local dx, dy = col - GRID_RADIUS, row - GRID_RADIUS
        local key = dx .. "," .. dy
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(CELL, CELL)
        btn.Position = UDim2.fromOffset(col * (CELL + GAP), row * (CELL + GAP))
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Parent = GridHolder
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)

        if dx == 0 and dy == 0 then
            btn.Text = "ME"
            btn.BackgroundColor3 = COLOR_ME
            btn.AutoButtonColor = false
        else
            btn.Text = ""
            btn.BackgroundColor3 = UI.gridTarget()[key] and COLOR_ON or COLOR_OFF
            CellButtons[key] = btn
            btn.MouseButton1Click:Connect(function()
                pcall(function()
                    local tgt = UI.gridTarget()
                    tgt[key] = (not tgt[key]) or nil
                    paintCell(key)
                    pcall(updateStatus)
                end)
            end)
        end
    end
end

local GridStart = Instance.new("TextButton")
GridStart.Size = UDim2.new(1, -20, 0, 30)
GridStart.Position = UDim2.new(0, 10, 1, -54)
GridStart.BackgroundColor3 = COLOR_ON
GridStart.Font = Enum.Font.GothamBold
GridStart.TextSize = 14
GridStart.TextColor3 = Color3.new(1, 1, 1)
GridStart.Text = T("START PABRIK")
GridStart.Parent = Panel
Instance.new("UICorner", GridStart).CornerRadius = UDim.new(0, 8)
UI.GridStart = GridStart
GridStart.MouseButton1Click:Connect(function()
    pcall(function()
        if Pabrik.Running then Pabrik.stop() else Pabrik.start() end
    end)
end)

local ClearBtn = Instance.new("TextButton")
ClearBtn.Size = UDim2.new(1, -20, 0, 18)
ClearBtn.Position = UDim2.new(0, 10, 1, -22)
ClearBtn.BackgroundTransparency = 1
ClearBtn.Font = Enum.Font.Gotham
ClearBtn.TextSize = 12
ClearBtn.TextColor3 = Color3.fromRGB(180, 180, 195)
ClearBtn.Text = T("Bersihkan pilihan")
ClearBtn.Parent = Panel
ClearBtn.MouseButton1Click:Connect(function()
    pcall(function()
        local tgt = UI.gridTarget()
        for key in pairs(tgt) do
            tgt[key] = nil
            paintCell(key)
        end
        pcall(updateStatus)
    end)
end)

local function refreshStart()
    GridStart.Text = T(Pabrik.Running and "STOP PABRIK" or "START PABRIK")
    GridStart.BackgroundColor3 = Pabrik.Running and COLOR_STOP or COLOR_ON
end

-- Grid cuma punya satu mode (pabrik); nama setGridMode dipertahankan supaya tombol di tab Pabrik jalan
UI.setGridMode = function(_)
    UI.GridMode = "pabrik"
    Title.Text = T("Tile Break Pabrik")
    for key in pairs(CellButtons) do paintCell(key) end
    refreshStart()
end
UI.setGridMode("pabrik")

-- Panel bisa digeser lewat judul
do (function()
    local dragging, dragStart, startPos
    Title.Active = true
    Title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = Panel.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    table.insert(Mod.Conns, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            Panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
end)() end

task.spawn(function()
    while uiAlive() do
        pcall(function()
            if GridGui.Enabled then
                local px, py = getPlayerTile()
                local t = px and ("ME (" .. px .. "," .. py .. ")") or T("Grid Tile | tidak di world")
                if Title.Text ~= t then Title.Text = t end
                refreshStart()
            end
        end)
        task.wait(0.5)
    end
end)

---------------------------------------------------------------------
-- TAB: LAHAN (setelan lahan Pabrik)
---------------------------------------------------------------------
do (function()
    local LTab = API.makeTab("Lahan", "layout-grid", "farm")

    safe(function()
        UI.LahanStatus = LTab:Paragraph({ Title = "Status Lahan", Desc = "-" })
    end)

    local lShape = API.box(LTab, "Bentuk lahan", true)

    local function num(text, def)
        local v = tonumber(tostring(text or ""):match("%-?%d+"))
        return v or def
    end

    safe(function()
        lShape:Input({
            Title = "X awal",
            Desc = "Kolom paling kiri",
            Value = tostring(Land.X0),
            Placeholder = "0",
            Callback = function(t) pcall(function() Land.X0 = math.max(0, num(t, Land.X0)) end) end,
        })
    end)

    safe(function()
        lShape:Input({
            Title = "X akhir",
            Desc = "Kolom paling kanan (lebih dari lebar world = sampai ujung)",
            Value = tostring(Land.X1),
            Placeholder = "99",
            Callback = function(t) pcall(function() Land.X1 = math.max(0, num(t, Land.X1)) end) end,
        })
    end)

    safe(function()
        lShape:Input({
            Title = "Y baris atas",
            Desc = "Baris block paling atas. Baris di bawahnya otomatis sampai di atas bedrock (tanah digali)",
            Value = tostring(Land.Y0),
            Placeholder = "2",
            Callback = function(t) pcall(function() Land.Y0 = math.max(1, num(t, Land.Y0)) end) end,
        })
    end)

    safe(function()
        lShape:Button({
            Title = "Pakai posisi karakter sebagai pojok kiri-atas",
            Desc = "Berdiri di atas block pertama baris paling atas, lalu tekan (tangga kiri di sebelah kirinya)",
            Callback = function()
                pcall(function()
                    local x, y = Engine.here()
                    if not x then
                        notify("Lahan", "Kamu belum masuk world", 3)
                        return
                    end
                    -- block yang dipijak = block pertama baris atas, kolom tangga kiri di sebelah kirinya
                    Land.X0, Land.Y0 = math.max(0, x - 1), y + 1
                    notify("Lahan", ("X awal %d, Y baris atas %d"):format(Land.X0, Land.Y0), 4)
                end)
            end,
        })
    end)

    local shown
    task.spawn(function()
        while uiAlive() do
            pcall(function()
                local txt
                if API.Refs.World then
                    local rows = Engine.landRows()
                    txt = table.concat({
                        (#rows > 0) and ("Bentuk : %d baris (y %d-%d), x %d-%d, 1 kosong per baris, tangga kiri & kanan"):format(
                            #rows, rows[1], rows[#rows], math.min(Land.X0, Land.X1), math.max(Land.X0, Land.X1))
                            or "Bentuk : tidak ada baris yang muat (Y atas terlalu bawah)",
                        "Dipakai: Pabrik (mode lahan)",
                    }, "\n")
                else
                    txt = "Data world belum ketemu"
                end
                if UI.LahanStatus and txt ~= shown then
                    shown = txt
                    UI.LahanStatus:SetDesc(txt)
                end
            end)
            task.wait(1)
        end
    end)
end)() end

---------------------------------------------------------------------
-- TAB: TITIK DROP (dipakai Pabrik, Farmer, Auto Farm)
---------------------------------------------------------------------
do (function()
    local DTab = API.makeTab("Titik Drop", "map-pin", "farm")

    safe(function()
        UI.DropPointStatus = DTab:Paragraph({ Title = "Titik Drop", Desc = "-" })
    end)

    local dBox = API.box(DTab, "Atur titik drop", true)

    safe(function()
        UI.DropWorldInput = dBox:Input({
            Title = "World drop",
            Desc = "Kosong = world ini | WORLD | WORLD:ID (masuk lewat pintu ID)",
            Value = Pabrik.DropWorld,
            Placeholder = "STORAGE:1",
            Callback = function(t)
                pcall(function()
                    local v = tostring(t or "")
                    if v ~= Pabrik.DropWorld then Pabrik.Zone = nil end -- titik drop diganti: zona lama tidak dipakai lagi
                    Pabrik.DropWorld = v
                end)
            end,
        })
    end)

    safe(function()
        dBox:Button({
            Title = "Pakai posisi sekarang untuk drop",
            Desc = "Berdiri di tempat drop (boleh di world lain), lalu tekan",
            Callback = function()
                pcall(function()
                    local x, y = Engine.here()
                    if not x then
                        notify("Titik Drop", "Kamu belum masuk world", 3)
                        return
                    end
                    Pabrik.DropX, Pabrik.DropY = x, y
                    Pabrik.Zone = nil -- titik drop diganti: zona lama tidak dipakai lagi
                    -- world ikut diisi, kecuali sudah pakai format WORLD:ID
                    if not string.find(Pabrik.DropWorld or "", ":", 1, true) then
                        Pabrik.DropWorld = Guard.worldName()
                        if UI.DropWorldInput then pcall(function() UI.DropWorldInput:Set(Pabrik.DropWorld) end) end
                    end
                    notify("Titik Drop", ("Posisi drop (%d,%d) di %s"):format(x, y, Pabrik.DropWorld), 4)
                end)
            end,
        })
    end)

    safe(function()
        dBox:Button({
            Title = "Hapus posisi drop",
            Desc = "Drop di titik kedatangan (pintu) saja",
            Callback = function()
                pcall(function()
                    Pabrik.DropX, Pabrik.DropY = -1, -1
                    Pabrik.Zone = nil -- titik drop dihapus: zona lama tidak dipakai lagi
                    notify("Titik Drop", "Posisi drop dihapus", 3)
                end)
            end,
        })
    end)

    task.spawn(function()
        while uiAlive() do
            pcall(function()
                local name, door = Engine.parseDropTarget()
                local here = Guard.worldName()
                local point
                if Pabrik.DropX < 0 and not door and (name == "" or name == here) then
                    point = "belum diatur"
                else
                    point = (name ~= "" and name or "world ini") .. (door and (" pintu " .. door) or "")
                        .. (Pabrik.DropX >= 0 and (" (" .. Pabrik.DropX .. "," .. Pabrik.DropY .. ")") or " (titik kedatangan)")
                end
                local txt = table.concat({
                    "Titik  : " .. point,
                    "Dipakai: Pabrik (seed), Farmer & Auto Farm (otomatis saat item ~190)",
                    ("Di-drop: Pabrik %d | Farmer %d | Auto Farm %d"):format(
                        Pabrik.Dropped or 0, Farmer.Dropped or 0, State.Dropped or 0),
                    "Catatan: drop di titik ini tidak di-collect lagi",
                }, "\n")
                if UI.DropPointStatus and txt ~= UI.DropPointShown then
                    UI.DropPointShown = txt
                    UI.DropPointStatus:SetDesc(txt)
                end
            end)
            task.wait(1)
        end
    end)
end)() end

---------------------------------------------------------------------
-- TAB: DISCORD (setelan & Config.add("Discord", ...) ada di engine.lua)
---------------------------------------------------------------------
do (function()
    local DcTab = API.makeTab("Discord", "bell", "setel")

    safe(function()
        UI.HookStatus = DcTab:Paragraph({ Title = "Status", Desc = Hook.Status })
    end)

    local dMain = API.box(DcTab, "Webhook", true)
    local dWhat = API.box(DcTab, "Yang dikirim", false)

    safe(function()
        dMain:Toggle({
            Title = "Notifikasi Discord",
            Desc = "Kirim kabar penting ke channel Discord kamu",
            Value = Hook.On,
            Callback = function(on) pcall(function() Hook.On = on end) end,
        })
    end)

    safe(function()
        dMain:Input({
            Title = "URL Webhook",
            Desc = "Channel Discord > Edit > Integrasi > Webhook > Salin URL",
            Value = Hook.Url,
            Placeholder = "https://discord.com/api/webhooks/...",
            Callback = function(text)
                pcall(function()
                    text = trim(text)
                    Hook.Url = text
                    if text ~= "" and not Hook.valid(text) then
                        notify("Discord", "URL webhook tidak valid", 4)
                    end
                end)
            end,
        })
    end)

    safe(function()
        dMain:Button({
            Title = "Tes kirim",
            Callback = function()
                pcall(function()
                    if not Hook.valid(Hook.Url) then
                        notify("Discord", "Isi URL webhook dulu", 3)
                        return
                    end
                    local was = Hook.On
                    Hook.On = true
                    Hook.send("test", "Tes notifikasi dari YutiCapital")
                    Hook.On = was
                    notify("Discord", "Pesan tes masuk antrian", 3)
                end)
            end,
        })
    end)

    for _, item in ipairs({
        { "Penjaga", "Mod / Dev / pemain masuk world" },
        { "Stop", "Aktivitas berhenti (block habis / error)" },
        { "Full", "Inventori penuh" },
        { "Bonus", "Quest diklaim / redeem berhasil" },
        { "Rejoin", "Terlempar / disconnect / masuk lagi" },
        { "Pabrik", "Pabrik drop seed / lahan selesai / berhenti" },
    }) do
        safe(function()
            dWhat:Toggle({
                Title = item[2],
                Value = Hook[item[1]],
                Callback = function(on) pcall(function() Hook[item[1]] = on end) end,
            })
        end)
    end

    local shown
    task.spawn(function()
        while uiAlive() do
            pcall(function()
                local hk = ("%s\nAntrian: %d pesan"):format(Hook.Status, #Hook.Queue)
                if UI.HookStatus and hk ~= shown then
                    shown = hk
                    UI.HookStatus:SetDesc(hk)
                end
            end)
            task.wait(1)
        end
    end)
end)() end

---------------------------------------------------------------------
-- CLEANUP (dipanggil Session.Cleanup saat script dijalankan ulang, dan oleh ui_extra.lua baru)
---------------------------------------------------------------------
function Mod.Cleanup()
    Mod.Dead = true
    for _, c in ipairs(Mod.Conns) do pcall(function() c:Disconnect() end) end
    table.clear(Mod.Conns)
    pcall(function() GridGui:Destroy() end)
    if UI.GridGui == GridGui then
        UI.GridGui, UI.GridStart, UI.setGridMode, UI.gridTarget = nil, nil, nil, nil
    end
end

do
    local base = Session.UiExtraBaseCleanup or Session.Cleanup
    Session.UiExtraBaseCleanup = base
    Session.Cleanup = function()
        pcall(Mod.Cleanup)
        if base then base() end
    end
end

Mod.ready = true

end)() end
