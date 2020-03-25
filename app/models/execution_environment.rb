class ExecutionEnvironment < ApplicationRecord
  include DefaultValues

  after_initialize :set_default_values

  def set_default_values
    set_default_values_if_present(permitted_execution_time: 60, pool_size: 0)
  end
  private :set_default_values

  def to_s
    name
  end
end
