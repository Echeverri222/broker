# OPS-05: fail the boot loudly instead of discovering connection exhaustion under load.
if Rails.env.production?
  problem = DeployConfig.pool_problem(ENV)
  raise problem if problem
end
