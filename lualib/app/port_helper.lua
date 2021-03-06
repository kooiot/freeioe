
local _M = {}

---
-- Read specified length data from socket
-- @tparam sock TCP socket channel object
-- @tparam len Required length
-- @tparam dump Stream dump function. e.g. function(str) print(str) end
function _M.read_socket(sock, len, dump)
	local log = require 'utils.log'
	log.trace('Start reading from socket stream. required len:', len)

	local str, err = sock:read(len)
	if not str then
		return nil, err
	end

	if dump then
		dump(str)
	end

	if string.len(str) >= len then
		return str
	end

	return nil, "The length of socket data is less than "..len
end

---
-- Read specified length data from serial 
-- @tparam serial Serial port channel object
-- @tparam len Required length
-- @tparam dump Stream dump function. e.g. function(str) print(str) end
-- @tparam timeout Reading timeout in ms. Default is 3000 ms
function _M.read_serial(serial, len, dump, timeout)
	local log = require 'utils.log'
	log.trace('Start reading from serial port. required len:', len)

	local str, err = serial:read(len, timeout)
	if not str or string.len(str) == 0 then
		return false, err or 'Serial read timeout'
	end

	if dump then
		dump(str)
	end

	if string.len(str) >= len then
		return str
	end

	return nil, "The length of serial data is less than "..len
end

return _M
