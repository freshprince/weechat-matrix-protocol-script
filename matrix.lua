-- WeeChat Matrix.org Client

--[[
 Author: xt <xt@xt.gg>
 Thanks to Ryan Huber of wee_slack.py for some ideas and inspiration.

 This script is considered alpha quality as only the bare minimal of
 functionality is in place and it is not very well tested.
]]


local json = require 'cjson'
local w = weechat

local SCRIPT_NAME = "matrix"
local SCRIPT_AUTHOR = "xt <xt@xt.gg>"
local SCRIPT_VERSION = "1"
local SCRIPT_LICENSE = "MIT"
local SCRIPT_DESC = "Matrix.org chat plugin"
local SCRIPT_COMMAND = SCRIPT_NAME

local SERVER
local STDOUT = {}
local OUT = {}
local BUFFER
local Room
local MatrixServer

local default_color = w.color('default')


local function tprint(tbl, indent, out)
    if not indent then indent = 0 end
    for k, v in pairs(tbl) do
        local formatting = string.rep("  ", indent) .. k .. ": "
        if type(v) == "table" then
            w.print(BUFFER, formatting)
            tprint(v, indent+1)
        elseif type(v) == 'boolean' then
            w.print(BUFFER, formatting .. tostring(v))
        elseif type(v) == 'userdata' then
            w.print(BUFFER, formatting .. tostring(v))
        else
            w.print(BUFFER, formatting .. v)
        end
    end
end

local function mprint(message)
    -- Print message to matrix buffer
    if type(message) == 'table' then
        tprint(message)
    else
        message = tostring(message)
        w.print(BUFFER, message)
    end
end

local function dbg(message)
    if type(message) == 'table' then
        tprint(message)
    else
        message = ("DEBUG: %s"):format(tostring(message))
        w.print(BUFFER, message)
    end
end

local function weechat_eval(text)
    local version = w.info_get('version_number', '') or 0
    if tonumber(version) >= 0x00040200 then
        return w.string_eval_expression(text,{},{},{})
    end
    return text
end

local urllib = {}
urllib.quote = function(str)
    if not str then return '' end
    if type(str) == 'number' then return str end
    return str:gsub(
    '([^%w ])',
    function (c)
        return string.format ("%%%02X", string.byte(c))
    end
    ):gsub(' ', '+')
end
urllib.urlencode = function(tbl)
    local out = {}
    for k, v in pairs(tbl) do
        table.insert(out, urllib.quote(k)..'='..urllib.quote(v))
    end
    return table.concat(out, '&')
end

local function split_args(args)
    local function_name, arg = args:match('^(.-) (.*)$')
    return function_name, arg
end

function unload()
    return w.WEECHAT_RC_OK
end

local function wconf(optionname)
    return w.config_string(w.config_get(optionname))
end

local function wcolor(optionname)
    return w.color(wconf(optionname))
end

local function format_nick(nick, is_self)
    -- Turns a nick name into a weechat-styled nickname. This means giving
    -- it colors, and proper prefix and suffix
    local color
    if is_self then
        color = w.color('chat_nick_self')
    else
        color = w.info_get('irc_nick_color', nick)
    end
    local prefix = wconf('weechat.look.nick_prefix')
    local prefix_c = wcolor('weechat.color.chat_nick_prefix')
    local suffix = wconf('weechat.look.nick_suffix')
    local suffix_c = wcolor('weechat.color.chat_nick_suffix')
    local nick_f = prefix_c .. prefix .. color .. nick .. suffix_c .. suffix
    return nick_f
end

function command_help(current_buffer, args)
    --help_cmds = { k[8:]: v.__doc__ for k, v in globals().items() if k.startswith("command_") }

    if args then
         local help_cmds = {args= help_cmds[args]}
         if not help_cmds then
             w.print("", "Command not found: " .. args)
             return
         end
    end

    for cmd, helptext in pairs(help_cmds) do
        w.print('', w.color("bold") .. cmd)
        w.print('', (helptext or 'No help text').strip())
        w.print('', '')
    end
end

function command_connect(current_buffer, args)
    if not SERVER.connected then
        SERVER:connect()
    end
    return w.WEECHAT_RC_OK
end

function matrix_command_cb(data, current_buffer, args)
    if args == 'connect' then
        return command_connect(current_buffer, arg)
    end
    --local command = cmds[function_name](current_buffer, args)
    --if not command then
    --    w.print("", "Command not found: " .. function_name)
    --end

    return w.WEECHAT_RC_OK
end

local function http(url, post, cb, timeout, extra)
    if not timeout then
        timeout = 30*1000
    end
    if not extra then
        extra = ''
    end

    local homeserver_url = w.config_get_plugin('homeserver_url')
    homeserver_url = homeserver_url .. "_matrix/client/api/v1"
    url = homeserver_url .. url
    w.hook_process_hashtable('url:' .. url, post, timeout, cb, extra)
end

function poll_cb(data, command, rc, stdout, stderr)
    if stderr ~= '' then
        mprint(('error: %s'):format(stderr))
        return w.WEECHAT_RC_OK
    end

    if stdout ~= '' then
        if not STDOUT[command] then
            STDOUT[command] = {}
        end
        table.insert(STDOUT[command], stdout)
    end

    if tonumber(rc) >= 0 then
        stdout = table.concat(STDOUT[command])
        STDOUT[command] = nil
        -- Protected call in case of JSON errors
        local success, js = pcall(json.decode, stdout)
        if not success then
            mprint(('error\t%s during json load: %s'):format(js, stdout))
            js = {}
        end
        if js['errcode'] then
            mprint(js)
        else
            SERVER.end_token = js['end']
            for _, chunk in pairs(js.chunk) do
                 if chunk.room_id then
                    local room = SERVER.rooms[chunk['room_id']]
                    if room then
                        room:parseChunk(chunk)
                    else
                        -- Chunk for non-existing room, maybe we just got 
                        -- invited, so lets create a room
                        SERVER:addRoom(chunk)
                    end
                end
            end
        end
    end
    if tonumber(rc) == -2 or tonumber(rc) >= 0 then
        if STDOUT[command] then
            STDOUT[command] = nil
        end
        SERVER.polling = false
        SERVER:poll()
    end
    return w.WEECHAT_RC_OK
end


function http_cb(data, command, rc, stdout, stderr)
    if stderr ~= '' then
        mprint(('error: %s'):format(stderr))
        return w.WEECHAT_RC_OK
    end

    if stdout ~= '' then
        if not STDOUT[command] then
            STDOUT[command] = {}
        end
        table.insert(STDOUT[command], stdout)
    end

    if tonumber(rc) >= 0 then
        stdout = table.concat(STDOUT[command])
        STDOUT[command] = nil
        -- Protected call in case of JSON errors
        local success, js = pcall(json.decode, stdout)
        if not success then
            mprint(('error\t%s during json load: %s'):format(js, stdout))
            js = {}
        end
        if js['errcode'] then
            if command:find'login' then
                w.print('', ('matrix: Error code during login: %s'):format(js['errcode']))
            else
                mprint(js)
            end
            return w.WEECHAT_RC_OK
        end
        -- Get correct handler
        if command:find('login') then
            for k, v in pairs(js) do
                SERVER[k] = v
            end
            SERVER.connected = true
            SERVER:initial_sync()
        elseif command:find'/rooms/.*/initialSync' then
            local myroom = SERVER:addRoom(js)
            for _, chunk in pairs(js['presence']) do
                myroom:parseChunk(chunk, true)
            end
            for _, chunk in pairs(js['messages']['chunk']) do
                myroom:parseChunk(chunk, true)
            end
        elseif command:find'initialSync' then
            for _, room in pairs(js['rooms']) do
                local myroom = SERVER:addRoom(room)
                local messages = room.messages
                if messages then
                    local chunks = messages.chunk or {}
                    for _, chunk in pairs(chunks) do
                        myroom:parseChunk(chunk, true)
                    end
                end
            end
            SERVER:poll()
        elseif command:find'messages' then
            dbg('command msgs returned, '.. command)
        elseif command:find'/join/' then
            -- We came from a join command, fecth some messages
            local found = false
            for id, _ in pairs(SERVER.rooms) do
                if id == js.room_id then
                    found = true
                    -- this is a false positive for example when getting
                    -- invited. need to investigate more
                    --mprint('error\tJoined room, but already in it.')
                    break
                end
            end
            if not found then
                local data = urllib.urlencode({
                    access_token= SERVER.access_token,
                    --limit= w.config_get_plugin('backlog_lines'),
                    limit = 10,
                })
                http(('/rooms/%s/initialSync?%s'):format(urllib.quote(js.room_id), data), {}, 'http_cb')
            end
        elseif command:find'leave' then
            -- We store room_id in data
            local room_id = data
            SERVER:delRoom(room_id)
        elseif command:find'upload' then
            -- We store room_id in data
            local room_id = data
            dbg(js)
            if js.content_uri then
                SERVER:msg(room_id, js.content_uri)
            end
        elseif command:find'/typing/' then
            -- either it errs or it is empty
        elseif command:find'/state/' then
            -- TODO errorcode: M_FORBIDDEN
            -- either it errs or it is empty
            --dbg({state= js})
        elseif command:find'/send/' then
            -- XXX Errorhandling 
        elseif command:find'createRoom' then
            local room_id = js.room_id
            -- We get join events, so we don't have to do anything
        else
            dbg({['error'] = 'Unknown command in http cb', command=command,
                js=js})
        end
    end
    if tonumber(rc) == -2 then
        mprint(('matrix: Call to API errored in command %s, maybe timeout?'):format(command))
    end

    return w.WEECHAT_RC_OK
end

MatrixServer = {}
MatrixServer.__index = MatrixServer

MatrixServer.create = function()
     local server = {}
     setmetatable(server, MatrixServer)
     server.nick = nil
     server.connecting = false
     server.polling = false
     server.connected = false
     server.rooms = {}
     server.end_token = 'END'
     server.typing_time = os.clock()
     -- Timer used in cased of errors to restart the polling cycle
     -- During normal operation the polling should re-invoke itself
     server.polltimer = w.hook_timer(5*1000, 0, 0, "poll", "")
     return server
end


function MatrixServer:_getPost(post)
    local extra = {
        accept_encoding= 'application/json',
        transfer= 'application/json',
        postfields= json.encode(post)
    }
    return extra
end

function MatrixServer:findRoom(buffer_ptr)
    for id, room in pairs(self.rooms) do
        if room.buffer == buffer_ptr then
            return room
        end
    end
end

function MatrixServer:connect()
    if not self.connecting then
        local user = weechat_eval(w.config_get_plugin('user'))
        local password = weechat_eval(w.config_get_plugin('password'))
        if user == '' or password == '' then
            w.print('', 'Please set your username and password using the settings system and then type /matrix connect')
            return
        end

        self.connecting = true
        w.print('', 'matrix: Connecting to homeserver URL: '..w.config_get_plugin('homeserver_url'))
        local post = {
            ["type"]="m.login.password",
            ["user"]=user,
            ["password"]=password
        }
        -- Set a short timeout so user can get more immidiate feedback
        http('/login', self:_getPost(post), 'http_cb', 5*1000)
    end
end

function MatrixServer:initial_sync()
    BUFFER = w.buffer_new("matrix", "", "", "closed_matrix_buffer_cb", "")
    w.buffer_set(BUFFER, "short_name", "matrix")
    w.buffer_set(BUFFER, "localvar_set_type", "server")
    w.buffer_set(BUFFER, "localvar_set_server", "matrix")
    --w.buffer_set(BUFFER, "display", "auto")
    local data = urllib.urlencode({
        access_token= self.access_token,
        limit= w.config_get_plugin('backlog_lines'),
    })
    http('/initialSync?'..data, {}, 'http_cb')
end

function MatrixServer:getMessages(room_id)
    local data = urllib.urlencode({
        access_token= self.access_token,
        dir = 'b',
        from = 'END',
        limit = w.config_get_plugin('backlog_lines'),
    })
    http(('/rooms/%s/messages?%s')
        :format(urllib.quote(room_id), data), {}, 'http_cb')
end

function MatrixServer:join(room)
    if not self.connected then
        --XXX'''
        return
    end

    mprint('\tJoining room '..room)
    room = urllib.quote(room)
    http('/join/' .. room,
        {postfields= "access_token="..self.access_token}, 'http_cb')
end

function MatrixServer:part(room)
    if not self.connected then
        --XXX'''
        return
    end

    local id = urllib.quote(room.identifier)
    local data = urllib.urlencode({
        access_token= self.access_token,
    })
    -- TODO: close buffer, delete data, etc
    http(('/rooms/%s/leave?%s'):format(id, data), {postfields= "{}"},
        'http_cb', 10000, room.identifier)
end

function MatrixServer:poll()
    if self.connected == false or self.polling then
        return
    end
    self.polling = true
    local data = urllib.urlencode({
        access_token= self.access_token,
        timeout= 1000*30,
        from= self.end_token
    })
    http('/events?'..data, {}, 'poll_cb')
end

function MatrixServer:addRoom(room)
    local myroom = Room.create(room)
    myroom:create_buffer()
    self.rooms[room['room_id']] = myroom
    return myroom
end

function MatrixServer:delRoom(room_id)
    for id, room in pairs(self.rooms) do
        if id == room_id then
            mprint(BUFFER, '\tLeaving room '..room.name..':'..room.server)
            room:destroy()
            self.rooms[id] = nil
            break
        end
    end
end

function MatrixServer:msg(room_id, body, msgtype)
    -- check if there's an outgoing message timer already
    self:ClearSendTimer()

    if not msgtype then
        msgtype = 'm.text'
    end

    if not OUT[room_id] then
        OUT[room_id] = {}
    end
    -- Add message to outgoing queue of messages for this room
    table.insert(OUT[room_id], {msgtype, body})

    self:StartSendTimer()
end

function MatrixServer:StartSendTimer()
    local send_delay = 200
    self.sendtimer = w.hook_timer(send_delay, 0, 1, "send", "")
end

function MatrixServer:ClearSendTimer()
    -- Clear timer if it exists
    if self.sendtimer then
        w.unhook(self.sendtimer)
    end
    self.sendtimer = nil
end

function send(data, calls)
    SERVER:ClearSendTimer()
    -- Iterate rooms
    for id, msgs in pairs(OUT) do
        -- Clear message
        OUT[id] = nil
        local body = {}
        local msgtype

        for _, msg in pairs(msgs) do
            -- last msgtype will override any other for simplicity's sake
            msgtype = msg[1]
            table.insert(body, msg[2])
        end
        body = table.concat(body, '\n')

        local data = {
            accept_encoding = 'application/json',
            transfer = 'application/json',
            postfields= {
                msgtype = msgtype,
                body = body,
        }}

        -- Support sending bold text
        if body:match('\02') then
            local inside = false
            local htmlbody = body:gsub('\02', function(c)
                if inside then
                    inside = false
                    return '</b>'
                end
                inside = true
                return '<b>'
            end)
            if not htmlbody:match('</b>') then
                htmlbody = htmlbody .. '</b>'
            end
            data.postfields.format = 'org.matrix.custom.html'
            data.postfields.formatted_body = htmlbody
            data.postfields.body = body:gsub('\02', '')
        end

        data.postfields = json.encode(data.postfields)


        http(('/rooms/%s/send/m.room.message?access_token=%s')
            :format(
              urllib.quote(id),
              urllib.quote(SERVER.access_token)
            ),
              data,
              'http_cb'
            )
    end
end

function MatrixServer:emote(room_id, body)
    self:msg(room_id, body, 'm.emote')
end

function MatrixServer:state(room_id, key, data)
    http(('/rooms/%s/state/%s?access_token=%s')
        :format(urllib.quote(room_id),
          urllib.quote(key),
          urllib.quote(self.access_token)),
        {customrequest = 'PUT',
         accept_encoding = 'application/json',
         transfer = 'application/json',
         postfields= json.encode(data),
        }, 'http_cb')
end

function MatrixServer:SendTypingNotice(room_id)
    local data = {
        typing = true,
        timeout = 4*1000
    }
    http(('/rooms/%s/typing/%s?access_token=%s')
        :format(urllib.quote(room_id),
          urllib.quote(self.user_id),
          urllib.quote(self.access_token)),
        {customrequest = 'PUT',
         accept_encoding = 'application/json',
         transfer = 'application/json',
         postfields= json.encode(data),
        }, 'http_cb')
end

function upload_cb(data, command, rc, stdout, stderr)
    if stderr ~= '' then
        mprint(('error: %s'):format(stderr))
        return w.WEECHAT_RC_OK
    end

    if stdout ~= '' then
        if not STDOUT[command] then
            STDOUT[command] = {}
        end
        table.insert(STDOUT[command], stdout)
    end

    if tonumber(rc) >= 0 then
        stdout = table.concat(STDOUT[command])
        STDOUT[command] = nil
        --- TODO improve content type detection, maybe let curl do it?
    end
end

function MatrixServer:upload(room_id, filename)
    local content_type = 'image/jpeg'
    if command:find'png' then
        content_type = 'image/png'
    end
    -- TODO:
    --local url = w.config_get_plugin('homeserver_url') ..
    --    ('_matrix/media/v1/upload?access_token=%s')
    --    :format( urllib.quote(SERVER.access_token) )
    --w.hook_process_hashtable('curl',
    --    {arg1 = '-F',
    --    arg2 = 'filedata=@'..filename
    --    }, 30*1000, 'upload_cb', room_id)
end

function MatrixServer:CreateRoom(public, alias, invites)
    local data = {}
    if alias then
        data.room_alias_name = alias
    end
    if public then
        data.visibility = 'public'
    else
        data.visibility = 'private'
    end
    if invites then
        data.invite = invites
    end
    http(('/createRoom?access_token=%s')
        :format(urllib.quote(self.access_token)),
        {customrequest = 'POST',
         accept_encoding = 'application/json',
         postfields= json.encode(data),
        }, 'http_cb')
end

function buffer_input_cb(b, buffer, data)
    for r_id, room in pairs(SERVER.rooms) do
        if buffer == room.buffer then
            SERVER:msg(r_id, data)
        end
    end
    return w.WEECHAT_RC_OK
end

Room = {}
Room.__index = Room
Room.create = function(obj)
    local room = {}
    setmetatable(room, Room)
    room.buffer = nil
    room.identifier = obj['room_id']
    room.server = 'matrix'
    room.member_count = 0
    -- We might not be a member yet
    local state_events = obj.state or {}
    for _, state in pairs(state_events) do
        if state['type'] == 'm.room.aliases' then
            local name = state['content']['aliases'][1]
            room.name, room.server = name:match('(.+):(.+)')
        end
    end
    if not room.name then
        room.name = room.identifier
    end
    room.visibility = obj.visibility
    if not obj['visibility'] then
        room.visibility = 'public'
    end

    if obj.membership == 'invite' then
        if w.config_get_plugin('autojoin_on_invite') == 'on' then
            SERVER:join(room.identifier)
        else
            mprint(('You have been invited to join room %s by %s. Type /join %s to join.'):format(room.identifier, obj.inviter, room.identifier))
        end
        room:addNick(obj.inviter)
    end

    -- Cache lines for dedup?
    room.lines = {}
    -- Cache users for presence/nicklist
    room.users = {}
    return room
end

function Room:setName(name)
    w.buffer_set(self.buffer, "short_name", self.name)
    w.buffer_set(self.buffer, "name", self.server.."."..self.name)
    -- Doesn't work
    --w.buffer_set(self.buffer, "plugin", "matrix")
    w.buffer_set(self.buffer, "full_name",
        self.server.."."..self.name)
end

function Room:topic(topic)
    SERVER:state(self.identifier, 'm.room.topic', {topic=topic})
end

function Room:upload(filename)
    SERVER:upload(self.identifier, filename)
end

function Room:msg(msg)
    SERVER:msg(self.identifier, msg)
end

function Room:emote(msg)
    SERVER:emote(self.identifier, msg)
end

function Room:SendTypingNotice()
    SERVER:SendTypingNotice(self.identifier)
end

function Room:create_buffer()
    local buffer = w.buffer_search("", ("%s.%s"):format(self.server, self.name))
    if buffer ~= '' then
        self.buffer = buffer
    else
        self.buffer = w.buffer_new(("%s.%s")
            :format(self.server, self.name), "buffer_input_cb",
            self.name, "closed_matrix_room_cb", "")
        -- Defined in weechat's irc-nick.h
        self.nicklist_group = w.nicklist_add_group(self.buffer,
                '', "999|...", "weechat.color.nicklist_group", 1)
    end
    w.buffer_set(self.buffer, "nicklist", "1")
    w.buffer_set(self.buffer, "nicklist_display_groups", "0")
    w.buffer_set(self.buffer, "localvar_set_server", self.server)
    self:setName(self.name)
end

function Room:destroy()
    w.buffer_close(self.buffer)
end

function Room:_nickListChanged()
    -- Check the user count, if it's 2 or less then we decide this buffer
    -- is a "private" one like IRC's query type
    if self.member_count == 3 then -- don't run code for every add > 2
        w.buffer_set(self.buffer, "localvar_set_type", 'channel')
    elseif self.member_count == 2 then
        -- At the point where we reach two nicks, set the buffer name to be
        -- the display name of the other guy that is not our self since it's
        -- in effect a query, but the matrix protocol doesn't have such
        -- a concept
        w.buffer_set(self.buffer, "localvar_set_type", 'private')
        w.buffer_set(self.buffer, "localvar_set_server", self.server)
        -- Check if the room name is identifier meaning we don't have a
        -- name set yet, and should try and set one
        local buffer_name = w.buffer_get_string(self.buffer, 'name')
        if buffer_name:match('^!(.-):(.-)%.(.-)$') then
            for id, name in pairs(self.users) do
                if id ~= SERVER.user_id then
                    w.buffer_set(self.buffer, "short_name", name)
                    w.buffer_set(self.buffer, "name", name)
                    w.buffer_set(self.buffer, "full_name",
                    self.server.."."..name)
                end
            end
        end
    end
end

function Room:addNick(user_id, displayname)
    if not displayname or displayname == json.null then
        displayname = user_id:match('@(.+):(.+)')
    end
    if not self.users[user_id] then
        self.users[user_id] = displayname
        self.member_count = self.member_count + 1
        local nick_c
        -- Check if this is ourselves
        if user_id == SERVER.user_id then
            w.buffer_set(self.buffer, "highlight_words", displayname)
            w.buffer_set(self.buffer, "localvar_set_nick", displayname)
            nick_c = w.color('chat_nick_self')
        else
            nick_c = w.info_get('irc_nick_color_name', displayname)
        end
        w.nicklist_add_nick(self.buffer,
            self.nicklist_group,
            displayname,
            nick_c, '', '', 1)
        self:_nickListChanged()

    end

    return displayname
end

function Room:delNick(id)
    if self.users[id] then
        self.users[id] = nil
        local nick_ptr = w.nicklist_search_nick(self.buffer, self.nicklist_group)
        if nick_ptr then
            w.nicklist_remove_nick(self.buffer,
                self.nicklist_group,
                nick_ptr)
        end
        self:_nickListChanged()
        return true
    end
end

-- Parses a chunk of json meant for a room
function Room:parseChunk(chunk, backlog)
    local taglist = {}
    local tag = function(tag)
        -- Helper function to add tags
        if type(tag) == 'table' then
            for _, t in pairs(tag) do
                taglist[t] = true
            end
        else
            taglist[tag] = true
        end
    end
    local tags = function()
        -- Helper for returning taglist for this message
        local out = {}
        for k, v in pairs(taglist) do
            table.insert(out, k)
        end
        local tagstring = table.concat(out, ',')
        return tagstring
    end
    if not backlog then
        backlog = false
    end

    if backlog then
        tag({'no_highlight','notify_none','no_log'})
    end

    local is_self = false
    -- Check if own message
    if chunk.user_id == SERVER.user_id then
        is_self = true
        tag{'no_highlight','notify_none'}
    end

    if chunk['type'] == 'm.room.message' then
        if not backlog and not is_self then
            tag'notify_message'
        end

        local time_int = chunk['origin_server_ts']/1000
        local color = default_color
        local nick_c
        local body
        local nick = self:addNick(chunk.user_id)
        if is_self then
            nick_c = w.color('chat_nick_self')
        else
            nick_c = w.info_get('irc_nick_color', nick)
        end
        local content = chunk['content']
        if not content['msgtype'] then
            -- We don't support redactions
            return
        end
        if content['msgtype'] == 'm.text' then
            body = content['body']
            -- TODO
            -- Parse HTML here:
            -- content.format = 'org.matrix.custom.html'
            -- fontent.formatted_body...
        elseif content['msgtype'] == 'm.image' then
            local url = content['url']:gsub('mxc://',
                w.config_get_plugin('homeserver_url')
                .. '_matrix/media/v1/download/')
            body = content['body'] .. ' ' .. url
        elseif content['msgtype'] == 'm.notice' then
            color = wcolor('irc.color.notice')
            body = content['body']

        elseif content['msgtype'] == 'm.emote' then
            tag"irc_action"
            local prefix = w.config_string(
                    w.config_get('weechat.look.prefix_action'))
            body = ("%s%s %s%s"):format(
                nick_c, nick, color, content['body']
            )
            nick = prefix
        else
            body = content['body']
            w.print('', 'Uknown content type')
            dbg(content)
        end
        local data = ("%s\t%s%s"):format(
                format_nick(nick, is_self),
                color,
                body)
        w.print_date_tags(self.buffer, time_int, tags(),
            data)
    elseif chunk['type'] == 'm.room.topic' then
        local title = chunk['content']['topic']
        w.buffer_set(self.buffer, "title", title)
        local color = wcolor("irc.color.topic_new")
        local nick = self.users[chunk.user_id] or chunk.user_id
        local data = ('--\t%s%s has changed the topic to "%s%s%s"'):format(
                format_nick(nick, is_self),
                default_color,
                color,
                title,
                default_color
              )
        w.print_date_tags(self.buffer, chunk.origin_server_ts, tags(),
            data)
    elseif chunk['type'] == 'm.room.name' then
        local name = chunk['content']['name']
        w.buffer_set(self.buffer, "short_name", name)
    elseif chunk['type'] == 'm.room.member' then
        if chunk['content']['membership'] == 'join' then
            tag"irc_join"
            local nick = self:addNick(chunk.user_id, chunk.content.displayname)
            local time_int = chunk['origin_server_ts']/1000
            -- Check if the chunk has prev_content or not
            -- if there is prev_content there wasn't a join but a nick change
            if chunk.prev_content and chunk.prev_content.membership == 'join' then
                local oldnick = chunk.prev_content.displayname
                if oldnick == json.null then
                    oldnick = ''
                else
                    self:delNick(oldnick)
                end
                local pcolor = wcolor'weechat.color.chat_prefix_network'
                local data = ('%s--\t%s%s%s is now known as %s%s'):format(
                    pcolor,
                    w.info_get('irc_nick_color', oldnick),
                    oldnick,
                    default_color,
                    w.info_get('irc_nick_color', nick),
                    nick)
                w.print_date_tags(self.buffer, time_int, tags(), data)
            else
                local data = ('%s%s\t%s%s%s (%s%s%s) joined the room.'):format(
                    wcolor('weechat.color.chat_prefix_join'),
                    wconf('weechat.look.prefix_join'),
                    w.info_get('irc_nick_color', nick),
                    nick,
                    wcolor('irc.color.message_join'),
                    wcolor'weechat.color.chat_host',
                    chunk.user_id,
                    wcolor('irc.color.message_join')
                )
                w.print_date_tags(self.buffer, time_int, tags(), data)
            end
        elseif chunk['content']['membership'] == 'leave' then
            local nick = chunk['prev_content'].displayname
            if not nick then
                nick = chunk['user_id']
            end
            tag"irc_quit"
            if not backlog then
                self:delNick(nick)
            end
            local time_int = chunk['origin_server_ts']/1000
            local data = ('%s%s\t%s%s%s left the room.'):format(
                wcolor('weechat.color.chat_prefix_quit'),
                wconf('weechat.look.prefix_quit'),
                w.info_get('irc_nick_color', nick),
                nick,
                wcolor('irc.color.message_quit')
            )
            w.print_date_tags(self.buffer, time_int, tags(),
                data)
        elseif chunk['content']['membership'] == 'invite' then
            if not is_self then -- Check if we were the one inviting
                mprint(('You have been invited to join room %s by %s. Type /join %s to join.')
                    :format(self.identifier, chunk.content.creator, self.identifier))
            end
        else
            dbg({err= 'unknown membership type in parseChunk', chunk= chunk})
        end
    elseif chunk['type'] == 'm.room.create' then
        -- TODO: parse create events --
        dbg({event='m.room.create',chunk=chunk})
    elseif chunk['type'] == 'm.room.power_levels' then
        -- TODO: parse power lvls events --
    elseif chunk['type'] == 'm.room.join_rules' then
        -- TODO: parse join_rules events --
    elseif chunk['type'] == 'm.typing' then
        -- TODO: Typing notices. --
    elseif chunk['type'] == 'm.presence' then
        self:addNick(chunk.content.user_id, chunk['content']['displayname'])
    elseif chunk['type'] == 'm.room.aliases' then
        -- Use first alias, weechat doesn't really support multiple  aliases
        self:setName(chunk.content.aliases[1])
    else
        dbg({err= 'unknown chunk type in parseChunk', chunk= chunk})
    end
end

function poll(a,b)
    SERVER:poll()
    return w.WEECHAT_RC_OK
end

function join_command_cb(data, current_buffer, args)
    if current_buffer == BUFFER then
        local _, args = split_args(args)
        SERVER:join(args)
        return w.WEECHAT_RC_OK_EAT
    else
        return w.WEECHAT_RC_OK
    end
end

function part_command_cb(data, current_buffer, args)
    local room = SERVER:findRoom(current_buffer)
    if room then
        SERVER:part(room)
        return w.WEECHAT_RC_OK_EAT
    else
        return w.WEECHAT_RC_OK
    end
end

function emote_command_cb(data, current_buffer, args)
    local room = SERVER:findRoom(current_buffer)
    if room then
        local _, args = split_args(args)
        room:emote(args)
        return w.WEECHAT_RC_OK_EAT
    else
        return w.WEECHAT_RC_OK
    end
end

function topic_command_cb(data, current_buffer, args)
    local room = SERVER:findRoom(current_buffer)
    if room then
        local _, args = split_args(args)
        room:topic(args)
        return w.WEECHAT_RC_OK_EAT
    else
        return w.WEECHAT_RC_OK
    end
end

function upload_command_cb(data, current_buffer, args)
    local room = SERVER:findRoom(current_buffer)
    if room then
        local _, args = split_args(args)
        room:upload(args)
        return w.WEECHAT_RC_OK_EAT
    else
        return w.WEECHAT_RC_OK
    end
end

function query_command_cb(data, current_buffer, args)
    local room = SERVER:findRoom(current_buffer)
    if room then
        local _, args = split_args(args)
        for id, displayname in pairs(room.users) do
            if displayname == args then
                -- Create a new room and invite the guy
                SERVER:CreateRoom(false, nil, {id})
                return w.WEECHAT_RC_OK_EAT
            end
        end
    else
        return w.WEECHAT_RC_OK
    end
end

function closed_matrix_buffer_cb(data, buffer)
    BUFFER = nil
    return w.WEECHAT_RC_OK
end

function closed_matrix_room_cb(data, buffer)
    return w.WEECHAT_RC_ERR
end

function typing_notification_cb(signal, sig_type, data)
    -- Ignore commands
    if data:match'^/' then
        return w.WEECHAT_RC_OK
    end
    -- Is this signal coming from a matrix buffer?
    local room = SERVER:findRoom(data)
    if room then
        -- Start sending when it reaches > 4
        if #w.buffer_get_string(data, "input") > 4 then
            local now = os.time()
            -- Generate typing events every 4th second
            if SERVER.typing_time + 4 < now then
                SERVER.typing_time = now
                room:SendTypingNotice()
            end
        end
    end

    return w.WEECHAT_RC_OK
end


if w.register(SCRIPT_NAME, SCRIPT_AUTHOR, SCRIPT_VERSION, SCRIPT_LICENSE, SCRIPT_DESC, "unload", "UTF-8") then
    local settings = {
        homeserver_url= {'https://matrix.org/', 'Full URL including port to your homeserver or use default matrix.org'},
        user= {'', 'Your homeserver username'},
        password= {'', 'Your homeserver password'},
        backlog_lines= {'20', 'Number of lines to fetch from backlog upon connecting'},
        autojoin_on_invite = {'on', 'Automatically join rooms you are invited to'},
        typing_notices = {'on', 'Send typing notices when you type'},
    }
    -- set default settings
    local version = w.info_get('version_number', '') or 0
    for option, value in pairs(settings) do
        if w.config_is_set_plugin(option) ~= 1 then
            w.config_set_plugin(option, value[1])
        end
        if tonumber(version) >= 0x00030500 then
            w.config_set_desc_plugin(option, ('%s (default: "%s")'):format(
                     value[2], value[1]))
        end
    end
    w.hook_command_run('/join', 'join_command_cb', '')
    w.hook_command_run('/part', 'part_command_cb', '')
    w.hook_command_run('/leave', 'part_command_cb', '')
    w.hook_command_run('/me', 'emote_command_cb', '')
    w.hook_command_run('/topic', 'topic_command_cb', '')
    w.hook_command_run('/upload', 'upload_command_cb', '')
    w.hook_command_run('/query', 'query_command_cb', '')
    -- TODO
    -- /invite
    -- /create
    -- /list
    -- /whois
    -- /nick
    -- /op
    -- /kick
    -- /ban
    -- /voice
    -- /deop
    -- /devoice
    if w.config_get_plugin('typing_notices') == 'on' then
        w.hook_signal('input_text_changed', "typing_notification_cb", '')
    end
    local cmds = {'help', 'connect', 'join', 'part'}
    w.hook_command(SCRIPT_COMMAND, 'Plugin for matrix.org chat protocol',
        '[command] [command options]',
        'Commands:\n' ..table.concat(cmds, '\n') ..
        '\nUse /matrix help [command] to find out more\n',
        -- Completions
        table.concat(cmds, '|'),
        'matrix_command_cb', '')

    SERVER = MatrixServer.create()
    SERVER:connect()
end
