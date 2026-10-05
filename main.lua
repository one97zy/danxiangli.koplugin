--[[
单向历 (DanXiangLi) V5 — KOReader 插件
- 每日下载单向历（OWSPACE）当日壁纸，并自动接管 KOReader 锁屏屏保。
- 安装即自动配置屏保（随机图模式 + 专用目录 + 拉伸填充，避免两侧黑边）。
- 唤醒后自动更新；Wi-Fi 重连期间退避重试，连上立即下载。
- 仅保留当日图片，旧图自动清理。
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local util            = require("util")
local http            = require("socket.http")
local ltn12           = require("ltn12")
local NetworkMgr      = require("ui/network/manager")
local gettext         = require("gettext")

local has_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not has_lfs then
    has_lfs, lfs = pcall(require, "lfs")
end

local DanXiangLi = WidgetContainer:extend{ name = "danxiangli" }

local BASE_URL = "https://img.owspace.com/Public/uploads/Download/"
local SAVE_DIR = "/mnt/us/koreader/screenshots/danxiangli/"
-- 旧版本曾用过的主目录，仅用于一次性迁移
local LEGACY_DIR = "/mnt/us/koreader/screenshots/"

-- 单向历按北京时间发布；固定偏移，不依赖设备时区
local UTC_OFFSET = 8 * 3600

local INIT_DELAY       = 8        -- 启动后首次检查延迟（秒）
local RESUME_DELAY     = 2        -- 唤醒后检查延迟（秒）
local CHECK_INTERVAL   = 5 * 60   -- 周期兜底检查（秒）
local MAX_RETRIES      = 6        -- Wi-Fi 重连等待的最大轮数
local RETRY_BASE       = 10       -- 退避基数（秒）
local RETRY_MAX        = 120      -- 单次退避上限（秒）
local HTTP_TIMEOUT     = 20       -- 下载超时（秒）
local HTTP404_COOLDOWN = 2 * 3600 -- 今日图未发布 (404) 后的冷却（秒）
local MIN_JPEG_SIZE    = 1024

local SETTING_LAST_DATE        = "danxiangli_last_date"
local SETTING_AUTO_SCREENSAVER = "danxiangli_auto_screensaver"

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

-- 按北京时间取“今日”，返回 {year,month,day}, 日期串, 目标路径
local function get_today_info()
    local t = os.date("!*t", os.time() + UTC_OFFSET)
    local date_str = string.format("%04d%02d%02d", t.year, t.month, t.day)
    return t, date_str, SAVE_DIR .. date_str .. ".jpg"
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
        if ok then return connected == true end
    end
    return false -- 无法确认时按未连接处理，避免无谓请求
end

-- 遍历 SAVE_DIR 中的 jpg 文件
local function each_jpg(callback)
    if not has_lfs then return end
    for f in lfs.dir(SAVE_DIR) do
        if f:match("%.jpg$") and lfs.attributes(SAVE_DIR .. f, "mode") == "file" then
            callback(f)
        end
    end
end

-- 只删除非今日图片（SAVE_DIR 由本插件独占，安全）
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
        logger.info("单向历: 清理旧图", removed, "张")
    end
end

-- 一次性迁移：把旧主目录里 YYYYMMDD.jpg 搬进子目录
local function migrate_legacy_files()
    if not has_lfs then return end
    util.makePath(SAVE_DIR)
    local migrated = 0
    for f in lfs.dir(LEGACY_DIR) do
        if f:match("^%d%d%d%d%d%d%d%d%.jpg$") then
            local src = LEGACY_DIR .. f
            local dst = SAVE_DIR .. f
            if file_exists(dst) then
                os.remove(src)
            elseif os.rename(src, dst) then
                migrated = migrated + 1
            else
                logger.warn("单向历: 迁移失败", src)
            end
        end
    end
    if migrated > 0 then
        logger.info("单向历: 迁移旧图", migrated, "张")
    end
end

----------------------------------------------------------------------
-- 持久化
----------------------------------------------------------------------

local function get_last_auto_date()
    if G_reader_settings then
        return G_reader_settings:readSetting(SETTING_LAST_DATE)
    end
end

local function set_last_auto_date(date_str)
    if G_reader_settings then
        G_reader_settings:saveSetting(SETTING_LAST_DATE, date_str)
    end
end

local function is_auto_screensaver_enabled()
    if not G_reader_settings then return true end
    local v = G_reader_settings:readSetting(SETTING_AUTO_SCREENSAVER)
    return v == nil or v == true -- 首次安装默认开启
end

local function set_auto_screensaver_enabled(enabled)
    if G_reader_settings then
        G_reader_settings:saveSetting(SETTING_AUTO_SCREENSAVER, enabled)
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
        return gettext("HTTP 错误: ") .. status:sub(6)
    end
    return gettext("错误: ") .. tostring(status)
end

----------------------------------------------------------------------
-- 下载（tmp + 校验 + 原子替换）
----------------------------------------------------------------------

local function download_image(year, month, day, date_str)
    local url = build_url(year, month, day)
    local target = SAVE_DIR .. date_str .. ".jpg"
    local tmp = target .. ".tmp"

    logger.info("单向历: 下载", url)
    os.remove(tmp)

    local file, err = io.open(tmp, "wb")
    if not file then
        logger.warn("单向历: 无法创建临时文件", tostring(err))
        return false, "open_error"
    end

    local ok, code = http.request{
        url = url,
        headers = {
            ["Referer"]    = "https://img.owspace.com/",
            ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader)",
        },
        sink = ltn12.sink.file(file),
        redirect = true,
        timeout = HTTP_TIMEOUT,
    }
    safe_close_file(file)

    if not ok then
        logger.warn("单向历: 网络错误", tostring(code))
        os.remove(tmp)
        return false, "network_error"
    end
    if code ~= 200 then
        logger.warn("单向历: HTTP", tostring(code))
        os.remove(tmp)
        return false, "http_" .. tostring(code)
    end
    if not is_valid_jpeg(tmp) then
        logger.warn("单向历: 文件校验失败")
        os.remove(tmp)
        return false, "invalid_file"
    end

    os.remove(target)
    local renamed, rerr = os.rename(tmp, target)
    if not renamed then
        logger.warn("单向历: 重命名失败", tostring(rerr))
        os.remove(tmp)
        return false, "rename_error"
    end

    logger.info("单向历: 完成", target)
    return true, "ok"
end

----------------------------------------------------------------------
-- 插件主体
----------------------------------------------------------------------

function DanXiangLi:init()
    self.ui.menu:registerToMainMenu(self)
    self._busy = false
    self._loop_scheduled = false
    self._suspended = false
    self._last_status = nil
    self._http404_until = nil

    util.makePath(SAVE_DIR)
    migrate_legacy_files()
    self:_ensure_screensaver_settings()

    self:_install_resume_hook()
    UIManager:scheduleIn(INIT_DELAY, function() self:_run() end)
    self:_schedule_loop()
end

-- 自动配置屏保；首次配置前保存原值，关闭开关时恢复
function DanXiangLi:_ensure_screensaver_settings()
    if not G_reader_settings then return end
    if not is_auto_screensaver_enabled() then return end

    if not self._orig_ss_settings then
        self._orig_ss_settings = {
            type        = G_reader_settings:readSetting("screensaver_type"),
            dir         = G_reader_settings:readSetting("screensaver_dir"),
            stretch     = G_reader_settings:readSetting("screensaver_stretch_images"),
            show_msg    = G_reader_settings:readSetting("screensaver_show_message"),
        }
    end

    local changed = false
    if G_reader_settings:readSetting("screensaver_type") ~= "random_image" then
        G_reader_settings:saveSetting("screensaver_type", "random_image")
        changed = true
    end
    if G_reader_settings:readSetting("screensaver_dir") ~= SAVE_DIR then
        G_reader_settings:saveSetting("screensaver_dir", SAVE_DIR)
        changed = true
    end
    -- 正确键名是 screensaver_stretch_images：不拉伸时图按比例缩放，
    -- 与屏幕宽高比不一致会留下两侧黑边，故必须开启
    if not G_reader_settings:isTrue("screensaver_stretch_images") then
        G_reader_settings:saveSetting("screensaver_stretch_images", true)
        changed = true
    end
    -- 壁纸上不覆盖 “Sleeping” 文字
    if G_reader_settings:isTrue("screensaver_show_message") then
        G_reader_settings:saveSetting("screensaver_show_message", false)
        changed = true
    end

    if changed then
        G_reader_settings:flush()
        logger.info("单向历: 屏保设置已自动配置")
    end
end

function DanXiangLi:_restore_screensaver_settings()
    if not G_reader_settings or not self._orig_ss_settings then return end
    local o = self._orig_ss_settings
    self._orig_ss_settings = nil

    local function restore(key, value)
        if value == nil then
            G_reader_settings:delSetting(key)
        else
            G_reader_settings:saveSetting(key, value)
        end
    end
    restore("screensaver_type", o.type)
    restore("screensaver_dir", o.dir)
    restore("screensaver_stretch_images", o.stretch)
    restore("screensaver_show_message", o.show_msg)
    G_reader_settings:flush()
    logger.info("单向历: 屏保设置已恢复")
end

-- Suspend/Resume 检测：KOReader 通过 UIManager:broadcastEvent 广播这两个事件
function DanXiangLi:_install_resume_hook()
    if self._hook_installed then return end
    self._hook_installed = true
    local plugin = self
    local orig = UIManager.broadcastEvent
    UIManager.broadcastEvent = function(ui, event)
        local name = event and event.handler
        if name == "Suspend" then
            plugin._suspended = true
        elseif name == "Resume" then
            plugin._suspended = false
            -- 唤醒后稍等再检查；网络未就绪会自动进入退避重试链
            UIManager:scheduleIn(RESUME_DELAY, function() plugin:_run() end)
        end
        return orig(ui, event)
    end
end

-- Wi-Fi 是否开启（与“是否已拿到 IP”分开判断）
function DanXiangLi:_wifi_on()
    if NetworkMgr and NetworkMgr.isWifiOn then
        local ok, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
        if ok then return on == true end
    end
    return true -- 无法确认时按开启处理，交给重试上限兜底
end

-- 周期兜底检查（自我重排的单链，无重复调度）
function DanXiangLi:_schedule_loop()
    if self._loop_scheduled then return end
    self._loop_scheduled = true
    UIManager:scheduleIn(CHECK_INTERVAL, function()
        self._loop_scheduled = false
        self:_run()
        self:_schedule_loop()
    end)
end

-- 失败后的退避重试：Wi-Fi 关闭即停；正在重连则等比退避等待
function DanXiangLi:_schedule_retry(attempt, opts)
    if attempt >= MAX_RETRIES then
        self._last_status = self._last_status or "network_error"
        logger.warn("单向历: 重试耗尽，放弃")
        return
    end
    local delay = math.min(RETRY_BASE * 2 ^ attempt, RETRY_MAX)
    UIManager:scheduleIn(delay, function()
        self:_retry_round(attempt + 1, opts)
    end)
end

function DanXiangLi:_retry_round(attempt, opts)
    if self._busy then return end
    if not self:_wifi_on() then
        logger.dbg("单向历: Wi-Fi 关闭，停止重试")
        self._last_status = "no_network"
        return
    end
    if not is_network_available() then
        self:_schedule_retry(attempt, opts) -- 仍在重连，继续等
        return
    end

    self._busy = true
    local t, today_str, today_path = get_today_info()
    local success, status = download_image(t.year, t.month, t.day, today_str)
    self._busy = false
    self._last_status = status

    if success then
        cleanup_old_images(today_str)
        set_last_auto_date(today_str)
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = gettext("单向历已更新"), timeout = 2 })
        end
    elseif status == "http_404" then
        self._http404_until = os.time() + HTTP404_COOLDOWN
    else
        self:_schedule_retry(attempt, opts)
    end
end

-- 主入口：图片已存在走快速路径；缺失则下载；失败自动进入重试链
function DanXiangLi:_run(opts)
    if self._busy then
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = gettext("单向历任务进行中…"), timeout = 2 })
        end
        return
    end

    util.makePath(SAVE_DIR)
    local t, today_str, today_path = get_today_info()

    -- 今日图确认未发布后，冷却期内不再打服务器
    if self._http404_until and os.time() < self._http404_until then
        logger.dbg("单向历: 今日图未发布，冷却中，跳过")
        return
    end

    -- 快速路径：今日图已就绪，只需跨天记日期 + 清理旧图
    if is_valid_jpeg(today_path) then
        if get_last_auto_date() ~= today_str then
            set_last_auto_date(today_str)
        end
        cleanup_old_images(today_str)
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = gettext("今日单向历已存在"), timeout = 2 })
        end
        return
    end

    if not is_network_available() then
        if self:_wifi_on() then
            self:_schedule_retry(0, opts) -- Wi-Fi 开着但还没拿到 IP：等待重连
        else
            self._last_status = "no_network"
            if opts and opts.notify then
                UIManager:show(InfoMessage:new{ text = gettext("无网络连接"), timeout = 3 })
            end
        end
        return
    end

    self._busy = true
    local success, status = download_image(t.year, t.month, t.day, today_str)
    self._busy = false
    self._last_status = status

    if success then
        cleanup_old_images(today_str)
        set_last_auto_date(today_str)
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = gettext("单向历已更新"), timeout = 2 })
        end
    elseif status == "http_404" then
        self._http404_until = os.time() + HTTP404_COOLDOWN
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = gettext("今日图片未发布 (404)"), timeout = 3 })
        end
    else
        self:_schedule_retry(0, opts)
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = status_text(status), timeout = 3 })
        end
    end
end

function DanXiangLi:force_redownload()
    if self._busy then
        UIManager:show(InfoMessage:new{ text = gettext("单向历任务进行中…"), timeout = 2 })
        return
    end
    local _, _, today_path = get_today_info()
    os.remove(today_path)
    self._http404_until = nil
    self:_run{ notify = true }
end

----------------------------------------------------------------------
-- 诊断
----------------------------------------------------------------------

function DanXiangLi:_diagnostics()
    local _, today_str, today_path = get_today_info()
    local lines = {}
    lines[#lines + 1] = gettext("目录: ") .. SAVE_DIR
    if is_valid_jpeg(today_path) then
        lines[#lines + 1] = gettext("今日图片: 已就绪 (") .. today_str .. ")"
    elseif file_exists(today_path) then
        lines[#lines + 1] = gettext("今日图片: 文件损坏")
    else
        lines[#lines + 1] = gettext("今日图片: 未下载")
    end
    lines[#lines + 1] = gettext("最近状态: ") .. tostring(self._last_status or "-")
    lines[#lines + 1] = gettext("网络: ") .. (is_network_available() and gettext("已连接") or gettext("未连接"))
    if G_reader_settings then
        lines[#lines + 1] = gettext("屏保类型: ") .. tostring(G_reader_settings:readSetting("screensaver_type"))
        lines[#lines + 1] = gettext("屏保目录: ") .. tostring(G_reader_settings:readSetting("screensaver_dir"))
        lines[#lines + 1] = gettext("拉伸填充: ") .. tostring(G_reader_settings:isTrue("screensaver_stretch_images"))
    end
    lines[#lines + 1] = gettext("自动配置: ") .. (is_auto_screensaver_enabled() and gettext("开") or gettext("关"))
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- 菜单
----------------------------------------------------------------------

function DanXiangLi:addToMainMenu(menu_items)
    menu_items.danxiangli = {
        text = gettext("单向历"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = gettext("自动配置屏保"),
                checked_func = function() return is_auto_screensaver_enabled() end,
                callback = function()
                    local enabled = not is_auto_screensaver_enabled()
                    set_auto_screensaver_enabled(enabled)
                    if enabled then
                        self:_ensure_screensaver_settings()
                        UIManager:show(InfoMessage:new{
                            text = gettext("已启用自动配置屏保"),
                            timeout = 3,
                        })
                    else
                        self:_restore_screensaver_settings()
                        UIManager:show(InfoMessage:new{
                            text = gettext("已停用，屏保设置已恢复"),
                            timeout = 3,
                        })
                    end
                end,
            },
            {
                text = gettext("下载今日单向历"),
                callback = function() self:_run{ notify = true } end,
            },
            {
                text = gettext("强制重新下载今日"),
                callback = function() self:force_redownload() end,
            },
            {
                text = gettext("诊断"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = self:_diagnostics(),
                        timeout = 12,
                    })
                end,
            },
        },
    }
    return menu_items
end

return DanXiangLi
