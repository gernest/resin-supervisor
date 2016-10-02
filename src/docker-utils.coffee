Docker = require 'docker-toolbelt'
{ getRegistryAndName, DockerProgress } = require 'docker-progress'
Promise = require 'bluebird'
progress = require 'request-progress'
dockerDelta = require 'docker-delta'
config = require './config'
_ = require 'lodash'
knex = require './db'
{ request } = require './request'
Lock = require 'rwlock'
utils = require './utils'
rimraf = Promise.promisify(require('rimraf'))
resumable = require 'resumable-request'

docker = new Docker(socketPath: config.dockerSocket)

exports.docker = docker
dockerProgress = new DockerProgress(socketPath: config.dockerSocket)

# Create an array of (repoTag, image_id, created) tuples like the output of `docker images`
listRepoTagsAsync = ->
	docker.listImagesAsync()
	.then (images) ->
		images = _.sortByOrder(images, 'Created', [ false ])
		ret = []
		for image in images
			for repoTag in image.RepoTags
				ret.push [ repoTag, image.Id, image.Created ]
		return ret

# Find either the most recent image of the same app or the image of the supervisor.
# Returns an image Id or Tag (depending on whatever's available)
findSimilarImage = (repoTag) ->
	application = repoTag.split('/')[1]

	listRepoTagsAsync()
	.then (repoTags) ->
		# Find the most recent image of the same application
		for repoTag in repoTags
			otherApplication = repoTag[0].split('/')[1]
			if otherApplication is application
				return repoTag[0]

		# Otherwise we start from scratch
		return 'resin/scratch'

DELTA_REQUEST_TIMEOUT = 15 * 60 * 1000

getRepoAndTag = (image) ->
	getRegistryAndName(image)
	.then ({ registry, imageName, tagName }) ->
		registry = registry.toString().replace(':443', '')
		return { repo: "#{registry}/#{imageName}", tag: tagName }

do ->
	_lock = new Lock()
	_writeLock = Promise.promisify(_lock.async.writeLock)
	_readLock = Promise.promisify(_lock.async.readLock)
	writeLockImages = ->
		_writeLock('images')
		.disposer (release) ->
			release()
	readLockImages = ->
		_readLock('images')
		.disposer (release) ->
			release()

	exports.rsyncImageWithProgress = (imgDest, onProgress, startFromEmpty = false) ->
		Promise.using readLockImages(), ->
			Promise.try ->
				if startFromEmpty
					return 'resin/scratch'
				findSimilarImage(imgDest)
			.then (imgSrc) ->
				new Promise (resolve, reject) ->
					progress resumable(request, { url: "#{config.deltaHost}/api/v2/delta?src=#{imgSrc}&dest=#{imgDest}", timeout: DELTA_REQUEST_TIMEOUT })
					.on 'progress', (progress) ->
						onProgress(percentage: progress.percent)
					.on 'end', ->
						onProgress(percentage: 100)
					.on 'response', (res) ->
						if res.statusCode isnt 200
							reject(new Error("Got #{res.statusCode} when requesting image from delta server."))
						else
							if imgSrc is 'resin/scratch'
								deltaSrc = null
							else
								deltaSrc = imgSrc
							res.pipe(dockerDelta.applyDelta(deltaSrc, imgDest))
							.on('id', resolve)
							.on('error', reject)
					.on 'error', reject
			.then (id) ->
				getRepoAndTag(imgDest)
				.then ({ repo, tag }) ->
					docker.getImage(id).tagAsync({ repo, tag, force: true })
			.catch dockerDelta.OutOfSyncError, (err) ->
				console.log('Falling back to delta-from-empty')
				exports.rsyncImageWithProgress(imgDest, onProgress, true)

	exports.fetchImageWithProgress = (image, onProgress) ->
		Promise.using readLockImages(), ->
			dockerProgress.pull(image, onProgress)

	supervisorTag = config.supervisorImage
	if !/:/g.test(supervisorTag)
		# If there is no tag then mark it as latest
		supervisorTag += ':latest'
	exports.cleanupContainersAndImages = ->
		Promise.using writeLockImages(), ->
			Promise.join(
				knex('image').select('repoTag')
				.map (image) ->
					# Docker sometimes prepends 'docker.io/' to official images
					return [ image.repoTag, 'docker.io/' + image.repoTag ]
				.then(_.flatten)
				knex('app').select()
				.map ({ imageId }) ->
					imageId + ':latest'
				knex('dependentApp').select()
				.map ({ imageId }) ->
					imageId + ':latest'
				docker.listImagesAsync()
				(locallyCreatedTags, apps, dependentApps, images) ->
					imageTags = _.map(images, 'RepoTags')
					supervisorTags = _.filter imageTags, (tags) ->
						_.contains(tags, supervisorTag)
					appTags = _.filter imageTags, (tags) ->
						_.any tags, (tag) ->
							_.contains(apps, tag) or _.contains(dependentApps, tag)
					supervisorTags = _.flatten(supervisorTags)
					appTags = _.flatten(appTags)
					locallyCreatedTags = _.flatten(locallyCreatedTags)
					return { images, supervisorTags, appTags, locallyCreatedTags }
			)
			.then ({ images, supervisorTags, appTags, locallyCreatedTags }) ->
				# Cleanup containers first, so that they don't block image removal.
				docker.listContainersAsync(all: true)
				.filter (containerInfo) ->
					# Do not remove user apps.
					getRepoAndTag(containerInfo.Image)
					.then ({ repo, tag }) ->
						repoTag = buildRepoTag(repo, tag)
						if _.contains(appTags, repoTag)
							return false
						if _.contains(locallyCreatedTags, repoTag)
							return false
						if !_.contains(supervisorTags, repoTag)
							return true
						return containerHasExited(containerInfo.Id)
				.map (containerInfo) ->
					docker.getContainer(containerInfo.Id).removeAsync(v: true, force: true)
					.then ->
						console.log('Deleted container:', containerInfo.Id, containerInfo.Image)
					.catch(_.noop)
				.then ->
					imagesToClean = _.reject images, (image) ->
						_.any image.RepoTags, (tag) ->
							return _.contains(appTags, tag) or _.contains(supervisorTags, tag) or _.contains(locallyCreatedTags, tag)
					Promise.map imagesToClean, (image) ->
						Promise.map image.RepoTags.concat(image.Id), (tag) ->
							docker.getImage(tag).removeAsync(force: true)
							.then ->
								console.log('Deleted image:', tag, image.Id, image.RepoTags)
							.catch(_.noop)

	containerHasExited = (id) ->
		docker.getContainer(id).inspectAsync()
		.then (data) ->
			return not data.State.Running

	buildRepoTag = (repo, tag, registry) ->
		repoTag = ''
		if registry?
			repoTag += registry + '/'
		repoTag += repo
		if tag?
			repoTag += ':' + tag
		else
			repoTag += ':latest'
		return repoTag

	sanitizeQuery = (query) ->
		_.omit(query, 'apikey')

	exports.createImage = (req, res) ->
		{ registry, repo, tag, fromImage } = req.query
		if fromImage?
			repoTag = buildRepoTag(fromImage, tag)
		else
			repoTag = buildRepoTag(repo, tag, registry)
		Promise.using writeLockImages(), ->
			knex('image').select().where({ repoTag })
			.then ([ img ]) ->
				knex('image').insert({ repoTag }) if !img?
			.then ->
				if fromImage?
					docker.createImageAsync({ fromImage, tag })
				else
					docker.importImageAsync(req, { repo, tag, registry })
			.then (stream) ->
				new Promise (resolve, reject) ->
					stream.on('error', reject)
					.on('response', -> resolve())
					.pipe(res)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	exports.pullAndProtectImage = (image, onProgress) ->
		repoTag = buildRepoTag(image)
		Promise.using writeLockImages(), ->
			knex('image').select().where({ repoTag })
			.then ([ img ]) ->
				knex('image').insert({ repoTag }) if !img?
			.then ->
				dockerProgress.pull(repoTag, onProgress)

	exports.getImageTarStream = (image) ->
		docker.getImage(image).getAsync()

	exports.loadImage = (req, res) ->
		Promise.using writeLockImages(), ->
			docker.listImagesAsync()
			.then (oldImages) ->
				docker.loadImageAsync(req)
				.then ->
					docker.listImagesAsync()
				.then (newImages) ->
					oldTags = _.flatten(_.map(oldImages, 'RepoTags'))
					newTags = _.flatten(_.map(newImages, 'RepoTags'))
					createdTags = _.difference(newTags, oldTags)
					Promise.map createdTags, (repoTag) ->
						knex('image').insert({ repoTag })
			.then ->
				res.sendStatus(200)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	exports.deleteImage = (req, res) ->
		imageName = req.params[0]
		Promise.using writeLockImages(), ->
			knex('image').select().where('repoTag', imageName)
			.then (images) ->
				throw new Error('Only images created via the Supervisor can be deleted.') if images.length == 0
				knex('image').where('repoTag', imageName).delete()
			.then ->
				docker.getImage(imageName).removeAsync(sanitizeQuery(req.query))
				.then (data) ->
					res.json(data)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	exports.listImages = (req, res) ->
		docker.listImagesAsync(sanitizeQuery(req.query))
		.then (images) ->
			res.json(images)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	docker.modem.dialAsync = Promise.promisify(docker.modem.dial)
	createContainer = (options, internalId) ->
		Promise.using writeLockImages(), ->
			knex('image').select().where('repoTag', options.Image)
			.then (images) ->
				throw new Error('Only images created via the Supervisor can be used for creating containers.') if images.length == 0
				knex.transaction (tx) ->
					Promise.try ->
						return internalId if internalId?
						tx.insert({}, 'id').into('container')
						.then ([ id ]) ->
							return id
					.then (id) ->
						options.HostConfig ?= {}
						options.Volumes ?= {}
						_.assign(options.Volumes, utils.defaultVolumes)
						options.HostConfig.Binds = utils.defaultBinds("containers/#{id}")
						query = ''
						query = "name=#{options.Name}&" if options.Name?
						optsf =
							path: "/containers/create?#{query}"
							method: 'POST'
							options: options
							statusCodes:
								200: true
								201: true
								404: 'no such container'
								406: 'impossible to attach'
								500: 'server error'
						utils.validateKeys(options, utils.validContainerOptions)
						.then ->
							utils.validateKeys(options.HostConfig, utils.validHostConfigOptions)
						.then ->
							docker.modem.dialAsync(optsf)
						.then (data) ->
							containerId = data.Id
							tx('container').update({ containerId }).where({ id })
							.return(data)
	exports.createContainer = (req, res) ->
		createContainer(req.body)
		.then (data) ->
			res.json(data)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	startContainer = (containerId, options) ->
		utils.validateKeys(options, utils.validHostConfigOptions)
		.then ->
			docker.getContainer(containerId).startAsync(options)
	exports.startContainer = (req, res) ->
		startContainer(req.params.id, req.body)
		.then (data) ->
			res.json(data)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	stopContainer = (containerId, options) ->
		container = docker.getContainer(containerId)
		knex('app').select()
		.then (apps) ->
			throw new Error('Cannot stop an app container') if _.any(apps, { containerId })
			container.inspectAsync()
		.then (cont) ->
			throw new Error('Cannot stop supervisor container') if cont.Name == '/resin_supervisor' or _.any(cont.Names, (n) -> n == '/resin_supervisor')
			container.stopAsync(options)
	exports.stopContainer = (req, res) ->
		stopContainer(req.params.id, sanitizeQuery(req.query))
		.then (data) ->
			res.json(data)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	deleteContainer = (containerId, options) ->
		container = docker.getContainer(containerId)
		knex('app').select()
		.then (apps) ->
			throw new Error('Cannot remove an app container') if _.any(apps, { containerId })
			container.inspectAsync()
		.then (cont) ->
			throw new Error('Cannot remove supervisor container') if cont.Name == '/resin_supervisor' or _.any(cont.Names, (n) -> n == '/resin_supervisor')
			if options.purge
				knex('container').select().where({ containerId })
				.then (contFromDB) ->
					# This will also be affected by #115. Should fix when we fix that.
					rimraf(utils.getDataPath("containers/#{contFromDB.id}"))
				.then ->
					knex('container').where({ containerId }).del()
		.then ->
			container.removeAsync(options)
	exports.deleteContainer = (req, res) ->
		deleteContainer(req.params.id, sanitizeQuery(req.query))
		.then (data) ->
			res.json(data)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	exports.listContainers = (req, res) ->
		docker.listContainersAsync(sanitizeQuery(req.query))
		.then (containers) ->
			res.json(containers)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	exports.updateContainer = (req, res) ->
		{ oldContainerId } = req.query
		return res.status(400).send('Missing oldContainerId') if !oldContainerId?
		knex('container').select().where({ containerId: oldContainerId })
		.then ([ oldContainer ]) ->
			return res.status(404).send('Old container not found') if !oldContainer?
			stopContainer(oldContainerId, t: 10)
			.then ->
				deleteContainer(oldContainerId, v: true)
			.then ->
				createContainer(req.body, oldContainer.id)
			.tap (data) ->
				startContainer(data.Id)
		.then (data) ->
			res.json(data)
		.catch (err) ->
			res.status(500).send(err?.message or err or 'Unknown error')

	exports.getImageEnv = (id) ->
		docker.getImage(id).inspectAsync()
		.get('Config').get('Env')
		.catch (err) ->
			console.log('Error getting env from image', err, err.stack)
			return {}
