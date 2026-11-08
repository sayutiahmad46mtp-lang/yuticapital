--[[
    YutiCapital  -  TAHAP 1
    Isi tahap ini : inti (kunci sesi, pcall, thread/koneksi, Cleanup), config auto save,
                    koneksi ke data game (getgc), jendela UI dengan sidebar (halaman masih kosong).
    Fitur akhir   : Pabrik + Masuk World Lagi otomatis (Tahap 3-4).

    Susunan file gabungan (tiap modul dibungkus do (function() ... end)() end):
        Core -> Config -> Game (koneksi ke game) -> UI -> Mulai
]]

local G = (getgenv and getgenv()) or _G

---------------------------------------------------------------------
-- KUNCI SESI: kalau script dijalankan ulang, sesi lama dibersihkan dulu
---------------------------------------------------------------------
do
    local lama = rawget(G, "YutiCapital")
    if type(lama) == "table" and type(lama.Cleanup) == "function" then
        pcall(lama.Cleanup)
    end
end

local App = { Versi = "0.1.1-tahap1", Mati = false }
G.YutiCapital = App

---------------------------------------------------------------------
-- MODUL 1: CORE (pcall, sinyal, thread, koneksi, Cleanup)
---------------------------------------------------------------------
do (function()
    local Core = {}
    App.Core = Core

    local koneksi = {}      -- semua koneksi yang harus diputus saat Cleanup
    local utas = {}         -- semua thread yang dibuat lewat Core.Jalan
    local pembersih = {}    -- fungsi pembersih tambahan (hancurkan UI, simpan config, dst)
    local terakhirWarn = {} -- supaya pesan error yang sama tidak membanjiri output

    -- Data bersama antar modul (DiWorld, NamaWorld, IdWorld diisi Game.MulaiPantau;
    -- sisanya Tahap 2-3)
    App.State = {
        Status = "Siap",
        DiWorld = false,     -- true = ada world termuat (aturan sementara, lihat modul Game)
        NamaWorld = "",      -- nama world kalau DiWorld, selain itu ""
        IdWorld = 0,         -- naik tiap fg World diganti (pindah world); 0 = belum ada bacaan
        Traveling = false,
    }

    function Core.Hidup()
        return rawget(G, "YutiCapital") == App and not App.Mati
    end

    -- Catatan singkat (maks 100 baris), bisa ditampilkan di UI nanti
    Core.Catatan = {}
    function Core.Log(teks)
        local c = Core.Catatan
        c[#c + 1] = os.date("%H:%M:%S") .. " " .. tostring(teks)
        if #c > 100 then table.remove(c, 1) end
    end

    function Core.Galat(tag, err)
        Core.Log("GALAT [" .. tostring(tag) .. "] " .. tostring(err))
        local sekarang = os.clock()
        if sekarang - (terakhirWarn[tag] or -10) >= 5 then
            terakhirWarn[tag] = sekarang
            warn("[YutiCapital] " .. tostring(tag) .. ": " .. tostring(err))
        end
    end

    -- Jalankan fungsi dengan pcall. Hasil: ok, ... (sama seperti pcall); error dicatat
    function Core.Aman(fn, ...)
        if type(fn) ~= "function" then return false, "bukan fungsi" end
        local hasil = table.pack(pcall(fn, ...))
        if not hasil[1] then Core.Galat("aman", hasil[2]) end
        return table.unpack(hasil, 1, hasil.n)
    end

    -- Sinyal sederhana buatan sendiri (callback dibungkus pcall)
    local Sinyal = {}
    Sinyal.__index = Sinyal

    function Sinyal:Connect(fn)
        local rec = { fn = fn }
        local daftar = self._daftar
        daftar[#daftar + 1] = rec
        return {
            Disconnect = function()
                rec.fn = nil
                for i, r in ipairs(daftar) do
                    if r == rec then
                        table.remove(daftar, i)
                        break
                    end
                end
            end,
        }
    end

    function Sinyal:Fire(...)
        local salinan = table.clone(self._daftar)
        for _, rec in ipairs(salinan) do
            local fn = rec.fn
            if fn then
                local ok, err = pcall(fn, ...)
                if not ok then Core.Galat("sinyal", err) end
            end
        end
    end

    function Core.Sinyal()
        return setmetatable({ _daftar = {} }, Sinyal)
    end

    -- Hubungkan callback ke sinyal Roblox (atau Core.Sinyal). Callback dibungkus pcall
    -- dan otomatis diputus saat Cleanup.
    function Core.Hubung(sinyal, fn)
        local ok, c = pcall(function()
            return sinyal:Connect(function(...)
                if not Core.Hidup() then return end
                local okF, err = pcall(fn, ...)
                if not okF then Core.Galat("koneksi", err) end
            end)
        end)
        if ok and c then
            koneksi[#koneksi + 1] = c
            return c
        end
        Core.Galat("hubung", c)
        return nil
    end

    -- Jalankan fungsi di thread baru. Error ditangkap, thread dibatalkan saat Cleanup
    function Core.Jalan(nama, fn, ...)
        local args = table.pack(...)
        local t = task.spawn(function()
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            if not ok then Core.Galat(nama, err) end
        end)
        if #utas > 64 then
            for i = #utas, 1, -1 do
                if coroutine.status(utas[i]) == "dead" then table.remove(utas, i) end
            end
        end
        utas[#utas + 1] = t
        return t
    end

    -- Loop berkala: tidak mati karena error, dan SELALU menunggu (minimal 0.05 dtk)
    function Core.Ulang(nama, jeda, fn)
        jeda = math.max(0.05, tonumber(jeda) or 1)
        return Core.Jalan(nama, function()
            while Core.Hidup() do
                local ok, err = pcall(fn)
                if not ok then Core.Galat(nama, err) end
                task.wait(jeda)
            end
        end)
    end

    -- Ubah flag sementara. Apa pun yang terjadi (termasuk error), flag kembali ke `awal`
    -- Hasil: ok, ... (hasil fn)
    function Core.Sementara(tabel, kunci, nilai, awal, fn, ...)
        tabel[kunci] = nilai
        local hasil = table.pack(pcall(fn, ...))
        tabel[kunci] = awal
        if not hasil[1] then Core.Galat("sementara:" .. tostring(kunci), hasil[2]) end
        return table.unpack(hasil, 1, hasil.n)
    end

    function Core.SaatBersih(fn)
        pembersih[#pembersih + 1] = fn
    end

    -- Cleanup: hentikan semua thread & koneksi, jalankan pembersih, lepas kunci sesi
    function Core.Bersih()
        if App.Mati then return end
        App.Mati = true
        if rawget(G, "YutiCapital") == App then G.YutiCapital = nil end
        for i = #pembersih, 1, -1 do pcall(pembersih[i]) end
        for _, c in ipairs(koneksi) do
            pcall(function() c:Disconnect() end)
        end
        table.clear(koneksi)
        local utasSaatIni = coroutine.running()
        for _, t in ipairs(utas) do
            pcall(function()
                if t ~= utasSaatIni and coroutine.status(t) ~= "dead" then task.cancel(t) end
            end)
        end
        table.clear(utas)
    end
    App.Cleanup = Core.Bersih
end)() end

---------------------------------------------------------------------
-- MODUL 2: CONFIG (simpan otomatis ke workspace/YutiCapital/config_<UserId>.json;
--                  kalau folder tidak bisa dipakai: workspace/YutiCapital_config_<UserId>.json)
---------------------------------------------------------------------
do (function()
    local Config = {}
    App.Config = Config

    local Core = App.Core
    local HttpService = game:GetService("HttpService")
    local Players = game:GetService("Players")

    local FOLDER = "YutiCapital"
    local uid = (Players.LocalPlayer and Players.LocalPlayer.UserId) or 0
    local NAMA_FILE = "config_" .. tostring(uid) .. ".json"
    local JALUR_FOLDER = FOLDER .. "/" .. NAMA_FILE     -- utama
    local JALUR_DATAR = FOLDER .. "_" .. NAMA_FILE      -- cadangan: tanpa folder
    local punyaFile = type(writefile) == "function" and type(readfile) == "function"
        and type(isfile) == "function"

    -- Cek folder config. Hasil: true / false, atau nil kalau executor tidak bisa memeriksa
    local function cekFolder()
        if type(isfolder) ~= "function" then return nil end
        local ok, hasil = pcall(isfolder, FOLDER)
        if not ok then return nil end
        return hasil and true or false
    end

    -- Pastikan folder config ada, tanpa pernah melempar error. Executor tanpa isfolder /
    -- makefolder tetap aman. Hasil true = boleh pakai JALUR_FOLDER, false = pakai JALUR_DATAR.
    local function siapkanFolder()
        local ada = cekFolder()
        if ada == true then return true end
        if type(makefolder) ~= "function" then return false end
        pcall(makefolder, FOLDER)           -- error / sudah ada tidak masalah, hasilnya dicek ulang
        ada = cekFolder()
        if ada ~= nil then return ada end
        return true                         -- tidak bisa diperiksa: kita sudah mencoba membuatnya
    end

    -- Urutan jalur untuk baca DAN tulis (sama, supaya yang dibaca = yang terakhir ditulis).
    -- Jalur kedua dipakai sebagai cadangan kalau yang pertama tidak ada / gagal ditulis.
    local function daftarJalur()
        if siapkanFolder() then return { JALUR_FOLDER, JALUR_DATAR } end
        return { JALUR_DATAR, JALUR_FOLDER }
    end

    local function bacaTeks(jalur)
        local ok, teks = pcall(function()
            if isfile(jalur) then return readfile(jalur) end
            return nil
        end)
        if ok and type(teks) == "string" and teks ~= "" then return teks end
        return nil
    end

    local sudahCatatDatar = false

    -- Nilai bawaan. Hanya kunci di sini yang diterima dari file / Config.Atur
    local BAWAAN = {
        Pabrik = {
            SeedId = 0,             -- id seed pabrik (0 = belum dipilih)
            TanamDi = "lahan",      -- "lahan" | "world"
            BreakX = -1,            -- posisi break (tile), -1 = belum diatur
            BreakY = -1,
            BreakTiles = {},        -- tile break dalam grid 5x5: daftar "dx,dy" (dx, dy = -2..2)
            SeedSisa = "drop",      -- cara membuang seed lebih: "drop" | "recycle"
            DropWorld = "",         -- titik drop: "WORLD" atau "WORLD:ID" (pintu)
            DropX = -1,             -- posisi drop di world drop, -1 = belum diatur
            DropY = -1,
            Sisakan = 50,           -- seed yang disisakan (dipakai bersama Drop & Recycle)
            AmbangSisa = 150,       -- Drop / Recycle jalan kalau seed >= ini
            BerhentiPanen = 180,    -- panen berhenti kalau seed >= ini (batas keras 200)
        },
        Lahan = {
            X0 = 0,                 -- kolom kiri & kanan lahan
            X1 = 0,
            Y0 = 1,                 -- baris lahan paling atas
        },
        MasukLagi = {
            Aktif = true,
        },
        UI = {
            X = -1,                 -- posisi jendela (-1 = tengah layar)
            Y = -1,
            Lipat = false,
            Halaman = "pabrik",     -- "pabrik" | "masuklagi" | "pengaturan"
            GridX = -1,             -- posisi panel grid 5x5
            GridY = -1,
        },
    }

    local function salinDalam(t)
        local out = {}
        for k, v in pairs(t) do
            if type(v) == "table" then
                out[k] = salinDalam(v)
            else
                out[k] = v
            end
        end
        return out
    end

    -- Bulatkan ke bilangan bulat dalam rentang; nilai tidak valid -> bawaan (yang juga dijepit)
    local function jepit(n, bawah, atas, bawaan)
        n = tonumber(n)
        if n == nil or n ~= n then n = bawaan end
        return math.clamp(math.floor(n), bawah, atas)
    end

    local function pilih(v, daftar, bawaan)
        for _, x in ipairs(daftar) do
            if v == x then return v end
        end
        return bawaan
    end

    -- "world:Pintu1" -> "WORLD:Pintu1" (nama world huruf besar tanpa simbol, spasi dibuang)
    local function rapikanTitikDrop(s)
        local mentah = tostring(s or ""):gsub("%s", "")
        local nama, pintu = string.match(mentah, "^([^:]*):(.*)$")
        if not nama then nama, pintu = mentah, "" end
        nama = string.upper(nama):gsub("[^A-Z0-9]", "")
        if #nama > 24 then nama = string.sub(nama, 1, 24) end
        if #pintu > 32 then pintu = string.sub(pintu, 1, 32) end
        if pintu ~= "" then return nama .. ":" .. pintu end
        return nama
    end

    local function bersihTile(daftar)
        local out, lihat = {}, {}
        if type(daftar) == "table" then
            for _, k in ipairs(daftar) do
                local a, b = string.match(tostring(k), "^(-?%d+),(-?%d+)$")
                if a and b then
                    a, b = tonumber(a), tonumber(b)
                    if a and b and math.abs(a) <= 2 and math.abs(b) <= 2 then
                        local kunci = string.format("%d,%d", a, b)
                        if not lihat[kunci] then
                            lihat[kunci] = true
                            out[#out + 1] = kunci
                        end
                    end
                end
            end
        end
        table.sort(out)
        return out
    end

    -- Pastikan semua nilai masuk akal. Urutan penting:
    --   Sisakan < AmbangSisa < BerhentiPanen <= 200  (tidak ada zona mati)
    local function normalisasi(d)
        local p = d.Pabrik
        p.SeedId = jepit(p.SeedId, 0, 1000000000, 0)
        p.TanamDi = pilih(p.TanamDi, { "lahan", "world" }, "lahan")
        p.BreakX = jepit(p.BreakX, -1, 100000, -1)
        p.BreakY = jepit(p.BreakY, -1, 100000, -1)
        p.BreakTiles = bersihTile(p.BreakTiles)
        p.SeedSisa = pilih(p.SeedSisa, { "drop", "recycle" }, "drop")
        p.DropWorld = rapikanTitikDrop(p.DropWorld)
        p.DropX = jepit(p.DropX, -1, 100000, -1)
        p.DropY = jepit(p.DropY, -1, 100000, -1)
        p.BerhentiPanen = jepit(p.BerhentiPanen, 3, 200, 180)
        p.AmbangSisa = jepit(p.AmbangSisa, 2, p.BerhentiPanen - 1, 150)
        p.Sisakan = jepit(p.Sisakan, 0, p.AmbangSisa - 1, 50)

        local l = d.Lahan
        l.X0 = jepit(l.X0, 0, 100000, 0)
        l.X1 = jepit(l.X1, 0, 100000, 0)
        l.Y0 = jepit(l.Y0, 1, 100000, 1)

        d.MasukLagi.Aktif = (d.MasukLagi.Aktif == true)

        local u = d.UI
        u.X = jepit(u.X, -1, 100000, -1)
        u.Y = jepit(u.Y, -1, 100000, -1)
        u.Lipat = (u.Lipat == true)
        u.Halaman = pilih(u.Halaman, { "pabrik", "masuklagi", "pengaturan" }, "pabrik")
        u.GridX = jepit(u.GridX, -1, 100000, -1)
        u.GridY = jepit(u.GridY, -1, 100000, -1)
    end

    -- Salin nilai dari file ke `dasar`, hanya kunci yang dikenal & bertipe sama
    local function gabungkan(dasar, tersimpan)
        if type(tersimpan) ~= "table" then return end
        for k, nilaiDasar in pairs(dasar) do
            local v = tersimpan[k]
            if v ~= nil then
                if type(nilaiDasar) == "table" then
                    if type(v) == "table" then
                        if next(nilaiDasar) == nil then
                            dasar[k] = v            -- daftar (mis. BreakTiles), dibersihkan normalisasi
                        else
                            gabungkan(nilaiDasar, v) -- sub-tabel bernama
                        end
                    end
                elseif type(v) == type(nilaiDasar) then
                    dasar[k] = v
                end
            end
        end
    end

    Config.Data = salinDalam(BAWAAN)
    Config.Berubah = Core.Sinyal()  -- dikirim dengan path yang berubah ("*" = semua)

    local kotor = false
    local terakhirUbah = 0
    local tundaSampai = 0

    function Config.Muat()
        local data = salinDalam(BAWAAN)
        if punyaFile then
            for _, jalur in ipairs(daftarJalur()) do
                local teks = bacaTeks(jalur)
                if teks then
                    local okJ, hasil = pcall(function() return HttpService:JSONDecode(teks) end)
                    if okJ and type(hasil) == "table" then
                        gabungkan(data, hasil)
                        break
                    end
                    Core.Log("File config rusak (" .. jalur .. "), mencoba jalur lain / nilai bawaan")
                end
            end
        else
            Core.Log("Executor tidak punya fungsi file: config tidak disimpan")
        end
        normalisasi(data)
        Config.Data = data
        kotor = false
        Config.Berubah:Fire("*")
    end

    function Config.Simpan()
        if not punyaFile then return false end
        local okE, teks = pcall(function() return HttpService:JSONEncode(Config.Data) end)
        if not okE then
            Core.Galat("config-simpan", teks)
            return false
        end
        local galat
        for _, jalur in ipairs(daftarJalur()) do
            local ok, err = pcall(writefile, jalur, teks)
            if ok then
                kotor = false
                if jalur == JALUR_DATAR and not sudahCatatDatar then
                    sudahCatatDatar = true
                    Core.Log("Folder config tidak bisa dipakai, config disimpan di " .. JALUR_DATAR)
                end
                return true
            end
            galat = err
        end
        Core.Galat("config-simpan", galat)
        return false
    end

    local function belah(path)
        local bagian = {}
        for s in string.gmatch(tostring(path), "[^%.]+") do
            bagian[#bagian + 1] = s
        end
        return bagian
    end

    -- Ambil nilai: Config.Ambil("Pabrik.Sisakan")
    function Config.Ambil(path)
        local t = Config.Data
        for _, k in ipairs(belah(path)) do
            if type(t) ~= "table" then return nil end
            t = t[k]
        end
        return t
    end

    -- Atur nilai (hanya kunci yang dikenal). Hasil: nilai akhir setelah dirapikan, atau nil
    function Config.Atur(path, nilai)
        local bagian = belah(path)
        local t = Config.Data
        for i = 1, #bagian - 1 do
            t = t[bagian[i]]
            if type(t) ~= "table" then return nil end
        end
        local kunci = bagian[#bagian]
        if kunci == nil or t[kunci] == nil then return nil end
        t[kunci] = nilai
        normalisasi(Config.Data)
        kotor = true
        terakhirUbah = os.clock()
        Config.Berubah:Fire(path)
        return Config.Ambil(path)
    end

    -- Simpan otomatis: 1 dtk setelah perubahan terakhir; kalau gagal, coba lagi 30 dtk kemudian
    function Config.MulaiAutoSimpan()
        Core.Ulang("config-autosimpan", 1.5, function()
            local sekarang = os.clock()
            if kotor and sekarang - terakhirUbah >= 1 and sekarang >= tundaSampai then
                if not Config.Simpan() then tundaSampai = os.clock() + 30 end
            end
        end)
        Core.SaatBersih(function()
            if kotor then Config.Simpan() end
        end)
    end
end)() end

---------------------------------------------------------------------
-- MODUL 3: GAME (koneksi ke data & fungsi game lewat getgc)
---------------------------------------------------------------------
do (function()
    local Game = {}
    App.Game = Game

    local Core = App.Core
    local ReplicatedStorage = game:GetService("ReplicatedStorage")

    -- Hasil pencarian. Diisi oleh Game.Hubungkan
    --   World : tabel dunia (fg, bg, w, h, spawn, name, call, ...)
    --   Inv   : tabel tas (slots, capacity, count, add, remove, ...)
    --   Pos   : fungsi pembaca posisi karakter (hasil: tabel x, y, facing, vx, ...)
    --   Menu  : tabel menu game (openBackpack, ui, openPicker, enter)
    --   Hud   : tabel hud (punchRange, handPower, onDrop)
    --   Place : fungsi place game
    --   Punch : fungsi pukul game
    local Refs = {}
    Game.Refs = Refs
    Game.ItemDB = nil
    Game.InvModul = nil
    Game.Sibuk = false
    Game.Pesan = "Belum dihubungkan"
    Game.Berubah = Core.Sinyal()

    -- Ciri fungsi lewat konstanta. Ditulis terbalik lalu dibalik lagi saat jalan,
    -- supaya konstanta ini tidak cocok dengan fungsi milik script ini sendiri.
    local function balik(s) return string.reverse(s) end
    local CIRI = {
        tile = balik("elit"),
        setTile = balik("eliTteS"),
        placed = balik("tAdecalp"),
        flips = balik("spilf"),
        vending = balik("!tsrif enihcaM gnidneV eht ytpmE"),
        crack = balik("kcarCwen"),
        harvest = balik("redivorPtsevraH"),
    }

    local ambilKonstanta = (debug and debug.getconstants) or getconstants

    local function konstanta(fn)
        if not ambilKonstanta then return nil end
        if islclosure and not islclosure(fn) then return nil end
        local ok, t = pcall(ambilKonstanta, fn)
        if ok and type(t) == "table" then return t end
        return nil
    end

    -- Fungsi milik game (bukan milik executor / script ini): lolos dua penyaring berurutan.
    --   1) bukan closure buatan executor
    --   2) sumber skripnya GameGui (sumber kosong / tidak terbaca = dianggap milik game)
    local function buatanExecutor(fn)
        if type(isexecutorclosure) ~= "function" then return false end
        local ok, hasil = pcall(isexecutorclosure, fn)
        return (ok and hasil) and true or false
    end

    local function sumberSkrip(fn)
        local ok, s = pcall(debug.info, fn, "s")
        if ok and type(s) == "string" then return s end
        return ""
    end

    local function milikGame(fn)
        if buatanExecutor(fn) then return false end
        local sumber = sumberSkrip(fn)
        return sumber == "" or string.find(sumber, "GameGui", 1, true) ~= nil
    end

    -- Pencocok tabel -------------------------------------------------
    -- Tiap jenis tabel dikenali dari daftar bentuk berisi pasangan { kunci, jenis }.
    --   jenis = nama tipe Lua, atau "*" = nilai apa saja asal bukan nil.
    -- Pasangan memakai indeks angka (bukan kunci bernama) supaya daftar ini sendiri
    -- tidak pernah ikut cocok ketika getgc memindai script ini.
    local BENTUK_WORLD = { { "fg", "table" }, { "bg", "table" }, { "w", "number" }, { "h", "number" }, { "spawn", "*" } }
    local BENTUK_TAS = { { "slots", "table" }, { "capacity", "*" } }
    local BENTUK_POSISI = { { "x", "number" }, { "y", "number" }, { "facing", "*" }, { "vx", "*" } }
    local BENTUK_MENU = { { "openBackpack", "function" }, { "ui", "table" } }
    local BENTUK_HUD = { { "punchRange", "function" }, { "handPower", "function" } }

    local function bacaBiasa(t, k) return t[k] end

    -- Cocokkan tabel dengan satu daftar bentuk. `baca` = cara membaca kunci (bawaan rawget)
    local function sesuaiBentuk(t, bentuk, baca)
        baca = baca or rawget
        for i = 1, #bentuk do
            local kunci, jenis = bentuk[i][1], bentuk[i][2]
            local nilai = baca(t, kunci)
            if jenis == "*" then
                if nilai == nil then return false end
            elseif type(nilai) ~= jenis then
                return false
            end
        end
        return true
    end

    local function adalahWorld(v)
        return sesuaiBentuk(v, BENTUK_WORLD)
    end

    -- Tas = objek dari modul Inventory (metatable-nya modul itu). Modul belum dimuat -> bukan.
    local function adalahTas(v)
        local modul = Game.InvModul
        if modul == nil or getmetatable(v) ~= modul then return false end
        return sesuaiBentuk(v, BENTUK_TAS)
    end

    -- Pemegang posisi = tabel dengan fungsi `state` yang mengembalikan tabel posisi
    local function adalahPembacaPosisi(v)
        local baca = rawget(v, "state")
        if type(baca) ~= "function" then return false end
        local ok, keadaan = pcall(baca)
        if not ok or type(keadaan) ~= "table" then return false end
        return sesuaiBentuk(keadaan, BENTUK_POSISI, bacaBiasa)
    end

    local function adalahMenu(v)
        return sesuaiBentuk(v, BENTUK_MENU)
    end

    local function adalahHud(v)
        return sesuaiBentuk(v, BENTUK_HUD)
    end

    -- Jenis yang dicari, urutan = prioritas (satu tabel hanya jadi satu jenis).
    --   slot  : nama di Refs     cocok : pencocok     ambil : (opsional) nilai yang disimpan
    local JENIS_TABEL = {
        { slot = "World", cocok = adalahWorld },
        { slot = "Inv", cocok = adalahTas },
        { slot = "Pos", cocok = adalahPembacaPosisi, ambil = function(v) return rawget(v, "state") end },
        { slot = "Menu", cocok = adalahMenu },
        { slot = "Hud", cocok = adalahHud },
    }

    -- Dipanggil di dalam satu pcall per objek (hemat untuk ratusan ribu objek)
    local function periksaTabel(v)
        for i = 1, #JENIS_TABEL do
            local jenis = JENIS_TABEL[i]
            if Refs[jenis.slot] == nil and jenis.cocok(v) then
                Refs[jenis.slot] = jenis.ambil and jenis.ambil(v) or v
                return
            end
        end
    end

    -- Fungsi place & pukul dikenali dari konstanta; cek milikGame hanya kalau cocok
    local function periksaFungsi(fn)
        local k = konstanta(fn)
        if not k then return end
        local kirim, placed, flips, vending, crack = false, false, false, false, false
        for _, c in pairs(k) do
            if type(c) == "string" then
                if c == CIRI.tile or c == CIRI.setTile then
                    kirim = true
                elseif c == CIRI.placed then
                    placed = true
                elseif c == CIRI.flips then
                    flips = true
                elseif c == CIRI.vending then
                    vending = true
                elseif c == CIRI.crack or c == CIRI.harvest then
                    crack = true
                end
            end
        end
        if not Refs.Place and kirim and placed and flips and milikGame(fn) then
            Refs.Place = fn
        elseif not Refs.Punch and vending and crack and milikGame(fn) then
            Refs.Punch = fn
        end
    end

    local function lengkapDasar()
        return Refs.World ~= nil and Refs.Inv ~= nil and Refs.Pos ~= nil and Refs.Menu ~= nil
            and Refs.Hud ~= nil and Refs.Place ~= nil and Refs.Punch ~= nil
    end
    Game.Lengkap = lengkapDasar

    -- Pindai getgc dalam potongan kecil (±12 ms lalu menyerahkan frame) supaya HP tidak macet
    local function pindai()
        local daftar = getgc(true)
        local mulai = os.clock()
        local hitung = 0
        for i = 1, #daftar do
            local v = daftar[i]
            local tipe = type(v)
            if tipe == "table" then
                pcall(periksaTabel, v)
            elseif tipe == "function" and (not Refs.Place or not Refs.Punch) then
                pcall(periksaFungsi, v)
            end
            hitung = hitung + 1
            if hitung % 2500 == 0 then
                if lengkapDasar() then return end
                if os.clock() - mulai > 0.012 then
                    task.wait()
                    mulai = os.clock()
                    if not Core.Hidup() then return end
                end
            end
        end
    end

    local function muatModul()
        if Game.ItemDB and Game.InvModul then return true end
        local shared = ReplicatedStorage:WaitForChild("Shared", 10)
        if not shared then return false, "Folder Shared tidak ketemu" end
        local nDB = shared:WaitForChild("ItemDB", 5)
        local nInv = shared:WaitForChild("Inventory", 5)
        if not nDB or not nInv then return false, "Modul ItemDB / Inventory tidak ketemu" end
        local okA, db = pcall(require, nDB)
        local okB, inv = pcall(require, nInv)
        if not okA or not okB then return false, "Gagal memuat modul game" end
        Game.ItemDB, Game.InvModul = db, inv
        return true
    end

    -- Buang hasil lama yang sudah rusak (supaya dipindai ulang).
    -- Tabel World SENGAJA tidak diperiksa lewat fg: tabel itu tetap sama saat pindah world,
    -- hanya fg-nya yang diganti (dan fg boleh kosong / bukan tabel saat di luar world).
    -- Membuang World karena fg berubah akan memaksa pindai ulang yang tidak bisa menemukannya.
    local SYARAT_TABEL = {      -- { slot, kunci yang harus ada, jenisnya }
        { "Inv", "slots", "table" },
        { "Menu", "ui", "table" },
        { "Hud", "punchRange", "function" },
    }
    local SLOT_FUNGSI = { "Pos", "Place", "Punch" }

    local function validasi()
        if Refs.World ~= nil and type(Refs.World) ~= "table" then Refs.World = nil end
        for _, s in ipairs(SYARAT_TABEL) do
            local t = Refs[s[1]]
            if t ~= nil and (type(t) ~= "table" or type(rawget(t, s[2])) ~= s[3]) then
                Refs[s[1]] = nil
            end
        end
        for _, slot in ipairs(SLOT_FUNGSI) do
            if Refs[slot] ~= nil and type(Refs[slot]) ~= "function" then Refs[slot] = nil end
        end
    end

    -- Nama data dasar yang belum ketemu (untuk pesan di UI)
    local NAMA_DASAR = {
        { "World", "World" }, { "Inv", "Tas" }, { "Pos", "Posisi" }, { "Menu", "Menu" },
        { "Hud", "Hud" }, { "Place", "Place" }, { "Punch", "Pukul" },
    }
    local function daftarHilang()
        local hilang = {}
        for _, p in ipairs(NAMA_DASAR) do
            if Refs[p[1]] == nil then hilang[#hilang + 1] = p[2] end
        end
        return hilang
    end

    local function prosesHubung(paksa)
        if not getgc then
            Game.Pesan = "Executor tidak punya getgc()"
            return false
        end
        local ok, alasan = muatModul()
        if not ok then
            Game.Pesan = alasan
            return false
        end
        if paksa then
            for k in pairs(Refs) do Refs[k] = nil end
        else
            validasi()
        end
        if lengkapDasar() then
            Game.Pesan = "Terhubung"
            return true
        end
        Game.Pesan = "Memindai data game..."
        Game.Berubah:Fire()
        pindai()
        if lengkapDasar() then
            Game.Pesan = "Terhubung"
            return true
        end
        Game.Pesan = "Belum ketemu: " .. table.concat(daftarHilang(), ", ") .. "."
        return false
    end

    -- Hubungkan di thread sendiri. paksa = true: buang hasil lama, pindai dari awal
    function Game.Hubungkan(paksa)
        if Game.Sibuk then return end
        Game.Sibuk = true
        Game.Berubah:Fire()
        Core.Jalan("game-hubung", function()
            local ok, err = pcall(prosesHubung, paksa)
            Game.Sibuk = false
            if not ok then
                Game.Pesan = "Error: " .. tostring(err)
                Core.Galat("game-hubung", err)
            end
            Game.Berubah:Fire()
        end)
    end

    -- Dipakai Tahap 2-3: segarkan data (validasi + pindai yang kurang). Menunggu sampai selesai.
    -- Hasil: true kalau semua data dasar lengkap
    function Game.Segarkan()
        if Game.Sibuk then
            local t0 = os.clock()
            while Game.Sibuk and Core.Hidup() and os.clock() - t0 < 30 do task.wait(0.2) end
            return lengkapDasar()
        end
        Game.Sibuk = true
        local ok, err = pcall(prosesHubung, false)
        Game.Sibuk = false
        if not ok then Core.Galat("game-segarkan", err) end
        Game.Berubah:Fire()
        return lengkapDasar()
    end

    function Game.NamaWorld()
        local w = Refs.World
        local n = w and rawget(w, "name")
        if type(n) == "string" then return n end
        return ""
    end

    -- Rute masuk / keluar world -------------------------------------
    --   Masuk  : utama Menu.enter,      cadangan World.enter
    --   Keluar : utama Menu.openPicker, cadangan World.call("LeaveWorld")
    -- Hasil: { nama = teks, cadangan = true/false, jalan = fungsi } atau nil kalau tidak ada rute.
    -- Tahap 1 hanya menyediakan & menampilkan rute (tidak ada yang dipanggil di sini).
    -- Argumen Menu.enter / World.enter belum dipastikan, jadi `jalan` untuk masuk adalah fungsi
    -- aslinya; Tahap 3 yang menentukan argumennya. Rute keluar lewat World.call sudah membawa
    -- argumen "LeaveWorld".
    local function ambilFungsi(t, nama)
        if type(t) ~= "table" then return nil end
        local f = rawget(t, nama)
        if type(f) == "function" then return f end
        return nil
    end

    function Game.RuteMasuk()
        local f = ambilFungsi(Refs.Menu, "enter")
        if f then return { nama = "Menu.enter", cadangan = false, jalan = f } end
        f = ambilFungsi(Refs.World, "enter")
        if f then return { nama = "World.enter", cadangan = true, jalan = f } end
        return nil
    end

    function Game.RuteKeluar()
        local f = ambilFungsi(Refs.Menu, "openPicker")
        if f then return { nama = "Menu.openPicker", cadangan = false, jalan = f } end
        f = ambilFungsi(Refs.World, "call")
        if f then
            return {
                nama = 'World.call("LeaveWorld")',
                cadangan = true,
                jalan = function() return f("LeaveWorld") end,
            }
        end
        return nil
    end

    -- Coba ulang otomatis ---------------------------------------------
    -- Menjalankan proses hubung berulang dengan jeda yang makin panjang sampai data dasar
    -- lengkap (pindai getgc berat di HP, jadi tidak boleh rapat). Setelah lengkap, loop tetap
    -- berjaga: kalau ada data rusak / hilang, percobaan dimulai lagi sendiri. Satu-satunya
    -- alasan berhenti: executor tidak punya getgc (tidak akan pernah berhasil).
    local JEDA_COBA = { 3, 5, 8, 12, 20, 30 }   -- detik; percobaan ke-n memakai urutan ke-n
    local JEDA_JAGA = 4                         -- detik; jarak cek saat data sudah lengkap
    local utasCoba = nil
    Game.Percobaan = 0                          -- 0 = tidak sedang mencoba ulang

    -- Satu langkah. Hasil: detik menunggu sebelum langkah berikut, atau nil = berhenti
    local function langkahCoba()
        if not getgc then
            Game.Pesan = "Executor tidak punya getgc()"
            Game.Berubah:Fire()
            return nil
        end
        validasi()
        if lengkapDasar() then
            if Game.Percobaan > 0 then
                Game.Percobaan = 0
                Game.Pesan = "Terhubung"
                Game.Berubah:Fire()
            end
            return JEDA_JAGA
        end
        Game.Percobaan = Game.Percobaan + 1
        if Game.Segarkan() then return JEDA_JAGA end    -- direset di langkah berikut
        local jeda = JEDA_COBA[math.min(Game.Percobaan, #JEDA_COBA)]
        Game.Pesan = string.format("%s Coba lagi otomatis dalam %d dtk (percobaan ke-%d).",
            Game.Pesan, jeda, Game.Percobaan)
        Game.Berubah:Fire()
        return jeda
    end

    function Game.MulaiCobaUlang()
        if utasCoba then return utasCoba end
        utasCoba = Core.Jalan("game-coba-ulang", function()
            while Core.Hidup() do
                local ok, jeda = pcall(langkahCoba)
                if not ok then
                    Core.Galat("game-coba-ulang", jeda)
                    jeda = 10
                end
                if jeda == nil then return end
                task.wait(jeda)
            end
        end)
        return utasCoba
    end

    -- Daftar status untuk ditampilkan di UI:
    --   { nama, ok, tingkat, rute }
    --   tingkat : "utama" | "cadangan" (hanya baris yang punya rute); rute : nama rute dipakai
    function Game.Status()
        local function punyaFungsi(t, nama)
            return ambilFungsi(t, nama) ~= nil
        end
        local function barisRute(nama, rute)
            return {
                nama = nama,
                ok = rute ~= nil,
                tingkat = rute and (rute.cadangan and "cadangan" or "utama") or nil,
                rute = rute and rute.nama or nil,
            }
        end
        return {
            { nama = "World", ok = Refs.World ~= nil },
            { nama = "Tas (inventori)", ok = Refs.Inv ~= nil },
            { nama = "Posisi karakter", ok = Refs.Pos ~= nil },
            { nama = "Menu game", ok = Refs.Menu ~= nil },
            { nama = "Hud", ok = Refs.Hud ~= nil },
            { nama = "Fungsi place", ok = Refs.Place ~= nil },
            { nama = "Fungsi pukul", ok = Refs.Punch ~= nil },
            barisRute("Keluar world", Game.RuteKeluar()),
            barisRute("Masuk world", Game.RuteMasuk()),
            { nama = "Fungsi drop", ok = punyaFungsi(Refs.Hud, "onDrop") },
            { nama = "Fungsi recycle", ok = punyaFungsi(Refs.World, "call") },
        }
    end

    -- Pantau world ----------------------------------------------------
    -- Acuan (dari game): tabel World tetap sama saat pindah world, hanya fg yang diganti.
    -- Jadi World tidak pernah dipindai ulang; yang diamati adalah fg-nya:
    --   * identitas fg berganti  -> pindah world (State.IdWorld naik, sinyal WorldBerubah)
    --   * bentuk World + isi fg  -> State.DiWorld
    --
    -- ATURAN "DI DALAM WORLD" (SEMENTARA, Game.AturanTerkunci = false):
    --   World berbentuk world termuat (BENTUK_WORLD, bentuk yang sama yang dipakai menemukannya)
    --   DAN fg berisi sesuatu. Bentuk World saat di luar world BELUM dipastikan siapa pun, jadi
    --   aturan ini hanya memakai bukti "ada world termuat" dan tidak menebak isi di luar world.
    --   Kalau game membiarkan fg lama saat keluar, di luar world tidak akan terdeteksi; itu
    --   terlihat di kartu "Pantau world" (nomor fg tidak berubah). Setelah bentuk aslinya
    --   diamati, ubah hitungDiWorld lalu set Game.AturanTerkunci = true.
    Game.AturanTerkunci = false
    Game.WorldBerubah = Core.Sinyal()   -- dikirim dengan (diWorld, nama, idWorld)
    Game.Riwayat = {}                   -- peristiwa terakhir (maks 8), terbaru di akhir

    local nomorTabel = setmetatable({}, { __mode = "k" })
    local nomorBerikut = 0
    local function nomorDari(t)
        local n = nomorTabel[t]
        if not n then
            nomorBerikut = nomorBerikut + 1
            n = nomorBerikut
            nomorTabel[t] = n
        end
        return n
    end

    -- Penanda identitas fg: nomor tabel, atau nama tipe kalau bukan tabel (nil, dst.)
    local function kunciFg(fg)
        if type(fg) == "table" then return nomorDari(fg) end
        return type(fg)
    end

    local function hitungDiWorld(w)
        if not sesuaiBentuk(w, BENTUK_WORLD) then return false end
        return next(rawget(w, "fg")) ~= nil
    end

    -- "belum" = World belum ketemu, "dalam" / "luar" = hasil aturan di atas
    function Game.StatusWorld()
        if Refs.World == nil then return "belum" end
        return App.State.DiWorld and "dalam" or "luar"
    end

    local function catatRiwayat(teks)
        local r = Game.Riwayat
        r[#r + 1] = os.date("%H:%M:%S") .. " " .. teks
        if #r > 8 then table.remove(r, 1) end
        Core.Log("World: " .. teks)
    end

    local kunciTerakhir, sudahBaca = nil, false

    local function tickPantau()
        local S = App.State
        local w = Refs.World
        if w == nil then
            sudahBaca = false           -- World hilang: bacaan berikutnya dianggap baru
            S.DiWorld, S.NamaWorld = false, ""
            return
        end
        local kunci = kunciFg(rawget(w, "fg"))
        local di = hitungDiWorld(w)
        local nama = di and Game.NamaWorld() or ""
        local fgBerganti = (not sudahBaca) or kunci ~= kunciTerakhir
        local berubah = fgBerganti or di ~= S.DiWorld or nama ~= S.NamaWorld
        if fgBerganti then
            sudahBaca = true
            kunciTerakhir = kunci
            S.IdWorld = S.IdWorld + 1
        end
        S.DiWorld, S.NamaWorld = di, nama
        if berubah then
            catatRiwayat(string.format("fg=%s, di dalam=%s, nama=%s",
                tostring(kunci), tostring(di), nama ~= "" and nama or "-"))
            Game.WorldBerubah:Fire(di, nama, S.IdWorld)
        end
    end

    local pantauJalan = false
    function Game.MulaiPantau()
        if pantauJalan then return end
        pantauJalan = true
        Core.Ulang("game-pantau-world", 0.5, tickPantau)
    end

    -- Bacaan mentah tabel World untuk kartu "Pantau world" di UI. Dipakai untuk melihat sendiri
    -- seperti apa World saat di dalam & di luar world (jangan menebak).
    function Game.TeksBacaan()
        local w = Refs.World
        if w == nil then return "World belum ketemu" end
        local fg = rawget(w, "fg")
        local teksFg = tostring(fg)
        if type(fg) == "table" then
            local n = 0
            for _ in pairs(fg) do
                n = n + 1
                if n >= 50000 then break end
            end
            teksFg = string.format("tabel #%d, %s isi", nomorDari(fg), n >= 50000 and "50000+" or tostring(n))
        end
        return table.concat({
            "fg    : " .. teksFg,
            "bg    : " .. type(rawget(w, "bg")),
            "w x h : " .. tostring(rawget(w, "w")) .. " x " .. tostring(rawget(w, "h")),
            "name  : " .. tostring(rawget(w, "name")),
            "spawn : " .. type(rawget(w, "spawn")),
        }, "\n")
    end

    function Game.TeksRiwayat()
        if #Game.Riwayat == 0 then return "(belum ada perubahan world)" end
        return table.concat(Game.Riwayat, "\n")
    end
end)() end

---------------------------------------------------------------------
-- MODUL 4: UI (buatan sendiri: ungu gelap + emas, sidebar ikon, bisa digeser & dilipat)
---------------------------------------------------------------------
do (function()
    local UI = {}
    App.UI = UI

    local Core, Config, Game = App.Core, App.Config, App.Game
    local UIS = game:GetService("UserInputService")
    local Players = game:GetService("Players")

    -- Warna (tanpa biru / pink)
    local W = {
        Latar = Color3.fromRGB(24, 16, 22),
        Sidebar = Color3.fromRGB(30, 20, 28),
        Panel = Color3.fromRGB(38, 26, 36),
        Kartu = Color3.fromRGB(50, 35, 50),
        Garis = Color3.fromRGB(86, 62, 86),
        Ungu = Color3.fromRGB(78, 48, 100),
        Emas = Color3.fromRGB(214, 175, 58),
        EmasTerang = Color3.fromRGB(242, 210, 122),
        Teks = Color3.fromRGB(238, 228, 208),
        TeksRedup = Color3.fromRGB(170, 152, 148),
        Ok = Color3.fromRGB(120, 196, 112),
        Gagal = Color3.fromRGB(222, 98, 72),
    }
    UI.Warna = W

    -- ---------- pembantu dasar ----------
    local function buat(kelas, props, induk)
        local o = Instance.new(kelas)
        if props then
            for k, v in pairs(props) do o[k] = v end
        end
        if induk then o.Parent = induk end
        return o
    end
    UI.Buat = buat

    local function sudut(o, r)
        return buat("UICorner", { CornerRadius = UDim.new(0, r) }, o)
    end

    local function garis(o, warna, tebal)
        return buat("UIStroke", {
            Color = warna,
            Thickness = tebal or 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, o)
    end

    local function padding(o, atas, kiri, kanan, bawah)
        return buat("UIPadding", {
            PaddingTop = UDim.new(0, atas), PaddingLeft = UDim.new(0, kiri),
            PaddingRight = UDim.new(0, kanan), PaddingBottom = UDim.new(0, bawah),
        }, o)
    end

    -- Nomor urut anak di dalam induk (UIListLayout memakai LayoutOrder)
    local hitungAnak = setmetatable({}, { __mode = "k" })
    local function urut(induk)
        hitungAnak[induk] = (hitungAnak[induk] or 0) + 1
        return hitungAnak[induk]
    end

    local function layar()
        local cam = workspace.CurrentCamera
        if cam then return cam.ViewportSize end
        return Vector2.new(800, 400)
    end

    -- ---------- komponen ----------
    function UI.Teks(induk, teks, ukuran, warna, ekstra)
        local t = buat("TextLabel", {
            BackgroundTransparency = 1,
            Text = teks,
            TextSize = ukuran or 14,
            TextColor3 = warna or W.Teks,
            Font = Enum.Font.GothamMedium,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            LayoutOrder = urut(induk),
        }, induk)
        if ekstra then
            for k, v in pairs(ekstra) do t[k] = v end
        end
        return t
    end

    function UI.Tombol(induk, teks, aksi)
        local b = buat("TextButton", {
            Text = teks,
            Size = UDim2.new(1, 0, 0, 40),
            BackgroundColor3 = W.Ungu,
            BorderSizePixel = 0,
            AutoButtonColor = true,
            Font = Enum.Font.GothamBold,
            TextSize = 15,
            TextColor3 = W.EmasTerang,
            LayoutOrder = urut(induk),
        }, induk)
        sudut(b, 8)
        garis(b, W.Emas, 1)
        if aksi then Core.Hubung(b.Activated, aksi) end
        return b
    end

    function UI.Kartu(induk, judul)
        local k = buat("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = W.Kartu,
            BorderSizePixel = 0,
            LayoutOrder = urut(induk),
        }, induk)
        sudut(k, 8)
        garis(k, W.Garis, 1)
        padding(k, 10, 10, 10, 10)
        buat("UIListLayout", {
            Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
        }, k)
        if judul then
            UI.Teks(k, judul, 15, W.Emas, { Font = Enum.Font.GothamBold })
        end
        return k
    end

    -- Baris "nama .... nilai". Hasil: label nama, label nilai
    function UI.Baris(induk, nama)
        local b = buat("Frame", {
            Size = UDim2.new(1, 0, 0, 22),
            BackgroundTransparency = 1,
            LayoutOrder = urut(induk),
        }, induk)
        local kiri = buat("TextLabel", {
            BackgroundTransparency = 1, Size = UDim2.new(0.6, 0, 1, 0), Text = nama,
            TextSize = 14, Font = Enum.Font.GothamMedium, TextColor3 = W.Teks,
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        }, b)
        local kanan = buat("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromScale(0.6, 0),
            Size = UDim2.new(0.4, 0, 1, 0), Text = "-", TextSize = 14,
            Font = Enum.Font.GothamBold, TextColor3 = W.TeksRedup,
            TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd,
        }, b)
        return kiri, kanan
    end

    -- ---------- geser (jendela & gelembung) ----------
    -- selesai(jarakMaks) dipanggil saat jari / mouse dilepas (jarak kecil = hanya ketukan)
    local function bisaGeser(pegangan, target, selesai)
        local geser = false
        local mulai = Vector2.new(0, 0)
        local awal = target.Position
        local jarak = 0

        local function inputUtama(i)
            return i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch
        end

        Core.Hubung(pegangan.InputBegan, function(i)
            if inputUtama(i) then
                geser = true
                mulai = Vector2.new(i.Position.X, i.Position.Y)
                awal = target.Position
                jarak = 0
            end
        end)
        Core.Hubung(UIS.InputChanged, function(i)
            if not geser then return end
            if i.UserInputType ~= Enum.UserInputType.MouseMovement
                and i.UserInputType ~= Enum.UserInputType.Touch then
                return
            end
            local d = Vector2.new(i.Position.X, i.Position.Y) - mulai
            if d.Magnitude > jarak then jarak = d.Magnitude end
            local v = layar()
            local ukuran = target.AbsoluteSize
            local x = math.clamp(awal.X.Offset + d.X, 0, math.max(0, v.X - ukuran.X))
            local y = math.clamp(awal.Y.Offset + d.Y, 0, math.max(0, v.Y - ukuran.Y))
            target.Position = UDim2.fromOffset(x, y)
        end)
        Core.Hubung(UIS.InputEnded, function(i)
            if geser and inputUtama(i) then
                geser = false
                if selesai then selesai(jarak) end
            end
        end)
    end
    UI.BisaGeser = bisaGeser

    -- ---------- ikon sidebar (digambar dari kotak & cincin, bisa diwarnai) ----------
    local function pembuatIkon(wadah)
        local padat, cincin = {}, {}
        local o = {}
        -- kotak berpusat di (x, y)
        function o.kotak(x, y, l, t, rot)
            padat[#padat + 1] = buat("Frame", {
                BackgroundColor3 = W.Emas, BorderSizePixel = 0,
                AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x, y),
                Size = UDim2.fromOffset(l, t), Rotation = rot or 0,
            }, wadah)
        end
        -- kotak / lingkaran kosong dengan garis tepi
        function o.cincin(x, y, l, t, tebal, radius)
            local f = buat("Frame", {
                BackgroundTransparency = 1, BorderSizePixel = 0,
                AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x, y),
                Size = UDim2.fromOffset(l, t),
            }, wadah)
            if radius and radius > 0 then sudut(f, radius) end
            cincin[#cincin + 1] = garis(f, W.Emas, tebal)
        end
        function o.warnai(c)
            for _, f in ipairs(padat) do f.BackgroundColor3 = c end
            for _, s in ipairs(cincin) do s.Color = c end
        end
        return o
    end

    local Ikon = {}
    function Ikon.pabrik(wadah)
        local o = pembuatIkon(wadah)
        o.kotak(12, 16.5, 20, 9)   -- badan pabrik
        o.kotak(6, 8, 4, 8)        -- cerobong
        o.kotak(12, 10, 4, 4)
        o.kotak(18, 7, 4, 10)
        return o.warnai
    end
    function Ikon.masuklagi(wadah)
        local o = pembuatIkon(wadah)
        o.cincin(16, 12, 10, 18, 2, 0)  -- pintu
        o.kotak(6.5, 12, 11, 2)         -- panah masuk
        o.kotak(9, 9.5, 2, 6, -45)
        o.kotak(9, 14.5, 2, 6, 45)
        return o.warnai
    end
    function Ikon.pengaturan(wadah)
        local o = pembuatIkon(wadah)
        o.cincin(12, 12, 12, 12, 3, 6)  -- roda gigi
        o.kotak(12, 3.5, 4, 5)
        o.kotak(12, 20.5, 4, 5)
        o.kotak(3.5, 12, 5, 4)
        o.kotak(20.5, 12, 5, 4)
        return o.warnai
    end

    -- ---------- induk GUI (gethui > CoreGui > PlayerGui) ----------
    local function cariInduk()
        local ok, gui = pcall(function()
            if gethui then return gethui() end
            return nil
        end)
        if ok and gui then return gui end
        local okC, cg = pcall(function() return game:GetService("CoreGui") end)
        if okC and cg then
            local uji = Instance.new("Folder")
            local bisa = pcall(function() uji.Parent = cg end)
            pcall(function() uji:Destroy() end)
            if bisa then return cg end
        end
        return Players.LocalPlayer:WaitForChild("PlayerGui")
    end

    -- ---------- jendela utama ----------
    function UI.Bangun()
        local gui = buat("ScreenGui", {
            Name = "YutiCapital", ResetOnSpawn = false, DisplayOrder = 999,
            IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        })
        gui.Parent = cariInduk()
        UI.Gui = gui
        Core.SaatBersih(function() pcall(function() gui:Destroy() end) end)

        local v = layar()
        local lebar = math.clamp(v.X - 20, 300, 480)
        local tinggi = math.clamp(v.Y - 20, 220, 320)
        local x0, y0 = Config.Ambil("UI.X"), Config.Ambil("UI.Y")
        if x0 < 0 or y0 < 0 then
            x0, y0 = (v.X - lebar) / 2, (v.Y - tinggi) / 2
        end
        x0 = math.clamp(x0, 0, math.max(0, v.X - lebar))
        y0 = math.clamp(y0, 0, math.max(0, v.Y - tinggi))

        local jendela = buat("Frame", {
            Name = "Jendela", Size = UDim2.fromOffset(lebar, tinggi),
            Position = UDim2.fromOffset(x0, y0), BackgroundColor3 = W.Latar,
            BorderSizePixel = 0, ClipsDescendants = true,
        }, gui)
        sudut(jendela, 10)
        garis(jendela, W.Emas, 1.5)

        -- bilah judul (pegangan untuk menggeser)
        local bar = buat("Frame", {
            Name = "Bar", Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = W.Panel,
            BorderSizePixel = 0, Active = true,
        }, jendela)
        buat("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0),
            Size = UDim2.new(1, -100, 1, 0), Text = "YutiCapital", TextSize = 17,
            Font = Enum.Font.GothamBold, TextColor3 = W.Emas,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, bar)
        local tLipat = buat("TextButton", {
            Text = "-", Size = UDim2.fromOffset(38, 30), Position = UDim2.new(1, -84, 0, 4),
            BackgroundColor3 = W.Ungu, BorderSizePixel = 0, TextColor3 = W.EmasTerang,
            Font = Enum.Font.GothamBold, TextSize = 22, AutoButtonColor = true,
        }, bar)
        sudut(tLipat, 6)
        local tTutup = buat("TextButton", {
            Text = "X", Size = UDim2.fromOffset(38, 30), Position = UDim2.new(1, -42, 0, 4),
            BackgroundColor3 = W.Ungu, BorderSizePixel = 0, TextColor3 = W.EmasTerang,
            Font = Enum.Font.GothamBold, TextSize = 16, AutoButtonColor = true,
        }, bar)
        sudut(tTutup, 6)

        -- sidebar ikon (kiri) + isi (kanan)
        local sidebar = buat("Frame", {
            Name = "Sidebar", Position = UDim2.fromOffset(0, 38), Size = UDim2.new(0, 58, 1, -38),
            BackgroundColor3 = W.Sidebar, BorderSizePixel = 0,
        }, jendela)
        buat("UIListLayout", {
            Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
        }, sidebar)
        padding(sidebar, 8, 0, 0, 8)

        local isi = buat("Frame", {
            Name = "Isi", Position = UDim2.fromOffset(58, 38), Size = UDim2.new(1, -58, 1, -38),
            BackgroundTransparency = 1,
        }, jendela)
        local judulHalaman = buat("TextLabel", {
            BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 4),
            Size = UDim2.new(1, -20, 0, 24), Text = "", TextSize = 16,
            Font = Enum.Font.GothamBold, TextColor3 = W.EmasTerang,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, isi)
        local daerah = buat("Frame", {
            Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 1, -30),
            BackgroundTransparency = 1,
        }, isi)

        -- halaman
        local halaman = {}
        local urutan = 0
        local function pilihHalaman(id)
            local h = halaman[id]
            if not h then return end
            for k, x in pairs(halaman) do
                local aktif = (k == id)
                x.badan.Visible = aktif
                x.penanda.Visible = aktif
                x.tombol.BackgroundColor3 = aktif and W.Ungu or W.Sidebar
                x.warnai(aktif and W.EmasTerang or W.TeksRedup)
            end
            judulHalaman.Text = h.judul
            Config.Atur("UI.Halaman", id)
        end

        local function tambahHalaman(id, judul, pembuat)
            urutan = urutan + 1
            local tombol = buat("TextButton", {
                Text = "", Size = UDim2.fromOffset(46, 46), BackgroundColor3 = W.Sidebar,
                BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = urutan,
            }, sidebar)
            sudut(tombol, 8)
            local penanda = buat("Frame", {
                Size = UDim2.fromOffset(3, 24), Position = UDim2.new(0, 0, 0.5, -12),
                BackgroundColor3 = W.Emas, BorderSizePixel = 0, Visible = false,
            }, tombol)
            local wadah = buat("Frame", {
                Size = UDim2.fromOffset(24, 24), Position = UDim2.new(0.5, -12, 0.5, -12),
                BackgroundTransparency = 1,
            }, tombol)
            local warnai = pembuat(wadah)
            warnai(W.TeksRedup)

            local badan = buat("ScrollingFrame", {
                Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
                ScrollBarThickness = 4, ScrollBarImageColor3 = W.Emas,
                CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollingDirection = Enum.ScrollingDirection.Y, Visible = false,
            }, daerah)
            buat("UIListLayout", {
                Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
            }, badan)
            padding(badan, 4, 10, 12, 10)

            halaman[id] = { judul = judul, tombol = tombol, penanda = penanda, warnai = warnai, badan = badan }
            Core.Hubung(tombol.Activated, function() pilihHalaman(id) end)
            return badan
        end

        local hPabrik = tambahHalaman("pabrik", "Pabrik", Ikon.pabrik)
        local hMasuk = tambahHalaman("masuklagi", "Masuk Lagi", Ikon.masuklagi)
        local hAtur = tambahHalaman("pengaturan", "Pengaturan", Ikon.pengaturan)

        -- isi halaman Pabrik & Masuk Lagi dibuat di Tahap 4
        UI.Teks(UI.Kartu(hPabrik), "Kontrol, status, dan setelan Pabrik menyusul di Tahap 4.", 14, W.TeksRedup)
        UI.Teks(UI.Kartu(hMasuk), "Status dan setelan Masuk Lagi menyusul di Tahap 4.", 14, W.TeksRedup)

        -- halaman Pengaturan: status koneksi ke game (untuk tes Tahap 1)
        local kKoneksi = UI.Kartu(hAtur, "Koneksi ke game")
        local labelWorld = UI.Teks(kKoneksi, "World: -", 14, W.Teks)
        local nilaiBaris = {}
        for i, s in ipairs(Game.Status()) do
            local _, nilai = UI.Baris(kKoneksi, s.nama)
            nilaiBaris[i] = nilai
        end
        -- OK = rute utama, CADANGAN = hanya rute cadangan yang ada, BELUM = tidak ada
        local labelRute = UI.Teks(kKoneksi, "", 12, W.TeksRedup)
        local labelPesan = UI.Teks(kKoneksi, Game.Pesan, 13, W.TeksRedup)
        local tHubung = UI.Tombol(kKoneksi, "Hubungkan ulang", function()
            Game.Hubungkan(true)
        end)

        -- bacaan mentah tabel World: keluar-masuk world sambil melihat kartu ini
        local kPantau = UI.Kartu(hAtur, "Pantau world")
        local labelDi = UI.Teks(kPantau, "-", 14, W.Teks)
        local labelBacaan = UI.Teks(kPantau, "-", 12, W.TeksRedup, { Font = Enum.Font.Code })
        local labelRiwayat = UI.Teks(kPantau, "", 12, W.TeksRedup, { Font = Enum.Font.Code })

        local function segarkanStatus()
            local teksRute = {}
            for i, s in ipairs(Game.Status()) do
                local n = nilaiBaris[i]
                if n then
                    if not s.ok then
                        n.Text, n.TextColor3 = "BELUM", W.Gagal
                    elseif s.tingkat == "cadangan" then
                        n.Text, n.TextColor3 = "CADANGAN", W.Emas
                    else
                        n.Text, n.TextColor3 = "OK", W.Ok
                    end
                end
                if s.rute then teksRute[#teksRute + 1] = s.nama .. " lewat " .. s.rute end
            end
            labelRute.Text = #teksRute > 0 and table.concat(teksRute, "\n") or "Rute masuk / keluar world belum tersedia"
            local sw = Game.StatusWorld()
            local nama = App.State.NamaWorld
            if sw == "belum" then
                labelWorld.Text = "World: (belum terhubung)"
            elseif sw == "luar" then
                labelWorld.Text = "World: (di luar world)"
            else
                labelWorld.Text = "World: " .. (nama ~= "" and nama or "(tanpa nama)")
            end
            labelDi.Text = "Di dalam world: " .. (sw == "belum" and "-" or (sw == "dalam" and "YA" or "TIDAK"))
                .. (Game.AturanTerkunci and "" or "  (aturan sementara)")
            labelBacaan.Text = Game.TeksBacaan()
            labelRiwayat.Text = Game.TeksRiwayat()
            labelPesan.Text = Game.Pesan
            tHubung.Text = Game.Sibuk and "Memindai..." or "Hubungkan ulang"
        end
        Core.Hubung(Game.Berubah, segarkanStatus)
        Core.Hubung(Game.WorldBerubah, segarkanStatus)
        Core.Ulang("ui-status", 1, segarkanStatus)

        -- gelembung (tampilan saat dilipat)
        local gelembung = buat("TextButton", {
            Name = "Gelembung", Size = UDim2.fromOffset(48, 48), BackgroundColor3 = W.Ungu,
            BorderSizePixel = 0, Text = "Y", Font = Enum.Font.GothamBold, TextSize = 24,
            TextColor3 = W.Emas, AutoButtonColor = false, Visible = false,
            Position = UDim2.fromOffset(x0, y0),
        }, gui)
        sudut(gelembung, 24)
        garis(gelembung, W.Emas, 2)

        local function jepitKe(o, ukuranX, ukuranY)
            local vv = layar()
            local p = o.Position
            o.Position = UDim2.fromOffset(
                math.clamp(p.X.Offset, 0, math.max(0, vv.X - ukuranX)),
                math.clamp(p.Y.Offset, 0, math.max(0, vv.Y - ukuranY)))
        end

        local function simpanPosisi()
            Config.Atur("UI.X", math.floor(jendela.Position.X.Offset))
            Config.Atur("UI.Y", math.floor(jendela.Position.Y.Offset))
        end

        local function setLipat(lipat)
            if lipat then
                gelembung.Position = jendela.Position
                jepitKe(gelembung, 48, 48)
            else
                jendela.Position = gelembung.Position
                jepitKe(jendela, lebar, tinggi)
                simpanPosisi()
            end
            jendela.Visible = not lipat
            gelembung.Visible = lipat
            Config.Atur("UI.Lipat", lipat)
        end

        bisaGeser(bar, jendela, function() simpanPosisi() end)
        bisaGeser(gelembung, gelembung, function(jarak)
            if jarak < 8 then setLipat(false) end
        end)
        Core.Hubung(tLipat.Activated, function() setLipat(true) end)
        Core.Hubung(tTutup.Activated, function() Core.Bersih() end)

        -- layar diputar: jepit ulang posisi
        local cam = workspace.CurrentCamera
        if cam then
            Core.Hubung(cam:GetPropertyChangedSignal("ViewportSize"), function()
                jepitKe(jendela, lebar, tinggi)
                jepitKe(gelembung, 48, 48)
            end)
        end

        pilihHalaman(Config.Ambil("UI.Halaman"))
        if Config.Ambil("UI.Lipat") then
            gelembung.Position = jendela.Position
            jendela.Visible = false
            gelembung.Visible = true
        end
        segarkanStatus()
        return true
    end
end)() end

---------------------------------------------------------------------
-- MULAI
---------------------------------------------------------------------
do (function()
    local Core, Config, Game, UI = App.Core, App.Config, App.Game, App.UI

    Core.Aman(Config.Muat)
    Core.Aman(Config.MulaiAutoSimpan)
    local ok = Core.Aman(UI.Bangun)
    if not ok then
        warn("[YutiCapital] Jendela UI gagal dibuat, lihat pesan galat di atas")
    end
    Game.MulaiPantau()      -- isi State.DiWorld / NamaWorld / IdWorld dari tabel World
    Game.MulaiCobaUlang()   -- hubungkan ke game, ulangi otomatis sampai data lengkap
    Core.Log("YutiCapital " .. App.Versi .. " siap")
end)() end
