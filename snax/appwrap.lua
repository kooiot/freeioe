local skynet = require 'skynet'
local snax = require 'skynet.snax'
local cache = require "skynet.codecache"
local app_sys = require 'app.sys'
local event = require 'app.event'
local log = require 'utils.log'

local app = nil
local app_name = "UNKNOWN"
local mgr_snax = nil
local sys_api = nil
local sys_id = nil

local cancel_ping_timer = nil
local cancel_ping_timeout = 5000 -- ms

local function protect_call(app, func, ...)
	assert(app and func)
	local f = app[func]
	if not f then
		return nil, "App has no function "..func
	end

	local r, er, err = xpcall(f, debug.traceback, app, ...)
	if not r then
		return nil, er
	end
	return er, err
end

local on_close = function(...)
	if app then
		local r, err = protect_call(app, 'close', ...)
		if not r and err then
			return nil, err
		end
	end
	if sys_api then
		sys_api:cleanup()
	end
	sys_api = nil
	app = nil
	app_name = "UNKNOWN"
	return true
end

local function work_proc()
	local timeout = 1000
	while app do
		skynet.sleep(timeout / 10)

		local t, err = protect_call(app, 'run', timeout)
		if t then
			timeout = t
		else
			if err then
				log.warning(err)
				timeout = 1000 * 60
			end
		end
	end
end

function response.ping()
	return "Pong "..app_name
end

function response.start()
	if app then
		local r, err = protect_call(app, 'start')
		if not r then
			return nil, err
		end

		if app.run then
			skynet.timeout(10, work_proc)
		end

		local ping_mgr = nil
		ping_mgr = function()
			mgr_snax.post.app_heartbeat(app_name, skynet.time())
			cancel_ping_timer = app_sys:cancelable_timeout(cancel_ping_timeout, ping_mgr)
		end
		cancel_ping_timer = app_sys:cancelable_timeout(cancel_ping_timeout, ping_mgr)

		return true
	else
		return nil, "app is nil"
	end
end

function response.stop(...)
	return on_close(...)
end

function response.set_conf(conf)
	if not app then
		return nil, "app is nil"
	end
	sys_api:set_conf(conf)	
	if app.reload then
		return protect_call(app, 'reload', conf)
	end
	return mgr_snax.req.restart(app_name, "Confiruation change restart")
end

function response.app_req(msg, ...)
	if not app then
		return nil, "app is nil"
	end
	if app.response then
		return protect_call(app, 'response', msg, ...)
	else
		local msg = 'on_req_'..msg
		if app[msg] then
			return protect_call(app, msg, ...)
		end
	end
	return nil, "no handler for request message "..msg
end

function accept.app_post(msg, ...)
	if not app then
		return nil, "app is nil"
	end
	if app.accept then
		return protect_call(app, 'accept', msg, ...)
	else
		local msg = 'on_post_'..msg
		if app[msg] then
			return protect_call(app, msg, ...)
		end
	end
	return nil, "no handler for post message "..msg
end

function fire_exception_event(info, data)
	if not mgr_snax then
		return
	end
	local data = data or {}
	data.app = app_name

	local type_ = event.type_to_string(event.EVENT_APP)
	return mgr_snax.post.fire_event(app_name, sys_id, event.LEVEL_ERROR, event.EVENT_APP, info, data)
end

function init(name, conf, mgr_handle, mgr_type)
	-- Disable Skynet Code Cache!!
	cache.mode('EXIST')

	app_name = name
	mgr_snax = snax.bind(mgr_handle, mgr_type)
	sys_api = app_sys:new(app_name, mgr_snax, snax.self())
	sys_id = sys_api:id()

	log.info("App "..app_name.." starting")
	package.path = package.path..";./ioe/apps/"..name.."/?.lua;./ioe/apps/"..name.."/?.luac"..";./ioe/apps/"..name.."/lualib/?.lua;./ioe/apps/"..name.."/lualib/?.luac"
	package.cpath = package.cpath..";./ioe/apps/"..name.."/luaclib/?.so"
	--local r, m = pcall(require, "app")
	local f, err = io.open("./ioe/apps/"..name.."/app.lua", "r")
	if not f then
		log.warning("Application does not exits!, Try to install it")	
		skynet.call("UPGRADER", "lua", "install_missing_app", name)
		return nil, "App does not exits!"
	end
	f:close()

	local r, err = skynet.call("IOE_EXT", "lua", "install_depends", name)
	if not r then
		log.error("Failed to install depends for ", name, "error:", err)
		local info = "Failed to start app. install depends failed"
		fire_exception_event(info, {ext=name, err=err})
		return nil, info
	end

	local lf, err = loadfile("./ioe/apps/"..name.."/app.lua")
	if not lf then
		local info = "Loading app failed."
		log.error(info, err)
		fire_exception_event(info, {err=err})
		return nil, err
	end
	local r, m = xpcall(lf, debug.traceback)
	if not r then
		local info = "Loading app failed."
		log.error(info, m)
		fire_exception_event(err, {err=m})
		return nil, m
	end

	if m.API_VER and m.API_VER < app_sys.API_MIN_VER then
		local s = string.format("API Version required is too old. Required: %d. Current %d-%d",
								m.API_VER, sys_api.API_MIN_VER, sys_api.API_VER)
		log.error(s)
		fire_exception_event(s)
		return nil, s
	else
		if not m.API_VER then
			log.warning("API Version is not specified, please use it only for development")
		end
	end

	r, err = xpcall(m.new, debug.traceback, m, app_name, sys_api, conf)
	if not r then
		log.error("Create App instance failed.", err)
		fire_exception_event("Create App instance failed.", {err=err})
		return nil, err
	end
	app = err
end

function exit(...)
	log.info("App "..app_name.." closed.")
	if cancel_ping_timer then
		cancel_ping_timer()
		cancel_ping_timer = nil
	end
	local r, err = on_close(...)
	if not r then
		log.error(err)
		fire_exception_event("App closed failure.", {err=err})
	end
end
