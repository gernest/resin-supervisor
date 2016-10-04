require('log-timestamp')
process.on 'uncaughtException', (e) ->
	console.error('Got unhandled exception', e, e?.stack)

Promise = require 'bluebird'
knex = require './db'
utils = require './utils'
bootstrap = require './bootstrap'
config = require './config'
_ = require 'lodash'

knex.init.then ->
	utils.mixpanelTrack('Supervisor start')

	console.log('Starting connectivity check..')
	utils.connectivityCheck()

	Promise.join bootstrap.startBootstrapping(), utils.getOrGenerateSecret('api'), utils.getOrGenerateSecret('logsChannel'), (uuid, secret, logsChannel) ->
		# Persist the uuid in subsequent metrics
		utils.mixpanelProperties.uuid = uuid

		api = require './api'
		application = require('./application')(logsChannel, bootstrap.offlineMode)

		console.log('Starting API server..')
		utils.createIpTablesRules()
		.then ->
			apiServer = api(application).listen(config.listenPort)
			apiServer.timeout = config.apiTimeout

		bootstrap.done
		.then ->
			# The device module communicates with the api and as such needs bootstrapping to complete
			device = require './device'
			device.getOSVersion()
			.then (osVersion) ->
				# Let API know what version we are, and our api connection info.
				console.log('Updating supervisor version and api info')
				device.updateState(
					api_port: config.listenPort
					api_secret: secret
					os_version: osVersion
					supervisor_version: utils.supervisorVersion
					provisioning_progress: null
					provisioning_state: ''
					download_progress: null
					logs_channel: logsChannel
				)

			updateIpAddr = ->
				utils.gosuper.getAsync('/v1/ipaddr', { json: true })
				.spread (response, body) ->
					if response.statusCode == 200 && body.Data.IPAddresses?
						device.updateState(
							ip_address: body.Data.IPAddresses.join(' ')
						)
				.catch(_.noop)
			console.log('Starting periodic check for IP addresses..')
			setInterval(updateIpAddr, 30 * 1000) # Every 30s
			updateIpAddr()

		console.log('Starting Apps..')
		application.initialize()
