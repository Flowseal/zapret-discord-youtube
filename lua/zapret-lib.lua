NFQWS2_COMPAT_VER_REQUIRED=6

if NFQWS2_COMPAT_VER~=NFQWS2_COMPAT_VER_REQUIRED then
	error("Incompatible NFQWS2_COMPAT_VER. Use pktws and lua scripts from the same release !")
end

HEXDUMP_DLOG_MAX = HEXDUMP_DLOG_MAX or 32
NOT3=bitnot(3)
NOT7=bitnot(7)
-- xor pid,tid,sec,nsec
math.randomseed(bitxor(getpid(),gettid(),clock_gettime()))

-- basic desync function
-- execute given lua code. "desync" is temporary set as global var to be accessible to the code
-- useful for simple fast actions without writing a func
-- arg: code=<lua_code>
function luaexec(ctx, desync)
	if not desync.arg.code then
		error("luaexec: no 'code' parameter")
	end
	local fname = desync.func_instance.."_code"
	if not _G[fname] then
		local err
		_G[fname], err = load(desync.arg.code, fname)
		if not _G[fname] then
			error(err)
		end
	end
	-- allow dynamic code to access desync
	_G.desync = desync
	local res, ret = pcall(_G[fname])
	_G.desync = nil
	if not res then
		error(ret)
	else
		return ret or VERDICT_PASS -- older nfqws2 failed if desync function returned explicit nil
	end
end

-- basic desync function
-- does nothing just acknowledges when it's called
-- no args
function pass(ctx, desync)
	DLOG("pass")
end

-- basic desync function
-- prints desync to DLOG
function pktdebug(ctx, desync)
	DLOG("desync:")
	var_debug(desync)
end
-- basic desync function
-- prints function args
function argdebug(ctx, desync)
	var_debug(desync.arg)
end

-- basic desync function
-- prints conntrack positions to DLOG
function posdebug(ctx, desync)
	if not desync.track then
		DLOG("posdebug: no track")
		return
	end
	local s="posdebug: "..(desync.outgoing and "out" or "in").." time +"..desync.track.pos.dt.."s direct"
	for i,pos in pairs({'n','d','b','s','p'}) do
		s=s.." "..pos..pos_get(desync, pos, false)
	end
	s=s.." reverse"
	for i,pos in pairs({'n','d','b','s','p'}) do
		s=s.." "..pos..pos_get(desync, pos, true)
	end
	s=s.." payload "..#desync.dis.payload
	if desync.reasm_data then
		s=s.." reasm "..#desync.reasm_data
	end
	if desync.decrypt_data then
		s=s.." decrypt "..#desync.decrypt_data
	end
	if desync.replay_piece_count then
		s=s.." replay "..desync.replay_piece.."/"..desync.replay_piece_count
	end
	DLOG(s)
end

-- basic desync function
-- set l7payload to 'arg.payload' if reasm.data or desync.dis.payload contains 'arg.pattern' substring
-- NOTE : this does not set payload on C code side !
-- NOTE : C code will not see payload change. --payload args take only payloads known to C code and cause error if unknown.
-- arg: pattern - substring for search inside reasm_data or desync.dis.payload
-- arg: payload - set desync.l7payload to this if detected
-- arg: undetected - set desync.l7payload to this if not detected
-- test case : --lua-desync=detect_payload_str:pattern=1234:payload=my --lua-desync=fake:blob=0x1234:payload=my
function detect_payload_str(ctx, desync)
	if not desync.arg.pattern then
		error("detect_payload_str: missing 'pattern'")
	end
	local data = desync.reasm_data or desync.dis.payload
	local b = data and string.find(data,desync.arg.pattern,1,true)
	if b then
		DLOG("detect_payload_str: detected '"..(desync.arg.payload or '?').."'")
		if desync.arg.payload then desync.l7payload = desync.arg.payload end
	else
		DLOG("detect_payload_str: not detected '"..(desync.arg.payload or '?').."'")
		if desync.arg.undetected then desync.l7payload = desync.arg.undetected end
	end
end


-- this shim is needed then function is orchestrated. ctx services not available
-- have to emulate cutoff in LUA using connection persistent table track.lua_state
function instance_cutoff_shim(ctx, desync, dir)
	if ctx then
		instance_cutoff(ctx, dir)
	elseif not desync.track then
		DLOG("instance_cutoff_shim: cannot cutoff '"..desync.func_instance.."' because conntrack is absent")
	else
		if not desync.track.lua_state.cutoff_shim then
			desync.track.lua_state.cutoff_shim = {}
		end
		if not desync.track.lua_state.cutoff_shim[desync.func_instance] then
			desync.track.lua_state.cutoff_shim[desync.func_instance] = {}
		end
		if type(dir)=="nil" then
			-- cutoff both directions by default
			desync.track.lua_state.cutoff_shim[desync.func_instance][true] = true
			desync.track.lua_state.cutoff_shim[desync.func_instance][false] = true
		else
			desync.track.lua_state.cutoff_shim[desync.func_instance][dir] = true
		end
		if b_debug then DLOG("instance_cutoff_shim: cutoff '"..desync.func_instance.."' in="..tostring(type(dir)=="nil" and true or not dir).." out="..tostring(type(dir)=="nil" or dir)) end
	end
end
function cutoff_shim_check(desync)
	if not desync.track then
		DLOG("cutoff_shim_check: cannot check '"..desync.func_instance.."' cutoff because conntrack is absent")
		return false
	else
		local b=desync.track.lua_state.cutoff_shim and
			desync.track.lua_state.cutoff_shim[desync.func_instance] and
			desync.track.lua_state.cutoff_shim[desync.func_instance][desync.outgoing]
		if b and b_debug then 
			DLOG("cutoff_shim_check: '"..desync.func_instance.."' "..(desync.outgoing and "out" or "in").." cutoff")
		end
		return b
	end
end


-- applies # and $ prefixes. #var means var length, %var means var value
function apply_arg_prefix(desync)
	-- prevent double apply
	if desync.arg.__prefix_applied then return end
	for a,v in pairs(desync.arg) do
		local c = string.sub(v,1,1)
		if c=='#' then
			local blb = blob(desync,string.sub(v,2))
			desync.arg[a] = tostring(type(blb)=='string' and #blb or 0)
		elseif c=='%' then
			desync.arg[a] = blob(desync,string.sub(v,2))
		elseif c=='\\' then
			c = string.sub(v,2,2);
			if c=='#' or c=='%' then
				desync.arg[a] = string.sub(v,2)
			end
		end
	end
	desync.arg.__prefix_applied = true
end
-- copy instance identification and args from execution plan to desync table
-- NOTE : to not lose VERDICT_MODIFY dissect changes pass original desync table
-- NOTE : if a copy was passed and VERDICT_MODIFY returned you must copy modified dissect back to desync table or resend it and return VERDICT_DROP
-- NOTE : args and some fields are substituted. if you need them - make a copy before calling this.
function apply_execution_plan(desync, instance)
	desync.func = instance.func
	desync.func_n = instance.func_n
	desync.func_instance = instance.func_instance
	desync.arg = deepcopy(instance.arg)
	-- no apply_arg_prefix here because it may refer non-existing blobs
end
-- produce resulting verdict from 2 verdicts
function verdict_aggregate(v1, v2)
	v1 = v1 or VERDICT_PASS
	v2 = v2 or VERDICT_PASS
	local vn = bitor(bitand(v1,VERDICT_PRESERVE_NEXT),bitand(v2,VERDICT_PRESERVE_NEXT))
	local v
	v1 = bitand(v1, VERDICT_MASK)
	v2 = bitand(v2, VERDICT_MASK)
	if v1==VERDICT_DROP or v2==VERDICT_DROP then
		v=VERDICT_DROP
	elseif v1==VERDICT_MODIFY or v2==VERDICT_MODIFY then
		v=VERDICT_MODIFY
	else
		v=VERDICT_PASS
	end
	return bitor(v,vn)
end
function plan_instance_execute_preapplied(desync, verdict, instance)
	if cutoff_shim_check(desync) then
		DLOG("plan_instance_execute: not calling '"..desync.func_instance.."' because of voluntary cutoff")
	elseif not payload_match_filter(desync.l7payload, instance.payload_filter) then
		DLOG("plan_instance_execute: not calling '"..desync.func_instance.."' because payload '"..desync.l7payload.."' does not match filter '"..instance.payload_filter.."'")
	elseif not pos_check_range(desync, instance.range) then
		DLOG("plan_instance_execute: not calling '"..desync.func_instance.."' because pos "..pos_str(desync,instance.range.from).." "..pos_str(desync,instance.range.to).." is out of range '"..pos_range_str(instance.range).."'")
	else
		-- condition is satisfied. here blobs must be referenced
		apply_arg_prefix(desync)
		desync.arg.__prefix_applied = nil
		DLOG("plan_instance_execute: calling '"..desync.func_instance.."'")
		verdict = verdict_aggregate(verdict,_G[instance.func](nil, desync))
	end
	return verdict
end
function plan_instance_execute(desync, verdict, instance)
	apply_execution_plan(desync, instance)
	return plan_instance_execute_preapplied(desync,verdict,instance)
end
function plan_instance_pop(desync)
	return (desync.plan and #desync.plan>0) and table.remove(desync.plan, 1) or nil
end
function plan_clear(desync, max)
	if max then
		local n=0
		while n<max and table.remove(desync.plan,1) do n=n+1 end
	else
		while table.remove(desync.plan) do end
	end
end
-- this approach allows nested orchestrators
function orchestrate(ctx, desync)
	if not desync.plan then
		execution_plan_cancel(ctx)
		desync.plan = execution_plan(ctx)
	end
end
-- copy desync preserving lua_state
function desync_copy(desync)
	local dcopy = deepcopy(desync)
	if desync.track then
		-- preserve lua state
		dcopy.track.lua_state = desync.track.lua_state
	end
	if desync.plan then
		-- preserve execution plan
		dcopy.plan = desync.plan
	end
	return dcopy
end
-- redo what whould be done without orchestration
function replay_execution_plan(desync, max)
	local verdict = VERDICT_PASS
	local n=0
	while not max or n<max do
		local instance = plan_instance_pop(desync)
		if not instance then break end
		verdict = plan_instance_execute(desync, verdict, instance)
		n = n + 1
	end
	if max and n>=max then
		DLOG("replay_execution_plan: reached max instances limit "..max)
	end
	return verdict
end
-- this function demonstrates how to stop execution of upcoming desync instances and take over their job
-- this can be used, for example, for orchestrating conditional processing without modifying of desync functions code
-- test case : --lua-desync=desync_orchestrator_example --lua-desync=pass --lua-desync=pass
function desync_orchestrator_example(ctx, desync)
	DLOG("orchestrator: taking over upcoming desync instances")
	orchestrate(ctx, desync)
	return replay_execution_plan(desync)
end

-- if seq is over 2G s and p position comparision can be wrong
function pos_counter_overflow(desync, mode, reverse)
	if not desync.track or (mode~='s' and mode~='p') then return false end
	local track_pos = reverse and desync.track.pos.reverse or desync.track.pos.direct
	return track_pos.tcp and track_pos.tcp.rseq_over_2G
end
-- these functions duplicate range check logic from C code
-- mode must be n,d,b,s,x,a
-- pos is {mode,pos}
-- range is {from={mode,pos}, to={mode,pos}, upper_cutoff}
-- upper_cutoff = true means non-inclusive upper boundary
function pos_get_pos(track_pos, mode)
	if track_pos then
		if mode=='n' then
			return track_pos.pcounter
		elseif mode=='d' then
			return track_pos.pdcounter
		elseif mode=='b' then
			return track_pos.pbcounter
		elseif track_pos.tcp then
			if mode=='s' then
				return track_pos.tcp.rseq
			elseif mode=='p' then
				return track_pos.tcp.pos
			end
		end
	end
	return 0
end
function pos_get(desync, mode, reverse)
	if desync.track then
		local track_pos = reverse and desync.track.pos.reverse or desync.track.pos.direct
		return pos_get_pos(track_pos,mode)
	end
	return 0
end
function pos_check_from(desync, range)
	if range.from.mode == 'x' or pos_counter_overflow(desync, range.from.mode) then return false end
	if range.from.mode ~= 'a' then
		if desync.track then
			return pos_get(desync, range.from.mode) >= range.from.pos
		else
			return false
		end
	end
	return true;
end
function pos_check_to(desync, range)
	local ps
	if range.to.mode == 'x' or pos_counter_overflow(desync, range.to.mode) then return false end
	if range.to.mode ~= 'a' then
		if desync.track then
			ps = pos_get(desync, range.to.mode)
			return (ps < range.to.pos) or not range.upper_cutoff and (ps == range.to.pos)
		else
			return false
		end
	end
	return true;
end
function pos_check_range(desync, range)
	return pos_check_from(desync,range) and pos_check_to(desync,range)
end
function pos_range_str(range)
	return range.from.mode..range.from.pos..(range.upper_cutoff and '<' or '-')..range.to.mode..range.to.pos
end
function pos_str(desync, pos)
	return pos.mode..pos_get(desync, pos.mode)
end


-- convert array a to packed string using 'packer' function. only numeric indexes starting from 1, order preserved
function barray(a, packer)
	if a then
		local sa={}
		for i=1,#a do
			sa[i] = packer(a[i])
		end
		return table.concat(sa)
	end
end
-- convert table a to packed string using 'packer' function. any indexes, any order
function btable(a, packer)
	if a then
		local sa={}
		local i=1
		for k,v in pairs(a) do
			sa[i] = packer(v)
			i=i+1
		end
		return table.concat(sa)
	end
end
-- sequence comparision functions. they work only within 2G interval
-- seq1>=seq2
function seq_ge(seq1, seq2)
	return 0==bitand(u32add(seq1, -seq2), 0x80000000)
end
-- seq1>seq2
function seq_gt(seq1, seq2)
	return seq1~=seq2 and seq_ge(seq1, seq2)
end
-- seq1<seq2
function seq_lt(seq1, seq2)
	return 0~=bitand(u32add(seq1, -seq2), 0x80000000)
end
-- seq1<=seq2
function seq_le(seq1, seq2)
	return seq1==seq2 or 0~=bitand(u32add(seq1, -seq2), 0x80000000)
end
-- seq_low<=seq<=seq_hi
function seq_within(seq, seq_low, seq_hi)
	return seq_ge(seq, seq_low) and seq_le(seq, seq_hi)
end

function is_retransmission(desync)
	return desync.track and desync.track.pos.direct.tcp and seq_ge(desync.track.pos.direct.tcp.uppos_prev, desync.track.pos.direct.tcp.pos)
end

-- prepare standard rawsend options from desync
-- repeats - how many time send the packet
-- ifout - override outbound interface (if --bind_fix4, --bind-fix6 enabled)
-- fwmark - override fwmark. desync mark bit(s) will be set unconditionally
function rawsend_opts(desync)
	return {
		repeats = desync.arg.repeats,
		ifout = desync.arg.ifout or desync.ifout,
		fwmark = desync.arg.fwmark or desync.fwmark
	}
end
-- only basic options. no repeats
function rawsend_opts_base(desync)
	return {
		ifout = desync.arg.ifout or desync.ifout,
		fwmark = desync.arg.fwmark or desync.fwmark
	}
end

-- prepare standard reconstruct options from desync
-- badsum - make L4 checksum invalid
-- ip6_preserve_next - use next protocol fields from dissect, do not auto fill values. can be set from code only, not from args
-- ip6_last_proto - last ipv6 "next" protocol. used only by "reconstruct_ip6hdr". can be set from code only, not from args
function reconstruct_opts(desync)
	return {
		badsum = desync.arg.badsum
	}
end

-- combined desync opts
function desync_opts(desync)
	return {
		rawsend = rawsend_opts(desync),
		reconstruct = reconstruct_opts(desync),
		ipfrag = desync.arg,
		ipid = desync.arg,
		fooling = desync.arg
	}
end


-- convert binary string to hex data
function string2hex(s)
	local ss = ""
	for i = 1, #s do
		if i>1 then
			ss = ss .. " "
		end
		ss = ss .. string.format("%02X", string.byte(s, i))
	end
	return ss
end
function has_nonprintable(s)
	return s:match("[^ -\r\n\t]")
end
function make_readable(v)
	if type(v)=="string" then
		return string.gsub(v,"[^ -]",".");
	else
		return tostring(v)
	end
end
-- return hex dump of a binary string if it has nonprintable characters or string itself otherwise
function str_or_hex(s)
	if has_nonprintable(s) then
		return string2hex(s)
	else
		return s
	end
end
function logical_xor(a,b)
	return a and not b or not a and b
end
-- print to DLOG any variable. tables are expanded in the tree form, unprintables strings are hex dumped
function var_debug(v)
	local function dbg(v,level)
		if type(v)=="table" then
			for key, value in pairs(v) do
				DLOG(string.rep(" ",2*level).."."..tostring(key))
				dbg(v[key],level+1)
			end
		elseif type(v)=="string" then
			DLOG(string.rep(" ",2*level)..type(v).." "..str_or_hex(v))
		else
			DLOG(string.rep(" ",2*level)..type(v).." "..make_readable(v))
		end
	end
	dbg(v,0)
end

-- make hex dump
function hexdump(s, max)
	if not s then return nil end
	local l = max<#s and max or #s
	local ss = string.sub(s,1,l)
	return string2hex(ss)..(#s>max and " ... " or "  " )..make_readable(ss)..(#s>max and " ... " or "" )
end
-- make hex dump limited by HEXDUMP_DLOG_MAX chars
function hexdump_dlog(s)
	return hexdump(s,HEXDUMP_DLOG_MAX)
end

-- make copy of an array recursively
function deepcopy(orig, copies)
    copies = copies or {}
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        if copies[orig] then
            copy = copies[orig]
        else
            copy = {}
            copies[orig] = copy
            for orig_key, orig_value in next, orig, nil do
                copy[deepcopy(orig_key, copies)] = deepcopy(orig_value, copies)
            end
            setmetatable(copy, deepcopy(getmetatable(orig), copies))
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

-- check if string 'v' in comma separated list 's'
function in_list(s, v)
	if s then
		for elem in string.gmatch(s, "[^,]+") do
			if elem==v then
				return true
			end
		end
	end
	return false
end

function blob_exist(desync, name)
	return name and (string.sub(name,1,2)=="0x" or _G[name] or desync[name])
end
-- blobs can be 0xHEX, field name in desync or global var
-- if name is nil - return def
function blob(desync, name, def)
	if not name or #name==0 then
		if def then
			return def
		else
			error("empty blob name")
		end
	end
	local blob
	if string.sub(name,1,2)=="0x" then
		blob = parse_hex(string.sub(name,3))
		if not blob then
			error("invalid hex string : "..name)
		end
	else
		blob = desync[name]
		if not blob then
			-- use global var if no field in dissect table
			blob = _G[name]
			if not blob then
				error("blob '"..name.."' unavailable")
			end
		end
		blob = tostring(blob)
	end
	return blob
end
function blob_or_def(desync, name, def)
	return name and blob(desync,name,def) or def
end

-- repeat pattern as needed to extract part of it with any length
-- pat="12345" len=10 offset=4 => "4512345123"
function pattern(pat, offset, len)
	if not pat or #pat==0 then
		error("pattern: bad or empty pattern")
	end
	local off = (offset-1) % #pat
	local pats = divint((len + #pat - 1), #pat) + (off==0 and 0 or 1)
	return string.sub(string.rep(pat,pats),off+1,off+len)
end

-- decrease by 1 all number values in the array
function zero_based_pos(a)
	if not a then return nil end
	local b={}
	for i,v in ipairs(a) do
		b[i] = type(a[i])=="number" and a[i] - 1 or a[i]
	end
	return b
end

-- delete elements with number value 1
function delete_pos_1(a)
	local i=1
	while i<=#a do
		if type(a[i])=="number" and a[i] == 1 then
			table.remove(a,i)
		else
			i = i+1
		end
	end
	return a
end

-- linear search array a for a[index]==v. return index
function array_search(a, v)
	for k,val in pairs(a) do
		if val==v then
			return k
		end
	end
end
-- linear search array a for a[index].f==v. return index
function array_field_search(a, f, v)
	for k,val in pairs(a) do
		if type(val)=="table" and val[f]==v then
			return k
		end
	end
end

-- find pos of the next eol and pos of the next non-eol character after eol
function find_next_line(s, pos)
	local p1, p2
	p1 = string.find(s,"[\r\n]",pos)
	if p1 then
		p2 = p1
		p1 = p1-1
		if string.sub(s,p2,p2)=='\r' then p2=p2+1 end
		if string.sub(s,p2,p2)=='\n' then p2=p2+1 end
		if p2>#s then p2=nil end
	else
		p1 = #s
	end
	return p1,p2
end


-- support sni=%var
function tls_mod_shim(desync, blob, modlist, payload)
	local p1,p2 = string.find(modlist,"sni=%%[^,]+")
	if p1 then
		local var = string.sub(modlist,p1+5,p2)
		local val = desync[var] or _G[var]
		if not val then
			error("tls_mod_shim: non-existent var '"..var.."'")
		end
		modlist = string.sub(modlist,1,p1+3)..tostring(val)..string.sub(modlist,p2+1)
	end
	return tls_mod(blob,modlist,payload)
end

-- convert comma separated list of tcp flags to tcp.th_flags bit field
function parse_tcp_flags(s)
	local flags={FIN=TH_FIN, SYN=TH_SYN, RST=TH_RST, PSH=TH_PUSH, PUSH=TH_PUSH, ACK=TH_ACK, URG=TH_URG, ECE=TH_ECE, CWR=TH_CWR}
	local f=0
	local s_upper = string.upper(s)
	for flag in string.gmatch(s_upper, "[^,]+") do
		if flags[flag] then
			f = bitor(f,flags[flag])
		else
			error("tcp flag '"..flag.."' is invalid")
		end
	end
	return f
end

-- get ip protocol from l3 headers
function ip_proto_l3(dis)
	if dis.ip then
		return dis.ip.ip_p
	elseif dis.ip6 then
		return #dis.ip6.exthdr==0 and dis.ip6.ip6_nxt or dis.ip6.exthdr[#dis.ip6.exthdr].next
	end
end
-- get ip protocol from l4 headers
function ip_proto_l4(dis)
	if dis.tcp then
		return IPPROTO_TCP
	elseif dis.udp then
		return IPPROTO_UDP
	elseif dis.ip then
		return dis.icmp and IPPROTO_ICMP or nil
	elseif dis.ip6 then
		return dis.icmp and IPPROTO_ICMPV6 or nil
	end
end
function ip_proto(dis)
	return ip_proto_l4(dis) or ip_proto_l3(dis)
end
-- discover ip protocol and fix "next" fields
function fix_ip_proto(dis, proto)
	local pr = proto or ip_proto(dis)
	if pr then
		if dis.ip then
			dis.ip.ip_p = pr
		elseif dis.ip6 then
			fix_ip6_next(dis.ip6, pr)
		end
	end
end

-- find first tcp options of specified kind in dissect.tcp.options
function find_tcp_option(options, kind)
	if options then
		for i, opt in ipairs(options) do
			if opt.kind==kind then return i end
		end
	end
	return nil
end

-- find first ipv6 extension header of specified protocol in dissect.ip6.exthdr
function find_ip6_exthdr(exthdr, proto)
	if exthdr then
		for i, hdr in ipairs(exthdr) do
			if hdr.type==proto then return i end
		end
	end
	return nil
end

-- insert ipv6 extension header at specified index. fix next proto chain
function insert_ip6_exthdr(ip6, idx, header_type, data)
	local prev
	if not ip6.exthdr then ip6.exthdr={} end
	if not idx then
		-- insert to the end
		idx = #ip6.exthdr+1
	elseif idx<0 or idx>(#ip6.exthdr+1) then
		error("insert_ip6_exthdr: invalid index "..idx)
	end
	if idx==1 then
		prev = ip6.ip6_nxt
		ip6.ip6_nxt = header_type
	else
		prev = ip6.exthdr[idx-1].next
		ip6.exthdr[idx-1].next = header_type
	end
	table.insert(ip6.exthdr, idx, {type = header_type, data = data, next = prev})
end
-- delete ipv6 extension header at specified index. fix next proto chain
function del_ip6_exthdr(ip6, idx)
	if idx<=0 or idx>#ip6.exthdr then
		error("delete_ip6_exthdr: nonexistent index "..idx)
	end
	local nxt = ip6.exthdr[idx].next
	if idx==1 then
		ip6.ip6_nxt = nxt
	else
		ip6.exthdr[idx-1].next = nxt
	end
	table.remove(ip6.exthdr, idx)
end
-- fills next proto fields in ipv6 header and extension headers
function fix_ip6_next(ip6, last_proto)
	if ip6.exthdr and #ip6.exthdr>0 then
		for i=1,#ip6.exthdr do
			if i==1 then
				-- first header
				ip6.ip6_nxt = ip6.exthdr[i].type
			end
			ip6.exthdr[i].next = i==#ip6.exthdr and (last_proto or IPPROTO_NONE) or ip6.exthdr[i+1].type
		end
	else
		-- no headers
		ip6.ip6_nxt = last_proto or IPPROTO_NONE
	end
end

function dis_ipsrc(dis)
	if dis.ip then
		return dis.ip.ip_src
	elseif dis.ip6 then
		return dis.ip6.ip6_src
	end
end
function dis_ipdst(dis)
	if dis.ip then
		return dis.ip.ip_dst
	elseif dis.ip6 then
		return dis.ip6.ip6_dst
	end
end

function dis_l4_name(dis)
	local l4
	if dis.tcp then
		l4="tcp"
	elseif dis.udp then
		l4="udp"
	elseif dis.icmp then
		l4="icmp"
	else
		l4="raw"..ip_proto_l3(dis)
	end
	return l4
end
function dis_l4_ports(dis)
	local p1,p2
	if dis.tcp then
		p1=dis.tcp.th_sport
		p2=dis.tcp.th_dport
	elseif dis.udp then
		p1=dis.udp.uh_sport
		p2=dis.udp.uh_dport
	elseif dis.icmp then
		p1=dis.icmp.icmp_type
		p2=dis.icmp.icmp_code
	end
	return p1 and (p1..":"..p2) or "?"
end

function dis_timer_name(dis)
	return table.concat({ntop(dis_ipsrc(dis)),"->",ntop(dis_ipdst(dis)),"_",dis_l4_name(dis),"_",dis_l4_ports(dis)})
end
function desync_timer_name(desync)
	local name = desync.func_instance.."_"..dis_timer_name(desync.dis)
	if desync.track then
		name = name.."_n"..desync.track.pos.direct.pcounter
	else
		name = name.."_"..brandom_az09(10)
	end
	return name
end


-- reverses ip addresses, ports and seq/ack
function dis_reverse(dis)
	if dis.ip then
		dis.ip.ip_src, dis.ip.ip_dst = dis.ip.ip_dst, dis.ip.ip_src
	end
	if dis.ip6 then
		dis.ip6.ip6_src, dis.ip6.ip6_dst = dis.ip6.ip6_dst, dis.ip6.ip6_src
	end
	if dis.tcp then
		dis.tcp.th_sport, dis.tcp.th_dport = dis.tcp.th_dport, dis.tcp.th_sport
		dis.tcp.th_ack, dis.tcp.th_seq = dis.tcp.th_seq, dis.tcp.th_ack
	end
	if dis.udp then
		dis.udp.uh_sport, dis.udp.uh_dport = dis.udp.uh_dport, dis.udp.uh_sport
	end
end

function dis_reconstruct_l3(dis, options)
	if dis.ip then
		return csum_ip4_fix(reconstruct_iphdr(dis.ip))
	elseif dis.ip6 then
		return reconstruct_ip6hdr(dis.ip6, options)
	end
end

-- parse autottl : delta,min-max
function parse_autottl(s)
	if s then
		local delta,min,max = string.match(s,"([-+]?%d+),(%d+)-(%d+)")
		min = tonumber(min)
		max = tonumber(max)
		delta = tonumber(delta)
		if not delta or min>max then
			error("parse_autottl: invalid value '"..s.."'")
		end
		return {delta=delta,min=min,max=max}
	else
		return nil
	end
end

-- calculate ttl value based on incoming_ttl and parsed attl definition (delta,min-max)
function autottl(incoming_ttl, attl)
	local function hop_count_guess(incoming_ttl)
		-- 18.65.168.125 ( cloudfront ) 	255
		-- 157.254.246.178 			128
		-- 1.1.1.1				 64
		-- guess original ttl. consider path lengths less than 32 hops

		local orig

		if incoming_ttl>223 then
			orig=255
		elseif incoming_ttl<=128 and incoming_ttl>96 then
			orig=128
		elseif incoming_ttl<=64 and incoming_ttl>32 then
			orig=64
		else
			return nil
		end

		return orig-incoming_ttl
	end
	-- return guessed fake ttl value. 0 means unsuccessfull, should not perform autottl fooling
	local function autottl_eval(hop_count, attl)
		local d,fake

		d = hop_count + attl.delta

		if d<attl.min then fake=attl.min
		elseif d>attl.max then fake=attl.max
		else fake=d
		end

		if attl.delta<0 and fake>=hop_count or attl.delta>=0 and fake<hop_count then return nil end
		return fake
	end
	local hops = hop_count_guess(incoming_ttl)
	if not hops then return nil end
	return autottl_eval(hops,attl)
end

-- apply standard header mods :

-- ip_ttl=N - set ipv.ip_ttl to N
-- ip6_ttl=N - set ip6.ip6_hlim to N
-- ip_autottl=delta,min-max - set ip.ip_ttl to auto discovered ttl
-- ip6_autottl=delta,min-max - set ip.ip_ttl to auto discovered ttl

-- ip6_hopbyhop[=hex] - add hopbyhop ipv6 header with optional data. data size must be 6+N*8. all zero by default.
-- ip6_hopbyhop2[=hex] - add second hopbyhop ipv6 header with optional data. data size must be 6+N*8. all zero by default.
-- ip6_destopt[=hex] - add destopt ipv6 header with optional data. data size must be 6+N*8. all zero by default.
-- ip6_destopt2[=hex] - add second destopt ipv6 header with optional data. data size must be 6+N*8. all zero by default.
-- ip6_routing[=hex] - add routing ipv6 header with optional data. data size must be 6+N*8. all zero by default.
-- ip6_ah[=hex] - add authentication ipv6 header with optional data. data size must be 6+N*4. 0000 + 4 random bytes by default.

-- tcp_seq=N - add N to tcp.th_seq
-- tcp_ack=N - add N to tcp.th_ack
-- tcp_ts=N - add N to timestamp value
-- tcp_md5[=hex] - add MD5 header with optional 16-byte data. all zero by default.
-- tcp_flags_set=<list> - set tcp flags in comma separated list
-- tcp_flags_unset=<list> - unset tcp flags in comma separated list
-- tcp_ts_up - move timestamp tcp option to the top if it's present. this allows linux not to accept badack segments without badseq. this is very strange discovery but it works.
-- tcp_nop_del - delete NOP tcp options to free space in tcp header

-- fool - custom fooling function : fool_func(dis, fooling_options)
function apply_fooling(desync, dis, fooling_options)
	local function prepare_bin(hex,def)
		local bin = parse_hex(hex)
		if not bin then error("apply_fooling: invalid hex string '"..hex.."'") end
		return #bin>0 and bin or def
	end
	local function ttl_discover(arg_ttl,arg_autottl)
		local ttl
		if arg_autottl and desync.track then
			if desync.track.incoming_ttl then
				-- use lua_cache to store discovered autottl
				if type(desync.track.lua_state.autottl_cache)~="table" then desync.track.lua_state.autottl_cache={} end
				if type(desync.track.lua_state.autottl_cache[desync.func_instance])~="table" then desync.track.lua_state.autottl_cache[desync.func_instance]={} end
				if not desync.track.lua_state.autottl_cache[desync.func_instance].autottl_found then
					local attl = parse_autottl(arg_autottl)
					if not attl then
						error("apply_fooling: invalid autottl value '"..arg_autottl.."'")
					end
					desync.track.lua_state.autottl_cache[desync.func_instance].autottl = autottl(desync.track.incoming_ttl,attl)
					if desync.track.lua_state.autottl_cache[desync.func_instance].autottl then
						desync.track.lua_state.autottl_cache[desync.func_instance].autottl_found = true
							DLOG("apply_fooling: discovered autottl "..desync.track.lua_state.autottl_cache[desync.func_instance].autottl)
					else
						DLOG("apply_fooling: could not discover autottl")
					end
				elseif desync.track.lua_state.autottl_cache[desync.func_instance].autottl then
					DLOG("apply_fooling: using cached autottl "..desync.track.lua_state.autottl_cache[desync.func_instance].autottl)
				end
				ttl=desync.track.lua_state.autottl_cache[desync.func_instance].autottl
			else
				DLOG("apply_fooling: cannot apply autottl because incoming ttl unknown")
			end
		end
		if not ttl and arg_ttl then
			ttl = tonumber(arg_ttl)
			if not ttl or ttl<0 or ttl>255 then
				error("apply_fooling: ip_ttl and ip6_ttl require valid value")
			end
		end
		--io.stderr:write("TTL "..tostring(ttl).."\n")
		return ttl
	end
	local function move_ts_top()
		local tsidx = find_tcp_option(dis.tcp.options, TCP_KIND_TS)
		if tsidx and tsidx>1 then
			table.insert(dis.tcp.options, 1, dis.tcp.options[tsidx])
			table.remove(dis.tcp.options, tsidx + 1)
		end
	end
	-- take default fooling from desync.arg
	if not fooling_options then fooling_options = desync.arg end
	-- use current packet if dissect not given
	if not dis then dis = desync.dis end
	if dis.tcp then
		if fooling_options.tcp_seq then
			if tonumber(fooling_options.tcp_seq) then
				dis.tcp.th_seq = u32add(dis.tcp.th_seq, fooling_options.tcp_seq)
			else
				error("apply_fooling: tcp_seq requires increment parameter. there's no default value.")
			end
		end
		if fooling_options.tcp_ack then
			if tonumber(fooling_options.tcp_ack) then
				dis.tcp.th_ack = u32add(dis.tcp.th_ack, fooling_options.tcp_ack)
			else
				error("apply_fooling: tcp_ack requires increment parameter. there's no default value.")
			end
		end
		if fooling_options.tcp_flags_unset then
			dis.tcp.th_flags = bitand(dis.tcp.th_flags, bitnot(parse_tcp_flags(fooling_options.tcp_flags_unset)))
		end
		if fooling_options.tcp_flags_set then
			dis.tcp.th_flags = bitor(dis.tcp.th_flags, parse_tcp_flags(fooling_options.tcp_flags_set))
		end
		if fooling_options.tcp_nop_del then
			for i=#dis.tcp.options,1,-1 do
				if dis.tcp.options[i].kind==TCP_KIND_NOOP then
					table.remove(dis.tcp.options,i)
				end
			end
		end
		if fooling_options.tcp_ts then
			if tonumber(fooling_options.tcp_ts) then
				local idx = find_tcp_option(dis.tcp.options,TCP_KIND_TS)
				if idx and (dis.tcp.options[idx].data and #dis.tcp.options[idx].data or 0)==8 then
					dis.tcp.options[idx].data = bu32(u32add(u32(dis.tcp.options[idx].data),fooling_options.tcp_ts))..string.sub(dis.tcp.options[idx].data,5)
				else
					DLOG("apply_fooling: timestamp tcp option not present or invalid")
				end
			else
				error("apply_fooling: tcp_ts requires increment parameter. there's no default value.")
			end
		end
		if fooling_options.tcp_md5 then
			if find_tcp_option(dis.tcp.options,TCP_KIND_MD5) then
				DLOG("apply_fooling: md5 option already present")
			else
				table.insert(dis.tcp.options,{kind=TCP_KIND_MD5, data=prepare_bin(fooling_options.tcp_md5,brandom(16))})
			end
		end
		if fooling_options.tcp_ts_up then
			move_ts_top()
		end
	end
	if dis.ip6 then
		local bin
		if fooling_options.ip6_hopbyhop then
			bin = prepare_bin(fooling_options.ip6_hopbyhop,"\x00\x00\x00\x00\x00\x00")
			insert_ip6_exthdr(dis.ip6,1,IPPROTO_HOPOPTS,bin)
		end
		if fooling_options.ip6_hopbyhop2 then
			bin = prepare_bin(fooling_options.ip6_hopbyhop2,"\x00\x00\x00\x00\x00\x00")
			insert_ip6_exthdr(dis.ip6,1,IPPROTO_HOPOPTS,bin)
		end
		-- for possible unfragmentable part
		if fooling_options.ip6_destopt then
			bin = prepare_bin(fooling_options.ip6_destopt,"\x00\x00\x00\x00\x00\x00")
			insert_ip6_exthdr(dis.ip6,nil,IPPROTO_DSTOPTS,bin)
		end
		if fooling_options.ip6_routing then
			bin = prepare_bin(fooling_options.ip6_routing,"\x00\x00\x00\x00\x00\x00")
			insert_ip6_exthdr(dis.ip6,nil,IPPROTO_ROUTING,bin)
		end
		-- for possible fragmentable part
		if fooling_options.ip6_destopt2 then
			bin = prepare_bin(fooling_options.ip6_destopt2,"\x00\x00\x00\x00\x00\x00")
			insert_ip6_exthdr(dis.ip6,nil,IPPROTO_DSTOPTS,bin)
		end
		if fooling_options.ip6_ah then
			-- by default truncated authentication header - only 6 bytes
			bin = prepare_bin(fooling_options.ip6_ah,"\x00\x00"..brandom(4))
			insert_ip6_exthdr(dis.ip6,nil,IPPROTO_AH,bin)
		end
	end
	if dis.ip then
		local ttl = ttl_discover(fooling_options.ip_ttl,fooling_options.ip_autottl)
		if ttl then dis.ip.ip_ttl = ttl end
	end
	if dis.ip6 then
		local ttl = ttl_discover(fooling_options.ip6_ttl,fooling_options.ip6_autottl)
		if ttl then dis.ip6.ip6_hlim = ttl end
	end

	if fooling_options.fool and #fooling_options.fool>0 then
		if type(_G[fooling_options.fool])=="function" then
			DLOG("apply_fooling: calling '"..fooling_options.fool.."'")
			_G[fooling_options.fool](dis, fooling_options)
		else
			error("apply_fooling: fool function '"..tostring(fooling_options.fool).."' does not exist")
		end
	end
end


-- assign dis.ip.ip_id value according to policy in ipid_options or desync.arg. apply def or "seq" policy if no ip_id options
-- ip_id=seq|rnd|zero|none
-- ip_id_conn - in 'seq' mode save current ip_id in track.lua_state to use it between packets
-- remember ip_id in desync
function apply_ip_id(desync, dis, ipid_options, def)
	-- use current packet if dissect not given
	if not dis then dis = desync.dis end
	if dis.ip then -- ip_id is ipv4 only, ipv6 doesn't have it
		-- take default ipid options from desync.arg
		if not ipid_options then ipid_options = desync.arg end
		local mode = ipid_options.ip_id or def or "seq"
		if mode == "seq" then
			if desync.track and ipid_options.ip_id_conn then
				dis.ip.ip_id = desync.track.lua_state.ip_id or dis.ip.ip_id
				desync.track.lua_state.ip_id = dis.ip.ip_id + 1
			else
				dis.ip.ip_id = desync.ip_id or dis.ip.ip_id
				desync.ip_id = dis.ip.ip_id + 1
			end
		elseif mode == "zero" then
			dis.ip.ip_id = 0
		elseif mode == "rnd" then
			dis.ip.ip_id = math.random(1,0xFFFF)
		end
	end
end


-- return length of ipv4 or ipv6 header without options and extension headers. should be 20 for ipv4 and 40 for ipv6.
function l3_base_len(dis)
	if dis.ip then
		return IP_BASE_LEN
	elseif dis.ip6 then
		return IP6_BASE_LEN
	else
		return 0
	end
end
-- return length of ipv4 options or summary length of all ipv6 extension headers
-- ip6_exthdr_last_idx - count lengths for headers up to this index
function l3_extra_len(dis, ip6_exthdr_last_idx)
	local l=0
	if dis.ip then
		if dis.ip.options then
			l = bitand(#dis.ip.options+3,NOT3)
		end
	elseif dis.ip6 and dis.ip6.exthdr then
		local ct
		if ip6_exthdr_last_idx and ip6_exthdr_last_idx>=0 and ip6_exthdr_last_idx<=#dis.ip6.exthdr then
			ct = ip6_exthdr_last_idx
		else
			ct = #dis.ip6.exthdr
		end
		for i=1, ct do
			if dis.ip6.exthdr[i].type == IPPROTO_AH then
				-- length in 32-bit words
				l = l + bitand(3+2+#dis.ip6.exthdr[i].data,NOT3)
			else
				-- length in 64-bit words
				l = l + bitand(7+2+#dis.ip6.exthdr[i].data,NOT7)
			end
		end
	end
	return l
end
-- return length of ipv4/ipv6 header with options/extension headers
function l3_len(dis)
	return l3_base_len(dis)+l3_extra_len(dis)
end
-- return length of tcp/udp headers without options. should be 20 for tcp and 8 for udp.
function l4_base_len(dis)
	if dis.tcp then
		return TCP_BASE_LEN
	elseif dis.udp then
		return UDP_BASE_LEN
	elseif dis.icmp then
		return ICMP_BASE_LEN
	else
		return 0
	end
end
-- return length of tcp options or 0 if not tcp
function l4_extra_len(dis)
	local l=0
	if dis.tcp and dis.tcp.options then
		for i=1, #dis.tcp.options do
			l = l + 1
			if dis.tcp.options[i].kind~=TCP_KIND_NOOP and dis.tcp.options[i].kind~=TCP_KIND_END then
				l = l + 1
				if dis.tcp.options[i].data then l = l + #dis.tcp.options[i].data end
			end
		end
		-- 4 byte aligned
		l = bitand(3+l,NOT3)
	end
	return l
end
-- return length of tcp header with options or base length of udp header - 8 bytes
function l4_len(dis)
	return l4_base_len(dis)+l4_extra_len(dis)
end
-- return summary extra length of ipv4/ipv6 and tcp headers. 0 if no options, no ext headers
function l3l4_extra_len(dis)
	return l3_extra_len(dis)+l4_extra_len(dis)
end
-- return summary length of ipv4/ipv6 and tcp/udp headers
function l3l4_len(dis)
	return l3_len(dis)+l4_len(dis)
end
-- return summary length of ipv4/ipv6 , tcp/udp headers and payload
function packet_len(dis)
	return l3l4_len(dis) + #dis.payload
end

-- option : ipfrag.ipfrag_disorder - send fragments from last to first
function rawsend_dissect_ipfrag(dis, options)
	if options and options.ipfrag and options.ipfrag.ipfrag and not dis.frag then
		local frag_func = options.ipfrag.ipfrag=="" and "ipfrag2" or options.ipfrag.ipfrag
		if type(_G[frag_func]) ~= "function" then
			error("rawsend_dissect_ipfrag: ipfrag function '"..tostring(frag_func).."' does not exist")
		end
		local fragments = _G[frag_func](dis, options.ipfrag)

		-- allow ipfrag function to do extheader magic with non-standard "next protocol"
		-- NOTE : dis.ip6 must have valid next protocol fields !!!!!
		local reconstruct_frag = options.reconstruct and deepcopy(options.reconstruct) or {}
		reconstruct_frag.ip6_preserve_next = true

		if fragments then
			if options.ipfrag.ipfrag_disorder then
				for i=#fragments,1,-1 do
					DLOG("sending ip fragment "..i)
					-- C function
					if not rawsend_dissect(fragments[i], options.rawsend, reconstruct_frag) then return false end
				end
			else
				for i, d in ipairs(fragments) do
					DLOG("sending ip fragment "..i)
					-- C function
					if not rawsend_dissect(d, options.rawsend, reconstruct_frag) then return false end
				end
			end
			return true
		end
		-- ipfrag failed. send unfragmented
	end
	-- C function
	return rawsend_dissect(dis, options and options.rawsend, options and options.reconstruct)
end

-- send dissect with tcp segmentation based on mss value. appply specified rawsend options.
function rawsend_dissect_segmented(desync, dis, mss, options)
	dis = dis or desync.dis
	local discopy = deepcopy(dis)
	options = options or desync_opts(desync)
	apply_fooling(desync, discopy, options and options.fooling)

	if dis.tcp then
		mss = mss or desync.tcp_mss
		local extra_len = l3l4_extra_len(discopy)
		if extra_len >= mss then return false end
		local max_data = mss - extra_len
		local urp = dis.tcp.th_urp
		local oob = bitand(dis.tcp.th_flags, TH_URG)~=0
		if #discopy.payload > max_data then
			local pos=1
			local len
			local payload=discopy.payload
			while pos <= #payload do
				len = #payload - pos + 1
				if len > max_data then len = max_data end
				if oob then
					if urp==0 and pos==1 then
						discopy.tcp.th_flags = bitor(discopy.tcp.th_flags, TH_URG)
					elseif urp>=pos and urp<(pos+len) then
						discopy.tcp.th_flags = bitor(discopy.tcp.th_flags, TH_URG)
						discopy.tcp.th_urp = urp-pos+1
					else
						discopy.tcp.th_flags = bitand(discopy.tcp.th_flags, bitnot(TH_URG))
						discopy.tcp.th_urp = 0
					end
				end
				discopy.payload = string.sub(payload,pos,pos+len-1)
				apply_ip_id(desync, discopy, options and options.ipid)
				if not rawsend_dissect_ipfrag(discopy, options) then
					-- stop if failed
					return false
				end
				discopy.tcp.th_seq = u32add(discopy.tcp.th_seq, len)
				pos = pos + len
			end
			return true
		end
	end
	apply_ip_id(desync, discopy, options and options.ipid)
	-- no reason to segment
	return rawsend_dissect_ipfrag(discopy, options)
end

-- send specified payload based on existing L3/L4 headers in the dissect. add seq to tcp.th_seq.
function rawsend_payload_segmented(desync, payload, seq, options)
	-- save some cpu and ram
	local dis = (payload or seq and seq~=0) and deepcopy(desync.dis) or desync.dis
	if payload then dis.payload = payload end
	if dis.tcp and seq then
		dis.tcp.th_seq = dis.tcp.th_seq + seq
	end
	return rawsend_dissect_segmented(desync, dis, nil, options)
end


-- check if desync.outgoing comply with arg.dir or def if it's not present or "out" of they are not present both. dir can be "in","out","any"
function direction_check(desync, def)
	local dir = desync.arg.dir or def or "out"
	return desync.outgoing and dir~="in" or not desync.outgoing and dir~="out"
end
-- if dir "in" or "out" cutoff current desync function from opposite direction
function direction_cutoff_opposite(ctx, desync, def)
	local dir = desync.arg.dir or def or "out"
	if dir=="out" then
		-- cutoff in
		instance_cutoff_shim(ctx, desync, false)
	elseif dir=="in" then
		-- cutoff out
		instance_cutoff_shim(ctx, desync, true)
	end
end

-- return true if l7payload matches filter l7payload_filter - comma separated list of payload types
function payload_match_filter(l7payload, l7payload_filter, def)
	local argpl = l7payload_filter or def or "known"
	local neg = string.sub(argpl,1,1)=="~"
	local pl = neg and string.sub(argpl,2) or argpl
	return neg ~= (in_list(pl, "all") or in_list(pl, l7payload) or in_list(pl, "known") and l7payload~="unknown" and l7payload~="empty")
end
-- check if desync payload type comply with payload type list in arg.payload
-- if arg.payload is not present - check for known payload - not empty and not unknown (nfqws1 behavior without "--desync-any-protocol" option)
-- if arg.payload is prefixed with '~' - it means negation
function payload_check(desync, def)
	local b = payload_match_filter(desync.l7payload, desync.arg.payload, def)
	if not b and b_debug then
		local argpl = desync.arg.payload or def or "known"
		DLOG("payload_check: payload '"..desync.l7payload.."' does not pass '"..argpl.."' filter")
	end
	return b
end

-- return name of replay drop field in track.lua_state for the current desync function instance
function replay_drop_key(desync)
	return desync.func_instance .. "_replay_drop"
end
-- set/unset replay drop flag in track.lua_state for the current desync function instance
function replay_drop_set(desync, v)
	if desync.track then
		if v == nil then v=true end
		local rdk = replay_drop_key(desync)
		if v then
			if desync.replay then desync.track.lua_state[rdk] = true end
		else
			desync.track.lua_state[rdk] = nil
		end
	end
end
-- auto unset replay drop flag if desync is not replay or it's the last replay piece
-- return true if the caller should return VERDICT_DROP
function replay_drop(desync)
	if desync.track then
		local drop = desync.replay and desync.track.lua_state[replay_drop_key(desync)]
		if not desync.replay or desync.replay_piece_last then
			-- replay stopped or last piece of reasm
			replay_drop_set(desync, false)
		end
		if drop then
			DLOG("dropping replay packet because reasm was already sent")
			return true
		end
	end
	return false
end
-- true if desync is not replay or it's the first replay piece
function replay_first(desync)
	return not desync.replay or desync.replay_piece==1
end

-- generate random host
-- template "google.com", len=16 : h82aj.google.com
-- template "google.com", len=11 : .google.com
-- template "google.com", len=10 : google.com
-- template "google.com", len=7 : gle.com
-- no template, len=6 : b8c54a
-- no template, len=7 : u9a.edu
-- no template, len=10 : jgha7c.com
function genhost(len, template)
	if template and #template>0 then
		if len <= #template then
			return string.sub(template,#template-len+1)
		elseif len==(#template+1) then
			return "."..template
		else
			return brandom_az(1)..brandom_az09(len-#template-2).."."..template
		end
	else
		if len>=7 then
			local tlds = {"com","org","net","edu","gov","biz"}
			local tld = tlds[math.random(#tlds)]
			return brandom_az(1)..brandom_az09(len-#tld-1-1).."."..tld
		else
			return brandom_az(1)..brandom_az09(len-1)
		end
	end
end

-- return ip addr of target host in text form
function host_ip(desync)
	return desync.target.ip and ntop(desync.target.ip) or desync.target.ip6 and ntop(desync.target.ip6)
end
-- return hostname of target host if present or ip address in text form otherwise
function host_or_ip(desync)
	if desync.track and desync.track.hostname then
		return desync.track.hostname
	end
	return host_ip(desync)
end

-- rate limited update of global ifaddrs
function update_ifaddrs()
	if ifaddrs then
		local now = os.time()
		if not ifaddrs_last then ifaddrs_last = now end
		if ifaddrs_last~=now then
			ifaddrs = get_ifaddrs()
			ifaddrs_last = now
		end
	else
		ifaddrs = get_ifaddrs()
	end
end
-- search ifaddrs for ip and return interface name or nil if not found
-- do not call get_ifaddrs too often to avoid overhead
function ip2ifname(ip)
	update_ifaddrs()
	if not ifaddrs then return nil end
	for ifname,ifinfo in pairs(ifaddrs) do
		if array_field_search(ifinfo.addr, "addr", ip) then
			return ifname
		end
	end
end

function is_absolute_path(path)
	if string.sub(path,1,1)=='/' then return true end
	local un = uname()
	return string.sub(un.sysname,1,6)=="CYGWIN" and string.sub(path,2,2)==':'
end
function append_path(path,file)
	return string.sub(path,#path,#path)=='/' and path..file or path.."/"..file
end
function writable_file_name(filename)
	if is_absolute_path(filename) then return filename end
	local writedir = os.getenv("WRITABLE")
	if not writedir then return filename end
	return append_path(writedir, filename)
end

-- arg : wsize=N . tcp window size
-- arg : scale=N . tcp option scale factor
-- return : true of changed anything
function wsize_rewrite(dis, arg)
	local b = false
	if arg.wsize then
		local wsize = tonumber(arg.wsize)
		DLOG("wsize_rewrite: window size "..dis.tcp.th_win.." => "..wsize)
		dis.tcp.th_win = tonumber(arg.wsize)
		b = true
	end
	if arg.scale then
		local scale = tonumber(arg.scale)
		local i = find_tcp_option(dis.tcp.options, TCP_KIND_SCALE)
		if i then
			local oldscale = u8(dis.tcp.options[i].data)
			if scale>oldscale then
				DLOG("wsize_rewrite: not increasing scale factor")
			elseif scale<oldscale then
				DLOG("wsize_rewrite: scale factor "..oldscale.." => "..scale)
				dis.tcp.options[i].data = bu8(scale)
				b = true
			end
		end
	end
	return b
end

-- standard fragmentation to 2 ip fragments
-- function returns 2 dissects with fragments
-- option : ipfrag_pos_udp - udp frag position. ipv4 : starting from L4 header. ipv6: starting from fragmentable part. must be multiple of 8. default 8
-- option : ipfrag_pos_tcp - tcp frag position. ipv4 : starting from L4 header. ipv6: starting from fragmentable part. must be multiple of 8. default 32
-- option : ipfrag_pos_icmp - icmp frag position. ipv4 : starting from L4 header. ipv6: starting from fragmentable part. must be multiple of 8. default 8
-- option : ipfrag_pos - icmp frag position for other L4. ipv4 : starting from L4 header. ipv6: starting from fragmentable part. must be multiple of 8. default 32
-- option : ipfrag_next - next protocol field in ipv6 fragment extenstion header of the second fragment. same as first by default.
function ipfrag2(dis, ipfrag_options)
	local function frag_idx(exthdr)
		-- fragment header after hopbyhop, destopt, routing
		-- allow second destopt header to be in fragmentable part
		-- test case : --lua-desync=send:ipfrag:ipfrag_pos_tcp=40:ip6_hopbyhop:ip6_destopt:ip6_destopt2
		-- WINDOWS may not send second ipv6 fragment with next protocol 60 (destopt)
		-- test case windows : --lua-desync=send:ipfrag:ipfrag_pos_tcp=40:ip6_hopbyhop:ip6_destopt:ip6_destopt2:ipfrag_next=255
		if exthdr then
			local first_destopts
			for i=1,#exthdr do
				if exthdr[i].type==IPPROTO_DSTOPTS then
					first_destopts = i
					break
				end
			end
			for i=#exthdr,1,-1 do
				if exthdr[i].type==IPPROTO_HOPOPTS or exthdr[i].type==IPPROTO_ROUTING or (exthdr[i].type==IPPROTO_DSTOPTS and i==first_destopts) then
					return i+1
				end
			end
		end
		return 1
	end

	local pos
	local dis1, dis2
	local l3

	if dis.tcp then
		pos = ipfrag_options.ipfrag_pos_tcp or 32
	elseif dis.udp then
		pos = ipfrag_options.ipfrag_pos_udp or 8
	elseif dis.icmp then
		pos = ipfrag_options.ipfrag_pos_icmp or 8
	else
		pos = ipfrag_options.ipfrag_pos or 32
	end

	DLOG("ipfrag2")

	if not pos then
		error("ipfrag2: no frag position")
	end
	l3 = l3_len(dis)
	if bitand(pos,7)~=0 then
		error("ipfrag2: frag position must be multiple of 8")
	end
	if (pos+l3)>0xFFFF then
		error("ipfrag2: too high frag offset")
	end

	local plen = l3 + l4_len(dis) + #dis.payload
	if dis.ip then
		-- ipv4 frag is done by both lua and C part
		-- lua code must correctly set ip_len, IP_MF and ip_off and provide full unfragmented payload
		-- ip_len must be set to valid value as it would appear in the fragmented packet
		-- ip_off must be set to fragment offset and IP_MF bit must be set if it's not the last fragment
		-- C code constructs unfragmented packet then moves everything after ip header according to ip_off and ip_len

		if (pos+l3)>=plen then
			DLOG("ipfrag2: ip frag pos "..pos.." exceeds packet length. ipfrag cancelled.")
			return nil
		end

		-- ip_id must not be zero or fragment will be dropped
		local ip_id = dis.ip.ip_id==0 and math.random(1,0xFFFF) or dis.ip.ip_id
		dis1 = deepcopy(dis)
		-- ip_len holds the whole packet length starting from the ip header. it includes ip, transport headers and payload
		dis1.ip.ip_len = l3 + pos -- ip header + first part up to frag pos
		dis1.ip.ip_off = IP_MF -- offset 0, IP_MF - more fragments
		dis1.ip.ip_id = ip_id
		dis2 = deepcopy(dis)
		dis2.ip.ip_off = bitrshift(pos,3) -- offset = frag pos, IP_MF - not set
		dis2.ip.ip_len = plen - pos -- unfragmented packet length - frag pos
		dis2.ip.ip_id = ip_id
	end

	if dis.ip6 then
		-- ipv6 frag is done by both lua and C part
		-- lua code must insert fragmentation extension header at any desirable position, fill fragment offset, more fragments flag and ident
		-- lua must set up ip6_plen as it would appear in the fragmented packet
		-- C code constructs unfragmented packet then moves fragmentable part as needed

		local idxfrag = frag_idx(dis.ip6.exthdr)
		local l3extra = l3_extra_len(dis, idxfrag-1) -- all ext headers before frag

		l3 = l3_base_len(dis) + l3extra
		if (pos+l3)>=plen then
			DLOG("ipfrag2: ip frag pos "..pos.." exceeds packet length. ipfrag cancelled.")
			return nil
		end

		l3extra = l3extra + 8 -- + 8 bytes for frag header
		local ident = math.random(1,0xFFFFFFFF)

		dis1 = deepcopy(dis)
		insert_ip6_exthdr(dis1.ip6, idxfrag, IPPROTO_FRAGMENT, bu16(IP6F_MORE_FRAG)..bu32(ident))
		dis1.ip6.ip6_plen = l3extra + pos
		dis2 = deepcopy(dis)
		insert_ip6_exthdr(dis2.ip6, idxfrag, IPPROTO_FRAGMENT, bu16(pos)..bu32(ident))
		-- only next proto of the first fragment is considered by standard
		-- fragments with non-zero offset can have different "next protocol" field
		-- this can be used to evade protection systems
		if ipfrag_options.ipfrag_next then
			dis2.ip6.exthdr[idxfrag].next = tonumber(ipfrag_options.ipfrag_next)
		end
		dis2.ip6.ip6_plen = plen - IP6_BASE_LEN + 8 - pos -- packet len without frag + 8 byte frag header - ipv6 base header
	end
	return {dis1,dis2}
end


-- option: sni_snt - server name type value in existing names
-- option: sni_snt_new - server name type value for new names
-- option: sni_del_ext - delete sni extension
-- option: sni_del - delete all names
-- option: sni_first - add name to the beginning
-- option: sni_last - add name to the end
function tls_client_hello_mod(tls, options)
	local tdis = tls_dissect(tls)
	if not tdis then
		DLOG("tls_client_hello_mod: could not dissect tls")
		return
	end
	if not tdis.handshake or not tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT] then
		DLOG("tls_client_hello_mod: handshake not dissected")
		return
	end
	local idx_sni
	if options.sni_snt or options.sni_del_ext or options.sni_del or options.sni_first or options.sni_last then
		if tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext then
			idx_sni = array_field_search(tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext, "type", TLS_EXT_SERVER_NAME)
		else
			tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext={}
		end
		if not idx_sni then
			DLOG("tls_client_hello_mod: no SNI extension. adding")
			table.insert(tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext, 1, { type = TLS_EXT_SERVER_NAME, dis = { list = {} } } )
			idx_sni = 1
		end
	end
	if options.sni_del_ext then
		table.remove(tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext, idx_sni)
	else
		if options.sni_del then
			tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext[idx_sni].dis.list = {}
		elseif options.sni_snt then
			for i,v in pairs(tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext[idx_sni].dis.list) do
				v.type = options.sni_snt
			end
		end
		if options.sni_first then
			table.insert(tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext[idx_sni].dis.list, 1, { name = options.sni_first, type = options.sni_snt_new } )
		end
		if options.sni_last then
			table.insert(tdis.handshake[TLS_HANDSHAKE_TYPE_CLIENT].dis.ext[idx_sni].dis.list, { name = options.sni_last, type = options.sni_snt_new } )
		end
	end
	local rtls = tls_reconstruct(tdis)
	if not rtls then
		DLOG_ERR("tls_client_hello_mod: reconstruct error")
	end
	return rtls
end

-- checks if filename is gzip compressed
function is_gzip_file(filename)
	local f, err = io.open(filename, "rb")
	if not f then
		error("is_gzip_file: "..err)
	end
	local hdr = f:read(2)
	f:close()
	return hdr and hdr=="\x1F\x8B"
end
-- ungzip file to raw string
-- expected_ratio = uncompressed_size/compressed_size (default 4)
function gunzip_file(filename, expected_ratio, read_block_size)
	local f, err = io.open(filename, "rb")
	if not f then
		error("gunzip_file: "..err)
	end
	if not read_block_size then read_block_size=16384 end
	if not expected_ratio then expected_ratio=4 end

	local decompressed=""
	local gz = gunzip_init()
	if not gz then
		error("gunzip_file: stream init error")
	end
	repeat
		local compressed, err = f:read(read_block_size)
		if not compressed then
			f:close()
			gunzip_end(gz)
			if err then
				error("gunzip_file: file read error : "..err)
			else
				return nil
			end
		end
		local decomp, eof = gunzip_inflate(gz, compressed, #compressed * expected_ratio)
		if not decomp then
			f:close()
			gunzip_end(gz)
			return nil
		end
		decompressed = decompressed .. decomp
	until eof
	f:close()
	gunzip_end(gz)
	return decompressed
end
-- zip file to raw string
-- expected_ratio = uncompressed_size/compressed_size (default 2)
-- level : 1..9 (default 9)
-- memlevel : 1..8 (default 8)
function gzip_file(filename, data, expected_ratio, level, memlevel, compress_block_size)
	local f, err = io.open(filename, "wb")
	if not f then
		error("gzip_file: "..err)
	end
	if not compress_block_size then compress_block_size=16384 end
	if not expected_ratio then expected_ratio=2 end

	local gz = gzip_init(nil, level, memlevel)
	if not gz then
		error("gzip_file: stream init error")
	end
	local off=1
	repeat
		local block_size = #data-off+1
		if block_size>compress_block_size then block_size=compress_block_size end
		local comp, eof = gzip_deflate(gz, string.sub(data,off,off+block_size-1), block_size / expected_ratio)
		if not comp then
			f:close()
			gzip_end(gz)
			return nil
		end
		f:write(comp)
		off = off + block_size
	until eof
	f:close()
	gzip_end(gz)
end
-- reads the whole file
function readfile(filename)
	local f, err = io.open(filename, "rb")
	if not f then
		error("readfile: "..err)
	end
	local s, err = f:read("*a")
	f:close()
	if err then
		error("readfile: "..err)
	end
	return s
end
-- reads plain or gzipped file with transparent decompression
-- expected_ratio = uncompressed_size/compressed_size (default 4)
function z_readfile(filename, expected_ratio)
	return is_gzip_file(filename) and gunzip_file(filename, expected_ratio) or readfile(filename)
end
-- write data to filename
function writefile(filename, data)
	local f, err = io.open(filename, "wb")
	if not f then
		error("writefile: "..err)
	end
	local s, err = f:write(data)
	f:close()
	if not s then
		error("writefile: "..err)
	end
end


-- DISSECTORS

function http_dissect_header(header)
	local p1,p2
	p1,p2 = string.find(header,":")
	if p1 then
		p2=string.find(header,"[^ \t]",p2+1)
		return string.sub(header,1,p1-1), p2 and string.sub(header,p2) or "", p1-1, p2 or #header
	end
	return nil
end
-- make table with structured http header representation
function http_dissect_headers(http, pos)
	local eol,pnext,header,value,headers,pos_endheader,pos_startvalue,pos_headers_end
	headers={}
	while pos do
		eol,pnext = find_next_line(http,pos)
		header = string.sub(http,pos,eol)
		if #header == 0 then
			pos_headers_end = pnext
			break
		end
		header,value,pos_endheader,pos_startvalue = http_dissect_header(header)
		if header then
			headers[#headers+1] = { header_low = string.lower(header), header = header, value = value, pos_start = pos, pos_end = eol, pos_header_end = pos+pos_endheader-1, pos_value_start = pos+pos_startvalue-1 }
		end
		pos=pnext
	end
	return headers, pos_headers_end
end
-- make table with structured http request representation
function http_dissect_req(http)
	if not http then return nil; end
	local eol,pnext,req,hdrpos
	local pos=1
	-- skip methodeol empty line(s)
	while pos do
		eol,pnext = find_next_line(http,pos)
		req = string.sub(http,pos,eol)
		pos=pnext
		if #req>0 then break end
	end
	hdrpos = pos
	if not req or #req==0 then return nil end
	pos = string.find(req,"[ \t]")
	if not pos then return nil end
	local method = string.sub(req,1,pos-1);
	pos = string.find(req,"[^ \t]",pos+1)
	if not pos then return nil end
	pnext = string.find(req,"[ \t]",pos+1)
	if not pnext then pnext = #req + 1 end
	local uri = string.sub(req,pos,pnext-1)
	pos = string.find(req,"[^ \t]",pnext)
	local http_ver
	if pos then
		pnext = string.find(req,"[\r\n]",pos)
		if not pnext then pnext = #req + 1 end
		http_ver = string.sub(req,pos,pnext-1)
	end
	local hdis = { method = method, uri = uri, http_ver = http_ver }
	hdis.headers, hdis.pos_headers_end = http_dissect_headers(http,hdrpos)
	if hdis.pos_headers_end then
		hdis.body = string.sub(http, hdis.pos_headers_end)
	end
	return hdis
end
function http_dissect_reply(http)
	if not http then return nil; end
	local s, pos, code
	s = string.sub(http,1,8)
	if s~="HTTP/1.1" and s~="HTTP/1.0" then return nil end
	pos = string.find(http,"[ \t\r\n]",10)
	if not pos then return nil end
	code = tonumber(string.sub(http,10,pos-1))
	if not code then return nil end
	s,pos = find_next_line(http,pos)
	local hdis = { code = code }
	hdis.headers, hdis.pos_headers_end = http_dissect_headers(http,pos)
	if hdis.pos_headers_end then
		hdis.body = string.sub(http, hdis.pos_headers_end)
	end
	return hdis
end
function http_reconstruct_headers(headers, unixeol)
	local eol = unixeol and "\n" or "\r\n"
	return headers and barray(headers, function(a) return a.header..": "..a.value..eol end) or ""
end
function http_reconstruct_req(hdis, unixeol)
	local eol = unixeol and "\n" or "\r\n"
	return hdis.method.." "..hdis.uri..(hdis.http_ver and (" "..hdis.http_ver) or "")..eol..http_reconstruct_headers(hdis.headers, unixeol)..eol..(hdis.body or "")
end

function dissect_url(url)
	local p1,pb,pstart,pend
	local proto, creds, domain, port, uri
	p1 = string.find(url,"[^ \t]")
	if not p1 then return nil end
	pb = p1
	pstart,pend = string.find(url,"[a-z]+://",p1)
	if pend then
		proto = string.sub(url,pstart,pend-3)
		p1 = pend+1
	end
	pstart,pend = string.find(url,"[@/]",p1)
	if pend and string.sub(url,pstart,pend)=='@' then
		creds = string.sub(url,p1,pend-1)
		p1 = pend+1
	end
	pstart,pend = string.find(url,"/",p1,true)
	if pend then
		if pend==pb then
			uri = string.sub(url,pb)
		else
			uri = string.sub(url,pend)
			domain = string.sub(url,p1,pend-1)
		end
	else
		if proto then
			domain = string.sub(url,p1)
		else
			uri = string.sub(url,p1)
		end
	end
	if domain then
		pstart,pend = string.find(domain,':',1,true)
		if pend then
			port = string.sub(domain, pend+1)
			domain = string.sub(domain, 1, pstart-1)
		end
	end
	return { proto = proto, creds = creds, domain = domain, port = port, uri=uri }
end

function dissect_nld(domain, level)
	if domain then
		local n=1
		for pos=#domain,1,-1 do
			if string.sub(domain,pos,pos)=='.' then
				if n==level then
					return string.sub(domain, pos+1)
				end
				n=n+1
			end
		end
		if n==level then
			return domain
		end
	end
	return nil
end



TLS_EXT_SERVER_NAME=0
TLS_EXT_MAX_FRAGMENT_LENGTH=1
TLS_EXT_CLIENT_CERTIFICATE_URL=2
TLS_EXT_TRUSTED_CA_KEYS=3
TLS_EXT_TRUNCATED_HMAC=4
TLS_EXT_STATUS_REQUEST=5
TLS_EXT_USER_MAPPING=6
TLS_EXT_CLIENT_AUTHZ=7
TLS_EXT_SERVER_AUTHZ=8
TLS_EXT_CERT_TYPE=9
TLS_EXT_SUPPORTED_GROUPS=10
TLS_EXT_EC_POINT_FORMATS=11
TLS_EXT_SRP=12
TLS_EXT_SIGNATURE_ALGORITHMS=13
TLS_EXT_USE_SRTP=14
TLS_EXT_HEARTBEAT=15
TLS_EXT_ALPN=16
TLS_EXT_STATUS_REQUEST_V2=17
TLS_EXT_SIGNED_CERTIFICATE_TIMESTAMP=18
TLS_EXT_CLIENT_CERT_TYPE=19
TLS_EXT_SERVER_CERT_TYPE=20
TLS_EXT_PADDING=21
TLS_EXT_ENCRYPT_THEN_MAC=22
TLS_EXT_EXTENDED_MASTER_SECRET=23
TLS_EXT_TOKEN_BINDING=24
TLS_EXT_CACHED_INFO=25
TLS_EXT_COMPRESS_CERTIFICATE=27
TLS_EXT_RECORD_SIZE_LIMIT=28
TLS_EXT_DELEGATED_CREDENTIALS=34
TLS_EXT_SESSION_TICKET_TLS=35
TLS_EXT_KEY_SHARE_OLD=40
TLS_EXT_PRE_SHARED_KEY=41
TLS_EXT_EARLY_DATA=42
TLS_EXT_SUPPORTED_VERSIONS=43
TLS_EXT_COOKIE=44
TLS_EXT_PSK_KEY_EXCHANGE_MODES=45
TLS_EXT_TICKET_EARLY_DATA_INFO=46
TLS_EXT_CERTIFICATE_AUTHORITIES=47
TLS_EXT_OID_FILTERS=48
TLS_EXT_POST_HANDSHAKE_AUTH=49
TLS_EXT_SIGNATURE_ALGORITHMS_CERT=50
TLS_EXT_KEY_SHARE=51
TLS_EXT_TRANSPARENCY_INFO=52
TLS_EXT_CONNECTION_ID_DEPRECATED=53
TLS_EXT_CONNECTION_ID=54
TLS_EXT_EXTERNAL_ID_HASH=55
TLS_EXT_EXTERNAL_SESSION_ID=56
TLS_EXT_QUIC_TRANSPORT_PARAMETERS_V1=57
TLS_EXT_TICKET_REQUEST=58
TLS_EXT_DNSSEC_CHAIN=59
TLS_EXT_GREASE_0A0A=2570
TLS_EXT_GREASE_1A1A=6682
TLS_EXT_GREASE_2A2A=10794
TLS_EXT_NPN=13172
TLS_EXT_GREASE_3A3A=14906
TLS_EXT_ALPS_OLD=17513
TLS_EXT_ALPS=17613
TLS_EXT_GREASE_4A4A=19018
TLS_EXT_GREASE_5A5A=23130
TLS_EXT_GREASE_6A6A=27242
TLS_EXT_CHANNEL_ID_OLD=30031
TLS_EXT_CHANNEL_ID=30032
TLS_EXT_GREASE_7A7A=31354
TLS_EXT_GREASE_8A8A=35466
TLS_EXT_GREASE_9A9A=39578
TLS_EXT_GREASE_AAAA=43690
TLS_EXT_GREASE_BABA=47802
TLS_EXT_GREASE_CACA=51914
TLS_EXT_GREASE_DADA=56026
TLS_EXT_GREASE_EAEA=60138
TLS_EXT_GREASE_FAFA=64250
TLS_EXT_ECH_OUTER_EXTENSIONS=64768
TLS_EXT_ENCRYPTED_CLIENT_HELLO=65037
TLS_EXT_RENEGOTIATION_INFO=65281
TLS_EXT_QUIC_TRANSPORT_PARAMETERS=65445
TLS_EXT_ENCRYPTED_SERVER_NAME=65486

TLS_HELLO_EXT_NAMES = {
 [TLS_EXT_SERVER_NAME] = "server_name", -- RFC 6066
 [TLS_EXT_MAX_FRAGMENT_LENGTH] = "max_fragment_length",-- RFC 6066
 [TLS_EXT_CLIENT_CERTIFICATE_URL] = "client_certificate_url", -- RFC 6066
 [TLS_EXT_TRUSTED_CA_KEYS] = "trusted_ca_keys", -- RFC 6066
 [TLS_EXT_TRUNCATED_HMAC] = "truncated_hmac", -- RFC 6066
 [TLS_EXT_STATUS_REQUEST] = "status_request", -- RFC 6066
 [TLS_EXT_USER_MAPPING] = "user_mapping", -- RFC 4681
 [TLS_EXT_CLIENT_AUTHZ] = "client_authz", -- RFC 5878
 [TLS_EXT_SERVER_AUTHZ] = "server_authz", -- RFC 5878
 [TLS_EXT_CERT_TYPE] = "cert_type", -- RFC 6091
 [TLS_EXT_SUPPORTED_GROUPS] = "supported_groups", -- RFC 4492, RFC 7919
 [TLS_EXT_EC_POINT_FORMATS] = "ec_point_formats", -- RFC 4492
 [TLS_EXT_SRP] = "srp", -- RFC 5054
 [TLS_EXT_SIGNATURE_ALGORITHMS] = "signature_algorithms", -- RFC 5246
 [TLS_EXT_USE_SRTP] = "use_srtp", -- RFC 5764
 [TLS_EXT_HEARTBEAT] = "heartbeat", -- RFC 6520
 [TLS_EXT_ALPN] = "application_layer_protocol_negotiation", -- RFC 7301
 [TLS_EXT_STATUS_REQUEST_V2] = "status_request_v2", -- RFC 6961
 [TLS_EXT_SIGNED_CERTIFICATE_TIMESTAMP] = "signed_certificate_timestamp", -- RFC 6962
 [TLS_EXT_CLIENT_CERT_TYPE] = "client_certificate_type", -- RFC 7250
 [TLS_EXT_SERVER_CERT_TYPE] = "server_certificate_type", -- RFC 7250
 [TLS_EXT_PADDING] = "padding", -- RFC 7685
 [TLS_EXT_ENCRYPT_THEN_MAC] = "encrypt_then_mac", -- RFC 7366
 [TLS_EXT_EXTENDED_MASTER_SECRET] = "extended_master_secret", -- RFC 7627
 [TLS_EXT_TOKEN_BINDING] = "token_binding", -- https://tools.ietf.org/html/draft-ietf-tokbind-negotiation
 [TLS_EXT_CACHED_INFO] = "cached_info", -- RFC 7924
 [TLS_EXT_COMPRESS_CERTIFICATE] = "compress_certificate", -- https://tools.ietf.org/html/draft-ietf-tls-certificate-compression-03
 [TLS_EXT_RECORD_SIZE_LIMIT] = "record_size_limit", -- RFC 8449
 [TLS_EXT_DELEGATED_CREDENTIALS] = "delegated_credentials", -- draft-ietf-tls-subcerts-10.txt
 [TLS_EXT_SESSION_TICKET_TLS] = "session_ticket", -- RFC 5077 / RFC 8447
 [TLS_EXT_KEY_SHARE_OLD] = "Reserved (key_share)", -- https://tools.ietf.org/html/draft-ietf-tls-tls13-22 (removed in -23)
 [TLS_EXT_PRE_SHARED_KEY] = "pre_shared_key", -- RFC 8446
 [TLS_EXT_EARLY_DATA] = "early_data", -- RFC 8446
 [TLS_EXT_SUPPORTED_VERSIONS] = "supported_versions", -- RFC 8446
 [TLS_EXT_COOKIE] = "cookie", -- RFC 8446
 [TLS_EXT_PSK_KEY_EXCHANGE_MODES] = "psk_key_exchange_modes", -- RFC 8446
 [TLS_EXT_TICKET_EARLY_DATA_INFO] = "Reserved (ticket_early_data_info)", -- draft-ietf-tls-tls13-18 (removed in -19)
 [TLS_EXT_CERTIFICATE_AUTHORITIES] = "certificate_authorities", -- RFC 8446
 [TLS_EXT_OID_FILTERS] = "oid_filters", -- RFC 8446
 [TLS_EXT_POST_HANDSHAKE_AUTH] = "post_handshake_auth", -- RFC 8446
 [TLS_EXT_SIGNATURE_ALGORITHMS_CERT] = "signature_algorithms_cert", -- RFC 8446
 [TLS_EXT_KEY_SHARE] = "key_share", -- RFC 8446
 [TLS_EXT_TRANSPARENCY_INFO] = "transparency_info", -- draft-ietf-trans-rfc6962-bis-41
 [TLS_EXT_CONNECTION_ID_DEPRECATED] = "connection_id (deprecated)", -- draft-ietf-tls-dtls-connection-id-07
 [TLS_EXT_CONNECTION_ID] = "connection_id", -- RFC 9146
 [TLS_EXT_EXTERNAL_ID_HASH] = "external_id_hash", -- RFC 8844
 [TLS_EXT_EXTERNAL_SESSION_ID] = "external_session_id", -- RFC 8844
 [TLS_EXT_QUIC_TRANSPORT_PARAMETERS_V1] = "quic_transport_parameters", -- draft-ietf-quic-tls-33
 [TLS_EXT_TICKET_REQUEST] = "ticket_request", -- draft-ietf-tls-ticketrequests-07
 [TLS_EXT_DNSSEC_CHAIN] = "dnssec_chain", -- RFC 9102
 [TLS_EXT_GREASE_0A0A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_1A1A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_2A2A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_NPN] = "next_protocol_negotiation", -- https://datatracker.ietf.org/doc/html/draft-agl-tls-nextprotoneg-03
 [TLS_EXT_GREASE_3A3A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_ALPS_OLD] = "application_settings_old", -- draft-vvv-tls-alps-01
 [TLS_EXT_ALPS] = "application_settings", -- draft-vvv-tls-alps-01 -- https://chromestatus.com/feature/5149147365900288
 [TLS_EXT_GREASE_4A4A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_5A5A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_6A6A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_CHANNEL_ID_OLD] = "channel_id_old", -- https://tools.ietf.org/html/draft-balfanz-tls-channelid-00
 [TLS_EXT_CHANNEL_ID] = "channel_id", -- https://tools.ietf.org/html/draft-balfanz-tls-channelid-01
 [TLS_EXT_RENEGOTIATION_INFO] = "renegotiation_info", -- RFC 5746
 [TLS_EXT_GREASE_7A7A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_8A8A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_9A9A] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_AAAA] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_BABA] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_CACA] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_DADA] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_EAEA] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_GREASE_FAFA] = "Reserved (GREASE)", -- RFC 8701
 [TLS_EXT_QUIC_TRANSPORT_PARAMETERS] = "quic_transport_parameters (drafts version)", -- https://tools.ietf.org/html/draft-ietf-quic-tls
 [TLS_EXT_ENCRYPTED_SERVER_NAME] = "encrypted_server_name", -- https://tools.ietf.org/html/draft-ietf-tls-esni-01
 [TLS_EXT_ENCRYPTED_CLIENT_HELLO] = "encrypted_client_hello", -- https://datatracker.ietf.org/doc/draft-ietf-tls-esni/17/
 [TLS_EXT_ECH_OUTER_EXTENSIONS] = "ech_outer_extensions" -- https://datatracker.ietf.org/doc/draft-ietf-tls-esni/17/
}

TLS_RECORD_TYPE_CHANGE_CIPHER_SPEC=0x14
TLS_RECORD_TYPE_ALERT=0x15
TLS_RECORD_TYPE_HANDSHAKE=0x16
TLS_RECORD_TYPE_DATA=0x17
TLS_RECORD_TYPE_HEARTBEAT=0x18

TLS_RECORD_TYPE_NAMES = {
 [TLS_RECORD_TYPE_CHANGE_CIPHER_SPEC] = "change_cipher_spec",
 [TLS_RECORD_TYPE_ALERT] = "alert",
 [TLS_RECORD_TYPE_HANDSHAKE] = "handshake",
 [TLS_RECORD_TYPE_DATA] = "data",
 [TLS_RECORD_TYPE_HEARTBEAT] = "heartbeat"
}

TLS_HANDSHAKE_TYPE_HELLO_REQUEST=0
TLS_HANDSHAKE_TYPE_CLIENT=1
TLS_HANDSHAKE_TYPE_SERVER=2
TLS_HANDSHAKE_TYPE_CERTIFICATE=11
TLS_HANDSHAKE_TYPE_KEY_EXCHANGE=12
TLS_HANDSHAKE_TYPE_CERTIFICATE_REQUEST=13
TLS_HANDSHAKE_TYPE_SERVER_HELLO_DONE=14
TLS_HANDSHAKE_TYPE_CERTIFICATE_VERIFY=15
TLS_HANDSHAKE_TYPE_CLIENT_KEY_EXCHANGE=16
TLS_HANDSHAKE_TYPE_FINISHED=20
TLS_HANDSHAKE_TYPE_CERTIFICATE_URL=21
TLS_HANDSHAKE_TYPE_CERTIFICATE_STATUS=22
TLS_HANDSHAKE_TYPE_SUPPLEMENTAL_DATA=23
TLS_HANDSHAKE_TYPE_KEY_UPDATE=24
TLS_HANDSHAKE_TYPE_COMPRESSED_CERTIFICATE=25

TLS_HANDSHAKE_TYPE_NAMES = {
 [TLS_HANDSHAKE_TYPE_HELLO_REQUEST]="hello_request",
 [TLS_HANDSHAKE_TYPE_CLIENT]="client_hello",
 [TLS_HANDSHAKE_TYPE_SERVER]="server_hello",
 [TLS_HANDSHAKE_TYPE_CERTIFICATE]="certificate",
 [TLS_HANDSHAKE_TYPE_KEY_EXCHANGE]="key_exchange",
 [TLS_HANDSHAKE_TYPE_CERTIFICATE_REQUEST]="certificate_request",
 [TLS_HANDSHAKE_TYPE_SERVER_HELLO_DONE]="hello_done",
 [TLS_HANDSHAKE_TYPE_CERTIFICATE_VERIFY]="certificate_verify",
 [TLS_HANDSHAKE_TYPE_CLIENT_KEY_EXCHANGE]="client_key_exchange",
 [TLS_HANDSHAKE_TYPE_FINISHED]="finished",
 [TLS_HANDSHAKE_TYPE_CERTIFICATE_URL]="certificate_url",
 [TLS_HANDSHAKE_TYPE_CERTIFICATE_STATUS]="certificate_status",
 [TLS_HANDSHAKE_TYPE_SUPPLEMENTAL_DATA]="supplemental_data",
 [TLS_HANDSHAKE_TYPE_KEY_UPDATE]="key_update",
 [TLS_HANDSHAKE_TYPE_COMPRESSED_CERTIFICATE]="compressed_certificate"
}

TLS_VER_SSL30=0x0300
TLS_VER_TLS10=0x0301
TLS_VER_TLS11=0x0302
TLS_VER_TLS12=0x0303
TLS_VER_TLS13=0x0304

TLS_HANDSHAKE_QUIC_TP_ORIGINAL_DESTINATION_CONNECTION_ID=0x00
TLS_HANDSHAKE_QUIC_TP_MAX_IDLE_TIMEOUT=0x01
TLS_HANDSHAKE_QUIC_TP_STATELESS_RESET_TOKEN=0x02
TLS_HANDSHAKE_QUIC_TP_MAX_UDP_PAYLOAD_SIZE=0x03
TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_DATA=0x04
TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL=0x05
TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE=0x06
TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAM_DATA_UNI=0x07
TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAMS_BIDI=0x08
TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAMS_UNI=0x09
TLS_HANDSHAKE_QUIC_TP_ACK_DELAY_EXPONENT=0x0a
TLS_HANDSHAKE_QUIC_TP_MAX_ACK_DELAY=0x0b
TLS_HANDSHAKE_QUIC_TP_DISABLE_ACTIVE_MIGRATION=0x0c
TLS_HANDSHAKE_QUIC_TP_PREFERRED_ADDRESS=0x0d
TLS_HANDSHAKE_QUIC_TP_ACTIVE_CONNECTION_ID_LIMIT=0x0e
TLS_HANDSHAKE_QUIC_TP_INITIAL_SOURCE_CONNECTION_ID=0x0f
TLS_HANDSHAKE_QUIC_TP_RETRY_SOURCE_CONNECTION_ID=0x10
TLS_HANDSHAKE_QUIC_TP_VERSION_INFORMATION=0x11 -- https://tools.ietf.org/html/draft-ietf-quic-version-negotiation-14
TLS_HANDSHAKE_QUIC_TP_MAX_DATAGRAM_FRAME_SIZE=0x20 -- https://datatracker.ietf.org/doc/html/draft-ietf-quic-datagram-06
TLS_HANDSHAKE_QUIC_TP_CIBIR_ENCODING=0x1000 -- https://datatracker.ietf.org/doc/html/draft-banks-quic-cibir-01
TLS_HANDSHAKE_QUIC_TP_LOSS_BITS=0x1057 -- https://tools.ietf.org/html/draft-ferrieuxhamchaoui-quic-lossbits-03
TLS_HANDSHAKE_QUIC_TP_GREASE_QUIC_BIT=0x2ab2 -- RFC 9287
TLS_HANDSHAKE_QUIC_TP_ENABLE_TIME_STAMP=0x7157 -- https://tools.ietf.org/html/draft-huitema-quic-ts-02
TLS_HANDSHAKE_QUIC_TP_ENABLE_TIME_STAMP_V2=0x7158 -- https://tools.ietf.org/html/draft-huitema-quic-ts-03
TLS_HANDSHAKE_QUIC_TP_MIN_ACK_DELAY_OLD=0xde1a -- https://tools.ietf.org/html/draft-iyengar-quic-delayed-ack-00
TLS_HANDSHAKE_QUIC_TP_GOOGLE_USER_AGENT=0x3129
TLS_HANDSHAKE_QUIC_TP_GOOGLE_KEY_UPDATE_NOT_YET_SUPPORTED=0x312B
TLS_HANDSHAKE_QUIC_TP_GOOGLE_QUIC_VERSION=0x4752
TLS_HANDSHAKE_QUIC_TP_GOOGLE_INITIAL_RTT=0x3127
TLS_HANDSHAKE_QUIC_TP_GOOGLE_SUPPORT_HANDSHAKE_DONE=0x312A
TLS_HANDSHAKE_QUIC_TP_GOOGLE_QUIC_PARAMS=0x4751
TLS_HANDSHAKE_QUIC_TP_GOOGLE_CONNECTION_OPTIONS=0x3128
TLS_HANDSHAKE_QUIC_TP_FACEBOOK_PARTIAL_RELIABILITY=0xFF00
TLS_HANDSHAKE_QUIC_TP_VERSION_INFORMATION_DRAFT=0xff73db -- https://datatracker.ietf.org/doc/draft-ietf-quic-version-negotiation/13/
TLS_HANDSHAKE_QUIC_TP_ADDRESS_DISCOVERY=0x9f81a176 -- https://tools.ietf.org/html/draft-ietf-quic-address-discovery-00
TLS_HANDSHAKE_QUIC_TP_MIN_ACK_DELAY_DRAFT_V1=0xFF03DE1A -- https://tools.ietf.org/html/draft-ietf-quic-ack-frequency-01
TLS_HANDSHAKE_QUIC_TP_MIN_ACK_DELAY_DRAFT05=0xff04de1a -- https://tools.ietf.org/html/draft-ietf-quic-ack-frequency-04 / draft-05
TLS_HANDSHAKE_QUIC_TP_MIN_ACK_DELAY=0xff04de1b -- https://tools.ietf.org/html/draft-ietf-quic-ack-frequency-07

TLS_HANDSHAKE_QUIC_TP_NAMES = {
 [TLS_HANDSHAKE_QUIC_TP_ORIGINAL_DESTINATION_CONNECTION_ID]="original_destination_connection_id",
 [TLS_HANDSHAKE_QUIC_TP_MAX_IDLE_TIMEOUT]="max_idle_timeout",
 [TLS_HANDSHAKE_QUIC_TP_STATELESS_RESET_TOKEN]="stateless_reset_token",
 [TLS_HANDSHAKE_QUIC_TP_MAX_UDP_PAYLOAD_SIZE]="max_udp_payload_size",
 [TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_DATA]="initial_max_data",
 [TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAM_DATA_BIDI_LOCAL]="initial_max_stream_data_bidi_local",
 [TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAM_DATA_BIDI_REMOTE]="initial_max_stream_data_bidi_remote",
 [TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAM_DATA_UNI]="initial_max_stream_data_uni",
 [TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAMS_UNI]="initial_max_streams_uni",
 [TLS_HANDSHAKE_QUIC_TP_INITIAL_MAX_STREAMS_BIDI]="initial_max_streams_bidi",
 [TLS_HANDSHAKE_QUIC_TP_ACK_DELAY_EXPONENT]="ack_delay_exponent",
 [TLS_HANDSHAKE_QUIC_TP_MAX_ACK_DELAY]="max_ack_delay",
 [TLS_HANDSHAKE_QUIC_TP_DISABLE_ACTIVE_MIGRATION]="disable_active_migration",
 [TLS_HANDSHAKE_QUIC_TP_PREFERRED_ADDRESS]="preferred_address",
 [TLS_HANDSHAKE_QUIC_TP_ACTIVE_CONNECTION_ID_LIMIT]="active_connection_id_limit",
 [TLS_HANDSHAKE_QUIC_TP_INITIAL_SOURCE_CONNECTION_ID]="initial_source_connection_id",
 [TLS_HANDSHAKE_QUIC_TP_RETRY_SOURCE_CONNECTION_ID]="retry_source_connection_id",
 [TLS_HANDSHAKE_QUIC_TP_MAX_DATAGRAM_FRAME_SIZE]="max_datagram_frame_size",
 [TLS_HANDSHAKE_QUIC_TP_CIBIR_ENCODING]="cibir_encoding",
 [TLS_HANDSHAKE_QUIC_TP_LOSS_BITS]="loss_bits",
 [TLS_HANDSHAKE_QUIC_TP_GREASE_QUIC_BIT]="grease_quic_bit",
 [TLS_HANDSHAKE_QUIC_TP_ENABLE_TIME_STAMP]="enable_time_stamp",
 [TLS_HANDSHAKE_QUIC_TP_ENABLE_TIME_STAMP_V2]="enable_time_stamp_v2",
 [TLS_HANDSHAKE_QUIC_TP_VERSION_INFORMATION]="version_information",
 [TLS_HANDSHAKE_QUIC_TP_VERSION_INFORMATION_DRAFT]="version_information_draft",
 [TLS_HANDSHAKE_QUIC_TP_MIN_ACK_DELAY_OLD]="min_ack_delay",
 [TLS_HANDSHAKE_QUIC_TP_GOOGLE_USER_AGENT]="google_user_agent",
 [TLS_HANDSHAKE_QUIC_TP_GOOGLE_KEY_UPDATE_NOT_YET_SUPPORTED]="google_key_update_not_yet_supported",
 [TLS_HANDSHAKE_QUIC_TP_GOOGLE_QUIC_VERSION]="google_quic_version",
 [TLS_HANDSHAKE_QUIC_TP_GOOGLE_INITIAL_RTT]="google_initial_rtt",
 [TLS_HANDSHAKE_QUIC_TP_GOOGLE_SUPPORT_HANDSHAKE_DONE]="google_support_handshake_done",
 [TLS_HANDSHAKE_QUIC_TP_GOOGLE_QUIC_PARAMS]="google_quic_params",
 [TLS_HANDSHAKE_QUIC_TP_GOOGLE_CONNECTION_OPTIONS]="google_connection_options",
 [TLS_HANDSHAKE_QUIC_TP_FACEBOOK_PARTIAL_RELIABILITY]="facebook_partial_reliability",
 [TLS_HANDSHAKE_QUIC_TP_ADDRESS_DISCOVERY]="address_discovery",
 [TLS_HANDSHAKE_QUIC_TP_MIN_ACK_DELAY_DRAFT_V1]="min_ack_delay (draft-01)",
 [TLS_HANDSHAKE_QUIC_TP_MIN_ACK_DELAY_DRAFT05]="min_ack_delay (draft-05)",
 [TLS_HANDSHAKE_QUIC_TP_MIN_ACK_DELAY]="min_ack_delay"
}


-- tls record length without header
function tls_record_data_len(tls, offset)
	if not offset then offset=1 end
	return u16(tls, offset+3)
end
-- true if tls has enough data to store the whole tls record
function tls_record_full(tls, offset)
	if not offset then offset=1 end
	return tls_record_data_len(tls, offset) <= (#tls-offset+1-5)
end
function tls_record_type(tls, offset)
	if not offset then offset=1 end
	return u8(tls, offset)
end
function is_tls_record(tls, offset, ctype, partialOK)
	if not tls then return false end
	if not offset then offset=1 end

	if (#tls-offset+1)<5 or (ctype and ctype~=tls_record_type(tls, offset)) then return false end
	local f2 = u16(tls, offset+1)
	return f2>=TLS_VER_SSL30 and f2<=TLS_VER_TLS12 and (partialOK or tls_record_full(tls, offset))

end
-- tls handshake record length without header
function tls_handshake_data_len(tls, offset)
	if not offset then offset=1 end
	return u24(tls, offset+1)
end
-- tls handshake record length with header
function tls_handshake_len(tls, offset)
	return tls_handshake_data_len(tls, offset) + 4
end
-- true if tls has enough data to store the whole handshake
function tls_handshake_full(tls, offset)
	if not offset then offset=1 end
	return tls_handshake_data_len(tls, offset) <= (#tls-offset+1-4)
end
function tls_handshake_type(tls, offset)
	return u8(tls,offset)
end
function is_tls_handshake_type_hello(tls, offset)
	if not tls then return false end
	local typ = tls_handshake_type(tls, offset)
	return typ == TLS_HANDSHAKE_TYPE_CLIENT or typ == TLS_HANDSHAKE_TYPE_SERVER
end
function is_tls_handshake(tls, offset, htype, partialOK)
	if not tls then return false end
	if not offset then offset=1 end

	if (#tls-offset+1)<4 then return false end
	local typ = tls_handshake_type(tls,offset)
	-- requested handshake type
	if htype and htype~=typ then return false end
	-- valid handshake type
	if not TLS_HANDSHAKE_TYPE_NAMES[typ] then return false end
	if typ==TLS_HANDSHAKE_TYPE_CLIENT or typ==TLS_HANDSHAKE_TYPE_SERVER then
		-- valid tls versions
		if (#tls-offset+1)<6 then return false end
		local f2 = u16(tls,offset+4)
		if f2<TLS_VER_SSL30 or f2>TLS_VER_TLS12 then return false end
	end
	-- length fits to data buffer
	return partialOK or tls_handshake_full(tls, offset)
end
function is_tls_hello(tls, offset, partialOK)
	return is_tls_handshake(tls, offset, TLS_HANDSHAKE_TYPE_CLIENT, partialOK) or is_tls_handshake(tls, offset, TLS_HANDSHAKE_TYPE_SERVER, partialOK)
end
-- quic-style tvb parse
function quic_tvb(data, offset)
	if not offset then offset=1 end
	if offset>#data then return end
	local size = bitrshift(u8(data,offset), 6)
	if size==0 then
		return u8(data,offset), 1
	elseif size==1 then
		if (offset+1)>#data then return end
		return bitand(u16(data,offset),0x3FFF), 2
	elseif size==2 then
		if (offset+3)>#data then return end
		return bitand(u32(data,offset),0x3FFFFFFF), 4
	elseif size==3 then
		if (offset+7)>#data then return end
		-- only lua 5.3+ can handle this. others can't store 64-bit integers
		return bitand(u32(data,offset),0x3FFFFFFF) * 0x100000000 + u32(data,offset+4), 8
	end
end
-- quic-style tvb reconstruct
function bquic_tvb(v)
	if v<0x40 then
		return bu8(v)
	elseif v<0x4000 then
		return bu16(v + 0x4000)
	elseif v<0x40000000 then
		return bu32(v + 0x80000000)
	elseif v<0x4000000000000000 then
		-- only lua 5.3+ can handle 64-bit int !
		return bu32(divint(v, 0x100000000) + 0xC0000000) .. bu32(v % 0x100000000)
	end
end


-- dissect tls extension
-- create dis tables inside ext for supported exts. leave 'data' as is for unsupported exts
function tls_dissect_ext(ext)
	local function len16_header()
		local left, len, off
		left = #ext.data
		if left<2 then return end
		len = u16(ext.data)
		left = left - 2
		off = 3
		if len>left then
			return
		else
			left = len
		end
		return left, off
	end
	local function len8_header()
		local left, len, off
		left = #ext.data
		if left<1 then return end
		len = u8(ext.data)
		left = left - 1
		off = 2
		if len>left then
			return
		else
			left = len
		end
		return left, off
	end

	local dis={}
	local off, len, left

	ext.dis = nil

	if ext.type==TLS_EXT_SERVER_NAME then
		left, off = len16_header()
		if not left then return end
		dis.list = {}
		while left>=3 do
			len = u16(ext.data, off+1)
			if (len+3)>left then return end
			dis.list[#dis.list+1] = { type = u8(ext.data, off), name = string.sub(ext.data, off+3, off+3+len-1) }
			left = left - 3 - len
			off = off + 3 + len
		end
	elseif ext.type==TLS_EXT_ALPN then
		left, off = len16_header()
		if not left then return end
		dis.list = {}
		while left>=1 do
			len = u8(ext.data, off)
			if (len+1)>left then return end
			dis.list[#dis.list+1] = string.sub(ext.data, off+1, off+1+len-1)
			left = left - 1 - len
			off = off + 1 + len
		end
	elseif ext.type==TLS_EXT_SUPPORTED_VERSIONS or ext.type==TLS_EXT_COMPRESS_CERTIFICATE then
		left, off = len8_header()
		if not left then return end
		dis.list = {}
		for i=1,left/2 do
			dis.list[#dis.list+1] = u16(ext.data,off)
			left = left - 2
			off = off + 2
		end
	elseif ext.type==TLS_EXT_SIGNATURE_ALGORITHMS or ext.type==TLS_EXT_DELEGATED_CREDENTIALS or ext.type==TLS_EXT_SUPPORTED_GROUPS then
		left, off = len16_header()
		if not left then return end
		dis.list = {}
		for i=1,left/2 do
			dis.list[#dis.list+1] = u16(ext.data,off)
			left = left - 2
			off = off + 2
		end
	elseif ext.type==TLS_EXT_EC_POINT_FORMATS or ext.type==TLS_EXT_PSK_KEY_EXCHANGE_MODES then
		left, off = len8_header()
		if not left then return end
		dis.list = {}
		for i=1,left do
			dis.list[#dis.list+1] = u8(ext.data,off)
			left = left - 1
			off = off + 1
		end
	elseif ext.type==TLS_EXT_KEY_SHARE then
		left, off = len16_header()
		if not left then return end
		dis.list = {}
		while left>=4 do
			len = u16(ext.data, off + 2)
			if (len+4)>left then return end
			dis.list[#dis.list+1] = { group = u16(ext.data, off) , kex = string.sub(ext.data, off+4, off+4+len-1) }
			left = left - 4 - len
			off = off + 4 + len
		end
	elseif ext.type==TLS_EXT_QUIC_TRANSPORT_PARAMETERS then
		left, off = len16_header()
		if not left then return end
		dis.list = {}
		while left>=4 do
			len = u16(ext.data, off + 2)
			if (len+4)>left then return end
			local typ = u16(ext.data, off)
			dis.list[#dis.list+1] = { type = typ, name = TLS_HANDSHAKE_QUIC_TP_NAMES[typ], data = string.sub(ext.data, off+4, off+4+len-1) }
			left = left - 4 - len
			off = off + 4 + len
		end
	elseif ext.type==TLS_EXT_QUIC_TRANSPORT_PARAMETERS_V1 then
		left, off = #ext.data, 1
		dis.list = {}
		local typ, size
		while left>=2 do
			typ, size = quic_tvb(ext.data, off)
			if not typ then return end
			off = off + size
			left = left - size
			len, size = quic_tvb(ext.data, off)
			if not len then return end
			off = off + size
			left = left - size
			if len > left then return end
			dis.list[#dis.list+1] = { type = typ, name = TLS_HANDSHAKE_QUIC_TP_NAMES[typ], data = string.sub(ext.data, off, off+len-1) }
			left = left - len
			off = off + len
		end
	else
		dis = nil
	end

	ext.dis = dis
end

-- dissect client/server hello. leave 'data' as is for others
function tls_dissect_handshake(handshake, partialOK)
	if is_tls_hello(handshake.data, 1, partialOK) then
		local hlen = tls_handshake_len(handshake.data, 1)
		if hlen > #handshake.data then
			if not partialOK then return false end
			hlen = #handshake.data
		end
		local typ = tls_handshake_type(handshake.data, 1)
		handshake.dis = { type = typ , ver = u16(handshake.data, 5), name = tostring(TLS_HANDSHAKE_TYPE_NAMES[typ]) }

		-- random
		if hlen<38 then return partialOK end
		handshake.dis.random = string.sub(handshake.data, 7, 38)

		-- session_id
		if hlen<39 then return partialOK end
		local len = u8(handshake.data, 39)
		local left = hlen-39-len
		if left<0 then return partialOK end
		handshake.dis.session_id = string.sub(handshake.data, 40, 40+len-1)
		local off = 40+len

		-- cipher suite(s)
		if left<2 then return partialOK end
		if handshake.dis.type==TLS_HANDSHAKE_TYPE_CLIENT then
			-- client hello - array
			len = u16(handshake.data, off)
			if left<(2+len) then return partialOK end
			handshake.dis.cipher_suites={}
			for i=1,(len/2) do
				handshake.dis.cipher_suites[i] = u16(handshake.data, off + i*2)
			end
			off = off + 2 + len
			left = left - 2 - len
		else
			-- server hello - single
			handshake.dis.cipher_suite = u16(handshake.data, off)
			off = off + 2
			left = left - 2
		end

		-- compression method(s)
		if left<1 then return partialOK end
		if handshake.dis.type==1 then
			-- client hello - array
			len = u8(handshake.data, off)
			if left<(1+len) then return partialOK end
			handshake.dis.compression_methods={}
			for i=1,len do
				handshake.dis.compression_methods[i] = u8(handshake.data, off + i)
			end
			off = off + 1 + len
			left = left - 1 - len
		else
			-- server hello - single
			handshake.dis.compression_method = u8(handshake.data, off)
			off = off + 1
			left = left - 1
		end

		-- tls extensions
		if left<2 then return partialOK end
		local extlen = u16(handshake.data, off)
		if left<(2+extlen) and not partialOK then return end
		off = off + 2
		left = left - 2
		if left>extlen then left=extlen end

		handshake.dis.ext = {}
		while left>=4 do
			len = u16(handshake.data, off + 2)
			if len>(left-4) then
				if partialOK then
					break
				else
					return
				end
			end
			local typ = u16(handshake.data, off)
			handshake.dis.ext[#handshake.dis.ext+1] = { type = typ, name = tostring(TLS_HELLO_EXT_NAMES[typ]), data = string.sub(handshake.data, off+4, off+4+len-1) }
			tls_dissect_ext(handshake.dis.ext[#handshake.dis.ext])
			left = left - 4 - len
			off = off + 4 + len
		end

		return true
	end
	return false
end

-- convert tls blob tls dissect
-- auto detects record layer. can work with pure handshake message
function tls_dissect(tls, offset, partialOK)
	if not offset then offset=1 end

	local tdis = {}
	local off = offset
	local encrypted = false
	while is_tls_record(tls, off, nil, partialOK) do
		if not tdis.rec then tdis.rec = {} end
		local len = tls_record_data_len(tls, off)
		local typ = tls_record_type(tls, off)
		tdis.rec[#tdis.rec+1] = { type = typ, name = tostring(TLS_RECORD_TYPE_NAMES[typ]), len = len, ver = u16(tls, off+1), encrypted = encrypted, data = string.sub(tls, off+5, off+5+len-1) }
		if typ==TLS_RECORD_TYPE_CHANGE_CIPHER_SPEC then
			encrypted = true
		elseif typ==TLS_RECORD_TYPE_HANDSHAKE and not encrypted then
			-- need 4 bytes for handshake type and 24-bit length
			if (#tls-off+1)<9 then
				if not partialOK then return end
				break
			end
			local htyp = tls_handshake_type(tls, off + 5)
			tdis.rec[#tdis.rec].htype = htyp
			if not tdis.handshake then tdis.handshake = {} end
			local hlen = tls_handshake_len(tls, off + 5)
			tdis.handshake[htyp] = { type = htyp, name = TLS_HANDSHAKE_TYPE_NAMES[htyp], data = "" }
			-- reasm handshake if required
			while true do
				tdis.handshake[htyp].data = tdis.handshake[htyp].data .. string.sub(tls, off + 5, off + 5 + len - 1)
				if #tdis.handshake[htyp].data >= hlen then
					-- reasm complete
					break
				end
				-- next record
				if not is_tls_record(tls, off + 5 + len, nil, partialOK) or tls_record_type(tls, off + 5 + len) ~= typ then
					if not partialOK then return end
					goto endrec
				end
				off = off + 5 + len
				len = tls_record_data_len(tls, off)
				tdis.rec[#tdis.rec+1] = { type = typ, htype = htyp, len=len, ver = u16(tls, off+1), encrypted = false, not_first = true, name = tostring(TLS_RECORD_TYPE_NAMES[typ]), data = string.sub(tls, off+5, off+5+len-1) }
			end
		end
		-- next record
		off = off + 5 + len
	end
::endrec::

	if tdis.handshake then
		for htyp, handshake in pairs(tdis.handshake) do
			if (handshake.type == TLS_HANDSHAKE_TYPE_CLIENT or handshake.type == TLS_HANDSHAKE_TYPE_SERVER) then
				tls_dissect_handshake(handshake, partialOK)
			end
		end
	elseif not tdis.rec and is_tls_handshake(tls, offset, nil, partialOK) then
		local htyp = tls_handshake_type(tls, offset)
		tdis.handshake = { [htyp] = { type = htyp, name = TLS_HANDSHAKE_TYPE_NAMES[htyp], data = string.sub(tls, offset, #tls) } }
		tls_dissect_handshake(tdis.handshake[htyp], partialOK)
	end

	return (tdis.rec or tdis.handshake) and tdis or nil
end


-- reconstruct tls extension dissects
-- unsupported ext types must have their 'data' filled
function tls_reconstruct_ext(ext)
	if ext.dis then
		if ext.type==TLS_EXT_SERVER_NAME then
			ext.data = barray(ext.dis.list, function(a) return bu8(a.type or 0) .. bu16(#a.name) .. a.name end)
			ext.data = bu16(#ext.data) .. ext.data
		elseif ext.type==TLS_EXT_ALPN then
			ext.data = barray(ext.dis.list, function(a) return bu8(#a) .. a end)
			ext.data = bu16(#ext.data) .. ext.data
		elseif ext.type==TLS_EXT_SUPPORTED_VERSIONS or ext.type==TLS_EXT_COMPRESS_CERTIFICATE then
			ext.data = barray(ext.dis.list, bu16)
			ext.data = bu8(#ext.data) .. ext.data
		elseif ext.type==TLS_EXT_SIGNATURE_ALGORITHMS or ext.type==TLS_EXT_DELEGATED_CREDENTIALS or ext.type==TLS_EXT_SUPPORTED_GROUPS then
			ext.data = barray(ext.dis.list, bu16)
			ext.data = bu16(#ext.data) .. ext.data
		elseif ext.type==TLS_EXT_EC_POINT_FORMATS or ext.type==TLS_EXT_PSK_KEY_EXCHANGE_MODES then
			ext.data = barray(ext.dis.list, bu8)
			ext.data = bu8(#ext.data) .. ext.data
		elseif ext.type==TLS_EXT_KEY_SHARE then
			ext.data = barray(ext.dis.list, function(a) return bu16(a.group) .. bu16(#a.kex) .. a.kex end)
			ext.data = bu16(#ext.data) .. ext.data
		elseif ext.type==TLS_EXT_QUIC_TRANSPORT_PARAMETERS then
			ext.data = barray(ext.dis.list, function(a) return bu16(a.type) .. bu16(#a.data) .. a.data end)
			ext.data = bu16(#ext.data) .. ext.data
		elseif ext.type==TLS_EXT_QUIC_TRANSPORT_PARAMETERS_V1 then
			ext.data = barray(ext.dis.list, function(a) return bquic_tvb(a.type) .. bquic_tvb(#a.data) .. a.data end)
		else
			ext.data=nil
		end
	end

	return type(ext.data)=="string"
end

-- reconstruct handshake dissect to raw string
-- deeper dissects are supported for client/server hello, others must have 'data' field
function tls_reconstruct_handshake(handshake)
	if handshake.dis then
		if handshake.dis.type == TLS_HANDSHAKE_TYPE_CLIENT or handshake.dis.type == TLS_HANDSHAKE_TYPE_SERVER then
			handshake.data = nil
			local header =
				bu16(handshake.dis.ver or TLS_VER_TLS12) ..
				((handshake.dis.random and #handshake.dis.random==32) and handshake.dis.random or brandom(32)) ..
				bu8(handshake.dis.session_id and #handshake.dis.session_id or 0) ..
				(handshake.dis.session_id or "")
			if handshake.dis.type == TLS_HANDSHAKE_TYPE_CLIENT then
				header = header ..
					bu16(handshake.dis.cipher_suites and 2*#handshake.dis.cipher_suites or 0) ..
					(handshake.dis.cipher_suites and barray(handshake.dis.cipher_suites, bu16) or "") ..
					bu8(handshake.dis.compression_methods and #handshake.dis.compression_methods or 0) ..
					(handshake.dis.compression_methods and barray(handshake.dis.compression_methods, bu8) or "")
			else
				header = header ..
					bu16(handshake.dis.cipher_suite) ..
					bu8(handshake.dis.compression_method)
			end
			local exts=""
			if handshake.dis.ext then
				for i=1,#handshake.dis.ext do
					if not tls_reconstruct_ext(handshake.dis.ext[i]) then
						return nil
					end
					exts = exts .. bu16(handshake.dis.ext[i].type) .. bu16(#handshake.dis.ext[i].data) .. handshake.dis.ext[i].data
				end
				handshake.data = bu8(handshake.type) .. bu24(#header + 2 + #exts) .. header .. bu16(#exts) .. exts
			else
				handshake.data = bu8(handshake.type) .. bu24(#header) .. header
			end
		end
	end

	return type(handshake.data)=="string"
end

-- recconstruct tls dissect to raw tls
-- supports tls records with optional handshake dissects
-- supports single handshake without tls records
function tls_reconstruct(tdis)
	if tdis.handshake then
		for htyp, handshake in pairs(tdis.handshake) do
			if not tls_reconstruct_handshake(handshake) then return nil end
		end
	end

	local tls
	if tdis.rec then
		-- need to follow in order
		local i=1
		while i <= #tdis.rec do
			local rec = tdis.rec[i]
			if rec.type==TLS_RECORD_TYPE_HANDSHAKE and not rec.encrypted and rec.htype and tdis.handshake and tdis.handshake[rec.htype] and tdis.handshake[rec.htype].data then
				rec.data = nil

				local data = tdis.handshake[rec.htype].data
				local htyp = rec.htype
				local j = i + 1
				while j <= #tdis.rec and tdis.rec[j].type==TLS_RECORD_TYPE_HANDSHAKE and not tdis.rec[j].encrypted and tdis.rec[j].htype == htyp do
					j = j + 1
				end
				j = j - 1
				local off = 1
				for k=i,j do
					local chunk_size = #data-off+1
					-- last chunk takes all remaining data
					if k~=j then
						chunk_size = (chunk_size < tdis.rec[k].len) and chunk_size or tdis.rec[k].len
					end
					tdis.rec[k].data = string.sub(data, off, off + chunk_size - 1)
					tdis.rec[k].len = chunk_size
					off = off + chunk_size
				end
				i = j + 1
			else
				i = i + 1
			end
			if not rec.data then return nil end
		end
		tls = barray(tdis.rec, function(a) return (#a.data > 0) and (bu8(a.type) .. bu16(a.ver) .. bu16(#a.data) .. a.data) or "" end)
	elseif tdis.handshake then
		local i = next(tdis.handshake)
		if i~=nil then
			tls = tdis.handshake[i].data
		end
	end

	return tls
end
