require 'concurrent/future'
require 'concurrent/timer_task'
require 'singleton'


class ContainerPool
  include Singleton

  def initialize
    @mutex = Mutex.new

    @containers = Concurrent::Hash[ExecutionEnvironment.all.map { |execution_environment| [execution_environment.id, Concurrent::Array.new] }]
    # as containers are not containing containers in use
    @all_containers = Concurrent::Hash[ExecutionEnvironment.all.map { |execution_environment| [execution_environment.id, Concurrent::Array.new] }]
    @container_mapping = Concurrent::Hash[]
  end

  def clean_up
    Rails.logger.info('Container Pool is now performing a cleanup. ')
    @refill_task.try(:shutdown)
    @all_containers.values.each do |containers|
      DockerClient.destroy_container(containers.shift) until containers.empty?
    end
  end

  def config
    # TODO: Why erb?
    @config ||= CodeOcean::Config.new(:docker).read(erb: true)[:pool]
  end

  def containers
    @containers
  end

  def all_containers
    @all_containers
  end

  def mutex
    @mutex
  end

  def remove_from_all_containers(container, execution_environment)
    if @containers[execution_environment.id].include?(container)
      @containers[execution_environment.id].delete(container)
      Rails.logger.debug('Removed container ' + container.to_s + ' from available_pool for execution environment ' + execution_environment.to_s + '. Remaining containers in available_pool ' + @containers[execution_environment.id].size.to_s)
    end

    @all_containers[execution_environment.id].delete(container)
    @container_mapping.delete(container.id)
    Rails.logger.debug('Removed container ' + container.to_s + ' from all_pool for execution environment ' + execution_environment.to_s + '. Remaining containers in all_pool ' + @all_containers[execution_environment.id].size.to_s)
  end

  def add_to_all_containers(container, execution_environment)
    @all_containers[execution_environment.id].push(container)
    @container_mapping[container.id] = container
    if !@containers[execution_environment.id].include?(container)
      @containers[execution_environment.id].push(container)
      # Rails.logger.debug('Added container ' + container.to_s + ' to all_pool for execution environment ' + execution_environment.to_s + '. Containers in all_pool: ' + @all_containers[execution_environment.id].size.to_s)
    else
      Rails.logger.error('failed trying to add existing container ' + container.to_s + ' to execution_environment ' + execution_environment.to_s)
    end
  end

  def translate(container_id)
    @container_mapping[container_id]
  end

  def create_container(execution_environment)
    Rails.logger.info('trying to create container for execution environment: ' + execution_environment.to_s)
    container = DockerClient.create_container(execution_environment)
    container.status = :available
    # Rails.logger.debug('created container ' + container.to_s + ' for execution environment ' + execution_environment.to_s)
    add_to_all_containers(container, execution_environment)
    container
  end

  def return_container(container, execution_environment)
    container.docker_client.exit_thread_if_alive
    container.status = :available
    if @containers[execution_environment.id] && !@containers[execution_environment.id].include?(container) && container.re_use
      @containers[execution_environment.id].push(container)
    else
      Rails.logger.error('trying to return existing container ' + container.to_s + ' to execution_environment ' + execution_environment.to_s)
    end
  end

  def get_container(execution_environment)
    # if pooling is active, do pooling, otherwise just create an container and return it
    if config[:active]
      container = nil
      # Use a mutex here to prevent that a container is used from the list and destroyed at the same time
      mutex.synchronize {
        container = @containers[execution_environment.id].try(:shift) || nil
        container&.status = :executing
      }
      Rails.logger.debug('get_container fetched container  ' + container.to_s + ' for execution environment ' + execution_environment.to_s)
      # just access and the following if we got a container. Otherwise, the execution_environment might be just created and not fully exist yet.
      if container
        begin
          # check whether the container is running. exited containers go to the else part.
          # Dead containers raise a NotFoundError on the container.json call. This is handled in the rescue block.
          if container.json['State']['Running']
            Rails.logger.debug('get_container remaining avail. containers:  ' + @containers[execution_environment.id].size.to_s)
            Rails.logger.debug('get_container all container count: ' + @all_containers[execution_environment.id].size.to_s)
          else
            Rails.logger.error('docker_container_pool.get_container retrieved a container not running. Container will be removed from list:  ' + container.to_s)
            # TODO: check in which state the container actually is and treat it accordingly (dead,... => destroy?)
            container = replace_broken_container(container, execution_environment)
          end
        rescue Docker::Error::NotFoundError => error
          Rails.logger.error('docker_container_pool.get_container rescued from Docker::Error::NotFoundError. Most likely, the container is not there any longer. Removing faulty entry from list: ' + container.to_s)
          container = replace_broken_container(container, execution_environment)
        end
      end
    else
      container = create_container(execution_environment)
      container&.status = :executing
    end
    # returning nil is no problem. then the pool is just depleted.
    container.docker_client.kill_after_timeout(container) unless container.blank?
    container
  end

  def replace_broken_container(container, execution_environment)
    remove_from_all_containers(container, execution_environment)
    missing_counter_count = execution_environment.pool_size - @all_containers[execution_environment.id].length
    if missing_counter_count > 0
      Rails.logger.error('replace_broken_container: Creating a new container and returning that.')
      new_container = create_container(execution_environment)
      new_container.status = :executing
    else
      Rails.logger.error('Broken container removed for ' + execution_environment.to_s + ' but not creating a new one. Currently, ' + missing_counter_count.abs.to_s + ' more containers than the configured pool size are available.')
      new_container = get_container(execution_environment)
    end
    new_container
  end

  def quantities
    @containers.transform_values { |value| value.length }
  end

  def dump_info
    {
      process: $$,
      release: Sentry.configuration.release,
      containers: @containers.as_json,
      all_containers: @all_containers.as_json
    }
  end

  def refill
    ExecutionEnvironment.where('pool_size > 0').order(pool_size: :desc).each do |execution_environment|
      if config[:refill][:async]
        Concurrent::Future.execute { ContainerPool.instance.refill_for_execution_environment(execution_environment) }
      else
        ContainerPool.instance.refill_for_execution_environment(execution_environment)
      end
    end
  end

  def refill_for_execution_environment(execution_environment)
    refill_count = [execution_environment.pool_size - @all_containers[execution_environment.id].length, config[:refill][:batch_size]].min
    if refill_count > 0
      Rails.logger.info('Adding ' + refill_count.to_s + ' containers for execution_environment ' + execution_environment.name)
      multiple_containers = refill_count.times.map { create_container(execution_environment) }
      # Rails.logger.info('Created containers: ' + multiple_containers.to_s )
      # Rails.logger.debug('@containers  for ' + execution_environment.name.to_s + ' (' + @containers.object_id.to_s + ') has the following content: '+ @containers[execution_environment.id].to_s)
      # Rails.logger.debug('@all_containers for '  + execution_environment.name.to_s + ' (' + @all_containers.object_id.to_s + ') has the following content: ' + @all_containers[execution_environment.id].to_s)
    end
  end

  def start_refill_task
    @refill_task = Concurrent::TimerTask.new(execution_interval: config[:refill][:interval], run_now: true, timeout_interval: config[:refill][:timeout]) {
      ContainerPool.instance.refill
    }
    @refill_task.execute
  end
end
