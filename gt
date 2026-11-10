-- n4th + perbaikan error kompilasi + AFK Drop Semua Seed + FPS Boost + susunan menu baru (v8)
-- Tiap bagian dipasang sendiri-sendiri. Kalau salah satu tidak cocok dengan script terbaru,
-- bagian itu dilewati dan yang lain tetap jalan. Urutan percobaan kompilasi:
--   semua yang berhasil dipasang  ->  perbaikan saja  ->  script asli.
assert(type(loadstring) == "function", "[AFK] Executor tidak menyediakan loadstring")
local repository = "ZennJxD/n4th"
local httpService = game:GetService("HttpService")

---------------------------------------------------------------------
-- PERBAIKAN: bungkus blok World Finder jadi fungsi (batas 200 variabel local)
---------------------------------------------------------------------
local FIX = {
    {
        name = "buka bungkus World Finder",
        old = "-- WORLD FINDER: pindah world dan verifikasi seluruh foreground sebelum menyebutnya tanpa lock.\ndo\n",
        new = "-- WORLD FINDER: pindah world dan verifikasi seluruh foreground sebelum menyebutnya tanpa lock.\ndo (function()\n",
    },
    {
        name = "tutup bungkus World Finder",
        old = "end\n\n-- ===== TAB: WORLD FINDER =====",
        new = "end)() end\n\n-- ===== TAB: WORLD FINDER =====",
    },
}

---------------------------------------------------------------------
-- FITUR AFK: drop semua seed yang stack-nya penuh (200)
---------------------------------------------------------------------
local AFK = {
    {
        name = "tabel AutoDrop",
        old = [==[local AutoDrop = {]==],
        new = [==[local AutoDrop = {
    AllSeeds = false,]==],
    },
    {
        name = "config AutoDrop",
        old = [==[Config.add("AutoDrop", AutoDrop, { "Items", "World", "X", "Y", "Facing" })]==],
        new = [==[Config.add("AutoDrop", AutoDrop, { "Items", "World", "X", "Y", "Facing", "AllSeeds" })]==],
    },
    {
        name = "fungsi seed penuh",
        old = [==[function AutoDrop.labels()]==],
        new = [==[function AutoDrop.covers(id)
        if table.find(AutoDrop.Items, id) then return true end
        if not AutoDrop.AllSeeds then return false end
        local item = ItemDB[id]
        return item ~= nil and item.kind == "seed"
    end

    AutoDrop.baseFull = AutoDrop.fullItems
    function AutoDrop.fullItems()
        local items = AutoDrop.baseFull()
        if AutoDrop.AllSeeds and Refs.Inv then
            local seen = {}
            for _, id in ipairs(items) do seen[id] = true end
            for _, slot in pairs(Refs.Inv.slots) do
                local id = type(slot) == "table" and slot.id or nil
                local item = type(id) == "number" and ItemDB[id] or nil
                if item and item.kind == "seed" and not seen[id] and invCount(id) >= 200 then
                    seen[id] = true
                    items[#items + 1] = id
                end
            end
        end
        return items
    end

    function AutoDrop.labels()]==],
    },
    {
        name = "drop saat trip",
        old = [==[if table.find(AutoDrop.Items, id) and invCount(id) >= 200 then]==],
        new = [==[if AutoDrop.covers(id) and invCount(id) >= 200 then]==],
    },
    {
        name = "validasi toggle",
        old = [==[local reason = #AutoDrop.Items == 0 and "Pilih item dulu" or AutoDrop.targetError()]==],
        new = [==[local reason = (#AutoDrop.Items == 0 and not AutoDrop.AllSeeds) and "Pilih item dulu" or AutoDrop.targetError()]==],
    },
    {
        name = "Farmer tidak dobel drop",
        old = [==[not (AutoDrop.On and table.find(AutoDrop.Items, id))]==],
        new = [==[not (AutoDrop.On and AutoDrop.covers(id))]==],
    },
    {
        name = "Auto Farm tidak dobel drop",
        old = [==[not (AutoDrop.On and table.find(AutoDrop.Items, seed))]==],
        new = [==[not (AutoDrop.On and AutoDrop.covers(seed))]==],
    },
    {
        name = "toggle AFK di menu",
        old = [==[local pointBox = box(tab, "Atur titik drop", true)]==],
        new = [==[local pointBox = box(tab, "Atur titik drop", true)

    safe(function()
        UI.AutoDropAllSeeds = controls:Toggle({
            Title = "AFK: drop semua seed",
            Desc = "Semua jenis seed yang stack-nya penuh (200) ikut di-drop ke tile drop. Block tidak. Nyalakan juga 'Pantau item penuh'.",
            Value = AutoDrop.AllSeeds,
            Callback = function(on)
                AutoDrop.AllSeeds = on
                if on and not AutoDrop.On then
                    notify("Auto Drop", "Nyalakan juga 'Pantau item penuh' dan atur tile drop", 4)
                end
                if Session.Ready then Config.save(true) end
            end,
        })
    end)]==],
    },
}

---------------------------------------------------------------------
-- FPS BOOST: toggle + opsi di tab Pengaturan > Opsi
---------------------------------------------------------------------
local FPS = {
    {
        name = "menu FPS Boost",
        old = [==[local OptTab = Box.SetOpt]==],
        new = [==[local OptTab = Box.SetOpt

do (function()
    local Lighting = game:GetService("Lighting")
    local PerfTab = Box.SetPerf or OptTab
    local Boost = {
        On = false, Cap = 40, Quality = true, Shadows = true, Hide3D = false, HideGui = false, Saved = nil,
    }
    Session.FpsBoost = Boost
    Config.add("FpsBoost", Boost, { "Cap", "Quality", "Shadows", "Hide3D", "HideGui" })

    local function setCap(n)
        local f = setfpscap or set_fps_cap
        if type(f) ~= "function" and syn then f = syn.set_fps_cap end
        if type(f) ~= "function" then return false end
        return (pcall(f, n))
    end

    local function apply()
        local s = { effects = {} }
        Boost.Saved = s
        s.lite, s.visual = State.LiteMode, State.Visual
        if not State.LiteMode then setLite(true) end
        State.Visual = false
        if Boost.Quality then
            pcall(function()
                local r = settings().Rendering
                s.quality = r.QualityLevel
                r.QualityLevel = Enum.QualityLevel.Level01
            end)
        end
        if Boost.Shadows then
            pcall(function()
                s.shadows = Lighting.GlobalShadows
                Lighting.GlobalShadows = false
                for _, e in ipairs(Lighting:GetChildren()) do
                    if e:IsA("PostEffect") then
                        s.effects[e] = e.Enabled
                        e.Enabled = false
                    end
                end
            end)
        end
        if Boost.Hide3D then
            if pcall(function() RunService:Set3dRenderingEnabled(false) end) then s.hide3d = true end
        end
        if Boost.HideGui then
            local gg = PlayerGui:FindFirstChild("GameGui")
            if gg and gg:IsA("ScreenGui") then
                s.gui, s.guiOn = gg, gg.Enabled
                gg.Enabled = false
            end
        end
        s.fps = setCap(Boost.Cap)
        if not s.fps then notify("FPS Boost", "Executor tidak punya setfpscap, batas FPS dilewati", 4) end
    end

    local function restore()
        local s = Boost.Saved
        if not s then return end
        Boost.Saved = nil
        if s.fps then setCap(60) end
        if s.quality then pcall(function() settings().Rendering.QualityLevel = s.quality end) end
        if s.shadows ~= nil then pcall(function() Lighting.GlobalShadows = s.shadows end) end
        for e, was in pairs(s.effects) do pcall(function() e.Enabled = was end) end
        if s.hide3d then pcall(function() RunService:Set3dRenderingEnabled(true) end) end
        if s.gui then pcall(function() s.gui.Enabled = s.guiOn end) end
        if s.lite == false then setLite(false) end
        if s.visual ~= nil then State.Visual = s.visual end
    end

    function Boost.set(on)
        if on == Boost.On then return end
        Boost.On = on
        if on then apply() else restore() end
    end

    local function changed()
        if Boost.On then
            restore()
            apply()
        end
    end

    safe(function()
        PerfTab:Toggle({
            Title = "FPS Boost",
            Desc = "Kurangi beban HP: batas FPS, grafis terendah, Mode Lite & animasi dimatikan. Semua dikembalikan saat dimatikan.",
            Value = false,
            Callback = function(on) Boost.set(on) end,
        })
    end)

    addNumber(PerfTab, {
        Title = "Batas FPS",
        Desc = "Makin rendah makin ringan. Jangan di bawah 30 kalau pakai Clear / Farmer / Pabrik",
        Min = 15, Max = 60, Step = 5, Default = Boost.Cap,
        Callback = function(v)
            Boost.Cap = math.floor(v)
            if Boost.On then setCap(Boost.Cap) end
        end,
    })

    safe(function()
        PerfTab:Toggle({
            Title = "Boost: kualitas grafis terendah",
            Value = Boost.Quality,
            Callback = function(on) Boost.Quality = on changed() end,
        })
    end)

    safe(function()
        PerfTab:Toggle({
            Title = "Boost: matikan bayangan & efek layar",
            Value = Boost.Shadows,
            Callback = function(on) Boost.Shadows = on changed() end,
        })
    end)

    safe(function()
        PerfTab:Toggle({
            Title = "Boost: matikan render 3D",
            Desc = "Game digambar lewat UI, jadi tampilan tidak berubah. Bisa bikin latar hitam di sebagian executor.",
            Value = Boost.Hide3D,
            Callback = function(on) Boost.Hide3D = on changed() end,
        })
    end)

    safe(function()
        PerfTab:Toggle({
            Title = "Boost: sembunyikan layar game (AFK)",
            Desc = "Layar game jadi kosong tapi farming tetap jalan. Paling hemat GPU. Matikan untuk melihat game lagi.",
            Value = Boost.HideGui,
            Callback = function(on) Boost.HideGui = on changed() end,
        })
    end)

    -- dipulihkan otomatis saat script ditutup / dijalankan ulang
    table.insert(Connections, { Disconnect = function() pcall(restore) end })
end)() end]==],
    },
}


---------------------------------------------------------------------
-- SUSUNAN MENU BARU: grup, urutan & nama tab
--   Farming: Auto Farm, Harvest, Splice | World: Clear World, Dirt Farm, Pabrik
--   Shop: Drop, Titik Drop, Vending, Tas | Info: Growscan, Statistik
--   Utilitas: Auto Chat, World Finder, Lainnya | Keamanan: Auto Mods, Auto Reconnect
--   Setelan: Umum, Performa, Koneksi & Config, Discord
---------------------------------------------------------------------
local LAYOUT = {
    {
        name = "grup World, Shop, Info",
        old = [==[{ key = "farm", title = "Farming", icon = "sprout", opened = true },]==],
        new = [==[{ key = "farm", title = "Farming", icon = "sprout", opened = true },
    { key = "world", title = "World", icon = "map" },
    { key = "shop", title = "Shop", icon = "shopping-bag" },
    { key = "info", title = "Info", icon = "info" },]==],
    },
    {
        name = "grup Utilitas",
        old = [==[{ key = "fitur", title = "Fitur", icon = "sparkles" },]==],
        new = [==[{ key = "fitur", title = "Utilitas", icon = "sparkles" },]==],
    },
    {
        name = "urutan dan nama tab",
        old = [==[local function makeTab(title, icon, group)]==],
        new = [==[Session.PreTabs = {}
do (function()
    -- { judul lama (dipakai kode), judul baru, ikon, grup }. Urutan di sini = urutan di sidebar.
    local PLAN = {
        { "Farm", "Auto Farm", "pickaxe", "farm" },
        { "Farmer", "Harvest", "leaf", "farm" },
        { "Splice", "Splice", "git-merge", "farm" },
        { "Clear World", "Clear World", "eraser", "world" },
        { "Lahan", "Dirt Farm", "layout-grid", "world" },
        { "Pabrik", "Pabrik", "factory", "world" },
        { "Auto Drop", "Drop", "package-open", "shop" },
        { "Titik Drop", "Titik Drop", "map-pin", "shop" },
        { "Vending", "Vending", "store", "shop" },
        { "Tas", "Tas", "backpack", "shop" },
        { "Growscan", "Growscan", "scan-search", "info" },
        { "Statistik", "Statistik", "bar-chart-3", "info" },
        { "Auto Chat", "Auto Chat", "message-circle", "fitur" },
        { "World Finder", "World Finder", "globe", "fitur" },
        { "Bonus", "Lainnya", "gift", "fitur" },
        { "Penjaga", "Auto Mods", "eye", "aman" },
        { "Auto Reconnect", "Auto Reconnect", "refresh-cw", "aman" },
        { "Pengaturan", "Umum", "sliders-horizontal", "setel" },
        { "Performa", "Performa", "gauge", "setel" },
        { "Koneksi", "Koneksi & Config", "plug", "setel" },
        { "Discord", "Discord", "bell", "setel" },
    }
    for _, e in ipairs(PLAN) do
        local section = Groups[e[4]]
        if section then
            local ok, tab = pcall(function() return section:Tab({ Title = e[2], Icon = e[3] }) end)
            if ok and tab then Session.PreTabs[e[1]] = tab end
        end
    end
end)() end

local function makeTab(title, icon, group)
    local cached = Session.PreTabs[title]
    if cached then return cached end
    local created = Session.rawTab(title, icon, group)
    Session.PreTabs[title] = created
    return created
end

Session.rawTab = function(title, icon, group)]==],
    },
    {
        name = "Auto Reconnect jadi tab Keamanan",
        old = [==[local rBox = box(ConnTab, "Auto Reconnect", false)]==],
        new = [==[local rBox = box(makeTab("Auto Reconnect", "refresh-cw", "aman"), "Auto Reconnect", true)]==],
    },
    {
        name = "kotak Performa",
        old = [==[Box.SetOpt = box(SetTab, "Opsi", true)]==],
        new = [==[Box.SetOpt = box(SetTab, "Opsi", true)
Box.SetPerf = box(makeTab("Performa", "gauge", "setel"), "Performa", true)]==],
    },
    {
        name = "Mode Lite ke Performa",
        old = "OptTab:Toggle({\n        Title = \"Mode Lite\",",
        new = "Box.SetPerf:Toggle({\n        Title = \"Mode Lite\",",
    },
    {
        name = "Mute suara ke Performa",
        old = "OptTab:Toggle({\n        Title = \"Mute suara pukulan\",",
        new = "Box.SetPerf:Toggle({\n        Title = \"Mute suara pukulan\",",
    },
    {
        name = "Animasi aksi ke Performa",
        old = "OptTab:Toggle({\n        Title = \"Animasi aksi\",",
        new = "Box.SetPerf:Toggle({\n        Title = \"Animasi aksi\",",
    },
    {
        name = "terjemahan English",
        old = [==[["Fitur"] = "Features", ["Keamanan"] = "Security", ["Setelan"] = "Setup",]==],
        new = [==[["Fitur"] = "Features", ["Keamanan"] = "Security", ["Setelan"] = "Setup",
    ["Utilitas"] = "Utilities", ["Umum"] = "General", ["Performa"] = "Performance",
    ["Koneksi & Config"] = "Connection & Config",
    ["Status Harvest"] = "Harvest Status", ["Jalankan Harvest"] = "Run Harvest",
    ["Status Dirt Farm"] = "Dirt Farm Status", ["Bangun Dirt Farm"] = "Build Dirt Farm",
    ["Status Auto Mods"] = "Auto Mods Status", ["Aktifkan Auto Mods"] = "Enable Auto Mods",]==],
    },
}

---------------------------------------------------------------------
-- RAPI-IN UI: tab Farm. Collect & kecepatan (global) pindah ke Setelan > Umum,
-- Auto Break Block pindah ke tab Clear World.
---------------------------------------------------------------------
local FARMUI = {
    {
        name = "judul kotak Auto Farm",
        old = [==[Box.FarmCtl = box(FarmTab, "Kontrol", true)]==],
        new = [==[Box.FarmCtl = box(FarmTab, "Auto Farm", true)]==],
    },
    {
        name = "kotak Mode, Collect, Kecepatan",
        old = [==[Box.FarmSpeed = box(FarmTab, "Mode & Kecepatan", false)]==],
        new = [==[Box.FarmSpeed = box(FarmTab, "Mode", false)
Box.GlobCollect = box(makeTab("Pengaturan", "sliders-horizontal", "setel"), "Collect", false)
Box.GlobSpeed = box(makeTab("Pengaturan", "sliders-horizontal", "setel"), "Kecepatan", false)]==],
    },
    {
        name = "Auto Collect pindah",
        old = "Box.FarmCtl:Toggle({\n        Title = \"Auto Collect\",",
        new = "Box.GlobCollect:Toggle({\n        Title = \"Auto Collect\",",
    },
    {
        name = "Mode collect pindah",
        old = "Box.FarmCtl:Dropdown({\n        Title = \"Mode collect\",",
        new = "Box.GlobCollect:Dropdown({\n        Title = \"Mode collect\",",
    },
    {
        name = "Radius collect pindah",
        old = "addNumber(Box.FarmCtl, {\n    Title = \"Radius collect (mode Remote)\",",
        new = "addNumber(Box.GlobCollect, {\n    Title = \"Radius collect (mode Remote)\",",
    },
    {
        name = "Speed Place pindah",
        old = "addNumber(SpeedTab, {\n    Title = \"Speed Place (ms)\",",
        new = "addNumber(Box.GlobSpeed, {\n    Title = \"Speed Place (ms)\",",
    },
    {
        name = "Speed Break pindah",
        old = "addNumber(SpeedTab, {\n    Title = \"Speed Break (ms)\",",
        new = "addNumber(Box.GlobSpeed, {\n    Title = \"Speed Break (ms)\",",
    },
    {
        name = "Auto Break Block pindah ke Clear World",
        old = [==[local controls = box(FarmTab, "Auto Break Block", true)]==],
        new = [==[local controls = box(makeTab("Clear World", "eraser", "world"), "Auto Break Block", false)]==],
    },
}

---------------------------------------------------------------------
-- GANTI NAMA yang kelihatan di menu: Farmer -> Harvest, Lahan -> Dirt Farm, Penjaga -> Auto Mods
---------------------------------------------------------------------
local RENAME = {
    {
        name = "judul notifikasi",
        old = [==[Title = I18N.T(title), Content = I18N.T(content)]==],
        new = [==[Title = I18N.T(({ Penjaga = "Auto Mods", Lahan = "Dirt Farm", ["Bangun Lahan"] = "Dirt Farm", Farmer = "Harvest" })[title] or title), Content = I18N.T(content)]==],
    },
    { name = "Status Farmer", old = [==[Title = "Status Farmer"]==], new = [==[Title = "Status Harvest"]==] },
    { name = "Jalankan Farmer", old = [==[Title = "Jalankan Farmer",]==], new = [==[Title = "Jalankan Harvest",]==] },
    { name = "Status Lahan", old = [==[Title = "Status Lahan"]==], new = [==[Title = "Status Dirt Farm"]==] },
    { name = "kotak Bangun Lahan", old = [==[local lCtl = box(LTab, "Bangun Lahan", true)]==], new = [==[local lCtl = box(LTab, "Bangun Dirt Farm", true)]==] },
    { name = "toggle Bangun Lahan", old = [==[Title = "Bangun Lahan",]==], new = [==[Title = "Bangun Dirt Farm",]==] },
    { name = "Status Penjaga", old = [==[Title = "Status Penjaga"]==], new = [==[Title = "Status Auto Mods"]==] },
    { name = "Aktifkan Penjaga", old = [==[Title = "Aktifkan Penjaga",]==], new = [==[Title = "Aktifkan Auto Mods",]==] },
}


---------------------------------------------------------------------
-- NAMA: n4th -> utimeme (judul menu, tombol buka, watermark nama di atas karakter, notifikasi)
-- Nama folder config dan nama internal tidak diubah, supaya pengaturan lama tidak hilang.
---------------------------------------------------------------------
local BRAND = {
    { name = "judul jendela", old = "WindUI:CreateWindow({\n    Title = \"n4th\",", new = "WindUI:CreateWindow({\n    Title = \"utimeme\"," },
    { name = "tombol buka menu", old = "Window:EditOpenButton({\n        Title = \"n4th\",", new = "Window:EditOpenButton({\n        Title = \"utimeme\"," },
    { name = "popup bahasa", old = "WindUI:Popup({\n            Title = \"n4th\",", new = "WindUI:Popup({\n            Title = \"utimeme\"," },
    { name = "nama di atas karakter", old = [==[NameText = "n4th",]==], new = [==[NameText = "utimeme",]==] },
    { name = "nama pengirim Discord", old = [==[username = "n4th",]==], new = [==[username = "utimeme",]==] },
    { name = "tes notifikasi", old = [==[Hook.send("test", "Tes notifikasi dari n4th")]==], new = [==[Hook.send("test", "Tes notifikasi dari utimeme")]==] },
    { name = "tes notifikasi EN", old = [==[["Tes notifikasi dari n4th"] = "Test notification from n4th",]==], new = [==[["Tes notifikasi dari utimeme"] = "Test notification from utimeme",]==] },
    { name = "tes World Finder", old = [==["World Finder siap mengirim hasil hunting dari n4th"]==], new = [==["World Finder siap mengirim hasil hunting dari utimeme"]==] },
    { name = "notifikasi koneksi", old = [==[reconnect("n4th v5.2")]==], new = [==[reconnect("utimeme")]==] },
}


---------------------------------------------------------------------
-- HUBUNGKAN OTOMATIS: kalau sudah di dalam world tapi data world / tas belum ketemu
-- (misal script dijalankan sebelum world siap), coba hubungkan ulang sendiri.
---------------------------------------------------------------------
local AUTOLINK = {
    {
        name = "hubungkan otomatis",
        old = [==[Session.InitStep = "siap"]==],
        new = [==[task.spawn(function()
    task.wait(8)
    local tries = 0
    while alive() do
        if not (Refs.World and Refs.Inv) and getPlayerTile() then
            tries += 1
            if tries <= 5 or tries % 8 == 0 then
                UI.later("autoLink", function() reconnect("Hubungkan otomatis") end)
            end
        else
            tries = 0
            if not UI.DropOk then
                UI.later("autoDropdown", function() doInvRefresh(true) end)
            end
        end
        task.wait(tries <= 5 and 8 or 8)
    end
end)

Session.InitStep = "siap"]==],
    },
}


---------------------------------------------------------------------
-- PERBAIKAN DROPDOWN: isi daftar langsung dulu; kalau gagal baru lewat jalur izin penuh (lama)
---------------------------------------------------------------------
local DROPFIX = {
    {
        name = "refresh dropdown langsung",
        old = [==[function UI.ddRefresh(dd, labels)]==],
        new = [==[function UI.ddRefresh(dd, labels)
    if dd and pcall(function() dd:Refresh(labels) end) then
        UI.DropOk = os.clock()
        UI.DropErr = nil
        return
    end
    return UI.ddRefreshElevated(dd, labels)
end

function UI.ddRefreshElevated(dd, labels)]==],
    },
}

-- Semua teks harus muncul tepat 1x; kalau tidak, seluruh daftar dilewati.
local function applyPatches(source, list)
    local out = source
    for _, p in ipairs(list) do
        local s, e = out:find(p.old, 1, true)
        if not s then return nil, p.name .. " (teks tidak ketemu)" end
        if out:find(p.old, e + 1, true) then return nil, p.name .. " (muncul lebih dari satu kali)" end
        out = out:sub(1, s - 1) .. p.new .. out:sub(e + 1)
    end
    return out
end

---------------------------------------------------------------------
-- DOWNLOAD
---------------------------------------------------------------------
local function usable(text)
    return type(text) == "string" and not text:match("^%s*$") and not text:match("^%s*<")
end

local function download(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and usable(body) then return body end
    for _, api in ipairs({ request or false, http_request or false, (syn and syn.request) or false, (http and http.request) or false }) do
        if type(api) == "function" then
            local sent, res = pcall(api, { Url = url, Method = "GET" })
            if sent and type(res) == "table" then
                local status = tonumber(res.StatusCode or res.Status)
                local text = res.Body or res.body
                if (not status or (status >= 200 and status < 300)) and usable(text) then return text end
            end
        end
    end
    error("[AFK] Unduh gagal: " .. url, 0)
end

local function latestSource()
    local okRef, ref = pcall(function()
        local url = "https://api.github.com/repos/" .. repository .. "/git/ref/heads/main?update=" .. httpService:GenerateGUID(false)
        return httpService:JSONDecode(download(url))
    end)
    local commit = okRef and type(ref) == "table" and type(ref.object) == "table" and ref.object.sha
    if type(commit) == "string" and #commit == 40 and commit:match("^%x+$") then
        local ok, body = pcall(download, "https://raw.githubusercontent.com/" .. repository .. "/" .. commit .. "/n4th-main.lua")
        if ok then return body, commit:sub(1, 8) end
    end
    return download("https://raw.githubusercontent.com/" .. repository .. "/main/n4th-main.lua"), "main"
end

---------------------------------------------------------------------
-- JALANKAN
---------------------------------------------------------------------
local function pickCompiled(source)
    source = (source:gsub("\r\n", "\n"))
    local fixed, fixProblem = applyPatches(source, FIX)
    if not fixed then print("[AFK] Perbaikan kompilasi tidak dipasang: " .. tostring(fixProblem)) end
    local current, added = fixed or source, {}
    for _, feature in ipairs({ { "AFK", AFK }, { "FPS Boost", FPS }, { "Susunan menu", LAYOUT }, { "UI Farm", FARMUI }, { "Nama baru", RENAME }, { "Nama utimeme", BRAND }, { "Hubungkan otomatis", AUTOLINK }, { "Perbaikan dropdown", DROPFIX } }) do
        local patched, problem = applyPatches(current, feature[2])
        if patched then
            current = patched
            added[#added + 1] = feature[1]
        else
            print("[AFK] Fitur " .. feature[1] .. " dilewati: " .. tostring(problem))
        end
    end
    local candidates = {}
    if #added > 0 then
        candidates[#candidates + 1] = {
            text = current,
            label = (fixed and "perbaikan + " or "") .. table.concat(added, " + "),
        }
    end
    if fixed then candidates[#candidates + 1] = { text = fixed, label = "perbaikan saja" } end
    candidates[#candidates + 1] = { text = source, label = "script asli" }
    local lastCompileError
    for _, c in ipairs(candidates) do
        local fn, err = loadstring(c.text, "n4th-main")
        if fn then return fn, c.label end
        lastCompileError = tostring(err)
        print("[AFK] Gagal dikompilasi (" .. c.label .. "): " .. lastCompileError)
    end
    return nil, lastCompileError
end

local lastError = "respons kosong"
for attempt = 1, 3 do
    local ok, source, commit = pcall(latestSource)
    if ok then
        local fn, label = pickCompiled(source)
        if not fn then error("[AFK] Semua versi gagal dikompilasi: " .. tostring(label), 0) end
        print("[AFK] Menjalankan: " .. label .. " (versi " .. tostring(commit) .. ")")
        local ran, result = xpcall(fn, function(err)
            if debug and type(debug.traceback) == "function" then return debug.traceback(tostring(err), 2) end
            return tostring(err)
        end)
        if not ran then
            local globals = (getgenv and getgenv()) or _G
            local session = globals.__n4thOpus
            error("[AFK] Gagal saat " .. tostring(session and session.InitStep or "inisialisasi") .. ":\n" .. tostring(result), 0)
        end
        return result
    end
    lastError = tostring(source)
    if attempt < 3 then task.wait(1) end
end
error("[AFK] Gagal mengambil script setelah 3 percobaan: " .. lastError, 0)
