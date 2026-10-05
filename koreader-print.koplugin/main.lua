--[[--
Send KOReader documents and text to a network printer, either directly over
IPP or through a small HTTP print bridge (the optional converter, which
converts the payload and hands it to CUPS on a Raspberry Pi or any Linux
host, so it works with any printer CUPS can drive).

Behavior:

* The printer's capabilities are queried before every job and the plugin
  reacts to what is advertised. Written for and tested against an Epson
  ET-2850 (from KOReader on a Kindle Paperwhite 5); other models are expected
  to work because nothing is hard-coded, but they are untested.
* Plain text (typed, clipboard, or highlighted) is never submitted to a
  printer that does not advertise text/plain. It goes through the converter
  when one is configured; otherwise the plugin explains that text needs the
  converter instead of sending a job that will not print.
* application/octet-stream is best-effort only: the printer has to guess the
  file type, so the plugin labels it as best-effort and never substitutes it
  automatically.
* The chosen print options (paper size, color mode, sides, copies) are
  checked against what the printer advertises, and substitutions are
  reported.
* The detected MIME type, a short result summary, the printer's job state
  (accepted, processing, completed, aborted, or canceled), and the reported
  page count are always shown. Page counts are provisional until the printer
  reports completion, and "completed" only means the printer finished the
  job, not that paper physically came out.
* After the printer accepts a job, its status is polled briefly, so
  processing, completed, and aborted states are reported accurately instead
  of relying on a single check.
* Jobs are never resubmitted automatically. If a status is ambiguous or a
  job was aborted, the plugin explains what is known and offers an explicit
  retry or conversion action.

@module koplugin.koreader_print
--]]--

local Device = require("device")
local ButtonSelector = require("ui/widget/buttonselector")
local ConfirmBox = require("ui/widget/confirmbox")
local PathChooser = require("ui/widget/pathchooser")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local https_ok, https = pcall(require, "ssl.https")
if not https_ok then https = nil end
local ltn12 = require("ltn12")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

-- No printer is configured out of the box: the user enters the printer's own
-- IPP address under Printer settings before the first print.

-- How long to keep checking a job after the printer accepts it. A JPEG test
-- can still be reported as "processing" right after the printer reports one
-- impression, so the plugin polls for up to JOB_POLL_INTERVAL *
-- JOB_POLL_ATTEMPTS seconds before giving up on a final answer.
local JOB_POLL_INTERVAL = 2
local JOB_POLL_ATTEMPTS = 8

-- Formats that typically print only after conversion. Used to tailor the
-- guidance; the actual decision always comes from the printer's own
-- advertised document-format-supported list.
local CONVERTER_ONLY_FORMATS = {
    ["application/pdf"] = true,
    ["application/epub+zip"] = true,
    ["text/plain"] = true,
}

-- Printers commonly advertise application/octet-stream, but that is
-- best-effort only: the printer has to guess the file type, so jobs sent
-- that way may not print. The plugin labels it as best-effort and never
-- substitutes it automatically.
local OCTET_STREAM_FORMAT = "application/octet-stream"

-- Small known-good JPEG shipped next to this file and used by the print test.
local TEST_IMAGE_FILE = "print-test.jpg"

-- Printer attributes queried before each job: document formats, media, color
-- mode, sides, and the supported copies range.
local CAPABILITY_ATTRIBUTES = {
    "document-format-supported",
    "document-format-default",
    "media-supported",
    "media-default",
    "print-color-mode-supported",
    "print-color-mode-default",
    "sides-supported",
    "sides-default",
    "copies-supported",
}

local PrintBridge = WidgetContainer:extend{
    name = "koreader_print",
    settings_key = "koreader_print",
}

local function trim(value)
    return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function join_url(base, path)
    return trim(base):gsub("/+$", "") .. path
end

local function file_size(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

local function extension(path)
    return (path:match("%.([^./]+)$") or ""):lower()
end

local function is_ipp_url(url)
    return url ~= nil and (
        url:match("^ipp://")
        or url:match("^ipps://")
        or url:match("/ipp/")
        or url:match("^http://[^/]+:631/")
        or url:match("^https://[^/]+:631/")
    )
end

local function pack_u16(value)
    value = math.max(0, math.floor(value))
    return string.char(
        math.floor(value / 256) % 256,
        value % 256
    )
end

local function pack_u32(value)
    value = math.max(0, math.floor(value))
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
    )
end

local function ipp_string_attribute(value_tag, name, value)
    return string.char(value_tag)
        .. pack_u16(#name) .. name
        .. pack_u16(#value) .. value
end

local function ipp_integer_attribute(name, value)
    return string.char(0x21)
        .. pack_u16(#name) .. name
        .. pack_u16(4) .. pack_u32(value)
end

local function ipp_range_attribute(name, first_page, last_page)
    -- RFC 8011 rangeOfInteger: value length 8, two 32-bit integers. Sending a
    -- shorter value can make a strict printer reject the whole Print-Job.
    return string.char(0x33)
        .. pack_u16(#name) .. name
        .. pack_u16(8) .. pack_u32(first_page) .. pack_u32(last_page)
end

local function read_u16(value, offset)
    local high, low = value:byte(offset, offset + 1)
    if not low then return nil end
    return high * 256 + low
end

local function ipp_status_message(code)
    local messages = {
        [0x0400] = _("bad request: the printer could not understand the request"),
        [0x0401] = _("forbidden"),
        [0x0402] = _("not authenticated"),
        [0x0403] = _("not authorized"),
        [0x0404] = _("operation not possible"),
        [0x040A] = _("document format not supported"),
        [0x040B] = _("print option not supported"),
        [0x040E] = _("conflicting print options"),
        [0x0500] = _("printer internal error"),
        [0x0501] = _("operation not supported"),
        [0x0502] = _("printer service unavailable"),
        [0x0504] = _("printer device error"),
        [0x0505] = _("temporary printer error"),
        [0x0506] = _("printer is not accepting jobs"),
        [0x0507] = _("printer is busy"),
    }
    return messages[code]
end

-- Actionable guidance for the IPP status codes printers commonly return.
local function ipp_status_hint(code)
    if code == 0x040A then
        return _("The printer does not accept this document format. PDF, EPUB, Markdown, and plain text need the optional converter.")
    elseif code == 0x040B or code == 0x040E then
        return _("The printer did not accept the print options. Try again with fewer options, for example a single copy on Letter paper.")
    elseif code == 0x0506 or code == 0x0507 then
        return _("The printer is not accepting jobs right now. Check its display, clear any error, and try again.")
    elseif code == 0x0500 or code == 0x0504 or code == 0x0505 then
        return _("The printer reported an internal error. Check its display, power-cycle it, and try again.")
    end
    return nil
end

-- Human-readable label for a document MIME type, e.g. "JPEG image (image/jpeg)".
local function format_label(document_format)
    local label
    if document_format == "application/pdf" then
        label = _("PDF")
    elseif document_format == "image/jpeg" then
        label = _("JPEG image")
    elseif document_format == "image/png" then
        label = _("PNG image")
    elseif document_format == "image/webp" then
        label = _("WebP image")
    elseif document_format == "image/bmp" then
        label = _("BMP image")
    elseif document_format == "text/plain" then
        label = _("plain text")
    elseif document_format == OCTET_STREAM_FORMAT then
        label = _("automatic format detection (best-effort)")
    end
    if label then
        return label .. " (" .. document_format .. ")"
    end
    return document_format
end

-- IPP job states: 3 pending, 4 pending-held, 5 processing, 6 processing-
-- stopped, 7 canceled, 8 aborted, 9 completed.
local function job_state_label(state)
    if state == nil then
        return _("unknown")
    elseif state == 3 then
        return _("accepted (pending)")
    elseif state == 4 then
        return _("accepted (held until the printer is ready)")
    elseif state == 5 then
        return _("processing")
    elseif state == 6 then
        return _("processing (stopped)")
    elseif state == 7 then
        return _("canceled")
    elseif state == 8 then
        return _("aborted")
    elseif state == 9 then
        return _("completed")
    end
    return string.format(_("unknown state (%d)"), state)
end

local function job_state_is_final(state)
    return state == 7 or state == 8 or state == 9
end

-- Short job-state word used in the one-line summary.
local function job_state_short(state)
    if state == 3 or state == 4 then return _("accepted")
    elseif state == 5 or state == 6 then return _("processing")
    elseif state == 7 then return _("canceled")
    elseif state == 8 then return _("aborted")
    elseif state == 9 then return _("completed") end
    return _("unknown")
end

local function media_label(value)
    if value == "na_letter" or value == "na_letter_8.5x11in" then return _("Letter") end
    if value == "iso_a4_210x297mm" or value == "iso_a4_210x297" then return _("A4") end
    return value or _("default")
end

local function color_mode_label(value)
    if value == "monochrome" then return _("black and white") end
    if value == "color" then return _("color") end
    return value or _("default")
end

local function sides_label(value)
    if value == "one-sided" then return _("single-sided") end
    if value == "two-sided-long-edge" then return _("double-sided") end
    if value == "two-sided-short-edge" then return _("double-sided (short edge)") end
    return value or _("default")
end

-- One-line result summary: job number, format sent, printer status, page count.
local function job_summary_line(job, job_id, status)
    local pages
    if status and status.impressions_completed ~= nil then
        pages = string.format(_("%d page(s)"), status.impressions_completed)
    else
        pages = _("no page count")
    end
    return string.format(_("Summary — job #%d · %s · %s · %s."),
        job_id, job.format_label, job_state_short(status and status.state), pages)
end

-- Translate IPP job-state-reasons tokens into plain language.
local function job_reason_label(reason)
    if reason == "document-unprintable-error" then
        return _("the printer could not render the document")
    elseif reason == "document-format-error" or reason == "unsupported-document-format" then
        return _("the document format was rejected")
    elseif reason == "document-access-error" then
        return _("the printer could not read the document")
    elseif reason == "compression-error" then
        return _("the printer could not decompress the document")
    elseif reason == "job-canceled-by-user" then
        return _("the job was canceled by a user")
    elseif reason == "job-canceled-at-device" then
        return _("the job was canceled at the printer")
    elseif reason == "job-canceled-by-operator" then
        return _("the job was canceled by the printer operator")
    elseif reason == "aborted-by-system" then
        return _("the printer aborted the job")
    elseif reason == "printer-stopped" then
        return _("the printer is stopped")
    elseif reason == "media-needed" then
        return _("the printer needs paper")
    elseif reason == "resources-are-not-ready" then
        return _("printer resources are not ready")
    elseif reason == "service-off-line" then
        return _("the printer is offline")
    elseif reason == "job-incoming" then
        return _("the printer is still receiving the job")
    elseif reason == "queued-in-device" then
        return _("the job is queued in the printer")
    elseif reason == "processing-to-stop-point" then
        return _("the printer is finishing the current page")
    end
    return reason
end

-- Next steps for the failure reasons the printer reports most often.
local function job_reason_next_steps(reason)
    if reason == "document-unprintable-error" or reason == "document-format-error"
        or reason == "unsupported-document-format" or reason == "document-access-error" then
        return _("Next step: the printer could not print this format. PDF, EPUB, Markdown, and plain text usually need the optional converter; configure it and print again, or send a JPEG image.")
    elseif reason == "media-needed" then
        return _("Next step: load paper in the printer and print again.")
    elseif reason == "printer-stopped" or reason == "service-off-line" or reason == "resources-are-not-ready" then
        return _("Next step: check the printer's display, clear the error, and print again.")
    elseif reason == "compression-error" then
        return _("Next step: send the file again; if it keeps failing, convert it with the optional converter first.")
    end
    return nil
end

local function ipp_job_id(response)
    local offset = 9 -- IPP header is eight bytes.
    local current_name
    while offset <= #response do
        local value_tag = response:byte(offset)
        offset = offset + 1
        if value_tag == 0x03 then break end
        if value_tag < 0x10 then
            current_name = nil
        else
            local name_length = read_u16(response, offset)
            if not name_length then return nil end
            offset = offset + 2
            if name_length > 0 then
                current_name = response:sub(offset, offset + name_length - 1)
                offset = offset + name_length
            end
            local value_length = read_u16(response, offset)
            if not value_length then return nil end
            offset = offset + 2
            if current_name == "job-id" and value_tag == 0x21 and value_length == 4 then
                local a, b, c, d = response:byte(offset, offset + 3)
                if not d then return nil end
                return a * 16777216 + b * 65536 + c * 256 + d
            end
            offset = offset + value_length
        end
    end
    return nil
end

local function ipp_document_format(path)
    local ext = extension(path)
    if ext == "pdf" then return "application/pdf" end
    if ext == "png" then return "image/png" end
    if ext == "jpg" or ext == "jpeg" then return "image/jpeg" end
    if ext == "webp" then return "image/webp" end
    if ext == "bmp" then return "image/bmp" end
    return "text/plain"
end

local function ipp_get_printer_attributes_request(printer_uri)
    local attributes = {
        string.char(0x01),
        ipp_string_attribute(0x47, "attributes-charset", "utf-8"),
        ipp_string_attribute(0x48, "attributes-natural-language", "en"),
        ipp_string_attribute(0x45, "printer-uri", printer_uri),
    }
    local first = true
    for _, name in ipairs(CAPABILITY_ATTRIBUTES) do
        attributes[#attributes + 1] = ipp_string_attribute(
            0x44, first and "requested-attributes" or "", name)
        first = false
    end
    attributes[#attributes + 1] = string.char(0x03)
    return string.char(0x01, 0x01)
        .. pack_u16(0x000B)
        .. pack_u32(os.time() % 2147483647)
        .. table.concat(attributes)
end

local function ipp_get_job_status_request(printer_uri, job_id)
    local requested_attributes = ipp_string_attribute(0x44, "requested-attributes", "job-state")
    for _, name in ipairs({ "job-state-reasons", "job-state-message", "job-impressions-completed" }) do
        requested_attributes = requested_attributes
            .. string.char(0x44) .. pack_u16(0) .. pack_u16(#name) .. name
    end
    local attributes = {
        string.char(0x01),
        ipp_string_attribute(0x47, "attributes-charset", "utf-8"),
        ipp_string_attribute(0x48, "attributes-natural-language", "en"),
        ipp_string_attribute(0x45, "printer-uri", printer_uri),
        ipp_integer_attribute("job-id", job_id),
        requested_attributes,
        string.char(0x03),
    }
    return string.char(0x01, 0x01)
        .. pack_u16(0x0009)
        .. pack_u32(os.time() % 2147483647)
        .. table.concat(attributes)
end

-- Parse an IPP response into a flat, in-order list of attributes. Multi-valued
-- attributes repeat the name for the first value and use an empty name for the
-- following values, which the callers handle.
local function ipp_parse_attributes(response)
    local entries = {}
    local offset = 9 -- IPP header is eight bytes.
    local current_name
    while offset <= #response do
        local value_tag = response:byte(offset)
        offset = offset + 1
        if value_tag == 0x03 then break end
        if value_tag < 0x10 then
            current_name = nil
        else
            local name_length = read_u16(response, offset)
            if not name_length then break end
            offset = offset + 2
            if name_length > 0 then
                current_name = response:sub(offset, offset + name_length - 1)
                offset = offset + name_length
            end
            local value_length = read_u16(response, offset)
            if not value_length then break end
            offset = offset + 2
            local raw = response:sub(offset, offset + value_length - 1)
            offset = offset + value_length
            entries[#entries + 1] = { name = current_name, tag = value_tag, raw = raw }
        end
    end
    return entries
end

local function ipp_integer_value(entry)
    if entry.tag == 0x21 and #entry.raw == 4 then
        local a, b, c, d = entry.raw:byte(1, 4)
        return a * 16777216 + b * 65536 + c * 256 + d
    end
    return nil
end

local function ipp_range_value(entry)
    if entry.tag ~= 0x33 then return nil end
    -- RFC 8011 rangeOfInteger is two 4-byte integers; tolerate the 2x2-byte
    -- form some printers use.
    if #entry.raw == 8 then
        local a, b, c, d = entry.raw:byte(1, 4)
        local e, f, g, h = entry.raw:byte(5, 8)
        return a * 16777216 + b * 65536 + c * 256 + d,
            e * 16777216 + f * 65536 + g * 256 + h
    elseif #entry.raw == 4 then
        return read_u16(entry.raw, 1), read_u16(entry.raw, 3)
    end
    return nil
end

local function ipp_parse_job_status(response)
    local status = { reasons = {} }
    local offset = 9 -- IPP header is eight bytes.
    local current_name
    while offset <= #response do
        local value_tag = response:byte(offset)
        offset = offset + 1
        if value_tag == 0x03 then break end
        if value_tag < 0x10 then
            current_name = nil
        else
            local name_length = read_u16(response, offset)
            if not name_length then break end
            offset = offset + 2
            if name_length > 0 then
                current_name = response:sub(offset, offset + name_length - 1)
                offset = offset + name_length
            end
            local value_length = read_u16(response, offset)
            if not value_length then break end
            offset = offset + 2
            local value = response:sub(offset, offset + value_length - 1)
            if current_name == "job-state" and value_tag == 0x23 and value_length == 4 then
                local a, b, c, d = value:byte(1, 4)
                status.state = a * 16777216 + b * 65536 + c * 256 + d
            elseif current_name == "job-state-reasons" then
                status.reasons[#status.reasons + 1] = value
            elseif current_name == "job-state-message" then
                status.message = value
            elseif current_name == "job-impressions-completed" and value_tag == 0x21 and value_length == 4 then
                local a, b, c, d = value:byte(1, 4)
                status.impressions_completed = a * 16777216 + b * 65536 + c * 256 + d
            end
            offset = offset + value_length
        end
    end
    if status.state then return status end
    return nil
end

local function unsupported_format_message(document_format, formats)
    local supported = {}
    local advertises_octet_stream = false
    for format in pairs(formats) do
        supported[#supported + 1] = format
        if format == OCTET_STREAM_FORMAT then
            advertises_octet_stream = true
        end
    end
    table.sort(supported)
    local message = string.format(
        _("This printer does not accept %s. It advertises: %s."),
        format_label(document_format),
        table.concat(supported, ", ")
    )
    if advertises_octet_stream then
        message = message .. "\n\n" .. _("application/octet-stream is best-effort only: the printer has to guess the file type, so the plugin does not send it as a fallback.")
    end
    if CONVERTER_ONLY_FORMATS[document_format] then
        message = message .. "\n\n" .. _("PDF, EPUB, Markdown, and plain text are usually not accepted directly by IPP printers; they need the optional converter.")
    else
        message = message .. "\n\n" .. _("Convert the file with the optional converter, or print it as a JPEG image.")
    end
    return message
end

local function ipp_printer_uri(target_url)
    local uri = target_url:gsub("^http://", "ipp://"):gsub("^https://", "ipps://")
    return uri
end

local function ipp_http_url(target_url)
    local protocol, rest = target_url:match("^(ipp)://(.*)$")
    if not protocol then
        protocol, rest = target_url:match("^(ipps)://(.*)$")
    end
    if not protocol then return target_url end

    local authority, path = rest:match("^([^/]+)(.*)$")
    if not authority then return target_url end
    local has_port
    if authority:sub(1, 1) == "[" then
        local close_bracket = authority:find("]", 2, true)
        has_port = close_bracket
            and authority:sub(close_bracket + 1, close_bracket + 1) == ":"
            and authority:sub(close_bracket + 2):match("^%d+$") ~= nil
    else
        has_port = authority:match(":%d+$") ~= nil
    end
    if not has_port then
        authority = authority .. ":631"
    end
    local http_protocol = protocol == "ipps" and "https" or "http"
    return http_protocol .. "://" .. authority .. path
end

local function ipp_page_ranges(value)
    if not value or value == "" then return "" end
    local attributes = {}
    local first = true
    for range in value:gmatch("[^,]+") do
        local start_page, end_page = range:match("^%s*(%d+)%s*%-%s*(%d+)%s*$")
        if not start_page then
            start_page = range:match("^%s*(%d+)%s*$")
            end_page = start_page
        end
        if start_page and end_page then
            table.insert(attributes, ipp_range_attribute(
                first and "page-ranges" or "",
                tonumber(start_page),
                tonumber(end_page)
            ))
            first = false
        end
    end
    return table.concat(attributes)
end

local function valid_page_ranges(value)
    if not value or trim(value) == "" then return true end
    for item in (value .. ","):gmatch("(.-),") do
        item = trim(item)
        local first_page, last_page = item:match("^(%d+)%s*%-%s*(%d+)$")
        if not first_page then
            first_page = item:match("^(%d+)$")
            last_page = first_page
        end
        first_page = tonumber(first_page)
        last_page = tonumber(last_page)
        if not first_page or not last_page
            or first_page < 1 or last_page < first_page or last_page > 65535 then
            return false
        end
    end
    return true
end

function PrintBridge:init()
    self.settings = G_reader_settings:readSetting(self.settings_key, {})
    if self.document and self.ui.highlight then
        self:addToHighlightDialog()
    end
    self.ui.menu:registerToMainMenu(self)
end

function PrintBridge:getPrinterUrl()
    local settings = self.settings or {}
    -- `or nil`: keeps the result nil (not false) when nothing is configured.
    return settings.printer_url
        or (is_ipp_url(settings.target_url) and settings.target_url)
        or nil
end

function PrintBridge:getBridgeUrl()
    local settings = self.settings or {}
    return settings.converter_url
        or (settings.target_url and not is_ipp_url(settings.target_url) and settings.target_url)
        or settings.bridge_url
        or nil
end

function PrintBridge:hasPrinterTarget()
    local url = self:getPrinterUrl()
    return url ~= nil and url ~= ""
end

function PrintBridge:hasConverterTarget()
    local url = self:getBridgeUrl()
    return url ~= nil and url ~= ""
end

function PrintBridge:isDirectPrinter(url)
    url = url or self:getPrinterUrl() or ""
    return is_ipp_url(url)
end

function PrintBridge:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
    })
end

function PrintBridge:showSettings()
    local dialog
    dialog = InputDialog:new{
        title = _("Direct printer IPP address"),
        input = self:getPrinterUrl() or "",
        input_hint = _("https://printer:631/ipp/print"),
        input_type = "string",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = trim(dialog:getInputText())
                        if value == "" then
                            self:showMessage(_("Enter the printer IPP address."))
                            return
                        end
                        self.settings.printer_url = value:gsub("/+$", "")
                        G_reader_settings:saveSetting(self.settings_key, self.settings)
                        UIManager:close(dialog)
                        self:showMessage(_("Printer address saved."), 3)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function PrintBridge:showConverterSettings()
    local dialog
    dialog = InputDialog:new{
        title = _("Optional format converter"),
        input = self:getBridgeUrl() or "",
        input_hint = _("http://BRIDGE-HOST-OR-IP:8787 (leave blank to skip)"),
        input_type = "string",
        buttons = {
            {
                {
                    text = _("Skip"),
                    callback = function()
                        self.settings.converter_url = nil
                        self.settings.bridge_url = nil
                        G_reader_settings:saveSetting(self.settings_key, self.settings)
                        UIManager:close(dialog)
                        self:showMessage(_("Converter disabled. Direct printing is ready."), 3)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = trim(dialog:getInputText())
                        self.settings.converter_url = value ~= "" and value:gsub("/+$", "") or nil
                        self.settings.bridge_url = nil
                        G_reader_settings:saveSetting(self.settings_key, self.settings)
                        UIManager:close(dialog)
                        self:showMessage(_("Converter address saved."), 3)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function PrintBridge:sendRequest(request)
    local headers = request.headers or {}
    headers["Content-Length"] = tostring(request.content_length or 0)
    headers["Content-Type"] = request.content_type or "application/octet-stream"
    headers["X-KOReader-Print"] = "1"

    local request_options = {
        url = request.url,
        method = "POST",
        headers = headers,
        source = request.source,
    }
    local transport = http
    if request.url:match("^https://") then
        if not https then
            return false, _("HTTPS support is unavailable in this KOReader build.")
        end
        transport = https
        -- Many home printers use a local self-signed certificate. KOReader
        -- devices may not have a CA store, so encrypt the local connection
        -- without requiring public certificate validation.
        request_options.protocol = "any"
        request_options.options = { "all", "no_sslv2", "no_sslv3" }
        request_options.verify = "none"
    end

    local response = {}
    request_options.sink = ltn12.sink.table(response)
    local ok, _request_result, status, response_headers, status_line = pcall(transport.request, request_options)

    if not ok then
        local detail = tostring(_request_result)
        logger.err("KOReader Print request failed", detail)
        return false, _("Could not connect to the printer or print bridge.") .. " (" .. detail .. ")"
    end

    local response_body = table.concat(response)
    local status_number = tonumber(status)
    if status_number == 426 and request.url:match("^http://") then
        local secure_url = request.url:gsub("^http://", "https://")
        return false, _("Printer requires encrypted IPP. Change its address in Printer settings to: ") .. secure_url
    end
    if not status_number or status_number < 200 or status_number >= 300 then
        logger.warn("KOReader Print Bridge request failed", status_line or status, response_body)
        local detail = status_line or tostring(status or _("No response"))
        if response_body ~= "" then
            detail = detail .. ": " .. response_body:sub(1, 240)
        end
        return false, detail
    end
    if request.content_type == "application/ipp" then
        if #response_body < 8 then
            return false, _("The printer returned an incomplete IPP response.")
        end
        local ipp_status = read_u16(response_body, 3)
        if ipp_status >= 0x0100 then
            local detail = ipp_status_message(ipp_status) or _("printer rejected the request")
            return false, string.format("IPP 0x%04X: %s", ipp_status, detail)
        end
        return true, response_body, response_headers, ipp_job_id(response_body)
    end
    return true, response_body, response_headers
end

-- Query the printer's capabilities. This runs before every job (no cache), so
-- the plugin reacts when the printer's reported support changes.
function PrintBridge:getPrinterCapabilities(url, printer_uri)
    local body = ipp_get_printer_attributes_request(printer_uri)
    local ok, response = self:sendRequest{
        url = url,
        content_length = #body,
        content_type = "application/ipp",
        headers = {
            ["Accept"] = "application/ipp",
        },
        source = ltn12.source.string(body),
    }
    if not ok then return nil end
    return self:parseCapabilities(response)
end

-- Build a capabilities table from a Get-Printer-Attributes response.
function PrintBridge:parseCapabilities(response)
    local caps = {
        formats = {},
        media_supported = {},
        color_supported = {},
        sides_supported = {},
    }
    for _, entry in ipairs(ipp_parse_attributes(response)) do
        local name = entry.name
        if name == "document-format-supported" then
            caps.formats[entry.raw] = true
        elseif name == "document-format-default" then
            caps.format_default = entry.raw
        elseif name == "media-supported" then
            caps.media_supported[entry.raw] = true
        elseif name == "media-default" then
            caps.media_default = entry.raw
        elseif name == "print-color-mode-supported" then
            caps.color_supported[entry.raw] = true
        elseif name == "print-color-mode-default" then
            caps.color_default = entry.raw
        elseif name == "sides-supported" then
            caps.sides_supported[entry.raw] = true
        elseif name == "sides-default" then
            caps.sides_default = entry.raw
        elseif name == "copies-supported" then
            local min_copies, max_copies = ipp_range_value(entry)
            if min_copies then
                caps.copies_min = min_copies
                caps.copies_max = max_copies
            end
        end
    end
    if not next(caps.formats) and not next(caps.media_supported)
        and not next(caps.color_supported) and not next(caps.sides_supported) then
        return nil
    end
    return caps
end

-- Kept for callers that only need the advertised document formats.
function PrintBridge:getPrinterDocumentFormats(url, printer_uri)
    local caps = self:getPrinterCapabilities(url, printer_uri)
    if caps and next(caps.formats) then
        return caps.formats
    end
    return nil
end

-- Pick the media keyword the printer actually advertises. Some IPP printers
-- list only the PWG-qualified name (na_letter_8.5x11in) while others list
-- the short one (na_letter); translate between them, otherwise send the
-- value as-is.
function PrintBridge:resolveMedia(value, caps)
    value = value or "na_letter"
    local media_supported = caps and caps.media_supported
    if media_supported and next(media_supported) then
        if media_supported[value] then return value end
        if value == "na_letter" and media_supported["na_letter_8.5x11in"] then
            return "na_letter_8.5x11in"
        end
        if value == "na_letter_8.5x11in" and media_supported["na_letter"] then
            return "na_letter"
        end
    end
    -- Fallback when the printer did not report media support: many IPP
    -- endpoints expect the PWG-qualified Letter name.
    if value == "na_letter" then return "na_letter_8.5x11in" end
    return value
end

-- Compare the chosen print options with what the printer advertises. Returns
-- the options to send plus notes describing any substitution.
function PrintBridge:checkPrintOptions(options, caps)
    local notes = {}
    local effective = {
        media = options.media,
        color = options.color,
        sides = options.sides,
        copies = options.copies,
    }
    if not caps then
        notes[#notes + 1] = _("The printer did not report which print options it supports, so the options are sent as requested (best-effort).")
        return effective, notes
    end
    -- A partially populated capabilities table must never crash the checks.
    caps.media_supported = caps.media_supported or {}
    caps.color_supported = caps.color_supported or {}
    caps.sides_supported = caps.sides_supported or {}
    if next(caps.media_supported) then
        local wanted = effective.media or "na_letter"
        local supported = caps.media_supported[wanted]
            or (wanted == "na_letter" and caps.media_supported["na_letter_8.5x11in"])
        if not supported then
            local chosen = caps.media_default
            if not chosen or not caps.media_supported[chosen] then
                for name in pairs(caps.media_supported) do chosen = name break end
            end
            if chosen then
                notes[#notes + 1] = string.format(
                    _("Paper size %s is not supported by the printer; using %s instead."),
                    media_label(wanted), media_label(chosen))
                effective.media = chosen
            end
        end
    end
    if effective.color and next(caps.color_supported) and not caps.color_supported[effective.color] then
        local chosen = caps.color_default
        if not chosen or not caps.color_supported[chosen] then
            for name in pairs(caps.color_supported) do chosen = name break end
        end
        if chosen then
            notes[#notes + 1] = string.format(
                _("Color mode %s is not supported by the printer; using %s instead."),
                color_mode_label(effective.color), color_mode_label(chosen))
            effective.color = chosen
        end
    end
    if effective.sides and next(caps.sides_supported) and not caps.sides_supported[effective.sides] then
        local chosen = caps.sides_default
        if not chosen or not caps.sides_supported[chosen] then
            for name in pairs(caps.sides_supported) do chosen = name break end
        end
        if chosen then
            notes[#notes + 1] = string.format(
                _("Sides %s is not supported by the printer; using %s instead."),
                sides_label(effective.sides), sides_label(chosen))
            effective.sides = chosen
        end
    end
    if caps.copies_max and effective.copies then
        local min_copies = caps.copies_min or 1
        if effective.copies < min_copies or effective.copies > caps.copies_max then
            local clamped = math.max(min_copies, math.min(effective.copies, caps.copies_max))
            notes[#notes + 1] = string.format(
                _("Copies %d is outside the printer's supported range (%d-%d); using %d."),
                effective.copies, min_copies, caps.copies_max, clamped)
            effective.copies = clamped
        end
    end
    return effective, notes
end

-- Describe, from reported capabilities, what prints directly and what needs
-- the converter. Used by the capabilities menu and by guidance messages.
function PrintBridge:directPrintSummary(caps)
    local formats = caps.formats or {}
    local direct = {}
    for _, format in ipairs({ "image/jpeg", "image/png", "image/webp", "image/bmp" }) do
        if formats[format] then
            direct[#direct + 1] = format
        end
    end
    local needs_conversion = {}
    if not formats["application/pdf"] then
        needs_conversion[#needs_conversion + 1] = _("PDF")
    end
    if not formats["text/plain"] then
        needs_conversion[#needs_conversion + 1] = _("plain text")
    end
    needs_conversion[#needs_conversion + 1] = _("Markdown and EPUB")
    local lines = {}
    lines[#lines + 1] = string.format(_("Prints directly: %s."),
        #direct > 0 and table.concat(direct, ", ") or _("nothing — the converter is required"))
    lines[#lines + 1] = string.format(_("Needs the converter: %s."), table.concat(needs_conversion, ", "))
    return table.concat(lines, "\n")
end

function PrintBridge:getPrinterJobStatus(url, printer_uri, job_id)
    local body = ipp_get_job_status_request(printer_uri, job_id)
    local ok, response = self:sendRequest{
        url = url,
        content_length = #body,
        content_type = "application/ipp",
        headers = {
            ["Accept"] = "application/ipp",
        },
        source = ltn12.source.string(body),
    }
    if not ok then return nil end
    return ipp_parse_job_status(response)
end

-- Build an accurate, plain-language report of what the printer reported for
-- one job. An IPP job state is the printer's own report: "accepted" and
-- "processing" do not mean a page printed, and "completed" only means the
-- printer finished the job, not that paper physically came out.
function PrintBridge:buildJobStatusReport(job, job_id, status, attempts)
    local lines = { job_summary_line(job, job_id, status) }
    for _, note in ipairs(job.option_notes or {}) do
        lines[#lines + 1] = "Note: " .. note
    end
    if not status then
        lines[#lines + 1] = string.format(
            _("The printer accepted the job, but its status could not be read after %d check(s): whether anything printed is unknown."),
            attempts)
        lines[#lines + 1] = _("Do not send another copy yet: the job may still be running. Check the printer's queue, display, and output tray first.")
        return table.concat(lines, "\n")
    end

    if status.state == 9 then
        lines[#lines + 1] = _("Printer state: completed — the printer reports the job as finished.")
    elseif status.state == 8 then
        lines[#lines + 1] = _("Printer state: aborted — the printer stopped this job.")
    elseif status.state == 7 then
        lines[#lines + 1] = _("Printer state: canceled — this job was canceled.")
    elseif status.state == 5 or status.state == 6 then
        lines[#lines + 1] = _("Printer state: processing — the printer started the job but has not finished it, so a printed page cannot be assumed yet.")
    elseif status.state == 3 or status.state == 4 then
        lines[#lines + 1] = _("Printer state: accepted — the printer has the job but has not started printing it.")
    else
        lines[#lines + 1] = string.format(_("Printer state: %s."), job_state_label(status.state))
    end

    if status.impressions_completed ~= nil then
        if status.state == 9 then
            lines[#lines + 1] = string.format(_("Pages counted by the printer: %d."), status.impressions_completed)
        elseif status.state == 8 or status.state == 7 then
            lines[#lines + 1] = string.format(_("Pages counted before the job stopped: %d."), status.impressions_completed)
        else
            lines[#lines + 1] = string.format(_("Impressions counted so far: %d (not final — the job has not completed)."), status.impressions_completed)
        end
    else
        lines[#lines + 1] = _("Pages counted by the printer: no page count was returned.")
    end

    if #status.reasons > 0 then
        local reasons = {}
        for _, reason in ipairs(status.reasons) do
            reasons[#reasons + 1] = job_reason_label(reason) .. " (" .. reason .. ")"
        end
        lines[#lines + 1] = string.format(_("Printer reasons: %s."), table.concat(reasons, "; "))
    end

    if status.state == 9 then
        if status.impressions_completed and status.impressions_completed > 0 then
            lines[#lines + 1] = _("Completion is the printer's own report of finishing the job; check the output tray to confirm the pages came out.")
        elseif status.impressions_completed == 0 then
            lines[#lines + 1] = _("The printer completed the job but counted zero pages, so nothing may have printed. Check the printer's display and queue.")
        else
            lines[#lines + 1] = _("The printer completed the job without returning a page count, so physical output cannot be confirmed. Check the output tray.")
        end
    elseif status.state == 8 or status.state == 7 then
        local steps = {}
        for _, reason in ipairs(status.reasons) do
            local step = job_reason_next_steps(reason)
            if step then
                steps[#steps + 1] = step
            end
        end
        if #steps == 0 then
            steps[#steps + 1] = _("Check the printer's display and queue, then print again. If this was a PDF, EPUB, Markdown, or plain-text job, it may need the optional converter.")
        end
        lines[#lines + 1] = table.concat(steps, "\n")
    elseif status.state == 3 or status.state == 4 then
        lines[#lines + 1] = string.format(
            _("The printer has not started this job after %d check(s). Do not send another copy yet; check the printer's queue and display."),
            attempts)
    elseif status.state == 5 or status.state == 6 then
        lines[#lines + 1] = string.format(
            _("The job is still processing after %d check(s) and has not completed, so no printed page can be assumed yet. Check the printer's queue in a moment, and do not send another copy."),
            attempts)
    else
        lines[#lines + 1] = string.format(
            _("The printer reported an unrecognized state (%s) after %d check(s), so whether anything printed is unknown. Do not send another copy yet; check the printer's queue and display."),
            job_state_label(status.state), attempts)
    end
    return table.concat(lines, "\n")
end

function PrintBridge:jobReasonsIndicateFormatFailure(status)
    if not status then return false end
    for _, reason in ipairs(status.reasons) do
        if reason == "document-unprintable-error"
            or reason == "document-format-error"
            or reason == "unsupported-document-format" then
            return true
        end
    end
    return false
end

-- Check the job a few times before reporting the final result, so a job that
-- is still processing gets a chance to complete or abort.
function PrintBridge:pollDirectJobStatus(job, http_url, printer_uri, job_id, attempt)
    local status = self:getPrinterJobStatus(http_url, printer_uri, job_id)
    if not (status and job_state_is_final(status.state)) and attempt < JOB_POLL_ATTEMPTS then
        UIManager:scheduleIn(JOB_POLL_INTERVAL, function()
            self:pollDirectJobStatus(job, http_url, printer_uri, job_id, attempt + 1)
        end)
        return
    end
    local report = self:buildJobStatusReport(job, job_id, status, attempt)
    if status and (status.state == 8 or status.state == 7) then
        -- The job was accepted, so the printer may already have printed part
        -- of it; only the user can decide to retry or convert.
        self:offerAfterAbort(job, report, status)
    else
        self:showMessage(report)
    end
end

-- Send one document directly to the printer over IPP. The job table carries
-- the payload (path or bytes), the detected MIME type, and a label:
--
--   job.path / job.bytes, job.name, job.document_format, job.format_label,
--   job.options
--
-- The printer's advertised formats are checked first; jobs in a format the
-- printer does not accept offer the converter instead of being submitted.
-- application/octet-stream is never substituted automatically.
function PrintBridge:sendDirectJob(job)
    local target_url = self:getPrinterUrl()
    if not target_url or target_url == "" then
        self:showMessage(_("Set the printer's IPP address first, under Print > Printer settings."))
        return
    end
    local http_url = ipp_http_url(target_url)
    local printer_uri = ipp_printer_uri(target_url)
    job.options = job.options or {}
    job.format_label = job.format_label or format_label(job.document_format)
    if job.path then
        job.size = file_size(job.path)
        if not job.size then
            self:showMessage(_("Unable to read the selected file."))
            return
        end
    else
        job.size = #(job.bytes or "")
    end

    self:showMessage(_("Contacting the printer…"), 1)
    NetworkMgr:runWhenConnected(function()
        local caps = self:getPrinterCapabilities(http_url, printer_uri)
        if caps and next(caps.formats or {}) and not caps.formats[job.document_format] then
            self:convertInstead(job, caps.formats)
            return
        end
        self:submitDirectJob(job, caps, http_url, printer_uri)
    end)
end

function PrintBridge:submitDirectJob(job, caps, http_url, printer_uri)
    local options = job.options or {}
    -- Check the chosen options against the printer's reported support, and note
    -- any substitution in the job report.
    local effective, notes = self:checkPrintOptions(options, caps)
    job.option_notes = notes
    local job_name = job.job_name or job.name or "KOReader document"
    local attributes = {
        string.char(0x01),
        ipp_string_attribute(0x47, "attributes-charset", "utf-8"),
        ipp_string_attribute(0x48, "attributes-natural-language", "en"),
        ipp_string_attribute(0x45, "printer-uri", printer_uri),
        ipp_string_attribute(0x42, "requesting-user-name", "koreader"),
        ipp_string_attribute(0x49, "document-format", job.document_format),
        string.char(0x02),
        -- Send both job-name and document-name: some printers label queued
        -- jobs from document-name, which is why a bare job can show "untitled".
        ipp_string_attribute(0x42, "job-name", job_name),
        ipp_string_attribute(0x42, "document-name", job_name),
        ipp_string_attribute(0x44, "media", self:resolveMedia(effective.media or "na_letter", caps)),
        ipp_string_attribute(0x44, "print-color-mode", effective.color or "color"),
        ipp_string_attribute(0x44, "sides", effective.sides or "one-sided"),
        ipp_integer_attribute("copies", effective.copies or 1),
        ipp_page_ranges(options.page_ranges),
        string.char(0x03),
    }
    local ipp_header = string.char(0x01, 0x01)
        .. pack_u16(0x0002)
        .. pack_u32(os.time() % 2147483647)
        .. table.concat(attributes)

    local file
    if job.path then
        file = io.open(job.path, "rb")
        if not file then
            self:showMessage(_("Unable to open the selected file."))
            return
        end
    end
    local body_source = file and ltn12.source.file(file) or ltn12.source.string(job.bytes or "")
    local sent_header = false
    local function source()
        if not sent_header then
            sent_header = true
            return ipp_header
        end
        return body_source()
    end

    self:showMessage(string.format(_("Sending %s to the printer…"), job.format_label), 1)
    local ok, message, _response_headers, job_id = self:sendRequest{
        url = http_url,
        content_length = #ipp_header + job.size,
        content_type = "application/ipp",
        headers = {
            ["Accept"] = "application/ipp",
        },
        source = source,
    }
    if file then
        pcall(function() file:close() end)
    end

    if ok then
        self:announceAcceptedJob(job, http_url, printer_uri, job_id)
    elseif message and message:find("IPP 0x040A", 1, true) then
        -- The printer refused the format without accepting a job, so offering
        -- the converter here cannot create a duplicate printout.
        self:convertInstead(job, nil, string.format(
            _("The printer rejected %s (IPP 0x040A: document format not supported)."), job.format_label))
    else
        local text = string.format(_("Direct print failed: %s"), tostring(message))
        local code = message and tonumber(message:match("IPP 0x(%x+)"), 16)
        local hint = code and ipp_status_hint(code)
        if hint then
            text = text .. "\n\n" .. hint
        end
        self:showMessage(text)
    end
end

-- The printer accepted the job; report what is known immediately, then poll
-- briefly so processing/completed/aborted states are reported accurately.
function PrintBridge:announceAcceptedJob(job, http_url, printer_uri, job_id)
    if not job_id then
        self:showMessage(string.format(
            _("The printer accepted this job (%s) but did not return a job ID, so its status cannot be checked. Do not send another copy yet: check the printer's queue, display, and output tray."),
            job.format_label))
        return
    end
    local lines = {
        string.format(_("The printer accepted job #%d (sent as %s), but accepted does not mean printed; checking its status…"), job_id, job.format_label),
    }
    if job.document_format == "image/jpeg" then
        lines[#lines + 1] = _("The printer advertises image/jpeg, but advertised support does not guarantee that every JPEG file will print; the job report will show what the printer actually did.")
    end
    self:showMessage(table.concat(lines, "\n"), 3)
    UIManager:scheduleIn(JOB_POLL_INTERVAL, function()
        self:pollDirectJobStatus(job, http_url, printer_uri, job_id, 1)
    end)
end

-- A descriptive name for the currently open document, used as the print job
-- name so queues show something meaningful instead of "untitled".
function PrintBridge:documentDisplayName()
    local file = self.document and self.document.file
    if file then
        local base = file:match("([^/]+)$")
        if base then
            local title = base:gsub("%.[^%.]*$", "")
            if trim(title) ~= "" then
                return title
            end
        end
    end
    return _("KOReader document")
end

-- Show the printer's reported capabilities and what that means for printing:
-- which formats print directly and which need the converter. Runs a fresh
-- capability query instead of relying on remembered values.
function PrintBridge:showPrinterCapabilities()
    if not self:hasPrinterTarget() then
        self:showMessage(_("No printer IPP address is set yet. Enter one under Print > Printer settings."))
        return
    end
    if not self:isDirectPrinter() then
        self:showMessage(_("Direct-print capabilities are only available for a printer IPP address; the converter endpoint does not report them."))
        return
    end
    local target_url = self:getPrinterUrl()
    local http_url = ipp_http_url(target_url)
    local printer_uri = ipp_printer_uri(target_url)
    self:showMessage(_("Checking the printer's capabilities…"), 1)
    NetworkMgr:runWhenConnected(function()
        local caps = self:getPrinterCapabilities(http_url, printer_uri)
        if not caps then
            self:showMessage(_("The printer did not report any capabilities. Check the printer's IPP address and that it is powered on."))
            return
        end
        local function sorted_keys(set)
            local keys = {}
            for name in pairs(set) do keys[#keys + 1] = name end
            table.sort(keys)
            return keys
        end
        local lines = {
            string.format(_("Printer capabilities for %s:"), target_url),
        }
        local formats = sorted_keys(caps.formats)
        lines[#lines + 1] = string.format(_("Formats the printer accepts: %s."),
            #formats > 0 and table.concat(formats, ", ") or _("none reported"))
        if next(caps.media_supported) then
            lines[#lines + 1] = string.format(_("Paper sizes: %s."), table.concat(sorted_keys(caps.media_supported), ", "))
        end
        if next(caps.color_supported) then
            lines[#lines + 1] = string.format(_("Color modes: %s."), table.concat(sorted_keys(caps.color_supported), ", "))
        end
        if next(caps.sides_supported) then
            lines[#lines + 1] = string.format(_("Sides: %s."), table.concat(sorted_keys(caps.sides_supported), ", "))
        end
        if caps.copies_max then
            lines[#lines + 1] = string.format(_("Copies: %d-%d."), caps.copies_min or 1, caps.copies_max)
        end
        if caps.formats[OCTET_STREAM_FORMAT] then
            lines[#lines + 1] = _("application/octet-stream is advertised, but it is best-effort: the printer guesses the file type, so the plugin does not use it as a fallback.")
        end
        lines[#lines + 1] = self:directPrintSummary(caps)
        self:showMessage(table.concat(lines, "\n"))
    end)
end

function PrintBridge:sendDirectFile(path, options, job_name)
    self:sendDirectJob{
        path = path,
        name = path:match("([^/]+)$") or "KOReader document",
        job_name = job_name,
        document_format = ipp_document_format(path),
        options = options or {},
    }
end

-- Send text straight to the printer as text/plain. This path is only used
-- when the printer advertises text/plain support. Many printers reject it,
-- so typed text goes through the converter instead (see sendText).
function PrintBridge:sendDirectText(text, title, options, job_name)
    self:sendDirectJob{
        bytes = text or "",
        name = title or "koreader-text.txt",
        job_name = job_name,
        document_format = "text/plain",
        options = options or {},
    }
end

-- A job that was refused before the printer accepted it cannot duplicate a
-- printout, so when a converter is configured the file is converted and
-- printed right away (with an explanation). Without a converter the user is
-- offered the setup instead.
function PrintBridge:convertInstead(job, formats, context_text)
    local details = context_text
    if not details and formats then
        details = unsupported_format_message(job.document_format, formats)
    end
    details = details or _("The printer cannot print this document directly.")
    if self:hasConverterTarget() then
        -- Conversion is the automatic happy path here, so say what is
        -- happening now instead of what failed, and let the submission
        -- confirmation close the loop (see sendFileViaBridge/sendTextViaBridge).
        self:showMessage(string.format(
            _("This printer cannot print %s directly; converting it with the converter and printing it now…"),
            format_label(job.document_format)), 3)
        self:resubmitViaConverter(job)
    else
        self:offerConverterSetup(details)
    end
end

function PrintBridge:offerConverterSetup(details)
    UIManager:show(ConfirmBox:new{
        text = details .. "\n\n" .. _("Set up the optional converter to print this file type (PDF, EPUB, Markdown, and plain text usually need it), or print the file as a JPEG image."),
        ok_text = _("Set up converter"),
        ok_callback = function()
            self:showConverterSettings()
        end,
        cancel_text = _("Cancel"),
    })
end

-- After a job was accepted and then aborted or canceled, the printer may
-- already have printed part of it, so a retry stays a user decision. Format
-- problems also offer the converter. Nothing is ever resubmitted silently.
function PrintBridge:offerAfterAbort(job, report, status)
    local retry = function()
        self:showMessage(_("Retrying the same job at the printer…"), 2)
        self:sendDirectJob(job)
    end
    local format_failure = self:jobReasonsIndicateFormatFailure(status)
    if format_failure and self:hasConverterTarget() then
        UIManager:show(ConfirmBox:new{
            text = report .. "\n\n" .. _("This looks like a format problem. Convert it with the optional converter and print again, or retry the same job (only if nothing was printed)."),
            ok_text = _("Convert & print"),
            ok_callback = function()
                self:resubmitViaConverter(job)
            end,
            other_buttons = { { { text = _("Retry"), callback = retry } } },
            cancel_text = _("Cancel"),
        })
    elseif format_failure then
        UIManager:show(ConfirmBox:new{
            text = report .. "\n\n" .. _("This looks like a format problem. Set up the optional converter to print this type, or retry the same job (only if nothing was printed)."),
            ok_text = _("Set up converter"),
            ok_callback = function()
                self:showConverterSettings()
            end,
            other_buttons = { { { text = _("Retry"), callback = retry } } },
            cancel_text = _("Cancel"),
        })
    else
        UIManager:show(ConfirmBox:new{
            text = report .. "\n\n" .. _("Retry this job now? Only do this if nothing was printed, so a page is not duplicated."),
            ok_text = _("Retry"),
            ok_callback = retry,
            cancel_text = _("Cancel"),
        })
    end
end

function PrintBridge:resubmitViaConverter(job)
    if job.path then
        self:sendFileViaBridge(job.path, job.options or {}, true)
    else
        self:sendTextViaBridge(job.bytes or "", job.name, job.options or {}, true)
    end
end

-- via_converter marks jobs that reached the bridge through the automatic
-- conversion path, so the success message can say the file was converted and
-- is printing, instead of a bare "submitted" that reads like the earlier
-- "not supported" explanation was the final word.
function PrintBridge:sendFileViaBridge(path, options, via_converter)
    if not self:hasConverterTarget() then
        self:showMessage(_("This file format is not supported by the printer directly. Set up the optional converter, or choose a printer-supported format."))
        return
    end
    local size = file_size(path)
    if not size then
        self:showMessage(_("Unable to read the selected file."))
        return
    end

    local name = path:match("([^/]+)$") or "document"
    local ext = extension(path)
    local url = join_url(self:getBridgeUrl(), "/v1/print/file")
    local headers = {
        ["X-File-Name"] = name,
        ["X-File-Type"] = ext,
    }
    if options then
        if options.page_ranges and options.page_ranges ~= "" then
            headers["X-Page-Ranges"] = options.page_ranges
        end
        if options.color then
            headers["X-Color"] = options.color
        end
        if options.sides then
            headers["X-Sides"] = options.sides
        end
        if options.media then
            headers["X-Media"] = options.media
        end
        if options.copies then
            headers["X-Copies"] = tostring(options.copies)
        end
    end

    self:showMessage(_("Sending to printer…"), 1)
    NetworkMgr:runWhenConnected(function()
        local file = io.open(path, "rb")
        if not file then
            self:showMessage(_("Unable to open the selected file."))
            return
        end
        local ok, message = self:sendRequest{
            url = url,
            headers = headers,
            content_length = size,
            content_type = "application/octet-stream",
            source = ltn12.source.file(file),
        }
        pcall(function() file:close() end)
        if ok then
            if via_converter then
                self:showMessage(string.format(
                    _("Converted and sent: %s is now printing via the converter."), name), 3)
            else
                self:showMessage(_("Print job submitted."), 2)
            end
        else
            self:showMessage(_("Print failed: ") .. message)
        end
    end)
end

function PrintBridge:sendFile(path, options, job_name)
    if not self:hasPrinterTarget() and not self:hasConverterTarget() then
        self:showMessage(_("Nothing is set up to print yet. Enter the printer's IPP address under Print > Printer settings, or a converter address."))
        return
    end
    if self:isDirectPrinter() then
        local ext = extension(path)
        if ext == "txt" or ext == "md" or ext == "markdown" then
            -- Text files print through the converter when one is configured:
            -- it renders them as PDF instead of the printer guessing
            -- text/plain.
            if self:hasConverterTarget() then
                self:showMessage(_("Text files print through the converter. Converting and printing now…"), 3)
                self:sendFileViaBridge(path, options or {}, true)
                return
            end
        end
        if ext == "pdf" or ext == "png" or ext == "jpg" or ext == "jpeg"
            or ext == "webp" or ext == "bmp" or ext == "txt"
            or ext == "md" or ext == "markdown" then
            self:sendDirectFile(path, options or {}, job_name)
            return
        end
        if not self:hasConverterTarget() then
            self:showMessage(_("This file format needs the optional converter."))
            return
        end
    end
    self:sendFileViaBridge(path, options)
end

function PrintBridge:sendTextViaBridge(text, title, options, via_converter)
    if not self:hasConverterTarget() then
        self:showMessage(_("The printer does not accept plain text (text/plain) directly. Set up the optional converter under Print > Optional format converter to print text."))
        return
    end
    local url = join_url(self:getBridgeUrl(), "/v1/print/text")
    local body = text
    local headers = {
        ["X-File-Name"] = title or "koreader-clipboard.txt",
        ["X-File-Type"] = "text",
    }
    if options then
        if options.color then
            headers["X-Color"] = options.color
        end
        if options.sides then
            headers["X-Sides"] = options.sides
        end
        if options.media then
            headers["X-Media"] = options.media
        end
        if options.copies then
            headers["X-Copies"] = tostring(options.copies)
        end
    end
    self:showMessage(_("Sending text to printer…"), 1)
    NetworkMgr:runWhenConnected(function()
        local ok, message = self:sendRequest{
            url = url,
            headers = headers,
            content_length = #body,
            content_type = "text/plain; charset=utf-8",
            source = ltn12.source.string(body),
        }
        if ok then
            if via_converter then
                self:showMessage(string.format(
                    _("Converted and sent: %s is now printing via the converter."), title), 3)
            else
                self:showMessage(_("Print job submitted."), 2)
            end
        else
            self:showMessage(_("Print failed: ") .. message)
        end
    end)
end

-- Send typed, clipboard, or highlighted text.
--
-- Text is never submitted as text/plain to a printer that does not advertise
-- it. With a converter configured the text is converted first; otherwise the
-- plugin explains that text needs the converter instead of sending a job that
-- will not print.
function PrintBridge:sendText(text, title, options, job_name)
    text = text or ""
    title = title or "koreader-text.txt"
    options = options or {}
    if trim(text) == "" then
        self:showMessage(_("There is no text to print."))
        return
    end
    if not self:hasPrinterTarget() and not self:hasConverterTarget() then
        self:showMessage(_("Nothing is set up to print yet. Enter the printer's IPP address under Print > Printer settings, or a converter address."))
        return
    end
    if self:hasConverterTarget() then
        self:showMessage(_("Typed text prints through the converter. Converting and printing now…"), 3)
        self:sendTextViaBridge(text, title, options, true)
        return
    end
    if not self:isDirectPrinter() then
        self:sendTextViaBridge(text, title, options)
        return
    end
    local target_url = self:getPrinterUrl()
    local http_url = ipp_http_url(target_url)
    local printer_uri = ipp_printer_uri(target_url)
    NetworkMgr:runWhenConnected(function()
        local caps = self:getPrinterCapabilities(http_url, printer_uri)
        local formats = caps and next(caps.formats or {}) and caps.formats or nil
        if formats and formats["text/plain"] then
            self:sendDirectText(text, title, options, job_name)
        elseif formats then
            self:convertInstead({
                bytes = text,
                name = title,
                job_name = job_name,
                document_format = "text/plain",
                options = options,
            }, formats)
        else
            -- The printer's formats could not be read. Plain text is the most
            -- commonly unsupported format, so it is never submitted directly
            -- here: offer the converter instead of a job that may not print.
            self:offerConverterSetup(_("The printer's advertised formats could not be read, so typed text is not sent to it directly. Many printers reject plain text (text/plain) over IPP."))
        end
    end)
end

function PrintBridge:getTestImagePath()
    if not self.path then return nil end
    return self.path .. "/" .. TEST_IMAGE_FILE
end

-- Print a small known-good JPEG. This separates connection or printer
-- problems (the test page does not come out) from unsupported document
-- formats (the test page prints, but PDF/text documents do not).
function PrintBridge:printTestPage()
    local path = self:getTestImagePath()
    if not path or not file_size(path) then
        self:showMessage(_("The JPEG test image is missing from the plugin folder. Copy the whole koreader-print.koplugin folder, including print-test.jpg, and restart KOReader."))
        return
    end
    local options = self:getSavedPrintOptions()
    options.copies = 1
    options.page_ranges = nil
    UIManager:show(ConfirmBox:new{
        text = _("Print a small JPEG test page? It checks the connection and the printer itself with the image/jpeg format, which most printers accept over IPP.\n\nIf this page prints but documents do not, the connection is fine and those documents need the optional converter."),
        ok_text = _("Print test page"),
        ok_callback = function()
            if self:isDirectPrinter() then
                self:sendDirectJob{
                    path = path,
                    name = TEST_IMAGE_FILE,
                    job_name = _("KOReader print test (JPEG)"),
                    document_format = "image/jpeg",
                    format_label = _("JPEG test image") .. " (image/jpeg)",
                    options = options,
                }
            elseif self:hasConverterTarget() then
                self:showMessage(_("Sending the JPEG test page through the converter…"), 2)
                self:sendFileViaBridge(path, options)
            else
                self:showMessage(_("Set the printer address (or the optional converter) before printing a test page."))
            end
        end,
        cancel_text = _("Cancel"),
    })
end

function PrintBridge:chooseOption(title, values, current_value, callback)
    UIManager:show(ButtonSelector:new{
        title = title,
        values = values,
        current_value = current_value,
        -- ButtonSelector normally skips the callback when the already checked
        -- value is tapped. Continue the print flow even for that selection.
        apply_current_value = true,
        callback = callback,
    })
end

function PrintBridge:savePrintOptions(options)
    self.settings.print_options = {
        color = options.color,
        sides = options.sides,
        media = options.media,
        copies = options.copies,
    }
    G_reader_settings:saveSetting(self.settings_key, self.settings)
end

function PrintBridge:getSavedPrintOptions()
    local saved = self.settings.print_options or {}
    return {
        color = saved.color or "color",
        sides = saved.sides or "one-sided",
        media = saved.media or "na_letter",
        copies = saved.copies or 1,
    }
end

function PrintBridge:askForCopies(options, callback)
    local dialog
    dialog = InputDialog:new{
        title = _("Copies"),
        input = tostring(options.copies or 1),
        input_hint = _("Enter 1–99"),
        input_type = "number",
        allow_newline = false,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Print"),
                    callback = function()
                        local copies = tonumber(dialog:getInputText())
                        if not copies or copies < 1 or copies > 99 then
                            self:showMessage(_("Enter a number from 1 to 99."))
                            return
                        end
                        options.copies = math.floor(copies)
                        UIManager:close(dialog)
                        self:savePrintOptions(options)
                        callback(options)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function PrintBridge:showPrintOptions(page_ranges, callback)
    local options = self:getSavedPrintOptions()
    options.page_ranges = page_ranges

    self:chooseOption(_("Color mode"), {
        { _("Color"), "color" },
        { _("Black and white"), "monochrome" },
    }, options.color, function(color)
        options.color = color
        self:chooseOption(_("Sides"), {
            { _("Single-sided"), "one-sided" },
            { _("Double-sided"), "two-sided-long-edge" },
        }, options.sides, function(sides)
            options.sides = sides
            self:chooseOption(_("Paper size"), {
                { _("Letter"), "na_letter" },
                { _("A4"), "iso_a4_210x297mm" },
            }, options.media, function(media)
                options.media = media
                self:askForCopies(options, callback)
            end)
        end)
    end)
end

function PrintBridge:askForPageRanges(path, callback)
    local dialog
    local current_page = ""
    if extension(path) == "pdf" and self.ui and self.ui.getCurrentPage then
        current_page = tostring(self.ui:getCurrentPage())
    end
    dialog = InputDialog:new{
        title = _("Pages to print"),
        input = current_page,
        input_hint = _("Examples: 1-3, 7 or leave empty for all"),
        input_type = "string",
        allow_newline = false,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Print"),
                    callback = function()
                        local ranges = trim(dialog:getInputText())
                        if not valid_page_ranges(ranges) then
                            self:showMessage(_("Enter page ranges like 1-3, 7. Pages must be 1-65535 and ranges must ascend."))
                            return
                        end
                        UIManager:close(dialog)
                        callback(ranges)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function PrintBridge:askForPrintOptions(path, callback)
    local needs_page_range = path
        and (extension(path) == "pdf" or extension(path) == "epub")
    if needs_page_range then
        self:askForPageRanges(path, function(page_ranges)
            self:showPrintOptions(page_ranges, callback)
        end)
    else
        self:showPrintOptions(nil, callback)
    end
end

function PrintBridge:printCurrentDocument()
    if not self.document or not self.document.file then
        self:showMessage(_("Open a document before printing."))
        return
    end
    self:askForPrintOptions(self.document.file, function(options)
        self:sendFile(self.document.file, options, self:documentDisplayName())
    end)
end

function PrintBridge:quickPrintCurrentDocument()
    if not self.document or not self.document.file then
        self:showMessage(_("Open a document before printing."))
        return
    end
    local options = self:getSavedPrintOptions()
    self:sendFile(self.document.file, options, self:documentDisplayName())
end

function PrintBridge:printClipboard()
    if not Device:hasClipboard() then
        self:showMessage(_("Clipboard access is not available on this device."))
        return
    end
    local text = Device.input.getClipboardText()
    self:askForPrintOptions(nil, function(options)
        self:sendText(text, "koreader-clipboard.txt", options, _("KOReader clipboard text"))
    end)
end

function PrintBridge:printTypedText()
    local dialog
    dialog = InputDialog:new{
        title = _("Print text or Markdown"),
        input = "",
        input_type = "string",
        allow_newline = true,
        fullscreen = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Print"),
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        self:askForPrintOptions(nil, function(options)
                            self:sendText(text, "koreader-text.md", options, _("KOReader typed text"))
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function PrintBridge:addToHighlightDialog()
    self.ui.highlight:addToHighlightDialog("13_print_selected_text", function(highlight)
        return {
            text = _("Print selected text"),
            callback = function()
                highlight:highlightFromHoldPos()
                if not (highlight.selected_text and highlight.selected_text.text) then
                    return
                end
                local text = util.cleanupSelectedText(highlight.selected_text.text)
                self:askForPrintOptions(nil, function(options)
                    self:sendText(text, "koreader-selection.txt", options, _("KOReader selected text"))
                    highlight:onClose(true)
                end)
            end,
        }
    end)
end

-- File types the plugin can print, directly or through the converter.
local function file_filter_printable(filename)
    local lower = filename:lower()
    return lower:match("%.pdf$") or lower:match("%.epub$")
        or lower:match("%.md$") or lower:match("%.markdown$")
        or lower:match("%.txt$") or lower:match("%.html?$")
        or lower:match("%.png$") or lower:match("%.jpe?g$")
        or lower:match("%.webp$") or lower:match("%.bmp$")
end

-- Pick a file with KOReader's PathChooser, the supported picker widget: it
-- builds its own title bar and navigation and controls, and reports a chosen
-- file through onConfirm(path) (long-press a file, then Choose; on non-touch
-- devices tapping the file offers the same confirm dialog). The chooser
-- closes itself after a choice, which avoids the self/instance mix-ups a
-- hand-rolled FileChooser caused before.
function PrintBridge:chooseFile()
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or "/"
    -- Callbacks run with the chooser as self, so keep the plugin instance in
    -- an upvalue. Calling the methods on the class table (PrintBridge:) would
    -- use a table without settings and crash KOReader.
    local plugin = self
    local chooser
    chooser = PathChooser:new{
        title = true, -- PathChooser shows "Long-press file's name to choose it"
        path = home,
        select_directory = false,
        select_file = true,
        detailed_file_info = false,
        -- With a file_filter set, PathChooser itself honors it by forcing
        -- show_unsupported = false.
        file_filter = file_filter_printable,
        -- Pass an explicit button row: KOReader's Menu base class requires
        -- buttons on some released versions.
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        if chooser then UIManager:close(chooser) end
                    end,
                },
            },
        },
        onConfirm = function(path)
            plugin:askForPrintOptions(path, function(options)
                plugin:sendFile(path, options)
            end)
        end,
    }
    UIManager:show(chooser)
end

function PrintBridge:addToMainMenu(menu_items)
    menu_items.koreader_print = {
        text = _("Print"),
        -- Top-level entry in the Tools tab of the top menu (the "tools"
        -- section exists in both the reader and the file manager menus).
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Print current document"),
                enabled_func = function()
                    return self.document ~= nil
                end,
                callback = function()
                    self:printCurrentDocument()
                end,
            },
            {
                text = _("Quick print current document"),
                enabled_func = function()
                    return self.document ~= nil
                end,
                callback = function()
                    self:quickPrintCurrentDocument()
                end,
            },
            {
                text = _("Print a file"),
                callback = function()
                    self:chooseFile()
                end,
            },
            {
                text = _("Print clipboard"),
                enabled_func = function()
                    return Device:hasClipboard()
                end,
                callback = function()
                    self:printClipboard()
                end,
            },
            {
                text = _("Print typed text or Markdown"),
                callback = function()
                    self:printTypedText()
                end,
            },
            {
                text = _("Print JPEG test page"),
                callback = function()
                    self:printTestPage()
                end,
            },
            {
                text = _("Check printer capabilities"),
                callback = function()
                    self:showPrinterCapabilities()
                end,
            },
            {
                text = _("Printer settings"),
                callback = function()
                    self:showSettings()
                end,
            },
            {
                text = _("Optional format converter"),
                callback = function()
                    self:showConverterSettings()
                end,
            },
        },
    }
end

return PrintBridge
