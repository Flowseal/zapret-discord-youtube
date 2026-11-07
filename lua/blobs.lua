local log = DLOG or print

-- шаблон
local blobs = {
	ACTIVE_DISCORD   = "ACTIVE_DISCORD_UDP.bin",
	ACTIVE_GAME      = "ACTIVE_GAME_UDP.bin",
	quic_4pda        = "quic_initial_4pda_to.bin",
	quic_5ka         = "quic_initial_5ka_ru.bin",
	quic_lemana      = "quic_initial_lemana_pro.bin",
	quic_rutube      = "quic_initial_rutube_ru.bin",
	quic_steam_chat  = "quic_initial_steam_chat_com.bin",
	quic_steamcomm   = "quic_initial_steamcommunity_com.bin",
	quic_steamstatic = "quic_initial_steamstatic_com.bin",
	quic_tencent     = "quic_initial_tencent_com.bin",
	quic_google      = "quic_initial_www_google_com.bin",
	stun             = "stun.bin",
	stun2            = "stun2.bin",
	tls_4pda         = "tls_clienthello_4pda_to.bin",
	tls_5ka          = "tls_clienthello_5ka_ru.bin",
	tls_awswaf       = "tls_clienthello_awswaf_com.bin",
	tls_onetrust     = "tls_clienthello_max_ru.bin",
	tls_sochi_park   = "tls_clienthello_sochi_park.bin",
	tls_steam_chat   = "tls_clienthello_steam_chat_com.bin",
	tls_steamstatic  = "tls_clienthello_steamstatic_com.bin",
	tls_teamspeak    = "tls_clienthello_teamspeak_com.bin",
	tls_google       = "tls_clienthello_www_google_com.bin",
	tls_sferum       = "tls_clienthello_www_sferum_ru.bin",
}

local folders = { "", "bin/" }
local exedir = os.getenv("EXEDIR") 
if exedir and exedir ~= "" then
    table.insert(folders, exedir .. "/")
    table.insert(folders, exedir .. "/bin/")
end

local function load(file)
    local errors = {}

    for _, folder in ipairs(folders) do
        local path = folder .. file
        local f, err = io.open(path, "rb")

        if f then
            local data, read_error = f:read("*a")
            f:close()

            if not data then
                return nil, path .. ": " .. tostring(read_error)
            end
            return data, path
        end

        table.insert(errors, tostring(err))
    end

    return nil, table.concat(errors, "; ")
end

local names = {}
for name in pairs(blobs) do
    table.insert(names, name)
end
table.sort(names)

local count = 0
local problems = {}

for _, name in ipairs(names) do
    local data, path = load(blobs[name])

    if not data then
        table.insert(problems, name .. " : " .. path)
    elseif data == "" then
        table.insert(problems, name .. " : " .. path .. " is empty")
    else
        if _G[name] ~= nil then
            log("blobs.lua: WARNING: '" .. name .. "' already exists and will be overwritten") -- если переменная (например tls_google) уже была задана 2 раза,
        end                                                                                    -- то скрипт заменит последнее ее содержимое фейком из указанного файла

        _G[name] = data
        count = count + 1
        log("blobs.lua: " .. name .. " = " .. path .. " (" .. #data .. " bytes)")
    end
end

if #problems > 0 then
    error("blobs.lua: " .. #problems .. " of " .. #names .. " blobs failed:\n  " ..
        table.concat(problems, "\n  "), 0)
end

log("blobs.lua: " .. count .. " blobs loaded")
