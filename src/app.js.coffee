app = require('express')()
http = require('http').Server(app)
cors = require('cors')
io = require('socket.io')(http)
redis = require('redis')

redis_url = process.env.REDIS_URL
debug_mode = process.env.LIVESITE_DEBUG == 'true'
redis_sub_client = redis.createClient(redis_url)
redis_client = redis.createClient(redis_url)

app.use(cors(origin: true, credentials: true))


app.get '/', (req, res)->
  #res.set('Access-Control-Allow-Origin', '*')
  # Load keys from Redis
  scope = req.query.scope
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


app.post '/', (req, res)->
  # Save object to Redis and emit event to Redis

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

# handle websockets
io.on 'connection', (socket)->
  # handle channel subscribe request
  socket.on 'subscribe', (channel_name)->
    socket.join(channel_name)
    console.log "Handling subscription to #{channel_name}" if debug_mode

  # handle channel unsubscribe request
  socket.on 'unsubscribe', (channel_name)->
    socket.leave(channel_name)

  socket.on 'model.updated', (msg, buffer)->
    msg.action ||= "updated"
    scope = msg.scope
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

  socket.on 'model.deleted', (msg)->
    msg.action ||= "deleted"
    scope = msg.scope
    model = msg.model
    action = msg.action
    data = msg.data
    msg.event = "#{model}.#{action}"
    model_key = "#{scope}:#{model}:#{data.id}"
    redis_client.del(model_key)
    redis_client.srem("#{scope}:#{model}:ids", data.id)
    redis_client.publish("model.deleted", JSON.stringify(msg))
    console.log("Deleted data from redis: #{JSON.stringify(data)}") if debug_mode


server_port = process.env.LIVESITE_PORT
http.listen server_port, ->
  console.log("Listening on *:#{server_port}") if debug_mode
