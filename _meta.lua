local _ = require("gettext")
return {
    fullname = _("单向历下载"),
    description = _("开机自动下载当日单向历，支持手动触发，自动清理过期图片；兼容Kindle墨水屏设备"),
    author = "Your Name",
    version = "1.2",
    depends = {},
    device_support = {"Kindle"},
}