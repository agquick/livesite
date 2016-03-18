app = require('express')()
http = require('http').Server(app)
cors = require('cors')
io = require('socket.io')(http)
redis = require('redis')

redis_url = process.env.REDIS_URL
redis_sub_client = redis.createClient(redis_url)
redis_client = redis.createClient(redis_url)

app.use(cors(origin: true, credentials: true))

class Channel
	constructor : ->
		@subscriptions = []
	isSocketSubscribed : (socket)=>
		i = @subscriptions.indexOf(socket)
		return i != -1
	subscribe : (socket)=>
		return if @isSocketSubscribed(socket)
		@subscriptions.push(socket)
	unsubscribe : (socket)=>
		i = @subscriptions.indexOf(socket)
		@subscriptions.splice(i, 1)


# subscription code
channels = {}
add_subscription = (channel_name, socket)->
	ch = channels[channel_name]
	ch.subscribe(socket)
remove_subscription = (channel_name, socket)->
	ch = channels[channel_name]
	ch.unsubscribe(socket)


app.get '/', (req, res)->
	#res.set('Access-Control-Allow-Origin', '*')
	# Load keys from Redis
	model = req.query.model
	console.log "REQUEST /: model: #{model}"
	redis_client.smembers "#{model}:ids", (err, rs)->
		ids = rs.map (id)-> "#{model}:#{id}"
		if ids.length > 0
			console.log("Found ids: #{JSON.stringify(ids)}")
			redis_client.mget ids, (err, rs)->
				console.log("Found models: #{JSON.stringify(rs)}")
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
	room = msg.model
	io.to(room).emit(msg.event, msg)
	console.log("Handling model.updated message from redis")

redis_sub_client.on 'ready', ->
	redis_sub_client.subscribe("model.updated")

# handle websockets
io.on 'connection', (socket)->
	# handle channel subscribe request
	socket.on 'subscribe', (channel_name)->
		socket.join(channel_name)
		console.log "Handling subscription to #{channel_name}"
	# handle channel unsubscribe request
	socket.on 'unsubscribe', (channel_name)->
		socket.leave(channel_name)
	socket.on 'model.updated', (msg)->
		msg.action ||= "updated"
		model = msg.model
		action = msg.action
		data = msg.data
		msg.event = "#{model}.#{action}"
		# store data to Redis
		model_key = "#{model}:#{data.id}"
		redis_client.set(model_key, JSON.stringify(data))
		#redis_client.expire(model_key, 60)
		redis_client.sadd("#{model}:ids", data.id)
		# emit event to Redis
		redis_client.publish("model.updated", JSON.stringify(msg))
		console.log("Updated redis with data: #{JSON.stringify(data)}")



server_port = process.env.LIVESITE_PORT
http.listen server_port, ->
	console.log("Listening on *:#{server_port}")
