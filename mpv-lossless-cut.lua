mp.msg = require("mp.msg")
mp.utils = require("mp.utils")
mp.options = require("mp.options")

local options = {
	output_dir = ".",
	multi_cut_mode = "separate",
	lossless = true,
	lossy_ffmpeg_args = "-c:v libx264 -crf 18 -preset fast -c:a aac -b:a 192k",
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
		return path:gsub("/", "\\"):gsub("\\", "\\\\"):gsub("'", "'\\''")
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

local function parse_ffmpeg_args(args_string)
	local args = {}
	local in_quote = false
	local quote_char = nil
	local current_arg = ""
	
	for i = 1, #args_string do
		local char = args_string:sub(i, i)
		
		if (char == '"' or char == "'") and not in_quote then
			in_quote = true
			quote_char = char
		elseif char == quote_char and in_quote then
			in_quote = false
			quote_char = nil
		elseif char:match("%s") and not in_quote then
			if current_arg ~= "" then
				table.insert(args, current_arg)
				current_arg = ""
			end
		else
			current_arg = current_arg .. char
		end
	end
	
	-- add the last argument
	if current_arg ~= "" then
		table.insert(args, current_arg)
	end
	
	return args
end

function join_paths(path1, path2)
	if not path1 or path1 == "" then
		return path2 or ""
	end
	if not path2 or path2 == "" then
		return path1
	end

	local separator
	if os_name == "windows" then
		separator = "\\"
	else
		separator = "/"
	end

	-- normalize separators in both paths
	path1 = path1:gsub("[/\\]", separator)
	path2 = path2:gsub("[/\\]", separator)

	-- remove trailing separator from path1
	path1 = path1:gsub(separator == "\\" and "\\+$" or "/+$", "")

	-- handle absolute path2 (starts with drive letter on Windows or / on Unix)
	if path2:match("^[A-Za-z]:") or path2:match("^" .. (separator == "\\" and "\\" or "/")) then
		return path2
	end

	-- handle relative paths with .. and .
	local function resolve_path(base, relative)
		local parts = {}

		-- split base path into parts
		local pattern = separator == "\\" and "[^\\\\]+" or "[^/]+"
		for part in base:gmatch(pattern) do
			table.insert(parts, part)
		end

		-- process relative path parts
		for part in relative:gmatch(pattern) do
			if part == ".." then
				if #parts > 0 then
					table.remove(parts)
				end
			elseif part ~= "." then
				table.insert(parts, part)
			end
		end

		-- reconstruct path
		local result = table.concat(parts, separator)

		-- handle drive letters on Windows
		if base:match("^[A-Za-z]:") then
			local drive = base:match("^[A-Za-z]:")
			if not result:match("^[A-Za-z]:") then
				result = drive .. separator .. result
			end
		elseif
			base:match("^" .. (separator == "\\" and "\\\\" or "/"))
			and not result:match("^" .. (separator == "\\" and "\\\\" or "/"))
		then
			result = separator .. result
		end

		return result
	end

	return resolve_path(path1, path2)
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

local function set_file_times(file_path, mtime)
	if not mtime then
		mp.msg.warn("No mtime provided for: " .. file_path)
		return false
	end

	local file_info = mp.utils.file_info(file_path)
	if not file_info then
		mp.msg.error("File does not exist, cannot set times: " .. file_path)
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
					"$file = Get-Item -LiteralPath '%s'; "
						.. '$date = (Get-Date "1970-01-01 00:00:00").AddSeconds(%d).ToLocalTime(); '
						.. "$file.CreationTime = $date; "
						.. "$file.LastWriteTime = $date",
					normalized_path:gsub("/", "\\"):gsub("'", "''"),
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

	if not success then
		local error_msg = result.stderr or result.stdout or "Unknown error"
		mp.msg.error("Failed to set file times for " .. file_path .. ": " .. error_msg)
	else
		mp.msg.verbose("Successfully set file times for: " .. file_path)
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

local function render_cut(input, outpath, start, duration, input_mtime, use_lossless)
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

	if use_lossless then
		table.insert(args, "-c")
		table.insert(args, "copy")
	else
		local parsed_args = parse_ffmpeg_args(options.lossy_ffmpeg_args)
		for _, arg in ipairs(parsed_args) do
			table.insert(args, arg)
		end
	end

	table.insert(args, outpath)

	local success = run_ffmpeg(args)

	if success and input_mtime then
		set_file_times(outpath, input_mtime)
	end

	return success
end

local function merge_cuts(temp_dir, filepaths, outpath, input_mtime)
	-- i hate that you have to do a separate command and render each cut separately first, i tried using
	-- filter_complex for merging with multiple inputs but it wouldn't let me. todo: look into this further

	local merge_file = join_paths(temp_dir, "merging.txt")
	local content = ""

	for _, path in ipairs(filepaths) do
		content = content .. string.format("file '%s'\n", ffmpeg_escape_filepath(path))
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
		set_file_times(outpath, input_mtime)
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

local function cut_render(use_lossless, copy_clipboard)
	if #cuts == 0 or not cuts[#cuts].end_time then
		log("No complete cuts to render")
		return
	end

	log("Rendering cuts...")

	local input = mp.get_property("path")
	local filename = mp.get_property("filename")

	local input_info = mp.utils.file_info(input)

	local is_stream = input_info == nil

	local outdir
	if copy_clipboard then
		if os_name == "windows" then
			outdir = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
		else
			outdir = os.getenv("TMPDIR") or "/tmp"
		end

		outdir = join_paths(outdir, "mpv-lossless-cut")
	elseif options.output_dir == "@cwd" or is_stream then
		outdir = mp.utils.getcwd()
	else
		input_dir = mp.utils.split_path(input)
		outdir = join_paths(input_dir, options.output_dir)
	end

	-- create output directory if needed
	if not ensure_directory_exists(outdir) then
		log("Failed to create output directory")
		return
	end

	local filename_noext, ext = "", ""
	local cache_offset = 0

	local temp_cache_file_name = join_paths(outdir, "cache-dump.mkv")

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

	input_info = mp.utils.file_info(input)

	if not input_info then
		log("Failed to read input file info")
	end

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

			local cut_path = join_paths(outdir, cut_name)

			log(string.format("(%d/%d) Rendering cut to %s", i, #cuts, cut_path))

			local mtime = input_info and input_info.mtime or nil
			local success = render_cut(input, cut_path, cut.start_time - cache_offset, duration, mtime, use_lossless)
			if success then
				table.insert(cut_paths, cut_path)
				log(string.format("(%d/%d) Rendered cut to %s", i, #cuts, cut_path))
			else
				log("Failed to render cut " .. i)
			end
		end
	end

	local final_output = nil

	if #cut_paths > 1 and options.multi_cut_mode == "merge" then
		local merge_name = string.format("(%d merged cuts) %s%s", #cut_paths, filename_noext, ext)

		local merge_path = join_paths(outdir, merge_name)

		log("Merging cuts...")
		local mtime = input_info and input_info.mtime or nil
		local success = merge_cuts(outdir, cut_paths, merge_path, mtime)

		if success then
			log("Successfully merged cuts")
			final_output = merge_path
		else
			log("Failed to merge cuts")
		end
	elseif #cut_paths == 1 then
		final_output = cut_paths[1]
	end

	if copy_clipboard and final_output then
		if mp.set_property('clipboard/text', final_output) then
			log("Copied to clipboard: " .. final_output)
		else
			log("Failed to copy to clipboard")
		end
	end

	if is_stream then
		delete_file(temp_cache_file_name)
	end
end

-- cut management functions
local function cut_toggle_mode()
	options.multi_cut_mode = options.multi_cut_mode == "separate" and "merge" or "separate"
	log(string.format('Cut mode set to "%s"', options.multi_cut_mode))
end

local function cut_clear(silent)
	if next(cuts) then
		cuts = {}

		if not silent then
			log("Cuts cleared")
		end
	else
		if not silent then
			log("No cuts to clear")
		end
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

mp.add_key_binding("r", "cut_render", function()
	cut_render(options.lossless, false)
end)
mp.add_key_binding("ctrl+r", "cut_render_clipboard", function()
	cut_render(false, true)
end)

mp.register_event("end-file", function()
	cut_clear(true)
end)

print("mpv-lossless-cut loaded")
