config = require './config'
Docker = require 'dockerode'
Promise = require 'bluebird'
_ = require 'lodash'
es = require 'event-stream'
fs = Promise.promisifyAll(require('fs'))

docker = Promise.promisifyAll(new Docker(socketPath: config.dockerSocket))
# Hack dockerode to promisify internal classes' prototypes
Promise.promisifyAll(docker.getImage().__proto__)
Promise.promisifyAll(docker.getContainer().__proto__)

localImage = config.localImage
remoteImage = config.remoteImage

getContainerId = ->
	fs.readFileAsync( '/proc/1/cgroup' )
	.then (data) ->
		data.toString().match( /:cpu:\/docker\/(.*)$/m )[1]
	.catch (err) ->
		return process.env.HOSTNAME

getCurrentContainer = ->
	getContainerId().then (containerId) ->
		docker.getContainer(containerId).inspectAsync()

startNewSupervisor = (currentSupervisor, waitForSuccess = true) ->
	console.log('Creating supervisor container:', localImage)
	docker.createContainerAsync(
		Image: localImage
		Cmd: [ '/start' ]
		Volumes: config.supervisorContainer.Volumes
		Env: currentSupervisor.Config.Env
	)
	.tap (container) ->
		console.log('Starting supervisor container:', localImage)
		container.startAsync(
			Privileged: true
			Binds: config.supervisorContainer.Binds
		)
	.then (container) ->
		if !waitForSuccess
			return
		# check that next supervisor outputs config.successMessage before this supervisor exits
		container.attachAsync({ stream: true, stdout: true, stderr: false, tty: true })
		.then (stream) ->
			new Promise (resolve, reject) ->
				es.pipeline(
					stream
					es.split()
					es.mapSync (line) ->
						# ignore first 8 characters of every line that are a header sent by docker attach
						data = line.substr(8)
						if data is config.successMessage
							resolve(container)
						return
				)
				stream.on 'end', ->
					reject(new Error('New supervisor stopped before success message'))
			.timeout(config.restartSuccessTimeout) # wait up to 1 minute
		.catch (e) ->
			container.stopAsync()
			console.error('Container failed to start successfully. Error: ', e)
			throw e
	.then ->
		# We've started the new container, so we're done here! #pray
		console.log('Exiting to let the new supervisor take over')
		process.exit()

currentSupervisor = getCurrentContainer().tap (currentSupervisor) ->
	# The volume keys are the important bit.
	expectedVolumes = _.sortBy(_.keys(config.supervisorContainer.Volumes))
	actualVolumes = _.sortBy(_.keys(currentSupervisor.Volumes))

	expectedBinds = _.sortBy(config.supervisorContainer.Binds)
	actualBinds = _.sortBy(currentSupervisor.HostConfig.Binds)

	# Check all the expected binds and volumes exist, if not then start a new supervisor (which will add them correctly)
	if !_.isEqual(expectedVolumes, actualVolumes) or !_.isEqual(expectedBinds, actualBinds)
		console.log('Supervisor restart (for binds/mounts)')
		restart = ->
			# When restarting for just binds/mounts we just wait for the supervisor updates to start.
			startNewSupervisor(currentSupervisor, false)
			.catch (err) ->
				console.error('Error restarting', err)
				# If there's an error just keep attempting to restart to get to a useful state.
				restart()
		restart()

# This is a promise that resolves when we have fully initialised.
exports.initialised = currentSupervisor.then (currentSupervisor) ->
	utils = require './utils'
	JSONStream = require 'JSONStream'

	supervisorUpdating = Promise.resolve()
	exports.update = ->
		# Make sure only one attempt to update the full supervisor is running at a time, ignoring any errors from
		# previous update attempts.
		supervisorUpdating = supervisorUpdating.then ->
			utils.mixpanelTrack('Supervisor update check')
			console.log('Fetching supervisor:', remoteImage)
			docker.createImageAsync(fromImage: remoteImage)
		.then (stream) ->
			return new Promise (resolve, reject) ->
				if stream.headers['content-type'] is 'application/json'
					stream.pipe(JSONStream.parse('error'))
					.pipe(es.mapSync(reject))
				else
					stream.pipe es.wait (error, text) ->
						if error
							reject(text)

				stream.on('end', resolve)
		.then ->
			console.log('Inspecting new supervisor:', remoteImage)
			Promise.all([
				docker.getImage(remoteImage).inspectAsync()
				currentSupervisor
			])
		.spread (localImageInfo, currentSupervisor) ->
			localImageId = localImageInfo.Id or localImageInfo.id
			if localImageId is currentSupervisor.Image
				utils.mixpanelTrack('Supervisor up to date')
				return
			utils.mixpanelTrack('Supervisor update start', image: localImageId)
			startNewSupervisor(currentSupervisor)
		.catch (err) ->
			utils.mixpanelTrack('Supervisor update failed', error: err)
			# The error here is intentionally not propagated further up the chain,
			# because the supervisor-update module internally handles update failures
			# and makes sure that ill updates do not affect the rest of the system.

	exports.startupSuccessful = ->
		# Let the previous supervisor know that we started successfully
		console.log(config.successMessage)

		console.log('Tagging ourselves as a working supervisor:', remoteImage)
		docker.getImage(remoteImage).tagAsync(
			repo: localImage
			force: true
		)
