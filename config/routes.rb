Rails.application.routes.draw do
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html

  scope 'docker_container_pool' do
    post 'get_container/:execution_environment_id', to: 'container_pool#get_container'
    put 'return_container/:container_id', to: 'container_pool#return_container'
    delete 'destroy_container/:container_id', to: 'container_pool#destroy_container'
    post 'reuse_container/:container_id', to: 'container_pool#reuse_container'
    delete 'purge_environment/:execution_environment_id', to: 'container_pool#purge_environment'
    post 'refill_environment/:execution_environment_id', to: 'container_pool#refill_environment'
    get 'quantities', to: 'container_pool#quantities'
    get 'dump_info', to: 'container_pool#dump_info'
    get 'available_images', to: 'container_pool#available_images'
  end

  resources :ping, only: :index, defaults: { format: :json }
end
