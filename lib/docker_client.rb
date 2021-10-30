require 'concurrent'
require 'pathname'

class DockerClient
  def self.config
    @config ||= CodeOcean::Config.new(:docker).read(erb: true)
  end

  CONTAINER_WORKSPACE_PATH = '/workspace' #'/home/python/workspace' #'/tmp/workspace'
  # Ralf: I suggest to replace this with the environment variable. Ask Hauke why this is not the case!
  LOCAL_WORKSPACE_ROOT = File.expand_path(self.config[:workspace_root])
  RECYCLE_CONTAINERS = true
  RETRY_COUNT = 2
  MINIMUM_CONTAINER_LIFETIME = 10.minutes
  MAXIMUM_CONTAINER_LIFETIME = 20.minutes
  SELF_DESTROY_GRACE_PERIOD = 2.minutes

  attr_reader :container

  def self.check_availability!
    Timeout.timeout(config[:connection_timeout]) { Docker.version }
  rescue Excon::Errors::SocketError, Excon::Error::Socket, Timeout::Error
    raise Error.new("The Docker host at #{Docker.url} is not reachable!")
  end

  def self.clean_container_workspace(container)
    # remove files when using transferral via Docker API archive_in (transmit)
    # container.exec(['bash', '-c', 'rm -rf ' + CONTAINER_WORKSPACE_PATH + '/*'])

    local_workspace_path = local_workspace_path(container)
    if local_workspace_path && Pathname.new(local_workspace_path).exist?
      Pathname.new(local_workspace_path).children.each do |p|
        p.rmtree
      rescue Errno::ENOENT, Errno::EACCES => error
        Sentry.capture_exception(error)
        Rails.logger.error("clean_container_workspace: Got #{error.class.to_s}: #{error.to_s}")
      end
      # FileUtils.rmdir(Pathname.new(local_workspace_path))
    end
  end

  def self.container_creation_options(execution_environment, local_workspace_path)
    {
        'Image' => find_image_by_tag(execution_environment.docker_image).info['RepoTags'].first,
        'NetworkDisabled' => !execution_environment.network_enabled?,
        #DockerClient.config['allowed_cpus']
        'OpenStdin' => true,
        'StdinOnce' => true,
        # required to expose standard streams over websocket
        'AttachStdout' => true,
        'AttachStdin' => true,
        'AttachStderr' => true,
        'Tty' => true,
        'Binds' => mapped_directories(local_workspace_path),
        'PortBindings' => mapped_ports(execution_environment),
        # Resource limitations.
        'NanoCPUs' => 4 * 1000000000, # CPU quota in units of 10^-9 CPUs.
        'PidsLimit' => 100,
        'KernelMemory' => execution_environment.memory_limit.megabytes, # if below Memory, the Docker host (!) might experience an OOM
        'Memory' => execution_environment.memory_limit.megabytes,
        'MemorySwap' => execution_environment.memory_limit.megabytes, # same value as Memory to disable Swap
        'OomScoreAdj' => 500
    }
  end

  def self.create_container(execution_environment)
    tries ||= 0
    # container.start sometimes creates the passed local_workspace_path on disk (depending on the setup).
    # this is however not guaranteed and caused issues on the server already. Therefore create the necessary folders manually!
    local_workspace_path = generate_local_workspace_path
    FileUtils.mkdir(local_workspace_path)
    FileUtils.chmod_R(0777, local_workspace_path)
    container = Docker::Container.create(container_creation_options(execution_environment, local_workspace_path))
    container.start
    container.start_time = Time.now
    container.status = :created
    container.execution_environment = execution_environment
    container.re_use = true
    container.docker_client = new(execution_environment: execution_environment)

    Thread.new do
      timeout = Random.rand(MINIMUM_CONTAINER_LIFETIME..MAXIMUM_CONTAINER_LIFETIME) # seconds
      sleep(timeout)
      container.re_use = false
      if container.status != :executing
        container.docker_client.kill_container(container, false)
        Rails.logger.info('Killing container in status ' + container.status.to_s + ' after ' + (Time.now - container.start_time).to_s + ' seconds.')
      else
        Thread.new do
          timeout = SELF_DESTROY_GRACE_PERIOD.to_i
          sleep(timeout)
          container.docker_client.kill_container(container, false)
          Rails.logger.info('Force killing container in status ' + container.status.to_s + ' after ' + (Time.now - container.start_time).to_s + ' seconds.')
        ensure
          # guarantee that the thread is releasing the DB connection after it is done
          ActiveRecord::Base.connection_pool.release_connection
        end
      end
    ensure
      # guarantee that the thread is releasing the DB connection after it is done
      ActiveRecord::Base.connection_pool.release_connection
    end

    container
  rescue Docker::Error::NotFoundError => error
    Rails.logger.error('create_container: Got Docker::Error::NotFoundError: ' + error.to_s)
    destroy_container(container)
    #(tries += 1) <= RETRY_COUNT ? retry : raise(error)
  end


  def self.destroy_container(container)
    Rails.logger.info('destroying container ' + container.to_s)
    container.kill
    container.port_bindings.values.each { |port| PortPool.release(port) }
    begin
      clean_container_workspace(container)
      FileUtils.rmtree(local_workspace_path(container))
    rescue Errno::ENOENT, Errno::EACCES => error
      Sentry.capture_exception(error)
      Rails.logger.error("clean_container_workspace: Got #{error.class.to_s}: #{error.to_s}")
    end

    # Checks only if container assignment is not nil and not whether the container itself is still present.
    container&.delete(force: true, v: true)
  rescue Docker::Error::NotFoundError => error
    Rails.logger.error('destroy_container: Rescued from Docker::Error::NotFoundError: ' + error.to_s)
    Rails.logger.error('No further actions are done concerning that.')
  rescue Docker::Error::ConflictError => error
    Rails.logger.error('destroy_container: Rescued from Docker::Error::ConflictError: ' + error.to_s)
    Rails.logger.error('No further actions are done concerning that.')
  end


  def kill_after_timeout(container)
    """
    We need to start a second thread to kill the websocket connection,
    as it is impossible to determine whether further input is requested.
    """
    @thread = Thread.new do
      timeout = (@execution_environment.permitted_execution_time.to_i + 3)  # seconds and some extra time for request handling
      sleep(timeout)
      container = ContainerPool.instance.translate(container.id)
      if container && container.status != :available
        Rails.logger.info('Killing container after timeout of ' + timeout.to_s + ' seconds.')
        Thread.new do
          kill_container(container)
        ensure
          ActiveRecord::Base.connection_pool.release_connection
        end
      else
        Rails.logger.info('Container' + container.to_s + ' already removed.')
      end
    ensure
      # guarantee that the thread is releasing the DB connection after it is done
      ActiveRecord::Base.connection_pool.release_connection
    end
  end

  def exit_thread_if_alive
    @thread.exit if @thread&.alive?
  end

  def exit_container(container)
    Rails.logger.debug('exiting container ' + container.to_s)
    # exit the timeout thread if it is still alive
    exit_thread_if_alive
    # if we use pooling and recylce the containers, put it back. otherwise, destroy it.
    (ContainerPool.instance.config[:active] && RECYCLE_CONTAINERS) ? self.class.return_container(container, @execution_environment) : self.class.destroy_container(container)
  end

  def kill_container(container, create_new = true)
    exit_thread_if_alive
    Rails.logger.info('killing container ' + container.to_s)
    # remove container from pool, then destroy it
    if (ContainerPool.instance.config[:active])
      ContainerPool.instance.remove_from_all_containers(container, @execution_environment)
      # create new container and add it to @all_containers and @containers.

      missing_counter_count = @execution_environment.pool_size - ContainerPool.instance.all_containers[@execution_environment.id].length
      if missing_counter_count > 0 && create_new
        Rails.logger.error('kill_container: Creating a new container.')
        new_container = self.class.create_container(@execution_environment)
        ContainerPool.instance.add_to_all_containers(new_container, @execution_environment)
      elsif !create_new
        Rails.logger.error('Container killed and removed for ' + @execution_environment.to_s + ' but not creating a new one. Currently, ' + missing_counter_count.abs.to_s + ' more containers than the configured pool size are available.')
      else
        Rails.logger.error('Container killed and removed for ' + @execution_environment.to_s + ' but not creating a new one as per request. Currently, ' + missing_counter_count.to_s + ' containers are missing compared to the configured pool size are available. Negative number means they are too much containers')
      end
    end

    Thread.new do
      self.class.destroy_container(container)
    end
  end

  def self.find_image_by_tag(tag)
    # todo: cache this.
    Docker::Image.all.detect do |image|
      begin
        image.info['RepoTags'].flatten.include?(tag)
      rescue
        # Skip image if it is not tagged
        next
      end
    end
  end

  def self.generate_local_workspace_path
    File.join(LOCAL_WORKSPACE_ROOT, SecureRandom.uuid)
  end

  def self.image_tags
    Docker::Image.all.map { |image| image.info['RepoTags'] }.flatten.reject { |tag| tag.nil? || tag.include?('<none>') }
  end

  def initialize(options = {})
    @execution_environment = options[:execution_environment]
    # todo: eventually re-enable this if it is cached. But in the end, we do not need this.
    # docker daemon got much too much load. all not 100% necessary calls to the daemon were removed.
    # @image = self.class.find_image_by_tag(@execution_environment.docker_image)
    # fail(Error, "Cannot find image #{@execution_environment.docker_image}!") unless @image
  end

  def self.initialize_environment
    raise(Error, 'Docker configuration missing!') unless config[:connection_timeout] && config[:workspace_root]

    Docker.url = config[:host] if config[:host]
    # todo: availability check disabled for performance reasons. Reconsider if this is necessary.
    # docker daemon got much too much load. all not 100% necessary calls to the daemon were removed.
    # check_availability!
    FileUtils.mkdir_p(LOCAL_WORKSPACE_ROOT)
  end

  def self.local_workspace_path(container)
    Pathname.new(container.binds.first.split(':').first) if container.binds.present?
  end

  def self.mapped_directories(local_workspace_path)
    # create the string to be returned
    ["#{local_workspace_path}:#{CONTAINER_WORKSPACE_PATH}"]
  end

  def self.mapped_ports(execution_environment)
    execution_environment.exposed_ports.map do |port|
      ["#{port}/tcp", [{'HostPort' => PortPool.available_port.to_s}]]
    end.to_h
  end

  def self.return_container(container, execution_environment)
    # ToDo: Move method to DockerContainerPool method
    Rails.logger.debug('returning container ' + container.to_s)
    begin
      clean_container_workspace(container)
    rescue Docker::Error::NotFoundError => error
      # FIXME: Create new container?
      Rails.logger.info('return_container: Rescued from Docker::Error::NotFoundError: ' + error.to_s)
      Rails.logger.info('Nothing is done here additionally. The container will be exchanged upon its next retrieval.')
    end
    ContainerPool.instance.return_container(container, execution_environment)
  end

  # private :return_container

  class Error < RuntimeError; end
end
