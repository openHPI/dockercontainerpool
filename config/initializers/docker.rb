DockerClient.initialize_environment unless Rails.env.test? && `which docker`.blank?

if ApplicationRecord.connection.tables.present? && ContainerPool.instance.config[:active]
  ContainerPool.instance.start_refill_task
  at_exit { ContainerPool.instance.clean_up }
end
