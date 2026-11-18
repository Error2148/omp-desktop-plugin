--!nonstrict
-- omp Desk (window half): Codex / Claude desktop style projects and threads for omp.
--
-- A Tern session is a project, a tab is a thread. The plugin
--   * pins the project folder of every session (tern.kv "roots") and opens new threads there
--     (overrides `new_tab`, and `new_session` becomes "add project"),
--   * keeps a "项目主页" canvas as the first tab of every session: open threads with their state,
--     the project's omp history (resume with a click), other projects, buttons for the rest,
--   * offers `smart_copy` (bound to Ctrl+C in settings.json keybinds): copy a selection in
--     terminal/agent panes, else pass ^C through,
--   * pastes files dropped on an omp pane into its composer.

local ui = tern.ui
local ID = tern.plugin.id
local IS_WIN = tern.runtime.os == "windows"

local HOME_TITLE = "项目主页"
local HOME_ABOUT = "omp-desk:home"
local HISTORY_LIMIT = 300
local PICK_TITLE = "选择项目文件夹"

-- ---------------------------------------------------------------------------
-- Helpers

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

local function norm(p: string?): string
	if p == nil or p == "" then
		return ""
	end
	local s = string.gsub(p, "/", "\\")
	s = string.gsub(s, "\\+$", "")
	if IS_WIN then
		s = string.lower(s)
	end
	return s
end

local function under(path: string, root: string): boolean
	local p, r = norm(path), norm(root)
	if r == "" then
		return false
	end
	return p == r or string.sub(p, 1, #r + 1) == r .. "\\"
end

local function basename(p: string): string
	local s = string.gsub(p, "[/\\]+$", "")
	return string.match(s, "([^/\\]+)$") or s
end

-- Single-quoted for the login shell (PowerShell, as Tern quotes its own `omp --restore '…'`).
local function shellQuote(s: string): string
	return "'" .. string.gsub(s, "'", "''") .. "'"
end

local function exists(path: string): boolean
	local ok, res = pcall(tern.fs.exists, path)
	return ok and res == true
end

-- omp titles start with a Nerd Font icon (private use area); drop it for display and matching.
local function cleanTitle(t: string?): string
	if t == nil or t == "" then
		return ""
	end
	local ok, res = pcall(function()
		local out = {}
		for _, c in utf8.codes(t) do
			if not ((c >= 0xE000 and c <= 0xF8FF) or c >= 0xF0000) then
				table.insert(out, utf8.char(c))
			end
		end
		return table.concat(out)
	end)
	return trim(if ok then res else t)
end

local function titleKey(t: string?): string
	return string.lower(cleanTitle(t))
end

local function ago(t: number): string
	local d = os.time() - t
	if d < 60 then
		return "刚刚"
	elseif d < 3600 then
		return string.format("%d 分钟前", d // 60)
	elseif d < 86400 then
		return string.format("%d 小时前", d // 3600)
	elseif d < 86400 * 7 then
		return string.format("%d 天前", d // 86400)
	end
	return tostring(os.date("%Y-%m-%d", t))
end

local function kvMap(key: string): { [string]: any }
	local ok, v = pcall(tern.kv.get, key)
	if ok and type(v) == "table" then
		return v
	end
	return {}
end

local function kvPut(key: string, v: { [string]: any })
	local ok, err = pcall(tern.kv.set, key, v)
	if not ok then
		tern.log.warn("omp-desk: kv.set failed", key, err)
	end
end

local function setting(cx, key: string): any
	local ok, v = pcall(function()
		return cx.settings:get(key)
	end)
	return if ok then v else nil
end

local function agentCommand(cx): string
	local c = setting(cx, "agent_command")
	if type(c) == "string" and trim(c) ~= "" then
		return c
	end
	return "omp"
end

local function newBlocksAgent(cx): boolean
	local v = setting(cx, "new_blocks")
	return type(v) == "string" and string.lower(v) == "agent"
end

local function runQuiet(argv: { string })
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = 15000 }, function(_res, _cx) end)
	if not ok then
		tern.log.warn("omp-desk: cannot run", argv[1], err)
	end
end

-- ---------------------------------------------------------------------------
-- Window model: sessions, tabs, panes, home canvases, agent states

type Model = {
	sessions: { any },
	tabs: { [number]: any },
	homes: { [number]: number },
	homeSession: { [number]: number },
	extraHomes: { number },
	agents: { [number]: any },
}

-- Home canvases this window opened. A new canvas reaches cx.canvas:list() only once its state arrives,
-- so without this a second call right after opening one (the session switch's `focus`) opens another.
local opened: { [number]: boolean } = {}

local function addHome(m: Model, pane: number, sid: number)
	if m.homeSession[pane] ~= nil then
		return
	end
	m.homeSession[pane] = sid
	if m.homes[sid] == nil then
		m.homes[sid] = pane
	else
		table.insert(m.extraHomes, pane)
	end
end

local function model(cx): Model
	local m: Model = {
		sessions = cx.session:sessions(), tabs = {}, homes = {}, homeSession = {}, extraHomes = {}, agents = {},
	}
	for _, t in cx.session:tabs() do
		m.tabs[t.id] = t
	end
	for _, c in cx.canvas:list() do
		if c.owner == ID and c.about == HOME_ABOUT then
			local tab = cx.session:tab_of(c.pane)
			local t = if tab then m.tabs[tab] else nil
			if t then
				addHome(m, c.pane, t.session)
			end
		end
	end
	for pane in opened do
		local tab = cx.session:tab_of(pane)
		local t = if tab then m.tabs[tab] else nil
		if t then
			addHome(m, pane, t.session)
		else
			opened[pane] = nil
		end
	end
	local ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if ok then
		for _, a in agents do
			m.agents[a.pane] = a
		end
	end
	return m
end

local function sessionOf(m: Model, sid: number): any
	for _, s in m.sessions do
		if s.id == sid then
			return s
		end
	end
	return nil
end

-- Thread tabs of a session in tab order (the home canvas left out).
local function threadTabs(m: Model, sid: number): { any }
	local out = {}
	local s = sessionOf(m, sid)
	if s then
		for _, tid in s.tabs do
			local t = m.tabs[tid]
			if t and m.homeSession[t.pane] == nil then
				table.insert(out, t)
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Project roots

local function setRoot(sid: number, dir: string)
	local roots = kvMap("roots")
	roots[tostring(sid)] = dir
	kvPut("roots", roots)
end

-- The session's project folder: the recorded one, else its first thread's folder (recorded then).
local function rootOf(m: Model, sid: number): string?
	local r = kvMap("roots")[tostring(sid)]
	if type(r) == "string" and r ~= "" and exists(r) then
		return r
	end
	for _, t in threadTabs(m, sid) do
		if type(t.cwd) == "string" and t.cwd ~= "" then
			setRoot(sid, t.cwd)
			return t.cwd
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- omp history (scan.ps1 lists ~/.omp/agent/sessions/*/*.jsonl)

type Rec = { file: string, cwd: string, title: string, mtime: number, size: number, token: string }

local history: { Rec } = {}
local byToken: { [string]: Rec } = {}
local lastScan = -1e12
local scanning = false
local rescan = false
local renderAll: (cx: any) -> ()

local function sessionsDir(): string
	local base = tern.getenv("PI_CODING_AGENT_DIR")
	if base == nil or base == "" then
		base = (tern.getenv("USERPROFILE") or tern.getenv("HOME") or "") .. "\\.omp\\agent"
	end
	return base .. "\\sessions"
end

local function ingest(data: { any })
	local list: { Rec } = {}
	local tokens: { [string]: Rec } = {}
	for _, d in data do
		if type(d) == "table" and type(d.file) == "string" and type(d.cwd) == "string" then
			local title = if type(d.title) == "string" then d.title else ""
			local size = tonumber(d.size) or 0
			-- Untitled tiny files are omp's empty stubs (no turn yet).
			if title ~= "" or size > 8192 then
				local stem = string.gsub(basename(d.file), "%.jsonl$", "")
				local token = string.gsub(stem, "[^%w%-_]", "_")
				local rec: Rec = {
					file = d.file,
					cwd = d.cwd,
					title = title,
					mtime = tonumber(d.mtime) or 0,
					size = size,
					token = token,
				}
				table.insert(list, rec)
				tokens[token] = rec
			end
		end
	end
	table.sort(list, function(a, b)
		return a.mtime > b.mtime
	end)
	history = list
	byToken = tokens
end

local function scan()
	if scanning then
		rescan = true
		return
	end
	scanning = true
	local argv = {
		"powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", tern.plugin.dir .. "\\scan.ps1", "-Root", sessionsDir(),
	}
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = 30000 }, function(res, cx)
		scanning = false
		lastScan = tern.now()
		if res.status == 0 then
			local okj, data = pcall(tern.json.decode, res.stdout)
			if okj and type(data) == "table" then
				ingest(data)
			else
				tern.log.warn("omp-desk: history scan output is not JSON", data)
			end
		else
			tern.log.warn("omp-desk: history scan failed", res.status, res.stderr)
		end
		if cx then
			renderAll(cx)
		end
		if rescan then
			rescan = false
			scan()
		end
	end)
	if not ok then
		scanning = false
		tern.log.warn("omp-desk: cannot start history scan", err)
	end
end

local function scanSoon(ms: number)
	tern.timer(ms, function(_cx)
		scan()
	end)
end

-- ---------------------------------------------------------------------------
-- Threads

local function openThread(cx, dir: string, file: string?)
	local launch: { [string]: any } = { cwd = dir }
	if file then
		launch.command = agentCommand(cx) .. " --resume " .. shellQuote(file)
	elseif newBlocksAgent(cx) then
		launch.command = agentCommand(cx)
	end
	cx.layout:new_tab(launch)
end

local function resume(cx, sid: number, rec: Rec)
	local m = model(cx)
	local key = titleKey(rec.title)
	if key ~= "" then
		for _, t in threadTabs(m, sid) do
			if titleKey(t.title) == key then
				cx.layout:focus(t.pane)
				return
			end
		end
	end
	local dir = if exists(rec.cwd) then rec.cwd else (rootOf(m, sid) or rec.cwd)
	openThread(cx, dir, rec.file)
end

-- ---------------------------------------------------------------------------
-- Home canvas view

local query: { [number]: string } = {}
local showHidden: { [number]: boolean } = {}

local function row(label: string, detail: string?, value: string?, icon: string?, tone: string?, key: string, actions: any): any
	local node = ui.list({ { label = label, detail = detail, value = value, icon = icon, tone = tone } }).c[1]
	node.p = node.p or {}
	node.p.key = key
	node.p.actions = actions
	return node
end

local function list(key: string, rows: { any }, empty: string): any
	return ui.node("list", { key = key, empty = { ui.span(empty, "muted") } }, rows)
end

local function button(text: string, icon: string, act: string, variant: string?): any
	local b = ui.button(text, { icon = icon, variant = variant or "default", size = "sm" })
	b.p = b.p or {}
	b.p.key = "btn-" .. act
	b.p.actions = { click = act }
	return b
end

local function stateOf(a: any): (string, string, string)
	local st = if a then a.state else nil
	if st == "working" then
		return "运行中", "activity", "accent"
	elseif st == "waiting_input" then
		return "等你回复", "bell", "warning"
	elseif st == "exited" then
		return "已退出", "x-circle", "muted"
	elseif st == "idle" then
		return "空闲", "check", "success"
	end
	return "", "app-omp", "muted"
end

local function homeView(m: Model, sid: number): any
	local s = sessionOf(m, sid)
	local name = if s then s.name else "?"
	local root = rootOf(m, sid)
	local parts = {}

	-- Head: project name and folder.
	table.insert(parts, ui.row({
		ui.node("icon", { name = "folder", tone = "accent" }),
		ui.text({ ui.span(name, "strong") }),
	}))
	local path = ui.text({ ui.span(root or "（还没有项目目录：先新建一个对话）", "muted") })
	path.p = path.p or {}
	path.p.key = "root"
	if root then
		path.p.actions = {
			click = "reveal-root",
			menu = {
				{ id = "reveal-root", label = "在资源管理器中打开", icon = "folder-open" },
				{ id = "copy-root", label = "复制路径", icon = "copy" },
			},
		}
	end
	table.insert(parts, path)

	local bar = {
		button("新对话", "plus", "new", "primary"),
		button("添加项目", "folder-plus", "add"),
		button(if query[sid] then "搜索：" .. query[sid] else "搜索历史", "search", "search"),
	}
	if query[sid] then
		table.insert(bar, button("清除搜索", "funnel-x", "clear-search", "quiet"))
	end
	table.insert(bar, button("刷新", "repeat", "refresh", "quiet"))
	table.insert(parts, ui.row(bar))

	-- Open threads of this session.
	local openRows = {}
	local openCount: { [string]: number } = {}
	for _, t in threadTabs(m, sid) do
		local key = titleKey(t.title)
		openCount[key] = (openCount[key] or 0) + 1
		local title = if t.name and t.name ~= "" then t.name else cleanTitle(t.title)
		if title == "" then
			title = "新对话"
		end
		local label, icon, tone = stateOf(m.agents[t.pane])
		local id = tostring(t.id)
		table.insert(openRows, row(title, label, nil, icon, tone, "t" .. id, {
			click = "focus=" .. id,
			menu = {
				{ id = "focus=" .. id, label = "打开", icon = "open" },
				{ id = "pin=" .. id, label = "置顶", icon = "pin" },
				{ id = "unpin=" .. id, label = "取消置顶", icon = "x" },
			},
		}))
	end
	table.insert(parts, ui.section({ ui.span(string.format("进行中 · %d", #openRows)) }, {
		list("open", openRows, "没有进行中的对话，点“新对话”开始"),
	}))

	-- History: this project's omp sessions (also those started in its subfolders).
	local hidden = kvMap("hidden")
	local q = if query[sid] then string.lower(query[sid]) else nil
	local histRows = {}
	local hiddenCount, total = 0, 0
	if root then
		for _, r in history do
			if under(r.cwd, root) then
				local key = titleKey(r.title)
				if key ~= "" and (openCount[key] or 0) > 0 then
					-- The newest record with an open tab's title is that tab.
					openCount[key] -= 1
				else
					local isHidden = hidden[norm(r.file)] == true
					if isHidden then
						hiddenCount += 1
					end
					local title = cleanTitle(r.title)
					if title == "" then
						title = "未命名对话"
					end
					local match = q == nil or string.find(string.lower(title), q, 1, true) ~= nil
					if match and (not isHidden or showHidden[sid]) then
						total += 1
						if #histRows < HISTORY_LIMIT then
							local tk = r.token
							local hideItem = if isHidden
								then { id = "unhide=" .. tk, label = "取消隐藏", icon = "eye" }
								else { id = "hide=" .. tk, label = "从列表隐藏", icon = "eye-off" }
							table.insert(histRows, row(
								title,
								ago(r.mtime) .. (if isHidden then " · 已隐藏" else ""),
								nil,
								"history",
								if isHidden then "muted" else nil,
								"h" .. tk,
								{
									click = "resume=" .. tk,
									menu = {
										{ id = "resume=" .. tk, label = "继续这个对话", icon = "play" },
										hideItem,
										"-",
										{ id = "reveal=" .. tk, label = "在资源管理器中显示会话文件", icon = "folder-open" },
										{ id = "copypath=" .. tk, label = "复制会话文件路径", icon = "copy" },
									},
								}
							))
						end
					end
				end
			end
		end
	end
	local histHead = string.format("历史对话 · %d", total)
	if total > HISTORY_LIMIT then
		histHead ..= string.format("（显示最近 %d 条）", HISTORY_LIMIT)
	end
	local histParts = { list("history", histRows, if q then "没有匹配的历史对话" else "还没有历史对话") }
	if hiddenCount > 0 then
		table.insert(histParts, button(
			if showHidden[sid] then "不显示已隐藏" else string.format("显示已隐藏（%d）", hiddenCount),
			if showHidden[sid] then "eye-off" else "eye",
			"toggle-hidden",
			"quiet"
		))
	end
	table.insert(parts, ui.section({ ui.span(histHead) }, histParts))

	-- Other projects.
	local otherRows = {}
	for _, o in m.sessions do
		if o.id ~= sid then
			local r = rootOf(m, o.id)
			local n = #threadTabs(m, o.id)
			table.insert(otherRows, row(o.name, r or "", tostring(n), "folder", nil, "s" .. tostring(o.id), {
				click = "goto=" .. tostring(o.id),
			}))
		end
	end
	table.insert(parts, ui.section({ ui.span("其他项目") }, { list("projects", otherRows, "还没有其他项目") }))

	return ui.col(parts)
end

renderAll = function(cx)
	local m = model(cx)
	for pane, sid in m.homeSession do
		local ok, err = pcall(function()
			cx.canvas:set(pane, { view = homeView(m, sid) })
		end)
		if not ok then
			tern.log.warn("omp-desk: cannot render home", pane, err)
		end
	end
end

local renderTimer = nil
local function renderSoon()
	if renderTimer then
		return
	end
	renderTimer = tern.timer(250, function(cx)
		renderTimer = nil
		if cx then
			renderAll(cx)
		end
	end)
end

-- Gives every session of this window that has none its home canvas, as its first tab.
local creating = false
local function ensureHomes(cx)
	if creating then
		return
	end
	creating = true
	local m = model(cx)
	local cur = cx.sessions:current()
	for _, pane in m.extraHomes do
		opened[pane] = nil
		cx.layout:close(pane)
	end
	for _, s in m.sessions do
		if m.homes[s.id] == nil then
			local ok, err = pcall(function()
				local pane, openErr = cx.canvas:open({
					title = HOME_TITLE,
					about = HOME_ABOUT,
					view = homeView(m, s.id),
					how = "tab",
					focus = false,
				})
				if pane == nil then
					error(openErr or "canvas not opened")
				end
				opened[pane] = true
				local tab = cx.session:tab_of(pane)
				if s.id ~= cur.id then
					local moved, moveErr = cx.layout:move_to_new_tab(pane, s.id, { focus = false })
					if moved == nil then
						cx.layout:close(pane)
						error(moveErr or "cannot move to session")
					end
					tab = moved
				end
				if tab then
					cx.layout:order_tab(tab, 1)
				end
			end)
			if not ok then
				tern.log.warn("omp-desk: cannot open home", s.name, err)
			end
		end
	end
	creating = false
end

-- ---------------------------------------------------------------------------
-- Projects

local function createProject(cx, dir: string)
	dir = trim(dir)
	if dir == "" or not exists(dir) then
		cx:toast("error", "文件夹不存在", dir)
		return
	end
	local m = model(cx)
	for _, s in m.sessions do
		local r = rootOf(m, s.id)
		if r and norm(r) == norm(dir) then
			cx.sessions:switch(s.id)
			return
		end
	end
	local s = cx.sessions:create({ name = basename(dir), cwd = dir })
	setRoot(s.id, dir)
	ensureHomes(cx)
	renderSoon()
end

local function pickFolder(cx)
	local argv = {
		"powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass",
		"-File", tern.plugin.dir .. "\\pickfolder.ps1", "-Title", PICK_TITLE,
	}
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = 3600000 }, function(res, cx2)
		if res.status ~= 0 then
			tern.log.warn("omp-desk: folder picker failed", res.status, res.stderr)
			if cx2 then
				cx2:toast("error", "无法打开选文件夹窗口", trim(res.stderr))
			end
			return
		end
		local dir = trim(res.stdout)
		if dir ~= "" and cx2 then
			createProject(cx2, dir)
		end
	end)
	if not ok then
		cx:toast("error", "无法打开选文件夹窗口", tostring(err))
	end
end

local function addProject(cx)
	local m = model(cx)
	local known: { [string]: boolean } = {}
	for _, s in m.sessions do
		local r = rootOf(m, s.id)
		if r then
			known[norm(r)] = true
		end
	end
	local items = {
		{ label = "选择文件夹…", detail = "打开 Windows 选文件夹窗口", icon = "folder-open", kind = "browse" },
	}
	local seen: { [string]: boolean } = {}
	for _, r in history do
		local n = norm(r.cwd)
		if not known[n] and not seen[n] and exists(r.cwd) then
			seen[n] = true
			table.insert(items, {
				label = basename(r.cwd),
				detail = r.cwd .. " · " .. ago(r.mtime),
				icon = "folder",
				group = "omp 用过的目录",
				kind = "dir",
				dir = r.cwd,
			})
		end
	end
	cx:pick({ items = items, placeholder = "添加项目：选择文件夹", icon = "folder-plus", action = "添加" })
		:next(function(item, err, cx2)
			if err or item == nil or cx2 == nil then
				return
			end
			if item.kind == "browse" then
				pickFolder(cx2)
			elseif type(item.dir) == "string" then
				createProject(cx2, item.dir)
			end
		end)
end

-- ---------------------------------------------------------------------------
-- Overrides, events and canvas actions

tern.override("new_tab", function(cx)
	local cur = cx.sessions:current()
	local root = rootOf(model(cx), cur.id)
	if root == nil then
		return false
	end
	openThread(cx, root, nil)
	return true
end)

tern.override("new_session", function(cx)
	addProject(cx)
	return true
end)

local started = false
local function start(cx)
	if started then
		return
	end
	started = true
	scan()
	ensureHomes(cx)
	renderSoon()
	local ticks = 0
	local function tick()
		tern.timer(60000, function(cx2)
			ticks += 1
			if cx2 then
				renderAll(cx2)
			end
			if ticks % 5 == 0 then
				scan()
			end
			tick()
		end)
	end
	tick()
end

tern.on("window_start", start)
-- A reload does not run window_start again: start from a timer too.
tern.timer(0, function(cx)
	if cx then
		start(cx)
	end
end)

tern.on("focus", function(ev, cx)
	ensureHomes(cx)
	local m = model(cx)
	if m.homeSession[ev.pane] and tern.now() - lastScan > 15000 then
		scan()
	end
end)

for _, name in { "tab_created", "title", "agent_state", "agent_finished" } do
	tern.on(name, function(_ev, _cx)
		renderSoon()
	end)
end

tern.on("tab_closed", function(_ev, _cx)
	renderSoon()
	scanSoon(2000)
end)

tern.on("session_ended", function(ev, _cx)
	local roots = kvMap("roots")
	if roots[tostring(ev.session)] ~= nil then
		roots[tostring(ev.session)] = nil
		kvPut("roots", roots)
	end
end)

local function homeSessionOf(cx, pane: number): number?
	return model(cx).homeSession[pane]
end

tern.on("canvas_action", function(ev, cx)
	if ev.owner ~= ID then
		return false
	end
	local sid = homeSessionOf(cx, ev.pane)
	if sid == nil then
		return false
	end
	local act, v = ev.act, ev.value or ""
	local rec = byToken[v]

	if act == "new" then
		local root = rootOf(model(cx), sid)
		if root then
			openThread(cx, root, nil)
		else
			cx:command("new_tab")
		end
	elseif act == "add" then
		addProject(cx)
	elseif act == "refresh" then
		scan()
	elseif act == "search" then
		cx:prompt({ placeholder = "搜索历史对话标题", icon = "search", value = query[sid], action = "搜索" })
			:next(function(text, _err, cx2)
				if text == nil then
					return
				end
				text = trim(text)
				query[sid] = if text == "" then nil else text
				if cx2 then
					renderAll(cx2)
				end
			end)
	elseif act == "clear-search" then
		query[sid] = nil
		renderAll(cx)
	elseif act == "toggle-hidden" then
		showHidden[sid] = not showHidden[sid]
		renderAll(cx)
	elseif act == "focus" then
		local t = model(cx).tabs[tonumber(v) or -1]
		if t then
			cx.layout:focus(t.pane)
		end
	elseif act == "pin" then
		local tab = tonumber(v)
		if tab then
			cx.layout:order_tab(tab, 2)
			cx.layout:color_tab(tab, "yellow")
		end
	elseif act == "unpin" then
		local tab = tonumber(v)
		if tab then
			cx.layout:color_tab(tab, nil)
		end
	elseif act == "resume" then
		if rec then
			resume(cx, sid, rec)
		else
			scan()
		end
	elseif act == "hide" or act == "unhide" then
		if rec then
			local hidden = kvMap("hidden")
			hidden[norm(rec.file)] = if act == "hide" then true else nil
			kvPut("hidden", hidden)
			renderAll(cx)
		end
	elseif act == "reveal" then
		if rec then
			runQuiet({ "explorer.exe", "/select," .. rec.file })
		end
	elseif act == "copypath" then
		if rec then
			cx:copy(rec.file)
			cx:toast("success", "已复制会话文件路径")
		end
	elseif act == "reveal-root" or act == "copy-root" then
		local root = rootOf(model(cx), sid)
		if root and act == "reveal-root" then
			runQuiet({ "explorer.exe", root })
		elseif root then
			cx:copy(root)
			cx:toast("success", "已复制项目路径")
		end
	elseif act == "goto" then
		local target = tonumber(v)
		if target then
			cx.sessions:switch(target)
			local home = model(cx).homes[target]
			if home then
				cx.layout:focus(home)
			end
		end
	else
		return false
	end
	return true
end)

-- ---------------------------------------------------------------------------
-- Smart copy for terminal/agent panes: copy the selection when there is one, else ^C to the program.
-- Tern's own keymap holds Ctrl+C, so a plugin bind is left out; settings.json `keybinds` puts
-- `plugin.omp-desk.smart_copy` first on Ctrl+C. `available` is false elsewhere, so the next action
-- on the chord (Tern's own) runs there.

local function focusedProgram(cx): number?
	local pane = cx.session:focused()
	local info = if pane then cx.session:pane(pane) else nil
	if info and (info.kind == "agent" or info.kind == "terminal") then
		return pane
	end
	return nil
end

tern.command({
	id = "smart_copy",
	title = "复制选中内容（无选中时发送 Ctrl+C）",
	icon = "copy",
	available = function(cx)
		return focusedProgram(cx) ~= nil
	end,
	run = function(cx)
		local pane = focusedProgram(cx)
		if pane == nil then
			return
		end
		local sel = cx.session:selection(pane)
		if sel and sel.text ~= "" then
			cx:copy(sel.text)
		else
			cx:action("text:\3")
		end
	end,
})

-- ---------------------------------------------------------------------------
-- Files dropped on an omp pane go into its composer as a paste (omp turns image paths into images).

tern.route.open(function(req, cx)
	if req.origin ~= "drop" then
		return nil
	end
	local pane = cx.session:focused()
	local info = if pane then cx.session:pane(pane) else nil
	if pane == nil or info == nil or info.kind ~= "agent" then
		return nil
	end
	cx:run(pane, "\27[200~" .. req.path .. "\27[201~")
	return { handled = true }
end)
