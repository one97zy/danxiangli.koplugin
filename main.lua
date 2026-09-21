-- main.lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local util            = require("util")
local http            = require("socket.http")
local ltn12           = require("ltn12")
local Device          = require("device")
local NetworkMgr      = require("ui/network/manager")
local Event           = require("ui/event")
-- 变量名用 gettext，避免与 UIManager 内部的 `_` 冲突
local gettext         = require("gettext")

local has_lfs, lfs = pcall(require, "lfs")

local DanXiangLi = WidgetContainer:extend{ name = "danxiangli" }

local BASE_URL = "https://img.owspace.com/Public/uploads/Download/"

-- 单向历专用子目录，与用户自己的图片隔离
local SAVE_DIR   = "/mnt/us/koreader/screenshots/danxiangli/"
-- 旧版本曾用过的主目录，仅用于迁移
local LEGACY_DIR = "/mnt/us/koreader/screenshots/"

local INIT_DELAY      = 8
local WAKE_DELAY      = 1
local SUSPEND_TIMEOUT = 3
local CHECK_INTERVAL  = 10 * 60
local RETRY_DELAY     = 3
local NET_WAIT_DELAY  = 5
local MIN_JPEG_SIZE   = 1024

local SETTING_KEY_LAST_DATE        = "danxiangli_last_date"
local SETTING_KEY_AUTO_SCREENSAVER = "danxiangli_auto_screensaver"

----------------------------------------------------------------------
-- 工具
----------------------------------------------------------------------

local function build_url(y, m, d)
    return string.format("%s%d/%02d%02d.jpg", BASE_URL, y, m, d)
end

local function safe_close_file(file)
    if file and not pcall(file.close, file) then
        logger.dbg("单向历: file:close() skipped")
    end
end

local function get_today_info()
    local now = os.date("*t")
    local date_str = string.format("%04d%02d%02d", now.year, now.month, now.day)
    return now, date_str, SAVE_DIR .. date_str .. ".jpg"
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function is_valid_jpeg(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(2)
    local size = f:seek("end")
    f:close()
    return head == "\255\216" and size and size >= MIN_JPEG_SIZE
end

local function is_network_available()
    if NetworkMgr and NetworkMgr.isConnected then
        local ok, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
        if ok then return connected end
    end
    return true
end

-- 遍历 SAVE_DIR（子目录）里的 jpg
local function each_jpg(callback)
    if has_lfs then
        for f in lfs.dir(SAVE_DIR) do
            if f:match("%.jpg$") then callback(f) end
        end
    else
        local handle = io.popen("ls -1 '" .. SAVE_DIR .. "' 2>/dev/null")
        if handle then
            for f in handle:lines() do
                if f:match("%.jpg$") then callback(f) end
            end
            handle:close()
        end
    end
end

-- 只删除"非今日"的 jpg（且只在 SAVE_DIR 里删）
local function cleanup_old_images(keep_date_str)
    local keep_name = keep_date_str .. ".jpg"
    local removed = 0
    each_jpg(function(f)
        if f ~= keep_name then
            os.remove(SAVE_DIR .. f)
            removed = removed + 1
        end
    end)
    if removed > 0 then
        logger.info("单向历: 删除旧图", removed, "张")
    end
end

-- 迁移：把旧主目录里的 YYYYMMDD.jpg 搬到子目录
-- 只认 8 位数字命名，绝不碰用户自己放的图
local function migrate_legacy_files()
    if not has_lfs then
        logger.dbg("单向历: 无 lfs，跳过旧文件迁移")
        return
    end

    local ok = util.makePath(SAVE_DIR)
    if not ok then return end

    local migrated = 0
    for f in lfs.dir(LEGACY_DIR) do
        if f:match("^%d%d%d%d%d%d%d%d%.jpg$") then
            local src = LEGACY_DIR .. f
            local dst = SAVE_DIR .. f
            if file_exists(dst) then
                os.remove(src)  -- 新目录已有，旧的就删
            else
                local rok = os.rename(src, dst)
                if rok then
                    migrated = migrated + 1
                else
                    logger.warn("单向历: 迁移失败", src)
                end
            end
        end
    end

    if migrated > 0 then
        logger.info("单向历: 迁移旧图", migrated, "张到子目录")
    end
end

----------------------------------------------------------------------
-- 持久化
----------------------------------------------------------------------

local function get_last_auto_date()
    if G_reader_settings then
        return G_reader_settings:readSetting(SETTING_KEY_LAST_DATE)
    end
    return nil
end

local function set_last_auto_date(date_str)
    if G_reader_settings then
        G_reader_settings:saveSetting(SETTING_KEY_LAST_DATE, date_str)
    end
end

local function is_auto_screensaver_enabled()
    if not G_reader_settings then return true end
    local v = G_reader_settings:readSetting(SETTING_KEY_AUTO_SCREENSAVER)
    if v == nil then return true end  -- 首次安装默认开启
    return v == true
end

local function set_auto_screensaver_enabled(enabled)
    if G_reader_settings then
        G_reader_settings:saveSetting(SETTING_KEY_AUTO_SCREENSAVER, enabled)
        G_reader_settings:flush()
    end
end

----------------------------------------------------------------------
-- 状态 -> 用户可读消息
----------------------------------------------------------------------

local function status_text(status)
    if status == "ok" then return gettext("单向历已更新")
    elseif status == "exists" then return gettext("今日单向历已存在")
    elseif status == "no_network" then return gettext("无网络连接")
    elseif status == "open_error" then return gettext("无法创建文件（权限或空间不足）")
    elseif status == "network_error" then return gettext("网络请求失败")
    elseif status == "invalid_file" then return gettext("下载文件校验失败")
    elseif status == "rename_error" then return gettext("文件替换失败")
    elseif type(status) == "string" and status:match("^http_") then
        local code = status:sub(6)
        if code == "404" then return gettext("今日图片未发布 (404)")
        elseif code == "403" then return gettext("访问被拒绝 (403)")
        elseif code == "500" or code == "502" or code == "503" then
            return gettext("服务器暂时不可用 (") .. code .. ")"
        end
        return gettext("HTTP 错误: ") .. code
    end
    return gettext("未知错误: ") .. tostring(status)
end

local function handle_result(success, status, silent, notify)
    if silent then
        if success and notify then
            UIManager:show(InfoMessage:new{
                text = gettext("单向历已更新"),
                timeout = 1.5,
            })
        elseif not success then
            logger.warn("单向历: 自动失败", status)
        end
        return
    end

    UIManager:show(InfoMessage:new{
        text = status_text(status),
        timeout = success and 2 or 4,
    })
end

----------------------------------------------------------------------
-- 下载（原子写入）
----------------------------------------------------------------------

local function download_image(year, month, day, date_str, timeout)
    if not is_network_available() then
        logger.dbg("单向历: 无网，跳过")
        return false, "no_network"
    end

    local url = build_url(year, month, day)
    local target = SAVE_DIR .. date_str .. ".jpg"
    local tmp = target .. ".tmp"
    timeout = timeout or 15

    logger.info("单向历: 开始下载", url)
    os.remove(tmp)

    local file, err = io.open(tmp, "wb")
    if not file then
        logger.warn("单向历: 无法创建 tmp", tostring(err))
        return false, "open_error"
    end

    local ok, status_code = http.request{
        url = url,
        headers = {
            ["Referer"]    = "https://img.owspace.com/",
            ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader)",
        },
        sink = ltn12.sink.file(file),
        redirect = true,
        timeout = timeout,
    }
    safe_close_file(file)

    if not ok then
        logger.warn("单向历: 网络错误", tostring(status_code))
        os.remove(tmp)
        return false, "network_error"
    end
    if type(status_code) ~= "number" or status_code ~= 200 then
        logger.warn("单向历: HTTP", tostring(status_code))
        os.remove(tmp)
        return false, "http_" .. tostring(status_code)
    end
    if not is_valid_jpeg(tmp) then
        logger.warn("单向历: 文件校验失败")
        os.remove(tmp)
        return false, "invalid_file"
    end

    os.remove(target)
    local rok, rerr = os.rename(tmp, target)
    if not rok then
        logger.warn("单向历: rename 失败", tostring(rerr))
        os.remove(tmp)
        return false, "rename_error"
    end

    logger.info("单向历: 下载完成", target)
    return true, "ok"
end

----------------------------------------------------------------------
-- 环境自检
----------------------------------------------------------------------

local function check_environment()
    local ok_wrap, result = pcall(function()
        local lines = {}

        local ok, err = util.makePath(SAVE_DIR)
        lines[#lines + 1] = ok and gettext("✓ 目录可写: ") .. SAVE_DIR
            or (gettext("✗ 目录错误: ") .. tostring(err))

        lines[#lines + 1] = has_lfs and gettext("✓ lfs 可用")
            or gettext("△ lfs 不可用（用 shell 兜底）")

        lines[#lines + 1] = is_network_available() and gettext("✓ 网络已连接")
            or gettext("✗ 无网络")

        lines[#lines + 1] = is_auto_screensaver_enabled()
            and gettext("✓ 自动配置屏保已开启")
            or gettext("○ 自动配置屏保已关闭")

        local _, today_str, today_path = get_today_info()
        if is_valid_jpeg(today_path) then
            lines[#lines + 1] = gettext("✓ 今日图片已存在: ") .. today_str
        elseif file_exists(today_path) then
            lines[#lines + 1] = gettext("△ 今日文件损坏: ") .. today_str
        else
            lines[#lines + 1] = gettext("○ 今日图片未下载")
        end

        local count = 0
        each_jpg(function() count = count + 1 end)
        lines[#lines + 1] = gettext("子目录 jpg 数量: ") .. count
            .. (count == 0 and gettext("（screensaver 将无图可显示！）") or "")

        local last = get_last_auto_date()
        if last then
            lines[#lines + 1] = gettext("上次自动完成: ") .. last
        end

        return table.concat(lines, "\n")
    end)

    if not ok_wrap then
        logger.warn("单向历: 自检异常", tostring(result))
        return gettext("自检内部错误: ") .. tostring(result)
    end
    return result
end

----------------------------------------------------------------------
-- 插件主体
----------------------------------------------------------------------

function DanXiangLi:init()
    self.ui.menu:registerToMainMenu(self)
    self._auto_running = false

    -- 迁移旧主目录里的单向历图到子目录（只搬 YYYYMMDD.jpg）
    migrate_legacy_files()

    -- 自动配置屏保（若开关开启）
    self:_ensure_screensaver_settings()

    UIManager:scheduleIn(INIT_DELAY, function() self:auto_run(true) end)
    self:_schedule_periodic_check()
    self:_install_power_hook()
end

-- 自动配置 KOReader 屏保为随机图片模式，指向 SAVE_DIR（子目录）
function DanXiangLi:_ensure_screensaver_settings()
    if not G_reader_settings then
        logger.warn("单向历: G_reader_settings 不可用，跳过屏保自动配置")
        return
    end

    if not is_auto_screensaver_enabled() then
        logger.dbg("单向历: 自动配置屏保已关闭，跳过")
        return
    end

    local changed = false

    -- 1. 屏保类型：随机图片
    if G_reader_settings:readSetting("screensaver_type") ~= "random_image" then
        G_reader_settings:saveSetting("screensaver_type", "random_image")
        logger.info("单向历: 已将屏保类型设为随机图片")
        changed = true
    end

    -- 2. 图片文件夹：指向子目录
    if G_reader_settings:readSetting("screensaver_dir") ~= SAVE_DIR then
        G_reader_settings:saveSetting("screensaver_dir", SAVE_DIR)
        logger.info("单向历: 已将屏保图片文件夹设为", SAVE_DIR)
        changed = true
    end

    -- 3. 拉伸图片以适应屏幕
    if not G_reader_settings:isTrue("screensaver_stretch") then
        G_reader_settings:saveSetting("screensaver_stretch", true)
        logger.info("单向历: 已启用屏保图片拉伸")
        changed = true
    end

    -- 4. 不显示屏保信息
    if not G_reader_settings:isTrue("screensaver_show_message") then
        G_reader_settings:saveSetting("screensaver_show_message", false)
        logger.info("单向历: 已关闭屏保信息显示")
        changed = true
    end

    if changed then
        G_reader_settings:flush()
        logger.info("单向历: 屏保设置已自动配置完成")
    else
        logger.dbg("单向历: 屏保设置已符合要求，无需更改")
    end
end

function DanXiangLi:_schedule_periodic_check()
    UIManager:scheduleIn(CHECK_INTERVAL, function()
        self:auto_run(true)
        self:_schedule_periodic_check()
    end)
end

function DanXiangLi:_install_power_hook()
    if self._power_hook_installed then return end
    self._power_hook_installed = true
    local plugin = self

    -- 方案 A：UIManager.broadcastEvent
    local orig_broadcast = UIManager.broadcastEvent
    self._orig_broadcast = orig_broadcast
    UIManager.broadcastEvent = function(ui, event)
        local name = event and event.handler
        if name == "Suspend" then
            plugin:_on_suspend()
        elseif name == "Resume" then
            plugin:_on_resume()
        end
        return orig_broadcast(ui, event)
    end

    -- 方案 B：Device.onPowerEvent + screen_saver_mode 变化
    local orig_on_power = Device.onPowerEvent
    self._orig_on_power = orig_on_power
    Device.onPowerEvent = function(dev, ev)
        local was_saver = dev.screen_saver_mode
        local ret = orig_on_power(dev, ev)
        local is_saver = dev.screen_saver_mode

        if was_saver ~= is_saver then
            if is_saver then
                plugin:_on_suspend()
            else
                plugin:_on_resume()
            end
        end
        return ret
    end
end

-- Suspend 热路径：不做磁盘写、不做网络请求
function DanXiangLi:_on_suspend()
    local _, today_str, today_path = get_today_info()
    self._suspended_date = today_str

    if is_valid_jpeg(today_path) then
        logger.dbg("单向历: [Suspend] 今日图已存在，无需处理")
    else
        logger.info("单向历: [Suspend] 今日图缺失，Resume 后自动下载")
    end
end

function DanXiangLi:_on_resume()
    logger.info("单向历: [Resume] 安排更新")
    UIManager:scheduleIn(WAKE_DELAY, function()
        self:auto_run(true)
    end)
end

function DanXiangLi:_schedule_net_retry()
    UIManager:scheduleIn(NET_WAIT_DELAY, function()
        if is_network_available() then
            logger.dbg("单向历: 网络已就绪，重试")
            self:auto_run(true)
        end
    end)
end

function DanXiangLi:auto_run(silent)
    if self._auto_running then
        logger.dbg("单向历: 任务进行中，跳过")
        if not silent then
            UIManager:show(InfoMessage:new{
                text = gettext("单向历任务进行中..."),
                timeout = 2,
            })
        end
        return
    end
    self._auto_running = true

    local ok, err = util.makePath(SAVE_DIR)
    if not ok then
        logger.warn("单向历: 创建目录失败", tostring(err))
        self._auto_running = false
        return
    end

    local now, today_str, today_path = get_today_info()
    local last_date = get_last_auto_date()
    local is_new_day = (last_date ~= today_str)

    -- 已经有效：仅清理旧图
    if is_valid_jpeg(today_path) then
        if is_new_day then
            logger.info("单向历: 今日图已存在（跨天首次检查）")
            set_last_auto_date(today_str)
        else
            logger.dbg("单向历: 今日图已存在，跳过")
        end
        cleanup_old_images(today_str)
        handle_result(true, "exists", silent, false)
        self._auto_running = false
        return
    end

    -- 今日图缺失：下载
    local was_missing = true
    local success, status = download_image(now.year, now.month, now.day, today_str)

    if not success and status ~= "no_network" then
        logger.info("单向历: 首次失败，稍后重试")
        UIManager:scheduleIn(RETRY_DELAY, function()
            local now2, today_str2 = get_today_info()
            local ok2, status2 = download_image(now2.year, now2.month, now2.day, today_str2)
            if ok2 then
                cleanup_old_images(today_str2)
                set_last_auto_date(today_str2)
            end
            handle_result(ok2, status2, silent, ok2 and (is_new_day or was_missing))
            self._auto_running = false
        end)
        return
    end

    if success then
        cleanup_old_images(today_str)
        set_last_auto_date(today_str)
        handle_result(true, "ok", silent, (is_new_day or was_missing))
    else
        self:_schedule_net_retry()
        handle_result(false, status, silent, false)
    end

    self._auto_running = false
end

function DanXiangLi:force_redownload()
    local _, today_str, today_path = get_today_info()
    os.remove(today_path)
    logger.info("单向历: 已删除今日文件，重新下载")
    self:auto_run(false)
end

----------------------------------------------------------------------
-- 菜单
----------------------------------------------------------------------

function DanXiangLi:addToMainMenu(menu_items)
    menu_items.danxiangli = {
        text = gettext("单向历"),
        sorting_hint = "tools",   -- 与微信读书同级
        sub_item_table = {
            {
                text = gettext("自动配置屏保"),
                checked_func = function() return is_auto_screensaver_enabled() end,
                callback = function()
                    local was = is_auto_screensaver_enabled()
                    local now = not was
                    set_auto_screensaver_enabled(now)

                    if now then
                        self:_ensure_screensaver_settings()
                        UIManager:show(InfoMessage:new{
                            text = gettext("已启用自动配置屏保\n屏保已指向 danxiangli 子目录"),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = gettext("已停用自动配置屏保\n现有屏保设置保持不变，可自行到\n设置 → 屏幕 → 屏保 中调整"),
                            timeout = 4,
                        })
                    end
                end,
            },
            {
                text = gettext("下载今日单向历"),
                callback = function() self:auto_run(false) end,
            },
            {
                text = gettext("强制重新下载今日"),
                callback = function() self:force_redownload() end,
            },
            {
                text = gettext("诊断 / 测试"),
                sub_item_table = {
                    {
                        text = gettext("环境自检"),
                        callback = function()
                            UIManager:show(InfoMessage:new{
                                text = check_environment(),
                                timeout = 10,
                            })
                        end,
                    },
                    {
                        text = gettext("测试网络（访问图片服务器）"),
                        callback = function()
                            local t = os.date("*t", os.time() - 86400)
                            local url = build_url(t.year, t.month, t.day)
                            logger.info("单向历: 网络测试", url)
                            local _, code = http.request{
                                url = url,
                                method = "HEAD",
                                headers = { ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader)" },
                                redirect = true,
                                timeout = 10,
                            }
                            local msg
                            if type(code) == "number" and code >= 200 and code < 400 then
                                msg = gettext("连接正常，HTTP ") .. tostring(code)
                            else
                                msg = gettext("网络异常: ") .. tostring(code)
                            end
                            UIManager:show(InfoMessage:new{ text = msg, timeout = 3 })
                        end,
                    },
                },
            },
        },
    }
    return menu_items
end

return DanXiangLi