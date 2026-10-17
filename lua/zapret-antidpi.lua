--[[

NFQWS2 ANTIDPI LIBRARY

--lua-init=@zapret-lib.lua --lua-init=@zapret-antidpi.lua
--lua-desync=func1:arg1[=val1]:arg2[=val2] --lua-desync=func2:arg1[=val1]:arg2[=val2] .... --lua-desync=funcN:arg1[=val1]:arg2[=val2]

BLOBS

blobs can be 0xHEX, field name in desync or global var
standard way to bring binary data to lua code is using the "--blob" parameter of nfqws2
dynamic blobs can be inside desync table. one function can prepare data for next functions.

STANDARD FUNCTION ARGS

standard direction :

* dir = in|out|any

standard fooling :

* ip_ttl=N - set ipv.ip_ttl to N
* ip6_ttl=N - set ip6.ip6_hlim to N
* ip_autottl=delta,min-max - set ip.ip_ttl to auto discovered ttl
* ip6_autottl=delta,min-max - set ip.ip_ttl to auto discovered ttl

* ip6_hopbyhop[=hex] - add hopbyhop ipv6 header with optional data. data size must be 6+N*8. all zero by default.
* ip6_hopbyhop2[=hex] - add second hopbyhop ipv6 header with optional data. data size must be 6+N*8. all zero by default.
* ip6_destopt[=hex] - add destopt ipv6 header with optional data. data size must be 6+N*8. all zero by default.
* ip6_destopt2[=hex] - add second destopt ipv6 header with optional data. data size must be 6+N*8. all zero by default.
* ip6_routing[=hex] - add routing ipv6 header with optional data. data size must be 6+N*8. all zero by default.
* ip6_ah[=hex] - add authentication ipv6 header with optional data. data size must be 6+N*4. 0000 + 4 random bytes by default.

* tcp_seq=N - add N to tcp.th_seq
* tcp_ack=N - add N to tcp.th_ack
* tcp_ts=N - add N to timestamp value
* tcp_md5[=hex] - add MD5 header with optional 16-byte data. all zero by default.
* tcp_flags_set=<list> - set tcp flags in comma separated list
* tcp_flags_unset=<list> - unset tcp flags in comma separated list
* tcp_ts_up - move timestamp tcp option to the top if present (workaround for badack without badseq fooling)
* tcp_nop_del - delete NOP tcp options to free space in tcp header

* fool=fool_function - custom fooling function : fool_func(dis, fooling_options)

standard reconstruct :

* badsum - make L4 checksum invalid

standard rawsend :

* repeats - how many time send the packet
* ifout - override outbound interface (if --bind_fix4, --bind-fix6 enabled)
* fwmark - override fwmark. desync mark bit(s) will be set unconditionally

standard payload :

* payload - comma separated list of allowed payload types. if not present - allow non-empty known payloads.

standard ip_id :

* ip_id - seq|rnd|zero|none
* ip_id_conn - in 'seq' mode save current ip_id in track.lua_state to use it between packets

standard ipfrag :

* ipfrag[=frag_function] - ipfrag function name. "ipfrag2" by default if empty
* ipfrag_disorder - send fragments from last to first
* ipfrag2 : ipfrag_pos_tcp - tcp frag position. ipv4 : starting from L4 header. ipv6: starting from fragmentable part. must be multiple of 8. default 32
* ipfrag2 : ipfrag_pos_udp - udp frag position. ipv4 : starting from L4 header. ipv6: starting from fragmentable part. must be multiple of 8. default 8
* ipfrag2 : ipfrag_pos_icmp - icmp frag position. ipv4 : starting from L4 header. ipv6: starting from fragmentable part. must be multiple of 8. default 8
* ipfrag2 : ipfrag_pos - frag position for other L4. ipv4 : starting from L4 header. ipv6: starting from fragmentable part. must be multiple of 8. default 32
* ipfrag2 : ipfrag_next - next protocol field in ipv6 fragment extenstion header of the second fragment. same as first by default.

]]


-- drop packet
-- standard args : direction, payload
function drop(ctx, desync)
	direction_cutoff_opposite(ctx, desync, "any")
	if direction_check(desync, "any") and payload_check(desync,"all") then
		DLOG("drop")
		return VERDICT_DROP
	end
end

-- nfqws1 : "--dup"
-- standard args : direction, fooling, ip_id, ipfrag, rawsend, reconstruct
-- arg : delay=<msec> - drop and send delayed
function send(ctx, desync)
	direction_cutoff_opposite(ctx, desync, "any")
	if direction_check(desync, "any") then
		DLOG("send")
		local dis = deepcopy(desync.dis)
		apply_fooling(desync, dis)
		apply_ip_id(desync, dis, nil, "none")
		if desync.arg.delay then
			local tname = desync_timer_name(desync)
			timer_set(tname, "send_timer_delayed", tonumber(desync.arg.delay), true, {dis = dis, opts = desync_opts(desync)})
		else
			-- it uses rawsend, reconstruct and ipfrag options
			rawsend_dissect_ipfrag(dis, desync_opts(desync))
		end
	end
end
function send_timer_delayed(name, data)
	-- oneshot timer, auto deletes
	rawsend_dissect_ipfrag(data.dis, data.opts)
end

-- nfqws1 : "--orig"
-- apply modification to current packet
-- standard args : direction, fooling, ip_id
function pktmod(ctx, desync)
	direction_cutoff_opposite(ctx, desync, "any")
	if direction_check(desync, "any") then
		-- apply to current packet
		apply_fooling(desync)
		apply_ip_id(desync, nil, nil, "none")
		DLOG("pktmod: applied")
		return VERDICT_MODIFY
	end
end

-- nfqws1 : "--domcase"
-- standard args : direction
function http_domcase(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.l7payload=="http_req" and direction_check(desync) then
		local host_range = resolve_multi_pos(desync.dis.payload,desync.l7payload,"host,endhost")
		if #host_range == 2 then
			local host = string.sub(desync.dis.payload,host_range[1],host_range[2]-1)
			local newhost=""
			for i = 1, #host do
				newhost=newhost..((i%2)==0 and string.lower(string.sub(host,i,i)) or string.upper(string.sub(host,i,i)))
			end
			DLOG("http_domcase: "..host.." => "..newhost)
			desync.dis.payload = string.sub(desync.dis.payload, 1, host_range[1]-1)..newhost..string.sub(desync.dis.payload, host_range[2])
			return VERDICT_MODIFY
		else
			DLOG("http_domcase: cannot find host range")
		end
	end
end

-- nfqws1 : "--hostcase"
-- standard args : direction
-- arg : spell=<str> . spelling of the "Host" header. must be exactly 4 chars long
function http_hostcase(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.l7payload=="http_req" and direction_check(desync) then
		local spell = desync.arg.spell or "host"
		if #spell ~= 4 then
			error("http_hostcase: invalid host spelling '"..spell.."'")
		else
			local hdis = http_dissect_req(desync.dis.payload)
			if hdis then
				local idx_host = array_field_search(hdis.headers, "header_low", "host")
				if idx_host then
					DLOG("http_hostcase: 'Host:' => '"..spell.."'")
					desync.dis.payload = string.sub(desync.dis.payload,1,hdis.headers[idx_host].pos_start-1)..spell..string.sub(desync.dis.payload,hdis.headers[idx_host].pos_header_end+1)
					return VERDICT_MODIFY
				else
					DLOG("http_hostcase: 'Host:' header not found")
				end
			else
				DLOG("http_hostcase: http dissect error")
			end
		end
	end
end

-- nfqws1 : "--methodeol"
-- standard args : direction
-- NOTE : if using with other http tampering methodeol should be the last !
function http_methodeol(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.l7payload=="http_req" and direction_check(desync) then
		local hdis = http_dissect_req(desync.dis.payload)
		if hdis then
			local idx_ua = array_field_search(hdis.headers, "header_low", "user-agent")
			if idx_ua then
				local ua = hdis.headers[idx_ua]
				if (ua.pos_end - ua.pos_value_start) < 2 then
					DLOG("http_methodeol: 'User-Agent:' header is too short")
				else
					DLOG("http_methodeol: applied")
					desync.dis.payload="\r\n"..string.sub(desync.dis.payload,1,ua.pos_end-2)..(string.sub(desync.dis.payload,ua.pos_end+1) or "");
					return VERDICT_MODIFY
				end
			else
				DLOG("http_methodeol: 'User-Agent:' header not found")
			end
		else
			DLOG("http_methodeol: http dissect error")
		end
	end
end

-- nfqws1 : not available
-- tpws : --unixeol
-- standard args : direction
function http_unixeol(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.l7payload=="http_req" and direction_check(desync) then
		local hdis = http_dissect_req(desync.dis.payload)
		if hdis then
			local idx_ua = array_field_search(hdis.headers, "header_low", "user-agent")
			if idx_ua then
				local http = http_reconstruct_req(hdis, true)
				if #http < #desync.dis.payload then
					hdis.headers[idx_ua].value = hdis.headers[idx_ua].value .. string.rep(" ", #desync.dis.payload - #http)
				end
				http = http_reconstruct_req(hdis, true)
				if #http==#desync.dis.payload then
					desync.dis.payload = http
					DLOG("http_unixeol: applied")
					return VERDICT_MODIFY
				else
					DLOG("http_unixeol: reconstruct differs in size from original: "..#http.."!="..#desync.dis.payload)
				end
			else
				DLOG("http_unixeol: 'User-Agent:' header absent")
			end
		else
			DLOG("http_unixeol: could not dissect http")
		end
	end
end

-- nfqws1 : "--synack-split"
-- standard args : rawsend, reconstruct, ipfrag
-- arg : mode=syn|synack|acksyn . "synack" by default
function synack_split(ctx, desync)
	if desync.dis.tcp then
		if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_SYN + TH_ACK) then
			local mode = desync.arg.mode or "synack"
			local options = desync_opts(desync)
			if mode=="syn" then
				local dis = deepcopy(desync.dis)
				dis.tcp.th_flags = bitand(desync.dis.tcp.th_flags, bitnot(TH_ACK))
				DLOG("synack_split: sending SYN")
				if not rawsend_dissect_ipfrag(dis, options) then return VERDICT_PASS end
				return VERDICT_DROP
			elseif mode=="synack" then
				local dis = deepcopy(desync.dis)
				dis.tcp.th_flags = bitand(desync.dis.tcp.th_flags, bitnot(TH_ACK))
				DLOG("synack_split: sending SYN")
				if not rawsend_dissect_ipfrag(dis, options) then return VERDICT_PASS end
				dis.tcp.th_flags = bitand(desync.dis.tcp.th_flags, bitnot(TH_SYN))
				DLOG("synack_split: sending ACK")
				if not rawsend_dissect_ipfrag(dis, options) then return VERDICT_PASS end
				return VERDICT_DROP
			elseif mode=="acksyn" then
				local dis = deepcopy(desync.dis)
				dis.tcp.th_flags = bitand(desync.dis.tcp.th_flags, bitnot(TH_SYN))
				DLOG("synack_split: sending ACK")
				if not rawsend_dissect_ipfrag(dis, options) then return VERDICT_PASS end
				dis.tcp.th_flags = bitand(desync.dis.tcp.th_flags, bitnot(TH_ACK))
				DLOG("synack_split: sending SYN")
				if not rawsend_dissect_ipfrag(dis, options) then return VERDICT_PASS end
				return VERDICT_DROP
			else
				error("synack_split: bad mode '"..mode.."'")
			end
		else
			instance_cutoff_shim(ctx, desync) -- mission complete
		end
	else
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
	end
end

-- nfqws1 : "--dpi-desync=synack"
-- standard args : rawsend, reconstruct, ipfrag
function synack(ctx, desync)
	if desync.dis.tcp then
		if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK)==TH_SYN then
			local dis = deepcopy(desync.dis)
			dis.tcp.th_flags = bitor(dis.tcp.th_flags, TH_ACK)
			DLOG("synack: sending")
			rawsend_dissect_ipfrag(dis, desync_opts(desync))
		else
			instance_cutoff_shim(ctx, desync) -- mission complete
		end
	else
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
	end
end


-- nfqws1 : "--wsize"
-- arg : wsize=N . tcp window size
-- arg : scale=N . tcp option scale factor
function wsize(ctx, desync)
	if desync.dis.tcp then
		if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK) == (TH_SYN + TH_ACK) then
			if wsize_rewrite(desync.dis, desync.arg) then
				return VERDICT_MODIFY
			end
		else
			instance_cutoff_shim(ctx, desync) -- mission complete
		end
	else
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
	end
end

-- nfqws1 : "--wssize"
-- standard args : direction
-- arg : wsize=N . tcp window size
-- arg : scale=N . tcp option scale factor
-- arg : forced_cutoff=<list> - comma separated list of payloads that trigger forced wssize cutoff. by default - any non-empty payload
function wssize(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	local verdict = VERDICT_PASS
	direction_cutoff_opposite(ctx, desync)
	if direction_check(desync) then
		if wsize_rewrite(desync.dis, desync.arg) then
			verdict = VERDICT_MODIFY
		end
		if #desync.dis.payload>0 and (not desync.arg.forced_cutoff or in_list(desync.arg.forced_cutoff, desync.l7payload)) then
			DLOG("wssize: forced cutoff")
			instance_cutoff_shim(ctx, desync)
		end
	end
	return verdict
end

-- nfqws1 : not available
-- standard args : direction
-- arg: blob - blob name to store cloned tls client hello (stored in desync, not global)
-- arg: fallback - copy this blob if could not clone
-- arg: sni_snt - server name type value in existing names
-- arg: sni_snt_new - server name type value for new names
-- arg: sni_del_ext - delete sni extension
-- arg: sni_del - delete all names
-- arg: sni_first - add name to the beginning
-- arg: sni_last - add name to the end
function tls_client_hello_clone(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if direction_check(desync) then
		if not desync.arg.blob then
			error("tls_client_hello_clone: 'blob' arg required")
		end
		if desync.l7payload=="tls_client_hello" then
			desync[desync.arg.blob] = tls_client_hello_mod(desync.reasm_data or desync.dis.payload, desync.arg)
			if desync[desync.arg.blob] then
				DLOG("tls_client_hello_clone: cloned to desync."..desync.arg.blob)
			end
		end
		if not desync[desync.arg.blob] and desync.arg.fallback then
			DLOG("tls_client_hello_clone: desync."..desync.arg.blob.."="..desync.arg.fallback)
			desync[desync.arg.blob] = blob(desync, desync.arg.fallback)
		end
	end
end

-- nfqws1 : "--dpi-desync=syndata"
-- standard args : fooling, rawsend, reconstruct, ipfrag
-- arg : blob=<blob> - fake payload. must fit to single packet. no segmentation possible. default - 16 zero bytes.
-- arg : tls_mod=<list> - comma separated list of tls mods : rnd,rndsni,sni=<str>. sni=%var is supported
function syndata(ctx, desync)
	if desync.dis.tcp then
		if bitand(desync.dis.tcp.th_flags, TH_SYN + TH_ACK)==TH_SYN then
			local dis = deepcopy(desync.dis)
			dis.payload = blob(desync, desync.arg.blob, "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")
			apply_fooling(desync, dis)
			if desync.arg.tls_mod then
				local pl = tls_mod_shim(desync, dis.payload, desync.arg.tls_mod, nil)
				if pl then dis.payload = pl end
			end
			if b_debug then DLOG("syndata: "..hexdump_dlog(dis.payload)) end
			if rawsend_dissect_ipfrag(dis, desync_opts(desync)) then
				return VERDICT_DROP
			end
		else
			instance_cutoff_shim(ctx, desync) -- mission complete
		end
	else
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
	end
end

-- nfqws1 : "--dpi-desync=rst"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : rstack - send RST,ACK instead of RST
function rst(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if direction_check(desync, "any") and payload_check(desync) then
		if replay_first(desync) then
			local dis = deepcopy(desync.dis)
			dis.payload = ""
			dis.tcp.th_flags = TH_RST + (desync.arg.rstack and TH_ACK or 0)
			apply_fooling(desync, dis)
			apply_ip_id(desync, dis, nil, "none")
			DLOG("rst")
			-- it uses rawsend, reconstruct and ipfrag options
			rawsend_dissect_ipfrag(dis, desync_opts(desync))
		else
			DLOG("rst: not acting on further replay pieces")
		end
	end
end

-- nfqws1 : "--dpi-desync=fake"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : blob=<blob> - fake payload
-- arg : optional - skip if blob is absent
-- arg : tls_mod=<list> - comma separated list of tls mods : rnd,rndsni,sni=<str>,dupsid,padencap . sni=%var is supported
function fake(ctx, desync)
	direction_cutoff_opposite(ctx, desync)
	-- by default process only outgoing known payloads. works only for tcp and udp
	if (desync.dis.tcp or desync.dis.udp) and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			if not desync.arg.blob then
				error("fake: 'blob' arg required")
			end
			if desync.arg.optional and not blob_exist(desync, desync.arg.blob) then
				DLOG("fake: blob '"..desync.arg.blob.."' not found. skipped")
				return
			end
			local fake_payload = blob(desync, desync.arg.blob)
			if desync.reasm_data and desync.arg.tls_mod then
				local pl = tls_mod_shim(desync, fake_payload, desync.arg.tls_mod, desync.reasm_data)
				if pl then fake_payload = pl end
			end
			-- check debug to save CPU
			if b_debug then DLOG("fake: "..hexdump_dlog(fake_payload)) end
			rawsend_payload_segmented(desync,fake_payload)
		else
			DLOG("fake: not acting on further replay pieces")
		end
	end
end

-- nfqws1 : "--dpi-desync=multisplit"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : pos=<posmarker list> . position marker list. for example : "1,host,midsld+1,-10"
-- arg : seqovl=N . decrease seq number of the first segment by N and fill N bytes with pattern (default - all zero)
-- arg : seqovl_pattern=<blob> . override pattern
-- arg : blob=<blob> - use this data instead of desync.dis.payload
-- arg : optional - skip if blob is absent. use zero pattern if seqovl_pattern blob is absent
-- arg : nodrop - do not drop current dissect
function multisplit(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("multisplit: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "2"
			-- check debug to save CPU
			if b_debug then DLOG("multisplit: split pos: "..spos) end
			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			if b_debug then DLOG("multisplit: resolved split pos: "..table.concat(zero_based_pos(pos)," ")) end
			delete_pos_1(pos) -- cannot split at the first byte
			if #pos>0 then
				for i=0,#pos do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part = string.sub(data,pos_start,pos_end)
					local seqovl=0
					if i==0 and desync.arg.seqovl and tonumber(desync.arg.seqovl)>0 then
						seqovl = tonumber(desync.arg.seqovl)
						local pat="\x00"
						if desync.arg.seqovl_pattern then
							if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
								DLOG("multisplit: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
							else
								pat = blob(desync,desync.arg.seqovl_pattern)
							end
						end
						part = pattern(pat,1,seqovl)..part
					end
					if b_debug then DLOG("multisplit: sending part "..(i+1).." "..(pos_start-1).."-"..(pos_end-1).." len="..#part.." seqovl="..seqovl.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,pos_start-1-seqovl) then
						return VERDICT_PASS
					end
				end
				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("multisplit: no valid split positions")
			end
		else
			DLOG("multisplit: not acting on further replay pieces")
		end
		-- drop replayed packets if reasm was sent successfully in splitted form
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end


function pos_normalize(pos, low, hi)
	return (pos>=low and pos<hi) and (pos-low+1) or nil
end
function pos_array_normalize(pos, low, hi)
	-- remove positions outside of hi,low range. normalize others to low
	local i=1
	while i<=#pos do
		pos[i] = pos_normalize(pos[i], low, hi)
		if pos[i] then
			i = i + 1
		else
			table.remove(pos, i);
		end
	end
end
-- internal function for code deduplication. do not call directly
function multidisorder_send(desync, data, seqovl, pos)
	for i=#pos,0,-1 do
		local pos_start = pos[i] or 1
		local pos_end = i<#pos and pos[i+1]-1 or #data
		local part = string.sub(data,pos_start,pos_end)
		local ovl=0
		if i==1 and seqovl and seqovl>0 then
			if seqovl>=pos[1] then
				DLOG("multidisorder: seqovl cancelled because seqovl "..(seqovl-1).." is not less than the first split pos "..(pos[1]-1))
			else
				ovl = seqovl - 1
				local pat="\x00"
				if desync.arg.seqovl_pattern then
					if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
						DLOG("multidisorder: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
					else
						pat = blob(desync,desync.arg.seqovl_pattern)
					end
				end
				part = pattern(pat,1,ovl)..part
			end
		end
		if b_debug then DLOG("multidisorder: sending part "..(i+1).." "..(pos_start-1).."-"..(pos_end-1).." len="..#part.." seqovl="..ovl.." : "..hexdump_dlog(part)) end
		if not rawsend_payload_segmented(desync,part,pos_start-1-ovl) then
			return VERDICT_PASS
		end
	end
	return VERDICT_DROP
end

-- nfqws1 : "--dpi-desync=multidisorder"
-- algorithm is not 100% the same as in nfqws1. multi-segment queries can produce different segment ordering.
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : pos=<postmarker list> . position marker list. example : "1,host,midsld+1,-10"
-- arg : seqovl=N . decrease seq number of the second segment in the original order by N and fill N bytes with pattern (default - all zero). N must be less than the first split pos.
-- arg : seqovl_pattern=<blob> . override pattern
-- arg : blob=<blob> - use this data instead of reasm_data
-- arg : optional - skip if blob is absent. use zero pattern if seqovl_pattern blob is absent
-- arg : nodrop - do not drop current dissect
function multidisorder(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("multidisorder: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "2"
			-- check debug to save CPU
			if b_debug then DLOG("multidisorder: split pos: "..spos) end
			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			if b_debug then DLOG("multidisorder: resolved split pos: "..table.concat(zero_based_pos(pos)," ")) end
			delete_pos_1(pos) -- cannot split at the first byte
			if #pos>0 then
				local seqovl
				if desync.arg.seqovl then
					seqovl = resolve_pos(data, desync.l7payload, desync.arg.seqovl)
					if not seqovl then
						DLOG("multidisorder: seqovl cancelled because could not resolve marker '"..desync.arg.seqovl.."'")
					end
				end
				if multidisorder_send(desync, data, seqovl, pos)==VERDICT_PASS then
					return VERDICT_PASS
				end
				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("multidisorder: no valid split positions")
			end
		else
			DLOG("multidisorder: not acting on further replay pieces")
		end
		-- drop replayed packets if reasm was sent successfully in splitted form
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end

-- nfqws1 : "--dpi-desync=multidisorder". segment ordering is the same as in nfqws1
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : pos=<postmarker list> . position marker list. example : "1,host,midsld+1,-10"
-- arg : seqovl=N . decrease seq number of the second segment in the original order by N and fill N bytes with pattern (default - all zero). N must be less than the first split pos.
-- arg : seqovl_pattern=<blob> . override pattern
-- arg : optional - use zero pattern if seqovl_pattern blob is absent
function multidisorder_legacy(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	-- by default process only outgoing known payloads
	local data = desync.dis.payload
	local fulldata = desync.reasm_data
	if #data>0 and direction_check(desync) and payload_check(desync) then
		local range_low = (desync.reasm_offset or 0) + 1
		local range_hi = range_low + #data
		local spos = desync.arg.pos or "2"
		-- check debug to save CPU
		if b_debug then DLOG("multidisorder_legacy: split pos: "..spos) end
		local pos = resolve_multi_pos(fulldata, desync.l7payload, spos)
		if b_debug then DLOG("multidisorder_legacy: resolved split pos: "..table.concat(zero_based_pos(pos)," ")) end
		DLOG("multidisorder_legacy: reasm piece range: "..(range_low-1).."-"..(range_hi-2))
		pos_array_normalize(pos, range_low, range_hi)
		delete_pos_1(pos) -- cannot split at the first byte
		if #pos>0 then
			if b_debug then DLOG("multidisorder_legacy: normalized split pos: "..table.concat(zero_based_pos(pos)," ")) end
			local seqovl
			if desync.arg.seqovl then
				seqovl = resolve_pos(fulldata, desync.l7payload, desync.arg.seqovl)
				if seqovl then
					DLOG("multidisorder_legacy: resolved seqovl pos: "..(seqovl-1))
					seqovl = pos_normalize(seqovl, range_low, range_hi)
					if seqovl then
						DLOG("multidisorder_legacy: normalized seqovl pos: "..(seqovl-1))
					else
						DLOG("multidisorder_legacy: normalized seqovl pos is outside of the reasm piece range")
					end
				else
					DLOG("multidisorder_legacy: seqovl cancelled because could not resolve marker '"..desync.arg.seqovl.."'")
				end
			end
			return multidisorder_send(desync, data, seqovl, pos)
		else
			DLOG("multidisorder_legacy: no normalized split pos in this packet")
			-- send as is with applied options
			if rawsend_payload_segmented(desync) then
				return VERDICT_DROP
			end
		end
	end
end

-- nfqws1 : "--dpi-desync=hostfakesplit"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct. FOOLING AND REPEATS APPLIED ONLY TO FAKES.
-- arg : host=<str> - hostname template. generate hosts like "random.template". example : e8nzn.vk.com
-- arg : midhost=<posmarker> - additionally split segment containing host at specified posmarker. must be within host+1 .. endhost-1 or split won't happen. example : "midsld"
-- arg : nofake1, nofake2 - do not send individual fakes
-- arg : disorder_after=<posmarker> - send after_host part in 2 disordered segments. if posmarker is empty string use marker "-1"
-- arg : blob=<blob> - use this data instead of desync.dis.payload
-- arg : optional - skip if blob is absent
-- arg : nodrop - do not drop current dissect
function hostfakesplit(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("hostfakesplit: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
			if pos then
				if b_debug then DLOG("hostfakesplit: resolved host range: "..table.concat(zero_based_pos(pos)," ")) end

				-- do not apply fooling to original parts except tcp_ts_up but apply ip_id
				local part, fakehost
				local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
				local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

				part = string.sub(data,1,pos[1]-1)
				if b_debug then DLOG("hostfakesplit: sending before_host part 0-"..(pos[1]-2).." len="..#part.." : "..hexdump_dlog(part)) end
				if not rawsend_payload_segmented(desync,part,0, opts_orig) then return VERDICT_PASS end

				fakehost = genhost(pos[2]-pos[1]+1, desync.arg.host)

				if not desync.arg.nofake1 then
					if b_debug then DLOG("hostfakesplit: sending fake host part (1) "..(pos[1]-1).."-"..(pos[2]-1).." len="..#fakehost.." : "..hexdump_dlog(fakehost)) end
					if not rawsend_payload_segmented(desync,fakehost,pos[1]-1, opts_fake) then return VERDICT_PASS end
				end

				local midhost
				if desync.arg.midhost then
					midhost = resolve_pos(data,desync.l7payload,desync.arg.midhost)
					if midhost then
						DLOG("hosfakesplit: midhost marker resolved to "..midhost)
						if midhost<=pos[1] or midhost>pos[2] then
							DLOG("hostfakesplit: midhost is not inside the host range")
							midhost = nil
						end
					else
						DLOG("hostfakesplit: cannot resolve midhost marker '"..desync.arg.midhost.."'")
					end
				end
				-- if present apply ipfrag only to real host parts. fakes and parts outside of the host must be visible to DPI.
				if midhost then
					part = string.sub(data,pos[1],midhost-1)
					if b_debug then DLOG("hostfakesplit: sending real host part 1 "..(pos[1]-1).."-"..(midhost-2).." len="..#part.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,pos[1]-1, opts_orig) then return VERDICT_PASS	end

					part = string.sub(data,midhost,pos[2])
					if b_debug then DLOG("hostfakesplit: sending real host part 2 "..(midhost-1).."-"..(pos[2]-1).." len="..#part.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,midhost-1, opts_orig) then return VERDICT_PASS end
				else
					part = string.sub(data,pos[1],pos[2])
					if b_debug then DLOG("hostfakesplit: sending real host part "..(pos[1]-1).."-"..(pos[2]-1).." len="..#part.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,pos[1]-1, opts_orig) then return VERDICT_PASS	end
				end

				if not desync.arg.nofake2 then
					if b_debug then DLOG("hostfakesplit: sending fake host part (2) "..(pos[1]-1).."-"..(pos[2]-1).." len="..#fakehost.." : "..hexdump_dlog(fakehost)) end
					if not rawsend_payload_segmented(desync,fakehost,pos[1]-1, opts_fake) then return VERDICT_PASS end
				end

				local disorder_after_pos
				if desync.arg.disorder_after then
					disorder_after_pos = resolve_pos(data, desync.l7payload, desync.arg.disorder_after=="" and "-1" or desync.arg.disorder_after)
					if disorder_after_pos then
						-- pos[2] points to the last letter of the host starting from 1
						if disorder_after_pos<=(pos[2]+1) then
							DLOG("hostfakesplit: disorder_after marker '"..(disorder_after_pos-1).."' resolved to pos not after after_host pos "..pos[2])
							disorder_after_pos = nil
						end

					else
						DLOG("hostfakesplit: could not resolve disorder_after marker '"..desync.arg.disorder_after.."'")
					end
				end
				if disorder_after_pos then
					part = string.sub(data,disorder_after_pos)
					if b_debug then DLOG("hostfakesplit: sending after_host part (2) "..(disorder_after_pos-1).."-"..(#data-1).." len="..#part.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,disorder_after_pos-1, opts_orig) then return VERDICT_PASS end

					part = string.sub(data,pos[2]+1,disorder_after_pos-1)
					if b_debug then DLOG("hostfakesplit: sending after_host part (1) "..pos[2].."-"..(disorder_after_pos-2).." len="..#part.." : "..hexdump_dlog(part)) end
				else
					part = string.sub(data,pos[2]+1)
					if b_debug then DLOG("hostfakesplit: sending after_host part "..pos[2].."-"..(#data-1).." len="..#part.." : "..hexdump_dlog(part)) end
				end
				if not rawsend_payload_segmented(desync,part,pos[2], opts_orig) then return VERDICT_PASS end

				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("hostfakesplit: host range cannot be resolved")
			end
		else
			DLOG("hostfakesplit: not acting on further replay pieces")
		end
		-- drop replayed packets if reasm was sent successfully in splitted form
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end

-- nfqws1 : "--dpi-desync=fakedsplit"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct. FOOLING AND REPEATS APPLIED ONLY TO FAKES.
-- arg : pos=<posmarker> - split position marker
-- arg : nofake1, nofake2, nofake3, nofake4 - do not send individual fakes
-- arg : pattern=<blob> . fill fake parts with this pattern
-- arg : seqovl=N . decrease seq number of the first segment by N and fill N bytes with pattern (default - all zero)
-- arg : seqovl_pattern=<blob> . override seqovl pattern
-- arg : blob=<blob> - use this data instead of reasm_data
-- arg : optional - skip if blob is absent. use zero pattern if seqovl_pattern blob is absent
-- arg : nodrop - do not drop current dissect
function fakedsplit(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("fakedsplit: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "2"
			local pos = resolve_pos(data, desync.l7payload, spos)
			if pos then
				if pos == 1 then
					DLOG("fakedsplit: split pos resolved to 0. cannot split.")
				else
					if b_debug then DLOG("fakedsplit: resolved split pos: "..tostring(pos-1)) end

					-- do not apply fooling to original parts except tcp_ts_up but apply ip_id
					local fake, fakepat, part, pat
					local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
					local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

					fakepat = desync.arg.pattern and blob(desync,desync.arg.pattern) or "\x00"

					-- first fake
					fake = pattern(fakepat,1,pos-1)

					if not desync.arg.nofake1 then
						if b_debug then DLOG("fakedsplit: sending fake part 1 (1) : 0-"..(pos-2).." len="..#fake.." : "..hexdump_dlog(fake)) end
						if not rawsend_payload_segmented(desync,fake,0, opts_fake) then return VERDICT_PASS end
					end

					-- first real
					part = string.sub(data,1,pos-1)
					local seqovl=0
					if desync.arg.seqovl and tonumber(desync.arg.seqovl)>0 then
						seqovl = tonumber(desync.arg.seqovl)
						pat="\x00"
						if desync.arg.seqovl_pattern then
							if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
								DLOG("fakedsplit: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
							else
								pat = blob(desync,desync.arg.seqovl_pattern)
							end
						end
						part = pattern(pat,1,seqovl)..part
					end
					if b_debug then DLOG("fakedsplit: sending real part 1 : 0-"..(pos-2).." len="..#part.." seqovl="..seqovl.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,-seqovl, opts_orig) then return VERDICT_PASS end

					-- first fake again
					if not desync.arg.nofake2 then
						if b_debug then DLOG("fakedsplit: sending fake part 1 (2) : 0-"..(pos-2).." len="..#fake.." : "..hexdump_dlog(fake)) end
						if not rawsend_payload_segmented(desync,fake,0, opts_fake) then return VERDICT_PASS end
					end

					-- second fake
					fake = pattern(fakepat,pos,#data-pos+1)
					if not desync.arg.nofake3 then
						if b_debug then DLOG("fakedsplit: sending fake part 2 (1) : "..(pos-1).."-"..(#data-1).." len="..#fake.." : "..hexdump_dlog(fake)) end
						if not rawsend_payload_segmented(desync,fake,pos-1, opts_fake) then return VERDICT_PASS end
					end

					-- second real
					part = string.sub(data,pos)
					if b_debug then DLOG("fakedsplit: sending real part 2 : "..(pos-1).."-"..(#data-1).." len="..#part.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,pos-1, opts_orig) then return VERDICT_PASS end

					-- second fake again
					if not desync.arg.nofake4 then
						if b_debug then DLOG("fakedsplit: sending fake part 2 (2) : "..(pos-1).."-"..(#data-1).." len="..#fake.." : "..hexdump_dlog(fake)) end
						if not rawsend_payload_segmented(desync,fake,pos-1, opts_fake) then return VERDICT_PASS end
					end

					replay_drop_set(desync)
					return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
				end
			else
				DLOG("fakedsplit: cannot resolve pos '"..spos.."'")
			end
		else
			DLOG("fakedsplit: not acting on further replay pieces")
		end
		-- drop replayed packets if reasm was sent successfully in splitted form
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end

-- nfqws1 : "--dpi-desync=fakeddisorder"
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct. FOOLING AND REPEATS APPLIED ONLY TO FAKES.
-- arg : pos=<posmarker> - split position marker
-- arg : nofake1, nofake2, nofake3, nofake4 - do not send individual fakes
-- arg : pattern=<blob> . fill fake parts with this pattern
-- arg : seqovl=N . decrease seq number of the second segment by N and fill N bytes with pattern (default - all zero). N must be less than the split pos.
-- arg : seqovl_pattern=<blob> . override seqovl pattern
-- arg : blob=<blob> - use this data instead of desync.dis.payload
-- arg : optional - skip if blob is absent. use zero pattern if seqovl_pattern blob is absent
-- arg : nodrop - do not drop current dissect
function fakeddisorder(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("fakeddisorder: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local spos = desync.arg.pos or "2"
			local pos = resolve_pos(data, desync.l7payload, spos)
			if pos then
				if pos == 1 then
					DLOG("fakeddisorder: split pos resolved to 0. cannot split.")
				else
					if b_debug then DLOG("fakeddisorder: resolved split pos: "..tostring(pos-1)) end

					-- do not apply fooling to original parts except tcp_ts_up but apply ip_id
					local fake, part
					local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
					local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

					local fakepat = desync.arg.pattern and blob(desync,desync.arg.pattern) or "\x00"

					-- second fake
					fake = pattern(fakepat,pos,#data-pos+1)
					if not desync.arg.nofake1 then
						if b_debug then DLOG("fakeddisorder: sending fake part 2 (1) : "..(pos-1).."-"..(#data-1).." len="..#fake.." : "..hexdump_dlog(fake)) end
						if not rawsend_payload_segmented(desync,fake,pos-1, opts_fake) then return VERDICT_PASS end
					end

					-- second real
					part = string.sub(data,pos)
					local seqovl = 0
					if desync.arg.seqovl then
						seqovl = resolve_pos(data, desync.l7payload, desync.arg.seqovl)
						if seqovl then
							seqovl = seqovl - 1
							if seqovl>=(pos-1) then
								DLOG("fakeddisorder: seqovl cancelled because seqovl "..seqovl.." is not less than the split pos "..(pos-1))
								seqovl = 0
							else
								local pat="\x00"
								if desync.arg.seqovl_pattern then
									if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
										DLOG("fakeddisorder: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
									else
										pat = blob(desync,desync.arg.seqovl_pattern)
									end
								end
								part = pattern(pat,1,seqovl)..part
							end
						else
							DLOG("fakeddisorder: seqovl cancelled because could not resolve marker '"..desync.arg.seqovl.."'")
							seqovl = 0
						end
					end
					if b_debug then DLOG("fakeddisorder: sending real part 2 : "..(pos-1).."-"..(#data-1).." len="..#part.." seqovl="..seqovl.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,pos-1-seqovl, opts_orig) then return VERDICT_PASS end

					-- second fake again
					if not desync.arg.nofake2 then
						if b_debug then DLOG("fakeddisorder: sending fake part 2 (2) : "..(pos-1).."-"..(#data-1).." len="..#fake.." : "..hexdump_dlog(fake)) end
						if not rawsend_payload_segmented(desync,fake,pos-1, opts_fake) then return VERDICT_PASS end
					end

					-- first fake
					fake = pattern(fakepat,1,pos-1)
					if not desync.arg.nofake3 then
						if b_debug then DLOG("fakeddisorder: sending fake part 1 (1) : 0-"..(pos-2).." len="..#fake.." : "..hexdump_dlog(fake)) end
						if not rawsend_payload_segmented(desync,fake,0, opts_fake) then return VERDICT_PASS end
					end

					-- first real
					part = string.sub(data,1,pos-1)
					if b_debug then DLOG("fakeddisorder: sending real part 1 : 0-"..(pos-2).." len="..#part.." : "..hexdump_dlog(part)) end
					if not rawsend_payload_segmented(desync,part,0, opts_orig) then return VERDICT_PASS end

					-- first fake again
					if not desync.arg.nofake4 then
						if b_debug then DLOG("fakeddisorder: sending fake part 1 (2) : 0-"..(pos-2).." len="..#fake.." : "..hexdump_dlog(fake)) end
						if not rawsend_payload_segmented(desync,fake,0, opts_fake) then return VERDICT_PASS end
					end

					replay_drop_set(desync)
					return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
				end
			else
				DLOG("fakeddisorder: cannot resolve pos '"..spos.."'")
			end
		else
			DLOG("fakeddisorder: not acting on further replay pieces")
		end
		-- drop replayed packets if reasm was sent successfully in splitted form
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end

-- nfqws1 : not available
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : pos=<postmarker list> . position marker list. 2 pos required, only 2 first pos used. example : "host,endhost"
-- arg : seqovl=N . decrease seq number of the first segment by N and fill N bytes with pattern (default - all zero)
-- arg : seqovl_pattern=<blob> . override pattern
-- arg : blob=<blob> - use this data instead of desync.dis.payload
-- arg : optional - skip if blob is absent. use zero pattern if seqovl_pattern blob is absent
function tcpseg(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if not desync.arg.pos then
		error("tcpseg: no pos specified")
	end
	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("tcpseg: blob '"..desync.arg.blob.."' not found. skipped")
		return
	end
	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			if b_debug then DLOG("tcpseg: pos: "..desync.arg.pos) end
			-- always returns 2 positions or nil or causes error
			local pos = resolve_range(data, desync.l7payload, desync.arg.pos)
			if pos then
				-- check debug to save CPU
				if b_debug then DLOG("tcpseg: resolved range: "..table.concat(zero_based_pos(pos)," ")) end
				local part = string.sub(data,pos[1],pos[2])
				local seqovl=0
				if desync.arg.seqovl and tonumber(desync.arg.seqovl)>0 then
					seqovl = tonumber(desync.arg.seqovl)
					local pat="\x00"
					if desync.arg.seqovl_pattern then
						if desync.arg.optional and not blob_exist(desync, desync.arg.seqovl_pattern) then
							DLOG("tcpseg: blob '"..desync.arg.seqovl_pattern.."' not found. using zero pattern")
						else
							pat = blob(desync,desync.arg.seqovl_pattern)
						end
					end
					part = pattern(pat,1,seqovl)..part
				end
				if b_debug then DLOG("tcpseg: sending "..(pos[1]-1).."-"..(pos[2]-1).." len="..#part.." seqovl="..seqovl.." : "..hexdump_dlog(part)) end
				rawsend_payload_segmented(desync,part,pos[1]-1-seqovl)
			else
				DLOG("tcpseg: range cannot be resolved")
			end
		else
			DLOG("tcpseg: not acting on further replay pieces")
		end
	end
end

-- nfqws1 : not available
-- tpws : close analog is "--split-pos=.. --oob" but works not the same way
-- standard args : fooling, ip_id, rawsend, reconstruct, ipfrag
-- arg : char - oob char
-- arg : byte - oob byte
-- arg : urp - urgent pointer position marker, 'b' or 'e'. default - 0
function oob(ctx, desync)
	if not desync.track then return end
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	local key = desync.func_instance.."_syn"
	if not desync.track.lua_state[key] then
		if bitand(desync.dis.tcp.th_flags, TH_SYN+TH_ACK)~=TH_SYN then
			DLOG("oob: must be applied since the very beginning of the tcp connection - SYN packet")
			instance_cutoff_shim(ctx, desync)
			return
		end
		desync.track.lua_state[key] = true
	end
	if desync.outgoing then
		-- direct pos - outgoing
		local pos = pos_get(desync, 's', false)
		if pos<=1 then
			local dseq = u32add(desync.dis.tcp.th_seq, -1)
			DLOG("oob: decreasing outgoing seq : "..desync.dis.tcp.th_seq.." => "..dseq)
			desync.dis.tcp.th_seq = dseq
		end
		if pos==0 then
			return VERDICT_MODIFY
		elseif pos==1 then
			local data = desync.reasm_data or desync.dis.payload
			if #data==0 then
				-- empty ACK
				return VERDICT_MODIFY
			else
				local oob = desync.arg.char or (desync.arg.byte and bu8(desync.arg.byte) or nil) or "\x00"
				if #oob~=1 then
					error("oob: OOB must be exactly one byte")
				end
				local dis_oob = deepcopy(desync.dis)
				local urp
				if not desync.arg.urp or desync.arg.urp=='b' then
					urp = 1
					dis_oob.tcp.th_urp = 0
				elseif desync.arg.urp=='e' then
					urp = #data+1
					dis_oob.tcp.th_urp = urp
				else
					urp = resolve_pos(data, desync.l7payload, desync.arg.urp)
					if not urp then
						DLOG("oob: cannot resolve urp marker '"..desync.arg.urp.."'")
						instance_cutoff_shim(ctx, desync)
						return
					end
					DLOG("oob: resolved urp marker to "..urp-1)
					dis_oob.tcp.th_urp = urp
				end
				DLOG("oob: th_urp "..dis_oob.tcp.th_urp)
				-- one byte OOB payload
				dis_oob.payload = string.sub(data, 1, urp-1) .. oob .. string.sub(data, urp)
				dis_oob.tcp.th_flags = bitor(dis_oob.tcp.th_flags, TH_URG)
				DLOG("oob: sending OOB")
				if not rawsend_dissect_segmented(desync, dis_oob) then
					instance_cutoff_shim(ctx, desync)
					return
				end
				if not desync.replay then
					instance_cutoff_shim(ctx, desync)
				end
			end
			return VERDICT_DROP
		else
			-- drop replay and cutoff
			if desync.replay then
				DLOG("oob: dropping replay piece")
				if desync.replay_piece_last then
					instance_cutoff_shim(ctx, desync)
				end
				return VERDICT_DROP
			end
			instance_cutoff_shim(ctx, desync)
		end
	else
		-- reverse pos - outgoing
		local pos = pos_get(desync, 's', true)
		if pos>1 then
			DLOG("oob: unexpected outgoing position "..pos)
			instance_cutoff_shim(ctx, desync)
			return
		end
		local dack = u32add(desync.dis.tcp.th_ack, 1)
		DLOG("oob: increasing incoming ack : "..desync.dis.tcp.th_ack.." => "..dack)
		desync.dis.tcp.th_ack = dack
		return VERDICT_MODIFY
	end
end

-- nfqws1 : "--dpi-desync=udplen"
-- standard args : direction, payload
-- arg : min=N . do not act on payloads smaller than N bytes
-- arg : max=N . do not act on payloads larger than N bytes
-- arg : increment=N . 2 by default. negative increment shrinks the packet, positive grows it.
-- arg : pattern=<blob> . used to fill extra bytes when length increases
-- arg : pattern_offset=N . offset in the pattern. 0 by default
function udplen(ctx, desync)
	if not desync.dis.udp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if direction_check(desync) and payload_check(desync) then
		local len = #desync.dis.payload
		if (desync.arg.min and #desync.dis.payload < tonumber(desync.arg.min)) then
			DLOG("udplen: payload size "..len.." is less than the minimum size "..desync.arg.min)
		elseif (desync.arg.max and #desync.dis.payload > tonumber(desync.arg.max)) then
			DLOG("udplen: payload size "..len.." is more than the maximum size "..desync.arg.max)
		else
			local inc = desync.arg.increment and tonumber(desync.arg.increment) or 2
			if inc>0 then
				local pat = desync.arg.pattern and blob(desync,desync.arg.pattern) or "\x00"
				local pat_offset = desync.arg.pattern_offset and (tonumber(desync.arg.pattern_offset)+1) or 1
				desync.dis.payload = desync.dis.payload .. pattern(pat, pat_offset, inc)
				DLOG("udplen: "..len.." => "..#desync.dis.payload)
				return VERDICT_MODIFY
			elseif inc<0 then
				if (len+inc)<1 then
					DLOG("udplen: will not shrink to zero length")
				else
					desync.dis.payload = string.sub(desync.dis.payload,1,len+inc)
					DLOG("udplen: "..len.." => "..#desync.dis.payload)
					return VERDICT_MODIFY
				end
			end
		end
	end
end

-- nfqws1 : "--dpi-desync=tamper" for dht proto
-- standard args : direction
-- arg : dn=N - message starts from "dN". 3 by default
function dht_dn(ctx, desync)
	if not desync.dis.udp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.l7payload=="dht" and direction_check(desync) then
		local N = tonumber(desync.arg.dn) or 3
		-- remove "d1" from the start not breaking bencode
		local prefix = "d"..tostring(N)..":"..string.rep("0",N).."1:x"
		desync.dis.payload = prefix..string.sub(desync.dis.payload,2)
		DLOG("dht_dn: tampered dht to start with '"..prefix.."' instead of 'd1:'")
		return VERDICT_MODIFY
	end
end
