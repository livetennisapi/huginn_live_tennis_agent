# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = 'huginn_live_tennis_agent'
  spec.version       = '0.1.0'
  spec.authors       = ['Live Tennis API']
  spec.email         = ['hello@livetennisapi.com']

  spec.summary       = 'Huginn agent for the Live Tennis API: emits events on match start, score change, match finish, and fixture changes.'
  spec.description   = 'Polls the Live Tennis API (livetennisapi.com) and emits Huginn events on state transitions: match_started, score_changed, match_finished in live_scores mode, and new_fixture / fixture_updated in fixtures mode. Vendor-authored: we run the Live Tennis API. Uses only FREE-tier endpoints.'

  spec.homepage      = 'https://github.com/livetennisapi/huginn_live_tennis_agent'
  spec.license       = 'MIT'

  spec.files         = Dir['LICENSE.txt', 'lib/**/*']
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.required_ruby_version = '>= 3.0'

  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'webmock', '~> 3.19'

  spec.add_runtime_dependency 'huginn_agent'
end
