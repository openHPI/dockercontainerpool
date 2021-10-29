class ContainerPoolController < ActionController::API
  def get_container
    execution_environment_id = params[:execution_environment_id].to_i
    execution_environment = ExecutionEnvironment.find(execution_environment_id)
    container = ContainerPool.instance.get_container(execution_environment)

    render json: {
      id: container ? container.id : nil
    }
  end

  def return_container
    container_id = params[:container_id]
    container = ContainerPool.instance.translate(container_id)
    ContainerPool.instance.return_container(container, container.execution_environment) unless container.blank?

    render json: { }
  end

  def destroy_container
    container_id = params[:container_id]
    container = ContainerPool.instance.translate(container_id)
    container.docker_client.kill_container(container) unless container.blank?

    render json: { }
  end

  def available_images
    DockerClient.check_availability!
    render json: DockerClient.image_tags
  rescue DockerClient::Error => e
    render json: { error: e.message }, status: :internal_server_error
  end

  def quantities
    render json: ContainerPool.instance.quantities
  end

  def dump_info
    render json: ContainerPool.instance.dump_info
  end
end
