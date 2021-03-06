Rails.application.routes.draw do
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html

  scope 'docker_container_pool' do
    get 'get_container/:execution_environment_id', to: 'container_pool#get_container'
    get 'return_container/:container_id', to: 'container_pool#return_container'
    get 'destroy_container/:container_id', to: 'container_pool#destroy_container'
    get 'quantities', to: 'container_pool#quantities'
    get 'dump_info', to: 'container_pool#dump_info'
  end

end
