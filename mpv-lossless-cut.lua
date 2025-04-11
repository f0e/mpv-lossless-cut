mp.msg = require("mp.msg")
mp.utils = require("mp.utils")
mp.options = require("mp.options")

local options = {
	lossless = true,
	output_dir = ".",
	multi_cut_mode = "separate",
}

mp.options.read_options(options, "mpv-lossless-cut")

local cuts = {}
local os_name = package.config:sub(1, 1) == "\\" and "windows"
	or (io.popen("uname"):read("*a"):match("Darwin") and "mac" or "linux")

-- utility functions
local function log(message)
	mp.msg.info(message)
	mp.osd_message(message)
end

local function sanitize_filename(filename)
	local sanitized = filename:gsub('[\\/:*?"<>|]', "_")

	-- leading and trailing whitespace
	sanitized = sanitized:gsub("^%s*(.-)%s*$", "%1")

	return sanitized
end

local function ffmpeg_escape_filepath(path)
	if os_name == "windows" then
		return path:gsub("/", "\\"):gsub("\\", "\\\\"):gsub('"', '\\"')
	else
		return path:gsub("\\", "/"):gsub("'", "'\\''")
	end
end

local function to_hms(secs)
	local hours = math.floor(secs / 3600)
	local minutes = math.floor((secs % 3600) / 60)
	local remaining_seconds = ((secs % 3600) % 60)

	local str = {}
	if hours > 0 then
		table.insert(str, hours .. "h")
	end
	if minutes > 0 then
		table.insert(str, minutes .. "m")
	end
	if remaining_seconds > 0 then
		table.insert(str, string.format("%.1fs", remaining_seconds))
	end

	return #str == 0 and "0" or table.concat(str, "")
end

-- file operations
local function ensure_directory_exists(dir)
	local dir_info = mp.utils.file_info(dir)
	if not dir_info or not dir_info.is_dir then
		local args
		if os_name == "windows" then
			args = { "cmd", "/c", "mkdir", dir }
		else
			args = { "mkdir", "-p", dir }
		end

		local res = mp.utils.subprocess({ args = args, cancellable = false })
		return res.status == 0
	end
	return true
end

local function delete_file(file_path)
	local file_info = mp.utils.file_info(file_path)

	if not file_info or file_info.is_dir then
		return false
	end

	local args
	if os_name == "windows" then
		args = { "cmd", "/c", "del", file_path }
	else
		args = { "rm", file_path }
	end

	local res = mp.utils.subprocess({ args = args, cancellable = false })
	return res.status == 0
end

local function set_file_modified_time(file_path, mtime)
	if not mtime then
		return false
	end

	local normalized_path = file_path:gsub([[\]], "/")
	local success = false
	local result

	if os_name == "windows" then
		result = mp.utils.subprocess({
			args = {
				"powershell",
				"-command",
				string.format(
					'(Get-Item -Path "%s").LastWriteTime = (Get-Date "1970-01-01 00:00:00").AddSeconds(%d).ToLocalTime()',
					normalized_path:gsub("/", "\\"),
					mtime
				),
			},
			cancellable = false,
		})
	else
		result = mp.utils.subprocess({
			args = {
				"touch",
				"-t",
				os.date("!%Y%m%d%H%M.%S", mtime),
				normalized_path,
			},
			cancellable = false,
		})
	end

	success = (result.status == 0)

	if not success and result.stderr then
		mp.msg.error("Failed to set file modified time: " .. (result.stderr or "Unknown error"))
	end

	return success
end

-- ffmpeg operations
local function run_ffmpeg(args)
	local base_args = {
		"ffmpeg",
		-- hide output
		"-nostdin",
		"-loglevel",
		"error",
		-- overwrite existing files
		"-y",
	}

	-- add args to base
	for _, arg in ipairs(args) do
		table.insert(base_args, arg)
	end

	local cmd_str = table.concat(base_args, " ")
	print("Running ffmpeg command: " .. cmd_str)

	local result = mp.utils.subprocess({
		args = base_args,
		cancellable = false,
	})

	return result.status == 0, result.stdout, result.stderr
end

local function render_cut(input, outpath, start, duration, input_mtime)
	local args = {
		-- seek to start before loading file (faster) https://trac.ffmpeg.org/wiki/Seeking#Inputseeking
		"-ss",
		tostring(start),
		"-t",
		tostring(duration),
		"-i",
		input,
		-- copy all input streams
		"-map",
		"0",
		-- shift timestamps so they start at 0
		"-avoid_negative_ts",
		"make_zero",
	}

	if options.lossless then
		table.insert(args, "-c")
		table.insert(args, "copy")
	end

	table.insert(args, outpath)

	local success = run_ffmpeg(args)

	if success and input_mtime then
		set_file_modified_time(outpath, input_mtime)
	end

	return success
end

local function merge_cuts(temp_dir, filepaths, outpath, input_mtime)
	-- i hate that you have to do a separate command and render each cut separately first, i tried using
	-- filter_complex for merging with multiple inputs but it wouldn't let me. todo: look into this further

	local merge_file = mp.utils.join_path(temp_dir, "merging.txt")
	local content = ""

	for _, path in ipairs(filepaths) do
		if os_name == "windows" then
			content = content .. string.format('file "%s"\n', path:gsub("/", "\\"))
		else
			content = content .. string.format("file '%s'\n", ffmpeg_escape_filepath(path))
		end
	end

	local file = io.open(merge_file, "w")
	if not file then
		log("Failed to create merge file")
		return false
	end
	file:write(content)
	file:close()

	local success = run_ffmpeg({
		"-f",
		"concat",
		"-safe",
		"0",
		"-i",
		merge_file,
		-- don't re-encode
		"-c",
		"copy",
		-- copy all input streams
		"-map",
		"0",
		outpath,
	})

	os.remove(merge_file)

	if success and input_mtime then
		set_file_modified_time(outpath, input_mtime)
	end

	if success then
		for _, path in ipairs(filepaths) do
			os.remove(path)
		end
	end

	return success
end

local function dump_cache(outpath)
	local cache_state = mp.get_property_native("demuxer-cache-state")
	if not cache_state then
		return nil
	end

	local cache_ranges = cache_state["seekable-ranges"]
	if #cache_ranges == 0 then
		return nil
	end

	local cache_start = cache_ranges[1]["start"]
	local cache_end = cache_ranges[1]["end"]

	local success = mp.commandv("dump-cache", cache_start, cache_end, outpath)
	if not success then
		log("Failed to dump cache")
		return nil
	end

	return cache_start
end

local function cut_render()
	if #cuts == 0 or not cuts[#cuts].end_time then
		log("No complete cuts to render")
		return
	end

	log("Rendering cuts...")

	local input = mp.get_property("path")
	local filename = mp.get_property("filename")

	local input_info = mp.utils.file_info(input)

	local is_stream = input_info == nil

	local cwd = mp.utils.getcwd()
	local outdir = mp.utils.join_path(cwd, options.output_dir)

	-- create output directory if needed
	if not ensure_directory_exists(outdir) then
		log("Failed to create output directory")
		return
	end

	local filename_noext, ext = "", ""
	local cache_offset = 0

	local temp_cache_file_name = mp.utils.join_path(outdir, "cache-dump.mkv")

	if not is_stream then
		filename_noext, ext = filename:match("^(.*)(%.[^%.]+)$")
	else
		filename_noext = sanitize_filename(mp.get_property("media-title"))
		ext = ".mkv"

		input = temp_cache_file_name

		local offset = dump_cache(input)
		if not offset then
			log("Failed to dump stream cache")
			return
		end

		cache_offset = offset
	end

	local input_info = mp.utils.file_info(input)

	if not input_info then
		log("Failed to read input")
	else
		-- sort cuts by start time
		table.sort(cuts, function(a, b)
			return a.start_time < b.start_time
		end)

		local cut_paths = {}

		for i, cut in ipairs(cuts) do
			if cut.end_time then
				local duration = cut.end_time - cut.start_time

				local cut_name = string.format(
					"(%s) %s (%s - %s)%s",
					#cuts == 1 and "cut" or "cut" .. i,
					filename_noext,
					to_hms(cut.start_time),
					to_hms(cut.end_time),
					ext
				)

				local cut_path = mp.utils.join_path(outdir, cut_name)

				log(string.format("(%d/%d) Rendering cut to %s", i, #cuts, cut_path))

				local success = render_cut(input, cut_path, cut.start_time - cache_offset, duration, input_info.mtime)
				if success then
					table.insert(cut_paths, cut_path)
				else
					log("Failed to render cut " .. i)
				end
			end
		end

		if #cut_paths > 1 and options.multi_cut_mode == "merge" then
			local merge_name = string.format("(%d merged cuts) %s%s", #cut_paths, filename_noext, ext)

			local merge_path = mp.utils.join_path(outdir, merge_name)

			log("Merging cuts...")
			local success = merge_cuts(cwd, cut_paths, merge_path, input_info.mtime)

			if success then
				log("Successfully merged cuts")
			else
				log("Failed to merge cuts")
			end
		end
	end

	if is_stream then
		delete_file(temp_cache_file_name)
	end

	log("Done!")
end

-- cut management functions
local function cut_toggle_mode()
	options.multi_cut_mode = options.multi_cut_mode == "separate" and "merge" or "separate"
	log(string.format('Cut mode set to "%s"', options.multi_cut_mode))
end

local function cut_clear()
	if next(cuts) then
		cuts = {}
		log("Cuts cleared")
	else
		log("No cuts to clear")
	end
end

local function cut_set_start(start_time)
	local last_cut = cuts[#cuts]
	if not last_cut or last_cut.end_time then
		local new_cut = { start_time = start_time }
		table.insert(cuts, new_cut)
		log(string.format("[cut %d] Set start time: %.2fs", #cuts, start_time))
	else
		last_cut.start_time = start_time
		log(string.format("[cut %d] Updated start time: %.2fs", #cuts, start_time))
	end
end

local function cut_set_end(end_time)
	if #cuts == 0 then
		log("No start point found")
		return
	end

	local had_end_time = cuts[#cuts].end_time ~= nil

	cuts[#cuts].end_time = end_time
	log(string.format("[cut %d] %s end time: %.2fs", #cuts, had_end_time and "updated" or "set", end_time))
end

-- key bindings
mp.add_key_binding("g", "cut_set_start", function()
	local time = mp.get_property_number("time-pos")
	if time ~= nil then
		cut_set_start(time)
	end
end)

mp.add_key_binding("h", "cut_set_end", function()
	local time = mp.get_property_number("time-pos")
	if time ~= nil then
		cut_set_end(time)
	end
end)

mp.add_key_binding("G", "cut_set_start_sof", function()
	cut_set_start(0)
end)

mp.add_key_binding("H", "cut_set_end_eof", function()
	cut_set_end(mp.get_property_number("duration"))
end)

mp.add_key_binding("ctrl+g", "cut_toggle_mode", cut_toggle_mode)
mp.add_key_binding("ctrl+h", "cut_clear", cut_clear)

mp.add_key_binding("r", "cut_render", cut_render)

mp.register_event("end-file", cut_clear)

log("mpv-lossless-cut loaded")
