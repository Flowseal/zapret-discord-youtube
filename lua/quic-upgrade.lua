local quic_v1 = string.char(0, 0, 0, 1)
local quic_v2_long_header = string.char(0xd0, 0x6b, 0x33, 0x43, 0xcf)

function quic_upgrade(ctx, desync)
    if not desync.outgoing or not desync.dis.udp or not replay_first(desync) then
        return
    end

    local payload = desync.dis.payload
    if #payload < 7 or payload:sub(2, 5) ~= quic_v1 then
        return
    end

    local dcid_length = payload:byte(6)
    local scid_length = payload:byte(7 + dcid_length)
    if dcid_length < 8 or dcid_length > 20 or not scid_length or scid_length > 20 then
        return
    end

    local header_end = 7 + dcid_length + scid_length
    if #payload < header_end then
        return
    end

    local header = quic_v2_long_header .. payload:sub(6, header_end)
    rawsend_payload_segmented(desync, header .. string.rep("\0", 1200 - #header))
end
