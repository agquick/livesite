express = require('express')
app = express()
http = require('http').Server(app)
cors = require('cors')
io = require('socket.io')(http)
redis = require('redis')

redis_url = process.env.REDIS_URL
debug_mode = process.env.LIVESITE_DEBUG == 'true'
require_authentication = process.env.LIVESITE_AUTHENTICATED == 'true'
redis_sub_client = redis.createClient(redis_url)
redis_client = redis.createClient(redis_url)
socket_state = {}

reportModelUpdated = (msg, auth)->
  msg.action ||= "updated"
  scope = msg.scope
  authorizeScope(scope, auth)
  model = msg.model
  action = msg.action
  has_buffer = msg.has_buffer
  data = msg.data
  if data
    data.updated_at ||= Math.floor( new Date() / 1000 )
  msg.event = "#{model}.#{action}"
  if has_buffer
    data.buffer = buffer.toString('base64')
  # store data to Redis
  model_key = "#{scope}:#{model}:#{data.id}"
  redis_client.set(model_key, JSON.stringify(data))
  #redis_client.expire(model_key, 60)
  redis_client.sadd("#{scope}:#{model}:ids", data.id)
  # emit event to Redis
  redis_client.publish("model.updated", JSON.stringify(msg))
  console.log("Updated redis with data: #{JSON.stringify(data)}") if debug_mode

reportModelDeleted = (msg, auth)->
  msg.action ||= "deleted"
  scope = msg.scope
  authorizeScope(scope, auth)
  model = msg.model
  action = msg.action
  data = msg.data
  msg.event = "#{model}.#{action}"
  model_key = "#{scope}:#{model}:#{data.id}"
  redis_client.del(model_key)
  redis_client.srem("#{scope}:#{model}:ids", data.id)
  redis_client.publish("model.deleted", JSON.stringify(msg))
  console.log("Deleted data from redis: #{JSON.stringify(data)}") if debug_mode

reportAppEvent = (msg, auth)->
  authorizeScope(msg.scope, auth)
  redis_client.publish("app.event", JSON.stringify(msg))
  console.log("Triggering app event: #{JSON.stringify(msg)}") if debug_mode

authorizeScope = (scope, auth)->
  if (require_authentication && (!auth? || !auth.allowed_scopes.includes(scope)))
    throw new Error("Scope '#{scope}' is not allowed (auth=#{JSON.stringify(auth)}).")
  return true

authenticateRequest = (req, res, callback)->
  scope = req.query.scope || req.body?.scope
  token = req.query.token || req.body?.token
  loadToken token, (tdata)->
    try
      callback(tdata)
    catch ex
      console.error ex
      res.json(success: false, error: ex.message)

loadToken = (key, callback)->
  if !key? || key == ""
    callback(null)
    return

  redis_client.get "livesite:token:#{key}", (err, val)->
    if val?
      console.log "Found token data #{val}" if debug_mode
      tdata = JSON.parse(val)
      callback(tdata)
    else
      callback(null)



app.use(cors(origin: true, credentials: true))
app.use(express.json())
#app.use(express.urlencoded(extended: true))

app.get '/', (req, res)->
  res.json(success: true, data: {})

app.get '/models', (req, res)->
  scope = req.query.scope
  authenticateRequest req, res, (auth)->
    authorizeScope(scope, auth)
    #res.set('Access-Control-Allow-Origin', '*')
    # Load keys from Redis
    model = req.query.model
    console.log("REQUEST /: model: #{model} in #{scope}") if debug_mode
    redis_client.smembers "#{scope}:#{model}:ids", (err, rs)->
      ids = rs.map (id)-> "#{scope}:#{model}:#{id}"
      if ids.length > 0
        console.log("Found ids: #{JSON.stringify(ids)}") if debug_mode
        redis_client.mget ids, (err, rs)->
          console.log("Found models: #{JSON.stringify(rs)}") if debug_mode
          ret = rs.map (md)-> JSON.parse(md)
          res.json(success: true, data: ret)
      else
        res.json(success: true, data: [])


app.post '/model', (req, res)->
  authenticateRequest req, res, (auth)->
    # Save object to Redis and emit event to Redis
    msg = {
      scope: req.body.scope,
      model: req.body.model,
      action: req.body.action,
      data: req.body.data
    }
    reportModelUpdated(msg, auth)
    res.json(success: true, data: msg)

app.delete '/model', (req, res)->
  authenticateRequest req, res, (auth)->
    msg = {
      scope: req.body.scope,
      model: req.body.model,
      action: req.body.action,
      data: req.body.data
    }
    reportModelDeleted(msg, auth)
    res.json(success: true, data: msg)

app.post '/event', (req, res)->
  authenticateRequest req, res, (auth)->
    msg = {
      scope: req.body.scope,
      event: req.body.event,
      data: req.body.data
    }
    reportAppEvent(msg, auth)
    res.json(success: true, data: msg)

# subscribe to redis
redis_sub_client.on "message", (channel, msg_data)->
  # get channel name from message
  msg = JSON.parse(msg_data)
  room = msg.scope
  if msg.has_buffer
    buffer = new Buffer(msg.data.buffer, 'base64')
    msg.data.buffer = null
    io.to(room).emit(msg.event, msg, buffer)
  else
    io.to(room).emit(msg.event, msg)
  console.log("Handling model.updated message from redis") if debug_mode

redis_sub_client.on 'ready', ->
  redis_sub_client.subscribe("model.updated")
  redis_sub_client.subscribe("model.deleted")
  redis_sub_client.subscribe("app.event")

# handle websockets
io.on 'connection', (socket)->

  # authenticate with token
  socket.on 'authenticate', (opts)->
    token = opts.token
    console.log "Authenticating with #{token}" if debug_mode
    # find token in redis
    loadToken token, (tdata)->
      if !tdata?
        console.log "Token #{token} could not be found" if debug_mode
        return
      console.log "Authenticated with #{JSON.stringify(tdata)}" if debug_mode
      sauth = tdata
      socket_state[socket.id] = {auth: tdata}
      # join allowed scopes if passed
      if opts.scopes?
        scopes_to_join = opts.scopes.filter((s)-> sauth.allowed_scopes.includes(s))
        console.log "Joining scopes: #{scopes_to_join}" if debug_mode
        for scope in scopes_to_join
          socket.join(scope)

      # emit authenticated event
      socket.emit 'authenticated', sauth

  # clear state on disconnect
  socket.on 'disconnect', ->
    delete socket_state[socket.id] 

  # handle channel subscribe request
  socket.on 'subscribe', (scope)->
    # check if in state
    sauth = socket_state[socket.id]?.auth
    try 
      authorizeScope(scope, sauth)
      socket.join(scope)
      console.log "Handling subscription to #{channel_name}" if debug_mode
    catch ex
      console.error ex

  # handle channel unsubscribe request
  socket.on 'unsubscribe', (channel_name)->
    socket.leave(channel_name)

  socket.on 'model.updated', (msg, buffer)->
    try
      sauth = socket_state[socket.id]?.auth
      reportModelUpdated(msg, sauth)
    catch ex
      console.error ex

  socket.on 'model.deleted', (msg)->
    try
      sauth = socket_state[socket.id]?.auth
      reportModelDeleted(msg, sauth)
    catch ex
      console.error ex

  socket.on 'app.event', (msg)->
    try
      sauth = socket_state[socket.id]?.auth
      reportAppEvent(msg, sauth)
    catch ex
      console.error ex


server_port = process.env.LIVESITE_PORT
http.listen server_port, ->
  console.log("Listening on *:#{server_port} (authenticated: #{require_authentication})")
