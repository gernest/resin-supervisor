Promise = require 'bluebird'
Knex = require 'knex'

knex = Knex(
	client: 'sqlite3'
	connection:
		filename: '/data/database.sqlite'
)

addColumn = (table, column, type) ->
	knex.schema.hasColumn(table, column)
	.then (exists) ->
		if not exists
			knex.schema.table table, (t) ->
				t[type](column)

knex.init = Promise.all([
	knex.schema.hasTable('config')
	.then (exists) ->
		if not exists
			knex.schema.createTable 'config', (t) ->
				t.string('key').primary()
				t.string('value')

	knex.schema.hasTable('deviceConfig')
	.then (exists) ->
		if not exists
			knex.schema.createTable 'deviceConfig', (t) ->
				t.json('values')
				t.json('targetValues')
			.then ->
				knex('deviceConfig').insert({ values: '{}', targetValues: '{}' })

	knex.schema.hasTable('app')
	.then (exists) ->
		if not exists
			knex.schema.createTable 'app', (t) ->
				t.increments('id').primary()
				t.string('name')
				t.string('containerId')
				t.string('commit')
				t.string('imageId')
				t.string('appId')
				t.boolean('privileged')
				t.json('env')
				t.json('config')
		else
			Promise.all [
				addColumn('app', 'commit', 'string')
				addColumn('app', 'appId', 'string')
				addColumn('app', 'config', 'json')
			]

	knex.schema.hasTable('image')
	.then (exists) ->
		if not exists
			knex.schema.createTable 'image', (t) ->
				t.increments('id').primary()
				t.string('repoTag')
	knex.schema.hasTable('container')
	.then (exists) ->
		if not exists
			knex.schema.createTable 'container', (t) ->
				t.increments('id').primary()
				t.string('containerId')

	knex.schema.hasTable('dependentApp')
	.then (exists) ->
		if not exists
			knex.schema.createTable 'dependentApp', (t) ->
				t.increments('id').primary()
				t.string('appId')
				t.string('parentAppId')
				t.string('name')
				t.string('commit')
				t.string('imageId')
				t.json('config')

	knex.schema.hasTable('dependentDevice')
	.then (exists) ->
		if not exists
			knex.schema.createTable 'dependentDevice', (t) ->
				t.increments('id').primary()
				t.string('uuid')
				t.string('appId')
				t.string('device_type')
				t.string('logs_channel')
				t.string('deviceId')
				t.boolean('is_online')
				t.string('name')
				t.string('status')
				t.string('download_progress')
				t.string('commit')
				t.string('targetCommit')
				t.json('environment')
				t.json('targetEnvironment')
				t.json('config')
				t.json('targetConfig')
				t.boolean('markedForDeletion')
		else
			addColumn('dependentDevice', 'markedForDeletion', 'boolean')
])

module.exports = knex
