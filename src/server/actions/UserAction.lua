
local ERR_USER_INVALID_PARAM = 3000
local ERR_USER_OPERATION_FAILED = 3100

local SECRET = [[a6733a8e68960921f9dea6d2080c722b]]

local UserAction = class("UserAction", cc.server.ActionBase)

local function Err(errCode, errMsg, ...)
    local msg = string.format(errMsg, ...)

    return {err_code = errCode, err_msg=msg}
end

-- actually, this function is only for test. 
-- In practice, client should offer password coded by MD5.
local function IsMD5(password)
    if string.len(password) ~= 32 then 
        return false
    end

    for i = 1, 32 do 
        if not tonumber(string.sub(password, i, i), 16) then 
            return false
        end
    end

    return true
end

local function ConstructBody(body) 
    if not IsMD5(body.password) then 
        body.password = ngx.md5(body.password)    
    end

    for k, v in pairs(body) do 
        body[k] = string.urlencode(v)
    end

    local str = SECRET .. "from" .. body.from .. "password" .. body.password .. "timestamp" .. body.timestamp .. "username" .. body.username .. SECRET

    body.sign = string.upper(ngx.md5(str))

    --local bodyStr = json.encode(body)
    local bodyStr = ""
    for k, v in pairs(body) do 
        bodyStr = bodyStr .. k .. "=" .. v .. "&"
    end
    bodyStr = string.sub(bodyStr, 1, -2)
   
    return bodyStr
end

function UserAction:ctor(app) 
    self.super:ctor(app)    

    self.Mysql = nil 
    self.Redis = nil

    if app then 
        self.Mysql = app.getMysql(app)
        self.Redis = app.getRedis(app)
    end  

    self.reply = {}
end

function UserAction:dector(app)
    if self.Mysql then 
        self.Mysql:close()
    end

    if self.Redis then
        self.Redis:close()
    end
end

function UserAction:LoginAction(data) 
    assert(type(data) == "table", "data is NOT a table.")

    local user = data.user
    if user == nil or type(user) ~= "string" then 
        self.reply = Err(ERR_USER_INVALID_PARAM, "param(user) is missed")
        return self.reply
    end

    local password = data.password 
    if password == nil or type(password) ~= "string" then 
        self.reply = Err(ERR_USER_INVALID_PARAM, "param(password) is missed")
        return self.reply
    end

    local from = data.from 
    if from == nil or type(from) ~= "string" then 
        self.reply = Err(ERR_USER_INVALID_PARAM, "param(from) is missed")
        return self.reply
    end

    local httpClient = cc.server.http:new()
    
    local bodyStr = nil 
    local reqBody = {}
    local ok = nil
    local code = nil 
    local status = nil
    local err = nil

    reqBody.username = user 
    reqBody.password = password
    reqBody.from = from 
    reqBody.timestamp= os.time()

    ok, code, _, status, bodyStr = httpClient:request{
        url = [[http://open.cocoachina.com/api/user_login]], 
        method = "POST", 
        headers = { ["Content-Type"] = [[application/x-www-form-urlencoded]]}, 
        body = ConstructBody(reqBody)
    } 

    if not ok then 
        self.reply = Err(ERR_USER_OPERATION_FAILED, "operation User.Login failed: http resp code = %s, status = %s", code, status)
        return self.reply
    end

    -- handle reply body
    echoInfo("Login Reply: %s", bodyStr)
    local body = json.decode(bodyStr) 
    if body.status == "error" then 
        self.reply =Err(ERR_USER_OPERATION_FAILED, "operation User.Login failed: username or passwrod is wrong.")
        return self.reply
    end

    -- if status is "success"
    body = body.msg
    local ip = ngx.var.remote_addr
    -- generate session_id from uid, ip and timestamp
    local session_id = ngx.md5(body.uid .. ":" .. ip .. ":" .. tostring(reqBody.timestamp))
    
    -- store login data into user_info table
    local findSql = string.format([[insert into user_info(uid, session_id, ip) value('%s', '%s', '%s') on duplicate key update session_id = '%s', ip = '%s';]], body.uid, session_id, ip, session_id, ip)
    ok, err = self.Mysql:query(findSql)
    if not ok then 
        self.reply = Err(ERR_USER_OPERATION_FAILED, "operation User.Login failed: Store user info failed.")
        return self.reply
    end

    -- set expired time of session_id in redis
    ok = self.Redis:command("hset", "__token_expire", body.uid, reqBody.timestamp)

    self.reply = {session_id = session_id, uid = body.uid, email = body.email}
    return self.reply
end

return UserAction 