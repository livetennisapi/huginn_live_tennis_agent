# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# The gem also works with the full huginn_agent integration harness (which
# clones Huginn into spec/huginn and runs the specs inside it). To use it,
# replace the tasks above with:
#
#   require 'huginn_agent'
#   HuginnAgent.load_tasks(branch: 'master', remote: 'https://github.com/huginn/huginn.git')
