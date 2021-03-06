local class = require 'middleclass'
local sysinfo = require 'utils.sysinfo'
local gcom = require 'utils.gcom'
local datacenter = require 'skynet.datacenter'
local event = require 'app.event'
local disk = require 'disk'

local app = class("FREEIOE_SYS_APP_CLASS")
app.API_VER = 1

function app:initialize(name, sys, conf)
	self._name = name
	self._sys = sys
	self._conf = conf or {}
	self._api = self._sys:data_api()
	self._log = sys:logger()
	self._cancel_timers = {}
end

function app:start()
	self._api:set_handler({
		on_output = function(app, sn, output, prop, value)
			print('on_output', app, sn, output, prop, value)
			return true, "done"
		end,
		on_command = function(app, sn, command, param)
			print('on_command', app, sn, command, param)
			return true, "eee"
		end,
		on_ctrl = function(app, command, param, ...)
			print('on_ctrl', app, command, param, ...)
		end,
	})

	local sys_id = self._sys:id()
	local inputs = {
		{
			name = 'cpuload',
			desc = 'System CPU Load'
		},
		{
			name = 'cpu_temp',
			desc = 'System CPU Temperature'
		},
		{
			name = 'mem_total',
			desc = 'System memory total size',
		},
		{
			name = 'mem_used',
			desc = 'System memory used size',
		},
		{
			name = 'mem_free',
			desc = 'System memory free size',
		},
		{
			name = "uptime",
			desc = "System uptime",
			vt = "int",
		},
		{
			name = "starttime",
			desc = "System start time in UTC",
			vt = "int",
		},
		{
			name = "version",
			desc = "System Version",
			vt = "int",
		},
		{
			name = "skynet_version",
			desc = "Skynet Platform Version",
			vt = "int",
		},
		{
			name = "platform",
			desc = "Skynet Platform type",
			vt = "string",
		},
		{
			name = "data_upload",
			desc = "Upload data to cloud",
			vt = "int",
		},
		{
			name = "stat_upload",
			desc = "Upload statictis data to cloud",
			vt = "int",
		},
		{
			name = "comm_upload",
			desc = "Upload communication data to cloud",
			vt = "int",
		},
		{
			name = "log_upload",
			desc = "Upload logs to cloud",
			vt = "int",
		},
		{
			name = "enable_beta",
			desc = "Device using beta enable flag",
			vt = "int",
		},
		{
			name = 'disk_tmp_used',
			desc = "Disk /tmp used percent",
		}
	}
	if string.sub(sys_id, 1, 8) == '2-30002-' then
		self._gcom = true
		local gcom_inputs = {
			{
				name = 'ccid',
				desc = 'SIM card ID',
				vt = "string",
			},
			{
				name = 'csq',
				desc = 'GPRS/LTE sginal strength',
				vt = "int",
			},
			{
				name = 'cpsi',
				desc = 'GPRS/LTE work mode and so on',
				vt = "string",
			}
		}

		for _,v in ipairs(gcom_inputs) do
			inputs[#inputs + 1] = v
		end
	end

	local meta = self._api:default_meta()
	meta.name = "BambooShoots IOE"
	meta.description = "BambooShoots IOE Device"
	meta.series = "Q102" -- TODO:
	self._dev = self._api:add_device(sys_id, meta, inputs)

	return true
end

function app:close(reason)
	--print(self._name, reason)
	for name, cancel_timer in pairs(self._cancel_timers) do
		cancel_timer()
	end
	self._cancel_timers = {}
end

function app:run(tms)
	if not self._start_time then
		self._start_time = self._sys:start_time()
		local v, gv = sysinfo.version()
		self._log:notice("System Version:", v, gv)
		local sv, sgv = sysinfo.skynet_version()
		self._log:notice("Skynet Platform Version:", sv, sgv)
		local plat = sysinfo.platform() or "unknown"

		self._dev:set_input_prop('starttime', "value", self._start_time)
		self._dev:set_input_prop('version', "value", v)
		self._dev:set_input_prop('version', "git_version", gv)
		self._dev:set_input_prop('skynet_version', "value", sv)
		self._dev:set_input_prop('skynet_version', "git_version", sgv)
		self._dev:set_input_prop('platform', "value", plat)


		--- Calculate uptime for earch 60 seconds
		local calc_tmp_disk = nil
		local tmp_disk_frep = self._conf.tmp_disk_frep or (1000 * 60)
		calc_tmp_disk = function()
			self._dev:set_input_prop('uptime', "value", self._sys:now())

			-- temp disk usage
			local r, err = disk.df('/tmp')
			if r then
				self._dev:set_input_prop('disk_tmp_used', 'value', r.used_percent)

				-- Check used percent limitation
				if not self._tmp_event_fired and r.used_percent > 98 then
					local info = "/tmp disk is nearly full!!!"
					self._log:error(info)
					self._dev:fire_event(event.LEVEL_ERROR, event.EVENT_SYS, info, r)
					self._tmp_event_fired = true
				end
			end

			-- Reset timer
			self._cancel_timers['tmp_disk'] = self._sys:cancelable_timeout(tmp_disk_frep, calc_tmp_disk)
		end
		calc_tmp_disk()

		if self._gcom then
			local calc_gcom = nil
			local gcom_frep = self._conf.gcom_frep or (1000 * 60 * 5)
			calc_gcom = function()
				local ccid, err = gcom.get_ccid()
				if ccid then
					self._dev:set_input_prop('ccid', "value", ccid)
				end
				local csq, err = gcom.get_csq()
				if csq then
					self._dev:set_input_prop('csq', "value", tonumber(csq))
				end
				local cpsi, err = gcom.get_cpsi()
				if cpsi then
					self._dev:set_input_prop('cpsi', "value", cpsi)
				end

				-- Reset timer
				self._cancel_timers['gcom'] = self._sys:cancelable_timeout(gcom_frep, calc_gcom)
			end
			calc_gcom()
		end

		--[[
		self._sys:timeout(100, function()
			self._log:debug("Fire event")
			local sys_id = self._sys:id()
			self._dev:fire_event(event.LEVEL_INFO, event.EVENT_SYS, "System Started!", {sn=sys_id})
		end)
		]]--
	end

	local loadavg = sysinfo.loadavg()
	self._dev:set_input_prop('cpuload', "value", tonumber(loadavg.lavg_15))
	local cpu_temp = sysinfo.cpu_temperature()
	if cpu_temp then
		self._dev:set_input_prop('cpu_temp', "value", tonumber(cpu_temp))
	end

	local mem = sysinfo.meminfo()
	self._dev:set_input_prop('mem_total', 'value', tonumber(mem.total))
	self._dev:set_input_prop('mem_used', 'value', tonumber(mem.used))
	self._dev:set_input_prop('mem_free', 'value', tonumber(mem.free))
	
	-- cloud flags
	--
	local enable_data_upload = datacenter.get("CLOUD", "DATA_UPLOAD")
	local enable_stat_upload = datacenter.get("CLOUD", "STAT_UPLOAD")
	local enable_comm_upload = datacenter.get("CLOUD", "COMM_UPLOAD")
	local enable_log_upload = datacenter.get("CLOUD", "LOG_UPLOAD")
	local enable_beta = datacenter.get('CLOUD', 'USING_BETA')

	self._dev:set_input_prop('data_upload', 'value', enable_data_upload and 1 or 0)
	self._dev:set_input_prop('stat_upload', 'value', enable_stat_upload  and 1 or 0)
	self._dev:set_input_prop('comm_upload', 'value', enable_comm_upload or 0)
	self._dev:set_input_prop('log_upload', 'value', enable_log_upload or 0)
	self._dev:set_input_prop('enable_beta', 'value', enable_beta and 1 or 0)

	if math.abs(os.time() - self._sys:time()) > 2 then
		self._log:error("Time diff found, system will be rebooted in five seconds. ", os.time(), self._sys:time())
		self._dev:fire_event(event.LEVEL_FATAL, event.EVENT_SYS, "Time diff found!", {os_time = os.time(), time=self._sys:time()}, os.time())
		self._sys:timeout(500, function()
			self._sys:abort()
		end)
	else
		--print(os.time() - self._sys:time())
	end

	return 1000 * 5
end

return app
