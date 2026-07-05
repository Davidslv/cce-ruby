# WHY: One canonical command to run the full deterministic test suite.
# WHAT: A minimal Rake test task over test/**/*_test.rb.
# RESPONSIBILITIES: Wire Minitest; own no application logic.

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
  t.verbose = false
end

task default: :test
