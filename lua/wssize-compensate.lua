local function window_shift(tcp)
    local index = find_tcp_option(tcp.options, TCP_KIND_SCALE)
    local data = index and tcp.options[index].data
    if type(data) == "string" and #data == 1 then
        local shift = data:byte(1)
        if shift <= 14 then return shift end
    end
end

function wssize_compensate(_, desync)
    local dis, track = desync.dis, desync.track
    local tcp = dis.tcp
    if not tcp or not track or dis.frag or dis.frag_off or
       find_tcp_option(tcp.options, TCP_KIND_MD5) or find_tcp_option(tcp.options, TCP_KIND_AO) then
        return
    end

    local flags = bitand(tcp.th_flags, TH_SYN + TH_ACK + TH_FIN + TH_RST)
    local has_data = #(dis.payload or "") > 0
    local state = track.lua_state.wssize_compensate

    -- todo: custom scale factor

    if desync.outgoing and flags == TH_SYN then
        local shift = window_shift(tcp)
        if has_data or not shift or shift <= 1 then
            track.lua_state.wssize_compensate = nil
        elseif not state or state.syn_seq ~= tcp.th_seq then
            track.lua_state.wssize_compensate = {
                syn_seq = tcp.th_seq,
                multiplier = 2 ^ (shift - 1),
            }
        end
        return
    end

    if not state then return end
    if not desync.outgoing then
        if flags == TH_SYN + TH_ACK and tcp.th_ack == u32add(state.syn_seq, 1) then
            state.scaling = window_shift(tcp) ~= nil
        end
        return
    end

    if not state.past_cutoff then
        state.past_cutoff = has_data
        return
    end

    if not state.scaling or bitand(flags, TH_ACK) == 0 or bitand(flags, TH_SYN + TH_RST) ~= 0 then
        return
    end

    local window = math.min(65535, tcp.th_win * state.multiplier)
    if window ~= tcp.th_win then
        tcp.th_win = window
        return VERDICT_MODIFY
    end
end
